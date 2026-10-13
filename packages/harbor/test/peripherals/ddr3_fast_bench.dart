import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/ddr3_mode_registers.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/fabric/axi4_fabric_harness.dart' show exposeInterface;
import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';

/// The AX7203 DDR3 at 400 MHz CK, so `ddr_clk` is 100 MHz.
const ax7203 = HarborDdrConfig.ax7203();
const ax7203CkPs = 2500;
final ax7203Params = DdrParams.fromConfig(ax7203, ckPeriodPs: ax7203CkPs);

/// The PHY and the DRAM together, at the controller side of the PHY, on the
/// controller clock. For a [HarborDdr3] built with `fastSim`.
///
/// It decodes the command slots of each controller cycle. A write stores
/// the controller word [writeDelay] cycles after its WR command, with the
/// DM bytes left out. A read puts the stored word on the ISERDES input
/// [readLatency] cycles after its RD command, and a changing junk pattern
/// in every other cycle, so a capture on the wrong cycle reads wrong data.
/// A word never written reads as the [WordMemory] start values of a 32-bit
/// bus. A byte that DM masks may be X. It checks that RD and WR go to an open row and that refresh finds
/// every bank closed.
class Ddr3PhyWordModel {
  final DdrParams p;
  final int readLatency;
  final int writeDelay;
  final Logic cmd;
  final Logic data;
  final Logic dm;
  final Logic iserdes;
  final errors = <String>[];
  final Map<int, BigInt> mem = {};
  final List<int?> _open;
  final Map<int, int> _rdDue = {};
  final Map<int, int> _wrDue = {};
  int cycle = 0;
  int reads = 0;
  int writes = 0;
  int activates = 0;
  int refreshes = 0;

  int get _cmdLen => 4 + 3 + p.baBits + p.rowBits;
  int get _colLo => p.colBits - 3;
  int get _wordBits => p.wbDataBits;

  Ddr3PhyWordModel(
    this.p, {
    required Logic clk,
    required this.cmd,
    required this.data,
    required this.dm,
    required this.iserdes,
    this.readLatency = 6,
    this.writeDelay = 3,
  }) : _open = List.filled(1 << p.baBits, null) {
    clk.negedge.listen((_) => _step());
  }

  /// The controller word address of a bank, row and column.
  int wordAddr(int bank, int row, int col) =>
      (row << (p.baBits + _colLo)) | (bank << _colLo) | (col >> 3);

  /// The 32-bit lanes of a word never written.
  BigInt startWord(int wa) {
    final lanes = _wordBits ~/ 32;
    var v = BigInt.zero;
    for (var i = lanes - 1; i >= 0; i--) {
      final w = wa * lanes + i;
      v = (v << 32) | BigInt.from((w * 0x9e3779b1 + 0x1234567) & 0xffffffff);
    }
    return v;
  }

  void _step() {
    final n = cycle++;
    final wa = _wrDue.remove(n);
    if (wa != null) {
      final d = data.value;
      final m = dm.value;
      var old = mem[wa] ?? startWord(wa);
      for (var b = 0; b < _wordBits ~/ 8; b++) {
        final mb = m[b];
        if (!mb.isValid) {
          errors.add('cycle $n: DM bit $b is X');
          continue;
        }
        if (mb.toBool()) continue;
        final byte = d.getRange(8 * b, 8 * b + 8);
        if (!byte.isValid) {
          errors.add('cycle $n: written byte $b is X');
          continue;
        }
        final bm = BigInt.from(0xff) << (8 * b);
        old = (old & ~bm) | (byte.toBigInt() << (8 * b));
      }
      mem[wa] = old;
    }
    final v = cmd.value;
    if (v.isValid) {
      for (var s = 0; s < p.serdesRatio; s++) {
        _slot(n, v.getRange(_cmdLen * s, _cmdLen * (s + 1)));
      }
    }
    final ra = _rdDue.remove(n);
    final junk =
        (BigInt.from(n * 0x2545f491 + 0x5a5a) << 64) |
        BigInt.from(n ^ 0x3c3c3c3c);
    iserdes.inject(
      LogicValue.ofBigInt(
        ra == null ? junk : (mem[ra] ?? startWord(ra)),
        _wordBits,
      ),
    );
  }

  void _slot(int n, LogicValue s) {
    if (s[_cmdLen - 1].toInt() != 0) return;
    final op = s.getRange(_cmdLen - 4, _cmdLen - 1).toInt();
    final bank = s.getRange(p.rowBits, p.rowBits + p.baBits).toInt();
    final addr = s.getRange(0, p.rowBits).toInt();
    switch (op) {
      case Ddr3Cmd.act:
        if (_open[bank] != null) errors.add('cycle $n: ACT to open bank $bank');
        _open[bank] = addr;
        activates++;
      case Ddr3Cmd.pre:
        if (addr & (1 << 10) != 0) {
          _open.fillRange(0, _open.length, null);
        } else {
          _open[bank] = null;
        }
      case Ddr3Cmd.ref:
        if (_open.any((r) => r != null)) {
          errors.add('cycle $n: REF with a bank open');
        }
        refreshes++;
      case final c when c == Ddr3Cmd.rd & 7 || c == Ddr3Cmd.wr & 7:
        final row = _open[bank];
        if (row == null) {
          errors.add(
            'cycle $n: ${c == Ddr3Cmd.rd & 7 ? 'RD' : 'WR'} to '
            'closed bank $bank',
          );
          return;
        }
        final wa = wordAddr(bank, row, addr & ((1 << p.colBits) - 1));
        if (c == Ddr3Cmd.rd & 7) {
          _rdDue[n + readLatency] = wa;
          reads++;
        } else {
          _wrDue[n + writeDelay] = wa;
          writes++;
        }
    }
  }
}

/// Task 8's line fetcher on a memory master waist, copied here because
/// this tree has the Wishbone fetcher only. Reads [words] 32-bit words
/// from [fetchAddr] with INCR requests of up to [burstWords] beats that
/// never cross 4 KB, as many in flight as the waist takes.
class WaistLineFetcher extends Module {
  Logic get done => output('done');
  Logic get busy => output('busy');
  Logic get wrEn => output('wr_en');

  WaistLineFetcher({
    required Logic clk,
    required Logic reset,
    required Logic fetchStart,
    required Logic fetchAddr,
    required Logic words,
    required HarborMemoryWaist waist,
    int burstWords = 16,
    super.name = 'line_fetcher',
  }) : super(definitionName: 'WaistLineFetcher_b$burstWords') {
    const ww = 17;
    const lenW = HarborMemoryWaistConfig.lenWidth;
    final idW = waist.config.idWidth;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    fetchStart = addInput('fetch_start', fetchStart);
    fetchAddr = addInput('fetch_addr', fetchAddr, width: 32);
    words = addInput('words', words, width: 16);
    addOutput('wr_en');
    addOutput('busy');
    addOutput('done');
    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.provider, uniquify: (n) => 'm_$n');

    Logic minOf(Logic a, Logic b) => mux(a.lt(b), a, b);
    Logic beatsFor(Logic a, Logic remain) {
      final off = a.getRange(2, 12).zeroExtend(ww);
      final toBoundary = Const(1024, width: ww) - off;
      return minOf(minOf(remain, Const(burstWords, width: ww)), toBoundary);
    }

    final reading = Logic(name: 'reading');
    final reqValid = Logic(name: 'req_valid_reg');
    final addr = Logic(name: 'addr', width: 32);
    final len = Logic(name: 'len', width: lenW);
    final reqLeft = Logic(name: 'req_left', width: ww);
    final rdLeft = Logic(name: 'rd_left', width: ww);
    final doneReg = Logic(name: 'done_reg');
    final total = words.zeroExtend(ww);
    final firstBeats = beatsFor(fetchAddr, total);
    final reqFire = reqValid & m.reqReady;
    final beatsThis = len.zeroExtend(ww) + Const(1, width: ww);
    final nextAddr = addr + (beatsThis.zeroExtend(32) << 2);
    final nextBeats = beatsFor(nextAddr, reqLeft);
    final rdataFire = m.rdataValid;

    m.reqValid <= reqValid;
    m.reqId <= Const(0, width: idW);
    m.reqWrite <= Const(0);
    m.reqAddr <= addr;
    m.reqLen <= len;
    m.reqSize <= Const(2, width: 3);
    m.reqBurst <= Const(HarborMemoryBurst.incr.value, width: 2);
    m.wdataValid <= Const(0);
    m.wdataData <= Const(0, width: 32);
    m.wdataStrb <= Const(0, width: 4);
    m.wdataLast <= Const(0);
    m.wrespReady <= Const(1);
    m.rdataReady <= Const(1);
    output('wr_en') <= rdataFire;
    output('busy') <= reading;
    output('done') <= doneReg;

    Sequential(clk, reset: reset, [
      doneReg < 0,
      If(
        ~reading,
        then: [
          If(
            fetchStart,
            then: [
              addr < fetchAddr,
              len < (firstBeats - 1).getRange(0, lenW),
              reqLeft < (total - firstBeats),
              reqValid < words.neq(0),
              rdLeft < total,
              reading < words.neq(0),
            ],
          ),
        ],
        orElse: [
          If(
            reqFire,
            then: [
              addr < nextAddr,
              len < (nextBeats - 1).getRange(0, lenW),
              reqValid < reqLeft.neq(0),
              reqLeft < (reqLeft - nextBeats),
            ],
          ),
          If(
            rdataFire,
            then: [
              rdLeft < (rdLeft - Const(1, width: ww)),
              If(rdLeft.eq(1), then: [reading < 0, doneReg < 1]),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// A display master: a [WaistLineFetcher] behind an AXI4 master port `bus`.
class DisplayMaster extends BridgeModule {
  DisplayMaster({
    int outstanding = 4,
    int burstWords = 16,
    String name = 'disp',
  }) : super('DisplayMaster_n${outstanding}_b$burstWords', name: name) {
    for (final p in ['clk', 'reset', 'fetch_start']) {
      createPort(p, PortDirection.input);
    }
    createPort('fetch_addr', PortDirection.input, width: 32);
    createPort('words', PortDirection.input, width: 16);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      config: HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: outstanding,
      ),
      clk: input('clk'),
      reset: input('reset'),
    );
    final f = WaistLineFetcher(
      clk: input('clk'),
      reset: input('reset'),
      fetchStart: input('fetch_start'),
      fetchAddr: input('fetch_addr'),
      words: input('words'),
      waist: port.waist,
      burstWords: burstWords,
    );
    for (final p in ['done', 'busy', 'wr_en']) {
      addOutput(p) <= f.output(p);
    }
  }
}

/// A fabric master the test drives on `<name>_*`.
class CoreCfg {
  final String name;
  final int idWidth;
  final int outstanding;
  final int? readChannel;

  /// AXI4 exclusive slots, as in [HarborFabricMaster.exclusiveIds]. With
  /// any core exclusive, the DDR3 gets a monitor.
  final int? exclusiveIds;
  const CoreCfg(
    this.name,
    this.idWidth,
    this.outstanding, {
    this.readChannel,
    this.exclusiveIds,
  });
}

/// AXI4 masters, an AXI4 crossbar and a fast sim AX7203 [HarborDdr3] with
/// [readChannels] read channels and [outstanding] requests per channel.
/// The fabric runs on `clk` and the DDR3 front end on `ddr_clk`.
class Ddr3FabricBench extends BridgeModule {
  late final HarborDdr3 ddr;
  final bool display;

  Ddr3FabricBench({
    required List<CoreCfg> cores,
    required int readChannels,
    required int outstanding,
    this.display = false,
    int readGap = 1,
    int displayOutstanding = 4,
    int? displayReadChannel,
    HarborFabricTopology topology = HarborFabricTopology.crossbar,
  }) : super(
         'Ddr3FabricBench_c${readChannels}_n${outstanding}_'
         '${cores.length}${display ? 'd' : ''}'
         '${cores.any((c) => (c.exclusiveIds ?? 0) != 0) ? 'x' : ''}',
         name: 'top',
       ) {
    for (final p in ['clk', 'reset', 'ddr_clk', 'ddr_reset']) {
      createPort(p, PortDirection.input);
    }
    final masters = <HarborFabricMaster>[];
    for (final c in cores) {
      final intf = Axi4Interface(
        addressWidth: 32,
        dataWidth: 32,
        idWidth: c.idWidth,
      );
      exposeInterface(this, intf, c.name, PairDirection.fromProvider);
      masters.add(
        HarborFabricMaster(
          name: c.name,
          interface: intf,
          outstanding: c.outstanding,
          readChannel: c.readChannel,
          exclusiveIds: c.exclusiveIds,
        ),
      );
    }
    if (display) {
      createPort('disp_fetch_start', PortDirection.input);
      createPort('disp_fetch_addr', PortDirection.input, width: 32);
      createPort('disp_words', PortDirection.input, width: 16);
      final d = addSubModule(DisplayMaster(outstanding: displayOutstanding));
      d.input('clk').srcConnection! <= input('clk');
      d.input('reset').srcConnection! <= input('reset');
      d.input('fetch_start').srcConnection! <= input('disp_fetch_start');
      d.input('fetch_addr').srcConnection! <= input('disp_fetch_addr');
      d.input('words').srcConnection! <= input('disp_words');
      for (final p in ['done', 'busy', 'wr_en']) {
        addOutput('disp_$p') <= d.output(p);
      }
      masters.add(
        HarborFabricMaster(
          name: 'disp',
          interface: d.interface('bus').interface,
          outstanding: displayOutstanding,
          readChannel: displayReadChannel,
        ),
      );
    }
    final idW = HarborAxi4Fabric.fullIdWidthOf(masters);
    final exclusive = HarborAxi4Fabric.exclusiveOf(masters);
    ddr = addSubModule(
      HarborDdr3(
        config: ax7203,
        baseAddress: 0,
        clockHz: 100000000,
        busAddressWidth: 32,
        busDataWidth: 32,
        ckPeriodPs: ax7203CkPs,
        protocol: HarborFabricKind.axi4,
        idWidth: idW,
        exclusive: exclusive,
        readChannels: readChannels,
        outstanding: outstanding,
        fastSim: true,
        readGap: readGap,
        target: const HarborFpgaTarget.artix7(
          device: 'xc7a200t',
          package: 'fbg484',
        ),
      ),
    );
    for (final p in ['clk', 'reset', 'ddr_clk', 'ddr_reset']) {
      ddr.input(p).srcConnection! <= input(p);
    }
    for (final p in [
      'ddr_ck_fast',
      'ddr_ck90_fast',
      'ddr_ck_dqs_fast',
      'ddr_idelay_ref',
    ]) {
      ddr.input(p).srcConnection! <= Const(0);
    }
    addOutput('bus_error') <= ddr.output('bus_error');
    for (final p in ['phy_cmd', 'phy_data', 'phy_dm']) {
      addOutput(p, width: ddr.output(p).width) <= ddr.output(p);
    }
    ddr.input('phy_iserdes_data').srcConnection! <=
        addInput(
          'phy_iserdes_data',
          Logic(width: ddr.input('phy_iserdes_data').width),
          width: ddr.input('phy_iserdes_data').width,
        );
    final fabric = HarborFabric.build(
      kind: HarborFabricKind.axi4,
      topology: topology,
      clk: input('clk'),
      reset: input('reset'),
      masters: masters,
      slaves: [
        HarborFabricSlave(
          name: 'ddr',
          range: BusAddressRange(0, ax7203.size),
          interface: ddr.interface('bus').interface,
          readInterfaces: [
            for (var k = 1; k < readChannels; k++)
              ddr.interface('bus_r$k').interface,
          ],
          outstanding: outstanding,
          exclusive: exclusive,
        ),
      ],
    );
    addOutput('fabric_error') <= fabric.busError;
  }
}

/// A running [Ddr3FabricBench] with a manager per core and the PHY model.
class Ddr3FabricRun {
  final Ddr3FabricBench top;
  final Sim sim;
  final Logic ddrClk;
  final Ddr3PhyWordModel model;
  final Map<String, AxiManager> managers;
  final List<String> errors = [];

  Ddr3FabricRun._(this.top, this.sim, this.ddrClk, this.model, this.managers);

  /// Builds and starts [top], with fabric and memory clock periods
  /// [fabricPeriod] and [ddrPeriod], and waits for the controller to open
  /// its bus. [stall] is the VALID gap and READY stall chance of the cores.
  static Future<Ddr3FabricRun> start(
    Ddr3FabricBench top, {
    int seed = 1,
    double stall = 0.2,
    int fabricPeriod = 10,
    int ddrPeriod = 10,
    List<String> cores = const [],
  }) async {
    final fabricClk = SimpleClockGenerator(fabricPeriod).clk;
    final ddrClk = SimpleClockGenerator(ddrPeriod).clk;
    for (final input in top.inputs.values) {
      if (input.name != 'clk' && input.name != 'ddr_clk') {
        input.srcConnection!.put(0);
      }
    }
    top.input('clk').srcConnection! <= fabricClk;
    top.input('ddr_clk').srcConnection! <= ddrClk;
    await top.build();
    final sim = Sim(top, clk: fabricClk);
    final model = Ddr3PhyWordModel(
      ax7203Params,
      clk: ddrClk,
      cmd: top.output('phy_cmd'),
      data: top.output('phy_data'),
      dm: top.output('phy_dm'),
      iserdes: top.input('phy_iserdes_data').srcConnection!,
    );
    final rng = Random(seed);
    final managers = {
      for (final c in cores)
        c: AxiManager(
          sim,
          c,
          rng,
          awIdle: stall,
          wIdle: stall / 3,
          arIdle: stall,
          stall: stall,
        ),
    };
    final run = Ddr3FabricRun._(top, sim, ddrClk, model, managers);
    for (final c in cores) {
      for (final (v, r) in [('B', 'B'), ('R', 'R')]) {
        StableCheck(sim, '${c}_${v}VALID', '${c}_${r}READY', [
          if (v == 'B') ...['${c}_BID', '${c}_BRESP'],
          if (v == 'R') ...['${c}_RID', '${c}_RDATA', '${c}_RLAST'],
        ], run.errors);
      }
    }
    sim.attach();
    sim.watchEnd();
    top.input('reset').srcConnection!.put(1);
    top.input('ddr_reset').srcConnection!.put(1);
    Simulator.setMaxSimTime(1 << 50);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await ddrClk.nextPosedge;
    }
    top.input('ddr_reset').srcConnection!.inject(0);
    await fabricClk.nextNegedge;
    top.input('reset').srcConnection!.inject(0);
    for (var i = 0; i < 16; i++) {
      await fabricClk.nextNegedge;
    }
    sim.running = true;
    final ctrl = top.ddr.controller!;
    for (var i = 0; ; i++) {
      await ddrClk.nextPosedge;
      final v = ctrl.debug1.value.getRange(0, 7);
      // DONE_CALIBRATE and reset_done.
      if (v.isValid && v.toInt() == 23 + 64) break;
      if (i > 200000) throw StateError('the controller never opened its bus');
    }
    return run;
  }

  /// All errors of the bench, the model and the stability checks.
  List<String> get allErrors => [...errors, ...model.errors];
}
