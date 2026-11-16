import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../peripherals/register_file.dart';
import '../soc/target.dart';
import 'cache_config.dart';

/// Largest L1 tag store, in bits, that stays in flops on an iCE40. One iCE40
/// block RAM holds 4096 bits. The iCE40 has no LUT RAM.
const harborL1TagFlopBits = 4096;

/// Most lines of an L1 tag store in LUT RAM on ECP5 and Xilinx targets. Up to
/// this depth the LUT RAM read is one level of RAM and a small mux, and it
/// costs fewer resources than a column of block RAMs. A deeper store uses
/// block RAM.
const harborL1TagLutRamLines = 64;

/// Width of the `mem_len` output of an L1 cache. It is the same as
/// LEN width of a Harbor memory waist.
const harborL1MemLenWidth = 8;

/// Stops the simulation when [bad] is high on a rising [clk] edge out of
/// reset. The generated RTL does not use [bad].
void _l1CheckInSim(Logic clk, Logic reset, Logic bad, String what) {
  clk.glitch.listen((args) {
    if (LogicValue.isPosedge(
          args.previousValue,
          args.newValue,
          ignoreInvalid: true,
        ) &&
        reset.value == LogicValue.zero &&
        bad.value == LogicValue.one) {
      Simulator.throwException(
        Exception('L1 cache: $what'),
        StackTrace.current,
      );
    }
  });
}

/// Line tag store of an L1 cache. Its read latency is 1 on every target.
///
/// - ECP5 and Xilinx: LUT RAM up to [harborL1TagLutRamLines] lines, block RAM
///   above. The RAM has a `ram_style` attribute, so synthesis keeps it in LUT
///   RAM. In a 4 KiB, 64-byte-line D-cache bench on an ECP5 85F this uses
///   about 500 LUT4 more than two EBRs and is about 8 MHz faster. On an
///   xc7s50 it frees one RAMB36 and costs about 6 to 21 MHz, the most with
///   snoop at 4 KiB and 64-byte lines.
/// - iCE40: flops up to [harborL1TagFlopBits] bits, block RAM above.
/// - No target: flops.
///
/// A read of the line that is written in the same cycle gives the new tag.
class _L1TagStore {
  final List<Logic> rdAddr;
  final Logic wrEn;
  final Logic wrAddr;
  final Logic wrData;
  final List<Logic> _data = [];

  _L1TagStore(
    BridgeModule parent, {
    required Logic clk,
    required Logic reset,
    required int lines,
    required int width,
    required int readPorts,
    required HarborDeviceTarget? target,
    required String name,
  }) : rdAddr = [
         for (var r = 0; r < readPorts; r++)
           Logic(
             name: '${name}_rd${r}_addr',
             width: (lines - 1).bitLength.clamp(1, 32),
           ),
       ],
       wrEn = Logic(name: '${name}_wr_en'),
       wrAddr = Logic(
         name: '${name}_wr_addr',
         width: (lines - 1).bitLength.clamp(1, 32),
       ),
       wrData = Logic(name: '${name}_wr_data', width: width) {
    final fpga = target is HarborFpgaTarget ? target : null;
    final lutRam =
        fpga != null &&
        fpga.vendor != HarborFpgaVendor.ice40 &&
        lines <= harborL1TagLutRamLines;
    if (lutRam) {
      final ram = _L1ValidRam(
        clk,
        width: width,
        depth: lines,
        wrEn: wrEn & ~reset,
        wrAddr: wrAddr,
        wrData: wrData,
        rdAddr: rdAddr,
        definitionPrefix: 'HarborL1TagRam',
        name: '${name}_lutram',
      );
      for (var r = 0; r < readPorts; r++) {
        final collide = wrEn & ~reset & wrAddr.eq(rdAddr[r]);
        _data.add(flop(clk, mux(collide, wrData, ram.rdData(r))));
      }
      return;
    }
    final ramTarget =
        fpga != null &&
            (fpga.vendor != HarborFpgaVendor.ice40 ||
                lines * width > harborL1TagFlopBits)
        ? target
        : null;
    final latency = HarborRegisterFile.blockRamReadLatency(ramTarget) ?? 1;
    final ram = HarborRegisterFile(
      useXilinxSdp72: true,
      numEntries: lines,
      dataWidth: width,
      numReadPorts: readPorts,
      reservedZero: false,
      target: ramTarget,
      forceReadLatency: latency,
      name: name,
    );
    parent.addSubModule(ram);
    ram.input('clk').srcConnection! <= clk;
    ram.input('reset').srcConnection! <= reset;
    for (var r = 0; r < readPorts; r++) {
      ram.input('rd${r}_addr').srcConnection! <= rdAddr[r];
      // The iCE40 block RAM reads in 0 cycles, so one flop follows it.
      _data.add(latency == 1 ? ram.readData(r) : flop(clk, ram.readData(r)));
    }
    ram.input('wr_en').srcConnection! <= wrEn;
    ram.input('wr_addr').srcConnection! <= wrAddr;
    ram.input('wr_data').srcConnection! <= wrData;
  }

  /// Tag of read port [r], one cycle after its address.
  Logic read(int r) => _data[r];
}

/// RAM with one write port and asynchronous read ports, for valid bits and
/// small tag stores. Synthesis maps it to LUT RAM, so it needs no per-line
/// enable.
/// Cells start at X, as in SystemVerilog. The simulation model samples the
/// write port on the rising clock edge, before the flops change.
class _L1ValidRam extends Module with SystemVerilog {
  final int width;
  final int depth;
  final int addrWidth;
  final int readPorts;

  Logic rdData(int r) => output('rd${r}_data');

  _L1ValidRam(
    Logic clk, {
    required this.width,
    required this.depth,
    required Logic wrEn,
    required Logic wrAddr,
    required Logic wrData,
    required List<Logic> rdAddr,
    String definitionPrefix = 'HarborL1ValidRam',
    super.name = 'valid_ram',
  }) : addrWidth = (depth - 1).bitLength.clamp(1, 32),
       readPorts = rdAddr.length,
       super(
         definitionName:
             '${definitionPrefix}_w${width}d${depth}r${rdAddr.length}',
         reserveDefinitionName: true,
       ) {
    clk = addInput('clk', clk);
    wrEn = addInput('wr_en', wrEn);
    wrAddr = addInput('wr_addr', wrAddr, width: addrWidth);
    wrData = addInput('wr_data', wrData, width: width);
    final unknown = LogicValue.filled(width, LogicValue.x);
    final cells = List<LogicValue>.filled(depth, unknown);
    final reads = <void Function()>[];
    for (var r = 0; r < readPorts; r++) {
      final addr = addInput('rd${r}_addr', rdAddr[r], width: addrWidth);
      final out = Logic(name: 'rd${r}_out', width: width);
      addOutput('rd${r}_data', width: width) <= out;
      void read() {
        final a = addr.value;
        out.put(a.isValid && a.toInt() < depth ? cells[a.toInt()] : unknown);
      }

      read();
      addr.glitch.listen((_) => read());
      reads.add(read);
    }
    clk.glitch.listen((event) {
      if (event.previousValue != LogicValue.zero ||
          event.newValue != LogicValue.one) {
        return;
      }
      final we = wrEn.value;
      if (we.isValid && we.toBool()) {
        final wa = wrAddr.value;
        if (!wa.isValid) throw StateError('$name: write address not valid');
        if (wa.toInt() < depth) cells[wa.toInt()] = wrData.value;
        unawaited(
          Simulator.clkStable.first.then((_) {
            for (final read in reads) {
              read();
            }
          }),
        );
      }
    });
  }

  @override
  String? definitionVerilog(String definitionType) {
    final a = addrWidth - 1;
    final w = width - 1;
    return '''
module $definitionType (
  input logic clk,
  input logic wr_en,
  input logic [$a:0] wr_addr,
  input logic [$w:0] wr_data,
${List.generate(readPorts, (r) => '  input logic [$a:0] rd${r}_addr,\n  output logic [$w:0] rd${r}_data').join(',\n')}
);
  (* ram_style = "distributed", syn_ramstyle = "distributed" *)
  logic [$w:0] mem [0:${depth - 1}];
  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
  end
${List.generate(readPorts, (r) => '  assign rd${r}_data = mem[rd${r}_addr];').join('\n')}
endmodule''';
  }
}

/// Valid bits of an L1 cache. A RAM word holds the bits of 8 lines.
///
/// A reset or a flush starts a sweep that writes zero to each word, one word
/// per cycle. The sweep ends [sweepCycles] cycles after the last reset or
/// flush cycle. While [sweeping] is high the cache must answer no lookup and
/// must not set a valid bit.
///
/// The update port sets or clears the bit of one line. The update goes into
/// flops ([pending]) and writes the next cycle, with a read, modify and write
/// of its word, so the cache must answer no lookup while [pending] is high.
/// A new set replaces a pending update, so the cache sends a new update while
/// one is pending only to set the line of the pending one. A reset, a flush
/// or a sweep drops it.
///
/// The clear port clears the bit of one line in the same cycle and has
/// priority. Its index must be the index of lookup `clearLookup` one cycle
/// before, so the clear reuses that read port. A pending update to a different word waits for it. A pending
/// update to the same word writes together with the clear, and the clear
/// wins on the same bit.
class _L1ValidBits {
  /// High while the sweep runs.
  final Logic sweeping = Logic(name: 'validSweeping');

  /// High while an update waits to write.
  final Logic pending = Logic(name: 'validPending');

  /// Valid bit of the line at each lookup index, in the same cycle.
  final List<Logic> valid = [];

  /// Number of cycles to clear all lines.
  final int sweepCycles;

  _L1ValidBits._(this.sweepCycles);

  factory _L1ValidBits({
    required Logic clk,
    required Logic reset,
    required Logic flush,
    required int lines,
    required List<Logic> lookups,
    required Logic updateEn,
    required Logic updateIdx,
    required Logic updateValue,
    Logic? clearEn,
    Logic? clearIdx,
    int? clearLookup,
  }) {
    final idxBits = (lines - 1).bitLength;
    final bitBits = idxBits < 3 ? idxBits : 3;
    final width = 1 << bitBits;
    final depth = (lines + width - 1) ~/ width;
    final bits = _L1ValidBits._(depth);
    final addrWidth = (depth - 1).bitLength.clamp(1, 32);

    Logic wordOf(Logic idx) => idxBits == bitBits
        ? Const(0, width: addrWidth)
        : idx.slice(idxBits - 1, bitBits);
    Logic bitOf(Logic idx, Logic word) =>
        bitBits == 0 ? word[0] : word[idx.slice(bitBits - 1, 0)];
    Logic maskOf(Logic idx) => bitBits == 0
        ? Const(1)
        : (Const(1, width: width) << idx.slice(bitBits - 1, 0));

    final clear = (reset | flush).named('validClear');
    final updEnQ = bits.pending;
    final updIdxQ = Logic(name: 'validUpdIdxQ', width: updateIdx.width);
    final updValueQ = Logic(name: 'validUpdValueQ');
    final sweepIdx = Logic(name: 'validSweepIdx', width: addrWidth);
    final wrEn = Logic(name: 'validWrEn');
    final wrAddr = Logic(name: 'validWrAddr', width: addrWidth);
    final wrData = Logic(name: 'validWrData', width: width);
    final clrIdx = clearIdx ?? Const(0, width: updateIdx.width);
    final clrEn = clearEn ?? Const(0);
    final ram = _L1ValidRam(
      clk,
      width: width,
      depth: depth,
      wrEn: wrEn,
      wrAddr: wrAddr,
      wrData: wrData,
      rdAddr: [...lookups.map(wordOf), wordOf(updIdxQ)],
    );
    for (var i = 0; i < lookups.length; i++) {
      bits.valid.add(bitOf(lookups[i], ram.rdData(i)));
    }

    final old = ram.rdData(lookups.length);
    final updMask = maskOf(updIdxQ);
    final updWord = mux(updValueQ, old | updMask, old & ~updMask);
    final Logic clrWrite;
    final Logic updDone;
    if (clearEn == null) {
      clrWrite = Const(0);
      updDone = updEnQ;
    } else {
      final sameWord = wordOf(clrIdx).eq(wordOf(updIdxQ));
      // The clear reads its word through lookup [clearLookup] one cycle
      // early, with the write of that cycle forwarded.
      final k = clearLookup!;
      final clrOld = Logic(name: 'validClrOld', width: width);
      Sequential(clk, [
        clrOld <
            mux(wrEn & wrAddr.eq(wordOf(lookups[k])), wrData, ram.rdData(k)),
      ]);
      final clrBase = mux(updEnQ & sameWord, updWord, clrOld);
      clrWrite = clrEn;
      updDone = (updEnQ & (~clrEn | sameWord)).named('validUpdDone');
      final clrWord = clrBase & ~maskOf(clrIdx);
      wrData <=
          mux(
            bits.sweeping,
            Const(0, width: width),
            mux(clrEn, clrWord, updWord),
          );
    }
    wrEn <= ~clear & (bits.sweeping | clrWrite | updEnQ);
    wrAddr <=
        mux(
          bits.sweeping,
          sweepIdx,
          clearEn == null
              ? wordOf(updIdxQ)
              : mux(clrEn, wordOf(clrIdx), wordOf(updIdxQ)),
        );
    if (clearEn == null) {
      wrData <= mux(bits.sweeping, Const(0, width: width), updWord);
    }

    Sequential(clk, [
      if (clearEn == null) ...[
        updIdxQ < updateIdx,
        updValueQ < updateValue,
      ] else
        If(
          ~(updEnQ & ~updDone & ~bits.sweeping & ~updateValue),
          then: [updIdxQ < updateIdx, updValueQ < updateValue],
        ),
      If(
        clear,
        then: [bits.sweeping < 1, sweepIdx < 0, updEnQ < 0],
        orElse: [
          updEnQ < updateEn | (updEnQ & ~updDone & ~bits.sweeping),
          If(
            bits.sweeping,
            then: [
              sweepIdx < sweepIdx + 1,
              If(sweepIdx.eq(depth - 1), then: [bits.sweeping < 0]),
            ],
          ),
        ],
      ),
    ]);
    return bits;
  }
}

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

  /// Stops the simulation when `mem_last` does not match the burst length.
  /// The cache treats such a burst as an error in all modes.
  final bool checkMemLast;

  /// Cycles after a reset or flush during which the cache clears its valid
  /// bits and answers no lookup.
  late final int sweepCycles;

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

  /// Performance events for one cycle.
  ///
  /// [perfAccess] is how many lookups the cache answered this cycle, so it is
  /// 2 bits wide on a dual-port cache where both ports can hit together, and 1
  /// bit otherwise. [perfMiss] counts the line fills those lookups caused.
  ///
  /// [miss] is not a count: it stays high for the whole miss, so it measures
  /// stall cycles instead.
  Logic get perfAccess => output('perf_access');
  Logic get perfMiss => output('perf_miss');

  /// Second lookup port (present only when [dualPort]).
  Logic get reqAddr1 => input('req_addr1');
  Logic get reqValid1 => input('req_valid1');
  Logic get respData1 => output('resp_data1');
  Logic get respValid1 => output('resp_valid1');

  /// Whole-cache flush (fence.i / satp change), since the cache is virtually
  /// addressed. It clears every valid bit in [sweepCycles] cycles. The cache
  /// answers no lookup until the clear is done.
  Logic get flush => input('flush');

  /// Refill request. A miss sends one INCR burst from the line base:
  /// [memLen] is the beat count minus one. [memEn] stays high from the start
  /// of the request to the beat with [memLast].
  Logic get memEn => output('mem_en');
  Logic get memAddr => output('mem_addr');
  Logic get memLen => output('mem_len');

  /// Refill response, one [memDone] pulse per beat. [memValid] low is an
  /// error on that beat. The memory must give exactly `mem_len + 1` beats,
  /// also after an error, and set [memLast] on the last one.
  Logic get memDone => input('mem_done');
  Logic get memValid => input('mem_valid');
  Logic get memLast => input('mem_last');
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
    this.checkMemLast = true,
    // Significant low bits of [reqAddr]: the tag store and compares are sized to
    // this instead of [xlen], so a cache over a narrow map does not pay for a
    // full 64-bit tag. Null = xlen. See the note on tag width below.
    int? reqAddrBits,
    // FPGA/ASIC target for the data block RAM and the tag store (see
    // [_L1TagStore]). Null (simulation / std-cell) uses flops at the same read
    // latency.
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
    // Both ports can hit in the same cycle, so the access event is a count,
    // not a pulse.
    addOutput('perf_access', width: dualPort ? 2 : 1);
    addOutput('perf_miss');
    if (dualPort) {
      createPort('req_addr1', PortDirection.input, width: xlen);
      createPort('req_valid1', PortDirection.input);
      addOutput('resp_data1', width: xlen);
      addOutput('resp_valid1');
    }
    addOutput('mem_en');
    addOutput('mem_addr', width: xlen);
    addOutput('mem_len', width: harborL1MemLenWidth);
    createPort('mem_done', PortDirection.input);
    createPort('mem_valid', PortDirection.input);
    createPort('mem_last', PortDirection.input);
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
    if (lineWords > 1 << harborL1MemLenWidth) {
      throw ArgumentError(
        'lineSize (${config.lineSize}B) must not be more than '
        '${1 << harborL1MemLenWidth} words, the longest burst.',
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
        ctxBits == 0 ? tagOf(addr) : [reqCtx, tagOf(addr)].concat();
    // Combined {line, word} index into the flat data RAM.
    Logic dataEntryOf(Logic addr) => (offBits + idxBits) == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits);

    final tagRam = _L1TagStore(
      this,
      clk: clk,
      reset: reset,
      lines: numLines,
      width: lineTagBits,
      readPorts: dualPort ? 2 : 1,
      target: target,
      name: 'l1i_tags',
    );
    tagRam.rdAddr[0] <= idxOf(reqAddr);
    if (dualPort) {
      tagRam.rdAddr[1] <= idxOf(reqAddr1);
    }

    // Per-line DATA in a block RAM (one read port, one write port for fills).
    // The cache expects read latency 1. The iCE40 block RAM reads at latency
    // 0, so one flop after it gives the same timing.
    final ramLatency = HarborRegisterFile.blockRamReadLatency(target) ?? 1;
    final dataRam = HarborRegisterFile(
      useXilinxSdp72: true,
      numEntries: numLines * lineWords,
      dataWidth: xlen,
      numReadPorts: dualPort ? 2 : 1,
      numWritePorts: 1,
      reservedZero: false,
      target: target,
      forceReadLatency: ramLatency,
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
    final fillWord = Logic(
      name: 'fillWord',
      width: (offBits == 0 ? 1 : offBits) + 1,
    );
    // An earlier beat of this refill had an error.
    final fillErr = Logic(name: 'fillErr');
    final fillErrPage = Logic(name: 'fillErrPage');

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

    final validUpdateEn = Logic(name: 'validUpdateEn');
    final validUpdateIdx = Logic(name: 'validUpdateIdx', width: fillIdx.width);
    final validUpdateValue = Logic(name: 'validUpdateValue');
    final lineValid = _L1ValidBits(
      clk: clk,
      reset: reset,
      flush: flush,
      lines: numLines,
      lookups: [idxOf(addrQ), if (dualPort) idxOf(addrQ1!)],
      updateEn: validUpdateEn,
      updateIdx: validUpdateIdx,
      updateValue: validUpdateValue,
    );
    sweepCycles = lineValid.sweepCycles;

    final blockHit = (filling | fillSettle | lineValid.sweeping).named(
      'blockHit',
    );

    // The valid bit and the tag of the line both belong to the address of the
    // last cycle.
    Logic committedHit(Logic a, [int port = 0]) =>
        lineValid.valid[port] & tagRam.read(port).eq(fullTagOf(a));

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
    memLen <= Const(lineWords - 1, width: harborL1MemLenWidth);

    Logic ramRead(int r) =>
        ramLatency == 1 ? dataRam.readData(r) : flop(clk, dataRam.readData(r));
    respData <= ramRead(0);
    respValid <= hit;
    // A faulting fetch presents as done (in core.dart: done = respValid |
    // respFault) with valid low, so the FetchUnit raises the instruction page
    // fault instead of retrying. Gated to the held request so a stale latch never
    // faults an unrelated fetch.
    respFault <= faultHeld;
    respFaultIsAccess <= faultHeld & ~faultIsPage;
    miss <= miss0;
    // A served lookup gives one hit pulse, so hits count accesses. Two ports
    // that hit together are two accesses, which a single pulse would lose.
    // perfMiss pulses on the cycle a fill starts, so it counts each miss once,
    // also while a flush or a drain holds the fill off.
    perfAccess <=
        (dualPort
            ? (hit.zeroExtend(2) + hit1.zeroExtend(2)).named('perfAccessCount')
            : hit);
    final fillStart = (wantFill & ~drain & ~flush & ~reset).named('fillStart');
    perfMiss <= fillStart;
    if (dualPort) {
      respData1 <= ramRead(1);
      respValid1 <= hit1;
    }

    // Data block-RAM write port: one fill word per beat.
    final fillWrEn = (filling & memDone & memValid & ~flush & ~reset).named(
      'fillWrEn',
    );
    final Logic fillEntry;
    if (offBits == 0) {
      fillEntry = fillIdx;
    } else if (idxBits == 0) {
      fillEntry = fillWord.slice(offBits - 1, 0);
    } else {
      fillEntry = [fillIdx, fillWord.slice(offBits - 1, 0)].concat();
    }
    dataRam.input('wr_en').srcConnection! <= fillWrEn;
    dataRam.input('wr_addr').srcConnection! <= fillEntry;
    dataRam.input('wr_data').srcConnection! <= memRdata;

    final lastWord = Const(lineWords - 1, width: fillWord.width);
    // A beat with an error, or a mem_last that does not match the burst
    // length, early or late. Either one fails the refill.
    final fillBad = (~memValid | memLast.neq(fillWord.eq(lastWord))).named(
      'fillBad',
    );
    // A refill commits only on a good last beat with no earlier error.
    final fillCommit = (fillWrEn & memLast & ~fillBad & ~fillErr).named(
      'fillCommit',
    );
    if (checkMemLast) {
      _l1CheckInSim(
        clk,
        reset,
        filling & memDone & memLast.neq(fillWord.eq(lastWord)),
        'mem_last does not match the burst length',
      );
    }
    tagRam.wrEn <= fillCommit;
    tagRam.wrAddr <= fillIdx;
    tagRam.wrData <= fillTag;

    // A fill sets its line valid when it commits. A new fill clears the
    // victim line first.
    final fillValidSet = fillCommit.named('fillValidSet');
    validUpdateEn <= fillValidSet | fillStart;
    validUpdateIdx <= mux(fillValidSet, fillIdx, idxOf(fillAddr));
    validUpdateValue <= fillValidSet;

    Sequential(clk, [
      addrQ < reqAddr,
      if (dualPort) addrQ1! < reqAddr1,
      If(
        reset,
        then: [
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
              drain < (filling | drain) & ~(memDone & memLast),
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
                  If(memDone & memLast, then: [drain < 0]),
                ],
                orElse: [
                  If(
                    filling,
                    then: [
                      If(
                        memDone,
                        then: [
                          fillWord < fillWord + 1,
                          If(
                            fillBad & ~fillErr,
                            then: [
                              fillErr < 1,
                              fillErrPage < ~memValid & memFault,
                            ],
                          ),
                          // An error on any beat drops the line and faults
                          // the fetch after the last beat.
                          If(
                            memLast,
                            then: [
                              memEnR < 0,
                              filling < 0,
                              If(
                                fillErr | fillBad,
                                then: [
                                  faultResp < 1,
                                  faultIsPage <
                                      mux(
                                        fillErr,
                                        fillErrPage,
                                        ~memValid & memFault,
                                      ),
                                ],
                                orElse: [fillSettle < 1],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                    orElse: [
                      If(
                        wantFill,
                        then: [
                          // Refill overwrites data before committing its tag.
                          // The victim line is dropped now (validUpdateEn), so
                          // a later fault cannot expose partial replacement
                          // data under the old valid tag.
                          filling < 1,
                          fillIdx < idxOf(fillAddr),
                          fillTag < fullTagOf(fillAddr),
                          fillWord < 0,
                          fillErr < 0,
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
/// A load miss fills its line with one INCR burst from the line base, then
/// the held load hits. Stores go to memory and are not posted: a store
/// completes when memory acknowledges it. A store to a resident line also
/// writes its bytes into the line, which stays valid. A store miss does not
/// allocate a line.
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
  /// so no permission check runs on it. A line that one privilege mode was
  /// allowed to fill therefore stays readable by a mode the page table
  /// forbids: user code read
  /// a supervisor-only page out of the cache, and a supervisor load with
  /// sstatus.SUM clear read a user page out of it.
  ///
  /// Each line records the context that filled it, and a load hit must match the
  /// context of the access. An access from a different context misses and goes
  /// to the MMU, which checks the PTE and faults if the access is not allowed.
  /// The core supplies the privilege mode and the SUM bit here (see [reqCtx]).
  ///
  /// Stores are unaffected: they are write-through, so every store already
  /// reaches the MMU and is checked. The store hit compares the address tag
  /// only, so a store never leaves another context holding stale data.
  final int ctxBits;

  /// Stops the simulation when `mem_last` does not match the burst length.
  /// The cache treats such a burst as an error in all modes.
  final bool checkMemLast;

  /// Adds the snoop port: [invalValid], [invalAddr], [invalHold],
  /// [invalBusy] and [fillLine]. It keeps the cache coherent with DMA writes
  /// to memory. Connect it to a [HarborDmaSnoop] or a [HarborDmaSnoopMerge]
  /// with their `connectCache`. It needs [physicalAddresses], and it costs a
  /// second read port on the tag store.
  ///
  /// A refill that a snoop kills still answers the held load, with the miss
  /// word it read, and the line stays invalid. The requester holds its
  /// request until it gets an answer, as for every other op.
  final bool snoop;

  /// Cycles after a reset or flush during which the cache clears its valid
  /// bits and answers no lookup.
  late final int sweepCycles;

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

  /// Performance event pulses, one cycle each, for cacheable traffic.
  ///
  /// [perfAccess] counts lookups the cache answered and [perfMiss] counts the
  /// line fills they caused. [miss] is not a count: it stays high for the whole
  /// miss, so it measures stall cycles instead.
  Logic get perfAccess => output('perf_access');
  Logic get perfMiss => output('perf_miss');

  /// Snoop invalidate, present only when [snoop] is set. A cycle with
  /// [invalValid] high drops the line that holds [invalAddr] if it is in the
  /// cache. The cache takes one in each cycle and has no ready.
  Logic get invalValid => input('inval_valid');
  Logic get invalAddr => input('inval_addr');

  /// High while [fillLine] is in a DMA write that is in flight. The cache
  /// takes it into a flop. A refill that is in flight in a cycle after
  /// [invalHold] was high does not make its line valid, because its read can
  /// come before the DMA write in memory.
  Logic get invalHold => input('inval_hold');

  /// High while an invalidate is in the cache and its line can still hit.
  /// The snoop holds a DMA completion until it is low.
  Logic get invalBusy => output('inval_busy');

  /// Line address of the refill. It is valid while a refill is in flight.
  Logic get fillLine => output('fill_line');

  /// Whole-cache flush. It clears every valid bit in [sweepCycles] cycles,
  /// and [busy] stays high until the clear is done.
  Logic get flush => input('flush');

  /// Memory request, for refills, write-through stores and uncached reads.
  /// A refill is one INCR burst from the line base with [memLen] set to the
  /// beat count minus one. A store or an uncached read is one beat, with
  /// [memLen] 0. [memEn] stays high from the start of the request to the beat
  /// with [memLast].
  Logic get memEn => output('mem_en');
  Logic get memWe => output('mem_we');
  Logic get memAddr => output('mem_addr');
  Logic get memLen => output('mem_len');
  Logic get memWdata => output('mem_wdata');
  Logic get memSize => output('mem_size');

  /// Memory response, one [memDone] pulse per beat. [memValid] low is an
  /// error on that beat. The memory must give exactly `mem_len + 1` beats,
  /// also after an error, and set [memLast] on the last one.
  Logic get memDone => input('mem_done');
  Logic get memValid => input('mem_valid');
  Logic get memLast => input('mem_last');
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
    this.checkMemLast = true,
    this.snoop = false,
    Logic? memFaultIn,
    // Significant low bits of [reqAddr]. See the note on tag width below.
    int? reqAddrBits,
    // FPGA/ASIC target for the data block RAM and the tag store (see
    // [_L1TagStore]). Null uses flops.
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
    if (snoop && !physicalAddresses) {
      throw ArgumentError('A snooping cache needs physicalAddresses: true.');
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
    if (snoop) {
      createPort('inval_valid', PortDirection.input);
      createPort('inval_addr', PortDirection.input, width: xlen);
      createPort('inval_hold', PortDirection.input);
      addOutput('inval_busy');
      addOutput('fill_line', width: xlen);
    }
    createPort('req_data', PortDirection.input, width: xlen);
    createPort('req_size', PortDirection.input, width: 3);
    createPort('flush', PortDirection.input);
    addOutput('resp_data', width: xlen);
    addOutput('resp_valid');
    addOutput('resp_fault');
    addOutput('resp_fault_is_access');
    addOutput('miss');
    addOutput('busy');
    addOutput('perf_access');
    addOutput('perf_miss');
    addOutput('mem_en');
    addOutput('mem_we');
    addOutput('mem_addr', width: xlen);
    addOutput('mem_len', width: harborL1MemLenWidth);
    addOutput('mem_wdata', width: xlen);
    addOutput('mem_size', width: 3);
    createPort('mem_done', PortDirection.input);
    createPort('mem_valid', PortDirection.input);
    createPort('mem_last', PortDirection.input);
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
    if (lineWords > 1 << harborL1MemLenWidth) {
      throw ArgumentError(
        'lineSize (${config.lineSize}B) must not be more than '
        '${1 << harborL1MemLenWidth} words, the longest burst.',
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
    // drop the line the other one holds. It does that by index (see
    // `storeValidClear`), which only reaches every alias while the index bits
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
        ctxBits == 0 ? tagOf(addr) : [reqCtx, tagOf(addr)].concat();
    Logic dataEntryOf(Logic addr) => (offBits + idxBits) == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits);

    final tagRam = _L1TagStore(
      this,
      clk: clk,
      reset: reset,
      lines: numLines,
      width: lineTagBits,
      readPorts: snoop ? 2 : 1,
      target: target,
      name: 'l1d_tags',
    );
    tagRam.rdAddr[0] <= idxOf(reqAddr);
    if (snoop) {
      tagRam.rdAddr[1] <= idxOf(invalAddr);
    }

    final ramLatency = HarborRegisterFile.blockRamReadLatency(target) ?? 1;
    final dataRam = HarborRegisterFile(
      useXilinxSdp72: true,
      numEntries: numLines * lineWords,
      dataWidth: xlen,
      numReadPorts: 1,
      numWritePorts: 1,
      reservedZero: false,
      byteWrite: true,
      target: target,
      forceReadLatency: ramLatency,
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
    final fillWord = Logic(
      name: 'fillWord',
      width: (offBits == 0 ? 1 : offBits) + 1,
    );
    // An earlier beat of this refill had an error.
    final fillErr = Logic(name: 'fillErr');
    final fillErrPage = Logic(name: 'fillErrPage');
    // Word of the line that the held load reads.
    final fillMissWord = Logic(
      name: 'fillMissWord',
      width: offBits == 0 ? 1 : offBits,
    );
    final missBeat = offBits == 0
        ? Const(1)
        : fillWord.getRange(0, offBits).eq(fillMissWord);
    final storeIdx = Logic(name: 'storeIdx', width: idxBits == 0 ? 1 : idxBits);
    // High in the first cycle of a store, when the tag read and addrQ belong
    // to the store address.
    final storeFirst = Logic(name: 'storeFirst');
    final storeHitQ = Logic(name: 'storeHitQ');

    final addrQ = Logic(name: 'addrQ', width: xlen);
    final validUpdateEn = Logic(name: 'validUpdateEn');
    final validUpdateIdx = Logic(
      name: 'validUpdateIdx',
      width: idxBits == 0 ? 1 : idxBits,
    );
    final fillValidSet = Logic(name: 'fillValidSet');
    // A flush clears every line, also while a store or an uncached read
    // finishes. Those operations keep their state and give their response.
    // Snoop stage: the invalidate of the last cycle, with its tag read.
    final snpV = Logic(name: 'snoopValid');
    final snpAddr = Logic(name: 'snoopAddr', width: xlen);
    final snpClrEn = Logic(name: 'snoopClrEn');
    final snpClrIdx = Logic(name: 'snoopClrIdx', width: validUpdateIdx.width);
    final lineValid = _L1ValidBits(
      clk: clk,
      reset: reset,
      flush: flush,
      lines: numLines,
      lookups: [idxOf(addrQ), if (snoop) idxOf(snpAddr)],
      updateEn: validUpdateEn,
      updateIdx: validUpdateIdx,
      updateValue: fillValidSet,
      clearEn: snoop ? snpClrEn : null,
      clearIdx: snoop ? snpClrIdx : null,
      clearLookup: 1,
    );
    final invalBusyNow = snoop
        ? (invalValid | snpV | snpClrEn).named('invalBusyNow')
        : Const(0);
    sweepCycles = lineValid.sweepCycles;

    // Match address and permission context.
    Logic committedHitOf(Logic a) =>
        lineValid.valid[0] & tagRam.read(0).eq(fullTagOf(a));
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
                flush |
                lineValid.sweeping |
                (snoop ? lineValid.pending : Const(0)))
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
    final memLenR = Logic(name: 'memLenR', width: harborL1MemLenWidth);
    memLen <= memLenR;
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
        : [addrQ.slice(byteBits - 1, 0), Const(0, width: 3)].concat();
    final ramRead = ramLatency == 1
        ? dataRam.readData(0)
        : flop(clk, dataRam.readData(0));
    respData <= mux(bypassDone, bypassData, ramRead >> rdShift);
    respValid <= (loadHit | storeDone | bypassDone);
    respFault <= faultDone;
    respFaultIsAccess <= faultDone & ~faultIsPage;
    miss <= loadMiss;
    busy <= (filling | storing | bypassing | drain | lineValid.sweeping);
    // Cacheable traffic only, so perfMiss over perfAccess is the miss rate.
    // An uncacheable access bypasses the line store and never looks a tag up,
    // so bypassDone is left out.
    perfAccess <= loadHit | storeDone;
    perfMiss <= loadMiss & ~filling;

    final fillWrEn = (filling & memDone & memValid & ~flush & ~reset).named(
      'fillWrEn',
    );
    final Logic fillEntry;
    if (offBits == 0) {
      fillEntry = fillIdx;
    } else if (idxBits == 0) {
      fillEntry = fillWord.slice(offBits - 1, 0);
    } else {
      fillEntry = [fillIdx, fillWord.slice(offBits - 1, 0)].concat();
    }
    // A store that hits writes its bytes into the line in the storeDone cycle,
    // after the memory acknowledged it. The write uses registers only, so the
    // tag compare is not on the path to the RAM write enable. The address tag
    // alone decides the hit: a line of the same address from another context
    // holds the same bytes.
    final storeHitNow =
        (lineValid.valid[0] &
                tagRam.read(0).getRange(0, tagBits).eq(tagOf(addrQ)))
            .named('storeHitNow');
    final storeHit = mux(storeFirst, storeHitNow, storeHitQ).named('storeHit');
    final storeAck = (storing & memDone & memValid).named('storeAck');
    final storeWrEn = (storeDone & storeHitQ).named('storeWrEn');
    final lanes = wordBytes;
    final lane = byteBits == 0
        ? Const(0, width: 1)
        : memAddrR.getRange(0, byteBits);
    // Byte i of the store is written when the size covers it.
    final strb = [
      for (var i = 0; i < lanes; i++)
        i == 0 ? Const(1) : memSizeR.gte(i.bitLength),
    ].rconcat();
    final storeStrb = (strb << lane).named('storeStrb');
    // The core sends only stores that are aligned to their size, so the bytes
    // stay in one word.
    if (byteBits > 0) {
      final sizeMask = [
        for (var i = 0; i < byteBits; i++) memSizeR.gt(i),
      ].rconcat();
      _l1CheckInSim(
        clk,
        reset,
        storing & (lane & sizeMask).neq(0),
        'store is not aligned to its size',
      );
    }
    final storeData = (memWdataR << [lane, Const(0, width: 3)].concat()).named(
      'storeData',
    );
    dataRam.input('wr_en').srcConnection! <= fillWrEn | storeWrEn;
    dataRam.input('wr_addr').srcConnection! <=
        mux(storeDone, dataEntryOf(memAddrR), fillEntry);
    dataRam.input('wr_data').srcConnection! <=
        mux(storeDone, storeData, memRdata);
    dataRam.input('wr_strb').srcConnection! <=
        mux(storeDone, storeStrb, Const((1 << lanes) - 1, width: lanes));

    final lastWord = Const(lineWords - 1, width: fillWord.width);
    // A refill commits only on a good last beat with no earlier error.
    // A snoop drops the line of a refill that is in flight or that waits to
    // set its valid bit. A refill of a line in a DMA write in flight also
    // does not make its line valid. Both kill the refill. The hold goes
    // through a flop first. A refill that commits in that cycle is cleared by
    // the invalidate of the write.
    final fillKill = Logic(name: 'fillKill');
    final fillMatch = Logic(name: 'fillMatch');
    final holdQ = snoop ? flop(clk, invalHold, reset: reset) : Const(0);
    final killNow = snoop
        ? (filling & (holdQ | fillMatch)).named('killNow')
        : Const(0);
    // A beat with an error, or a mem_last that does not match the burst
    // length, early or late. Either one fails the refill.
    final fillBad = (~memValid | memLast.neq(fillWord.eq(lastWord))).named(
      'fillBad',
    );
    final fillCommit =
        (fillWrEn & memLast & ~fillBad & ~fillErr & ~fillKill & ~killNow).named(
          'fillCommit',
        );
    if (checkMemLast) {
      _l1CheckInSim(
        clk,
        reset,
        memDone &
            ((filling & memLast.neq(fillWord.eq(lastWord))) |
                ((storing | bypassing) & ~memLast)),
        'mem_last does not match the burst length',
      );
    }
    // Fill completion, acknowledged stores, and miss-victim invalidation are
    // mutually exclusive FSM events, so they share the one valid update port.
    // Each one is followed by a cycle with no lookup (fillSettle, storeDone or
    // filling), which the registered update needs.
    fillValidSet <= fillCommit;
    // A store miss in a physical cache leaves the line alone. In a virtual
    // cache another virtual address of the same frame can hold the line at
    // this index (see the alias check above), so the miss drops it.
    final storeValidClear =
        (physicalAddresses ? Const(0) : storeAck & ~storeHit).named(
          'storeValidClear',
        );
    validUpdateEn <= fillValidSet | storeValidClear | loadMiss;
    validUpdateIdx <=
        mux(
          fillValidSet,
          fillIdx,
          mux(storeValidClear, storeIdx, idxOf(addrQ)),
        );
    tagRam.wrEn <= fillCommit;
    tagRam.wrAddr <= fillIdx;
    tagRam.wrData <= fillTag;

    if (snoop) {
      final snpIdx = idxOf(snpAddr);
      final live = (filling | lineValid.pending).named('fillLive');
      fillMatch <= snpV & live & snpIdx.eq(fillIdx);
      final snpHit =
          (snpV &
                  lineValid.valid[1] &
                  tagRam.read(1).getRange(0, tagBits).eq(tagOf(snpAddr)))
              .named('snoopHit');
      invalBusy <= invalBusyNow;
      fillLine <= memAddrR;
      Sequential(clk, [
        snpAddr < invalAddr,
        snpClrIdx < snpIdx,
        If(
          reset,
          then: [snpV < 0, snpClrEn < 0],
          orElse: [snpV < invalValid, snpClrEn < snpHit | fillMatch],
        ),
      ]);
    } else {
      fillMatch <= Const(0);
    }

    Sequential(clk, [
      addrQ < reqAddr,
      storeFirst < 0,
      If(killNow, then: [fillKill < 1]),
      If(storeFirst, then: [storeHitQ < storeHitNow]),
      If(
        reset,
        then: [
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
          memLenR < 0,
          drain < 0,
        ],
        orElse: [
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
              drain < (filling | drain) & ~(memDone & memLast),
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
                  If(memDone & memLast, then: [drain < 0]),
                ],
                orElse: [
                  If(
                    filling,
                    then: [
                      If(
                        memDone,
                        then: [
                          fillWord < fillWord + 1,
                          // Keep the miss word for a refill that a snoop
                          // kills.
                          if (snoop)
                            If(
                              memValid & missBeat,
                              then: [bypassData < memRdata >> rdShift],
                            ),
                          If(
                            fillBad & ~fillErr,
                            then: [
                              fillErr < 1,
                              fillErrPage < ~memValid & memFault,
                            ],
                          ),
                          // An error on any beat drops the line and faults
                          // the load after the last beat.
                          If(
                            memLast,
                            then: [
                              memEnR < 0,
                              filling < 0,
                              If(
                                fillErr | fillBad,
                                then: [
                                  faultDone < 1,
                                  faultIsPage <
                                      mux(
                                        fillErr,
                                        fillErrPage,
                                        ~memValid & memFault,
                                      ),
                                ],
                                orElse: [
                                  If(
                                    fillKill | killNow,
                                    then: [bypassDone < 1],
                                    orElse: [fillSettle < 1],
                                  ),
                                ],
                              ),
                            ],
                          ),
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
                                  memLenR < 0,
                                  storeIdx < idxOf(reqAddr),
                                  storeFirst < 1,
                                ],
                                orElse: [
                                  If(
                                    loadMiss,
                                    then: [
                                      filling < 1,
                                      // A fault after an earlier refill beat
                                      // must not leave the victim's old tag
                                      // pointing at partially overwritten data.
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
                                      fillWord < 0,
                                      fillErr < 0,
                                      fillKill < 0,
                                      if (offBits > 0)
                                        fillMissWord <
                                            addrQ.getRange(
                                              byteBits,
                                              byteBits + offBits,
                                            ),
                                      memLenR <
                                          Const(
                                            lineWords - 1,
                                            width: harborL1MemLenWidth,
                                          ),
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
                                          memLenR < 0,
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
