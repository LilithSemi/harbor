import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// A bit level I2C slave for a PCA9548 at 0x74 and an ADV7511 at 0x39.
class _Bus {
  final Map<int, int> adv;
  final bool present;
  final log = <String>[];

  bool pull = false;
  bool _scl = true, _sda = true;
  bool _inFrame = false;
  String _state = 'idle';
  int _bits = 0, _shift = 0, _byteNo = 0, _addr = 0, _ptr = 0;
  bool _ackThis = false, _read = false;
  int _txByte = 0;
  int starts = 0;

  _Bus(this.adv, {this.present = true});

  /// Advances the slave one step. [master] is true when the master releases
  /// SDA, and the return value is the SDA level of the bus.
  bool step(bool scl, bool masterSda) {
    final sda = masterSda && !pull;
    if (present) {
      if (scl && _scl && _sda && !sda) {
        _inFrame = true;
        _state = 'recv';
        _bits = 0;
        _shift = 0;
        _byteNo = 0;
        pull = false;
        starts++;
      } else if (scl && _scl && !_sda && sda) {
        _inFrame = false;
        _state = 'idle';
        pull = false;
      } else if (_inFrame && scl && !_scl) {
        _rise(sda);
      } else if (_inFrame && !scl && _scl) {
        _fall();
      }
    }
    _scl = scl;
    _sda = sda;
    return sda;
  }

  void _rise(bool sda) {
    if (_state == 'recv' && _bits < 8) {
      _shift = (_shift << 1) | (sda ? 1 : 0);
      _bits++;
    }
  }

  void _fall() {
    if (_state == 'recv' && _bits == 8) {
      if (_byteNo == 0) {
        _addr = _shift >> 1;
        _read = _shift & 1 == 1;
        _ackThis = _addr == 0x74 || _addr == 0x39;
      } else if (_addr == 0x74) {
        log.add('mux ${_shift.toRadixString(16)}');
        _ackThis = true;
      } else if (_byteNo == 1) {
        _ptr = _shift;
        _ackThis = true;
      } else {
        log.add('w ${_ptr.toRadixString(16)}=${_shift.toRadixString(16)}');
        _ptr++;
        _ackThis = true;
      }
      _byteNo++;
      pull = _ackThis;
      _state = 'ack';
      _bits = 9;
    } else if (_state == 'ack') {
      pull = false;
      _bits = 0;
      _shift = 0;
      if (_read && _ackThis) {
        log.add('rd ${_ptr.toRadixString(16)}');
        _txByte = adv[_ptr] ?? 0;
        _state = 'send';
        pull = (_txByte & 0x80) == 0;
      } else {
        _state = 'recv';
      }
    } else if (_state == 'send') {
      _bits++;
      if (_bits < 8) {
        pull = (_txByte >> (7 - _bits)) & 1 == 0;
      } else {
        pull = false;
        _state = 'master';
      }
    }
  }
}

const _repeat = 12000;
var gapBusy = 0;

Future<
  ({
    HarborAdv7511Initializer dut,
    _Bus bus,
    List<int> passStarts,
    List<int> passEnds,
  })
>
_run({required _Bus bus, required int cycles}) async {
  final dut = HarborAdv7511Initializer(
    clk: SimpleClockGenerator(10).clk,
    reset: Logic(),
    sclIn: Logic(),
    sdaIn: Logic(),
    clockFrequency: 1600000,
    repeatCycles: _repeat,
  );
  await dut.build();
  final clk = dut.input('clk');
  dut.input('reset').inject(1);
  dut.input('scl_in').inject(1);
  dut.input('sda_in').inject(1);
  Simulator.setMaxSimTime(cycles * 10 + 100);
  var cycle = 0;
  final passStarts = <int>[], passEnds = <int>[];
  var lastPasses = 0;
  var lastStarts = 0;
  var busyInGap = 0;
  clk.negedge.listen((_) {
    cycle++;
    final scl = dut.sclOe.value.toInt() == 0;
    final sda = dut.sdaOe.value.toInt() == 0;
    final bus_ = bus.step(scl, sda);
    dut.input('scl_in').inject(scl ? 1 : 0);
    dut.input('sda_in').inject(bus_ ? 1 : 0);
    final p = dut.passes.value.toInt();
    if (p != lastPasses) {
      passEnds.add(cycle);
      lastPasses = p;
      busyInGap = 0;
    }
    if (passEnds.isNotEmpty &&
        passStarts.length == passEnds.length &&
        (dut.sclOe.value.toInt() | dut.sdaOe.value.toInt()) == 1) {
      busyInGap++;
    }
    if (dut.sdaOe.value.toInt() == 1 &&
        dut.sclOe.value.toInt() == 0 &&
        passStarts.length == passEnds.length) {
      passStarts.add(cycle);
    }
    lastStarts = bus.starts;
  });
  unawaited(Simulator.run());
  await clk.nextNegedge;
  await clk.nextNegedge;
  dut.input('reset').inject(0);
  await Simulator.simulationEnded;
  expect(lastStarts, greaterThanOrEqualTo(0));
  gapBusy = busyInGap;
  return (dut: dut, bus: bus, passStarts: passStarts, passEnds: passEnds);
}

void main() {
  tearDown(() async => Simulator.reset());

  final adv = {
    0x42: 0x60,
    0x9E: 0x10,
    0xF5: 0x75,
    0xF6: 0x11,
    0x3E: 0x04,
    0x3D: 0x55,
  };
  final expectedPass = <String>[
    'mux 20',
    for (final (r, v) in adv7511RegisterTable)
      'w ${r.toRadixString(16)}=${v.toRadixString(16)}',
    for (final r in adv7511ReadRegisters) 'rd ${r.toRadixString(16)}',
  ];

  test(
    'writes the mux, the register list in order, and reads status back',
    () async {
      final r = await _run(bus: _Bus(adv), cycles: 2 * 60000 + _repeat * 3);
      final log = r.bus.log;
      final n = expectedPass.length;
      expect(log.length, greaterThanOrEqualTo(2 * n));
      expect(log.sublist(0, n), expectedPass);
      // The second pass repeats the whole sequence.
      expect(log.sublist(n, 2 * n), expectedPass);
      expect(r.dut.muxResetN.value.toInt(), 1);
      expect(r.dut.vic.value.toInt(), 0x04);
      expect(r.dut.timing.value.toInt(), 0x55);
      // 0x60 in 0x42, PLL lock, chip ID 0x7511 and a finished pass.
      expect(
        r.dut.status.value.toInt(),
        HarborAdv7511Initializer.statusHotPlug |
            HarborAdv7511Initializer.statusSense |
            HarborAdv7511Initializer.statusPllLocked |
            HarborAdv7511Initializer.statusChipId |
            HarborAdv7511Initializer.statusValid,
      );
      expect(r.passEnds.length, greaterThanOrEqualTo(2));
      // The next pass starts about [_repeat] clocks after the last one ends.
      final gap = r.passStarts[1] - r.passEnds[0];
      expect(gap, inInclusiveRange(_repeat - 4, _repeat + 40));
      // The bus is released between passes. The gap check counts clocks where
      // a line is pulled after a pass ended and before the next START.
      expect(gapBusy, lessThan(2));
    },
  );

  test('a NACK sets the error flag and the pass still ends', () async {
    final r = await _run(
      bus: _Bus(adv, present: false),
      cycles: 60000 + _repeat * 2,
    );
    final s = r.dut.status.value.toInt();
    expect(s & HarborAdv7511Initializer.statusNack, isNonZero);
    expect(s & HarborAdv7511Initializer.statusValid, isNonZero);
    expect(s & HarborAdv7511Initializer.statusChipId, 0);
    expect(r.dut.passes.value.toInt(), greaterThanOrEqualTo(1));
  });

  test('the sequence has the PCA9548 select before the chip', () {
    final ops = HarborAdv7511Initializer.ops;
    expect(ops.first, (HarborAdv7511Initializer.opStart, 0));
    expect(ops[1], (HarborAdv7511Initializer.opWrite, 0xE8));
    expect(ops[2], (HarborAdv7511Initializer.opWrite, 0x20));
    expect(ops[3], (HarborAdv7511Initializer.opStop, 0));
    expect(ops[5], (HarborAdv7511Initializer.opWrite, 0x72));
  });
}
