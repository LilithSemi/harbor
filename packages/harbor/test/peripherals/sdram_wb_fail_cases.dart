import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'harbor_sdram_wb_test.dart' show sdramByteAddr;
import 'sdram_wb_stack.dart';

/// One bus access for [streamHeld].
typedef WbOp = ({int addr, bool write, int data});

/// Runs [ops] with cyc held high across every ack and returns the data of
/// each ack, or -1 where the data is not valid.
Future<List<int>> streamHeld(
  SdramWbStack s,
  List<WbOp> ops, {
  void Function()? onCycle,
}) async {
  final got = <int>[];
  var i = 0;
  s.drive(byteAddr: ops[0].addr, write: ops[0].write, data: ops[0].data);
  for (var n = 0; n < 20000 && i < ops.length; n++) {
    await s.sysClk.nextPosedge;
    onCycle?.call();
    if (s.sdram.output('bus_ACK').value != LogicValue.one) continue;
    final d = s.sdram.output('bus_DAT_MISO').value;
    got.add(d.isValid ? d.toInt() : -1);
    i++;
    if (i < ops.length) {
      s.drive(byteAddr: ops[i].addr, write: ops[i].write, data: ops[i].data);
    }
  }
  s.release();
  await s.sysClk.nextPosedge;
  expect(got.length, equals(ops.length), reason: 'acks seen');
  return got;
}

/// Writes a known word into each bank and returns the addresses.
Future<List<int>> seed(SdramWbStack s, int row, int base) async {
  final addrs = [
    for (var bank = 0; bank < s.config.banks; bank++)
      for (final col in [0, 6]) sdramByteAddr(s, bank, row, col),
  ];
  for (var i = 0; i < addrs.length; i++) {
    await s.write32(addrs[i], base + i);
  }
  // Give the memory side time to settle after the last ack.
  await s.idle(200);
  return addrs;
}

Future<void> checkSeed(SdramWbStack s, List<int> addrs) async {
  for (final a in addrs) {
    expect(await s.read32(a), equals(s.peek32(a)), reason: 'addr $a');
  }
}

/// Drops cyc in the middle of a read and of a write, then starts a read of
/// another word one cycle later. That read must get its own data.
Future<void> abortCase(SdramWbStack s) async {
  final a = sdramByteAddr(s, 0, 1, 0);
  final b = sdramByteAddr(s, 1, 5, 8);
  await s.write32(a, 0xaaaaaaaa);
  await s.write32(b, 0xbbbbbbbb);

  for (final after in [1, 3, 6, 12]) {
    s.drive(byteAddr: a, write: false);
    for (var i = 0; i < after; i++) {
      await s.sysClk.nextPosedge;
    }
    s.release();
    await s.sysClk.nextPosedge;
    expect(await s.read32(b), equals(0xbbbbbbbb), reason: 'read after $after');
  }

  for (final after in [1, 3, 6]) {
    s.drive(byteAddr: a, write: true, data: 0x5555aaaa + after);
    for (var i = 0; i < after; i++) {
      await s.sysClk.nextPosedge;
    }
    s.release();
    await s.sysClk.nextPosedge;
    expect(await s.read32(b), equals(0xbbbbbbbb), reason: 'write $after');
    // An aborted write may or may not land, but never only in part, since
    // the front end finishes both words.
    final now = await s.read32(a);
    expect(
      now == s.peek32(a) || now == 0x5555aaaa + after,
      isTrue,
      reason: 'word a after write abort $after: 0x${now.toRadixString(16)}',
    );
    await s.write32(a, 0xaaaaaaaa);
  }
  expect(await s.read32(a), equals(0xaaaaaaaa));
}

/// Pulses the bus reset in the middle of a write and of a read. The sdram
/// contents and refresh must survive it.
Future<void> sysResetCase(SdramWbStack s) async {
  final addrs = await seed(s, 4, 0x31000000);
  final w = sdramByteAddr(s, 2, 9, 16);
  final port = s.wbPort;

  Future<void> pulse(int sysCycles) async {
    s.release();
    s.sysReset.inject(1);
    for (var i = 0; i < sysCycles; i++) {
      await s.sysClk.nextPosedge;
    }
    s.sysReset.inject(0);
    await s.idle(8);
  }

  // Reset while the front end still has write words to hand over.
  s.drive(byteAddr: w, write: true, data: 0x7e7e7e7e);
  while (port.output('wr_valid').value != LogicValue.one) {
    await s.memClk.nextPosedge;
    if (s.sdram.output('bus_ACK').value == LogicValue.one) s.release();
  }
  await pulse(4);
  s.forget(w);

  // Reset while a read is queued in the engine.
  s.drive(byteAddr: addrs[3], write: false);
  await s.waitHigh(port.output('req_valid'));
  await s.idle(2);
  await pulse(4);

  // Reset while read data is coming back.
  s.drive(byteAddr: addrs[5], write: false);
  await s.waitHigh(port.input('rd_valid'));
  await pulse(4);

  // A long reset, many refresh intervals.
  s.drive(byteAddr: w, write: true, data: 0x1e1e1e1e);
  await s.waitHigh(port.output('wr_valid'));
  await pulse((s.cycles.refi * 4 * s.sysClockHz) ~/ s.memClockHz);

  expect(s.sdram.output('init_done').value, equals(LogicValue.one));
  await checkSeed(s, addrs);
  await s.write32(w, 0x600df00d);
  expect(await s.read32(w), equals(0x600df00d));
  await s.idle(s.cycles.refi * 2);
  await checkSeed(s, addrs);
}

/// Pulses the memory reset in the middle of a read. The engine runs init
/// again and bus_error goes high. In async mode the waiting bus cycle ends
/// with a poison ack, in sync mode the front end runs the read again.
Future<void> memResetCase(SdramWbStack s) async {
  final addrs = await seed(s, 5, 0x42000000);
  expect(s.sdram.output('bus_error').value, equals(LogicValue.zero));

  s.drive(byteAddr: addrs[1], write: false);
  await s.waitHigh(s.wbPort.output('req_valid'));
  s.memReset.inject(1);
  unawaited(s.idle(16).then((_) => s.memReset.inject(0)));
  final got = await s.waitAck(limit: 20000);
  s.release();
  await s.sysClk.nextPosedge;
  expect(got, isNotNull, reason: 'the read must end');
  if (!s.busClockSync) expect(got, equals(0xffffffff), reason: 'poison data');
  expect(s.sdram.output('bus_error').value, equals(LogicValue.one));

  while (s.sdram.output('init_done').value != LogicValue.one) {
    await s.memClk.nextPosedge;
  }
  final a = sdramByteAddr(s, 3, 7, 4);
  await s.write32(a, 0x0badcafe);
  expect(await s.read32(a), equals(0x0badcafe));
}

/// Holds cyc across each ack: two writes then two reads back to back.
Future<void> heldCycCase(SdramWbStack s) async {
  final a = sdramByteAddr(s, 0, 8, 2);
  final b = sdramByteAddr(s, 3, 8, 2);
  final got = await streamHeld(s, [
    (addr: a, write: true, data: 0x0a0a0a0a),
    (addr: b, write: true, data: 0x0b0b0b0b),
    (addr: a, write: false, data: 0),
    (addr: b, write: false, data: 0),
    (addr: a, write: true, data: 0x1a1a1a1a),
    (addr: a, write: false, data: 0),
  ]);
  expect(got[2], equals(0x0a0a0a0a));
  expect(got[3], equals(0x0b0b0b0b));
  expect(got[5], equals(0x1a1a1a1a));
}

/// Pulses the bus reset [n] cycles after the ack of a write, for a sweep
/// of [n], on a row hit, a row miss, and a row miss with a refresh due. An
/// acked write must read back exact. A write cut before its ack lands in
/// full or not at all.
Future<void> committedWriteCase(SdramWbStack s, {int maxN = 20}) async {
  final eng = s.sdram.engine!;
  final need = eng.subModules
      .firstWhere((m) => m.name == 'sdram_refresh')
      .output('need');
  final allowed = <int, Set<int>>{};
  var k = 0;
  for (var n = 0; n < maxN; n++) {
    for (final variant in ['hit', 'miss', 'refresh']) {
      for (final acked in [true, false]) {
        final bank = k % s.config.banks;
        final col = (k * 4) % (1 << s.config.colWidth);
        // Open row 30 in this bank, then write to row 30 or row 31.
        await s.read32(sdramByteAddr(s, bank, 30, 0));
        final a = sdramByteAddr(s, bank, variant == 'hit' ? 30 : 31, col);
        final old = s.peek32(a);
        final data = (0x5ac00000 + k * 0x101) & 0xffffffff;
        k++;
        if (variant == 'refresh') {
          for (var i = 0; i < 2 * s.cycles.refi; i++) {
            if (need.value == LogicValue.one) break;
            await s.memClk.nextPosedge;
          }
        }
        s.drive(byteAddr: a, write: true, data: data);
        if (acked) {
          expect(await s.waitAck(), isNotNull);
          s.release();
          if (s.postedWrites) {
            // A posted ack only means the write queued in the cdc fifo.
            // The sweep must count from when the memory side takes it.
            await s.waitHigh(s.wbPort.ack);
          }
          // A non-posted ack means the memory side has already taken the
          // write, so the sweep counts straight from the ack.
          await s.idle(n);
        } else {
          for (var i = 0; i < n; i++) {
            await s.sysClk.nextPosedge;
            if (s.sdram.output('bus_ACK').value == LogicValue.one) break;
          }
          s.release();
        }
        s.sysReset.inject(1);
        for (var i = 0; i <= k % 3; i++) {
          await s.sysClk.nextPosedge;
        }
        s.sysReset.inject(0);
        await s.idle(4);
        allowed[a] = acked ? {data} : {old, data};
        s.forget(a);
      }
    }
  }
  await s.idle(100);
  for (final e in allowed.entries) {
    final got = await s.read32(e.key);
    expect(
      e.value.contains(got),
      isTrue,
      reason:
          'addr ${e.key}: 0x${got.toRadixString(16)}, allowed '
          '${e.value.map((v) => v.toRadixString(16)).toList()}',
    );
  }
}
