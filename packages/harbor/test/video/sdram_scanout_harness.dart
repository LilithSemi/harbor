import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../peripherals/sdram_phy_ecp5_harness.dart';
import '../peripherals/sdram_pin_model.dart';

/// A fabric master that the test bench drives one access at a time.
class _BenchMaster extends BridgeModule {
  _BenchMaster(WishboneConfig cfg) : super('BenchMaster', name: 'bench') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('t_cyc', PortDirection.input);
    createPort('t_we', PortDirection.input);
    createPort('t_adr', PortDirection.input, width: 32);
    createPort('t_dat', PortDirection.input, width: 32);
    addOutput('t_ack');
    addOutput('t_dat_r', width: 32);
    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;
    bus.cyc <= input('t_cyc');
    bus.stb <= input('t_cyc');
    bus.we <= input('t_we');
    bus.adr <= input('t_adr');
    bus.datMosi <= input('t_dat');
    bus.sel <= Const(0xF, width: 4);
    output('t_ack') <= bus.ack;
    output('t_dat_r') <= bus.datMiso;
  }
}

/// Fixed overlay inputs of a [BenchScanDisplay].
class BenchOverlay {
  final HarborPixelFormat format;
  final List<int> base;
  final List<int> pitch;
  final int srcX;
  final int srcY;
  final int dstX;
  final int dstY;
  final int width;
  final int height;
  final int alpha;

  const BenchOverlay({
    required this.format,
    required this.base,
    required this.pitch,
    this.srcX = 0,
    this.srcY = 0,
    this.dstX = 0,
    this.dstY = 0,
    required this.width,
    required this.height,
    this.alpha = 128,
  });
}

/// [HarborDualClockDisplay] on a [HarborSdram] scanout port.
///
/// With [driven], the bench drives `update`, `format_sel` and
/// `plane_pitch_0` as a register block does, and the display has the
/// `red`, `green`, `blue` and `update_pending` outputs.
class BenchScanDisplay extends BridgeModule {
  BenchScanDisplay({
    required HarborDisplayTiming timing,
    required int stride,
    List<HarborPixelFormat>? formats,
    List<int> planeBases = const [],
    List<int> planePitches = const [],
    BenchOverlay? overlay,
    bool driven = false,
  }) : super('BenchScanDisplay', name: 'display') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('pixel_clk', PortDirection.input);
    createPort('pixel_reset', PortDirection.input);
    createPort('fb_base', PortDirection.input, width: 32);
    createPort('enable', PortDirection.input);
    createPort('rq_ready', PortDirection.input);
    createPort('rd_valid', PortDirection.input);
    createPort('rd_data', PortDirection.input, width: 16);
    if (driven) {
      createPort('update', PortDirection.input);
      createPort(
        'format_sel',
        PortDirection.input,
        width: (formats!.length - 1).bitLength,
      );
      createPort('plane_pitch_0', PortDirection.input, width: 32);
    }
    final shift = Const(0);
    final xw = max((timing.hTotal - 1).bitLength, timing.hActive.bitLength);
    final yw = max((timing.vTotal - 1).bitLength, timing.vActive.bitLength);
    final d = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: input('pixel_clk'),
      pixelReset: input('pixel_reset'),
      shiftClk: shift,
      shiftReset: shift,
      sysClk: input('clk'),
      sysReset: input('reset'),
      enable: input('enable'),
      update: driven ? input('update') : Const(1),
      fbBase: input('fb_base'),
      rqReady: input('rq_ready'),
      rdValid: input('rd_valid'),
      rdData: input('rd_data'),
      lineStride: formats == null ? stride : null,
      formats: formats,
      formatSel: driven && formats!.length > 1 ? input('format_sel') : null,
      planeBase: [for (final b in planeBases) Const(b, width: 32)],
      planePitch: [
        if (driven)
          input('plane_pitch_0')
        else if (formats != null)
          Const(stride, width: 32),
        for (final p in planePitches) Const(p, width: 32),
      ],
      overlayFormats: overlay == null ? null : [overlay.format],
      overlayEnable: overlay == null ? null : Const(1),
      overlayBase: [
        for (final b in overlay?.base ?? <int>[]) Const(b, width: 32),
      ],
      overlayPitch: [
        for (final p in overlay?.pitch ?? <int>[]) Const(p, width: 32),
      ],
      overlaySrcX: overlay == null ? null : Const(overlay.srcX, width: xw),
      overlaySrcY: overlay == null ? null : Const(overlay.srcY, width: yw),
      overlayDstX: overlay == null ? null : Const(overlay.dstX, width: xw),
      overlayDstY: overlay == null ? null : Const(overlay.dstY, width: yw),
      overlayWidth: overlay == null ? null : Const(overlay.width, width: xw),
      overlayHeight: overlay == null ? null : Const(overlay.height, width: yw),
      overlayAlpha: overlay == null ? null : Const(overlay.alpha, width: 8),
    );
    if (overlay != null) {
      addOutput('overlay_underrun_count', width: 16) <=
          d.output('overlay_underrun_count_0');
    }
    addOutput('rq_valid') <= d.rqValid;
    addOutput('rq_addr', width: 32) <= d.rqAddr;
    addOutput('rq_words', width: d.rqWords.width) <= d.rqWords;
    addOutput('de') <= d.de;
    addOutput('underrun') <= d.underrun;
    addOutput('x', width: d.x.width) <= d.x;
    addOutput('y', width: d.y.width) <= d.y;
    addOutput('pixel_word', width: 32) <= d.pixelWord;
    if (driven) {
      addOutput('red', width: 8) <= d.red;
      addOutput('green', width: 8) <= d.green;
      addOutput('blue', width: 8) <= d.blue;
      addOutput('update_pending') <= d.updatePending;
    }
  }
}

/// An SoC with a bench master on the fabric, a [HarborSdram] (real
/// controller, ecp5 phy, pin-level sdram model) and a display on the
/// sdram scanout port, as in a Glacier SoC.
class SdramScanoutBench {
  static const sdramBase = 0x80000000;

  final HarborDisplayTiming timing;
  final int sysPeriodPs;
  final int memPeriodPs;
  final int pixelPeriodPs;
  final int fbBase;
  final int maxInFlight;

  /// [HarborSdram.readPortStages] of the scanout port.
  final int readPortStages;
  late final int stride;

  /// Pixel formats of a planar display, null for xrgb8888.
  final List<HarborPixelFormat>? formats;

  /// Base and pitch of each plane after plane 0.
  final List<int> planeBases;
  final List<int> planePitches;

  /// The overlay of the display, or null.
  final BenchOverlay? overlay;

  /// True when the bench drives the display controls, see
  /// [BenchScanDisplay].
  final bool driven;
  final fbIn = Logic(name: 'fb_in', width: 32);
  final update = Logic(name: 'update');
  final formatSel = Logic(name: 'format_sel');
  final pitch0 = Logic(name: 'pitch0', width: 32);

  late final HarborSoC soc;
  late final HarborSdram sdram;
  late final SdramPinModel model;
  late final _BenchMaster bench;
  late final BenchScanDisplay display;
  late final Logic sysClk;
  late final Logic memClk;
  late final Logic pixelClk;
  final sysReset = Logic(name: 'sys_reset');
  final memReset = Logic(name: 'mem_reset');
  final pixelReset = Logic(name: 'pixel_reset');
  final enable = Logic(name: 'enable');
  final tCyc = Logic(name: 'tb_cyc');
  final tWe = Logic(name: 'tb_we');
  final tAdr = Logic(name: 'tb_adr', width: 32);
  final tDat = Logic(name: 'tb_dat', width: 32);

  /// Longest bench access, from `cyc` high to `ack`, in system cycles.
  int longestAccess = 0;

  /// Bench accesses done.
  int accesses = 0;

  /// Fetch time of each line, in memory cycles.
  final lineCycles = <int>[];

  /// Every scanout request taken: (byte address, 16-bit words).
  final requests = <(int, int)>[];

  /// Pixels of the frame being scanned, keyed by y * hActive + x.
  final frame = <int, int>{};

  /// Frames completed since start.
  int frames = 0;

  /// Frames in which the underrun flag was seen high.
  int underrunFrames = 0;

  /// The scanout fetcher `busy` output.
  late final Logic fetchBusy;

  /// When true, each frame is checked against memory as it ends. Memory
  /// must not change while this is on.
  bool checkFrames = false;

  /// Frames that differed from memory while [checkFrames] was on, with
  /// their first differences.
  final badFrames = <List<String>>[];

  /// `mem_clk` cycles with `scan_reset` high since [start] ended.
  int scanResetCycles = 0;
  bool _started = false;

  final Map<int, int> _written = {};
  late final HarborSdramConfig _config;

  SdramScanoutBench({
    required this.timing,
    this.sysPeriodPs = 40000,
    this.memPeriodPs = 10000,
    this.pixelPeriodPs = 39722,
    this.fbBase = sdramBase + 0x10000,
    this.maxInFlight = 3,
    this.readPortStages = 0,
    int? stride,
    this.formats,
    this.planeBases = const [],
    this.planePitches = const [],
    this.overlay,
    this.driven = false,
  }) {
    this.stride = stride ?? timing.hActive * 4;
  }

  int get _memHz => 1000000000000 ~/ memPeriodPs;

  /// Byte address of pixel ([x], [y]).
  int pixelAddr(int x, int y) => fbBase + y * stride + x * 4;

  /// The 32-bit word at SoC byte address [addr] in the sdram: the model's
  /// power-up pattern, or what the bench wrote.
  int expected(int addr) {
    final w = _written[addr];
    if (w != null) return w;
    final off = addr - sdramBase;
    int half(int wordAddr) {
      final c = _config;
      final col = wordAddr & ((1 << c.colWidth) - 1);
      final hi = wordAddr >> c.colWidth;
      final bank = hi & (c.banks - 1);
      final row = hi >> c.bankBits;
      return SdramPinModel.initialWord(bank, row, col);
    }

    final wa = (off >> 1) & ~1;
    return half(wa) | (half(wa + 1) << 16);
  }

  Future<void> start() async {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    const base = HarborSdramConfig.as4c16m16sb6();
    _config = base.copyWith(timing: base.timing.copyWith(powerUpNs: 2000));
    final cycles = HarborSdramCycles(
      _config,
      clockHz: _memHz,
      phyMaxClockHz: SdramPhyEcp5.maxClockHzLvcmos33,
    );

    soc = HarborSoC(name: 'ScanPortSoC', compatible: 'test,scanport');
    bench = soc.addMaster(_BenchMaster(cfg), busInterfaceName: 'bus');
    display = BenchScanDisplay(
      timing: timing,
      stride: stride,
      formats: formats,
      planeBases: planeBases,
      planePitches: planePitches,
      overlay: overlay,
      driven: driven,
    );
    soc.addSubModule(display);
    sdram = soc.addPeripheral(
      HarborSdram(
        config: _config,
        baseAddress: sdramBase,
        clockHz: _memHz,
        busAddressWidth: 32,
        scanoutPorts: 1,
        scanoutMaxInFlight: maxInFlight,
        readPortStages: readPortStages,
        target: const HarborFpgaTarget.ecp5(
          device: 'LFE5U-85F',
          package: 'CABGA381',
        ),
      ),
    );
    soc.buildFabric();

    sysClk = SimpleClockGenerator(sysPeriodPs).clk;
    memClk = SimpleClockGenerator(memPeriodPs).clk;
    pixelClk = SimpleClockGenerator(pixelPeriodPs).clk;

    soc.input('clk').srcConnection! <= sysClk;
    soc.input('reset').srcConnection! <= sysReset;
    sdram.input('mem_clk').srcConnection! <= memClk;
    sdram.input('mem_reset').srcConnection! <= memReset;
    bench.input('t_cyc').srcConnection! <= tCyc;
    bench.input('t_we').srcConnection! <= tWe;
    bench.input('t_adr').srcConnection! <= tAdr;
    bench.input('t_dat').srcConnection! <= tDat;
    display.input('pixel_clk').srcConnection! <= pixelClk;
    display.input('pixel_reset').srcConnection! <= pixelReset;
    display.input('fb_base').srcConnection! <=
        (driven ? fbIn : Const(fbBase, width: 32));
    if (driven) {
      display.input('update').srcConnection! <= update;
      display.input('format_sel').srcConnection! <= formatSel;
      display.input('plane_pitch_0').srcConnection! <= pitch0;
      for (final l in [fbIn, update, formatSel, pitch0]) {
        l.inject(0);
      }
    }
    display.input('enable').srcConnection! <= enable;
    display.input('clk').srcConnection! <= sdram.output('scan_clk');
    display.input('reset').srcConnection! <= sdram.output('scan_reset');
    display.input('rq_ready').srcConnection! <= sdram.output('scan0_rq_ready');
    display.input('rd_valid').srcConnection! <= sdram.output('scan0_rd_valid');
    display.input('rd_data').srcConnection! <= sdram.output('scan0_rd_data');
    sdram.input('scan0_rq_valid').srcConnection! <= display.output('rq_valid');
    sdram.input('scan0_rq_addr').srcConnection! <= display.output('rq_addr');
    sdram.input('scan0_rq_words').srcConnection! <= display.output('rq_words');

    for (final s in [sysReset, memReset, pixelReset]) {
      s.inject(1);
    }
    enable.inject(0);
    tCyc.inject(0);
    tWe.inject(0);
    tAdr.inject(0);
    tDat.inject(0);

    await soc.build();

    final phy = sdram.subModules.whereType<SdramPhyEcp5>().single;
    final bbs = {for (final m in phy.subModules.whereType<Ecp5Bb>()) m.name: m};
    final dqBbs = [for (var i = 0; i < 16; i++) bbs['dq_bb_$i']!];
    const fpgaToSdramNs = 4.6;
    final tAcNs = cycles.casLatency == 3 ? 5.0 : 6.0;
    if (!sdramPhyCaptureOk(
      periodPs: memPeriodPs,
      tAcNs: tAcNs,
      fpgaToSdramNs: fpgaToSdramNs,
      phy: const HarborSdramPhyConfig(),
    )) {
      throw ArgumentError('the capture window misses at $memPeriodPs ps');
    }
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
      rules: const SdramModelRules.as4c16m16sb6().copyWith(powerUpNs: 2000),
      fpgaToSdramNs: fpgaToSdramNs,
      fpgaDqOe: [for (final bb in dqBbs) ~bb.input('T')].rswizzle(),
      fpgaDqOut: [for (final bb in dqBbs) bb.input('I')].rswizzle(),
      refreshPolicy: SdramRefreshPolicy(
        maxPostponed: cycles.maxPostponed,
        maxPulledIn: cycles.maxPulledIn,
        periodNs: cycles.refi * memPeriodPs / 1000,
        maxLatencyNs: 256 * memPeriodPs / 1000,
        initRefreshes: cycles.initRefreshes,
      ),
    );

    _watch();
    Simulator.setMaxSimTime(1 << 50);
    unawaited(Simulator.run());

    for (var i = 0; i < 8; i++) {
      await sysClk.nextPosedge;
    }
    sysReset.put(0);
    pixelReset.put(0);
    for (var i = 0; i < 8; i++) {
      await memClk.nextPosedge;
    }
    memReset.put(0);
    while (sdram.output('init_done').value != LogicValue.one) {
      await memClk.nextPosedge;
    }
    enable.put(1);
    _started = true;
  }

  void _watch() {
    Iterable<Module> all(Module m) sync* {
      yield m;
      for (final s in m.subModules) {
        yield* all(s);
      }
    }

    final busy = fetchBusy = all(
      display,
    ).whereType<HarborScanoutFetcher>().single.output('busy');
    final rqValid = display.output('rq_valid');
    final rqReady = sdram.output('scan0_rq_ready');
    final rqAddr = display.output('rq_addr');
    final rqWords = display.output('rq_words');
    var busyFor = 0;
    final scanReset = sdram.output('scan_reset');
    memClk.posedge.listen((_) {
      if (_started && scanReset.value != LogicValue.zero) scanResetCycles++;
      if (rqValid.value == LogicValue.one && rqReady.value == LogicValue.one) {
        requests.add((rqAddr.value.toInt(), rqWords.value.toInt()));
      }
      if (busy.value == LogicValue.one) {
        busyFor++;
      } else if (busyFor > 0) {
        lineCycles.add(busyFor);
        busyFor = 0;
      }
    });

    var access = 0;
    sysClk.posedge.listen((_) {
      if (tCyc.value != LogicValue.one) {
        access = 0;
        return;
      }
      access++;
      if (bench.output('t_ack').value == LogicValue.one) {
        longestAccess = max(longestAccess, access);
        access = 0;
      }
    });

    final de = display.output('de');
    final x = display.output('x');
    final y = display.output('y');
    final word = display.output('pixel_word');
    final under = display.output('underrun');
    var sawUnder = false;
    // The display takes enable at a frame start, so a frame counts only
    // when it showed pixels.
    var shown = false;
    var prevY = -1;
    pixelClk.posedge.listen((_) {
      if (enable.value != LogicValue.one || !y.value.isValid) return;
      final yv = y.value.toInt();
      if (de.value == LogicValue.one) {
        shown = true;
        frame[yv * timing.hActive + x.value.toInt()] = word.value.isValid
            ? word.value.toInt()
            : -1;
      }
      if (under.value == LogicValue.one) sawUnder = true;
      if (prevY == timing.vActive - 1 && yv == timing.vActive && !shown) {
        sawUnder = false;
      } else if (prevY == timing.vActive - 1 && yv == timing.vActive) {
        shown = false;
        frames++;
        if (checkFrames) {
          final bad = frameErrors();
          if (bad.isNotEmpty) badFrames.add(bad);
        }
        if (sawUnder && frames > 1) underrunFrames++;
        sawUnder = false;
      }
      prevY = yv;
    });
  }

  Future<int> _access(int addr, {int? write, int limit = 1 << 20}) async {
    tAdr.inject(addr);
    tDat.inject(write ?? 0);
    tWe.inject(write == null ? 0 : 1);
    tCyc.inject(1);
    for (var n = 0; ; n++) {
      await sysClk.nextPosedge;
      if (bench.output('t_ack').value == LogicValue.one) break;
      if (n > limit) throw StateError('no ack at 0x${addr.toRadixString(16)}');
    }
    final v = bench.output('t_dat_r').value.toInt();
    tCyc.inject(0);
    tWe.inject(0);
    accesses++;
    await sysClk.nextPosedge;
    if (write != null) _written[addr] = write;
    return v;
  }

  Future<void> write(int addr, int data) => _access(addr, write: data);
  Future<int> read(int addr) => _access(addr);

  /// Starts a fabric read of [addr] and resets the fabric while it waits,
  /// so the controller drops that read.
  Future<void> resetDuringRead(int addr) async {
    tAdr.inject(addr);
    tWe.inject(0);
    tCyc.inject(1);
    for (var i = 0; i < 3; i++) {
      await sysClk.nextPosedge;
    }
    sysReset.inject(1);
    for (var i = 0; i < 4; i++) {
      await sysClk.nextPosedge;
    }
    tCyc.inject(0);
    sysReset.inject(0);
    await sysClk.nextPosedge;
  }

  /// Waits until [n] more frames have been scanned.
  Future<void> waitFrames(int n) async {
    final target = frames + n;
    while (frames < target) {
      await pixelClk.nextPosedge;
    }
  }

  /// Pixels of the last captured frame that differ from memory, at most 8.
  List<String> frameErrors() {
    final bad = <String>[];
    for (var y = 0; y < timing.vActive; y++) {
      for (var x = 0; x < timing.hActive; x++) {
        final want = expected(pixelAddr(x, y));
        final got = frame[y * timing.hActive + x];
        if (got != want && bad.length < 8) {
          bad.add(
            '($x,$y) got 0x${got?.toRadixString(16)} '
            'want 0x${want.toRadixString(16)}',
          );
        }
      }
    }
    return bad;
  }

  Future<void> stop() async {
    model.finish();
    await Simulator.endSimulation();
  }
}

/// 640x480 horizontal timing at 25.175 MHz with [lines] active lines, so a
/// line has its full width and deadline but a frame stays short enough to
/// simulate.
HarborDisplayTiming vgaLines(int lines) => HarborDisplayTiming(
  hActive: 640,
  hFrontPorch: 16,
  hSyncWidth: 96,
  hBackPorch: 48,
  vActive: lines,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: 25175000,
);

/// Result of [runFullWidthScanout].
typedef FullWidthResult = ({
  int longestAccess,
  int accessBound,
  List<int> lineCycles,
  double mbPerSecond,
  int underrunFrames,
  int frames,
});

/// Scans 640-pixel lines at 32 bpp with a 3072-byte stride from the sdram
/// scanout port, while the bench master writes every pixel of the frame
/// through the 25 MHz fabric. Checks the frame, the requests and the pin
/// model, and returns the numbers for the caller to assert.
Future<FullWidthResult> runFullWidthScanout({
  required int memPeriodPs,
  int lines = 3,
  int maxInFlight = 3,
  int readPortStages = 0,
}) async {
  final b = SdramScanoutBench(
    timing: vgaLines(lines),
    memPeriodPs: memPeriodPs,
    stride: 3072,
    maxInFlight: maxInFlight,
    readPortStages: readPortStages,
  );
  await b.start();
  if (b.sdram.scanoutStride(640 * 4) != b.stride) {
    throw StateError('stride ${b.stride} is not the sdram row stride');
  }
  await b.waitFrames(1);
  for (var y = 0; y < lines; y++) {
    for (var x = 0; x < 640; x++) {
      await b.write(b.pixelAddr(x, y), (y << 16) | x | 0x5A000000);
    }
  }
  print('filled: ${b.accesses} accesses, ${b.frames} frames');
  final lastAddr = b.pixelAddr(639, lines - 1);
  if (await b.read(lastAddr) != b.expected(lastAddr)) {
    throw StateError('the last pixel did not read back');
  }
  await b.waitFrames(2);

  final bad = b.frameErrors();
  if (bad.isNotEmpty) throw StateError('frame differs from memory: $bad');
  for (final (a, n) in b.requests) {
    if ((a >> 10) != ((a + 2 * n - 1) >> 10)) {
      throw StateError('request at 0x${a.toRadixString(16)} crosses a page');
    }
  }
  if (b.model.errors.isNotEmpty) {
    throw StateError('pin model: ${b.model.errors.take(4)}');
  }
  final memHz = 1000000000000 ~/ memPeriodPs;
  // The bus access with no scanout, from the measured HarborSdram cost,
  // plus the scanout wait at the arbiter in bus cycles and the crossing.
  final base = HarborSimDram.latencyFor(busHz: 25000000, memHz: memHz);
  final waitSys = (b.sdram.busWaitBound * 25000000 + memHz - 1) ~/ memHz;
  final worst = b.lineCycles.reduce(max);
  final mb = 2560 * memHz / worst / 1e6;
  final result = (
    longestAccess: b.longestAccess,
    accessBound: base + waitSys + 4,
    lineCycles: List.of(b.lineCycles),
    mbPerSecond: mb,
    underrunFrames: b.underrunFrames,
    frames: b.frames,
  );
  await b.stop();
  return result;
}

/// Resets the fabric three times, each 1000 `mem_clk` cycles into a line
/// fetch and with a fabric read in flight. A reset that restarted the line
/// fetch would put all three in one line, which then misses its deadline.
/// Throws if `scan_reset` rises, if a frame differs from memory or
/// underruns, or if the fabric does not work after the resets.
Future<void> runFabricResetDuringScanout({required int memPeriodPs}) async {
  const lines = 3;
  final b = SdramScanoutBench(
    timing: vgaLines(lines),
    memPeriodPs: memPeriodPs,
    stride: 3072,
  );
  await b.start();
  await b.waitFrames(2);
  b.checkFrames = true;
  for (var i = 0; i < 3; i++) {
    while (b.fetchBusy.value != LogicValue.one) {
      await b.memClk.nextPosedge;
    }
    for (var c = 0; c < 1000; c++) {
      await b.memClk.nextPosedge;
    }
    if (b.fetchBusy.value != LogicValue.one) {
      throw StateError('the line fetch ended before the reset');
    }
    await b.resetDuringRead(b.pixelAddr(100 * i, 1));
    while (b.fetchBusy.value == LogicValue.one) {
      await b.memClk.nextPosedge;
    }
  }
  await b.waitFrames(2);
  b.checkFrames = false;
  if (b.scanResetCycles != 0) {
    throw StateError('scan_reset was high for ${b.scanResetCycles} cycles');
  }
  if (b.badFrames.isNotEmpty) {
    throw StateError('frames differ from memory: ${b.badFrames}');
  }

  final addr = b.pixelAddr(320, 2);
  await b.write(addr, 0x12345678);
  if (await b.read(addr) != 0x12345678) {
    throw StateError('the fabric did not read back after the resets');
  }
  await b.waitFrames(2);
  final after = b.frameErrors();
  if (after.isNotEmpty) throw StateError('frame after resets differs: $after');
  if (b.underrunFrames != 0) {
    throw StateError('${b.underrunFrames} frames underran');
  }
  if (b.model.errors.isNotEmpty) {
    throw StateError('pin model: ${b.model.errors.take(4)}');
  }
  await b.stop();
}
