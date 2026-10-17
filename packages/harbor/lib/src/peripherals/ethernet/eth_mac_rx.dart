import 'package:rohd/rohd.dart';

import '../../clock/cdc.dart';
import 'eth_config.dart';
import 'eth_crc.dart';
import 'eth_rx_filter.dart';

/// Ethernet MAC receive core. It runs byte wide on the RX clock.
///
/// The core reads one byte on each cycle with `rx_strobe` high. A frame
/// starts with any number of 0x55 bytes and 0xD5, and ends when `rx_dv` is
/// low on a strobe. The core removes the preamble, the SFD and the FCS.
///
/// The output gives one byte on each cycle with `out_valid` high. There is
/// no ready, so the consumer must take each byte. `out_last` marks the last
/// byte of a frame and `out_status` on that byte has [0] fcs_err [1] runt
/// [2] oversize [3] rx_er [4] mcast [5] bcast. A runt has fewer than 64
/// bytes with the FCS. A frame of more than 1522 bytes is cut after 1522
/// bytes, the core sends its first 1518 bytes and sets oversize.
///
/// The address filter drops frames before their first byte goes out. All
/// other frames go out, also bad ones. A frame with fewer than 6 bytes
/// gives no output.
///
/// `rx_en`, `mac_addr`, `mc_hash` and `promisc` come from the register clock
/// and the core synchronizes them per bit. The core reads `rx_en` only at
/// the SFD. A frame that starts with `rx_en` low gives no output, and a frame
/// that started continues to its end. Change `mac_addr` only while `rx_en`
/// is low. The `rx_en` chain has one more stage, so a new `mac_addr` is
/// complete when `rx_en` goes high. `mc_hash` and `promisc` can change at
/// any time, because a frame reads only one hash bit and `promisc` once.
class HarborEthMacRx extends Module {
  /// Configuration of the MAC that contains this core.
  final HarborEthernetConfig config;

  /// High for one cycle with each output byte.
  Logic get outValid => output('out_valid');

  /// Output data byte.
  Logic get outData => output('out_data');

  /// Last byte of the frame.
  Logic get outLast => output('out_last');

  /// Frame status, valid with [outLast].
  Logic get outStatus => output('out_status');

  /// High from the SFD of a frame to its last output byte.
  Logic get busy => output('busy');

  /// `rx_en` as the core sees it after the synchronizer.
  Logic get enabled => output('enabled');

  static const _wait = 0;
  static const _idle = 1;
  static const _data = 2;
  static const _flush = 3;

  /// Largest frame with the FCS.
  static const maxFrameBytes = 1522;

  /// Smallest frame with the FCS.
  static const minFrameBytes = 64;

  /// CRC state after a frame and its correct FCS, before the inversion.
  static const crcResidue = 0xDEBB20E3;

  /// Status bits on the last byte.
  static const statusFcsErr = 1 << 0;
  static const statusRunt = 1 << 1;
  static const statusOversize = 1 << 2;
  static const statusRxEr = 1 << 3;
  static const statusMcast = 1 << 4;
  static const statusBcast = 1 << 5;

  HarborEthMacRx(
    Logic clk,
    Logic reset, {
    required this.config,
    required Logic rxStrobe,
    required Logic rxData,
    required Logic rxDv,
    required Logic rxEr,
    required Logic rxEn,
    required Logic macAddr,
    Logic? mcHash,
    Logic? promisc,
    super.name = 'eth_mac_rx',
  }) : super(definitionName: _definitionName(config)) {
    if (config.multicastHash && mcHash == null) {
      throw ArgumentError('multicastHash needs mcHash');
    }
    if (config.promiscuous && promisc == null) {
      throw ArgumentError('promiscuous needs promisc');
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    rxStrobe = addInput('rx_strobe', rxStrobe);
    rxData = addInput('rx_data', rxData, width: 8);
    rxDv = addInput('rx_dv', rxDv);
    rxEr = addInput('rx_er', rxEr);

    final outValid = addOutput('out_valid');
    final outData = addOutput('out_data', width: 8);
    final outLast = addOutput('out_last');
    final outStatus = addOutput('out_status', width: 8);
    final busyOut = addOutput('busy');
    final enabledOut = addOutput('enabled');

    Logic sync(String name, Logic src, int width, {int stages = 2}) {
      final s = HarborCdcSync(
        stages: stages,
        width: width,
        name: '${name}_sync',
      );
      s.input('async_in').srcConnection! <= addInput(name, src, width: width);
      s.input('dst_clk').srcConnection! <= clk;
      s.input('dst_reset').srcConnection! <= reset;
      return s.syncOut;
    }

    final rxEnRx = sync('rx_en', rxEn, 1, stages: 3);
    enabledOut <= rxEnRx;
    final macRx = sync('mac_addr', macAddr, 48);
    final mcHashRx = config.multicastHash ? sync('mc_hash', mcHash!, 64) : null;
    final promiscRx = config.promiscuous ? sync('promisc', promisc!, 1) : null;

    final state = Logic(name: 'state', width: 2);
    final cnt = Logic(name: 'cnt', width: 11);
    final crc = Logic(name: 'crc', width: 32);
    final er = Logic(name: 'er');
    final oversize = Logic(name: 'oversize');
    // Bytes wait here for the filter and to strip the FCS. sh[0] is newest.
    final sh = [for (var i = 0; i < 6; i++) Logic(name: 'sh_$i', width: 8)];

    Logic st(int s) => state.eq(Const(s, width: 2));
    Conditional go(int s) => state < Const(s, width: 2);
    busyOut <= st(_data) | st(_flush);

    final crcNext = harborEthCrcByte(crc, rxData).named('crc_next');
    final byteIn = (rxStrobe & rxDv).named('byte_in');
    final sfd = (st(_idle) & byteIn & rxData.eq(Const(0xD5, width: 8)) & rxEnRx)
        .named('sfd');
    final full = cnt.eq(Const(maxFrameBytes, width: 11)).named('full');
    final take = (st(_data) & byteIn & ~full).named('take');

    final filter = HarborEthRxFilter(
      clk,
      reset,
      config: config,
      start: sfd,
      inValid: take,
      inData: rxData,
      macAddr: macRx,
      crcNext: config.multicastHash ? crcNext : null,
      mcHash: mcHashRx,
      promisc: promiscRx,
    );

    final status = [
      Const(0, width: 2),
      filter.bcast,
      filter.mcast,
      er,
      oversize,
      cnt.lt(Const(minFrameBytes, width: 11)),
      crc.neq(Const(crcResidue, width: 32)),
    ].swizzle().named('status');

    List<Conditional> endFrame() => [
      If(
        filter.keep,
        then: [outValid < 1, outData < sh[5], go(_flush)],
        orElse: [go(_wait)],
      ),
    ];

    Sequential(clk, [
      outValid < 0,
      outLast < 0,
      outStatus < Const(0, width: 8),
      Case(state, [
        CaseItem(Const(_wait, width: 2), [
          If(rxStrobe & ~rxDv, then: [go(_idle)]),
        ]),
        CaseItem(Const(_idle, width: 2), [
          If.block([
            Iff(sfd, [
              cnt < Const(0, width: 11),
              crc < Const(0xFFFFFFFF, width: 32),
              er < 0,
              oversize < 0,
              go(_data),
            ]),
            Iff(byteIn & ~rxData.eq(Const(0x55, width: 8)), [go(_wait)]),
          ]),
        ]),
        CaseItem(Const(_data, width: 2), [
          If.block([
            Iff(rxStrobe & ~rxDv, endFrame()),
            Iff(byteIn & full, [oversize < 1, ...endFrame()]),
            Iff(byteIn, [
              If(filter.keep, then: [outValid < 1, outData < sh[5]]),
              sh[0] < rxData,
              for (var i = 1; i < 6; i++) sh[i] < sh[i - 1],
              crc < crcNext,
              cnt < cnt + Const(1, width: 11),
              er < er | rxEr,
            ]),
          ]),
        ]),
        CaseItem(Const(_flush, width: 2), [
          outValid < 1,
          outData < sh[4],
          outLast < 1,
          outStatus < status,
          // After a cut frame, wait for the end of its bytes.
          If(oversize, then: [go(_wait)], orElse: [go(_idle)]),
        ]),
      ]),
    ], reset: reset);
  }

  static String _definitionName(HarborEthernetConfig config) =>
      'HarborEthMacRx'
      '${config.multicastHash ? '_Hash' : ''}'
      '${config.promiscuous ? '_Promisc' : ''}';
}
