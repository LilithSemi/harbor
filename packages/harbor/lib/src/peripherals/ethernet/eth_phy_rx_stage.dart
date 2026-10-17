import 'package:rohd/rohd.dart';

/// Output of [harborEthPhyRxStage].
typedef HarborEthPhyRxOut = ({Logic data, Logic dv, Logic er, Logic strobe});

/// Receive output stage that a PHY front end shares.
///
/// It holds each byte for one byte time, so a dribble nibble at the end of a
/// frame can set `er` on the last byte. A frame end gives the held byte,
/// then one strobe with `dv` low. While no frame is active, [idleTick] gives
/// strobes with `dv` low. Between frames the MAC core needs these strobes.
/// At a frame end up to 3 strobes can come on back-to-back clocks.
HarborEthPhyRxOut harborEthPhyRxStage(
  Logic clk,
  Logic reset, {
  required Logic byteIn,
  required Logic byteData,
  required Logic byteEr,
  required Logic frameEnd,
  required Logic dribble,
  required Logic idleTick,
}) {
  final data = Logic(name: 'rx_data_r', width: 8);
  final dv = Logic(name: 'rx_dv_r');
  final er = Logic(name: 'rx_er_r');
  final strobe = Logic(name: 'rx_strobe_r');
  final heldValid = Logic(name: 'held_valid');
  final held = Logic(name: 'held', width: 8);
  final heldEr = Logic(name: 'held_er');
  final tail = Logic(name: 'tail');

  Sequential(clk, [
    strobe < 0,
    dv < 0,
    er < 0,
    If.block([
      Iff(byteIn, [
        If(heldValid, then: [data < held, dv < 1, er < heldEr, strobe < 1]),
        held < byteData,
        heldEr < byteEr,
        heldValid < 1,
      ]),
      Iff(frameEnd, [
        strobe < 1,
        If(
          heldValid,
          then: [
            data < held,
            dv < 1,
            er < (heldEr | dribble),
            heldValid < 0,
            tail < 1,
          ],
        ),
      ]),
      Iff(tail, [strobe < 1, tail < 0]),
      Iff(idleTick, [strobe < 1]),
    ]),
  ], reset: reset);

  return (data: data, dv: dv, er: er, strobe: strobe);
}

/// Nibble receive path that a 4-bit front end shares.
///
/// It pairs the nibbles on [rxd] into bytes, the low nibble first, and gives
/// them to [harborEthPhyRxStage]. The first `0xD` nibble after the `0x5`
/// nibbles is the top nibble of the SFD and sets the alignment. [enable] low
/// stops the path, so another path at a different rate can use the clock.
HarborEthPhyRxOut harborEthPhyNibbleRx(
  Logic clk,
  Logic reset, {
  required Logic rxd,
  required Logic rxDv,
  required Logic rxEr,
  Logic? enable,
}) {
  final en = enable ?? Const(1);
  final dv = (rxDv & en).named('rx_dv_en');
  final half = Logic(name: 'rx_half');
  final active = Logic(name: 'rx_active');
  final low = Logic(name: 'rx_low', width: 4);
  final locked = Logic(name: 'rx_locked');
  final acc = Logic(name: 'rx_acc');
  final idleTog = Logic(name: 'rx_idle_tog');
  final sfdNibble = rxd.eq(0xD);
  final forced = (~locked & ~half & sfdNibble).named('rx_forced');
  Sequential(clk, [
    active < dv,
    If(dv & sfdNibble, then: [locked < 1]),
    If(~dv, then: [locked < 0]),
    If(
      dv,
      then: [
        idleTog < 0,
        If(
          half | forced,
          then: [half < 0, acc < 0],
          orElse: [half < 1, low < rxd, acc < rxEr],
        ),
      ],
      orElse: [half < 0, acc < 0, idleTog < ~idleTog],
    ),
  ], reset: reset);

  return harborEthPhyRxStage(
    clk,
    reset,
    byteIn: dv & (half | forced),
    byteData: [rxd, mux(half, low, Const(5, width: 4))].swizzle(),
    byteEr: acc | rxEr,
    frameEnd: active & ~dv,
    dribble: half,
    idleTick: ~active & ~dv & idleTog & en,
  );
}
