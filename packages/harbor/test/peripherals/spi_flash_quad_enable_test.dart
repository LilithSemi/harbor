import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';
import '../util/spi_nor_model.dart';

const _xipBase = 0x20000000;
const _portBase = 0x30000000;

int _byteAt(int a) => (a * 29 + 5) & 0xFF;

int _wordAt(int a) =>
    _byteAt(a) |
    (_byteAt(a + 1) << 8) |
    (_byteAt(a + 2) << 16) |
    (_byteAt(a + 3) << 24);

class _Part {
  const _Part({
    required this.name,
    required this.config,
    required this.jedecId,
    required this.foreignId,
    required this.clearReads,
    required this.setReads,
    required this.writeOp,
    required this.writeData,
    required this.readOp,
    required this.fallbackOp,
    required this.sr1Bits,
    required this.reg2Bits,
    required this.verifyOp,
  });

  final String name;
  final HarborSpiFlashConfig config;

  /// The ID that the model of the part returns, and an ID of another vendor.
  final int jedecId;
  final int foreignId;

  /// Opcodes of the reads before the write, and when QE is already set.
  final List<int> clearReads;
  final List<int> setReads;
  final int writeOp;
  final List<int> writeData;
  final int verifyOp;
  final int readOp;
  final int fallbackOp;
  final int sr1Bits;
  final int reg2Bits;

  HarborSpiFlashQuadEnable get qe => config.quadEnable;
}

const _parts = [
  _Part(
    name: 'w25q128 sr2Bit1',
    config: HarborSpiFlashConfig.w25q128(),
    jedecId: 0xef4018,
    foreignId: 0x9d6018,
    clearReads: [0x9F, 0x35, 0x35],
    setReads: [0x9F, 0x35],
    writeOp: 0x31,
    writeData: [0x42],
    verifyOp: 0x35,
    readOp: 0x6B,
    fallbackOp: 0x0B,
    sr1Bits: 0x1C,
    reg2Bits: 0x79,
  ),
  _Part(
    name: 'is25lp128 sr1Bit6',
    config: HarborSpiFlashConfig.is25lp128(),
    jedecId: 0x9d6018,
    foreignId: 0xef4018,
    clearReads: [0x9F, 0x05, 0x05],
    setReads: [0x9F, 0x05],
    writeOp: 0x01,
    writeData: [0xD8],
    verifyOp: 0x05,
    readOp: 0x6B,
    fallbackOp: 0x0B,
    sr1Bits: 0x98,
    reg2Bits: 0,
  ),
  _Part(
    name: 's25fl256 cr1Bit1',
    config: HarborSpiFlashConfig.s25fl256(),
    jedecId: 0x010219,
    foreignId: 0xef4018,
    clearReads: [0x9F, 0x05, 0x05, 0x35, 0x35],
    setReads: [0x9F, 0x05, 0x05, 0x35],
    writeOp: 0x01,
    writeData: [0x1C, 0xC2],
    verifyOp: 0x35,
    readOp: 0x6C,
    fallbackOp: 0x0C,
    sr1Bits: 0x1C,
    reg2Bits: 0xE8,
  ),
  _Part(
    name: 's25fl128s cr1Bit1',
    config: HarborSpiFlashConfig.s25fl128s(),
    jedecId: 0x012018,
    foreignId: 0xef4018,
    clearReads: [0x9F, 0x05, 0x05, 0x35, 0x35],
    setReads: [0x9F, 0x05, 0x05, 0x35],
    writeOp: 0x01,
    writeData: [0x1C, 0xC2],
    verifyOp: 0x35,
    readOp: 0x6B,
    fallbackOp: 0x0B,
    sr1Bits: 0x1C,
    reg2Bits: 0xE8,
  ),
  _Part(
    name: 'gd25q128 sr2Bit1',
    config: HarborSpiFlashConfig.gd25q128(),
    jedecId: 0xc84018,
    foreignId: 0x9d6018,
    clearReads: [0x9F, 0x35, 0x35],
    setReads: [0x9F, 0x35],
    writeOp: 0x31,
    writeData: [0x42],
    verifyOp: 0x35,
    readOp: 0x6B,
    fallbackOp: 0x0B,
    sr1Bits: 0x1C,
    reg2Bits: 0x79,
  ),
];

SpiNorModel _model(
  _Part part, {
  bool qe = false,
  bool refuse = false,
  int? jedecId,
  bool unstable = false,
  int wipPolls = 2,
  bool stuckWip = false,
  bool busyUntilClsr = false,
  HarborSpiFlashQuadEnable? method,
}) => SpiNorModel(
  quadEnable: method ?? part.qe,
  qe: qe,
  sr1Bits: part.sr1Bits,
  reg2Bits: part.reg2Bits,
  wipPolls: wipPolls,
  refuseQeWrite: refuse,
  stuckWip: stuckWip,
  jedecId: jedecId ?? part.jedecId,
  unstableReads: unstable,
  busyUntilClsr: busyUntilClsr,
);

/// A controller on split quad pins with a NOR model behind it.
class _Rig {
  _Rig(
    this.config,
    this.model, {
    this.clockHz = 100000000,
    bool port = false,
    this.busBits = 32,
    this.holdWrReq = false,
  }) : port = port && HarborSpiFlashController.supportsWriteEngine(config);

  final HarborSpiFlashConfig config;
  final SpiNorModel model;
  final int clockHz;
  final bool port;
  final int busBits;
  final bool holdWrReq;
  final reset = Logic(name: 'reset');
  final ioIn = Logic(name: 'io_in', width: 4);
  final wrReq = Logic(name: 'wr_req');
  final wrOp = Logic(name: 'wr_op');
  late final Logic clk;
  late final HarborSpiFlashController flash;
  late final RegBus xip;
  late final RegBus cpu;
  late final SpiNorQuadPins pins;
  final violations = <String>[];

  /// Clocks from the end of reset to the rise of qe_done.
  int qeCycles = -1;

  Future<void> start() async {
    clk = SimpleClockGenerator(10).clk;
    flash = HarborSpiFlashController(
      config: config,
      baseAddress: _xipBase,
      busAddressWidth: 32,
      busDataWidth: busBits,
      clockHz: clockHz,
      cpuPortBase: port ? _portBase : null,
    );
    flash.input('clk').srcConnection! <= clk;
    flash.input('reset').srcConnection! <= reset;
    flash.input('spi_io_in').srcConnection! <= ioIn;
    flash.input('wr_req').srcConnection! <= wrReq;
    flash.input('wr_op').srcConnection! <= wrOp;
    final aw = flash.input('wr_addr').width;
    flash.input('wr_addr').srcConnection! <= Const(0x2000, width: aw);
    flash.input('wr_len').srcConnection! <= Const(0, width: 9);
    flash.input('wr_data').srcConnection! <= Const(0, width: 8);
    xip = RegBus.attach(flash, clk, name: 'bus')..timeout = 400000;
    if (port) cpu = RegBus.attach(flash, clk, name: 'cpu_bus');
    await flash.build();
    xip.idle();
    if (port) cpu.idle();
    for (var a = 0x1000; a < 0x1100; a++) {
      model.storage[a] = _byteAt(a);
    }
    final addrBytes = config.addressBytes;
    pins = model.attachQuad(
      clk: clk,
      csN: flash.output('spi_cs_n'),
      spiClk: flash.output('spi_clk'),
      ioOut: flash.output('spi_io_out'),
      ioOe: flash.output('spi_io_oe'),
      ioIn: ioIn,
    );
    // IO2 and IO3 are driven high except in the dummy and data phases of a
    // quad read.
    pins.onEdge = (idx, op, out, oe) {
      final quadRead = op == 0x6B || op == 0x6C;
      final released = quadRead && idx >= 8 + 8 * addrBytes;
      if (released) return;
      if ((oe >> 2) & 3 != 3 || (out >> 2) & 3 != 3) {
        violations.add('IO2/IO3 not high at idx $idx op $op out $out oe $oe');
      }
    };
    reset.inject(1);
    ioIn.inject(0);
    wrReq.inject(holdWrReq ? 1 : 0);
    wrOp.inject(0);
    Simulator.setMaxSimTime(800000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    unawaited(_countQe());
  }

  Future<void> _countQe() async {
    var n = 0;
    while (qeCycles < 0) {
      await clk.nextPosedge;
      n++;
      final v = flash.output('qe_done').value;
      if (v.isValid && v.toInt() == 1) qeCycles = n;
    }
  }

  int port1(String name) => flash.output(name).value.toInt();

  /// The word that a read of [a] returns on this bus.
  BigInt word(int a) => busBits == 64
      ? BigInt.from(_wordAt(a)) | (BigInt.from(_wordAt(a + 4)) << 32)
      : BigInt.from(_wordAt(a));

  Future<BigInt> readWide(int a) async =>
      (await xip.accessWide(a, write: false)).data;

  Future<void> stop() async {
    await pins.stop();
    await Simulator.endSimulation();
  }
}

bool _vendorWrite(int op) => const [0x06, 0x01, 0x31].contains(op);

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final part in _parts) {
    group(part.name, () {
      test('clear QE: the sequence sets it, then quad reads work', () async {
        final model = _model(part);
        final rig = _Rig(part.config, model, port: true);
        await rig.start();
        // The read waits for the sequence.
        final first = rig.xip.read(0x1000);
        if (rig.port) {
          expect(await rig.cpu.read(0x14), 0, reason: 'sequence running');
        }
        expect(await first, _wordAt(0x1000));
        expect(rig.port1('qe_done'), 1);
        expect(await rig.xip.read(0x1040), _wordAt(0x1040));
        expect(rig.port1('qe_set'), 1);
        expect(rig.port1('qe_err'), 0);
        expect(rig.port1('qe_fallback'), 0);
        expect(rig.port1('qe_id_err'), 0);
        expect(model.qe, isTrue);
        expect(model.qeLog.length, 1);
        expect(model.qeLog.single.$1, part.writeOp);
        expect(model.qeLog.single.$2, part.writeData);
        final ops = model.opcodes;
        final wren = part.clearReads.length;
        expect(ops.sublist(0, wren + 2), [
          ...part.clearReads,
          0x06,
          part.writeOp,
        ]);
        // WIP polls with 0x05, then one read back, then the quad reads.
        final firstRead = ops.indexOf(part.readOp);
        expect(ops.sublist(wren + 2, firstRead - 1), everyElement(0x05));
        expect(ops.sublist(wren + 2, firstRead - 1).length, greaterThan(1));
        expect(ops[firstRead - 1], part.verifyOp);
        expect(ops.sublist(firstRead), everyElement(part.readOp));
        if (rig.port) expect(await rig.cpu.read(0x14), 3);
        // ignore: avoid_print
        print(
          '${part.name}: ${rig.qeCycles} clocks to qe_done, '
          '${rig.qeCycles / 25} us at 25 MHz with 2 busy polls',
        );
        expect(rig.violations, isEmpty);
        await rig.stop();
      });

      test('QE already set: no write happens', () async {
        final model = _model(part, qe: true);
        final rig = _Rig(part.config, model, port: true);
        await rig.start();
        expect(await rig.xip.read(0x1000), _wordAt(0x1000));
        expect(rig.port1('qe_set'), 1);
        expect(rig.port1('qe_err'), 0);
        expect(model.qeLog, isEmpty);
        expect(model.opcodes, [...part.setReads, part.readOp]);
        if (rig.port) expect(await rig.cpu.read(0x14), 3);
        expect(rig.violations, isEmpty);
        await rig.stop();
      });

      test('a part that refuses the write falls back to single line', () async {
        final model = _model(part, refuse: true, wipPolls: 1);
        final rig = _Rig(part.config, model, port: true);
        await rig.start();
        expect(await rig.xip.read(0x1000), _wordAt(0x1000));
        expect(await rig.xip.read(0x1040), _wordAt(0x1040));
        expect(await rig.xip.read(0x1080), _wordAt(0x1080));
        expect(rig.port1('qe_done'), 1);
        expect(rig.port1('qe_set'), 0);
        expect(rig.port1('qe_err'), 1);
        expect(rig.port1('qe_fallback'), 1);
        expect(rig.port1('qe_id_err'), 0);
        expect(model.qeLog.length, 1);
        expect(model.qeLog.single.$2, part.writeData);
        expect(model.opcodes.where((o) => o == part.readOp), isEmpty);
        expect(model.opcodes.where((o) => o == part.fallbackOp).length, 3);
        expect(model.opcodes.last, part.fallbackOp);
        if (rig.port) expect(await rig.cpu.read(0x14), 5);
        expect(rig.violations, isEmpty);
        await rig.stop();
      });

      test('another vendor ID gets no vendor command', () async {
        final model = _model(part, jedecId: part.foreignId);
        final rig = _Rig(part.config, model, port: true);
        await rig.start();
        expect(await rig.xip.read(0x1000), _wordAt(0x1000));
        expect(await rig.xip.read(0x1040), _wordAt(0x1040));
        expect(rig.port1('qe_done'), 1);
        expect(rig.port1('qe_err'), 1);
        expect(rig.port1('qe_fallback'), 1);
        expect(rig.port1('qe_id_err'), 1);
        expect(model.opcodes.where(_vendorWrite), isEmpty);
        expect(model.opcodes.where((o) => o == 0x35), isEmpty);
        expect(model.opcodes.take(2), [0x9F, part.fallbackOp]);
        expect(model.qeLog, isEmpty);
        if (rig.port) expect(await rig.cpu.read(0x14), 13);
        expect(rig.violations, isEmpty);
        await rig.stop();
      });

      test('two status reads that differ stop the write', () async {
        final model = _model(part, unstable: true);
        final rig = _Rig(part.config, model, port: true);
        await rig.start();
        expect(await rig.xip.read(0x1000), _wordAt(0x1000));
        expect(rig.port1('qe_err'), 1);
        expect(rig.port1('qe_id_err'), 0);
        expect(model.opcodes.where(_vendorWrite), isEmpty);
        expect(model.qeLog, isEmpty);
        expect(model.opcodes.last, part.fallbackOp);
        if (rig.port) expect(await rig.cpu.read(0x14), 5);
        expect(rig.violations, isEmpty);
        await rig.stop();
      });
    });
  }

  test('the gd25q128 preset also takes the Winbond ID', () async {
    const gd = HarborSpiFlashConfig.gd25q128();
    final model = SpiNorModel(
      quadEnable: HarborSpiFlashQuadEnable.sr2Bit1,
      jedecId: 0xef4018,
    );
    final rig = _Rig(gd, model);
    await rig.start();
    expect(await rig.xip.read(0x1000), _wordAt(0x1000));
    expect(rig.port1('qe_set'), 1);
    expect(rig.port1('qe_err'), 0);
    expect(model.qe, isTrue);
    expect(rig.violations, isEmpty);
    await rig.stop();
  });

  test('w25q128 against the S25FL128S and ISSI IDs falls back', () async {
    for (final id in [0x012018, 0x9d6018]) {
      final model = SpiNorModel(
        quadEnable: HarborSpiFlashQuadEnable.cr1Bit1,
        jedecId: id,
      );
      final rig = _Rig(const HarborSpiFlashConfig.w25q128(), model);
      await rig.start();
      expect(await rig.xip.read(0x1000), _wordAt(0x1000));
      expect(rig.port1('qe_id_err'), 1);
      expect(rig.port1('qe_err'), 1);
      expect(model.opcodes.where(_vendorWrite), isEmpty);
      expect(model.opcodes.where((o) => o == 0x35), isEmpty);
      expect(model.qeLog, isEmpty);
      await rig.stop();
      await Simulator.reset();
    }
  });

  test('a failed S25FL write is cleared with CLSR and WRDI', () async {
    final part = _parts[2];
    final model = _model(part, refuse: true, busyUntilClsr: true);
    final rig = _Rig(
      const HarborSpiFlashConfig.s25fl256(eraseTimeoutMs: 650),
      model,
      clockHz: 10000,
    );
    await rig.start();
    expect(await rig.xip.read(0x1000), _wordAt(0x1000));
    expect(rig.port1('qe_err'), 1);
    final ops = model.opcodes;
    final clsr = ops.indexOf(0x30);
    expect(clsr, greaterThan(0));
    expect(ops[clsr + 1], 0x04);
    expect(ops[clsr + 2], 0x0C);
    expect(ops.where((o) => o == 0x6C), isEmpty);
    expect(rig.violations, isEmpty);
    await rig.stop();
  });

  test('a request held from reset starts after qe_done', () async {
    final part = _parts[0];
    final model = _model(part, wipPolls: 2);
    final rig = _Rig(part.config, model, holdWrReq: true);
    await rig.start();
    var busyAt = -1;
    var doneAt = -1;
    var pulses = 0;
    var qeDoneAtBusy = 0;
    final busyOut = rig.flash.output('wr_busy');
    final doneOut = rig.flash.output('wr_done');
    for (var i = 0; i < 3000; i++) {
      await rig.clk.nextPosedge;
      final busy = busyOut.value.isValid && busyOut.value.toInt() == 1;
      if (busy && busyAt < 0) {
        busyAt = i;
        qeDoneAtBusy = rig.port1('qe_done');
        rig.wrReq.inject(0);
      }
      if (doneOut.value.isValid && doneOut.value.toInt() == 1) {
        pulses++;
        doneAt = i;
      }
    }
    expect(busyAt, greaterThan(0), reason: 'the op never started');
    expect(qeDoneAtBusy, 1);
    expect(busyAt, greaterThan(rig.qeCycles - 3));
    expect(doneAt, greaterThan(busyAt));
    expect(pulses, 1);
    expect(model.log, [(0x20, 0x2000)]);
    expect(
      model.opcodes.indexOf(0x20),
      greaterThan(model.opcodes.indexOf(0x31)),
    );
    expect(rig.port1('qe_set'), 1);
    expect(rig.violations, isEmpty);
    await rig.stop();
  });

  group('fallback on a wider read line and a 64-bit bus', () {
    for (final (name, config, bits) in [
      (
        'readAheadWords 4',
        const HarborSpiFlashConfig.w25q128(readAheadWords: 4),
        32,
      ),
      ('64-bit bus', const HarborSpiFlashConfig.w25q128(), 64),
      (
        '64-bit bus, readAheadWords 2',
        const HarborSpiFlashConfig.w25q128(readAheadWords: 2),
        64,
      ),
    ]) {
      final part = _parts[0];
      test('$name falls back with correct data', () async {
        final model = _model(part, refuse: true, wipPolls: 1);
        final rig = _Rig(config, model, busBits: bits);
        await rig.start();
        for (final a in [0x1000, 0x1008, 0x1010, 0x1020, 0x1040]) {
          expect(await rig.readWide(a), rig.word(a), reason: 'read $a');
        }
        expect(rig.port1('qe_err'), 1);
        expect(model.opcodes.where((o) => o == 0x6B), isEmpty);
        expect(model.opcodes.last, 0x0B);
        expect(rig.violations, isEmpty);
        await rig.stop();
      });
      test('$name reads quad when QE sets', () async {
        final model = _model(part);
        final rig = _Rig(config, model, busBits: bits);
        await rig.start();
        for (final a in [0x1000, 0x1008, 0x1010, 0x1020, 0x1040]) {
          expect(await rig.readWide(a), rig.word(a), reason: 'read $a');
        }
        expect(rig.port1('qe_set'), 1);
        expect(model.opcodes.last, 0x6B);
        expect(rig.violations, isEmpty);
        await rig.stop();
      });
    }
  });

  test('a part with no QE bit runs no sequence', () async {
    final model = SpiNorModel();
    final rig = _Rig(const HarborSpiFlashConfig.n25q128(), model, port: true);
    await rig.start();
    expect(rig.port1('qe_done'), 1);
    expect(await rig.cpu.read(0x14), 1);
    expect(await rig.xip.read(0x1000), _wordAt(0x1000));
    expect(model.opcodes, [0x6B]);
    expect(rig.port1('qe_set'), 0);
    expect(rig.violations, isEmpty);
    await rig.stop();
  });

  test('a part that stays busy ends the sequence with the fallback', () async {
    final part = _parts[0];
    final model = _model(part, stuckWip: true);
    final rig = _Rig(
      const HarborSpiFlashConfig.w25q128(eraseTimeoutMs: 400),
      model,
      clockHz: 10000,
    );
    await rig.start();
    expect(await rig.xip.read(0x1000), _wordAt(0x1000));
    expect(rig.port1('qe_err'), 1);
    expect(model.opcodes.last, 0x0B);
    expect(rig.violations, isEmpty);
    await rig.stop();
  });

  test('standard and dual mode run no sequence', () {
    HarborSpiFlashController make(
      HarborSpiFlashMode m,
      HarborSpiFlashQuadEnable qe,
    ) => HarborSpiFlashController(
      config: HarborSpiFlashConfig(size: 1024 * 1024, mode: m, quadEnable: qe),
      baseAddress: _xipBase,
      busAddressWidth: 32,
      clockHz: 100000000,
    );
    for (final m in [HarborSpiFlashMode.standard, HarborSpiFlashMode.dual]) {
      expect(
        make(m, HarborSpiFlashQuadEnable.sr1Bit6).definitionName,
        make(m, HarborSpiFlashQuadEnable.none).definitionName,
      );
    }
  });

  test('the method and the manufacturers are in the definition name', () {
    HarborSpiFlashController make(HarborSpiFlashConfig c) =>
        HarborSpiFlashController(
          config: c,
          baseAddress: _xipBase,
          busAddressWidth: 32,
          clockHz: 100000000,
        );
    final names = {
      for (final c in [
        const HarborSpiFlashConfig.w25q128(),
        const HarborSpiFlashConfig.is25lp128(),
        const HarborSpiFlashConfig.gd25q128(),
      ])
        make(c).definitionName,
    };
    expect(names.length, 3);
  });

  test('the new presets have the geometry of the data sheets', () {
    const arty = HarborSpiFlashConfig.s25fl128s();
    expect(arty.jedecId, 0x012018);
    expect(arty.size, 16 << 20);
    expect(arty.addressBytes, 3);
    expect(arty.sectorSize, 256 * 1024);
    expect(arty.quadEnable, HarborSpiFlashQuadEnable.cr1Bit1);
    expect(HarborSpiFlashController.supportsWriteEngine(arty), isFalse);
    expect(
      () => HarborSpiFlashController(
        config: arty,
        baseAddress: _xipBase,
        busAddressWidth: 32,
        clockHz: 100000000,
        cpuPortBase: _portBase,
      ),
      throwsArgumentError,
    );
    const gd = HarborSpiFlashConfig.gd25q128();
    expect(gd.jedecId, 0xc84018);
    expect(gd.acceptedManufacturers, [0xc8, 0xef]);
    expect(gd.quadEnable, HarborSpiFlashQuadEnable.sr2Bit1);
    expect(HarborSpiFlashController.supportsWriteEngine(gd), isTrue);
  });

  test('an erase timeout below the register write time is rejected', () {
    expect(
      () => HarborSpiFlashController(
        config: const HarborSpiFlashConfig.s25fl256(eraseTimeoutMs: 650),
        baseAddress: _xipBase,
        busAddressWidth: 32,
        clockHz: 100000000,
      ),
      returnsNormally,
    );
    expect(
      () => HarborSpiFlashController(
        config: const HarborSpiFlashConfig.s25fl128s(eraseTimeoutMs: 2000),
        baseAddress: _xipBase,
        busAddressWidth: 32,
        clockHz: 100000000,
      ),
      throwsArgumentError,
    );
  });
}
