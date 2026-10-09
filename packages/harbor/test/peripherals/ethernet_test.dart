import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register word indices (the bus presents a word index).
const _intStatus = 0x20;
const _intEnable = 0x28;
const _txCtrl = 0x40;
const _txDescBase = 0x50;
const _txLen = 0x58;
const _rxCtrl = 0x60;
const _rxStatus = 0x68;
const _rxDescBase = 0x70;
const _mdioCtrl = 0x80;
const _mdioData = 0x88;
const _txData = 0x90;
const _rxData = 0x98;
const _rxLen = 0xA0;

List<int> _bits(int v, int w) => [
  for (var i = w - 1; i >= 0; i--) (v >> i) & 1,
];

/// Reference Ethernet FCS CRC32 (reflected, 0xEDB88320), matching the hardware.
int _ethCrc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final by in bytes) {
    for (var i = 0; i < 8; i++) {
      final x = ((by >> i) & 1) ^ (c & 1);
      c >>= 1;
      if (x != 0) c ^= 0xEDB88320;
    }
  }
  return c & 0xFFFFFFFF;
}

void main() {
  group('HarborEthernetConfig', () {
    test('defaults to gigabit RGMII', () {
      const config = HarborEthernetConfig();
      expect(config.maxSpeed, equals(HarborEthernetSpeed.speed1000));
      expect(config.phyInterface, equals(HarborEthernetPhyInterface.rgmii));
    });

    test('toPrettyString', () {
      const config = HarborEthernetConfig(checksumOffload: true);
      final pretty = config.toPrettyString();
      expect(pretty, contains('1000 Mbps'));
      expect(pretty, contains('rgmii'));
      expect(pretty, contains('checksum offload'));
    });
  });

  group('HarborEthernetMac', () {
    test('creates gigabit controller', () {
      final eth = HarborEthernetMac(
        config: const HarborEthernetConfig(),
        baseAddress: 0x40000000,
      );
      expect(eth.bus, isNotNull);
      expect(eth.interrupt.width, equals(1));
    });

    test('100M has narrower data bus', () {
      final eth100 = HarborEthernetMac(
        config: const HarborEthernetConfig(
          maxSpeed: HarborEthernetSpeed.speed100,
        ),
        baseAddress: 0x40000000,
      );
      // 10/100 uses 4-bit data, gigabit uses 8-bit
      expect(eth100.output('txd').width, equals(4));

      final eth1000 = HarborEthernetMac(
        config: const HarborEthernetConfig(
          maxSpeed: HarborEthernetSpeed.speed1000,
        ),
        baseAddress: 0x40000000,
      );
      expect(eth1000.output('txd').width, equals(8));
    });

    test('DT node', () {
      final eth = HarborEthernetMac(
        config: const HarborEthernetConfig(
          phyInterface: HarborEthernetPhyInterface.rmii,
          maxSpeed: HarborEthernetSpeed.speed100,
        ),
        baseAddress: 0x40000000,
      );
      final dt = eth.dtNode;
      expect(dt.compatible.first, equals('harbor,ethernet'));
      expect(dt.properties['phy-mode'], equals('rmii'));
      expect(dt.properties['max-speed'], equals(100));
    });
  });

  group('HarborEthernetMac MDIO engine', () {
    late HarborEthernetMac eth;
    late Logic clk, reset, stb, we, adr, mosi, mdioIn;
    late Logic mdc, mdioOut, mdioOe, irq;
    late Logic txd, txEn, rxdSig, rxDvSig;
    late List<Logic> mem; // 16-word DMA memory model

    Future<void> bw(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (eth.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<int> br(int addr) async {
      adr.inject(addr);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (eth.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = eth.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> setUpDut({List<int> dmaMem = const []}) async {
      eth = HarborEthernetMac(
        config: const HarborEthernetConfig(
          maxSpeed: HarborEthernetSpeed.speed100,
        ),
        baseAddress: 0x40000000,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 12);
      mosi = Logic(name: 'mosi', width: 32);
      mdioIn = Logic(name: 'mdio_in');

      eth.input('clk').srcConnection! <= clk;
      eth.input('reset').srcConnection! <= reset;
      eth.input('bus_CYC').srcConnection! <= stb;
      eth.input('bus_STB').srcConnection! <= stb;
      eth.input('bus_WE').srcConnection! <= we;
      eth.input('bus_ADR').srcConnection! <= adr;
      eth.input('bus_DAT_MOSI').srcConnection! <= mosi;
      eth.input('bus_SEL').srcConnection! <=
          Const(0xF, width: eth.input('bus_SEL').width);
      eth.input('mdio_in').srcConnection! <= mdioIn;
      rxdSig = Logic(name: 'rxd_sig', width: eth.input('rxd').width);
      rxDvSig = Logic(name: 'rx_dv_sig');
      eth.input('rx_clk').srcConnection! <= clk;
      eth.input('rx_dv').srcConnection! <= rxDvSig;
      eth.input('rxd').srcConnection! <= rxdSig;
      // 16-word memory model on the master port (ack = stb, single-cycle).
      final initVals = [
        for (var i = 0; i < 16; i++) i < dmaMem.length ? dmaMem[i] : 0,
      ];
      mem = [for (var i = 0; i < 16; i++) Logic(name: 'mem$i', width: 32)];
      final mStb = eth.output('dma_stb');
      final mWe = eth.output('dma_we');
      final mAddr = eth.output('dma_addr');
      final mWdata = eth.output('dma_wdata');
      final mIdx = mAddr.getRange(2, 6);
      Sequential(
        clk,
        reset: reset,
        resetValues: {
          for (var i = 0; i < 16; i++) mem[i]: Const(initVals[i], width: 32),
        },
        [
          If(
            mStb & mWe,
            then: [
              for (var i = 0; i < 16; i++)
                If(mIdx.eq(Const(i, width: 4)), then: [mem[i] < mWdata]),
            ],
          ),
        ],
      );
      Logic mRd = mem[15];
      for (var i = 14; i >= 0; i--) {
        mRd = mux(mIdx.eq(Const(i, width: 4)), mem[i], mRd);
      }
      eth.input('dma_rdata').srcConnection! <= mRd;
      eth.input('dma_ack').srcConnection! <= mStb;

      await eth.build();
      mdc = eth.output('mdc');
      mdioOut = eth.output('mdio_out');
      mdioOe = eth.output('mdio_oe');
      irq = eth.output('interrupt');
      txd = eth.output('txd');
      txEn = eth.output('tx_en');

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      mdioIn.inject(0);
      rxdSig.inject(0);
      rxDvSig.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      await bw(_intEnable, 0x01); // unmask MDIO-done
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('serializes a clause-22 write frame', () async {
      await setUpDut();
      await bw(_mdioData, 0xABCD);
      // phy 3, reg 7, write, start.
      await bw(_mdioCtrl, 7 | (3 << 5) | (0 << 10) | (1 << 11));

      // Capture the line on each MDC falling edge (where a bit is driven).
      final captured = <int>[];
      var prevMdc = mdc.value.toInt();
      for (var i = 0; i < 4000 && captured.length < 64; i++) {
        await clk.nextPosedge;
        final m = mdc.value.toInt();
        if (prevMdc == 1 && m == 0) captured.add(mdioOut.value.toInt());
        prevMdc = m;
      }

      final expected = [
        ..._bits(0xFFFFFFFF, 32), // preamble
        0, 1, // ST
        0, 1, // OP write
        ..._bits(3, 5), // PHYAD
        ..._bits(7, 5), // REGAD
        1, 0, // TA
        ..._bits(0xABCD, 16), // DATA
      ];
      expect(captured, equals(expected));
      // Wait out completion and check the done IRQ.
      for (var i = 0; i < 200 && irq.value.toInt() == 0; i++) {
        await clk.nextPosedge;
      }
      expect(irq.value.toInt(), equals(1));
      await Simulator.endSimulation();
    });

    test('reads PHY data and releases the line for turnaround', () async {
      await setUpDut();
      mdioIn.inject(1); // PHY drives the data window all-ones
      // phy 3, reg 7, read, start.
      await bw(_mdioCtrl, 7 | (3 << 5) | (1 << 10) | (1 << 11));

      var sawRelease = false;
      var done = false;
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        if (mdioOe.value.toInt() == 0) sawRelease = true;
        if (irq.value.toInt() == 1) {
          done = true;
          break;
        }
      }
      expect(done, isTrue);
      expect(sawRelease, isTrue); // host released the line for the PHY
      expect(await br(_mdioData) & 0xFFFF, equals(0xFFFF));
      await Simulator.endSimulation();
    });

    test('frames a payload with preamble, SFD, and CRC32 FCS', () async {
      await setUpDut();
      await bw(_intEnable, 0x02); // unmask TX-done
      const payload = [0x01, 0x02, 0x03, 0x04];
      final word =
          payload[0] |
          (payload[1] << 8) |
          (payload[2] << 16) |
          (payload[3] << 24);
      await bw(_txData, word);
      await bw(_txLen, payload.length);

      // Start the frame inline (no trailing cycle) so capture begins on the
      // first emitted nibble.
      adr.inject(_txCtrl);
      mosi.inject(0x1 | 0x2); // enable + start
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (eth.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);

      // One nibble per cycle on the 4-bit MII bus while tx_en is asserted.
      final nibbles = <int>[];
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        if (txEn.value.toInt() == 1) {
          nibbles.add(txd.value.toInt() & 0xF);
        } else if (nibbles.isNotEmpty) {
          break; // tx_en dropped: frame done
        }
      }
      // Reassemble bytes, low nibble first.
      final bytes = <int>[
        for (var k = 0; k + 1 < nibbles.length; k += 2)
          nibbles[k] | (nibbles[k + 1] << 4),
      ];

      final fcs = _ethCrc32(payload) ^ 0xFFFFFFFF;
      final expected = [
        0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, // preamble
        0xD5, // SFD
        ...payload,
        fcs & 0xFF, (fcs >> 8) & 0xFF, (fcs >> 16) & 0xFF, (fcs >> 24) & 0xFF,
      ];
      expect(bytes, equals(expected));
      expect(await br(_intStatus) & 0x02, equals(0x02)); // TX-done IRQ
      await Simulator.endSimulation();
    });

    // Drive a frame on rxd/rx_dv: 15 preamble nibbles (0x5) + the SFD high
    // nibble (0xD), then the bytes (low nibble first), one nibble per cycle.
    Future<void> driveRxFrame(List<int> bytes) async {
      List<int> nib(List<int> bs) => [
        for (final b in bs) ...[b & 0xF, (b >> 4) & 0xF],
      ];
      final stream = [...List.filled(15, 0x5), 0xD, ...nib(bytes)];
      for (final n in stream) {
        rxdSig.inject(n);
        rxDvSig.inject(1);
        await clk.nextPosedge;
      }
      rxDvSig.inject(0);
      rxdSig.inject(0);
      await clk.nextPosedge;
      await clk.nextPosedge;
    }

    test('receives a frame and validates the FCS', () async {
      await setUpDut();
      const payload = [0x01, 0x02, 0x03, 0x04];
      final fcs = _ethCrc32(payload) ^ 0xFFFFFFFF;
      final fcsBytes = [
        fcs & 0xFF,
        (fcs >> 8) & 0xFF,
        (fcs >> 16) & 0xFF,
        (fcs >> 24) & 0xFF,
      ];
      // The CRC32 register over message+FCS lands on the standard residue.
      expect(_ethCrc32([...payload, ...fcsBytes]), equals(0xDEBB20E3));

      await driveRxFrame([...payload, ...fcsBytes]);

      expect(await br(_rxStatus) & 0x01, equals(0x01)); // FCS good
      expect(await br(_rxStatus) & 0x02, equals(0)); // not bad
      expect(await br(_rxLen), equals(payload.length));
      // First received word, little-endian (byte 0 in the low lane).
      expect(await br(_rxData), equals(0x04030201));
      await Simulator.endSimulation();
    });

    test('flags a frame with a corrupted FCS', () async {
      await setUpDut();
      const payload = [0xAA, 0xBB, 0xCC, 0xDD];
      final fcs = (_ethCrc32(payload) ^ 0xFFFFFFFF) ^ 0x00000010; // corrupt
      final fcsBytes = [
        fcs & 0xFF,
        (fcs >> 8) & 0xFF,
        (fcs >> 16) & 0xFF,
        (fcs >> 24) & 0xFF,
      ];

      await driveRxFrame([...payload, ...fcsBytes]);

      expect(await br(_rxStatus) & 0x01, equals(0)); // not good
      expect(await br(_rxStatus) & 0x02, equals(0x02)); // FCS bad
      await Simulator.endSimulation();
    });

    test('transmits a frame from memory via a TX descriptor', () async {
      const payload = [0x01, 0x02, 0x03, 0x04];
      // Descriptor at word 0: [bufAddr=0x20, len=4]. Buffer word at word 8.
      await setUpDut(dmaMem: [0x20, 4, 0, 0, 0, 0, 0, 0, 0x04030201]);
      await bw(_intEnable, 0x02); // TX-done
      await bw(_txDescBase, 0); // descriptor table at byte 0
      await bw(_txCtrl, 0x1 | 0x4); // enable + DMA start

      final nibbles = <int>[];
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        if (txEn.value.toInt() == 1) {
          nibbles.add(txd.value.toInt() & 0xF);
        } else if (nibbles.isNotEmpty) {
          break;
        }
      }
      final bytes = <int>[
        for (var k = 0; k + 1 < nibbles.length; k += 2)
          nibbles[k] | (nibbles[k + 1] << 4),
      ];
      final fcs = _ethCrc32(payload) ^ 0xFFFFFFFF;
      final expected = [
        0x55,
        0x55,
        0x55,
        0x55,
        0x55,
        0x55,
        0x55,
        0xD5,
        ...payload,
        fcs & 0xFF,
        (fcs >> 8) & 0xFF,
        (fcs >> 16) & 0xFF,
        (fcs >> 24) & 0xFF,
      ];
      expect(bytes, equals(expected)); // frame came from the memory buffer
      // Wait for the DMA to write the descriptor status back.
      for (var i = 0; i < 200 && mem[1].value.toInt() != 0; i++) {
        await clk.nextPosedge;
      }
      expect(mem[1].value.toInt(), equals(0)); // descriptor status written back
      expect(await br(_intStatus) & 0x02, equals(0x02)); // TX-done
      await Simulator.endSimulation();
    });

    test('receives a frame into memory via an RX descriptor', () async {
      const payload = [0x01, 0x02, 0x03, 0x04];
      final fcs = _ethCrc32(payload) ^ 0xFFFFFFFF;
      final fcsBytes = [
        fcs & 0xFF,
        (fcs >> 8) & 0xFF,
        (fcs >> 16) & 0xFF,
        (fcs >> 24) & 0xFF,
      ];
      // RX descriptor at word 0: [bufAddr=0x20, 0]. Buffer at word 8.
      await setUpDut(dmaMem: [0x20, 0]);
      await bw(_intEnable, 0x08); // RX-done
      await bw(_rxDescBase, 0); // descriptor at byte 0
      await bw(_rxCtrl, 0x1 | 0x2); // enable + RX DMA enable

      await driveRxFrame([...payload, ...fcsBytes]);
      // Wait for the DMA to write the descriptor length back.
      for (var i = 0; i < 200 && mem[1].value.toInt() == 0; i++) {
        await clk.nextPosedge;
      }

      expect(
        mem[8].value.toInt(),
        equals(0x04030201),
      ); // payload DMA'd to buffer
      expect(
        mem[1].value.toInt(),
        equals(payload.length),
      ); // length written back
      expect(await br(_intStatus) & 0x08, equals(0x08)); // RX-done
      await Simulator.endSimulation();
    });
  });
}
