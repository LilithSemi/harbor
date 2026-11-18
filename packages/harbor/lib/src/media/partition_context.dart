import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 partition-decode setup (`decode_partition` context derivation).
///
/// For a block at mode-info position `(r, c)` of width-log2 `bsl`
/// (= mi_size_wide_log2[bSize]), this computes the inputs the partition-symbol
/// read needs: the CDF context `ctx` (from the above/left partition context
/// bytes), the `has_rows`/`has_cols` availability that selects between a full
/// partition symbol, the split-or-horz/vert binary, or a forced split, and the
/// `avail_u`/`avail_l` neighbour-available flags.
///
///   num4x4 = 1 << bsl
///   half = num4x4 >> 1
///   has_rows = (r + half) < mi_rows
///   has_cols = (c + half) < mi_cols
///   above_p = (above_ctx >> bsl) & 1
///   left_p = (left_ctx >> bsl) & 1
///   ctx = left_p * 2 + above_p
/// Combinational. The symbol read, the context byte updates, and the recursion
/// are the tile FSM's job. This is the exact per-step setup.
class HarborPartitionContext extends BridgeModule {
  HarborPartitionContext({String? name})
    : super('HarborPartitionContext', name: name ?? 'partition_ctx') {
    createPort('r', PortDirection.input, width: 16);
    createPort('c', PortDirection.input, width: 16);
    createPort('mi_rows', PortDirection.input, width: 16);
    createPort('mi_cols', PortDirection.input, width: 16);
    createPort('bsl', PortDirection.input, width: 3); // mi_size_wide_log2
    createPort('above_ctx', PortDirection.input, width: 8);
    createPort('left_ctx', PortDirection.input, width: 8);
    addOutput('ctx', width: 2);
    addOutput('has_rows', width: 1);
    addOutput('has_cols', width: 1);
    addOutput('avail_u', width: 1);
    addOutput('avail_l', width: 1);

    final r = input('r');
    final c = input('c');
    final bsl = input('bsl');

    // num4x4 = 1 << bsl, half = num4x4 >> 1.
    final num4x4 = (Const(1, width: 16) << bsl.zeroExtend(16)).getRange(0, 16);
    final half = (num4x4 >>> 1).getRange(0, 16);
    final rPlus = (r + half).getRange(0, 16);
    final cPlus = (c + half).getRange(0, 16);

    output('has_rows') <= rPlus.lt(input('mi_rows'));
    output('has_cols') <= cPlus.lt(input('mi_cols'));
    output('avail_u') <= r.or(); // r > 0
    output('avail_l') <= c.or(); // c > 0

    // above_p / left_p = bit `bsl` of the context byte.
    final aboveP = (input('above_ctx') >>> bsl.zeroExtend(8)).getRange(0, 1);
    final leftP = (input('left_ctx') >>> bsl.zeroExtend(8)).getRange(0, 1);
    output('ctx') <=
        ([leftP, aboveP].concat()).getRange(0, 2); // left*2 + above
  }
}
