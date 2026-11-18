import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor adaptive multi-symbol arithmetic (range) decoder.
///
/// This is the core of an AV1-style entropy decoder: a binary range decoder
/// generalised to multi-symbol alphabets driven by a cumulative distribution
/// function (CDF), with **CDF adaptation**. The decoder owns its CDFs in a
/// per-context memory. After each symbol the active context's distribution is
/// nudged toward the observed symbol (matching AV1's `update_cdf`), so the
/// model tracks the source statistics as decoding proceeds.
///
/// Each symbol is decoded by narrowing a 16-bit range against the context's
/// Q15 cumulative CDF (increasing, last used entry 0x8000), then renormalising
/// (pulling fresh bits from the coded stream) so the range stays in
/// [0x8000, 0xFFFF].
///
/// Interface (inputs sampled on the strobes):
/// - init  : load `stream`, the code window takes the top 16 bits.
/// - load  : store `cdf` / `num_syms` into context `ctx`, resetting its count.
/// - decode: decode one symbol from context `ctx`, then adapt that CDF.
/// - symbol / symbol_valid : the decoded symbol (registered).
class HarborEntropyDecoder extends BridgeModule {
  /// Maximum alphabet size (CDF entries).
  final int maxSyms;

  /// Width of the internal coded-bit buffer.
  final int bufBits;

  /// Number of CDF contexts held in the decoder.
  final int numCtx;

  /// Width of the symbol output.
  int get symWidth => (maxSyms - 1).bitLength;

  /// Width of the context selector.
  int get ctxWidth => numCtx <= 1 ? 1 : (numCtx - 1).bitLength;

  /// Decoded symbol.
  Logic get symbol => output('symbol');

  HarborEntropyDecoder({
    this.maxSyms = 16,
    this.bufBits = 64,
    this.numCtx = 8,
    String? name,
  }) : super('HarborEntropyDecoder', name: name ?? 'entropy_decoder') {
    assert(bufBits >= 32, 'need room for the code window plus renorm bits');
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('init', PortDirection.input);
    createPort('stream', PortDirection.input, width: bufBits);
    createPort('load', PortDirection.input);
    createPort('decode', PortDirection.input);
    createPort('ctx', PortDirection.input, width: ctxWidth);
    createPort('cdf', PortDirection.input, width: maxSyms * 16);
    createPort('num_syms', PortDirection.input, width: 5);
    // Byte-feed refill: the environment presents the next two stream bytes
    // (byte at [15:8] consumed first) and advances its read pointer by the
    // `byte_pop` the decoder reports each cycle.
    createPort('bytes_in', PortDirection.input, width: 16);
    addOutput('byte_pop', width: 2);
    addOutput('symbol', width: symWidth);
    addOutput('symbol_valid');
    addOutput('rng', width: 16);
    addOutput('code', width: 16);

    final clk = input('clk');
    final reset = input('reset');

    // Range-decoder state.
    final rng = Logic(name: 'rng_reg', width: 16);
    final code = Logic(name: 'code_reg', width: 16);
    final bitbuf = Logic(name: 'bitbuf', width: bufBits);
    final cnt = Logic(name: 'valid_bits', width: 7); // valid bits in bitbuf
    final symReg = Logic(name: 'sym_reg', width: symWidth);
    final validReg = Logic(name: 'valid_reg');

    // Per-context CDF memory: the cumulative frequencies, the alphabet size and
    // an adaptation count that slows the update rate as the model settles.
    final cdfMem = [
      for (var c = 0; c < numCtx; c++)
        [
          for (var s = 0; s < maxSyms; s++)
            Logic(name: 'cdf_${c}_$s', width: 16),
        ],
    ];
    final nSymsMem = [
      for (var c = 0; c < numCtx; c++) Logic(name: 'nsyms_$c', width: 5),
    ];
    final cntMem = [
      for (var c = 0; c < numCtx; c++) Logic(name: 'cnt_$c', width: 6),
    ];

    output('rng') <= rng;
    output('code') <= code;
    output('symbol') <= symReg;
    output('symbol_valid') <= validReg;

    final ctxIn = input('ctx');
    final cdfIn = input('cdf');

    Logic selByIdx(List<Logic> arr, Logic idx) {
      Logic v = arr.last;
      for (var i = arr.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), arr[i], v);
      }
      return v;
    }

    // Read the active context's CDF / alphabet / count.
    Logic curCdf(int s) =>
        selByIdx([for (var c = 0; c < numCtx; c++) cdfMem[c][s]], ctxIn);
    final curN = selByIdx(nSymsMem, ctxIn).named('cur_n');
    final curCnt = selByIdx(cntMem, ctxIn).named('cur_cnt');

    // Boundary for symbol s: scale the range by the cumulative frequency.
    final b = [
      for (var s = 0; s < maxSyms; s++)
        ((rng.zeroExtend(32) * curCdf(s).zeroExtend(32)) >>> 15)
            .getRange(0, 16)
            .named('bound_$s'),
    ];

    // Symbol = number of boundaries below the code value (within num_syms-1).
    final lastIdx = (curN - Const(1, width: 5)).named('last_idx');
    Logic sym = Const(0, width: symWidth);
    for (var s = 0; s < maxSyms - 1; s++) {
      final counts = (code.gte(b[s]) & Const(s, width: 5).lt(lastIdx)).named(
        'ge_$s',
      );
      sym = (sym + counts.zeroExtend(symWidth)).named('sym_acc_$s');
    }

    // Low/high boundaries around the chosen symbol (b[-1] = 0).
    final bExt = [Const(0, width: 16), ...b];
    final symExt = sym.zeroExtend(symWidth + 1);
    final lo = selByIdx(bExt, symExt).named('lo');
    final hi = selByIdx(
      bExt,
      (symExt + Const(1, width: symWidth + 1)),
    ).named('hi');
    final code1 = (code - lo).named('code1');
    final rng1 = (hi - lo).named('rng1');

    // Renormalise: shift so rng1 returns to [0x8000, 0xFFFF].
    Logic floorLog2(Logic x) {
      Logic r = Const(0, width: 4);
      for (var i = 1; i < 16; i++) {
        r = mux(x[i], Const(i, width: 4), r);
      }
      return r;
    }

    final sh = (Const(15, width: 4) - floorLog2(rng1)).named('renorm_sh');
    final rngN = ((rng1 << sh).getRange(0, 16)).named('rng_n');
    final freshBits =
        (bitbuf >>> (Const(bufBits, width: bufBits) - sh.zeroExtend(bufBits)))
            .getRange(0, 16)
            .named('fresh_bits');
    final codeN = (((code1 << sh) | freshBits.zeroExtend(16)).getRange(
      0,
      16,
    )).named('code_n');

    // Refill: after consuming `sh` bits, top the window back up from the byte
    // feed (up to two bytes, covering the most a renorm can consume).
    final shifted = ((bitbuf << sh).getRange(0, bufBits)).named('shifted');
    final cnt2 = (cnt - sh.zeroExtend(7)).named('cnt2');
    final room = (Const(bufBits, width: 7) - cnt2).named('room');
    final pop = mux(
      room.gte(Const(16, width: 7)),
      Const(2, width: 2),
      mux<Logic>(
        room.gte(Const(8, width: 7)),
        Const(1, width: 2),
        Const(0, width: 2),
      ),
    ).named('byte_pop_v');
    final byte0 = input('bytes_in').getRange(8, 16);
    final byte1 = input('bytes_in').getRange(0, 8);
    final pos0 = (Const(bufBits, width: 7) - cnt2 - Const(8, width: 7));
    final pos1 = (Const(bufBits, width: 7) - cnt2 - Const(16, width: 7));
    final ins0 = mux(
      pop.gte(Const(1, width: 2)),
      (byte0.zeroExtend(bufBits) << pos0.zeroExtend(bufBits)).getRange(
        0,
        bufBits,
      ),
      Const(0, width: bufBits),
    );
    final ins1 = mux(
      pop.gte(Const(2, width: 2)),
      (byte1.zeroExtend(bufBits) << pos1.zeroExtend(bufBits)).getRange(
        0,
        bufBits,
      ),
      Const(0, width: bufBits),
    );
    final bitbufN = (shifted | ins0 | ins1).named('bitbuf_n');
    final cntN = (cnt2 + (pop.zeroExtend(7) << 3)).named('cnt_n');

    output('byte_pop') <= mux(input('decode'), pop, Const(0, width: 2));

    // CDF adaptation (AV1 update_cdf, in cumulative space). The update rate
    // grows with the count so the model converges. Symbols below the decoded
    // one move toward 0, the rest toward 0x8000.
    final speed = mux(
      curN.lt(Const(2, width: 5)),
      Const(0, width: 2),
      mux<Logic>(
        curN.lt(Const(4, width: 5)),
        Const(1, width: 2),
        Const(2, width: 2),
      ),
    ).named('speed');
    final rate =
        (Const(3, width: 4) +
                curCnt.gt(Const(15, width: 6)).zeroExtend(4) +
                curCnt.gt(Const(31, width: 6)).zeroExtend(4) +
                speed.zeroExtend(4))
            .named('rate');
    final newCnt = mux(
      curCnt.lt(Const(32, width: 6)),
      curCnt + Const(1, width: 6),
      curCnt,
    ).named('new_cnt');
    Logic newCdf(int s) {
      final c = curCdf(s);
      final dec = (c - (c >>> rate)).getRange(0, 16);
      final inc = (c + ((Const(0x8000, width: 16) - c) >>> rate)).getRange(
        0,
        16,
      );
      final inUse = Const(s, width: 5).lt(lastIdx);
      final below = sym.gt(Const(s, width: symWidth));
      return mux(inUse, mux(below, dec, inc), c);
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          rng < Const(0xFFFF, width: 16),
          code < Const(0, width: 16),
          bitbuf < Const(0, width: bufBits),
          cnt < Const(0, width: 7),
          symReg < Const(0, width: symWidth),
          validReg < Const(0),
          for (var c = 0; c < numCtx; c++) ...[
            nSymsMem[c] < Const(0, width: 5),
            cntMem[c] < Const(0, width: 6),
            for (var s = 0; s < maxSyms; s++)
              cdfMem[c][s] < Const(0, width: 16),
          ],
        ],
        orElse: [
          validReg < Const(0),
          If(
            input('init'),
            then: [
              rng < Const(0xFFFF, width: 16),
              code < input('stream').getRange(bufBits - 16, bufBits),
              bitbuf < (input('stream') << 16).getRange(0, bufBits),
              // The window holds the stream minus the 16 bits taken by `code`.
              cnt < Const(bufBits - 16, width: 7),
            ],
          ),
          // Load an initial CDF into the selected context.
          If(
            input('load'),
            then: [
              for (var c = 0; c < numCtx; c++)
                If(
                  ctxIn.eq(Const(c, width: ctxWidth)),
                  then: [
                    nSymsMem[c] < input('num_syms'),
                    cntMem[c] < Const(0, width: 6),
                    for (var s = 0; s < maxSyms; s++)
                      cdfMem[c][s] < cdfIn.getRange(s * 16, s * 16 + 16),
                  ],
                ),
            ],
          ),
          // Decode one symbol and adapt the active context's CDF.
          If(
            input('decode'),
            then: [
              rng < rngN,
              code < codeN,
              bitbuf < bitbufN,
              cnt < cntN,
              symReg < sym,
              validReg < Const(1),
              for (var c = 0; c < numCtx; c++)
                If(
                  ctxIn.eq(Const(c, width: ctxWidth)),
                  then: [
                    cntMem[c] < newCnt,
                    for (var s = 0; s < maxSyms; s++) cdfMem[c][s] < newCdf(s),
                  ],
                ),
            ],
          ),
        ],
      ),
    ]);
  }
}
