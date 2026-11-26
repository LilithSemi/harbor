import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

import 'reg_bus.dart';

/// A running [HarborUart] with a register bus and a drivable RX pin.
class UartDut {
  final HarborUart uart;
  final Logic clk;
  final RegBus bus;
  final Logic rx;
  UartDut(this.uart, this.clk, this.bus, this.rx);

  /// Clock cycles of one serial bit: 16 times the divisor that [setDivisor]
  /// programs.
  int cyclesPerBit = 16;

  static Future<UartDut> start({
    HarborFabricKind kind = HarborFabricKind.wishbone,
    int maxSimTime = 4000000,
    int clockFrequency = 0,
  }) async {
    final uart = HarborUart(
      baseAddress: 0x10000000,
      fabricKind: kind,
      clockFrequency: clockFrequency,
    );
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final rx = Logic(name: 'rx');
    uart.input('clk').srcConnection! <= clk;
    uart.input('reset').srcConnection! <= reset;
    uart.input('rx').srcConnection! <= rx;
    final bus = RegBus.attach(uart, clk);
    await uart.build();
    reset.inject(1);
    bus.idle();
    rx.inject(1);
    Simulator.setMaxSimTime(maxSimTime);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    return UartDut(uart, clk, bus, rx);
  }

  Future<void> wait(int cycles) async {
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
    }
  }

  Future<int> read(int reg) => bus.read(reg);
  Future<void> write(int reg, int v) => bus.write(reg, v);

  /// Sets the baud divisor and leaves LCR at 8N1.
  Future<void> setDivisor(int divisor) async {
    await write(3, 0x83);
    await write(0, divisor & 0xff);
    await write(1, divisor >> 8);
    await write(3, 0x03);
    cyclesPerBit = 16 * divisor;
  }

  /// The interrupt output, sampled at the falling clock edge.
  Future<bool> irq() async {
    await clk.nextNegedge;
    return uart.interrupt.value.toInt() == 1;
  }

  /// Waits up to [cycles] cycles for the interrupt output to go high.
  Future<bool> waitIrq({int cycles = 20000}) async {
    for (var i = 0; i < cycles; i++) {
      if (await irq()) return true;
    }
    return false;
  }

  /// Sends one 8N1 frame on the RX pin.
  Future<void> sendByte(int byte) async {
    rx.inject(0);
    await wait(cyclesPerBit);
    for (var i = 0; i < 8; i++) {
      rx.inject((byte >> i) & 1);
      await wait(cyclesPerBit);
    }
    rx.inject(1);
    // The receiver samples the stop bit a few cycles after the frame ends,
    // because of the input synchronizer.
    await wait(cyclesPerBit + 4);
  }

  /// Collects [count] 8N1 frames from TX. The result holds fewer bytes when
  /// [maxCycles] pass first.
  Future<List<int>> collectTx(int count, {int maxCycles = 200000}) async {
    final out = <int>[];
    var spent = 0;
    final tx = uart.tx;
    while (out.length < count && spent < maxCycles) {
      await clk.nextNegedge;
      spent++;
      if (tx.value.toInt() != 0) continue;
      var byte = 0;
      for (var i = 0; i < 8; i++) {
        await wait(i == 0 ? cyclesPerBit + cyclesPerBit ~/ 2 : cyclesPerBit);
        await clk.nextNegedge;
        byte |= tx.value.toInt() << i;
      }
      await wait(cyclesPerBit);
      out.add(byte);
      spent += cyclesPerBit * 10;
    }
    return out;
  }
}
