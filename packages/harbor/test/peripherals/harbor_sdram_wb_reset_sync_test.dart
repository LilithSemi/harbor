import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'harbor_sdram_wb_test.dart' show sdramByteAddr;
import 'sdram_wb_fail_cases.dart' show seed;
import 'sdram_wb_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('sync: there is no mem_reset port, and a bus reset re-initializes the '
      'device, which then serves again', () async {
    final s = SdramWbStack(
      sysClockHz: 125000000,
      memClockHz: 125000000,
      busClockSync: true,
    );
    await s.start();
    expect(s.sdram.inputs.keys, isNot(contains('mem_reset')));
    final a = sdramByteAddr(s, 1, 3, 8);
    await s.write32(a, 0x12345678);
    expect(await s.read32(a), equals(0x12345678));

    s.sysReset.inject(1);
    await s.idle(8);
    s.sysReset.inject(0);
    await s.idle(4);
    while (s.sdram.output('init_done').value != LogicValue.one) {
      await s.memClk.nextPosedge;
    }
    final b = sdramByteAddr(s, 2, 5, 4);
    await s.write32(b, 0x0badcafe);
    expect(await s.read32(b), equals(0x0badcafe));
    expect(s.sdram.output('bus_error').value, equals(LogicValue.zero));
    await s.stop();
    expect(s.errors, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('sync: a bus reset with a row open starts with precharge all, so no '
      'row stays open through the power-up wait', () async {
    final s = SdramWbStack(
      sysClockHz: 125000000,
      memClockHz: 125000000,
      busClockSync: true,
      fastInit: false,
    );
    await s.start();
    final addrs = await seed(s, 5, 0x42000000);
    final top = s.sdram;
    final cmds = <String>[];
    var recording = false;
    s.memClk.negedge.listen((_) {
      if (!recording || top.output('sdram_cs_n').value != LogicValue.zero) {
        return;
      }
      final ras = top.output('sdram_ras_n').value.toInt();
      final cas = top.output('sdram_cas_n').value.toInt();
      final we = top.output('sdram_we_n').value.toInt();
      final name = switch ((ras, cas, we)) {
        (1, 1, 1) => null,
        (0, 1, 1) => 'act',
        (1, 0, 1) => 'read',
        (1, 0, 0) => 'write',
        (0, 1, 0) =>
          top.output('sdram_addr').value.toInt() & 0x400 != 0
              ? 'pre_all'
              : 'pre',
        (0, 0, 1) => 'ref',
        _ => 'mrs',
      };
      if (name != null) cmds.add(name);
    });
    s.drive(byteAddr: addrs[1], write: false);
    await s.waitHigh(s.wbPort.output('req_valid'));
    for (var i = 0; i < 6; i++) {
      await s.memClk.nextPosedge;
    }
    recording = true;
    s.sysReset.inject(1);
    await s.idle(8);
    s.release();
    s.sysReset.inject(0);
    while (top.output('init_done').value != LogicValue.one) {
      await s.memClk.nextPosedge;
    }
    await s.idle(50);
    recording = false;

    // The read in flight may still issue commands while reset is held, so
    // the check starts at the first precharge all.
    final first = cmds.indexOf('pre_all');
    expect(first, isNot(-1), reason: '$cmds');
    expect(cmds.sublist(first), [
      'pre_all',
      'pre_all',
      'mrs',
      for (var i = 0; i < 8; i++) 'ref',
      ...cmds.sublist(first + 11),
    ], reason: '$cmds');
    final a = sdramByteAddr(s, 2, 5, 4);
    await s.write32(a, 0x0badcafe);
    expect(await s.read32(a), equals(0x0badcafe));
    await s.stop();
    expect(s.errors, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
