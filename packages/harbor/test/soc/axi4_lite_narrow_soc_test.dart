// A burst master with a 32 or 64 bit AXI4 fabric reads the XIP window of an
// N25Q128 flash controller at address 0, and reads and writes a register
// slave, with narrow sizes and bursts. The fabric converts each access for
// the AXI4-Lite slave.

import 'dart:isolate';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import '../util/spi_nor_model.dart';

const _xip = 0x0;
const _regs = 0x30008000;
const _echo = 0x30009000;

class _Master extends BridgeModule {
  _Master(int dw) : super('LiteNarrowMaster$dw', name: 'burster') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final mem = HarborMemoryMasterPort.create(
      module: this,
      name: 'dataBus',
      kind: HarborFabricKind.axi4,
      config: HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: dw,
        idWidth: 2,
        outstanding: 2,
      ),
      clk: input('clk'),
      reset: input('reset'),
    );
    exposeWaist(this, mem.waist, 'mem', PairRole.consumer);
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (n.startsWith('mem_')) soc.pullUpPort(port(n), newPortName: 'cpu_$n');
    }
  }
}

/// A register slave as wide as the fabric. It keeps the last write and
/// returns the byte address of its word on a read.
class _Regs extends BridgeModule with HarborDeviceTreeNodeProvider {
  _Regs(int dw) : super('LiteNarrowRegs$dw', name: 'regs') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      addressWidth: 32,
      dataWidth: dw,
      clk: input('clk'),
      reset: input('reset'),
    );
    final lastAddr = addOutput('last_addr', width: 32);
    final lastData = addOutput('last_data', width: dw);
    final lastSel = addOutput('last_sel', width: dw ~/ 8);
    final addr = Logic(name: 'addr_q', width: 32);
    final data = Logic(name: 'data_q', width: dw);
    final sel = Logic(name: 'sel_q', width: dw ~/ 8);
    lastAddr <= addr;
    lastData <= data;
    lastSel <= sel;
    Sequential(input('clk'), reset: bus.reset, [
      bus.ack < (bus.stb & ~bus.ack),
      bus.dataOut < bus.addr.zeroExtend(dw),
      If(
        bus.stb & ~bus.ack & bus.we,
        then: [addr < bus.addr, data < bus.dataIn, sel < bus.sel],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,regs'],
    reg: BusAddressRange(_regs, 0x1000),
  );
}

/// A 32-bit device that returns the address it sees.
class _Echo extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborNarrowSlaveOk {
  _Echo() : super('LiteNarrowEcho', name: 'echo') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      addressWidth: 32,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
    );
    Sequential(input('clk'), reset: bus.reset, [
      bus.ack < (bus.stb & ~bus.ack),
      bus.dataOut < bus.addr,
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,echo'],
    reg: BusAddressRange(_echo, 0x1000),
  );
}

int _byte(int a) => (a * 7 + 3) & 0xff;

int _flashWord(int a, int bytes) => [
  for (var i = bytes - 1; i >= 0; i--) _byte((a & ~(bytes - 1)) + i),
].fold(0, (v, b) => v << 8 | b);

// The bytes of [word] in the lanes of an access of 2^[size] bytes at [a].
int _lanes(int word, int a, int size, int bytes) {
  final lo = (a & (bytes - 1)) & ~((1 << size) - 1);
  final mask = ((1 << (8 << size)) - 1) << (lo * 8);
  return word & mask;
}

/// Runs the reads and writes and returns an error text per case. An empty
/// text is a pass.
Future<Map<String, String>> _run(int dw) => Isolate.run(() async {
  final bytes = dw ~/ 8;
  final full = bytes.bitLength - 1;
  final soc = HarborSoC(
    name: 'lite_narrow',
    compatible: 'test,lite-narrow',
    fabricKind: HarborFabricKind.axi4,
    target: const HarborSimTarget(frequency: 50000000),
  );
  final cpu = soc.addMaster(_Master(dw), memory: true);
  final flash = soc.addPeripheral(
    HarborSpiFlashController(
      config: const HarborSpiFlashConfig.n25q128(),
      baseAddress: _xip,
      busAddressWidth: 32,
      busDataWidth: dw,
      fabricKind: HarborFabricKind.axi4,
      clockHz: 50000000,
    ),
  );
  final regs = soc.addPeripheral(_Regs(dw));
  final echo = dw == 64 ? soc.addPeripheral(_Echo()) : null;
  flash.input('wr_req').srcConnection! <= Const(0);
  flash.input('wr_op').srcConnection! <= Const(0);
  flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
  flash.input('wr_len').srcConnection! <= Const(0, width: 9);
  flash.input('wr_data').srcConnection! <= Const(0, width: 8);
  soc
    ..exposePin(flash, 'spi_clk', externalName: 'spi_clk')
    ..exposePin(flash, 'spi_cs_n', externalName: 'spi_cs_n')
    ..exposePin(flash, 'spi_io_out', externalName: 'spi_io_out')
    ..exposePin(flash, 'spi_io_oe', externalName: 'spi_io_oe')
    ..exposePin(flash, 'qe_done', externalName: 'qe_done');
  final ioIn = Logic(name: 'io_in', width: 4);
  flash.input('spi_io_in').srcConnection! <= ioIn;
  cpu.pullUp(soc);
  soc.buildFabric();

  final model = SpiNorModel();
  for (var a = 0; a < 0x400; a++) {
    model.storage[a] = _byte(a);
  }
  final sim = Sim(soc);
  final errors = <String>[];
  final req = WaistRequester(sim, 'cpu_mem', Random(5), errors: errors);
  await sim.start();
  Simulator.setMaxSimTime(60000000);
  final pins = model.attachQuad(
    clk: sim.clk,
    csN: soc.output('spi_cs_n'),
    spiClk: soc.output('spi_clk'),
    ioOut: soc.output('spi_io_out'),
    ioOe: soc.output('spi_io_oe'),
    ioIn: ioIn,
  );
  await sim.cycles(60);

  Burst rd(int addr, int len, int size, [int burst = 1]) => Burst(
    id: 0,
    write: false,
    addr: addr,
    len: len,
    size: size,
    burst: burst,
  );
  Burst wr(int addr, int size, int data, int strb) => Burst(
    id: 1,
    write: true,
    addr: addr,
    len: 0,
    size: size,
    burst: 1,
    data: [data],
    strb: [strb],
  );

  final reads = <String, Burst>{
    'flash full single read at 0': rd(_xip, 0, full),
    'flash full single read': rd(_xip + 0x40, 0, full),
    'flash 4 beat burst at 0': rd(_xip, 3, full),
    'flash 4 beat burst': rd(_xip + 0x80, 3, full),
    'flash 16 beat burst': rd(_xip + 0x100, 15, full),
    'flash 1 byte read': rd(_xip + 0x43, 0, 0),
    'flash 2 byte read': rd(_xip + 0x46, 0, 1),
    'flash 4 byte read': rd(_xip + 0x44, 0, 2),
    'flash 4 beat burst of 4 bytes': rd(_xip + 0x84, 3, 2),
    'flash 4 beat burst of 2 bytes': rd(_xip + 0x82, 3, 1),
    'flash bad WRAP length': rd(_xip + 0x40, 2, full, 2),
    'flash reserved burst type': rd(_xip + 0x40, 0, full, 3),
    'regs 1 byte read': rd(_regs + 0x13, 0, 0),
    if (echo != null) ...{
      'narrow slave 4 beat burst of 4 bytes': rd(_echo + 0x14, 3, 2),
      'narrow slave 1 byte read': rd(_echo + 0x1b, 0, 0),
    },
  };
  final writes = <String, Burst>{
    'regs 1 byte write': wr(
      _regs + 0x13,
      0,
      0xaa << 8 * (0x13 % bytes),
      1 << 0x13 % bytes,
    ),
    'regs 2 byte write': wr(
      _regs + 0x22,
      1,
      0xbbcc << 8 * (0x22 % bytes),
      3 << 0x22 % bytes,
    ),
    'regs 4 byte write': wr(
      _regs + 0x34,
      2,
      0x11223344 << 8 * (0x34 % bytes & ~3),
      0xf << (0x34 % bytes & ~3),
    ),
    'regs stray strobes outside the size': wr(
      _regs + 0x41,
      0,
      (BigInt.parse('ffffffffffffffff', radix: 16) &
              ((BigInt.one << dw) - BigInt.one))
          .toInt(),
      bytes == 8 ? 0xff : 0xf,
    ),
  };
  final results = <String, String>{};
  final readNames = reads.keys.toList();
  for (final n in readNames) {
    req.send(reads[n]!);
  }
  await waitUntil(sim, () => req.done, limit: 600000);
  for (var i = 0; i < readNames.length; i++) {
    final n = readNames[i];
    final x = reads[n]!;
    final beats = req.readResp[i];
    final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
    final errs = beats.map((b) => b.$3).toList();
    final expectBad = n.contains('bad WRAP') || n.contains('reserved');
    if (beats.length != x.beats) {
      results[n] = 'got ${beats.length} beats, want ${x.beats}';
    } else if (expectBad) {
      if (errs.any((e) => e == 0)) results[n] = 'no error on a bad burst';
    } else if (errs.any((e) => e != 0)) {
      results[n] = 'error response $errs';
    } else {
      for (var k = 0; k < beats.length; k++) {
        final a = addrs[k];
        int want;
        if (n.startsWith('flash')) {
          want = _flashWord(a, bytes);
        } else if (n.startsWith('regs')) {
          want = (a - _regs) & ~(bytes - 1);
        } else {
          // The 32-bit slave sees its own word address in its lane.
          final w = (a - _echo) & ~3;
          want = w << (8 * (a & (bytes - 1) & ~3));
        }
        final got = _lanes(beats[k].$2, a, x.size, bytes);
        if (got != _lanes(want, a, x.size, bytes)) {
          results[n] =
              'beat $k at 0x${a.toRadixString(16)} got '
              '0x${got.toRadixString(16)} want '
              '0x${_lanes(want, a, x.size, bytes).toRadixString(16)}';
          break;
        }
      }
    }
    results.putIfAbsent(n, () => '');
  }
  final writeNames = writes.keys.toList();
  for (final n in writeNames) {
    final x = writes[n]!;
    final before = req.writeResp.length;
    req.send(x);
    await waitUntil(sim, () => req.writeResp.length > before, limit: 20000);
    if (req.writeResp.last.$2 != 0) {
      results[n] = 'error response';
      continue;
    }
    final strb = regs.output('last_sel').value.toInt();
    final want = x.strb[0] & _laneMask(x.addr, x.size, bytes);
    if (strb != want) {
      results[n] = 'slave saw strobes $strb, want $want';
    } else {
      results[n] = '';
    }
  }
  await pins.stop();
  await sim.stop();
  results['bus errors'] = errors.join('; ');
  return results;
});

int _laneMask(int addr, int size, int bytes) {
  final lo = (addr & (bytes - 1)) & ~((1 << size) - 1);
  return ((1 << (1 << size)) - 1) << lo;
}

void main() {
  for (final dw in [32, 64]) {
    group('$dw-bit fabric', () {
      late final Map<String, String> results;
      setUpAll(() async {
        results = await _run(dw);
      });
      for (final n in [
        'flash full single read at 0',
        'flash full single read',
        'flash 4 beat burst at 0',
        'flash 4 beat burst',
        'flash 16 beat burst',
        'flash 1 byte read',
        'flash 2 byte read',
        'flash 4 byte read',
        'flash 4 beat burst of 4 bytes',
        'flash 4 beat burst of 2 bytes',
        'flash bad WRAP length',
        'flash reserved burst type',
        'regs 1 byte read',
        if (dw == 64) ...[
          'narrow slave 4 beat burst of 4 bytes',
          'narrow slave 1 byte read',
        ],
        'regs 1 byte write',
        'regs 2 byte write',
        'regs 4 byte write',
        'regs stray strobes outside the size',
        'bus errors',
      ]) {
        test(n, () => expect(results[n], '', reason: n));
      }
    });
  }
}
