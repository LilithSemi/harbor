import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

import 'sdram_phy_ecp5_harness.dart';
import 'sdram_pin_model.dart';

/// [HarborSdram] driven as a wishbone master, with [SdramPinModel] attached
/// to its `sdram_*` ports and its `sdram_dq` pad net. Mirrors
/// `SdramEngineStack`, but through the wishbone front end instead of the
/// raw [SdramPortInterface].
class SdramWbStack {
  final int sysClockHz;
  final int memClockHz;
  final bool busClockSync;
  final bool postedWrites;
  final bool fastInit;
  final double fpgaToSdramNs;
  final HarborSdramConfig config;
  final HarborSdramCycles cycles;
  final int busAddressWidth;

  late final HarborSdram sdram;
  late final SdramPinModel model;
  late final Logic sysClk;
  late final Logic memClk;
  final Logic sysReset = Logic(name: 'sys_reset');
  final Logic memReset = Logic(name: 'mem_reset_drv');

  late final Logic cyc, we, adr, datW, sel;

  late final Future<void> simRun;

  /// Shadow memory, 32-bit word keyed by byte address, for the scoreboard.
  final Map<int, int> _mem = {};

  SdramWbStack({
    required this.sysClockHz,
    required this.memClockHz,
    this.busClockSync = false,
    this.postedWrites = false,
    this.fastInit = true,
    this.fpgaToSdramNs = 4.6,
    HarborSdramAddressMap map = HarborSdramAddressMap.rowBankCol,
  }) : config = _config(map, fastInit),
       cycles = HarborSdramCycles(
         _config(map, fastInit),
         clockHz: memClockHz,
         phyMaxClockHz: SdramPhyEcp5.maxClockHzLvcmos33,
       ),
       busAddressWidth = _config(map, fastInit).sizeBytes.bitLength;

  static HarborSdramConfig _config(HarborSdramAddressMap map, bool fastInit) {
    const base = HarborSdramConfig.as4c16m16sb6();
    return base.copyWith(
      addressMap: map,
      timing: base.timing.copyWith(powerUpNs: fastInit ? 2000 : null),
    );
  }

  int get sysPeriodPs => 1000000000000 ~/ sysClockHz;
  int get memPeriodPs => 1000000000000 ~/ memClockHz;

  /// Splits a word address into (bank, row, col) per [config].
  (int, int, int) split(int wordAddr) {
    final col = wordAddr & ((1 << config.colWidth) - 1);
    final hi = wordAddr >> config.colWidth;
    if (config.addressMap == HarborSdramAddressMap.rowBankCol) {
      return (hi & (config.banks - 1), hi >> config.bankBits, col);
    }
    return (hi >> config.rowWidth, hi & ((1 << config.rowWidth) - 1), col);
  }

  /// The device's power-up seed for the 32-bit word at [byteAddr], read as
  /// low word then high word.
  int _initialWord32(int byteAddr) {
    final wordAddr = (byteAddr >> 1) & ~1;
    final (b0, r0, c0) = split(wordAddr);
    final (b1, r1, c1) = split(wordAddr + 1);
    return SdramPinModel.initialWord(b0, r0, c0) |
        (SdramPinModel.initialWord(b1, r1, c1) << 16);
  }

  int _mergeSel(int oldVal, int newVal, int selMask) {
    var result = oldVal;
    for (var byte = 0; byte < 4; byte++) {
      if ((selMask >> byte) & 1 == 1) {
        final mask = 0xFF << (byte * 8);
        result = (result & ~mask) | (newVal & mask);
      }
    }
    return result;
  }

  /// The scoreboard's own expectation for the 32-bit word at [byteAddr].
  int peek32(int byteAddr) => _mem[byteAddr] ?? _initialWord32(byteAddr);

  /// Every model error so far.
  List<String> get errors => model.errors;

  Future<void> start() async {
    sysClk = SimpleClockGenerator(sysPeriodPs).clk;
    memClk = busClockSync ? sysClk : SimpleClockGenerator(memPeriodPs).clk;

    cyc = Logic(name: 'wb_cyc');
    we = Logic(name: 'wb_we');
    adr = Logic(name: 'wb_adr', width: busAddressWidth);
    datW = Logic(name: 'wb_dat_w', width: 32);
    sel = Logic(name: 'wb_sel', width: 4);

    sysReset.inject(1);
    memReset.inject(1);
    cyc.inject(0);
    we.inject(0);
    adr.inject(0);
    datW.inject(0);
    sel.inject(0xf);

    sdram = HarborSdram(
      config: config,
      baseAddress: 0,
      clockHz: memClockHz,
      busClockSync: busClockSync,
      postedWrites: postedWrites,
      target: const HarborFpgaTarget.ecp5(
        device: 'LFE5U-85F',
        package: 'CABGA381',
      ),
    );

    sdram.input('clk').srcConnection! <= sysClk;
    sdram.input('reset').srcConnection! <= sysReset;
    if (!busClockSync) {
      sdram.input('mem_clk').srcConnection! <= memClk;
    }
    sdram.input('mem_reset').srcConnection! <= memReset;
    sdram.input('bus_CYC').srcConnection! <= cyc;
    sdram.input('bus_STB').srcConnection! <= cyc;
    sdram.input('bus_WE').srcConnection! <= we;
    sdram.input('bus_ADR').srcConnection! <= adr;
    sdram.input('bus_DAT_MOSI').srcConnection! <= datW;
    sdram.input('bus_SEL').srcConnection! <= sel;

    await sdram.build();

    final phy = sdram.subModules.whereType<SdramPhyEcp5>().single;
    final bbs = {for (final m in phy.subModules.whereType<Ecp5Bb>()) m.name: m};
    final dqBbs = [for (var i = 0; i < 16; i++) bbs['dq_bb_$i']!];
    final tAcNs = cycles.casLatency == 3 ? 5.0 : 6.0;
    if (!sdramPhyCaptureOk(
      periodPs: memPeriodPs,
      tAcNs: tAcNs,
      fpgaToSdramNs: fpgaToSdramNs,
      phy: const HarborSdramPhyConfig(),
    )) {
      throw ArgumentError('fpgaToSdramNs $fpgaToSdramNs misses the window');
    }

    var rules = const SdramModelRules.as4c16m16sb6();
    if (fastInit) rules = rules.copyWith(powerUpNs: 2000);
    final periodNs = cycles.refi * memPeriodPs / 1000;
    model = SdramPinModel(
      clk: sdram.output('sdram_clk'),
      cke: sdram.output('sdram_cke'),
      csN: sdram.output('sdram_cs_n'),
      rasN: sdram.output('sdram_ras_n'),
      casN: sdram.output('sdram_cas_n'),
      weN: sdram.output('sdram_we_n'),
      ba: sdram.output('sdram_ba'),
      addr: sdram.output('sdram_addr'),
      dqm: sdram.output('sdram_dqm'),
      dq: sdram.inOutSource('sdram_dq') as LogicNet,
      rules: rules,
      fpgaToSdramNs: fpgaToSdramNs,
      fpgaDqOe: [for (final bb in dqBbs) ~bb.input('T')].rswizzle(),
      fpgaDqOut: [for (final bb in dqBbs) bb.input('I')].rswizzle(),
      refreshPolicy: SdramRefreshPolicy(
        maxPostponed: cycles.maxPostponed,
        maxPulledIn: cycles.maxPulledIn,
        periodNs: periodNs,
        maxLatencyNs: 256 * memPeriodPs / 1000,
        initRefreshes: cycles.initRefreshes,
      ),
    );

    simRun = Simulator.run();
    unawaited(simRun);

    for (var i = 0; i < 8; i++) {
      await sysClk.nextPosedge;
    }
    sysReset.put(0);
    for (var i = 0; i < 8; i++) {
      await memClk.nextPosedge;
    }
    memReset.put(0);
    while (sdram.output('init_done').value != LogicValue.one) {
      await memClk.nextPosedge;
    }
  }

  Future<void> _wait(Logic clk) async {
    await clk.nextPosedge;
  }

  /// Writes [data] at byte address [byteAddr], masked by [selMask], and
  /// updates the scoreboard the same way.
  Future<void> write32(int byteAddr, int data, {int selMask = 0xf}) async {
    adr.inject(byteAddr);
    datW.inject(data);
    sel.inject(selMask);
    we.inject(1);
    cyc.inject(1);
    await _wait(sysClk);
    for (var n = 0; sdram.output('bus_ACK').value.toInt() != 1; n++) {
      if (n > 20000) throw StateError('no ack at byte address $byteAddr');
      await _wait(sysClk);
    }
    cyc.inject(0);
    we.inject(0);
    await _wait(sysClk);
    _mem[byteAddr] = _mergeSel(peek32(byteAddr), data, selMask);
  }

  /// Reads the 32-bit word at byte address [byteAddr].
  Future<int> read32(int byteAddr) async {
    adr.inject(byteAddr);
    we.inject(0);
    sel.inject(0xf);
    cyc.inject(1);
    await _wait(sysClk);
    for (var n = 0; sdram.output('bus_ACK').value.toInt() != 1; n++) {
      if (n > 20000) throw StateError('no ack at byte address $byteAddr');
      await _wait(sysClk);
    }
    final v = sdram.output('bus_DAT_MISO').value.toInt();
    cyc.inject(0);
    await _wait(sysClk);
    return v;
  }

  /// The wishbone front end inside [sdram].
  SdramWishbonePort get wbPort =>
      sdram.subModules.whereType<SdramWishbonePort>().single;

  /// Puts a request on the bus and returns at once.
  void drive({required int byteAddr, required bool write, int data = 0}) {
    adr.inject(byteAddr);
    datW.inject(data);
    sel.inject(0xf);
    we.inject(write ? 1 : 0);
    cyc.inject(1);
  }

  /// Drops cyc.
  void release() {
    cyc.inject(0);
    we.inject(0);
  }

  /// Waits up to [limit] bus cycles for an ack and returns the read data,
  /// or null on a timeout.
  Future<int?> waitAck({int limit = 4000}) async {
    for (var i = 0; i < limit; i++) {
      await sysClk.nextPosedge;
      if (sdram.output('bus_ACK').value == LogicValue.one) {
        return sdram.output('bus_DAT_MISO').value.toInt();
      }
    }
    return null;
  }

  /// Waits until [signal] is high on a memory clock edge.
  Future<void> waitHigh(Logic signal, {int limit = 4000}) async {
    for (var i = 0; i < limit; i++) {
      await memClk.nextPosedge;
      if (signal.value == LogicValue.one) return;
    }
    throw StateError('${signal.name} did not go high');
  }

  /// Waits [n] memory clock cycles.
  Future<void> idle(int n) async {
    for (var i = 0; i < n; i++) {
      await memClk.nextPosedge;
    }
  }

  /// Marks [byteAddr] as unknown in the scoreboard after an aborted write.
  void forget(int byteAddr) => _mem.remove(byteAddr);

  /// Runs the model's end checks and stops the simulation. A test must
  /// call this before returning: otherwise the background [simRun] races
  /// the next test's [Simulator.reset].
  Future<void> stop() async {
    model.finish();
    await Simulator.endSimulation();
  }
}
