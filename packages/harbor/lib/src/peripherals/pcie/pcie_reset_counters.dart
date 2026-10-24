import 'package:rohd/rohd.dart';

import '../../clock/cdc.dart';

/// Counts the reset events of a PCIe endpoint, so a host can see after a
/// warm boot which resets the device saw.
///
/// The counters have no reset. They start at the FPGA init value 0, and a
/// simulation starts them at 0 too. No PCIe reset clears them. Each count is
/// 8 bits and stops at 255.
///
/// `status` is 64 bits. Word 0: [7:0] user reset assertions, [15:8] PERST#
/// assertions, [23:16] hot resets received, [31:24] link down events. Word
/// 1: [3:0] PHY reset state, [7:4] PHY failure state, [15:8] PHY retries,
/// [16] PERST# is low now, [31:24] link retrains from [linkRetrains], 0
/// when it is null. The PHY fields come from the PIPE clock and are not
/// synchronized. The user reset count includes the reset at power-on.
///
/// [clk] is the user clock from the MMCM. It stops while PERST# is low,
/// because PERST# resets the MMCM, and it is not stable before [mmcmLock].
/// The counts on [clk] change only while the synchronized lock is high. An
/// event that occurs while the MMCM is not locked counts after the lock.
/// The counts are best effort. A PERST# or lock loss edge on the same clock
/// edge as an increment can store a wrong value.
///
/// With [freeClk], a clock that runs while PERST# is low, a synchronizer on
/// that clock counts each PERST# assertion on the pin. The count crosses to
/// [clk] in gray code through a 2 flop synchronizer per bit. openXC7 has no
/// false path or max delay constraint, so it times this crossing as a
/// related path.
///
/// Without [freeClk], PERST# sets a flag with no clock, and the count goes
/// up after the MMCM locks again. Two PERST# pulses with no relock between
/// them count as one. A PERST# that is low at configuration counts as one.
class HarborPcieResetCounters extends Module {
  Logic get status => output('status');

  HarborPcieResetCounters({
    required Logic clk,
    required Logic mmcmLock,
    required Logic perstN,
    required Logic userReset,
    required Logic hotReset,
    required Logic linkUp,
    required Logic phyResetState,
    required Logic phyFailState,
    required Logic phyRetries,
    Logic? freeClk,
    Logic? linkRetrains,
    super.name = 'pcie_reset_counters',
  }) : super(
         definitionName:
             'HarborPcieResetCounters${freeClk == null ? '' : '_F'}'
             '${linkRetrains == null ? '' : '_R'}',
       ) {
    clk = addInput('clk', clk);
    mmcmLock = addInput('mmcm_lock', mmcmLock);
    perstN = addInput('perst_n', perstN);
    userReset = addInput('user_reset', userReset);
    hotReset = addInput('hot_reset', hotReset);
    linkUp = addInput('link_up', linkUp);
    phyResetState = addInput('phy_reset_state', phyResetState, width: 4);
    phyFailState = addInput('phy_fail_state', phyFailState, width: 4);
    phyRetries = addInput('phy_retries', phyRetries, width: 8);
    final retrains = linkRetrains == null
        ? Const(0, width: 8)
        : addInput('link_retrains', linkRetrains, width: 8);

    Logic count(Logic c, Logic event) =>
        mux(event & ~c.and(), c + 1, c).named('${c.name}_next');

    Logic sync(Logic d, Logic dstClk, String name) {
      final s = HarborCdcSync(
        width: d.width,
        powerUpValue: 0,
        name: '${name}_sync',
      );
      s.input('async_in').srcConnection! <= d;
      s.input('dst_clk').srcConnection! <= dstClk;
      s.input('dst_reset').srcConnection! <= Const(0);
      return s.syncOut;
    }

    // The lock loss resets this at once, also with no clock.
    final locked = ~harborCdcJoinReset(
      clk,
      ~mmcmLock,
      Const(0),
      powerUpValue: 1,
      name: 'lock_reset',
    );

    final Logic perstCount;
    final Logic perstLow;
    if (freeClk != null) {
      freeClk = addInput('free_clk', freeClk);
      final low = sync(~perstN, freeClk, 'perst_free');
      final prev = Logic(name: 'perst_free_prev');
      final bin = Logic(name: 'perst_free_count', width: 8);
      final gray = Logic(name: 'perst_free_gray', width: 8);
      Sequential(freeClk, [
        prev < low,
        bin < count(bin, low & ~prev),
        gray < harborGray(bin),
      ]);
      harborSimPowerUp(freeClk, [prev, bin, gray]);
      final user = sync([low, gray].swizzle(), clk, 'perst_user');
      perstCount = harborGrayToBin(user.slice(7, 0)).named('perst_count');
      perstLow = user[8];
    } else {
      // PERST# sets perst0 and perst1 at once. perst0 clears on the first
      // edge with the MMCM locked, and perst1 one edge later.
      final perst0 = Logic(name: 'perst_seen_0');
      final perst1 = Logic(name: 'perst_seen_1');
      final perst2 = Logic(name: 'perst_seen_2');
      Sequential(
        clk,
        [perst0 < perst0 & ~locked, perst1 < perst0],
        reset: ~perstN,
        asyncReset: true,
        resetValues: {perst0: 1, perst1: 1},
      );
      final c = Logic(name: 'perst_count', width: 8);
      Sequential(clk, [
        perst2 < perst1,
        c < count(c, perst2 & ~perst1 & locked),
      ]);
      harborSimPowerUp(clk, [perst0, perst1, perst2, c]);
      perstCount = c;
      perstLow = perst1;
    }

    final hot = sync(hotReset, clk, 'hot_reset');
    final hotPrev = Logic(name: 'hot_reset_prev');
    final userPrev = Logic(name: 'user_reset_prev');
    final linkPrev = Logic(name: 'link_up_prev');
    final userCount = Logic(name: 'user_count', width: 8);
    final hotCount = Logic(name: 'hot_count', width: 8);
    final linkCount = Logic(name: 'link_down_count', width: 8);
    Sequential(clk, [
      If(
        locked,
        then: [
          hotPrev < hot,
          userPrev < userReset,
          linkPrev < linkUp,
          userCount < count(userCount, userReset & ~userPrev),
          hotCount < count(hotCount, hot & ~hotPrev),
          linkCount < count(linkCount, ~linkUp & linkPrev),
        ],
      ),
    ]);
    harborSimPowerUp(clk, [
      hotPrev,
      userPrev,
      linkPrev,
      userCount,
      hotCount,
      linkCount,
    ]);

    addOutput('status', width: 64) <=
        [
          retrains,
          Const(0, width: 7),
          perstLow,
          phyRetries,
          phyFailState,
          phyResetState,
          linkCount,
          hotCount,
          perstCount,
          userCount,
        ].swizzle();
  }
}
