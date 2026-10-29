import 'package:rohd/rohd.dart';

import 'eth_config.dart';
import 'eth_dma_tx.dart';
import 'eth_mdio.dart';

/// Register offsets of the Ethernet MAC.
abstract final class HarborEthReg {
  static const id = 0x000;
  static const hwCaps = 0x004;
  static const ctrl = 0x008;
  static const status = 0x00C;
  static const intStatus = 0x010;
  static const intEnable = 0x014;
  static const macLo = 0x018;
  static const macHi = 0x01C;
  static const mcHashLo = 0x020;
  static const mcHashHi = 0x024;
  static const txRingLo = 0x030;
  static const txRingHi = 0x034;
  static const txRingSize = 0x038;
  static const txTail = 0x03C;
  static const txHead = 0x040;
  static const rxRingLo = 0x050;
  static const rxRingHi = 0x054;
  static const rxRingSize = 0x058;
  static const rxTail = 0x05C;
  static const rxHead = 0x060;
  static const mdioCtrl = 0x070;
  static const mdioData = 0x074;
  static const mdioDiv = 0x078;
  static const txFrames = 0x080;
  static const rxFrames = 0x084;
  static const rxFcsErr = 0x088;
  static const rxMissed = 0x08C;
  static const rxOverflow = 0x090;
  static const rxRunt = 0x094;
  static const rxOversize = 0x098;
  static const txPause = 0x09C;
  static const rxPause = 0x0A0;

  /// Value of the ID register, "ETH1".
  static const idValue = 0x45544831;

  /// Reset value of MDIO_DIV.
  static const mdioDivReset = 63;
}

/// Register file of the Ethernet MAC on the sys clock.
///
/// It decodes the register map at [HarborEthReg] in a window of 4 KB. The
/// bus inputs follow the register waist of a 32-bit BusSlavePort: `stb`
/// holds until `ack`, which goes high for one cycle with the read data on
/// `rdata`. `ack` comes 2 cycles after `stb`. An offset with no register
/// reads 0 and ignores writes. A write changes only the bytes that `sel`
/// selects.
///
/// The interrupt and counter events are one cycle pulses on the sys clock.
/// INT_STATUS and the sticky STATUS bits are write 1 to clear. An event in
/// the same cycle as a clear wins.
///
/// STATUS bits: 0 tx_running, 1 rx_running, 2 tx_ring_err, 3 rx_ring_err,
/// 4 rx_clk_lost, 5 tx_clk_lost, 6 bus_bad_id, 7 bus_w_last.
///
/// STATUS tx_ring_err and rx_ring_err set on the rising edge of the DMA
/// `ring_err`. STATUS tx_clk_lost and rx_clk_lost show the FIFO `clk_lost`,
/// and a write 1 pulses `*_clk_lost_clear`. STATUS bus_bad_id and bus_w_last
/// show the sticky `err_bad_id` and `err_w_last` of the DMA arbiter. They
/// are read only, and the datapath reset (reset or soft_reset) clears them.
/// Both read 0 while the fabric and the DMAs work correctly.
///
/// CTRL soft_reset makes `tx_en` and `rx_en` low, so the DMAs end their
/// frames. When both DMAs are idle and `bus_idle` is high, `soft_reset`
/// pulses for one cycle and the bit reads 0 again. The pulse also clears
/// TX_TAIL, RX_TAIL, INT_STATUS and the STATUS ring errors. The counters
/// and the other registers keep their values.
///
/// A write to a ring LO, HI or SIZE register pulses that `*_ring_reset` and
/// sets TAIL to 0, so the driver writes TAIL after the ring. The DMA gets
/// the new base and size only when it is idle, the same time it applies
/// the ring reset, so a frame in flight finishes in its old ring. The ring
/// base drops the bits below the descriptor size and the bits at or above
/// the DMA address width, which read 0. SIZE is clamped to 1 to 12. TAIL
/// reads and drives the stored value masked to the ring size.
///
/// STATUS tx_running is high while the TX DMA is busy, TX is enabled with no
/// ring error, the TX FIFO holds a word, or the TX MAC is in a frame or its
/// gap. rx_running is high while the RX DMA is busy, RX is enabled with no ring
/// error, or the RX MAC is in a frame or still sees rx_en. Change the CTRL
/// speed only when both read 0. While a PHY clock is lost, the bits of that
/// side keep their last value. Then the matching STATUS clk_lost bit counts as
/// stopped. Change MAC_LO and MAC_HI only while rx_en is low, as the RX MAC
/// reads them bit by bit.
///
/// MDIO_CTRL start pulses `mdio_start` when the MDIO master is not busy.
/// With [HarborEthernetConfig.mdioC45], MDIO_CTRL c45 and devad are stored
/// and MDIO_DATA [31:16] holds the clause 45 register address. After a
/// read, MDIO_DATA [15:0] takes the result.
///
/// Options that are off store nothing and read 0: promisc, MC_HASH, c45,
/// devad and the pause counters.
class HarborEthRegs extends Module {
  /// Configuration of the MAC that contains this register file.
  final HarborEthernetConfig config;

  /// Address width of the DMA master.
  final int dmaAddressWidth;

  Logic get ack => output('ack');
  Logic get rdata => output('rdata');
  Logic get irq => output('irq');
  Logic get txEn => output('tx_en');
  Logic get rxEn => output('rx_en');
  Logic get promisc => output('promisc');
  Logic get keepBad => output('keep_bad');
  Logic get speed => output('speed');
  Logic get macAddr => output('mac_addr');
  Logic get mcHash => output('mc_hash');
  Logic get softReset => output('soft_reset');
  Logic get txRingBase => output('tx_ring_base');
  Logic get txRingSize => output('tx_ring_size');
  Logic get txTail => output('tx_tail');
  Logic get txRingReset => output('tx_ring_reset');
  Logic get rxRingBase => output('rx_ring_base');
  Logic get rxRingSize => output('rx_ring_size');
  Logic get rxTail => output('rx_tail');
  Logic get rxRingReset => output('rx_ring_reset');
  Logic get txClkLostClear => output('tx_clk_lost_clear');
  Logic get rxClkLostClear => output('rx_clk_lost_clear');
  Logic get mdioStart => output('mdio_start');
  Logic get mdioWrite => output('mdio_write');
  Logic get mdioC45 => output('mdio_c45');
  Logic get mdioPhy => output('mdio_phy');
  Logic get mdioReg => output('mdio_reg');
  Logic get mdioDevad => output('mdio_devad');
  Logic get mdioWdata => output('mdio_wdata');
  Logic get mdioAddr => output('mdio_addr');
  Logic get mdioDiv => output('mdio_div');

  HarborEthRegs(
    Logic clk,
    Logic reset, {
    required this.config,
    required this.dmaAddressWidth,
    required Logic stb,
    required Logic addr,
    required Logic we,
    required Logic wdata,
    required Logic sel,
    required Logic txHead,
    required Logic rxHead,
    required Logic txBusy,
    required Logic rxBusy,
    required Logic busIdle,
    required Logic txRingErr,
    required Logic rxRingErr,
    required Logic txDone,
    required Logic txErr,
    required Logic rxDone,
    required Logic rxErr,
    required Logic rxMissed,
    required Logic txClkLost,
    required Logic rxClkLost,
    required Logic rxOverflow,
    required Logic busBadId,
    required Logic busWLast,
    required Logic evTxFrame,
    required Logic evRxFrame,
    required Logic evRxFcs,
    required Logic evRxRunt,
    required Logic evRxOversize,
    required Logic mdioBusy,
    required Logic mdioRdone,
    required Logic mdioRdata,
    required Logic txPathBusy,
    required Logic rxPathBusy,
    super.name = 'eth_regs',
  }) : super(
         definitionName:
             'HarborEthRegs_a${dmaAddressWidth}'
             '_c${config.hwCaps.toRadixString(16)}',
       ) {
    final aw = dmaAddressWidth;
    if (aw < 12 || aw > 64) {
      throw ArgumentError.value(aw, 'dmaAddressWidth', 'must be 12 to 64');
    }
    const iw = HarborEthDmaTx.indexWidth;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    stb = addInput('stb', stb);
    addr = addInput('addr', addr, width: 12);
    we = addInput('we', we);
    wdata = addInput('wdata', wdata, width: 32);
    sel = addInput('sel', sel, width: 4);
    txHead = addInput('tx_head', txHead, width: iw);
    rxHead = addInput('rx_head', rxHead, width: iw);
    txBusy = addInput('tx_busy', txBusy);
    rxBusy = addInput('rx_busy', rxBusy);
    busIdle = addInput('bus_idle', busIdle);
    txRingErr = addInput('tx_ring_err', txRingErr);
    rxRingErr = addInput('rx_ring_err', rxRingErr);
    txDone = addInput('tx_done', txDone);
    txErr = addInput('tx_err', txErr);
    rxDone = addInput('rx_done', rxDone);
    rxErr = addInput('rx_err', rxErr);
    rxMissed = addInput('rx_missed', rxMissed);
    txClkLost = addInput('tx_clk_lost', txClkLost);
    rxClkLost = addInput('rx_clk_lost', rxClkLost);
    rxOverflow = addInput('rx_overflow', rxOverflow);
    busBadId = addInput('bus_bad_id', busBadId);
    busWLast = addInput('bus_w_last', busWLast);
    evTxFrame = addInput('ev_tx_frame', evTxFrame);
    evRxFrame = addInput('ev_rx_frame', evRxFrame);
    evRxFcs = addInput('ev_rx_fcs', evRxFcs);
    evRxRunt = addInput('ev_rx_runt', evRxRunt);
    evRxOversize = addInput('ev_rx_oversize', evRxOversize);
    mdioBusy = addInput('mdio_busy', mdioBusy);
    mdioRdone = addInput('mdio_rdone', mdioRdone);
    mdioRdata = addInput('mdio_rdata', mdioRdata, width: 16);
    txPathBusy = addInput('tx_path_busy', txPathBusy);
    rxPathBusy = addInput('rx_path_busy', rxPathBusy);

    final ackR = Logic(name: 'ack_r');
    final rdataR = Logic(name: 'rdata_r', width: 32);
    addOutput('ack') <= ackR;
    addOutput('rdata', width: 32) <= rdataR;

    // The bus request goes into registers first, and the access is done one
    // cycle later from them. So the decode and the read mux have a full
    // cycle after a flop, and `ack` comes 2 cycles after `stb`.
    final act = Logic(name: 'req_act');
    final addrR = Logic(name: 'req_addr', width: 12);
    final weR = Logic(name: 'req_we');
    final wdataR = Logic(name: 'req_wdata', width: 32);
    final selR = Logic(name: 'req_sel', width: 4);
    Sequential(clk, reset: reset, [
      act < stb & ~ackR & ~act,
      If(~act, then: [addrR < addr, weR < we, wdataR < wdata, selR < sel]),
    ]);
    final latch = (stb & ~ackR & ~act).named('req_latch');
    final addrIn = addr;
    final weIn = we;
    addr = addrR;
    we = weR;
    wdata = wdataR;
    sel = selR;

    Logic c(int v, int w) => Const(v, width: w);

    // Byte b of the write data where `sel` selects it, else of [old].
    Logic merge(Logic old) => [
      for (var b = 0; b < (old.width + 7) ~/ 8; b++)
        mux(
          sel[b],
          wdata.getRange(8 * b, 8 * b + _bits(old.width, b)),
          old.getRange(8 * b, 8 * b + _bits(old.width, b)),
        ),
    ].rswizzle();
    // Write data with the bytes that `sel` does not select set to 0.
    final wMasked = [
      for (var b = 0; b < 4; b++)
        mux(sel[b], wdata.getRange(8 * b, 8 * b + 8), c(0, 8)),
    ].rswizzle().named('w_masked');
    Logic wBit(int i) => wMasked[i];

    final access = act;
    // The write select of each register is decoded when the request is
    // latched, so it is one flop in the access cycle.
    final wrSel = <int, Logic>{};
    Logic wrAt(int off) => wrSel.putIfAbsent(off, () {
      final f = Logic(name: 'wr_${_hex(off)}');
      Sequential(clk, [f < latch & weIn & addrIn.eq(c(off, 12))], reset: reset);
      return f;
    });

    // CTRL.
    final txEnR = Logic(name: 'ctrl_tx_en');
    final rxEnR = Logic(name: 'ctrl_rx_en');
    final keepBadR = Logic(name: 'ctrl_keep_bad');
    final gig = config.maxSpeed == HarborEthSpeed.mbps1000;
    final speedR = Logic(name: 'ctrl_speed', width: gig ? 2 : 1);
    final promiscR = config.promiscuous ? Logic(name: 'ctrl_promisc') : null;
    final softPend = Logic(name: 'soft_pend');
    final softR = Logic(name: 'soft_reset_r');
    final speed2 = gig ? speedR : speedR.zeroExtend(2);
    final ctrlRead = [
      c(0, 24),
      softPend,
      c(1, 1),
      speed2,
      keepBadR,
      promiscR ?? c(0, 1),
      rxEnR,
      txEnR,
    ].swizzle().named('ctrl_read');

    // `tx_en` and `rx_en` are flops, one cycle after CTRL. They are low
    // while `soft_pend` or `soft_reset` was high in the cycle before. The
    // pulse waits until both are low, so no DMA starts a frame in the
    // cycles before the DMAs reset.
    final txEnFlop = Logic(name: 'tx_en_r');
    final rxEnFlop = Logic(name: 'rx_en_r');
    Sequential(clk, [
      txEnFlop < txEnR & ~softPend & ~softR,
      rxEnFlop < rxEnR & ~softPend & ~softR,
    ], reset: reset);
    final softFire =
        (softPend & ~txBusy & ~rxBusy & busIdle & ~txEnFlop & ~rxEnFlop).named(
          'soft_fire',
        );
    addOutput('tx_en') <= txEnFlop;
    addOutput('rx_en') <= rxEnFlop;
    addOutput('keep_bad') <= keepBadR;
    addOutput('speed', width: 2) <= speed2;
    addOutput('promisc') <= (promiscR ?? c(0, 1));
    addOutput('soft_reset') <= softR;

    // STATUS.
    final txRingErrS = Logic(name: 'st_tx_ring_err');
    final rxRingErrS = Logic(name: 'st_rx_ring_err');
    final txRingErrD = Logic(name: 'tx_ring_err_d');
    final rxRingErrD = Logic(name: 'rx_ring_err_d');
    final txRunning = (txBusy | txPathBusy | (txEnR & ~txRingErr)).named(
      'tx_running',
    );
    final rxRunning = (rxBusy | rxPathBusy | (rxEnR & ~rxRingErr)).named(
      'rx_running',
    );
    final statusRead = [
      c(0, 24),
      busWLast,
      busBadId,
      txClkLost,
      rxClkLost,
      rxRingErrS,
      txRingErrS,
      rxRunning,
      txRunning,
    ].swizzle().named('status_read');
    final txRingRise = (txRingErr & ~txRingErrD).named('tx_ring_rise');
    final rxRingRise = (rxRingErr & ~rxRingErrD).named('rx_ring_rise');

    final txClkClear = Logic(name: 'tx_clk_lost_clear_r');
    final rxClkClear = Logic(name: 'rx_clk_lost_clear_r');
    addOutput('tx_clk_lost_clear') <= txClkClear;
    addOutput('rx_clk_lost_clear') <= rxClkClear;

    // Interrupts.
    final intStatus = Logic(name: 'int_status', width: 5);
    final intEnable = Logic(name: 'int_enable', width: 5);
    final intSet = [
      rxMissed,
      rxErr,
      txErr,
      rxDone,
      txDone,
    ].swizzle().named('int_set');
    final irqR = Logic(name: 'irq_r');
    addOutput('irq') <= irqR;

    // MAC address and multicast hash.
    final macLo = Logic(name: 'mac_lo', width: 32);
    final macHi = Logic(name: 'mac_hi', width: 16);
    addOutput('mac_addr', width: 48) <= [macHi, macLo].swizzle();
    final hashLo = config.multicastHash
        ? Logic(name: 'hash_lo', width: 32)
        : null;
    final hashHi = config.multicastHash
        ? Logic(name: 'hash_hi', width: 32)
        : null;
    addOutput('mc_hash', width: 64) <=
        (config.multicastHash ? [hashHi!, hashLo!].swizzle() : c(0, 64));

    // Rings.
    final lowBits = config.descBytes.bitLength - 1;
    final loW = (aw < 32 ? aw : 32) - lowBits;
    final hiW = aw > 32 ? aw - 32 : 0;
    final rings = [
      for (final (n, lo, size, tail, head, busy) in [
        (
          'tx',
          HarborEthReg.txRingLo,
          HarborEthReg.txRingSize,
          HarborEthReg.txTail,
          txHead,
          txBusy,
        ),
        (
          'rx',
          HarborEthReg.rxRingLo,
          HarborEthReg.rxRingSize,
          HarborEthReg.rxTail,
          rxHead,
          rxBusy,
        ),
      ])
        _Ring(n, lo, size, tail, head, busy, loW, hiW, lowBits, aw),
    ];
    for (final r in rings) {
      addOutput('${r.name}_ring_base', width: aw) <= r.appBase;
      addOutput('${r.name}_ring_size', width: 4) <= r.appSize;
      addOutput('${r.name}_tail', width: iw) <= r.tailOut;
      addOutput('${r.name}_ring_reset') <= r.reset;
    }

    // MDIO.
    final c45 = config.mdioC45;
    final mReg = Logic(name: 'mdio_reg_r', width: 5);
    final mPhy = Logic(name: 'mdio_phy_r', width: 5);
    final mWrite = Logic(name: 'mdio_write_r');
    final mC45 = c45 ? Logic(name: 'mdio_c45_r') : null;
    final mDevad = c45 ? Logic(name: 'mdio_devad_r', width: 5) : null;
    final mData = Logic(name: 'mdio_data_r', width: 16);
    final mAddr = c45 ? Logic(name: 'mdio_addr_r', width: 16) : null;
    final mDiv = Logic(name: 'mdio_div_r', width: HarborEthMdio.divWidth);
    final mStart = Logic(name: 'mdio_start_r');
    addOutput('mdio_start') <= mStart;
    addOutput('mdio_write') <= mWrite;
    addOutput('mdio_c45') <= (mC45 ?? c(0, 1));
    addOutput('mdio_phy', width: 5) <= mPhy;
    addOutput('mdio_reg', width: 5) <= mReg;
    addOutput('mdio_devad', width: 5) <= (mDevad ?? c(0, 5));
    addOutput('mdio_wdata', width: 16) <= mData;
    addOutput('mdio_addr', width: 16) <= (mAddr ?? c(0, 16));
    addOutput('mdio_div', width: HarborEthMdio.divWidth) <= mDiv;
    final mdioBusyRead = (mdioBusy | mStart).named('mdio_busy_read');
    final mCtrlNext = merge(
      [
        c(0, 11),
        mDevad ?? c(0, 5),
        c(0, 4),
        mC45 ?? c(0, 1),
        mWrite,
        mPhy,
        mReg,
      ].swizzle(),
    ).named('mdio_ctrl_next');
    final mdioCtrlRead = [
      c(0, 11),
      mDevad ?? c(0, 5),
      c(0, 2),
      mdioBusyRead,
      c(0, 1),
      mC45 ?? c(0, 1),
      mWrite,
      mPhy,
      mReg,
    ].swizzle().named('mdio_ctrl_read');

    // Counters.
    final counters = <int, Logic>{};
    for (final (off, name, ev) in [
      (HarborEthReg.txFrames, 'tx_frames', evTxFrame),
      (HarborEthReg.rxFrames, 'rx_frames', evRxFrame),
      (HarborEthReg.rxFcsErr, 'rx_fcs_err', evRxFcs),
      (HarborEthReg.rxMissed, 'rx_missed', rxMissed),
      (HarborEthReg.rxOverflow, 'rx_overflow', rxOverflow),
      (HarborEthReg.rxRunt, 'rx_runt', evRxRunt),
      (HarborEthReg.rxOversize, 'rx_oversize', evRxOversize),
    ]) {
      final cnt = Logic(name: 'cnt_$name', width: 32);
      Sequential(clk, reset: reset, [
        If(ev, then: [cnt < cnt + 1]),
      ]);
      counters[off] = cnt;
    }

    // Read mux.
    final reads = <int, Logic>{
      HarborEthReg.id: c(HarborEthReg.idValue, 32),
      HarborEthReg.hwCaps: c(config.hwCaps, 32),
      HarborEthReg.ctrl: ctrlRead,
      HarborEthReg.status: statusRead,
      HarborEthReg.intStatus: intStatus.zeroExtend(32),
      HarborEthReg.intEnable: intEnable.zeroExtend(32),
      HarborEthReg.macLo: macLo,
      HarborEthReg.macHi: macHi.zeroExtend(32),
      if (hashLo != null) HarborEthReg.mcHashLo: hashLo,
      if (hashHi != null) HarborEthReg.mcHashHi: hashHi,
      for (final r in rings) ...{
        r.loOff: [r.lo, c(0, lowBits)].swizzle().zeroExtend(32),
        if (hiW > 0) r.loOff + 4: r.hi!.zeroExtend(32),
        r.sizeOff: r.size.zeroExtend(32),
        r.tailOff: r.tailMasked.zeroExtend(32),
        r.tailOff + 4: r.head.zeroExtend(32),
      },
      HarborEthReg.mdioCtrl: mdioCtrlRead,
      HarborEthReg.mdioData: [mAddr ?? c(0, 16), mData].swizzle(),
      HarborEthReg.mdioDiv: mDiv.zeroExtend(32),
      ...counters,
    };
    final readData = Logic(name: 'read_data', width: 32);
    Combinational([
      Case(
        addr,
        [
          for (final e in reads.entries)
            CaseItem(c(e.key, 12), [readData < e.value]),
        ],
        defaultItem: [readData < c(0, 32)],
      ),
    ]);

    // Ring register writes and their ring_reset pulses.
    for (final r in rings) {
      final baseWrite = wrAt(r.loOff) | wrAt(r.sizeOff);
      final hiWrite = hiW > 0 ? wrAt(r.loOff + 4) : c(0, 1);
      final sizeIn = wdata.getRange(0, 4);
      final sizeClamped = mux(
        sizeIn.eq(0),
        c(1, 4),
        mux(sizeIn.gt(12), c(12, 4), sizeIn),
      );
      final loNext = merge(
        [r.lo, c(0, lowBits)].swizzle().zeroExtend(32),
      ).getRange(lowBits, lowBits + loW);
      final base = [if (hiW > 0) r.hi!, r.lo, c(0, lowBits)].swizzle();
      // The DMA takes a new ring only in idle, where it also applies its
      // ring_reset. Until then it keeps the ring of its frame.
      final apply = (r.pend & ~r.busy).named('${r.name}_ring_apply');
      Sequential(
        clk,
        reset: reset,
        resetValues: {r.size: c(1, 4), r.appSize: c(1, 4)},
        [
          r.reset < (baseWrite | hiWrite | softR),
          If.block([
            Iff(baseWrite | hiWrite | softR, [r.pend < 1]),
            Iff(apply, [r.pend < 0]),
          ]),
          If(apply, then: [r.appBase < base, r.appSize < r.size]),
          If(wrAt(r.loOff), then: [r.lo < loNext]),
          if (hiW > 0)
            If(
              wrAt(r.loOff + 4),
              then: [r.hi! < merge(r.hi!.zeroExtend(32)).getRange(0, hiW)],
            ),
          If(wrAt(r.sizeOff) & sel[0], then: [r.size < sizeClamped]),
          If.block([
            Iff(softR | baseWrite | hiWrite, [r.tail < c(0, iw)]),
            Iff(wrAt(r.tailOff), [
              r.tail < merge(r.tail.zeroExtend(32)).getRange(0, iw) & r.mask,
            ]),
          ]),
        ],
      );
    }

    Sequential(
      clk,
      reset: reset,
      resetValues: {mDiv: c(HarborEthReg.mdioDivReset, HarborEthMdio.divWidth)},
      [
        ackR < 0,
        softR < 0,
        txClkClear < 0,
        rxClkClear < 0,
        mStart < 0,
        txRingErrD < txRingErr,
        rxRingErrD < rxRingErr,
        irqR < (intStatus & intEnable).or(),
        If(access, then: [ackR < 1, rdataR < readData]),

        // CTRL.
        If(
          wrAt(HarborEthReg.ctrl) & sel[0],
          then: [
            txEnR < wdata[0],
            rxEnR < wdata[1],
            if (promiscR != null) promiscR < wdata[2],
            keepBadR < wdata[3],
            speedR < wdata.getRange(4, gig ? 6 : 5),
            If(wdata[7], then: [softPend < 1]),
          ],
        ),
        If(softFire, then: [softPend < 0, softR < 1]),

        // STATUS and INT_STATUS.
        If.block([
          Iff(softR, [txRingErrS < 0, rxRingErrS < 0]),
          Else([
            txRingErrS <
                txRingRise |
                    (txRingErrS & ~(wrAt(HarborEthReg.status) & wBit(2))),
            rxRingErrS <
                rxRingRise |
                    (rxRingErrS & ~(wrAt(HarborEthReg.status) & wBit(3))),
          ]),
        ]),
        If(
          wrAt(HarborEthReg.status),
          then: [rxClkClear < wBit(4), txClkClear < wBit(5)],
        ),
        intStatus <
            mux(
              softR,
              c(0, 5),
              intSet |
                  (intStatus &
                      ~mux(
                        wrAt(HarborEthReg.intStatus),
                        wMasked.getRange(0, 5),
                        c(0, 5),
                      )),
            ),
        If(wrAt(HarborEthReg.intEnable), then: [intEnable < merge(intEnable)]),

        // Addresses.
        If(wrAt(HarborEthReg.macLo), then: [macLo < merge(macLo)]),
        If(wrAt(HarborEthReg.macHi), then: [macHi < merge(macHi)]),
        if (hashLo != null)
          If(wrAt(HarborEthReg.mcHashLo), then: [hashLo < merge(hashLo)]),
        if (hashHi != null)
          If(wrAt(HarborEthReg.mcHashHi), then: [hashHi < merge(hashHi)]),

        // MDIO.
        If(
          wrAt(HarborEthReg.mdioCtrl),
          then: [
            mReg < mCtrlNext.getRange(0, 5),
            mPhy < mCtrlNext.getRange(5, 10),
            mWrite < mCtrlNext[10],
            if (mC45 != null) mC45 < mCtrlNext[11],
            if (mDevad != null) mDevad < mCtrlNext.getRange(16, 21),
            If(wBit(12) & ~mdioBusyRead, then: [mStart < 1]),
          ],
        ),
        If.block([
          Iff(mdioRdone, [mData < mdioRdata]),
          Iff(wrAt(HarborEthReg.mdioData), [mData < merge(mData)]),
        ]),
        if (mAddr != null)
          If(
            wrAt(HarborEthReg.mdioData),
            then: [
              mAddr < merge([mAddr, c(0, 16)].swizzle()).getRange(16, 32),
            ],
          ),
        If(wrAt(HarborEthReg.mdioDiv), then: [mDiv < merge(mDiv)]),
      ],
    );
  }

  static int _bits(int width, int b) {
    final lo = b * 8;
    return (lo + 8 > width ? width : lo + 8) - lo;
  }

  static String _hex(int v) => v.toRadixString(16).padLeft(3, '0');
}

/// Registers of one descriptor ring.
class _Ring {
  final String name;
  final int loOff;
  final int sizeOff;
  final int tailOff;
  final Logic head;
  final Logic lo;
  final Logic? hi;
  final Logic size;
  final Logic tail;
  final Logic reset;
  final Logic busy;
  final Logic pend;
  final Logic appBase;
  final Logic appSize;
  late final Logic mask;
  late final Logic tailMasked;
  late final Logic tailOut;

  _Ring(
    this.name,
    this.loOff,
    this.sizeOff,
    this.tailOff,
    this.head,
    this.busy,
    int loW,
    int hiW,
    int lowBits,
    int aw,
  ) : pend = Logic(name: '${name}_ring_pend'),
      appBase = Logic(name: '${name}_ring_base_applied', width: aw),
      appSize = Logic(name: '${name}_ring_size_applied', width: 4),
      lo = Logic(name: '${name}_ring_lo', width: loW),
      hi = hiW > 0 ? Logic(name: '${name}_ring_hi', width: hiW) : null,
      size = Logic(name: '${name}_ring_size_r', width: 4),
      tail = Logic(name: '${name}_tail_r', width: HarborEthDmaTx.indexWidth),
      reset = Logic(name: '${name}_ring_reset_r') {
    const iw = HarborEthDmaTx.indexWidth;
    // Ones in the low `size` bits.
    Logic ones(Logic n) =>
        ~(Const((1 << iw) - 1, width: iw) << n.zeroExtend(iw));
    mask = ones(size).named('${name}_mask');
    tailMasked = (tail & mask).named('${name}_tail_masked');
    tailOut = (tail & ones(appSize)).named('${name}_tail_out');
  }
}
