import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _ctrl = 0x00;
const _intEnable = 0x10;
int _chBase(int ch) => 0x40 * (ch + 1);
int _chCtrl(int ch) => _chBase(ch) + 0x00;
int _chSrc(int ch) => _chBase(ch) + 0x10;
int _chDst(int ch) => _chBase(ch) + 0x18;
int _chLen(int ch) => _chBase(ch) + 0x20;

/// Copies [beats] words with a HarborDmaController on a plain Wishbone
/// slave. The slave gives ACK in the STB cycle, or one cycle later when
/// [waitStates] is 1. Returns the cycles of each write ACK.
Future<List<int>> _copy(int beats, int waitStates) async {
  final dma = HarborDmaController(baseAddress: 0x30000000, channels: 2);
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final stb = Logic(name: 'stb');
  final we = Logic(name: 'we');
  final adr = Logic(name: 'adr', width: 12);
  final mosi = Logic(name: 'mosi', width: 32);
  dma.input('clk').srcConnection! <= clk;
  dma.input('reset').srcConnection! <= reset;
  dma.input('bus_CYC').srcConnection! <= stb;
  dma.input('bus_STB').srcConnection! <= stb;
  dma.input('bus_WE').srcConnection! <= we;
  dma.input('bus_ADR').srcConnection! <= adr;
  dma.input('bus_DAT_MOSI').srcConnection! <= mosi;
  dma.input('bus_SEL').srcConnection! <=
      Const(0xF, width: dma.input('bus_SEL').width);

  final cyc = dma.output('dma_CYC');
  final mStb = dma.output('dma_STB');
  final req = (cyc & mStb).named('req');
  final Logic ack;
  if (waitStates == 0) {
    ack = req;
  } else {
    final ackReg = Logic(name: 'ack_reg');
    Sequential(clk, reset: reset, [ackReg < req & ~ackReg]);
    ack = ackReg;
  }
  dma.input('dma_ACK').srcConnection! <= ack;
  // Read data is the address.
  dma.input('dma_DAT_MISO').srcConnection! <= dma.output('dma_ADR');
  for (final p in dma.inputs.keys.toList()) {
    if (!p.startsWith('dma_') || p == 'dma_ACK' || p == 'dma_DAT_MISO') {
      continue;
    }
    dma.input(p).srcConnection! <= Const(0, width: dma.input(p).width);
  }

  await dma.build();
  final irq = dma.output('interrupt');
  reset.inject(1);
  stb.inject(0);
  we.inject(0);
  adr.inject(0);
  mosi.inject(0);
  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  await clk.nextPosedge;

  Future<void> bw(int a, int d) async {
    adr.inject(a);
    mosi.inject(d);
    we.inject(1);
    stb.inject(1);
    await clk.nextPosedge;
    while (dma.output('bus_ACK').value.toInt() != 1) {
      await clk.nextPosedge;
    }
    stb.inject(0);
    we.inject(0);
    await clk.nextPosedge;
  }

  await bw(_ctrl, 1);
  await bw(_intEnable, 1);
  await bw(_chSrc(0), 0);
  await bw(_chDst(0), 0x400);
  await bw(_chLen(0), beats * 4);
  await bw(_chCtrl(0), 1);
  final writes = <int>[];
  for (var c = 0; c < 4000; c++) {
    await clk.nextNegedge;
    if (req.value.toInt() == 1 &&
        ack.value.toInt() == 1 &&
        dma.output('dma_WE').value.toInt() == 1) {
      writes.add(c);
    }
    if (irq.value.toInt() == 1) break;
  }
  await Simulator.endSimulation();
  return writes;
}

void main() {
  tearDown(() async => Simulator.reset());

  // One beat is a read and a write. The raw dma_stb and dma_ack ports that
  // the memory port replaced took the same cycles.
  for (final (waitStates, cycles) in [(0, 4), (1, 6)]) {
    test('DMA copies one beat every $cycles cycles on a plain Wishbone '
        'slave with $waitStates wait states', () async {
      final writes = await _copy(16, waitStates);
      expect(writes.length, 16);
      for (var i = 1; i < writes.length; i++) {
        expect(writes[i] - writes[i - 1], cycles, reason: 'beat $i');
      }
    });
  }
}
