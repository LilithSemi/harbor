import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';
import '../util/spi_nor_model.dart';

const _xipBase = 0x20000000;
const _portBase = 0x30000000;

const _ctrl = 0x00;
const _addr = 0x04;
const _len = 0x08;
const _status = 0x0c;
const _lockMask = 0x10;
const _claim = 0x1c;
const _page = 0x100;

const _busy = 1;
const _done = 2;
const _err = 4;
const _locked = 8;

const _erase = 1;
const _program = 2;
const _go = 1 << 31;

const _parts = [
  HarborFlashPartition(label: 'fpga-bitstream', offset: 0, size: 0x20000),
  HarborFlashPartition(label: 'river-fsbl', offset: 0x20000, size: 0x10000),
  HarborFlashPartition(label: 'river-firmware', offset: 0x30000, size: 0x20000),
];

class _Rig {
  _Rig({
    this.readAhead = 4,
    this.clockHz,
    this.eraseMs = 3000,
    this.programMs = 50,
    bool stuckWip = false,
    int wipPolls = 3,
  }) : model = SpiNorModel(stuckWip: stuckWip, wipPolls: wipPolls);

  final int readAhead;
  final int? clockHz;
  final int eraseMs;
  final int programMs;
  final SpiNorModel model;
  late final Logic clk;
  final reset = Logic(name: 'reset');
  final miso = Logic(name: 'miso');
  final wrReq = Logic(name: 'wr_req');
  final wrOp = Logic(name: 'wr_op');
  final wrAddr = Logic(name: 'wr_addr', width: 24);
  final wrLen = Logic(name: 'wr_len', width: 9);
  final wrData = Logic(name: 'wr_data', width: 8);
  late final HarborSpiFlashController flash;
  late final RegBus xip;
  late final RegBus cpu;
  late final SpiNorPins pins;

  Future<void> start() async {
    clk = SimpleClockGenerator(10).clk;
    flash = HarborSpiFlashController(
      config: HarborSpiFlashConfig(
        size: 1024 * 1024,
        mode: HarborSpiFlashMode.standard,
        readAheadWords: readAhead,
        partitions: _parts,
        eraseTimeoutMs: eraseMs,
        programTimeoutMs: programMs,
      ),
      baseAddress: _xipBase,
      busAddressWidth: 32,
      cpuPortBase: _portBase,
      clockHz: clockHz ?? 100000000,
    );
    flash.input('clk').srcConnection! <= clk;
    flash.input('reset').srcConnection! <= reset;
    flash.input('spi_miso').srcConnection! <= miso;
    flash.input('wr_req').srcConnection! <= wrReq;
    flash.input('wr_op').srcConnection! <= wrOp;
    flash.input('wr_addr').srcConnection! <= wrAddr;
    flash.input('wr_len').srcConnection! <= wrLen;
    flash.input('wr_data').srcConnection! <= wrData;
    xip = RegBus.attach(flash, clk, name: 'bus');
    cpu = RegBus.attach(flash, clk, name: 'cpu_bus');
    await flash.build();
    xip.idle();
    cpu.idle();
    reset.inject(1);
    miso.inject(0);
    wrReq.inject(0);
    wrOp.inject(0);
    wrAddr.inject(0);
    wrLen.inject(0);
    wrData.inject(0);
    Simulator.setMaxSimTime(400000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    for (var i = 0; i < 2 * HarborSpiFlashController.startupClocks + 4; i++) {
      await clk.nextPosedge;
    }
    pins = model.attach(
      clk: clk,
      csN: flash.output('spi_cs_n'),
      spiClk: flash.output('spi_clk'),
      mosi: flash.output('spi_mosi'),
      miso: miso,
    );
  }

  Future<void> stop() async {
    await pins.stop();
    await Simulator.endSimulation();
  }

  Future<int> status() => cpu.read(_status);

  Future<int> waitIdle() async {
    for (var i = 0; i < 2000; i++) {
      final s = await status();
      if (s & _busy == 0) return s;
    }
    fail('port stayed busy');
  }

  Future<void> start1(int op, int addr, {int len = 0}) async {
    await cpu.write(_addr, addr);
    await cpu.write(_len, len);
    await cpu.write(_ctrl, op | _go);
  }

  /// Runs one op to its end and returns the status.
  Future<int> run(int op, int addr, {int len = 0}) async {
    await start1(op, addr, len: len);
    return waitIdle();
  }

  Future<void> fill(List<int> bytes) async {
    for (var i = 0; i < bytes.length; i += 4) {
      var w = 0;
      for (var j = 0; j < 4 && i + j < bytes.length; j++) {
        w |= bytes[i + j] << (8 * j);
      }
      await cpu.write(_page + i, w);
    }
  }

  Future<int> xipWord(int off) => xip.read(off);

  Future<void> clearErr() => cpu.write(_status, _err);
}

Future<void> _withRig(
  Future<void> Function(_Rig r) body, {
  int readAhead = 4,
  int? clockHz,
  int eraseMs = 3000,
  int programMs = 50,
  bool stuckWip = false,
  int wipPolls = 3,
}) async {
  final r = _Rig(
    readAhead: readAhead,
    clockHz: clockHz ?? 100000000,
    eraseMs: eraseMs,
    programMs: programMs,
    stuckWip: stuckWip,
    wipPolls: wipPolls,
  );
  await r.start();
  try {
    await body(r);
  } finally {
    await r.stop();
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'erase and program read back through XIP',
    () => _withRig((r) async {
      r.model.storage[0x1000] = 0x00;
      r.model.storage[0x1fff] = 0x55;
      expect(await r.run(_erase, 0x1000), _done);
      expect(r.model.read(0x1000), 0xff);
      expect(r.model.read(0x1fff), 0xff);
      await r.fill([0xde, 0xad, 0xbe, 0xef, 0x01]);
      expect(await r.run(_program, 0x1004, len: 5), _done);
      expect(await r.xipWord(0x1004), 0xefbeadde);
      expect(await r.xipWord(0x1008) & 0xff, 0x01);
      expect(r.model.log, [(0x20, 0x1000), (0x02, 0x1004)]);
    }),
  );

  test(
    'a bitstream partition erase and program at offset 0 succeed',
    () => _withRig((r) async {
      expect(await r.run(_erase, 0), _done);
      await r.fill([0x12, 0x34, 0x56, 0x78]);
      expect(await r.run(_program, 0, len: 4), _done);
      expect(await r.xipWord(0), 0x78563412);
    }),
  );

  test(
    'the page buffer honours byte enables and reads back',
    () => _withRig((r) async {
      await r.cpu.write(_page, 0x44332211);
      await r.cpu.write(_page, 0xaabbccdd, sel: 0x2);
      expect(await r.cpu.read(_page), 0x4433cc11);
      await r.cpu.write(_page + 0xfc, 0x01020304);
      expect(await r.cpu.read(_page + 0xfc), 0x01020304);
    }),
  );

  test(
    'a busy port reads the page as 0 and ignores writes',
    () => _withRig((r) async {
      await r.fill([1, 2, 3, 4]);
      await r.start1(_program, 0x2000, len: 4);
      expect((await r.status()) & _busy, _busy);
      expect(await r.cpu.read(_page), 0);
      await r.cpu.write(_page, 0x99999999);
      await r.waitIdle();
      expect(await r.cpu.read(_page), 0x04030201);
      expect(r.model.read(0x2000), 1);
    }),
  );

  test(
    'program rejects: page wrap, len 0, len above 256, bad op, range',
    () => _withRig((r) async {
      final before = r.model.log.length;
      // One byte past the page end.
      expect(await r.run(_program, 0x10ff, len: 2), _err);
      await r.clearErr();
      expect(await r.run(_program, 0x1000, len: 0), _err);
      await r.clearErr();
      expect(await r.run(_program, 0x1000, len: 257), _err);
      await r.clearErr();
      expect(await r.run(_program, 0x1000, len: 0x10100), _err);
      await r.clearErr();
      expect(await r.run(0, 0x1000), _err);
      await r.clearErr();
      expect(await r.run(3, 0x1000), _err);
      await r.clearErr();
      expect(await r.run(_erase, 0x100000), _err);
      await r.clearErr();
      expect(await r.status(), 0);
      // Exactly the page end is fine.
      await r.fill([0xaa]);
      expect(await r.run(_program, 0x10ff, len: 1), _done);
      expect(r.model.log.length, before + 1);
    }),
  );

  test(
    'a go while busy sets err and the first op finishes',
    () => _withRig((r) async {
      await r.start1(_erase, 0x1000);
      await r.cpu.write(_addr, 0x5000);
      await r.cpu.write(_ctrl, _erase | _go);
      expect((await r.status()) & _err, _err);
      await r.waitIdle();
      expect(r.model.log, [(0x20, 0x1000)]);
      expect((await r.status()) & _done, _done);
      // The next go clears done.
      await r.clearErr();
      await r.start1(_erase, 0x6000);
      await r.waitIdle();
      expect(r.model.log, [(0x20, 0x1000), (0x20, 0x6000)]);
    }),
  );

  test(
    'err is sticky and write 1 clears it with locked',
    () => _withRig((r) async {
      await r.cpu.write(_lockMask, 1 << 1);
      expect(await r.run(_erase, 0x20000), _err | _locked);
      await r.cpu.write(_status, _done);
      expect(await r.status(), _err | _locked);
      expect(await r.run(_erase, 0x1000), _err | _locked | _done);
      await r.clearErr();
      expect(await r.status(), _done);
    }),
  );

  test(
    'DFU wins over a pending CPU op and an op never interleaves',
    () => _withRig((r) async {
      Future<void> dfuErase(int a) async {
        r.wrOp.inject(0);
        r.wrAddr.inject(a);
        r.wrLen.inject(0);
        r.wrReq.inject(1);
        while (r.flash.output('wr_busy').value.toInt() == 0) {
          await r.clk.nextPosedge;
        }
        r.wrReq.inject(0);
      }

      await dfuErase(0x5000);
      await r.start1(_erase, 0x6000);
      // Queue the second DFU op while the first runs.
      r.wrOp.inject(0);
      r.wrAddr.inject(0x7000);
      r.wrReq.inject(1);
      while (r.flash.output('wr_busy').value.toInt() == 1) {
        await r.clk.nextPosedge;
      }
      while (r.flash.output('wr_busy').value.toInt() == 0) {
        await r.clk.nextPosedge;
      }
      r.wrReq.inject(0);
      final st = await r.waitIdle();
      expect(r.model.log, [
        (0x20, 0x5000),
        (0x20, 0x7000),
        (0x20, 0x6000),
      ], reason: 'st=$st t=${Simulator.time}');
    }),
  );

  test(
    'the first status read after a go shows busy and not done',
    () => _withRig((r) async {
      expect(await r.run(_erase, 0x1000), _done);
      await r.cpu.write(_addr, 0x2000);
      await r.cpu.write(_ctrl, _erase | _go);
      expect(await r.status(), _busy);
      await r.waitIdle();
      expect(await r.status(), _done);
    }),
  );

  test(
    'a program sends page bytes 0 to len-1 at any addr[7:0]',
    () => _withRig((r) async {
      await r.cpu.write(_page, 0x44332211);
      await r.cpu.write(_page + 4, 0x55);
      expect(await r.run(_program, 0x22, len: 5), _done);
      for (var i = 0; i < 5; i++) {
        expect(r.model.read(0x22 + i), 0x11 * (i + 1), reason: 'byte $i');
      }
      expect(r.model.read(0x21), 0xff);
      expect(r.model.read(0x27), 0xff);
      expect(r.model.log, [(0x02, 0x22)]);
    }),
  );

  test(
    'a go keeps err and locked and is accepted while they are set',
    () => _withRig((r) async {
      await r.cpu.write(_lockMask, 1 << 1);
      expect(await r.run(_erase, 0x20000), _err | _locked);
      await r.cpu.write(_addr, 0x1000);
      await r.cpu.write(_ctrl, _erase | _go);
      expect(await r.status(), _err | _locked | _busy);
      expect(await r.waitIdle(), _err | _locked | _done);
      expect(r.model.log, [(0x20, 0x1000)]);
      // A write of 1 to bit 2 clears both. A write of 0 does not.
      await r.cpu.write(_status, 0);
      expect(await r.status(), _err | _locked | _done);
      await r.cpu.write(_status, _err);
      expect(await r.status(), _done);
    }),
  );

  test(
    'a stuck part ends the op: busy drops, err sets, CS goes high',
    () => _withRig(clockHz: 10000, eraseMs: 3, programMs: 3, stuckWip: true, (
      r,
    ) async {
      final cs = r.flash.output('spi_cs_n');
      expect(await r.run(_erase, 0x1000), _err | _done);
      await r.clk.nextPosedge;
      expect(cs.value.toInt(), 1);
      expect(r.flash.output('wr_busy').value.toInt(), 0);
      await r.fill([1]);
      await r.clearErr();
      expect(await r.run(_program, 0x2000, len: 1), _err | _done);
      await r.clearErr();
      expect(await r.cpu.read(_claim), 1);
    }),
  );

  // The timer counts clocks from the start of the poll phase. A poll takes
  // 34 clocks and the part is read at 34 * n clocks, so WIP set at poll n
  // times out when the limit is 34 * n or less.
  for (final (cycles, passes) in [(103, true), (102, false)]) {
    test(
      'WIP that clears after 3 polls with a limit of $cycles clocks '
      '${passes ? 'passes' : 'times out'}',
      () => _withRig(clockHz: cycles * 1000, eraseMs: 1, (r) async {
        final s = await r.run(_erase, 0x1000);
        expect(s, passes ? _done : _err | _done);
      }),
    );
  }

  test(
    'erase and program have their own limits',
    () => _withRig(clockHz: 102000, eraseMs: 1000, programMs: 1, (r) async {
      expect(await r.run(_erase, 0x1000), _done);
      await r.fill([1]);
      expect(await r.run(_program, 0x2000, len: 1), _err | _done);
    }),
  );

  test('the timeout ends the op at the right clock', () async {
    Future<int> cycles(int limit) async {
      var n = 0;
      await _withRig(clockHz: limit * 1000, eraseMs: 1, stuckWip: true, (
        r,
      ) async {
        await r.start1(_erase, 0x1000);
        final busy = r.flash.output('wr_busy');
        while (busy.value.toInt() == 0) {
          await r.clk.nextPosedge;
        }
        while (busy.value.toInt() == 1) {
          await r.clk.nextPosedge;
          n++;
        }
      });
      await Simulator.reset();
      return n;
    }

    // One more poll of 34 clocks when the limit moves past a poll end.
    final a = await cycles(340);
    final b = await cycles(341);
    expect(b - a, 34);
    expect(await cycles(306), a - 34);
  });

  group('partition lock', () {
    test(
      'the mask is set only and reads back',
      () => _withRig((r) async {
        expect(await r.cpu.read(_lockMask), 0);
        await r.cpu.write(_lockMask, 0x1);
        await r.cpu.write(_lockMask, 0x4);
        expect(await r.cpu.read(_lockMask), 0x5);
        await r.cpu.write(_lockMask, 0);
        await r.cpu.write(_lockMask, 0x1, sel: 0x2);
        expect(await r.cpu.read(_lockMask), 0x5);
        await r.cpu.write(_lockMask, 0x8000, sel: 0x2);
        expect(await r.cpu.read(_lockMask), 0x8005);
      }),
    );

    test(
      'reserved registers read 0 and ignore writes',
      () => _withRig((r) async {
        await r.cpu.write(0x14, 0xffffffff);
        await r.cpu.write(0x18, 0xffffffff);
        expect(await r.cpu.read(0x14), 0);
        expect(await r.cpu.read(0x18), 0);
        expect(await r.run(_erase, 0x20000), _done);
      }),
    );

    test(
      'edges of a locked partition',
      () => _withRig((r) async {
        await r.cpu.write(_lockMask, 1 << 1);
        // The partition is [0x20000, 0x30000).
        await r.fill([0x00]);
        expect(await r.run(_program, 0x20000, len: 1), _err | _locked);
        await r.clearErr();
        expect(await r.run(_program, 0x2ffff, len: 1), _err | _locked);
        await r.clearErr();
        expect(await r.run(_program, 0x1ffff, len: 1), _done);
        expect(await r.run(_program, 0x30000, len: 1), _done);
        expect(r.model.log, [(0x02, 0x1ffff), (0x02, 0x30000)]);
      }),
    );

    test(
      'an erase sector that touches the partition is refused',
      () => _withRig((r) async {
        await r.cpu.write(_lockMask, 1 << 1);
        expect(await r.run(_erase, 0x20000), _err | _locked);
        await r.clearErr();
        expect(await r.run(_erase, 0x2f000), _err | _locked);
        await r.clearErr();
        expect(await r.run(_erase, 0x2ffff), _err | _locked);
        await r.clearErr();
        expect(await r.run(_erase, 0x1f000), _done);
        expect(await r.run(_erase, 0x30000), _done);
        expect(r.model.log, [(0x20, 0x1f000), (0x20, 0x30000)]);
      }),
    );

    test(
      'bits for absent partitions do nothing',
      () => _withRig((r) async {
        await r.cpu.write(_lockMask, 0xfffffff8);
        expect(await r.run(_erase, 0x20000), _done);
        expect(await r.run(_erase, 0), _done);
        expect(await r.run(_erase, 0x30000), _done);
      }),
    );

    test(
      'the bitstream partition stays writable until it is locked',
      () => _withRig((r) async {
        await r.cpu.write(_lockMask, (1 << 1) | (1 << 2));
        expect(await r.run(_erase, 0), _done);
        await r.fill([0x42]);
        expect(await r.run(_program, 0x1ffff, len: 1), _done);
        expect(await r.xipWord(0x1fffc) >> 24, 0x42);
        await r.cpu.write(_lockMask, 1);
        expect(await r.run(_erase, 0), _err | _locked | _done);
      }),
    );

    test(
      'DFU is never locked',
      () => _withRig((r) async {
        await r.cpu.write(_lockMask, 0xffffffff);
        r.wrOp.inject(0);
        r.wrAddr.inject(0x20000);
        r.wrReq.inject(1);
        while (r.flash.output('wr_busy').value.toInt() == 0) {
          await r.clk.nextPosedge;
        }
        r.wrReq.inject(0);
        while (r.flash.output('wr_done').value.toInt() == 0) {
          await r.clk.nextPosedge;
        }
        expect(r.model.log, [(0x20, 0x20000)]);
      }),
    );
  });

  group('claim', () {
    test(
      'claim, claim again, release, claim',
      () => _withRig((r) async {
        expect(await r.cpu.read(_claim), 1);
        expect(await r.cpu.read(_claim), 0);
        expect(await r.cpu.read(_claim), 0);
        await r.cpu.write(_claim, 1);
        expect(await r.cpu.read(_claim), 1);
        expect(await r.cpu.read(_claim), 0);
      }),
    );

    test(
      'writing 0 keeps the claim and a reset clears it',
      () => _withRig((r) async {
        expect(await r.cpu.read(_claim), 1);
        await r.cpu.write(_claim, 0);
        expect(await r.cpu.read(_claim), 0);
        r.reset.inject(1);
        await r.clk.nextPosedge;
        await r.clk.nextPosedge;
        r.reset.inject(0);
        await r.clk.nextPosedge;
        expect(await r.cpu.read(_claim), 1);
      }),
    );
  });

  group('line buffer', () {
    test(
      'XIP reads see an erase and a program',
      () => _withRig((r) async {
        for (var i = 0; i < 16; i++) {
          r.model.storage[0x3000 + i] = 0x10 + i;
        }
        expect(await r.xipWord(0x3000), 0x13121110);
        expect(await r.xipWord(0x3004), 0x17161514);
        expect(await r.run(_erase, 0x3000), _done);
        expect(await r.xipWord(0x3000), 0xffffffff);
        expect(await r.xipWord(0x3004), 0xffffffff);
        await r.fill([0xa5, 0x5a, 0x0f, 0xf0]);
        expect(await r.run(_program, 0x3000, len: 4), _done);
        expect(await r.xipWord(0x3000), 0xf00f5aa5);
      }),
    );
  });

  test('a 64-bit bus puts each register in its own lane', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final flash = HarborSpiFlashController(
      clockHz: 100000000,
      config: HarborSpiFlashConfig(size: 1 << 20, partitions: _parts),
      baseAddress: _xipBase,
      busAddressWidth: 32,
      busDataWidth: 64,
      cpuPortBase: _portBase,
    );
    flash.input('clk').srcConnection! <= clk;
    flash.input('reset').srcConnection! <= reset;
    flash.input('spi_miso').srcConnection! <= Const(0);
    flash.input('wr_req').srcConnection! <= Const(0);
    flash.input('wr_op').srcConnection! <= Const(0);
    flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
    flash.input('wr_len').srcConnection! <= Const(0, width: 9);
    flash.input('wr_data').srcConnection! <= Const(0, width: 8);
    RegBus.attach(flash, clk, name: 'bus').idle();
    final cpu = RegBus.attach(flash, clk, name: 'cpu_bus');
    await flash.build();
    cpu.idle();
    reset.inject(1);
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    // The lock mask is the low lane of 0x10 and the claim the high lane of 0x18.
    await cpu.write(0x10, 0x5, sel: 0x0f);
    await cpu.write(0x10, 0x2 << 32, sel: 0xf0);
    expect(await cpu.read(0x10), 0x5);
    expect(await cpu.read(0x18), 0x1 << 32);
    expect(await cpu.read(0x18, sel: 0xf0), 0x1 << 32);
    expect(await cpu.read(0x18, sel: 0xf0), 0x0);
    await cpu.write(0x18, 1 << 32, sel: 0xf0);
    expect(await cpu.read(0x18, sel: 0xf0), 0x1 << 32);
    await cpu.write(0x100, 0x1111111122222222);
    expect(await cpu.read(0x100), 0x1111111122222222);
    await cpu.write(0x104, 0x33333333 << 32, sel: 0xf0);
    expect(await cpu.read(0x100), 0x3333333322222222);
    await Simulator.endSimulation();
  });

  test(
    'CS stays high for csHighClocks between frames',
    () => _withRig((r) async {
      // 100 MHz and 50 ns make 5 clocks.
      expect(HarborSpiFlashController.csHighClocks(50, 100000000), 5);
      final cs = r.flash.output('spi_cs_n');
      var run = 0;
      var minHigh = 1 << 30;
      var seenLow = false;
      var watching = true;
      final watcher = () async {
        while (watching) {
          await r.clk.nextPosedge;
          if (!cs.value.isValid) continue;
          if (cs.value.toInt() == 1) {
            run++;
          } else {
            if (run > 0 && seenLow && run < minHigh) minHigh = run;
            seenLow = true;
            run = 0;
          }
        }
      }();
      Future<void> dfuErase(int a) async {
        r.wrOp.inject(0);
        r.wrAddr.inject(a);
        r.wrReq.inject(1);
        await r.clk.nextPosedge;
        while (r.flash.output('wr_busy').value.toInt() == 0) {
          await r.clk.nextPosedge;
        }
        r.wrReq.inject(0);
        while (r.flash.output('wr_busy').value.toInt() == 1) {
          await r.clk.nextPosedge;
        }
      }

      expect(await r.xipWord(0x100), 0xffffffff);
      expect(await r.run(_erase, 0x1000), _done);
      await r.fill([1, 2, 3, 4]);
      expect(await r.run(_program, 0x1000, len: 4), _done);
      expect(await r.xipWord(0x1000), 0x04030201);
      expect(await r.xipWord(0x2000), 0xffffffff);
      await dfuErase(0x3000);
      expect(await r.xipWord(0x3000), 0xffffffff);
      expect(await r.xipWord(0x4000), 0xffffffff);
      watching = false;
      await watcher;
      expect(minHigh, greaterThanOrEqualTo(5));
      expect(minHigh, lessThan(1 << 30));
    }),
  );

  test(
    'an XIP miss in the cycle of a DFU accept waits for the engine',
    () => _withRig((r) async {
      r.model.storage[0x3000] = 0x12;
      await r.xipWord(0x100);
      await r.clk.nextPosedge;
      final read = r.xip.read(0x3000);
      r.wrOp.inject(0);
      r.wrAddr.inject(0x3000);
      r.wrReq.inject(1);
      await r.clk.nextPosedge;
      while (r.flash.output('wr_busy').value.toInt() == 0) {
        await r.clk.nextPosedge;
      }
      r.wrReq.inject(0);
      expect(await read, 0xffffffff);
      expect(r.model.log, [(0x20, 0x3000)]);
    }),
  );

  test(
    'the IO2 and IO3 pins hold 1 in the engine and the read command',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final wrReq = Logic(name: 'wr_req');
      final flash = HarborSpiFlashController(
        config: const HarborSpiFlashConfig.w25q128(),
        baseAddress: _xipBase,
        busAddressWidth: 32,
        clockHz: 100000000,
      );
      flash.input('clk').srcConnection! <= clk;
      flash.input('reset').srcConnection! <= reset;
      flash.input('spi_io_in').srcConnection! <= Const(0, width: 4);
      flash.input('wr_req').srcConnection! <= wrReq;
      flash.input('wr_op').srcConnection! <= Const(0);
      flash.input('wr_addr').srcConnection! <= Const(0x1000, width: 24);
      flash.input('wr_len').srcConnection! <= Const(0, width: 9);
      flash.input('wr_data').srcConnection! <= Const(0, width: 8);
      final xip = RegBus.attach(flash, clk, name: 'bus');
      await flash.build();
      xip.idle();
      reset.inject(1);
      wrReq.inject(0);
      Simulator.setMaxSimTime(40000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 40; i++) {
        await clk.nextPosedge;
      }
      final oe = flash.output('spi_io_oe');
      final busy = flash.output('wr_busy');
      var released = false;
      var busyCycles = 0;
      var watching = true;
      final watcher = () async {
        while (watching) {
          await clk.nextPosedge;
          if (!oe.value.isValid) continue;
          final v = oe.value.toInt();
          if (busy.value.toInt() == 1) {
            busyCycles++;
            expect(v >> 2, 3, reason: 'IO2 and IO3 are driven in the engine');
          }
          if (v >> 2 == 0) released = true;
        }
      }();
      // A read: IO2 and IO3 are released only in the dummy and data phase.
      await xip.read(0);
      expect(released, isTrue);
      released = false;
      wrReq.inject(1);
      await clk.nextPosedge;
      while (busy.value.toInt() == 0) {
        await clk.nextPosedge;
      }
      wrReq.inject(0);
      while (busy.value.toInt() == 1) {
        await clk.nextPosedge;
      }
      expect(busyCycles, greaterThan(50));
      expect(released, isFalse);
      watching = false;
      await watcher;
      await Simulator.endSimulation();
    },
  );

  test('the own-pads quad controller builds', () async {
    final f = HarborSpiFlashController(
      config: const HarborSpiFlashConfig.w25q128(),
      baseAddress: _xipBase,
      busAddressWidth: 32,
      clockHz: 100000000,
      ownPads: true,
    );
    await f.build();
    expect(f.inOuts.keys, contains('spi_io'));
  });

  test(
    'a 64-bit store checks the new addr and a 64-bit read does not claim',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final flash = HarborSpiFlashController(
        config: HarborSpiFlashConfig(size: 1 << 20, partitions: _parts),
        baseAddress: _xipBase,
        busAddressWidth: 32,
        busDataWidth: 64,
        clockHz: 100000000,
        cpuPortBase: _portBase,
      );
      flash.input('clk').srcConnection! <= clk;
      flash.input('reset').srcConnection! <= reset;
      flash.input('spi_miso').srcConnection! <= Const(0);
      flash.input('wr_req').srcConnection! <= Const(0);
      flash.input('wr_op').srcConnection! <= Const(0);
      flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
      flash.input('wr_len').srcConnection! <= Const(0, width: 9);
      flash.input('wr_data').srcConnection! <= Const(0, width: 8);
      RegBus.attach(flash, clk, name: 'bus').idle();
      final cpu = RegBus.attach(flash, clk, name: 'cpu_bus');
      await flash.build();
      cpu.idle();
      reset.inject(1);
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      await cpu.write(0x10, 1 << 1);
      // ctrl (erase, go) and addr (a locked sector) in one 64-bit store.
      await cpu.write(0x00, (0x20000 << 32) | _erase | _go);
      expect(await cpu.read(0x08) & 0xffffffff, 0);
      expect((await cpu.read(0x08) >> 32) & 0xffffffff, _err | _locked);
      // A 64-bit read of the word at 0x18 does not take the claim.
      expect(await cpu.read(0x18), 0x1 << 32);
      expect(await cpu.read(0x18), 0x1 << 32);
      expect(await cpu.read(0x18, sel: 0xf0), 0x1 << 32);
      expect(await cpu.read(0x18, sel: 0xf0), 0);
      await Simulator.endSimulation();
    },
  );

  group('build', () {
    test('port off has no port and no port tag', () {
      final f = HarborSpiFlashController(
        clockHz: 100000000,
        config: const HarborSpiFlashConfig.w25q128(readAheadWords: 4),
        baseAddress: _xipBase,
        busAddressWidth: 32,
        useStartupe2: true,
      );
      final on = HarborSpiFlashController(
        clockHz: 100000000,
        config: const HarborSpiFlashConfig.w25q128(readAheadWords: 4),
        baseAddress: _xipBase,
        busAddressWidth: 32,
        useStartupe2: true,
        cpuPortBase: _portBase,
      );
      expect(f.definitionName, isNot(on.definitionName));
      expect(f.inputs.keys.where((k) => k.startsWith('cpu_bus')), isEmpty);
      expect(f.dtNode.extraReg, isEmpty);
      expect(f.extraDtNodes, isEmpty);
      expect(f.secondarySlaves, isEmpty);
    });

    HarborSpiFlashController build(int base, {int size = 1 << 20}) =>
        HarborSpiFlashController(
          clockHz: 100000000,
          config: HarborSpiFlashConfig(size: size),
          baseAddress: _xipBase,
          cpuPortBase: base,
        );

    test('the port window is aligned and outside the XIP window', () {
      expect(() => build(_portBase + 4), throwsArgumentError);
      expect(() => build(_xipBase + 0x1000), throwsArgumentError);
      expect(() => build(_xipBase + (1 << 20) - 0x1000), throwsArgumentError);
      expect(build(_xipBase + (1 << 20)).cpuPortBase, _xipBase + (1 << 20));
    });

    test('partitions are checked', () {
      HarborSpiFlashConfig cfg(List<HarborFlashPartition> p) =>
          HarborSpiFlashConfig(size: 1 << 20, partitions: p);
      HarborFlashPartition p(String l, int o, int s) =>
          HarborFlashPartition(label: l, offset: o, size: s);
      void bad(List<HarborFlashPartition> list) =>
          expect(cfg(list).validatePartitions, throwsArgumentError);
      cfg(_parts).validatePartitions();
      bad([p('a', 0, 0x1000), p('a', 0x1000, 0x1000)]);
      bad([p('', 0, 0x1000)]);
      bad([p('a', 0x100, 0x1000)]);
      bad([p('a', 0, 0x1100)]);
      bad([p('a', 0, 0)]);
      bad([p('a', 0, 0x2000), p('b', 0x1000, 0x1000)]);
      bad([p('a', 0xff000, 0x2000)]);
      bad([for (var i = 0; i < 33; i++) p('p$i', i * 0x1000, 0x1000)]);
      cfg([
        for (var i = 0; i < 32; i++) p('p$i', i * 0x1000, 0x1000),
      ]).validatePartitions();
      expect(
        () => HarborSpiFlashController(
          clockHz: 100000000,
          config: cfg([p('a', 0x100, 0x1000)]),
          baseAddress: _xipBase,
        ),
        throwsArgumentError,
      );
    });

    test('the partitions carry through copyWith and the n25q128 preset', () {
      const base = HarborSpiFlashConfig.n25q128();
      final c = base.copyWith(partitions: _parts);
      expect(c.partitions, _parts);
      expect(c.size, 16 << 20);
      expect(c.readCommand, 0x6b);
      expect(
        const HarborSpiFlashConfig.w25q128(partitions: _parts).partitions,
        _parts,
      );
      expect(
        const HarborSpiFlashConfig.is25lp128(partitions: _parts).partitions,
        _parts,
      );
    });

    test('csHighClocks rounds tSHSL up to whole clocks', () {
      expect(HarborSpiFlashController.csHighClocks(50, 25000000), 2);
      expect(HarborSpiFlashController.csHighClocks(50, 50000000), 3);
      expect(HarborSpiFlashController.csHighClocks(50, 100000000), 5);
      expect(HarborSpiFlashController.csHighClocks(50, 1000), 1);
      expect(HarborSpiFlashController.csHighClocks(0, 100000000), 1);
    });

    test('a timeout below the data sheet maximum is rejected', () {
      void bad(HarborSpiFlashConfig c) =>
          expect(c.validatePartitions, throwsArgumentError);
      bad(const HarborSpiFlashConfig.n25q128(eraseTimeoutMs: 799));
      bad(const HarborSpiFlashConfig.n25q128(programTimeoutMs: 4));
      bad(const HarborSpiFlashConfig.w25q128(eraseTimeoutMs: 399));
      bad(const HarborSpiFlashConfig.w25q128(programTimeoutMs: 2));
      const HarborSpiFlashConfig.n25q128(
        eraseTimeoutMs: 800,
        programTimeoutMs: 5,
      ).validatePartitions();
      expect(
        () => HarborSpiFlashController(
          config: const HarborSpiFlashConfig.w25q128(eraseTimeoutMs: 10),
          baseAddress: _xipBase,
          clockHz: 100000000,
        ),
        throwsArgumentError,
      );
    });

    test('the write engine needs 4 KiB sectors and 3-byte addresses', () {
      const wide = HarborSpiFlashConfig(size: 1 << 20, sectorSize: 8192);
      const four = HarborSpiFlashConfig(size: 1 << 20, addressBytes: 4);
      expect(HarborSpiFlashController.supportsWriteEngine(wide), isFalse);
      expect(HarborSpiFlashController.supportsWriteEngine(four), isFalse);
      for (final c in [wide, four]) {
        expect(
          () => HarborSpiFlashController(
            config: c,
            baseAddress: _xipBase,
            clockHz: 100000000,
            cpuPortBase: _portBase,
          ),
          throwsArgumentError,
        );
      }
    });

    test('the PMA regions of the XIP window and the port window', () {
      HarborSpiFlashController make(int? port, {int? width}) =>
          HarborSpiFlashController(
            config: const HarborSpiFlashConfig(size: 1 << 20),
            baseAddress: _xipBase,
            busAddressWidth: 32,
            busDataWidth: width,
            clockHz: 100000000,
            cpuPortBase: port,
          );
      final on = make(_portBase).xipPma;
      expect(on.start, _xipBase);
      expect(on.size, 1 << 20);
      expect(on.memoryType, HarborPmaMemoryType.io);
      expect(on.executable, isTrue);
      expect(on.readable, isTrue);
      expect(on.writable, isFalse);
      expect(on.idempotent, isTrue);
      expect(on.atomicSupport, isFalse);
      expect(on.accessWidths, [1, 2, 4]);
      expect(make(_portBase, width: 64).xipPma.accessWidths, [1, 2, 4, 8]);
      final off = make(null).xipPma;
      expect(off.memoryType, HarborPmaMemoryType.memory);
      expect(off.executable, isTrue);
      expect(off.writable, isFalse);
      expect(off.start, _xipBase);
      expect(make(null).ctrlPma, isNull);
      final ctrl = make(_portBase).ctrlPma!;
      expect(ctrl.start, _portBase);
      expect(ctrl.size, 0x1000);
      expect(ctrl.memoryType, HarborPmaMemoryType.io);
      expect(ctrl.executable, isFalse);
      expect(ctrl.writable, isTrue);
      expect(ctrl.accessWidths, [4]);
      expect(ctrl.idempotent, isFalse);
    });
  });
}
