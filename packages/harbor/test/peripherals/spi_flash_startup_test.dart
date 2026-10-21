import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Checks the SCK clocks sent with CS# high after reset, and that a bus read
/// issued in the first cycle after reset waits for them and then gets the
/// correct data from a flash model that decodes the opcode and address.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('startup clocks run with CS high, early read still correct', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final stb = Logic(name: 'stb');
    final addr = Logic(name: 'addr', width: 32);
    final miso = Logic(name: 'miso');

    final flash = HarborSpiFlashController(
      config: const HarborSpiFlashConfig(
        size: 1024 * 1024,
        mode: HarborSpiFlashMode.standard,
        readCommand: 0x03,
        addressBytes: 3,
        dummyCycles: 0,
      ),
      baseAddress: 0x20000000,
      busAddressWidth: 32,
      busDataWidth: 32,
    );
    flash.input('clk').srcConnection! <= clk;
    flash.input('reset').srcConnection! <= reset;
    flash.input('bus_CYC').srcConnection! <= stb;
    flash.input('bus_STB').srcConnection! <= stb;
    flash.input('bus_WE').srcConnection! <= Const(0);
    flash.input('bus_ADR').srcConnection! <= addr;
    flash.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 32);
    flash.input('bus_SEL').srcConnection! <=
        Const(0xF, width: flash.input('bus_SEL').width);
    flash.input('spi_miso').srcConnection! <= miso;
    flash.input('wr_req').srcConnection! <= Const(0);
    flash.input('wr_op').srcConnection! <= Const(0);
    flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
    flash.input('wr_len').srcConnection! <= Const(0, width: 9);
    flash.input('wr_data').srcConnection! <= Const(0, width: 8);

    await flash.build();

    final spiClk = flash.output('spi_clk');
    final csN = flash.output('spi_cs_n');
    final mosi = flash.output('spi_mosi');
    final ack = flash.output('bus_ACK');
    final dataOut = flash.output('bus_DAT_MISO');

    int byteAt(int a) => (a * 29 + 5) & 0xFF;
    const readAddr = 0x1234;
    final expected =
        byteAt(readAddr) |
        (byteAt(readAddr + 1) << 8) |
        (byteAt(readAddr + 2) << 16) |
        (byteAt(readAddr + 3) << 24);

    reset.inject(1);
    stb.inject(0);
    addr.inject(0);
    miso.inject(0);
    Simulator.setMaxSimTime(8000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;

    // Request in the first cycle that reset is low.
    reset.inject(0);
    addr.inject(readAddr);
    stb.inject(1);

    var prevClk = 0;
    var startupRises = 0;
    var seenLow = false;
    var frameRises = 0;
    var opcode = 0;
    var flashAddr = 0;
    var data = -1;
    for (var i = 0; i < 4000 && data < 0; i++) {
      await clk.nextPosedge;
      final cs = csN.value.toInt();
      final sc = spiClk.value.toInt();
      if (cs == 1 && !seenLow) {
        if (sc == 1 && prevClk == 0) {
          startupRises++;
        }
        expect(
          ack.value.isValid && ack.value.toBool(),
          isFalse,
          reason: 'acked during startup',
        );
      } else if (cs == 0) {
        seenLow = true;
        if (sc == 1 && prevClk == 0) {
          final bit = mosi.value.toInt();
          if (frameRises < 8) {
            opcode = (opcode << 1) | bit;
          } else if (frameRises < 32) {
            flashAddr = (flashAddr << 1) | bit;
          }
          final idx = frameRises - 32;
          final b = byteAt(flashAddr + (idx ~/ 8));
          miso.inject(idx >= 0 ? (b >> (7 - idx % 8)) & 1 : 0);
          frameRises++;
        }
      }
      prevClk = sc;
      if (ack.value.isValid && ack.value.toBool()) {
        data = dataOut.value.toInt();
      }
    }
    stb.inject(0);
    await clk.nextPosedge;
    await Simulator.endSimulation();

    expect(
      startupRises,
      greaterThanOrEqualTo(8),
      reason: 'SCK rising edges with CS# high before the first command',
    );
    expect(opcode, equals(0x03));
    expect(flashAddr, equals(readAddr));
    expect(data, equals(expected));
  });
}
