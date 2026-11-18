import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'av1_cdf_tables.dart' as cdf;
import 'od_ec_decoder.dart';

/// Harbor bit-exact AV1 partition-symbol decode (the entropy read inside
/// `decode_partition` when both rows and cols are available).
///
/// At a square block of size bucket [partIdx] (0 = 128x128, 1 = 64x64, 2 =
/// 32x32, 3 = 16x16, 4 = 8x8) the partition type is decoded from
/// `default_partition_cdf[partIdx][ctx]`, an N-symbol CDF where N = 8 for
/// 128x128, 4 for 8x8, else 10. `ctx` (0..3) = left*2 + above from the
/// above/left partition context bits (computed by the frame walk, not here).
/// Wraps the proven [HarborOdEcDecoder]: selects the CDF row for the runtime
/// `ctx`, loads it, one decode gives the partition type.
///
/// `bytes` holds the coded data (byte i at `[i*8 +: 8]`). Pulse `start`. `done`
/// asserts with `partition` valid (PARTITION_NONE = 0 .. PARTITION_VERT_4 = 9).
class HarborPartitionSymbol extends BridgeModule {
  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  /// Block-size bucket selecting the CDF (0 = 128x128 .. 4 = 8x8).
  final int partIdx;

  HarborPartitionSymbol({
    required this.partIdx,
    this.maxBytes = 16,
    String? name,
  }) : assert(partIdx >= 0 && partIdx < 5, 'partIdx 0..4'),
       super(
         'HarborPartitionSymbol',
         name: name ?? 'partition_decode_$partIdx',
       ) {
    final nsyms = partIdx == 0 ? 8 : (partIdx == 4 ? 4 : 10);
    final table = cdf.kAv1DefaultPartitionCdf[partIdx];

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('ctx', PortDirection.input, width: 2);
    addOutput('done');
    addOutput('partition', width: 4);

    final clk = input('clk');
    final reset = input('reset');
    final ctx = input('ctx');

    Logic packCdf(List<int> icdf) => [
      for (var s = nsyms - 1; s >= 0; s--)
        Const(s < icdf.length ? icdf[s] : 0, width: 16),
    ].concat();
    // Select the CDF row for the runtime ctx (0..3) from the 4-context table.
    Logic selCdf() {
      Logic v = packCdf(table[3]);
      for (var i = 2; i >= 0; i--) {
        v = mux(ctx.eq(Const(i, width: 2)), packCdf(table[i]), v);
      }
      return v;
    }

    final ec = HarborOdEcDecoder(maxSyms: nsyms, numCtx: 1, name: 'ec');
    addSubModule(ec);
    final cw = ec.ctxWidth;

    final buf = [
      for (var i = 0; i < maxBytes; i++) Logic(name: 'b_$i', width: 8),
    ];
    final cursor = Logic(name: 'cursor', width: (maxBytes + 4).bitLength);
    Logic byteAt(Logic ix) {
      Logic v = buf.last;
      for (var i = maxBytes - 2; i >= 0; i--) {
        v = mux(ix.eq(Const(i, width: cursor.width)), buf[i], v);
      }
      return mux(
        ix.gte(Const(maxBytes, width: cursor.width)),
        Const(0, width: 8),
        v,
      );
    }

    final ecInit = Logic(name: 'ec_init');
    final ecLoad = Logic(name: 'ec_load');
    final ecDecode = Logic(name: 'ec_decode');
    ec.input('clk').srcConnection! <= clk;
    ec.input('reset').srcConnection! <= reset;
    ec.input('init').srcConnection! <= ecInit;
    ec.input('load').srcConnection! <= ecLoad;
    ec.input('decode').srcConnection! <= ecDecode;
    ec.input('ctx').srcConnection! <= Const(0, width: cw);
    ec.input('cdf').srcConnection! <= selCdf();
    ec.input('num_syms').srcConnection! <= Const(nsyms, width: 5);
    ec.input('bytes_in').srcConnection! <=
        [
          byteAt(cursor),
          byteAt((cursor + Const(1, width: cursor.width))),
          byteAt((cursor + Const(2, width: cursor.width))),
        ].concat();
    final sym = ec.output('symbol');
    final bytePop = ec.output('byte_pop');

    const sIdle = 0, sLoad = 1, sInit = 2, sDec = 3, sCap = 4, sDone = 5;
    final st = Logic(name: 'st', width: 3);
    final partReg = Logic(name: 'part_r', width: 4);

    output('done') <= st.eq(Const(sDone, width: 3));
    output('partition') <= partReg;

    Combinational([
      ecInit < Const(0),
      ecLoad < Const(0),
      ecDecode < Const(0),
      Case(st, [
        CaseItem(Const(sLoad, width: 3), [ecLoad < Const(1)]),
        CaseItem(Const(sInit, width: 3), [ecInit < Const(1)]),
        CaseItem(Const(sDec, width: 3), [ecDecode < Const(1)]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          cursor < Const(0, width: cursor.width),
          partReg < Const(0, width: 4),
          for (var i = 0; i < maxBytes; i++) buf[i] < Const(0, width: 8),
        ],
        orElse: [
          cursor <
              (cursor + bytePop.zeroExtend(cursor.width)).getRange(
                0,
                cursor.width,
              ),
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  for (var i = 0; i < maxBytes; i++)
                    buf[i] < input('bytes').getRange(i * 8, i * 8 + 8),
                  cursor < Const(0, width: cursor.width),
                  st < Const(sLoad, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sLoad, width: 3), [st < Const(sInit, width: 3)]),
            CaseItem(Const(sInit, width: 3), [st < Const(sDec, width: 3)]),
            CaseItem(Const(sDec, width: 3), [st < Const(sCap, width: 3)]),
            CaseItem(Const(sCap, width: 3), [
              partReg < sym.zeroExtend(4),
              st < Const(sDone, width: 3),
            ]),
            CaseItem(Const(sDone, width: 3), [
              If(~input('start'), then: [st < Const(sIdle, width: 3)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
