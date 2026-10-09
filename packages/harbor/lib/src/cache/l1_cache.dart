import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../peripherals/register_file.dart';
import '../soc/target.dart';
import 'cache_config.dart';

/// L1 cache request type.
enum HarborL1RequestType {
  /// Instruction fetch.
  fetch,

  /// Data load.
  load,

  /// Data store.
  store,

  /// Atomic (LR/SC/AMO).
  atomic,

  /// Cache management (fence, invalidate).
  management,
}

/// L1 cache line state for coherency.
enum HarborL1LineState {
  /// Invalid.
  invalid,

  /// Shared (read-only, other copies may exist).
  shared,

  /// Exclusive (only copy, clean).
  exclusive,

  /// Modified (only copy, dirty).
  modified,

  /// Owned (dirty, other shared copies may exist, MOESI only).
  owned,
}

/// Synthesizable L1 instruction cache.
///
/// Set-associative cache with configurable size, associativity,
/// and line size. Generates the tag RAM, data RAM, hit detection,
/// and replacement logic.
///
/// Connects to the CPU fetch port on the request side and the
/// L2/memory bus on the refill side.
class HarborL1ICache extends BridgeModule {
  /// Cache configuration.
  final HarborCacheConfig config;

  /// Machine word width (RV32 = 32, RV64 = 64). One word is served per fetch.
  final int xlen;

  /// Second lookup port for dual-dispatch fetch: both lanes are served the same
  /// cycle when their (consecutive) addresses land in the same line, the
  /// bandwidth a single shared bus could not provide.
  final bool dualPort;

  /// Width of the permission-context tag kept with each line. Zero disables it.
  ///
  /// The cache is in FRONT of the MMU: the pipeline presents a VIRTUAL address,
  /// and only a MISS goes on to the MMU, which translates it and checks the PTE.
  /// A HIT is decided by the tag and the valid bit alone, so no permission check
  /// runs on it. A line that one privilege mode was allowed to fill therefore
  /// stays usable by a mode the page table forbids.
  ///
  /// Each line records the context that filled it, and a hit must match the
  /// context of the access. An access from a different context misses and goes
  /// to the MMU, which checks the PTE and faults if the access is not allowed.
  /// The core supplies the privilege mode here (see [reqCtx]).
  final int ctxBits;

  /// Request port (from CPU fetch unit). The fetcher holds [reqAddr]/[reqValid]
  /// until [respValid]. A hit answers one cycle after the address is presented.
  Logic get reqAddr => input('req_addr');
  Logic get reqValid => input('req_valid');
  Logic get respData => output('resp_data');

  /// Permission context of the current request. Present only when [ctxBits] > 0.
  Logic get reqCtx => input('req_ctx');

  /// High for one cycle when the held request is served (hit). Doubles as the
  /// done handshake, the fetch unit re-reads until it sees this.
  Logic get respValid => output('resp_valid');
  Logic get miss => output('miss');

  /// Second lookup port (present only when [dualPort]).
  Logic get reqAddr1 => input('req_addr1');
  Logic get reqValid1 => input('req_valid1');
  Logic get respData1 => output('resp_data1');
  Logic get respValid1 => output('resp_valid1');

  /// Whole-cache flush (fence.i / satp change). Clears every valid bit in one
  /// cycle, since the cache is virtually addressed.
  Logic get flush => input('flush');

  /// Word-granular refill request to the MMU/memory. A miss fills its line one
  /// word per response, so the DDR PHY only ever sees the single paced read it
  /// captures correctly, never a back-to-back line burst.
  Logic get memEn => output('mem_en');
  Logic get memAddr => output('mem_addr');
  Logic get memDone => input('mem_done');
  Logic get memValid => input('mem_valid');
  Logic get memRdata => input('mem_rdata');

  /// Instruction page fault from the fetch translation. Asserted with the refill
  /// response (done, not valid) when the MMU walk faulted. Without it a faulting
  /// refill leaves the fill FSM stalled forever, since it only completes on
  /// done AND valid.
  Logic get memFault => input('mem_fault');

  /// Fetch fault to the pipeline. Held with resp done AND not valid for the
  /// faulting request. Consumers that do not inspect [respFaultIsAccess] still
  /// complete and trap the request safely.
  Logic get respFault => output('resp_fault');

  /// Qualifies [respFault]: high for a physical access fault, low for a page
  /// fault. Meaningful only while [respFault] is high.
  Logic get respFaultIsAccess => output('resp_fault_is_access');

  HarborL1ICache({
    required this.config,
    this.xlen = 64,
    this.dualPort = false,
    this.ctxBits = 0,
    // Significant low bits of [reqAddr]: the tag store and compares are sized to
    // this instead of [xlen], so a cache over a narrow map does not pay for a
    // full 64-bit tag. Null = xlen. See the note on tag width below.
    int? reqAddrBits,
    // FPGA/ASIC target for the data block RAM. Null (simulation / std-cell) uses
    // the flop backend at the same forced read latency.
    HarborDeviceTarget? target,
    super.name = 'l1i',
  }) : super('HarborL1ICache') {
    if (config.ways != 1) {
      throw ArgumentError(
        'HarborL1ICache is direct-mapped (ways must be 1, got ${config.ways}).',
      );
    }
    if (ctxBits < 0) {
      throw ArgumentError('ctxBits must not be negative (got $ctxBits).');
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('req_addr', PortDirection.input, width: xlen);
    createPort('req_valid', PortDirection.input);
    if (ctxBits > 0) {
      createPort('req_ctx', PortDirection.input, width: ctxBits);
    }
    createPort('flush', PortDirection.input);
    addOutput('resp_data', width: xlen);
    addOutput('resp_valid');
    addOutput('resp_fault');
    addOutput('resp_fault_is_access');
    addOutput('miss');
    if (dualPort) {
      createPort('req_addr1', PortDirection.input, width: xlen);
      createPort('req_valid1', PortDirection.input);
      addOutput('resp_data1', width: xlen);
      addOutput('resp_valid1');
    }
    // Word-granular refill handshake to the MMU ifetch port.
    addOutput('mem_en');
    addOutput('mem_addr', width: xlen);
    createPort('mem_done', PortDirection.input);
    createPort('mem_valid', PortDirection.input);
    createPort('mem_rdata', PortDirection.input, width: xlen);
    createPort('mem_fault', PortDirection.input);

    final clk = input('clk');
    final reset = input('reset');

    final wordBytes = xlen ~/ 8;
    final lineWords = config.lineSize ~/ wordBytes;
    if (lineWords < 1) {
      throw ArgumentError(
        'lineSize (${config.lineSize}B) must hold at least one $wordBytes-byte '
        'word.',
      );
    }
    final numLines = config.lines;
    final offBits = (lineWords - 1).bitLength; // word index within a line
    final idxBits = (numLines - 1).bitLength; // line index
    final byteBits = (wordBytes - 1).bitLength; // byte within a word
    final tagLo = byteBits + offBits + idxBits;
    // Tag width.
    //
    // This cache is in FRONT of the MMU, so it is virtually indexed AND
    // virtually tagged: [reqAddr] is a VIRTUAL address whenever paging is on.
    // The tag must therefore span every significant bit of the VIRTUAL address,
    // not of the physical map. Sizing it from a physical width (32 bits on a
    // 4 GB map) dropped VA[63:32] from the compare, and under Sv39 the
    // supervisor half puts the linear map, vmalloc and kernel text at different
    // VA[38:32] with overlapping low bits, so two different pages became ONE
    // line and a load returned the other page's data.
    //
    // For a canonical Sv39 address VA[63:39] is a sign extension of VA[38], so
    // comparing VA[38:tagLo] is EXACTLY equivalent to comparing all 64 bits, not
    // an approximation: 39 is the minimum correct width, and the caller passes
    // it. A non-canonical address is architecturally a fault and never reaches a
    // resident line, because nothing can fill one for it.
    //
    // The bits cannot be folded or hashed down. The tag is the only evidence the
    // cache has about which address a line holds, so any encoding that maps two
    // addresses onto one tag produces a false HIT and serves the wrong data.
    // Only a lossless width is correct.
    final reqBits = reqAddrBits ?? xlen;
    final addrBits = reqBits > xlen ? xlen : reqBits;
    if (addrBits <= tagLo) {
      throw ArgumentError(
        'reqAddrBits ($reqBits) must exceed the index and offset bits '
        '($tagLo), or a line has no tag at all.',
      );
    }
    final tagBits = addrBits - tagLo;
    // The stored tag is {context, address tag}, so a line is only hit from the
    // context that filled it. See [ctxBits].
    final lineTagBits = tagBits + ctxBits;

    Logic idxOf(Logic addr) => idxBits == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits + offBits);
    Logic tagOf(Logic addr) => addr.slice(addrBits - 1, tagLo);
    Logic fullTagOf(Logic addr) =>
        ctxBits == 0 ? tagOf(addr) : [reqCtx, tagOf(addr)].swizzle();
    // Combined {line, word} index into the flat data RAM.
    Logic dataEntryOf(Logic addr) => (offBits + idxBits) == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits);

    // Valid bits flush in one cycle; tags and data share registered read timing.
    final lineValid = List.generate(numLines, (i) => Logic(name: 'valid_$i'));
    final tagRam = HarborRegisterFile(
      numEntries: numLines,
      dataWidth: lineTagBits,
      numReadPorts: dualPort ? 2 : 1,
      numWritePorts: 1,
      reservedZero: false,
      target: target,
      forceReadLatency: 1,
      name: 'l1i_tags',
    );
    addSubModule(tagRam);
    tagRam.input('clk').srcConnection! <= clk;
    tagRam.input('reset').srcConnection! <= reset;
    tagRam.input('rd0_addr').srcConnection! <= idxOf(reqAddr);
    if (dualPort) {
      tagRam.input('rd1_addr').srcConnection! <= idxOf(reqAddr1);
    }

    // Balanced mux tree (log2(numLines) deep) when the line count is a power of
    // two; see the matching helper in HarborL1DCache. Replaces a numLines-deep
    // linear priority chain that was the core's FPGA timing-critical path.
    Logic muxLine(List<Logic> arr, Logic idx) {
      if (numLines > 1 && (numLines & (numLines - 1)) == 0) {
        var level = List<Logic>.from(arr);
        var bit = 0;
        while (level.length > 1) {
          final next = <Logic>[];
          for (var i = 0; i < level.length; i += 2) {
            next.add(mux(idx[bit], level[i + 1], level[i]));
          }
          level = next;
          bit++;
        }
        return level[0];
      }
      var r = arr[0];
      for (var i = 1; i < numLines; i++) {
        r = mux(idx.eq(i), arr[i], r);
      }
      return r;
    }

    // Per-line DATA in a block RAM (one read port, one write port for fills).
    // readLatency forced to 1 so the sim flop model behaves exactly like a
    // registered EBR read.
    final dataRam = HarborRegisterFile(
      numEntries: numLines * lineWords,
      dataWidth: xlen,
      numReadPorts: dualPort ? 2 : 1,
      numWritePorts: 1,
      reservedZero: false,
      target: target,
      forceReadLatency: 1,
      name: 'l1i_data',
    );
    addSubModule(dataRam);
    dataRam.input('clk').srcConnection! <= clk;
    dataRam.input('reset').srcConnection! <= reset;
    dataRam.input('rd0_addr').srcConnection! <= dataEntryOf(reqAddr);
    if (dualPort) {
      dataRam.input('rd1_addr').srcConnection! <= dataEntryOf(reqAddr1);
    }

    // Miss/fill FSM state.
    final filling = Logic(name: 'filling');
    // A flush (fence.i) mid-fill abandons the in-flight refill, but the MMU
    // latched that read at arbitration and completes it regardless. `drain`
    // holds the cache off starting a new fill until that stale completion has
    // arrived and been discarded, so it can never land as word 0 of the next
    // line (the creek Weir->Ferrite handoff corruption).
    final drain = Logic(name: 'drain');
    // High for one cycle after a fill commits: the just-written entry was the
    // read-during-write target, so its registered read is only trustworthy the
    // cycle after. Gates the hit off for that settling cycle.
    final fillSettle = Logic(name: 'fillSettle');
    final fillIdx = Logic(name: 'fillIdx', width: idxBits == 0 ? 1 : idxBits);
    final fillTag = Logic(name: 'fillTag', width: lineTagBits);
    final fillBase = Logic(name: 'fillBase', width: xlen);
    final fillWord = Logic(
      name: 'fillWord',
      width: (offBits == 0 ? 1 : offBits) + 1,
    );

    // Fetch-fault latch: set when a refill fails, with mem_fault preserving
    // whether it was a page fault or a physical access fault. Held until the
    // requesting fetch retargets (the pipeline trapped and redirected).
    // While set for [faultAddr] it suppresses a fresh fill of that same line, so
    // the miss does not loop fill -> fault -> fill.
    final faultResp = Logic(name: 'faultResp');
    final faultIsPage = Logic(name: 'faultIsPage');
    final faultAddr = Logic(name: 'faultAddr', width: xlen);

    // One-cycle-delayed copy of the request address: the block-RAM read launched
    // last cycle answers this cycle, so hit detection compares against it.
    final addrQ = Logic(name: 'addrQ', width: xlen);
    final addrQ1 = dualPort ? Logic(name: 'addrQ1', width: xlen) : null;

    final blockHit = (filling | fillSettle).named('blockHit');

    Logic committedHit(Logic a, [int port = 0]) =>
        muxLine(lineValid, idxOf(a)) & tagRam.readData(port).eq(fullTagOf(a));

    final ans = (reqValid & reqAddr.eq(addrQ)).named('ans');
    final hit = (ans & committedHit(addrQ) & ~blockHit).named('hit');
    final miss0 = (ans & ~committedHit(addrQ) & ~blockHit).named('miss0');
    final ans1 = dualPort
        ? (reqValid1 & reqAddr1.eq(addrQ1!)).named('ans1')
        : Const(0);
    final hit1 = dualPort
        ? (ans1 & committedHit(addrQ1!, 1) & ~blockHit).named('hit1')
        : Const(0);
    final miss1 = dualPort
        ? (ans1 & ~committedHit(addrQ1!, 1) & ~blockHit).named('miss1')
        : Const(0);
    // The faulting fetch is held by the FetchUnit at [faultAddr]; do not restart a
    // fill for it (it would just fault again), let respFault deliver the fault.
    final faultHeld = (faultResp & reqValid & reqAddr.eq(faultAddr)).named(
      'faultHeld',
    );
    // Port 0 has priority for starting a fill, fill from the missing port's held
    // (registered) address.
    final wantFill = ((miss0 | miss1) & ~faultHeld).named('wantFill');
    final fillAddr = mux(miss0, addrQ, dualPort ? addrQ1! : addrQ);

    final fillLineBase =
        fillAddr &
        ~Const((BigInt.one << (byteBits + offBits)) - BigInt.one, width: xlen);

    final memEnR = Logic(name: 'memEnR');
    final memAddrR = Logic(name: 'memAddrR', width: xlen);
    memEn <= memEnR;
    memAddr <= memAddrR;

    respData <= dataRam.readData(0);
    respValid <= hit;
    // A faulting fetch presents as done (in core.dart: done = respValid |
    // respFault) with valid low, so the FetchUnit raises the instruction page
    // fault instead of retrying. Gated to the held request so a stale latch never
    // faults an unrelated fetch.
    respFault <= faultHeld;
    respFaultIsAccess <= faultHeld & ~faultIsPage;
    miss <= miss0;
    if (dualPort) {
      respData1 <= dataRam.readData(1);
      respValid1 <= hit1;
    }

    // Data block-RAM write port: one fill word per MMU response.
    final fillWrEn = (filling & memDone & memValid & ~flush & ~reset).named(
      'fillWrEn',
    );
    final Logic fillEntry;
    if (offBits == 0) {
      fillEntry = fillIdx;
    } else if (idxBits == 0) {
      fillEntry = fillWord.slice(offBits - 1, 0);
    } else {
      fillEntry = [fillIdx, fillWord.slice(offBits - 1, 0)].swizzle();
    }
    dataRam.input('wr_en').srcConnection! <= fillWrEn;
    dataRam.input('wr_addr').srcConnection! <= fillEntry;
    dataRam.input('wr_data').srcConnection! <= memRdata;

    final lastWord = Const(lineWords - 1, width: fillWord.width);
    tagRam.input('wr_en').srcConnection! <= fillWrEn & fillWord.eq(lastWord);
    tagRam.input('wr_addr').srcConnection! <= fillIdx;
    tagRam.input('wr_data').srcConnection! <= fillTag;

    Sequential(clk, [
      addrQ < reqAddr,
      if (dualPort) addrQ1! < reqAddr1,
      If(
        reset,
        then: [
          ...List.generate(numLines, (i) => lineValid[i] < 0),
          filling < 0,
          fillSettle < 0,
          memEnR < 0,
          drain < 0,
          faultResp < 0,
          faultIsPage < 0,
        ],
        orElse: [
          If(
            flush,
            then: [
              ...List.generate(numLines, (i) => lineValid[i] < 0),
              filling < 0,
              fillSettle < 0,
              memEnR < 0,
              faultResp < 0,
              // If a refill read is still outstanding to the MMU (filling, or
              // already draining a prior flush), keep draining until its stale
              // completion arrives, unless it completes this very cycle.
              //
              // "Completes" is `memDone` ALONE, exactly like the release arm
              // below and like HarborL1DCache. A page-faulting refill answers
              // with mem_done high and mem_valid LOW, so the old
              // `~(memDone & memValid)` treated a fault as "no completion yet".
              // A fetch page fault that landed on the same cycle as a flush
              // therefore armed a drain that was ALREADY satisfied, no second
              // response ever came to release it, and the cache blocked every
              // future fill: the core stopped fetching. Linux reaches this
              // every time a demand-paging fetch fault meets the satp write of
              // a context switch, an sfence.vma or a fence.i.
              drain < (filling | drain) & ~memDone,
            ],
            orElse: [
              fillSettle < 0,
              // The pipeline trapped on the fault and redirected the fetch, so the
              // held request retargeted; drop the latch so a later miss can fill.
              If(faultResp & ~faultHeld, then: [faultResp < 0]),
              If(
                drain,
                then: [
                  // Waiting out the abandoned read. filling is 0 so its
                  // completion is never written; just release once it lands
                  // (data or fault, so a faulting stale read cannot hang drain).
                  If(memDone, then: [drain < 0]),
                ],
                orElse: [
                  If(
                    filling,
                    then: [
                      If(
                        memDone & memValid,
                        then: [
                          If(
                            fillWord.eq(lastWord),
                            then: [
                              memEnR < 0,
                              filling < 0,
                              fillSettle < 1,
                              ...List.generate(
                                numLines,
                                (l) =>
                                    If(fillIdx.eq(l), then: [lineValid[l] < 1]),
                              ),
                            ],
                            orElse: [
                              fillWord < fillWord + 1,
                              memAddrR <
                                  (fillBase +
                                      ((fillWord + 1).zeroExtend(xlen) *
                                          Const(wordBytes, width: xlen))),
                            ],
                          ),
                        ],
                        // done AND not valid: the MMU fetch walk page-faulted
                        // (mem_fault). Stop the fill (never mark the line valid)
                        // and latch the fault so respFault delivers it to the
                        // pipeline. Without this the fill FSM stalls forever.
                        orElse: [
                          If(
                            memDone,
                            then: [
                              memEnR < 0,
                              filling < 0,
                              faultResp < 1,
                              faultIsPage < memFault,
                            ],
                          ),
                        ],
                      ),
                    ],
                    orElse: [
                      If(
                        wantFill,
                        then: [
                          filling < 1,
                          // Refill overwrites data before committing its tag.
                          // Drop the victim now so a later fault cannot expose
                          // partial replacement data under the old valid tag.
                          ...List.generate(
                            numLines,
                            (l) => If(
                              idxOf(fillAddr).eq(l),
                              then: [lineValid[l] < 0],
                            ),
                          ),
                          fillIdx < idxOf(fillAddr),
                          fillTag < fullTagOf(fillAddr),
                          fillBase < fillLineBase,
                          fillWord < 0,
                          memEnR < 1,
                          memAddrR < fillLineBase,
                          // Remember the exact request address this fill serves;
                          // if it faults, respFault is gated to a held request at
                          // this address so a stale latch never faults another
                          // fetch.
                          faultAddr < fillAddr,
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// Synthesizable L1 data cache: direct-mapped, write-through, no-write-allocate.
///
/// The load path is the [HarborL1ICache] path, a miss fills its line one paced
/// word at a time so the DDR PHY only ever sees the single reads it captures
/// correctly, then held loads hit out of the block RAM. That pacing is the whole
/// reason the cache exists: it isolates the data-load stream from back-to-back
/// bursts the marginal PHY mis-captures.
///
/// Stores are write-through with no write-allocate: the store goes straight to
/// memory through the same verified write path, and if its line is resident the
/// line is invalidated (a following load re-fills it, paced). This keeps the
/// cached copy coherent without any sub-word merge or dirty-line eviction burst,
/// stores already work on this hardware. The cache is here to pace loads.
class HarborL1DCache extends BridgeModule {
  /// Cache configuration.
  final HarborCacheConfig config;

  /// Machine word width (RV32 = 32, RV64 = 64).
  final int xlen;

  /// Lowest cacheable address. Only accesses at or above this are cached, every
  /// access below it (MMIO devices, boot SRAM, flash) is passed straight through
  /// to memory uncached. Caching MMIO is a correctness bug: a cached UART status
  /// register would read a stale ready bit forever and hang the first putchar.
  /// Defaults to the RISC-V DRAM base (0x80000000), which is exactly the region
  /// whose reads need pacing.
  final int cacheableBase;

  /// Requests already carry physical addresses. The caller must perform
  /// translation, permission and cacheability checks before every request,
  /// including hits, and authorize the complete refill footprint.
  ///
  /// Physical aliases have the same index, so this opt-in removes the virtual
  /// cache's page-size capacity bound. Tags must retain the full address width.
  /// It does not translate addresses or change [cacheableBase].
  final bool physicalAddresses;

  /// Bits of the address that translation does not change (log2 of the page
  /// size). Sv32, Sv39 and Sv48 all use 4 KB base pages, so 12. The store
  /// invalidate relies on the cache index being cut from these bits, because
  /// they are identical in every virtual mapping of one physical frame.
  static const int pageOffsetBits = 12;

  /// Width of the permission-context tag kept with each line. Zero disables it.
  ///
  /// In the default virtual placement, the pipeline presents a virtual address
  /// and only a miss reaches the MMU, which translates it and checks the PTE.
  /// In that placement, a LOAD HIT is decided by the tag and valid bit alone,
  /// so no permission
  /// check runs on it. A line that one privilege mode was allowed to fill
  /// therefore stays readable by a mode the page table forbids: user code read
  /// a supervisor-only page out of the cache, and a supervisor load with
  /// sstatus.SUM clear read a user page out of it.
  ///
  /// Each line records the context that filled it, and a load hit must match the
  /// context of the access. An access from a different context misses and goes
  /// to the MMU, which checks the PTE and faults if the access is not allowed.
  /// The core supplies the privilege mode and the SUM bit here (see [reqCtx]).
  ///
  /// Stores are unaffected: they are write-through, so every store already
  /// reaches the MMU and is checked. Store invalidation stays context-blind, so
  /// a store never leaves another context holding stale data.
  final int ctxBits;

  /// Request port (from the load/store unit). [reqWrite] selects store.
  ///
  /// There is no accept handshake. The cache answers with [respValid] or
  /// [respFault] and gives no earlier signal, so the requester MUST hold
  /// [reqValid], [reqAddr], [reqData] and [reqSize] steady until one of the two
  /// arrives. A request that is withdrawn while the cache is busy with an
  /// earlier op is simply not seen. The core's exec unit keeps its registered
  /// request asserted until it samples done, which satisfies this, and it cannot
  /// do otherwise because a store completes only through `storeDone`, which the
  /// cache raises only after the write-through has gone to memory.
  Logic get reqAddr => input('req_addr');
  Logic get reqValid => input('req_valid');
  Logic get reqWrite => input('req_write');
  Logic get reqData => input('req_data');
  Logic get reqSize => input('req_size');
  Logic get respData => output('resp_data');

  /// Permission context of the current request. Present only when [ctxBits] > 0.
  Logic get reqCtx => input('req_ctx');

  /// High for one cycle when the op completes: a load hit/fill-done, or a store
  /// once memory acknowledges the write.
  Logic get respValid => output('resp_valid');

  /// High for one cycle when the memory response for this op was a fault. A
  /// consumer that does not inspect [respFaultIsAccess] still completes and
  /// traps the request safely.
  ///
  /// Without this the fill and bypass FSMs only ever complete on
  /// `mem_done & mem_valid`, so a faulting access left them asserted FOREVER and
  /// the core hung on that instruction instead of trapping: a NULL pointer
  /// dereference froze the machine rather than producing a kernel oops. The
  /// I-cache has had the equivalent path; the D-cache never did.
  Logic get respFault => output('resp_fault');

  /// Qualifies [respFault]: high for a physical access fault, low for a page
  /// fault. Meaningful only while [respFault] is high.
  Logic get respFaultIsAccess => output('resp_fault_is_access');
  Logic get miss => output('miss');
  Logic get busy => output('busy');

  /// Whole-cache flush.
  Logic get flush => input('flush');

  /// Word-granular memory port (shared by load fills and write-through stores).
  Logic get memEn => output('mem_en');
  Logic get memWe => output('mem_we');
  Logic get memAddr => output('mem_addr');
  Logic get memWdata => output('mem_wdata');
  Logic get memSize => output('mem_size');
  Logic get memDone => input('mem_done');
  Logic get memValid => input('mem_valid');
  Logic get memRdata => input('mem_rdata');

  /// Distinguishes a page fault from a physical access fault when [memDone] is
  /// high and [memValid] is low.
  Logic get memFault => input('mem_fault');

  HarborL1DCache({
    required this.config,
    this.xlen = 64,
    this.cacheableBase = 0x80000000,
    this.physicalAddresses = false,
    this.ctxBits = 0,
    Logic? memFaultIn,
    // Significant low bits of [reqAddr]. See the note on tag width below.
    int? reqAddrBits,
    HarborDeviceTarget? target,
    super.name = 'l1d',
  }) : super('HarborL1DCache') {
    if (config.ways != 1) {
      throw ArgumentError(
        'HarborL1DCache is direct-mapped (ways must be 1, got ${config.ways}).',
      );
    }
    if (ctxBits < 0) {
      throw ArgumentError('ctxBits must not be negative (got $ctxBits).');
    }
    if (physicalAddresses && reqAddrBits != null && reqAddrBits != xlen) {
      throw ArgumentError(
        'Physical cache tags must retain all $xlen address bits.',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('req_addr', PortDirection.input, width: xlen);
    createPort('req_valid', PortDirection.input);
    if (ctxBits > 0) {
      createPort('req_ctx', PortDirection.input, width: ctxBits);
    }
    createPort('req_write', PortDirection.input);
    createPort('req_data', PortDirection.input, width: xlen);
    createPort('req_size', PortDirection.input, width: 3);
    createPort('flush', PortDirection.input);
    addOutput('resp_data', width: xlen);
    addOutput('resp_valid');
    addOutput('resp_fault');
    addOutput('resp_fault_is_access');
    addOutput('miss');
    addOutput('busy');
    // Word-granular memory port.
    addOutput('mem_en');
    addOutput('mem_we');
    addOutput('mem_addr', width: xlen);
    addOutput('mem_wdata', width: xlen);
    addOutput('mem_size', width: 3);
    createPort('mem_done', PortDirection.input);
    createPort('mem_valid', PortDirection.input);
    createPort('mem_rdata', PortDirection.input, width: xlen);
    // Default to page fault for backwards compatibility: an old consumer that
    // does not wire classification must still complete and trap, never float.
    addInput('mem_fault', memFaultIn ?? Const(0));

    final clk = input('clk');
    final reset = input('reset');

    final wordBytes = xlen ~/ 8;
    final lineWords = config.lineSize ~/ wordBytes;
    if (lineWords < 1) {
      throw ArgumentError(
        'lineSize (${config.lineSize}B) must hold at least one $wordBytes-byte '
        'word.',
      );
    }
    final numLines = config.lines;
    final offBits = (lineWords - 1).bitLength;
    final idxBits = (numLines - 1).bitLength;
    final byteBits = (wordBytes - 1).bitLength;
    final tagLo = byteBits + offBits + idxBits;
    // Tag width.
    //
    // This cache is in FRONT of the MMU, so it is virtually indexed AND
    // virtually tagged: [reqAddr] is a VIRTUAL address whenever paging is on.
    // The tag must therefore span every significant bit of the VIRTUAL address,
    // not of the physical map. Sizing it from a physical width (32 bits on a
    // 4 GB map) dropped VA[63:32] from the compare, and under Sv39 the
    // supervisor half puts the linear map, vmalloc and kernel text at different
    // VA[38:32] with overlapping low bits, so two different pages became ONE
    // line and a load returned the other page's data.
    //
    // For a canonical Sv39 address VA[63:39] is a sign extension of VA[38], so
    // comparing VA[38:tagLo] is EXACTLY equivalent to comparing all 64 bits, not
    // an approximation: 39 is the minimum correct width, and the caller passes
    // it. A non-canonical address is architecturally a fault and never reaches a
    // resident line, because nothing can fill one for it.
    //
    // The bits cannot be folded or hashed down. The tag is the only evidence the
    // cache has about which address a line holds, so any encoding that maps two
    // addresses onto one tag produces a false HIT and serves the wrong data.
    // Only a lossless width is correct.
    final reqBits = reqAddrBits ?? xlen;
    final addrBits = reqBits > xlen ? xlen : reqBits;
    if (addrBits <= tagLo) {
      throw ArgumentError(
        'reqAddrBits ($reqBits) must exceed the index and offset bits '
        '($tagLo), or a line has no tag at all.',
      );
    }
    // The index must come from bits BELOW the 4 KB page offset, so the cache
    // size per way must not exceed one page.
    //
    // Two virtual addresses can name one physical word. The cache is virtually
    // tagged, so it cannot see that, and a store through one of them must still
    // drop the line the other one holds. It does that by index (see `storeInv`
    // in the store arm), which only reaches every alias while the index bits
    // are inside the page offset: those bits are the same in every mapping of
    // one frame. Above a page per way the index moves into the translated part
    // of the address, two aliases land on DIFFERENT lines, and a store can no
    // longer find the other one. This is the classic alias-free condition for a
    // virtually indexed cache.
    if (!physicalAddresses && tagLo > pageOffsetBits) {
      throw ArgumentError(
        'the cache is virtually indexed, so one way (${config.size ~/ config.ways} '
        'bytes) must not exceed the ${1 << pageOffsetBits}-byte page: the index '
        'takes bits [${tagLo - 1}:0] and anything above bit '
        '${pageOffsetBits - 1} differs between two mappings of one frame, so a '
        'store cannot invalidate its aliases.',
      );
    }
    final tagBits = addrBits - tagLo;
    // The stored tag is {context, address tag}, so a load is only hit from the
    // context that filled the line. See [ctxBits].
    final lineTagBits = tagBits + ctxBits;

    Logic idxOf(Logic addr) => idxBits == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits + offBits);
    Logic tagOf(Logic addr) => addr.slice(addrBits - 1, tagLo);
    Logic fullTagOf(Logic addr) =>
        ctxBits == 0 ? tagOf(addr) : [reqCtx, tagOf(addr)].swizzle();
    Logic dataEntryOf(Logic addr) => (offBits + idxBits) == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits);

    final lineValid = List.generate(numLines, (i) => Logic(name: 'valid_$i'));
    final tagRam = HarborRegisterFile(
      numEntries: numLines,
      dataWidth: lineTagBits,
      numReadPorts: 1,
      numWritePorts: 1,
      reservedZero: false,
      target: target,
      forceReadLatency: 1,
      name: 'l1d_tags',
    );
    addSubModule(tagRam);
    tagRam.input('clk').srcConnection! <= clk;
    tagRam.input('reset').srcConnection! <= reset;
    tagRam.input('rd0_addr').srcConnection! <= idxOf(reqAddr);

    // Select arr[idx]. A balanced mux tree (log2(numLines) deep) when the line
    // count is a power of two, folding pairs on one index bit per level. The
    // old linear `mux(idx.eq(i), arr[i], r)` chain was numLines muxes deep and,
    // run twice (valid + tag) into the tag compare, was the core's FPGA timing-
    // critical path. Falls back to the linear form for a non-power-of-two count.
    Logic muxLine(List<Logic> arr, Logic idx) {
      if (numLines > 1 && (numLines & (numLines - 1)) == 0) {
        var level = List<Logic>.from(arr);
        var bit = 0;
        while (level.length > 1) {
          final next = <Logic>[];
          for (var i = 0; i < level.length; i += 2) {
            next.add(mux(idx[bit], level[i + 1], level[i]));
          }
          level = next;
          bit++;
        }
        return level[0];
      }
      var r = arr[0];
      for (var i = 1; i < numLines; i++) {
        r = mux(idx.eq(i), arr[i], r);
      }
      return r;
    }

    // Match address and permission context. Stores invalidate by index and
    // require no asynchronous tag read.
    Logic committedHitOf(Logic a) =>
        muxLine(lineValid, idxOf(a)) & tagRam.readData(0).eq(fullTagOf(a));

    final dataRam = HarborRegisterFile(
      numEntries: numLines * lineWords,
      dataWidth: xlen,
      numReadPorts: 1,
      numWritePorts: 1,
      reservedZero: false,
      target: target,
      forceReadLatency: 1,
      name: 'l1d_data',
    );
    addSubModule(dataRam);
    dataRam.input('clk').srcConnection! <= clk;
    dataRam.input('reset').srcConnection! <= reset;
    dataRam.input('rd0_addr').srcConnection! <= dataEntryOf(reqAddr);

    // FSM state.
    final filling = Logic(name: 'filling');
    final fillSettle = Logic(name: 'fillSettle');
    // Drain an abandoned refill beat after a flush. Stores and bypass reads
    // must instead finish normally: they may already have caused MMIO side
    // effects, so discarding their response would make the requester retry.
    // A discarded refill completion must not become word 0 of a new line.
    // Mirrors [HarborL1ICache].
    final drain = Logic(name: 'drain');
    final storing = Logic(name: 'storing');
    // Single-cycle pulse, same shape as storeDone/bypassDone: the memory
    // response for the in-flight op was a fault.
    final faultDone = Logic(name: 'faultDone');
    final faultIsPage = Logic(name: 'faultIsPage');
    final storeDone = Logic(name: 'storeDone');
    // Uncached-read pass-through (MMIO / SRAM / flash): a single memory read
    // whose data is returned directly, never written into the cache.
    final bypassing = Logic(name: 'bypassing');
    final bypassDone = Logic(name: 'bypassDone');
    final bypassData = Logic(name: 'bypassData', width: xlen);
    final fillIdx = Logic(name: 'fillIdx', width: idxBits == 0 ? 1 : idxBits);
    final fillTag = Logic(name: 'fillTag', width: lineTagBits);
    final fillBase = Logic(name: 'fillBase', width: xlen);
    final fillWord = Logic(
      name: 'fillWord',
      width: (offBits == 0 ? 1 : offBits) + 1,
    );
    final storeIdx = Logic(name: 'storeIdx', width: idxBits == 0 ? 1 : idxBits);
    final storeInv = Logic(name: 'storeInv');

    final addrQ = Logic(name: 'addrQ', width: xlen);
    // Also block on the completion pulses (storeDone / bypassDone / fillSettle):
    // the pipeline holds its request one cycle past `done`, so without this the
    // FSM would re-issue the SAME op the cycle it finishes. A back-to-back
    // request like that deadlocks the DRAM CDC bridge (which needs cyc to drop
    // between transactions), the on-hardware hang the instant-memory unit test
    // could not surface.
    final blockHit =
        (filling |
                fillSettle |
                storing |
                bypassing |
                storeDone |
                bypassDone |
                faultDone |
                drain |
                flush)
            .named('blockHit');

    // Only DRAM (>= cacheableBase) is cacheable, everything else bypasses.
    Logic cacheableOf(Logic a) => a.gte(Const(cacheableBase, width: xlen));

    // Loads. A store never uses the hit/fill path (no write-allocate).
    final loadEn = (reqValid & ~reqWrite).named('loadEn');
    final ansLoad = (loadEn & reqAddr.eq(addrQ)).named('ansLoad');
    final cacheableQ = cacheableOf(addrQ).named('cacheableQ');
    final loadHit = (ansLoad & cacheableQ & committedHitOf(addrQ) & ~blockHit)
        .named('loadHit');
    final loadMiss = (ansLoad & cacheableQ & ~committedHitOf(addrQ) & ~blockHit)
        .named('loadMiss');
    // Uncacheable load: pass straight through to memory, do not allocate.
    final loadBypass = (ansLoad & ~cacheableQ & ~blockHit).named('loadBypass');
    // A store is taken from the COMBINATIONAL request, with no counterpart to
    // the load's `reqAddr.eq(addrQ)` stability guard. That asymmetry is
    // deliberate. A load needs the extra cycle because the data RAM read has one
    // cycle of latency and the fill path works off `addrQ`, so the address has to
    // be one cycle old for the RAM output to belong to it. A store reads nothing
    // and only samples the request into `memAddrR`/`memWdataR`/`memSizeR` on the
    // cycle it starts. The requester drives all of those from registers that
    // change on the same edge as `req_write`, so the sampled cycle never carries
    // a half-updated address or a stale data word.
    final storeReq = (reqValid & reqWrite).named('storeReq');

    final fillLineBase =
        addrQ &
        ~Const((BigInt.one << (byteBits + offBits)) - BigInt.one, width: xlen);

    final memEnR = Logic(name: 'memEnR');
    final memWeR = Logic(name: 'memWeR');
    final memAddrR = Logic(name: 'memAddrR', width: xlen);
    final memWdataR = Logic(name: 'memWdataR', width: xlen);
    final memSizeR = Logic(name: 'memSizeR', width: 3);
    memEn <= memEnR;
    memWe <= memWeR;
    memAddr <= memAddrR;
    memWdata <= memWdataR;
    memSize <= memSizeR;

    // The data path expects the addressed sub-word in lane 0: the MMU dport
    // right-shifts an aligned bus read by (byteOffset*8) so `lw`/`lbu` land in
    // lane 0 (the ifetch path stays raw, the fetch unit extracts itself). The
    // cache holds the RAW aligned line word, so a hit must apply the same shift.
    // A bypass read used the EXACT address, so the MMU already shifted it, do not
    // shift again.
    final rdShift = byteBits == 0
        ? Const(0, width: 1)
        : [addrQ.slice(byteBits - 1, 0), Const(0, width: 3)].swizzle();
    respData <= mux(bypassDone, bypassData, dataRam.readData(0) >> rdShift);
    respValid <= (loadHit | storeDone | bypassDone);
    respFault <= faultDone;
    respFaultIsAccess <= faultDone & ~faultIsPage;
    miss <= loadMiss;
    busy <= (filling | storing | bypassing | drain);

    final fillWrEn = (filling & memDone & memValid & ~flush & ~reset).named(
      'fillWrEn',
    );
    final Logic fillEntry;
    if (offBits == 0) {
      fillEntry = fillIdx;
    } else if (idxBits == 0) {
      fillEntry = fillWord.slice(offBits - 1, 0);
    } else {
      fillEntry = [fillIdx, fillWord.slice(offBits - 1, 0)].swizzle();
    }
    dataRam.input('wr_en').srcConnection! <= fillWrEn;
    dataRam.input('wr_addr').srcConnection! <= fillEntry;
    dataRam.input('wr_data').srcConnection! <= memRdata;

    final lastWord = Const(lineWords - 1, width: fillWord.width);
    tagRam.input('wr_en').srcConnection! <= fillWrEn & fillWord.eq(lastWord);
    tagRam.input('wr_addr').srcConnection! <= fillIdx;
    tagRam.input('wr_data').srcConnection! <= fillTag;

    Sequential(clk, [
      addrQ < reqAddr,
      If(
        reset,
        then: [
          ...List.generate(numLines, (i) => lineValid[i] < 0),
          filling < 0,
          fillSettle < 0,
          storing < 0,
          storeDone < 0,
          bypassing < 0,
          bypassDone < 0,
          faultDone < 0,
          faultIsPage < 0,
          memEnR < 0,
          memWeR < 0,
          drain < 0,
        ],
        orElse: [
          // Invalidate every line even while an uncached read or write-through
          // store is finishing. Those operations cannot be cancelled safely:
          // their side effects may already have happened. Keep their state and
          // deliver their success/fault response, including during a held flush.
          If(
            flush,
            then: [...List.generate(numLines, (i) => lineValid[i] < 0)],
          ),
          // Refills can be abandoned, but drain their outstanding beat before
          // starting another operation. blockHit prevents new requests and
          // cached hits while flush is asserted or a stale beat is draining.
          If(
            flush & ~storing & ~bypassing,
            then: [
              filling < 0,
              fillSettle < 0,
              storing < 0,
              storeDone < 0,
              bypassing < 0,
              bypassDone < 0,
              faultDone < 0,
              memEnR < 0,
              memWeR < 0,
              // Only an abandoned refill can enter drain; an in-flight store
              // or bypass read follows its normal completion path below.
              drain < (filling | drain) & ~memDone,
            ],
            orElse: [
              fillSettle < 0,
              storeDone < 0,
              bypassDone < 0,
              faultDone < 0,
              If(
                drain,
                then: [
                  // Waiting out the abandoned op; discard its completion
                  // (filling is 0 so nothing is written) and release.
                  If(memDone, then: [drain < 0]),
                ],
                orElse: [
                  If(
                    filling,
                    then: [
                      If(
                        memDone & memValid,
                        then: [
                          If(
                            fillWord.eq(lastWord),
                            then: [
                              memEnR < 0,
                              filling < 0,
                              fillSettle < 1,
                              ...List.generate(
                                numLines,
                                (l) =>
                                    If(fillIdx.eq(l), then: [lineValid[l] < 1]),
                              ),
                            ],
                            orElse: [
                              fillWord < fillWord + 1,
                              memAddrR <
                                  (fillBase +
                                      ((fillWord + 1).zeroExtend(xlen) *
                                          Const(wordBytes, width: xlen))),
                            ],
                          ),
                        ],
                      ),
                      // done AND not valid: the MMU faulted this refill. End the
                      // fill (never mark the line valid, the data is garbage) and
                      // pulse faultDone so the core takes a load page fault.
                      // Without this arm `filling` stays asserted forever and the
                      // core hangs on the load instead of trapping.
                      If(
                        memDone & ~memValid,
                        then: [
                          memEnR < 0,
                          filling < 0,
                          faultDone < 1,
                          faultIsPage < memFault,
                        ],
                      ),
                    ],
                    orElse: [
                      If(
                        storing,
                        then: [
                          // Write-through in flight: wait for the memory ack, then drop
                          // the resident line if the store landed on it.
                          //
                          // Gated on memValid too. This used to complete on
                          // memDone ALONE, so a FAULTING store reported success
                          // and the store page fault was silently swallowed: the
                          // core carried on as if the write had landed.
                          If(
                            memDone & memValid,
                            then: [
                              memEnR < 0,
                              memWeR < 0,
                              storing < 0,
                              storeDone < 1,
                              ...List.generate(
                                numLines,
                                (l) => If(
                                  storeInv & storeIdx.eq(l),
                                  then: [lineValid[l] < 0],
                                ),
                              ),
                            ],
                          ),
                          // Faulting store: end it, leave the resident line
                          // alone (nothing was written), and report the fault.
                          If(
                            memDone & ~memValid,
                            then: [
                              memEnR < 0,
                              memWeR < 0,
                              storing < 0,
                              faultDone < 1,
                              faultIsPage < memFault,
                            ],
                          ),
                        ],
                        orElse: [
                          If(
                            bypassing,
                            then: [
                              // Uncached read in flight: return the word, cache untouched.
                              If(
                                memDone & memValid,
                                then: [
                                  memEnR < 0,
                                  bypassing < 0,
                                  bypassDone < 1,
                                  bypassData < memRdata,
                                ],
                              ),
                              // Faulting uncached load: end it and report, else
                              // `bypassing` stalls forever exactly like a fill.
                              If(
                                memDone & ~memValid,
                                then: [
                                  memEnR < 0,
                                  bypassing < 0,
                                  faultDone < 1,
                                  faultIsPage < memFault,
                                ],
                              ),
                            ],
                            orElse: [
                              // Idle. Store (write-through) has priority, then a cacheable
                              // load miss (fill), then an uncacheable load (bypass). The
                              // core presents at most one of these per cycle. Gate the
                              // store start on ~blockHit too, so the completion-cycle
                              // block above also stops a store from re-issuing.
                              If(
                                storeReq & ~blockHit,
                                then: [
                                  storing < 1,
                                  memEnR < 1,
                                  memWeR < 1,
                                  memAddrR < reqAddr,
                                  memWdataR < reqData,
                                  memSizeR < reqSize,
                                  storeIdx < idxOf(reqAddr),
                                  // ALWAYS drop the line at the stored index.
                                  //
                                  // This used to be
                                  // `addrHitOf(reqAddr) & cacheableOf(reqAddr)`,
                                  // which only dropped the line when the STORED
                                  // virtual address matched the tag. The cache
                                  // is virtually tagged, so a second virtual
                                  // address for the same physical page has a
                                  // DIFFERENT tag: the store left that line
                                  // resident and a later load through it
                                  // returned the value from before the store.
                                  // RVWMO makes a hart see its own store to the
                                  // same PHYSICAL address, so that was a memory
                                  // model violation with no fence software is
                                  // obliged to insert. Linux hits it through
                                  // the linear map, vmemmap, vmalloc/vmap,
                                  // kmap and DMA buffers, all of which name one
                                  // frame by two virtual addresses.
                                  //
                                  // The index is safe to use for this because
                                  // it is cut from bits BELOW the page offset
                                  // (see the tagLo check in the constructor):
                                  // every synonym of a physical word shares
                                  // those bits, so every alias of the stored
                                  // word is on this one line. The tag compare
                                  // added nothing but the hole, so dropping it
                                  // also removes a comparator from the store
                                  // path.
                                  //
                                  // Uncacheable stores drop the line too. The
                                  // cacheable test reads the VIRTUAL address,
                                  // so one physical word can be cacheable
                                  // through a high virtual address and
                                  // uncacheable through a low one, and gating
                                  // on it reopened the same hole.
                                  storeInv < Const(1),
                                ],
                                orElse: [
                                  If(
                                    loadMiss,
                                    then: [
                                      filling < 1,
                                      // A fault after an earlier refill beat
                                      // must not leave the victim's old tag
                                      // pointing at partially overwritten data.
                                      ...List.generate(
                                        numLines,
                                        (l) => If(
                                          idxOf(addrQ).eq(l),
                                          then: [lineValid[l] < 0],
                                        ),
                                      ),
                                      memEnR < 1,
                                      memWeR < 0,
                                      // Read a FULL word per fill beat. wordBytes
                                      // is 8 on RV64, so the size must be 3 (8
                                      // bytes), not a hardcoded 2 (4 bytes) which
                                      // left the upper half of every 64-bit line
                                      // word undefined.
                                      memSizeR <
                                          Const(
                                            wordBytes.bitLength - 1,
                                            width: 3,
                                          ),
                                      fillIdx < idxOf(addrQ),
                                      fillTag < fullTagOf(addrQ),
                                      fillBase < fillLineBase,
                                      fillWord < 0,
                                      memAddrR < fillLineBase,
                                    ],
                                    orElse: [
                                      If(
                                        loadBypass,
                                        then: [
                                          bypassing < 1,
                                          memEnR < 1,
                                          memWeR < 0,
                                          // Carry the REQUESTED size, as the
                                          // store and fill paths do. A
                                          // hardcoded 2 (4 bytes) told the bus
                                          // that an 8-byte `ld` from an MMIO
                                          // register, from boot SRAM or from
                                          // flash wanted only 4 bytes, because
                                          // the MMU makes the Wishbone SEL mask
                                          // from this size.
                                          memSizeR < reqSize,
                                          memAddrR < addrQ,
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}
