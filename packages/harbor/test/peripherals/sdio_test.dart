import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register byte offsets: each register in its own 8-byte slot (the byte-addressed
// fabric decodes byte-offset >> 3).
const _ctrl = 0x00;
const _clkDiv = 0x10;
const _cmd = 0x18;
const _cmdArg = 0x20;
const _resp0 = 0x28;
const _data = 0x48;
const _blkSize = 0x50;
const _intStatus = 0x60;
const _intEnable = 0x68;
const _admaAddr = 0x70;

/// Reference SD CRC7 (x^7 + x^3 + 1) over an MSB-first bit list, mirroring the
/// hardware. Returns 7 bits, MSB-first.
List<int> _crc7(List<int> bits) {
  var c = List<int>.filled(7, 0);
  for (final b in bits) {
    final inv = b ^ c[6];
    c = [inv, c[0], c[1], c[2] ^ inv, c[3], c[4], c[5]];
  }
  return [c[6], c[5], c[4], c[3], c[2], c[1], c[0]];
}

/// Reference SD data CRC16 (CCITT) over an MSB-first bit list. Returns 16 bits,
/// MSB-first.
List<int> _crc16(List<int> bits) {
  var c = List<int>.filled(16, 0);
  for (final b in bits) {
    final inv = b ^ c[15];
    c = [
      for (var i = 0; i < 16; i++)
        if (i == 0)
          inv
        else if (i == 5)
          c[4] ^ inv
        else if (i == 12)
          c[11] ^ inv
        else
          c[i - 1],
    ];
  }
  return [for (var i = 15; i >= 0; i--) c[i]];
}

List<int> _bitsMsb(int value, int width) => [
  for (var i = width - 1; i >= 0; i--) (value >> i) & 1,
];

/// A 48-bit short response frame carrying [payload] (CRC is don't-care here:
/// the controller does not verify the command-response CRC).
List<int> _resp48(int payload) => [
  0,
  0,
  ..._bitsMsb(0, 6),
  ..._bitsMsb(payload, 32),
  ..._bitsMsb(0, 7),
  1,
];

/// The 4 bytes of a 32-bit word in transmit order (byte 0, the low lane,
/// first), each MSB-first: the SD data-line bit order.
List<int> _wordBitsMsb(int word) => [
  for (var byte = 0; byte < 4; byte++)
    ..._bitsMsb((word >> (byte * 8)) & 0xFF, 8),
];

/// The 4-bit-wide DAT line groups for one 32-bit word: a start group (0), then
/// 8 data nibbles (byte 0 first, high nibble first, DAT3 = bit 7), then 16
/// per-lane CRC16 groups. Each value is the 4-bit vector on DAT[3:0].
List<int> _fourBitStream(int word) {
  final bytes = [for (var i = 0; i < 4; i++) (word >> (i * 8)) & 0xFF];
  final data = <int>[];
  for (final b in bytes) {
    data.add((b >> 4) & 0xF);
    data.add(b & 0xF);
  }
  final laneCrc = [
    for (var l = 0; l < 4; l++) _crc16([for (final g in data) (g >> l) & 1]),
  ];
  final crc = [
    for (var t = 0; t < 16; t++)
      [for (var l = 0; l < 4; l++) laneCrc[l][t] << l].reduce((a, b) => a | b),
  ];
  return [0, ...data, ...crc];
}

void main() {
  group('HarborSdioConfig', () {
    test('SD preset', () {
      const config = HarborSdioConfig.sd();
      expect(config.maxBusWidth, equals(HarborSdioBusWidth.four));
      expect(config.maxSpeed, equals(HarborSdioSpeed.highSpeed));
      expect(config.supportsIo, isFalse);
      expect(config.maxIoFunctions, equals(0));
    });

    test('WiFi preset', () {
      const config = HarborSdioConfig.wifi();
      expect(config.supportsIo, isTrue);
      expect(config.maxIoFunctions, equals(2));
    });

    test('UHS preset', () {
      const config = HarborSdioConfig.uhs();
      expect(config.maxSpeed, equals(HarborSdioSpeed.sdr104));
      expect(config.supports1v8, isTrue);
      expect(config.maxIoFunctions, equals(7));
    });

    test('eMMC preset', () {
      const config = HarborSdioConfig.emmc();
      expect(config.maxBusWidth, equals(HarborSdioBusWidth.eight));
      expect(config.supportsEmmc, isTrue);
      expect(config.maxIoFunctions, equals(0));
    });

    test('toPrettyString', () {
      const config = HarborSdioConfig.wifi();
      final pretty = config.toPrettyString();
      expect(pretty, contains('4-bit'));
      expect(pretty, contains('SDIO I/O'));
    });
  });

  group('HarborSdioController', () {
    test('creates with SD config', () {
      final sdio = HarborSdioController(baseAddress: 0x60000000);
      expect(sdio.bus, isNotNull);
      expect(sdio.interrupt.width, equals(1));
    });

    test('DT compatible for SD vs eMMC', () {
      final sd = HarborSdioController(baseAddress: 0x60000000);
      expect(sd.dtNode.compatible.first, equals('harbor,sdhci'));

      final emmc = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig.emmc(),
      );
      expect(emmc.dtNode.compatible.first, equals('harbor,sdhci-emmc'));
    });

    test('bus width in DT', () {
      final sd = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig(maxBusWidth: HarborSdioBusWidth.eight),
      );
      expect(sd.dtNode.properties['bus-width'], equals(8));
    });
  });

  group('HarborSdioController CMD engine', () {
    late HarborSdioController sdio;
    late Logic clk, reset, stb, we, adr, mosi;
    late Logic cmdIn, cmdOut, cmdOe, sdClk, irq;
    late Logic datIn, datOut, datOe;
    late List<Logic> mem; // ADMA bus-master memory model (16 words)

    Future<void> busWrite(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (sdio.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    // A read that keeps STB asserted for `hold` extra cycles after ACK, the way
    // a master that is slow to react does. ACK is a one-cycle pulse, so the
    // handler must not re-enter and run the access a second time.
    Future<int> busReadHeld(int addr, int hold) async {
      adr.inject(addr);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (sdio.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = sdio.output('bus_DAT_MISO').value.toInt();
      for (var i = 0; i < hold; i++) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<int> busRead(int addr) async {
      adr.inject(addr);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (sdio.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = sdio.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> setUpDut({
      List<int> dmaMem = const [],
      int ackDelay = 0,
      int fifoDepth = 16,
      int dmaDataWidth = 32,
    }) async {
      sdio = HarborSdioController(
        baseAddress: 0x60000000,
        rxFifoDepth: fifoDepth,
        dmaDataWidth: dmaDataWidth,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 12);
      mosi = Logic(name: 'mosi', width: 32);
      cmdIn = Logic(name: 'cmd_in');
      datIn = Logic(name: 'dat_in', width: 4);

      sdio.input('clk').srcConnection! <= clk;
      sdio.input('reset').srcConnection! <= reset;
      sdio.input('bus_CYC').srcConnection! <= stb;
      sdio.input('bus_STB').srcConnection! <= stb;
      sdio.input('bus_WE').srcConnection! <= we;
      sdio.input('bus_ADR').srcConnection! <= adr;
      sdio.input('bus_DAT_MOSI').srcConnection! <= mosi;
      sdio.input('bus_SEL').srcConnection! <=
          Const(0xF, width: sdio.input('bus_SEL').width);
      sdio.input('sd_cmd_in').srcConnection! <= cmdIn;
      sdio.input('sd_cd').srcConnection! <= Const(0);
      sdio.input('sd_dat_in').srcConnection! <= datIn;

      // A 16-word memory model on the ADMA master port. [ackDelay] holds every
      // beat off for that many cycles before acking, which is what a real DDR
      // controller does and what the 1-cycle model hid.
      final initVals = [
        for (var i = 0; i < 16; i++) i < dmaMem.length ? dmaMem[i] : 0,
      ];
      mem = [for (var i = 0; i < 16; i++) Logic(name: 'mem$i', width: 32)];
      final mStb = sdio.output('dma_stb');
      final mWe = sdio.output('dma_we');
      final mAddr = sdio.output('dma_addr');
      final mWdata = sdio.output('dma_wdata');
      final mSel = sdio.output('dma_sel');
      final mIdx = mAddr.getRange(2, 6); // 32-bit word index 0..15
      final mPair = mAddr.getRange(3, 6); // 64-bit beat index 0..7
      final ackCnt = Logic(name: 'ack_cnt', width: 8);
      final ackNow = (mStb & ackCnt.eq(Const(ackDelay, width: 8))).named(
        'ack_now',
      );
      // Byte-enables decide which half of a 64-bit beat commits, so a packed
      // beat (SEL=0xFF) lands both words and a half beat lands only its own.
      final selLo = mSel.getRange(0, 4).or().named('sel_lo');
      final selHi = dmaDataWidth == 64
          ? mSel.getRange(4, 8).or().named('sel_hi')
          : Const(0);
      Sequential(
        clk,
        reset: reset,
        resetValues: {
          for (var i = 0; i < 16; i++) mem[i]: Const(initVals[i], width: 32),
          ackCnt: Const(0, width: 8),
        },
        [
          If(
            mStb,
            then: [
              If(
                ackCnt.lt(Const(ackDelay, width: 8)),
                then: [ackCnt < (ackCnt + Const(1, width: 8))],
              ),
            ],
            orElse: [ackCnt < Const(0, width: 8)],
          ),
          If(
            ackNow & mWe,
            then: [
              if (dmaDataWidth == 32)
                for (var i = 0; i < 16; i++)
                  If(mIdx.eq(Const(i, width: 4)), then: [mem[i] < mWdata])
              else
                for (var p = 0; p < 8; p++)
                  If(
                    mPair.eq(Const(p, width: 3)),
                    then: [
                      If(selLo, then: [mem[2 * p] < mWdata.getRange(0, 32)]),
                      If(
                        selHi,
                        then: [mem[2 * p + 1] < mWdata.getRange(32, 64)],
                      ),
                    ],
                  ),
            ],
          ),
        ],
      );
      Logic mRd;
      if (dmaDataWidth == 32) {
        mRd = mem[15];
        for (var i = 14; i >= 0; i--) {
          mRd = mux(mIdx.eq(Const(i, width: 4)), mem[i], mRd);
        }
      } else {
        mRd = [mem[15], mem[14]].swizzle();
        for (var p = 6; p >= 0; p--) {
          mRd = mux(
            mPair.eq(Const(p, width: 3)),
            [mem[2 * p + 1], mem[2 * p]].swizzle(),
            mRd,
          );
        }
      }
      sdio.input('dma_rdata').srcConnection! <= mRd;
      sdio.input('dma_ack').srcConnection! <= ackNow;

      await sdio.build();

      cmdOut = sdio.output('sd_cmd_out');
      cmdOe = sdio.output('sd_cmd_oe');
      sdClk = sdio.output('sd_clk');
      irq = sdio.output('interrupt');
      datOut = sdio.output('sd_dat_out');
      datOe = sdio.output('sd_dat_oe');

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      cmdIn.inject(1); // CMD line idles high
      datIn.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Enable, fastest clock (toggle every cycle), unmask cmd-done + timeout.
      await busWrite(_clkDiv, 0);
      await busWrite(_intEnable, 0x11);
      await busWrite(_ctrl, 0x1);
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('serializes a command frame with a correct CRC7', () async {
      await setUpDut();

      const index = 17; // READ_SINGLE_BLOCK
      const arg = 0xDEADBEEF;
      await busWrite(_cmdArg, arg);
      await busWrite(_cmd, index); // resp type 0 (none)

      // Sample the CMD line at each SD rising edge: the host drives a bit on the
      // falling edge, the card samples it on the next rising edge.
      final captured = <int>[];
      var prevClk = sdClk.value.toInt();
      for (var i = 0; i < 300; i++) {
        await clk.nextPosedge;
        final c = sdClk.value.toInt();
        if (prevClk == 0 && c == 1) captured.add(cmdOut.value.toInt());
        prevClk = c;
      }

      // Expected 48-bit frame: start, tx, index, arg, CRC7, end.
      final content = [0, 1, ..._bitsMsb(index, 6), ..._bitsMsb(arg, 32)];
      final expected = [...content, ..._crc7(content), 1];

      // Drop the idle ones held before the start bit, take the 48-bit frame.
      final start = captured.indexOf(0);
      expect(start, greaterThanOrEqualTo(0));
      expect(captured.length, greaterThanOrEqualTo(start + 48));
      expect(captured.sublist(start, start + 48), equals(expected));

      expect(await busRead(_intStatus) & 0x01, equals(0x01)); // cmd-done
      await Simulator.endSimulation();
    });

    test('captures a short response into RESP0', () async {
      await setUpDut();

      const payload = 0x12345678;
      // 48-bit response: start(0), tx(0), index echo(6), payload(32), crc7(7),
      // end(1). RESP0 should be the 32-bit payload.
      final frame = [
        0,
        0,
        ..._bitsMsb(17, 6),
        ..._bitsMsb(payload, 32),
        ..._bitsMsb(0, 7),
        1,
      ];

      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6)); // resp type 1 (short)

      // After the host releases the line, present one response bit per SD
      // period: inject on the falling-edge posedge (sd_clk just went low) so it
      // is stable for the card-sample rising edge that follows.
      var sawDrive = false;
      var k = 0;
      for (var i = 0; i < 1200; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        if (sawDrive &&
            !sending &&
            sdClk.value.toInt() == 0 &&
            k < frame.length) {
          cmdIn.inject(frame[k]);
          k++;
        }
        if (irq.value.toInt() == 1) break;
      }

      expect(k, equals(frame.length)); // all response bits consumed
      expect(await busRead(_intStatus) & 0x01, equals(0x01)); // cmd-done
      expect(await busRead(_resp0), equals(payload));
      await Simulator.endSimulation();
    });

    test('reports a timeout when the card never responds', () async {
      await setUpDut();

      await busWrite(_cmdArg, 0);
      cmdIn.inject(1); // line stays idle high: no start bit ever
      await busWrite(_cmd, 55 | (1 << 6)); // resp type 1 (short)

      var done = false;
      for (var i = 0; i < 6000; i++) {
        await clk.nextPosedge;
        if (irq.value.toInt() == 1) {
          done = true;
          break;
        }
      }
      expect(done, isTrue);
      expect(await busRead(_intStatus) & 0x10, equals(0x10)); // timeout bit
      await Simulator.endSimulation();
    });

    test('reads a block into the data register with a good CRC16', () async {
      await setUpDut();

      const word = 0xA5A5F00F;
      await busWrite(_blkSize, 4); // 4-byte block = one word
      await busWrite(_intEnable, 0x12); // irq on data-done / timeout only
      await busWrite(_cmdArg, 0);
      // index 17, short response, data present, read direction.
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9));

      // Drive the command response, then the data block on DAT0. Both feed one
      // bit per SD period on the falling-edge posedge ahead of each sample.
      final resp = _resp48(0);
      final dataBits = _wordBitsMsb(word);
      final datStream = [0, ...dataBits, ..._crc16(dataBits)]; // start+data+crc
      final total = resp.length + datStream.length;

      var sawDrive = false;
      var prevSdLow = sdClk.value.toInt() == 0;
      var idx = 0;
      for (var i = 0; i < 6000; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        final sdLow = sdClk.value.toInt() == 0;
        if (sawDrive && !sending && sdLow && !prevSdLow && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(datStream[idx - resp.length]);
          }
          idx++;
        }
        prevSdLow = sdLow;
        if (irq.value.toInt() == 1) break; // data-done
      }

      final status = await busRead(_intStatus);
      expect(status & 0x02, equals(0x02)); // data-done
      expect(status & 0x08, equals(0)); // no CRC error
      expect(await busRead(_data), equals(word));
      await Simulator.endSimulation();
    });

    test(
      'a corrupted block CRC16 raises the data-CRC-error interrupt',
      () async {
        await setUpDut();

        const word = 0xA5A5F00F;
        await busWrite(_blkSize, 4);
        await busWrite(
          _intEnable,
          0x1a,
        ); // irq on data-done / crc-err / timeout
        await busWrite(_cmdArg, 0);
        await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9));

        final resp = _resp48(0);
        final dataBits = _wordBitsMsb(word);
        final crcBits = _crc16(dataBits);
        crcBits[crcBits.length - 1] ^= 1; // flip the last CRC bit
        final datStream = [0, ...dataBits, ...crcBits];
        final total = resp.length + datStream.length;

        var sawDrive = false;
        var prevSdLow = sdClk.value.toInt() == 0;
        var idx = 0;
        for (var i = 0; i < 6000; i++) {
          await clk.nextPosedge;
          final sending = cmdOe.value.toInt() == 1;
          if (sending) sawDrive = true;
          final sdLow = sdClk.value.toInt() == 0;
          if (sawDrive && !sending && sdLow && !prevSdLow && idx < total) {
            if (idx < resp.length) {
              cmdIn.inject(resp[idx]);
            } else {
              datIn.inject(datStream[idx - resp.length]);
            }
            idx++;
          }
          prevSdLow = sdLow;
          if (irq.value.toInt() == 1) break;
        }

        final status = await busRead(_intStatus);
        // The single (final) block completes AND the bad CRC must be flagged.
        // Regression: two racing intStatus writes used to drop the CRC-error bit
        // whenever data-done landed in the same cycle.
        expect(status & 0x02, equals(0x02)); // data-done still reported
        expect(status & 0x08, equals(0x08)); // CRC error flagged
        await Simulator.endSimulation();
      },
    );

    test('writes a block out of DAT0 with a correct CRC16', () async {
      await setUpDut();

      const word = 0x11223344;
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_data, word); // fill the holding register
      await busWrite(_cmdArg, 0);
      // index 24, short response, data present, write direction (bit 9 = 0).
      await busWrite(_cmd, 24 | (1 << 6) | (1 << 8));
      datIn.inject(1); // DAT0 idles high until the card drives the status token

      final resp = _resp48(0);
      final dataBits = _wordBitsMsb(word);
      // start + 32 data + 16 CRC (the end bit is driven with OE already low).
      final expected = [0, ...dataBits, ..._crc16(dataBits)];
      // Card CRC status token (010 = accepted), then busy-low then busy-high.
      const statusBusy = [0, 0, 1, 0, 0, 1];

      var sawCmd = false, sawDat = false, ri = 0, si = 0;
      final captured = <int>[];
      var prevClk = sdClk.value.toInt();
      for (var i = 0; i < 8000; i++) {
        await clk.nextPosedge;
        final cmdSending = cmdOe.value.toInt() == 1;
        if (cmdSending) sawCmd = true;
        final datDriving = datOe.value.toInt() == 1;
        if (datDriving) sawDat = true;
        if (sawCmd &&
            !cmdSending &&
            !sawDat &&
            sdClk.value.toInt() == 0 &&
            ri < resp.length) {
          cmdIn.inject(resp[ri]);
          ri++;
        }
        final c = sdClk.value.toInt();
        if (prevClk == 0 && c == 1 && datDriving) {
          captured.add(datOut.value.toInt() & 1);
        }
        prevClk = c;
        if (sawDat &&
            !datDriving &&
            sdClk.value.toInt() == 0 &&
            si < statusBusy.length) {
          datIn.inject(statusBusy[si]);
          si++;
        }
        if (irq.value.toInt() == 1) break; // data-done (after busy)
      }

      expect(captured.length, greaterThanOrEqualTo(expected.length));
      expect(captured.sublist(0, expected.length), equals(expected));
      expect(si, equals(statusBusy.length)); // token + busy consumed
      final status = await busRead(_intStatus);
      expect(status & 0x02, equals(0x02)); // data-done
      expect(status & 0x20, equals(0)); // no write error (status accepted)
      await Simulator.endSimulation();
    });

    test(
      'a rejected CRC-status token raises the write-error interrupt',
      () async {
        await setUpDut();

        const word = 0x11223344;
        await busWrite(_blkSize, 4);
        // irq on data-done only, so the loop runs through the busy phase to the
        // end and we then read the sticky write-error bit.
        await busWrite(_intEnable, 0x02);
        await busWrite(_data, word);
        await busWrite(_cmdArg, 0);
        await busWrite(_cmd, 24 | (1 << 6) | (1 << 8)); // write

        datIn.inject(1);
        final resp = _resp48(0);
        // Card CRC-status token 101 (not 010 = accepted), then busy-low/high.
        const statusBusy = [0, 1, 0, 1, 0, 1];

        var sawCmd = false, sawDat = false, ri = 0, si = 0;
        for (var i = 0; i < 8000; i++) {
          await clk.nextPosedge;
          final cmdSending = cmdOe.value.toInt() == 1;
          if (cmdSending) sawCmd = true;
          final datDriving = datOe.value.toInt() == 1;
          if (datDriving) sawDat = true;
          if (sawCmd &&
              !cmdSending &&
              !sawDat &&
              sdClk.value.toInt() == 0 &&
              ri < resp.length) {
            cmdIn.inject(resp[ri]);
            ri++;
          }
          if (sawDat &&
              !datDriving &&
              sdClk.value.toInt() == 0 &&
              si < statusBusy.length) {
            datIn.inject(statusBusy[si]);
            si++;
          }
          if (irq.value.toInt() == 1) break;
        }

        expect(si, equals(statusBusy.length));
        final status = await busRead(_intStatus);
        expect(status & 0x20, equals(0x20)); // write error flagged
        await Simulator.endSimulation();
      },
    );

    test('reads a 4-bit-wide block with per-lane CRC16', () async {
      await setUpDut();

      const word = 0xC3A5F00F;
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_ctrl, 0x01 | (1 << 4)); // enable + 4-bit width
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9));

      final resp = _resp48(0);
      final stream = _fourBitStream(word);
      final total = resp.length + stream.length;

      var sawDrive = false;
      var idx = 0;
      for (var i = 0; i < 6000; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        if (sawDrive && !sending && sdClk.value.toInt() == 0 && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(stream[idx - resp.length]);
          }
          idx++;
        }
        if (irq.value.toInt() == 1) break;
      }

      final status = await busRead(_intStatus);
      expect(status & 0x02, equals(0x02)); // data-done
      expect(status & 0x08, equals(0)); // no CRC error on any lane
      expect(await busRead(_data), equals(word));
      await Simulator.endSimulation();
    });

    test('writes a 4-bit-wide block with a correct per-lane CRC16', () async {
      await setUpDut();

      const word = 0x0FF0A55A;
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_ctrl, 0x01 | (1 << 4)); // enable + 4-bit width
      await busWrite(_data, word);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 24 | (1 << 6) | (1 << 8)); // write
      datIn.inject(1); // DAT0 idles high until the status token

      final resp = _resp48(0);
      final expected = _fourBitStream(word); // start + data + CRC, end excluded
      const statusBusy = [0, 0, 1, 0, 0, 1]; // status token on DAT0, then busy

      var sawCmd = false, sawDat = false, ri = 0, si = 0;
      final captured = <int>[];
      var prevClk = sdClk.value.toInt();
      for (var i = 0; i < 8000; i++) {
        await clk.nextPosedge;
        final cmdSending = cmdOe.value.toInt() == 1;
        if (cmdSending) sawCmd = true;
        final datDriving = datOe.value.toInt() == 1;
        if (datDriving) sawDat = true;
        if (sawCmd &&
            !cmdSending &&
            !sawDat &&
            sdClk.value.toInt() == 0 &&
            ri < resp.length) {
          cmdIn.inject(resp[ri]);
          ri++;
        }
        final c = sdClk.value.toInt();
        if (prevClk == 0 && c == 1 && datDriving) {
          captured.add(datOut.value.toInt() & 0xF);
        }
        prevClk = c;
        if (sawDat &&
            !datDriving &&
            sdClk.value.toInt() == 0 &&
            si < statusBusy.length) {
          datIn.inject(statusBusy[si]);
          si++;
        }
        if (irq.value.toInt() == 1) break;
      }

      expect(captured.length, greaterThanOrEqualTo(expected.length));
      expect(captured.sublist(0, expected.length), equals(expected));
      expect(si, equals(statusBusy.length));
      expect(await busRead(_intStatus) & 0x02, equals(0x02)); // data-done
      await Simulator.endSimulation();
    });

    test('reads a block into memory via ADMA DMA', () async {
      const word = 0xCAFEF00D;
      // Direct single-buffer DMA: ADMA_ADDR is the buffer physical address
      // (byte 0x20 = word 8), length comes from BLK_SIZE*BLK_COUNT. No
      // descriptor is fetched from memory.
      await setUpDut();
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0x20); // buffer address
      await busWrite(_cmdArg, 0);
      // short resp, data present, read direction, DMA.
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));

      final resp = _resp48(0);
      final dataBits = _wordBitsMsb(word);
      final datStream = [0, ...dataBits, ..._crc16(dataBits)];
      final total = resp.length + datStream.length;

      var sawDrive = false, idx = 0;
      var prevSdLow = sdClk.value.toInt() == 0;
      for (var i = 0; i < 6000; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        final sdLow = sdClk.value.toInt() == 0;
        if (sawDrive && !sending && sdLow && !prevSdLow && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(datStream[idx - resp.length]);
          }
          idx++;
        }
        prevSdLow = sdLow;
        if (irq.value.toInt() == 1) break;
      }

      final status = await busRead(_intStatus);
      expect(status & 0x02, equals(0x02)); // data-done
      expect(status & 0x08, equals(0)); // no CRC error
      // The engine stored the received word to the descriptor's buffer.
      expect(mem[8].value.toInt(), equals(word));
      await Simulator.endSimulation();
    });

    test('writes a block from memory via ADMA DMA', () async {
      const word = 0x12345678;
      // Data word preloaded at word 8 (byte 0x20), descriptor points at it.
      await setUpDut(dmaMem: [0x20, 0x80000004, 0, 0, 0, 0, 0, 0, word]);
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0x20);
      await busWrite(_cmdArg, 0);
      // short resp, data present, write direction, DMA.
      await busWrite(_cmd, 24 | (1 << 6) | (1 << 8) | (1 << 10));
      datIn.inject(1); // DAT0 idles high for the status token

      final resp = _resp48(0);
      final dataBits = _wordBitsMsb(word);
      final expected = [0, ...dataBits, ..._crc16(dataBits)];
      const statusBusy = [0, 0, 1, 0, 0, 1];

      var sawCmd = false, sawDat = false, ri = 0, si = 0;
      final captured = <int>[];
      var prevClk = sdClk.value.toInt();
      for (var i = 0; i < 8000; i++) {
        await clk.nextPosedge;
        final cmdSending = cmdOe.value.toInt() == 1;
        if (cmdSending) sawCmd = true;
        final datDriving = datOe.value.toInt() == 1;
        if (datDriving) sawDat = true;
        if (sawCmd &&
            !cmdSending &&
            !sawDat &&
            sdClk.value.toInt() == 0 &&
            ri < resp.length) {
          cmdIn.inject(resp[ri]);
          ri++;
        }
        final c = sdClk.value.toInt();
        if (prevClk == 0 && c == 1 && datDriving) {
          captured.add(datOut.value.toInt() & 1);
        }
        prevClk = c;
        if (sawDat &&
            !datDriving &&
            sdClk.value.toInt() == 0 &&
            si < statusBusy.length) {
          datIn.inject(statusBusy[si]);
          si++;
        }
        if (irq.value.toInt() == 1) break;
      }

      // The serialized stream came straight from memory via ADMA.
      expect(captured.length, greaterThanOrEqualTo(expected.length));
      expect(captured.sublist(0, expected.length), equals(expected));
      expect(await busRead(_intStatus) & 0x02, equals(0x02)); // data-done
      await Simulator.endSimulation();
    });

    // Drives one CMD17 + ADMA read of `words` words and returns how many system
    // clocks the data phase took, so two ack latencies can be compared.
    Future<int> timedAdmaRead(List<int> words) async {
      final resp = _resp48(0);
      // One block: a single start bit, every word's bits, then one CRC16 over
      // all of them.
      final dataBits = [for (final w in words) ..._wordBitsMsb(w)];
      final datStream = [0, ...dataBits, ..._crc16(dataBits)];
      final total = resp.length + datStream.length;

      var sawDrive = false, idx = 0, datStart = -1, cycles = 0;
      for (var i = 0; i < 40000; i++) {
        await clk.nextPosedge;
        cycles++;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        if (sawDrive && !sending && sdClk.value.toInt() == 0 && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            if (datStart < 0) datStart = cycles;
            datIn.inject(datStream[idx - resp.length]);
          }
          idx++;
        }
        if (irq.value.toInt() == 1) break;
      }
      return cycles - datStart;
    }

    // Regression, found on an Arty S7 at 20 MHz: the receive engine used a
    // single holding register, so the SD clock stalled for the WHOLE memory
    // round-trip of every word. Card reads ran at a few KB/s. The elastic RX
    // FIFO must decouple the two, so a slow memory costs no SD bus time until
    // the FIFO fills.
    test('a slow memory does not stall the SD receive clock', () async {
      const words = [0x11111111, 0x22222222, 0x33333333, 0x44444444];

      // Descriptor: [addr=0x20, len=16 | end]; buffer is word 8 (byte 0x20).
      await setUpDut(dmaMem: [0x20, 0x80000010]);
      await busWrite(_blkSize, 16);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0x20);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));
      final fastCycles = await timedAdmaRead(words);
      expect(await busRead(_intStatus) & 0x02, equals(0x02));
      for (var i = 0; i < words.length; i++) {
        expect(mem[8 + i].value.toInt(), equals(words[i]));
      }
      await Simulator.endSimulation();
      await Simulator.reset();

      // The same transfer, but every memory beat takes 20 cycles to ack.
      await setUpDut(dmaMem: [0x20, 0x80000010], ackDelay: 20);
      await busWrite(_blkSize, 16);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0x20);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));
      final slowCycles = await timedAdmaRead(words);
      expect(await busRead(_intStatus) & 0x02, equals(0x02));
      expect(await busRead(_intStatus) & 0x08, equals(0)); // no CRC error
      for (var i = 0; i < words.length; i++) {
        expect(mem[8 + i].value.toInt(), equals(words[i]));
      }

      // The data phase must cost the same SD bus time either way. Allow a
      // couple of cycles of slack for the final drain; the pre-FIFO design
      // took hundreds of cycles longer (one full ack latency per word).
      expect(
        slowCycles,
        lessThanOrEqualTo(fastCycles + 8),
        reason: 'the SD clock stalled waiting on memory',
      );
      await Simulator.endSimulation();
    });

    // Regression, found on an Arty S7 clock sweep: block reads were flat across
    // an 8x SD clock range, so the cost was not the SD bus. The ADMA drove
    // CYC == STB, and the SoC arbiter locks its grant to whoever holds CYC, so
    // the engine handed the bus back after EVERY word and re-arbitrated against
    // a CPU spinning on STATUS. CYC must span a burst of beats instead.
    test('the ADMA holds the bus across a burst instead of per beat', () async {
      const words = [
        0x11111111,
        0x22222222,
        0x33333333,
        0x44444444,
        0x55555555,
        0x66666666,
        0x77777777,
        0x88888888,
      ];

      // The bus hold only matters when the ADMA is the bottleneck, which is the
      // hardware case: a memory slower than the SD fill rate, so the RX FIFO
      // backs up and the engine always has a word ready. With a fast memory the
      // engine drains instantly and releasing per beat is the right thing.
      // Descriptor: [addr=0x20, len=32 | end]; buffer is word 8 (byte 0x20).
      await setUpDut(dmaMem: [0x20, 0x80000020], ackDelay: 200);
      await busWrite(_blkSize, 32);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0x20);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));

      final cyc = sdio.output('dma_cyc');
      final stb = sdio.output('dma_stb');
      var cycRises = 0, beats = 0, prevCyc = 0, prevStb = 0;
      final resp = _resp48(0);
      final dataBits = [for (final w in words) ..._wordBitsMsb(w)];
      final datStream = [0, ...dataBits, ..._crc16(dataBits)];
      final total = resp.length + datStream.length;

      var sawDrive = false, idx = 0;
      var prevSdLow = sdClk.value.toInt() == 0;
      for (var i = 0; i < 200000; i++) {
        await clk.nextPosedge;
        final c = cyc.value.toInt();
        final st = stb.value.toInt();
        if (c == 1 && prevCyc == 0) cycRises++;
        if (st == 1 && prevStb == 0) beats++;
        prevCyc = c;
        prevStb = st;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        final sdLow = sdClk.value.toInt() == 0;
        if (sawDrive && !sending && sdLow && !prevSdLow && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(datStream[idx - resp.length]);
          }
          idx++;
        }
        prevSdLow = sdLow;
        if (irq.value.toInt() == 1) break;
      }

      expect(await busRead(_intStatus) & 0x02, equals(0x02)); // data-done
      for (var i = 0; i < words.length; i++) {
        expect(mem[8 + i].value.toInt(), equals(words[i]));
      }

      // Before the streaming fix STB pulsed once per beat, so a bus cycle ran
      // for every word and the STB-rise count matched the word count. The
      // streaming ADMA now buffers a wide-burst's worth of words and STREAMS
      // them out under ONE continuous STB, so both STB and CYC are held across
      // the batch and their rise counts collapse far below the word count. That
      // continuous stream is exactly what lets the burst adapter combine the
      // narrow words into wide DRAM bursts.
      expect(
        beats,
        greaterThanOrEqualTo(1),
        reason: 'the data phase must have driven at least one bus cycle',
      );
      expect(
        beats,
        lessThan(words.length),
        reason: 'STB is now held across the batch, not pulsed once per word',
      );
      expect(
        cycRises,
        lessThanOrEqualTo(beats),
        reason: 'CYC is held across the burst, at least as much as STB',
      );
      await Simulator.endSimulation();
    });

    // Byte stability under backpressure. A memory far slower than the SD fill
    // rate keeps the RX FIFO pressed against full for the whole block, which is
    // exactly the regime where an unguarded push wraps the write pointer over
    // unread entries and the transfer returns a mix of old and new words. Every
    // word must come back exactly once, in order, with no overrun reported.
    test('an ADMA read is byte-stable when the FIFO is pressed full', () async {
      // 11 distinct words through a 4-deep FIFO, memory acking far slower than
      // the SD side fills, so the FIFO sits at its limit for most of the block.
      final words = [for (var i = 0; i < 11; i++) 0x1000_0000 + i * 0x11111];

      // Descriptor at word 0/1; the buffer is word 5 (byte 0x14), so 11 words
      // land in 5..15 without running off the 16-word model.
      await setUpDut(
        dmaMem: [0x14, 0x80000000 | (11 * 4)],
        ackDelay: 150,
        fifoDepth: 4,
      );
      await busWrite(_blkSize, words.length * 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0x14);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));

      final resp = _resp48(0);
      final dataBits = [for (final w in words) ..._wordBitsMsb(w)];
      final datStream = [0, ...dataBits, ..._crc16(dataBits)];
      final total = resp.length + datStream.length;

      var sawDrive = false, idx = 0;
      var prevSdLow = sdClk.value.toInt() == 0;
      for (var i = 0; i < 200000; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        final sdLow = sdClk.value.toInt() == 0;
        if (sawDrive && !sending && sdLow && !prevSdLow && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(datStream[idx - resp.length]);
          }
          idx++;
        }
        prevSdLow = sdLow;
        if (irq.value.toInt() == 1) break;
      }

      final status = await busRead(_intStatus);
      expect(status & 0x02, equals(0x02)); // data-done
      expect(status & 0x08, equals(0)); // no CRC error
      expect(status & 0x40, equals(0), reason: 'RX FIFO overran');
      // Every word landed exactly once and in order. A wrapped write pointer
      // shows up here as a repeated or skipped word, not as a CRC error.
      for (var i = 0; i < words.length; i++) {
        expect(
          mem[5 + i].value.toInt(),
          equals(words[i]),
          reason: 'word $i came back wrong',
        );
      }
      await Simulator.endSimulation();
    });

    /// Runs one ADMA card-read of [words] and returns how many memory beats and
    /// packed (full-width) beats the engine issued.
    Future<({int beats, int packed})> countedAdmaRead(List<int> words) async {
      final stbSig = sdio.output('dma_stb');
      final weSig = sdio.output('dma_we');
      final selSig = sdio.output('dma_sel');
      final ackSig = sdio.input('dma_ack');
      var beats = 0, packed = 0;

      final resp = _resp48(0);
      final dataBits = [for (final w in words) ..._wordBitsMsb(w)];
      final datStream = [0, ...dataBits, ..._crc16(dataBits)];
      final total = resp.length + datStream.length;

      var sawDrive = false, idx = 0;
      var prevSdLow = sdClk.value.toInt() == 0;
      for (var i = 0; i < 200000; i++) {
        await clk.nextPosedge;
        // A retired write beat: STB + WE with the ack back this cycle.
        if (stbSig.value.toInt() == 1 &&
            weSig.value.toInt() == 1 &&
            ackSig.value.toInt() == 1) {
          beats++;
          if (selSig.value.toInt() == 0xFF) packed++;
        }
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        final sdLow = sdClk.value.toInt() == 0;
        if (sawDrive && !sending && sdLow && !prevSdLow && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(datStream[idx - resp.length]);
          }
          idx++;
        }
        prevSdLow = sdLow;
        if (irq.value.toInt() == 1) break;
      }
      return (beats: beats, packed: packed);
    }

    // The ADMA drove one 32-bit half of every 64-bit beat and masked the other
    // with byte-enables, so a 64-bit fabric cost two round trips per 8 bytes.
    // Consecutive words must share a beat instead.
    test('a 64-bit ADMA read packs two words into one beat', () async {
      const words = [0x11112222, 0x33334444, 0x55556666, 0x77778888];

      // Descriptor: [addr=0x20, len=16 | end]; buffer is word 8 (byte 0x20),
      // which is 8-byte aligned so every beat can pack.
      await setUpDut(
        dmaMem: [0x20, 0x80000010],
        ackDelay: 20,
        dmaDataWidth: 64,
      );
      await busWrite(_blkSize, words.length * 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0x20);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));

      final r = await countedAdmaRead(words);

      expect(await busRead(_intStatus) & 0x02, equals(0x02)); // data-done
      expect(await busRead(_intStatus) & 0x08, equals(0)); // no CRC error
      expect(await busRead(_intStatus) & 0x40, equals(0)); // no overrun
      for (var i = 0; i < words.length; i++) {
        expect(
          mem[8 + i].value.toInt(),
          equals(words[i]),
          reason: 'word $i must survive the packed beat',
        );
      }
      expect(
        r.beats,
        words.length ~/ 2,
        reason: 'four words must cost two beats, not four',
      );
      expect(r.packed, r.beats, reason: 'every beat must be full width');
      await Simulator.endSimulation();
    });

    // Packing may not refuse an awkward descriptor. An 8-byte misaligned start
    // takes a half beat to get aligned, and an odd trailing word takes another,
    // so a 4-word transfer at byte 0x24 is half + packed + half.
    test(
      'a 64-bit ADMA read falls back for an unaligned start and an odd tail',
      () async {
        const words = [0xAAAA0001, 0xBBBB0002, 0xCCCC0003, 0xDDDD0004];

        // Buffer at byte 0x24 = word 9, which is NOT 8-byte aligned.
        await setUpDut(
          dmaMem: [0x24, 0x80000010],
          ackDelay: 20,
          dmaDataWidth: 64,
        );
        await busWrite(_blkSize, words.length * 4);
        await busWrite(_intEnable, 0x12);
        await busWrite(_admaAddr, 0x24);
        await busWrite(_cmdArg, 0);
        await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));

        final r = await countedAdmaRead(words);

        expect(await busRead(_intStatus) & 0x02, equals(0x02));
        expect(await busRead(_intStatus) & 0x08, equals(0));
        for (var i = 0; i < words.length; i++) {
          expect(
            mem[9 + i].value.toInt(),
            equals(words[i]),
            reason: 'word $i must land at the unaligned target',
          );
        }
        expect(
          mem[8].value.toInt(),
          equals(0),
          reason: 'the word before the buffer must not be touched',
        );
        expect(
          mem[13].value.toInt(),
          equals(0),
          reason: 'the word after the buffer must not be touched',
        );
        expect(r.beats, 3, reason: 'half beat, packed beat, half beat');
        expect(r.packed, 1, reason: 'only the aligned middle pair may pack');
        await Simulator.endSimulation();
      },
    );

    // Back-to-back blocks through a packed 64-bit port: the second read must be
    // byte-stable too, so nothing survives in the pack registers or the FIFO
    // pointers across the re-arm.
    test('back-to-back 64-bit ADMA reads stay byte-stable', () async {
      const first = [0x1A2B3C4D, 0x5E6F7081, 0x92A3B4C5, 0xD6E7F809];
      const second = [0x0F1E2D3C, 0x4B5A6978, 0x8796A5B4, 0xC3D2E1F0];

      await setUpDut(
        dmaMem: [0x20, 0x80000010],
        ackDelay: 20,
        dmaDataWidth: 64,
      );
      const blocks = [first, second];
      for (var n = 0; n < blocks.length; n++) {
        final words = blocks[n];
        await busWrite(_blkSize, words.length * 4);
        await busWrite(_intEnable, 0x12);
        await busWrite(_admaAddr, 0x20);
        await busWrite(_cmdArg, 0);
        await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));

        final r = await countedAdmaRead(words);
        final status = await busRead(_intStatus);
        expect(status & 0x02, equals(0x02), reason: 'block $n did not finish');
        expect(
          status & 0x08,
          equals(0),
          reason: 'block $n reported a CRC error',
        );
        expect(status & 0x40, equals(0), reason: 'block $n overran the FIFO');
        expect(r.packed, 2, reason: 'block $n must still pack');
        for (var i = 0; i < words.length; i++) {
          expect(
            mem[8 + i].value.toInt(),
            equals(words[i]),
            reason: 'block $n word $i came back wrong',
          );
        }
        await busWrite(_intStatus, status); // clear for the next block
      }
      await Simulator.endSimulation();
    });

    // A master that holds STB across the one-cycle ACK must not have its access
    // run twice. On a DATA read that pops the RX FIFO a second time and skips a
    // word, so the caller silently loses data - the same shape as a boot image
    // that reads back with holes.
    test('a held STB reads one word, not two', () async {
      const words = [0xAAAA1111, 0xBBBB2222, 0xCCCC3333];
      await setUpDut();
      await busWrite(_blkSize, words.length * 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_cmdArg, 0);
      // PIO read: data present, read direction, NO DMA, so DATA is the drain.
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9));

      final resp = _resp48(0);
      final dataBits = [for (final w in words) ..._wordBitsMsb(w)];
      final datStream = [0, ...dataBits, ..._crc16(dataBits)];
      final total = resp.length + datStream.length;

      var sawDrive = false, idx = 0;
      var prevSdLow = sdClk.value.toInt() == 0;
      for (var i = 0; i < 40000; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        final sdLow = sdClk.value.toInt() == 0;
        if (sawDrive && !sending && sdLow && !prevSdLow && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(datStream[idx - resp.length]);
          }
          idx++;
        }
        prevSdLow = sdLow;
        if (irq.value.toInt() == 1) break;
      }

      // Drain with a master that lingers on STB. Every word must come back in
      // order; a double-pop shows up as the second word going missing.
      for (var i = 0; i < words.length; i++) {
        expect(
          await busReadHeld(_data, 3),
          equals(words[i]),
          reason: 'word $i lost to a re-entered bus access',
        );
      }
      await Simulator.endSimulation();
    });

    // Regression, found on the same board: the first CMD17 + ADMA read
    // completed and the second deadlocked the fabric. A word lost to the old
    // producer/consumer race left the descriptor walker waiting for a word that
    // could never arrive, with its bus request still asserted.
    test('two back-to-back ADMA reads both complete', () async {
      const first = [0xAAAA1111, 0xBBBB2222];
      const second = [0xCCCC3333, 0xDDDD4444];

      // Two descriptors, used one per command: word 0/1 -> buffer at byte 0x20,
      // word 2/3 -> buffer at byte 0x30.
      await setUpDut(dmaMem: [0x20, 0x80000008, 0x30, 0x80000008]);
      await busWrite(_blkSize, 8);
      await busWrite(_intEnable, 0x12);

      await busWrite(_admaAddr, 0x20);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));
      await timedAdmaRead(first);
      expect(await busRead(_intStatus) & 0x02, equals(0x02));
      expect(mem[8].value.toInt(), equals(first[0]));
      expect(mem[9].value.toInt(), equals(first[1]));
      await busWrite(_intStatus, 0x3f); // clear before the second command

      // The second read must run to completion, not hang.
      await busWrite(_admaAddr, 0x30); // the second descriptor
      await busWrite(_cmdArg, 1);
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));
      await timedAdmaRead(second);
      expect(
        await busRead(_intStatus) & 0x02,
        equals(0x02),
        reason: 'the second ADMA read never finished',
      );
      expect(await busRead(_intStatus) & 0x08, equals(0)); // no CRC error
      expect(mem[12].value.toInt(), equals(second[0]));
      expect(mem[13].value.toInt(), equals(second[1]));
      await Simulator.endSimulation();
    });

    test('writes a multi-word block from memory via ADMA DMA', () async {
      // Two words, so the serializer must refill its byte shifter from the
      // NEXT word the ADMA fetches. A single-word block hides that step.
      const w0 = 0x12345678;
      const w1 = 0x9ABCDEF0;
      await setUpDut(dmaMem: [0x20, 0x80000008, 0, 0, 0, 0, 0, 0, w0, w1]);
      await busWrite(_blkSize, 8);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0x20);
      await busWrite(_cmdArg, 0);
      // short resp, data present, write direction, DMA.
      await busWrite(_cmd, 24 | (1 << 6) | (1 << 8) | (1 << 10));
      datIn.inject(1); // DAT0 idles high for the status token

      final resp = _resp48(0);
      final dataBits = [..._wordBitsMsb(w0), ..._wordBitsMsb(w1)];
      final expected = [0, ...dataBits, ..._crc16(dataBits)];
      const statusBusy = [0, 0, 1, 0, 0, 1];

      var sawCmd = false, sawDat = false, ri = 0, si = 0;
      final captured = <int>[];
      var prevClk = sdClk.value.toInt();
      for (var i = 0; i < 12000; i++) {
        await clk.nextPosedge;
        final cmdSending = cmdOe.value.toInt() == 1;
        if (cmdSending) sawCmd = true;
        final datDriving = datOe.value.toInt() == 1;
        if (datDriving) sawDat = true;
        if (sawCmd &&
            !cmdSending &&
            !sawDat &&
            sdClk.value.toInt() == 0 &&
            ri < resp.length) {
          cmdIn.inject(resp[ri]);
          ri++;
        }
        final c = sdClk.value.toInt();
        if (prevClk == 0 && c == 1 && datDriving) {
          captured.add(datOut.value.toInt() & 1);
        }
        prevClk = c;
        if (sawDat &&
            !datDriving &&
            sdClk.value.toInt() == 0 &&
            si < statusBusy.length) {
          datIn.inject(statusBusy[si]);
          si++;
        }
        if (irq.value.toInt() == 1) break;
      }

      expect(captured.length, greaterThanOrEqualTo(expected.length));
      expect(captured.sublist(0, expected.length), equals(expected));
      expect(await busRead(_intStatus) & 0x02, equals(0x02)); // data-done
      expect(await busRead(_intStatus) & 0x20, equals(0)); // no write error
      await Simulator.endSimulation();
    });
  });

  group('HarborSdioController UHS structural layer', () {
    tearDown(() async {
      await Simulator.reset();
    });

    const spartan7 = HarborFpgaTarget.spartan7(
      device: 's50',
      package: 'csga324',
    );
    const ecp5 = HarborFpgaTarget.ecp5(device: '85f', package: 'CABGA381');
    const hs400 = HarborSdioConfig(
      maxBusWidth: HarborSdioBusWidth.eight,
      maxSpeed: HarborSdioSpeed.hs400,
      supportsEmmc: true,
      supports1v8: true,
      maxFrequency: 200000000,
    );

    test('Spartan 7 UHS config conditions inputs with IDELAYE2', () async {
      final sdio = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig.uhs(), // SDR104
        target: spartan7,
      );
      await sdio.build();
      final sv = sdio.generateSynth();
      expect(sv, contains('IDELAYE2')); // input-delay tuning tap
      expect(sv, isNot(contains('DELAYG'))); // no Lattice primitive
      expect(sv, isNot(contains('IDDR'))); // SDR104 is not DDR
    });

    test('ECP5 UHS config conditions inputs with DELAYG', () async {
      final sdio = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig.uhs(),
        target: ecp5,
      );
      await sdio.build();
      final sv = sdio.generateSynth();
      expect(sv, contains('DELAYG'));
      expect(sv, isNot(contains('IDELAYE2')));
    });

    test('HS400 (DDR) adds DDR input gearing', () async {
      final sdio = HarborSdioController(
        baseAddress: 0x60000000,
        config: hs400,
        target: spartan7,
      );
      await sdio.build();
      final sv = sdio.generateSynth();
      expect(sv, contains('IDELAYE2'));
      expect(sv, contains('IDDR')); // DDR capture gearing
    });

    test('non-UHS config leaves the SDR datapath untouched', () async {
      final sdio = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig.sd(), // high speed, not UHS
        target: spartan7,
      );
      await sdio.build();
      final sv = sdio.generateSynth();
      expect(sv, isNot(contains('IDELAYE2')));
      expect(sv, isNot(contains('IDDR')));
    });
  });

  group('HarborSdioController fabric integration', () {
    test(
      'ownPads collapses CMD/DAT to bidirectional pads + a WB dma master',
      () async {
        final sdio = HarborSdioController(
          baseAddress: 0x60000000,
          config: const HarborSdioConfig.sd(),
          ownPads: true,
          fabricDma: true,
        );
        await sdio.build();

        // Bidirectional pads replace the split triplets.
        expect(sdio.tryInput('sd_cmd_in'), isNull);
        expect(sdio.tryOutput('sd_cmd_out'), isNull);
        expect(() => sdio.inOut('sd_cmd'), returnsNormally);
        expect(() => sdio.inOut('sd_dat0'), returnsNormally); // per-lane pads
        expect(() => sdio.inOut('sd_dat3'), returnsNormally);

        // The ADMA master is a Wishbone interface, not the raw ports.
        expect(sdio.tryOutput('dma_stb'), isNull);
        expect(() => sdio.interface('dma'), returnsNormally);

        final sv = sdio.generateSynth();
        expect(sv, contains('inout wire sd_cmd')); // bidirectional pad
        expect(sv, contains('inout wire sd_dat0')); // per-lane pads
        expect(sv, contains('inout wire sd_dat3'));
        expect(sv, contains('dma_CYC')); // Wishbone master interface
      },
    );

    test(
      'default (no flags) keeps the split ports and raw ADMA handshake',
      () async {
        final sdio = HarborSdioController(baseAddress: 0x60000000);
        await sdio.build();
        expect(() => sdio.output('sd_cmd_out'), returnsNormally);
        expect(() => sdio.input('sd_cmd_in'), returnsNormally);
        expect(() => sdio.output('dma_stb'), returnsNormally);
        expect(sdio.tryInOut('sd_cmd'), isNull);
      },
    );
  });
}
