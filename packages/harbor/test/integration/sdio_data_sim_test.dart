import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

// Register WORD indices.
// Byte offsets: each register in its own 8-byte slot (the byte-addressed fabric).
const _ctrl = 0x00;
const _status = 0x08;
const _clkDiv = 0x10;
const _cmd = 0x18;
const _cmdArg = 0x20;
const _data = 0x48;
const _blkSize = 0x50;
const _blkCount = 0x58;
const _intStatus = 0x60;

// CMD field encoding.
const _respShort = 1;
int _cmdWord(
  int index, {
  int respType = 0,
  bool data = false,
  bool read = false,
}) => index | (respType << 6) | ((data ? 1 : 0) << 8) | ((read ? 1 : 0) << 9);

// STATUS / INT_STATUS bits.
const _stDataValid = 1 << 9;
const _intDataDone = 0x02;
const _intDataCrcErr = 0x08;

int _bit(Logic l) {
  final v = l.value;
  return v.isValid ? v.toInt() : 0;
}

// SD data CRC16 (CCITT, x^16+x^12+x^5+1), MSB-first, seed 0. Mirrors the RTL
// _crc16Next bit-for-bit so it is an independent golden reference.
int _crc16Next(int crc, int bit) {
  final inv = ((crc >> 15) ^ (bit & 1)) & 1;
  var next = 0;
  for (var i = 0; i < 16; i++) {
    int b;
    if (i == 0) {
      b = inv;
    } else if (i == 5) {
      b = ((crc >> 4) & 1) ^ inv;
    } else if (i == 12) {
      b = ((crc >> 11) & 1) ^ inv;
    } else {
      b = (crc >> (i - 1)) & 1;
    }
    next |= (b & 1) << i;
  }
  return next & 0xffff;
}

int _crc7(List<int> bits) {
  var crc = 0;
  for (final b in bits) {
    final fb = ((crc >> 6) & 1) ^ (b & 1);
    crc = (crc << 1) & 0x7f;
    if (fb != 0) crc ^= 0x09;
  }
  return crc;
}

List<int> _toBits(int value, int n) {
  final bits = <int>[];
  for (var i = n - 1; i >= 0; i--) {
    bits.add((value >> i) & 1);
  }
  return bits;
}

int _fromBits(List<int> bits) {
  var v = 0;
  for (final b in bits) {
    v = (v << 1) | (b & 1);
  }
  return v;
}

/// Fake native-SD card with a 1-bit block-read datapath, the oracle for the DAT
/// read engine. It responds R1 on CMD, then (when [readBlock] is set) drives the
/// block on DAT0: a start bit, the data bits MSB-first per byte, and the 16-bit
/// CRC16, all on falling edges so the host samples on rising edges.
class _FakeSdCard {
  final HarborSdioController dut;
  final Logic cmdIn;
  final Logic datIn;

  int gotIndex = -1;
  bool gotCrcOk = false;
  int commandCount = 0;
  bool stop = false;

  /// Blocks to stream on DAT0 after the next command's response, each framed
  /// with its own start bit + CRC16 (as the RTL expects per block). Null = none.
  List<List<int>>? readBlocks;

  /// Flip one CRC bit so the host must flag a CRC error.
  bool corruptCrc = false;

  /// Launch the DAT block on the SD clock RISING edge instead of the falling
  /// edge. This models a real card whose read data is aligned to the rising
  /// edge (the worst case for a host that also samples on the rising edge): the
  /// data reaches the host only after its own rising edge, so a rising-sample
  /// host reads it a bit early. A host that samples on the falling edge
  /// (CTRL[8]=1) captures it correctly.
  bool driveDatOnRise = false;

  /// Round-trip delay, in system-clock cycles, between the card launching a DAT
  /// bit and the host seeing it. Models the host-SDCLK-out plus card-tOD plus
  /// data-back propagation that eats the host sampling window at speed. 0 keeps
  /// the ideal zero-delay model (existing tests). It must stay under half an SD
  /// period so a falling-edge sample still captures the bit.
  int datDelay = 0;

  _FakeSdCard(this.dut, this.cmdIn, this.datIn);

  List<int> _buildR1(int index, int arg) {
    final bits = <int>[0, 0];
    bits.addAll(_toBits(index, 6));
    bits.addAll(_toBits(arg, 32));
    bits.addAll(_toBits(_crc7(bits.sublist(0, 40)), 7));
    bits.add(1);
    return bits;
  }

  List<int> _buildDat(List<List<int>> blocks) {
    final bits = <int>[];
    for (final block in blocks) {
      bits.add(0); // per-block start bit on DAT0
      var crc = 0;
      for (final byte in block) {
        for (var i = 7; i >= 0; i--) {
          final b = (byte >> i) & 1;
          bits.add(b);
          crc = _crc16Next(crc, b);
        }
      }
      if (corruptCrc) crc ^= 0x0001;
      for (var i = 15; i >= 0; i--) {
        bits.add((crc >> i) & 1);
      }
    }
    return bits;
  }

  Future<void> run(Logic clk) async {
    var prevClk = 0;
    var prevOe = 0;
    var collecting = false;
    final cmdBits = <int>[];
    var respBits = <int>[];
    var responding = false;
    var respGap = 0;

    var datBits = <int>[];
    var datPhase = 0; // 0 idle, 1 gap, 2 driving
    var datGap = 0;

    // One-entry delay line for the round-trip model: a launched bit becomes
    // visible on DAT `datDelay` system cycles later.
    var pendVal = -1;
    var pendCnt = 0;

    while (!stop) {
      await clk.nextPosedge;
      if (pendCnt > 0) {
        pendCnt--;
        if (pendCnt == 0 && pendVal >= 0) {
          datIn.inject(pendVal);
          pendVal = -1;
        }
      }
      final sclk = _bit(dut.output('sd_clk'));
      final oe = _bit(dut.output('sd_cmd_oe'));
      final cmdOut = _bit(dut.output('sd_cmd_out'));
      final rise = prevClk == 0 && sclk == 1;
      final fall = prevClk == 1 && sclk == 0;

      // Command RX.
      if (oe == 1 && rise) {
        if (!collecting) {
          if (cmdOut == 0) {
            collecting = true;
            cmdBits.add(0);
          }
        } else {
          cmdBits.add(cmdOut);
        }
      }
      if (prevOe == 1 && oe == 0 && collecting && !responding) {
        if (cmdBits.length >= 47) {
          final f = cmdBits.sublist(0, 47);
          gotIndex = _fromBits(f.sublist(2, 8));
          gotCrcOk = _crc7(f.sublist(0, 40)) == _fromBits(f.sublist(40, 47));
          commandCount++;
          respBits = _buildR1(gotIndex, _fromBits(f.sublist(8, 40)));
          responding = true;
          respGap = 2;
        }
        collecting = false;
        cmdBits.clear();
      }

      // CMD response on falling edges; queue the DAT block when it finishes.
      if (responding && fall) {
        if (respGap > 0) {
          respGap--;
          cmdIn.inject(1);
        } else if (respBits.isNotEmpty) {
          cmdIn.inject(respBits.removeAt(0));
        } else {
          cmdIn.inject(1);
          responding = false;
          if (readBlocks != null && datPhase == 0) {
            datBits = _buildDat(readBlocks!);
            datPhase = 1;
            datGap = 3; // let the host reach dRWait
          }
        }
      }

      // DAT block drive, on the falling edge by default (so a rising-sample
      // host captures cleanly) or on the rising edge to model a real card.
      if (datPhase != 0 && (driveDatOnRise ? rise : fall)) {
        if (datPhase == 1) {
          if (datGap > 0) {
            datGap--;
          } else {
            datPhase = 2;
          }
        }
        if (datPhase == 2) {
          if (datBits.isNotEmpty) {
            final v = 0xe | datBits.removeAt(0);
            if (datDelay > 0) {
              pendVal = v;
              pendCnt = datDelay;
            } else {
              datIn.inject(v);
            }
          } else {
            datIn.inject(0xf);
            datPhase = 0;
            readBlocks = null;
          }
        }
      }

      prevClk = sclk;
      prevOe = oe;
    }
  }
}

Future<(PeripheralTestBench, _FakeSdCard)> _bringUp({
  bool corrupt = false,
}) async {
  final sdio = HarborSdioController(baseAddress: 0x9000);
  final cmdIn = Logic(name: 'fake_cmd_in');
  final cd = Logic(name: 'fake_cd');
  final datIn = Logic(name: 'fake_dat_in', width: 4);
  sdio.port('sd_cmd_in').getsLogic(cmdIn);
  sdio.port('sd_cd').getsLogic(cd);
  sdio.port('sd_dat_in').getsLogic(datIn);
  for (final p in sdio.inputs.keys.where((p) => p.startsWith('dma_'))) {
    sdio.port(p).getsLogic(Const(0, width: sdio.input(p).width));
  }

  final tb = PeripheralTestBench(sdio);
  final card = _FakeSdCard(sdio, cmdIn, datIn)..corruptCrc = corrupt;
  await tb.init(maxSimTime: 8000000);
  cmdIn.inject(1);
  cd.inject(1);
  datIn.inject(0xf);
  unawaited(card.run(tb.clk));

  await tb.write(_clkDiv, 1);
  await tb.write(_ctrl, 1);
  return (tb, card);
}

/// Drains [wordCount] DATA words, polling STATUS for data-valid.
Future<List<int>> _drain(
  PeripheralTestBench tb,
  int wordCount, {
  int max = 400000,
}) async {
  final words = <int>[];
  for (var i = 0; i < max && words.length < wordCount; i++) {
    if (await tb.read(_status) & _stDataValid != 0) {
      words.add(await tb.read(_data));
    }
  }
  return words;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('SDIO 1-bit block read', () {
    test('CMD17 single block: DATA words match, no CRC error', () async {
      final (tb, card) = await _bringUp();
      final block = [0x11, 0x22, 0x33, 0x44, 0xde, 0xad, 0xbe, 0xef];
      card.readBlocks = [block];

      await tb.write(_blkSize, block.length);
      await tb.write(_blkCount, 1);
      await tb.write(_cmdArg, 0);
      await tb.write(
        _cmd,
        _cmdWord(17, respType: _respShort, data: true, read: true),
      );

      final words = await _drain(tb, block.length ~/ 4);
      expect(card.commandCount, equals(1));
      expect(card.gotIndex, equals(17));

      // Bytes assemble little-endian: byte0 is the low byte of word0.
      final expected = [
        block[0] | block[1] << 8 | block[2] << 16 | block[3] << 24,
        block[4] | block[5] << 8 | block[6] << 16 | block[7] << 24,
      ];
      expect(words, equals(expected), reason: 'DATA word payload');

      // Wait for data-done, then confirm no CRC error was flagged.
      var ints = 0;
      for (var i = 0; i < 40000; i++) {
        ints = await tb.read(_intStatus);
        if (ints & _intDataDone != 0) break;
      }
      expect(ints & _intDataDone, equals(_intDataDone), reason: 'data done');
      expect(ints & _intDataCrcErr, equals(0), reason: 'good CRC16 accepted');

      card.stop = true;
      await Simulator.endSimulation();
    });

    test(
      'a corrupted block CRC16 raises the data-CRC-error interrupt',
      () async {
        final (tb, card) = await _bringUp(corrupt: true);
        final block = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08];
        card.readBlocks = [block];

        await tb.write(_blkSize, block.length);
        await tb.write(_blkCount, 1);
        await tb.write(_cmdArg, 0);
        await tb.write(
          _cmd,
          _cmdWord(17, respType: _respShort, data: true, read: true),
        );

        await _drain(tb, block.length ~/ 4);
        var ints = 0;
        for (var i = 0; i < 40000; i++) {
          ints = await tb.read(_intStatus);
          if (ints & _intDataDone != 0) break;
        }
        expect(ints & _intDataDone, equals(_intDataDone));
        expect(
          ints & _intDataCrcErr,
          equals(_intDataCrcErr),
          reason: 'a bad CRC16 must set the CRC-error interrupt',
        );

        card.stop = true;
        await Simulator.endSimulation();
      },
    );

    test('CMD18 multi-block: two blocks stream back correctly', () async {
      final (tb, card) = await _bringUp();
      // Two blocks of 8 bytes; the card streams them back to back.
      final b0 = [0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7];
      final b1 = [0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7];
      // Each block is framed separately (its own start bit + CRC16).
      card.readBlocks = [b0, b1];

      await tb.write(_blkSize, 8);
      await tb.write(_blkCount, 2);
      await tb.write(_cmdArg, 0);
      await tb.write(
        _cmd,
        _cmdWord(18, respType: _respShort, data: true, read: true),
      );

      final words = await _drain(tb, 4);
      final expected = [
        b0[0] | b0[1] << 8 | b0[2] << 16 | b0[3] << 24,
        b0[4] | b0[5] << 8 | b0[6] << 16 | b0[7] << 24,
        b1[0] | b1[1] << 8 | b1[2] << 16 | b1[3] << 24,
        b1[4] | b1[5] << 8 | b1[6] << 16 | b1[7] << 24,
      ];
      expect(words, equals(expected), reason: 'both blocks stream in order');

      card.stop = true;
      await Simulator.endSimulation();
    });

    // HW repro: CMD18 multi-block reads corrupt at scale (n=16 reads correct on
    // the Arty S7, n>=32 returns wrong data). Every word carries a unique
    // fingerprint (block index in the high bits, word index in the low bits) so
    // the FIRST mismatch names exactly where the receive engine desyncs across a
    // block boundary. 512-byte blocks match the hardware block size.
    for (final nBlocks in [8, 16, 32, 48, 63]) {
      test('CMD18 $nBlocks x 32-byte blocks stream back byte-exact', () async {
        final (tb, card) = await _bringUp();
        await tb.write(
          _clkDiv,
          0,
        ); // fastest SD clock to keep the sim tractable

        // Small blocks so many-block counts stay sim-tractable: this probes the
        // BLOCK-COUNT dimension of the receive FSM (where the block-boundary
        // desync would live), not the byte-total dimension.
        const blkBytes = 32;
        const wordsPerBlk = blkBytes ~/ 4;
        int fp(int b, int w) => (0xB0000000 | (b << 12) | w) & 0xffffffff;
        final blocks = [
          for (var b = 0; b < nBlocks; b++)
            [
              for (var w = 0; w < wordsPerBlk; w++)
                for (var byte = 0; byte < 4; byte++)
                  (fp(b, w) >> (byte * 8)) & 0xff,
            ],
        ];
        card.readBlocks = blocks;

        await tb.write(_blkSize, blkBytes);
        await tb.write(_blkCount, nBlocks);
        await tb.write(_cmdArg, 0);
        await tb.write(
          _cmd,
          _cmdWord(18, respType: _respShort, data: true, read: true),
        );

        final total = nBlocks * wordsPerBlk;
        final words = await _drain(tb, total, max: 40000000);

        // Report the FIRST divergence with decoded fingerprints.
        expect(
          words.length,
          total,
          reason: 'drained ${words.length}/$total words (stream stalled)',
        );
        for (var i = 0; i < total; i++) {
          final want = fp(i ~/ wordsPerBlk, i % wordsPerBlk);
          if (words[i] != want) {
            final gb = (words[i] >> 12) & 0xfffff, gw = words[i] & 0xfff;
            fail(
              'word $i (block ${i ~/ wordsPerBlk}, word ${i % wordsPerBlk}): '
              'want 0x${want.toRadixString(16)} '
              'got 0x${words[i].toRadixString(16)} '
              '(claims block $gb word $gw)',
            );
          }
        }

        card.stop = true;
        await Simulator.endSimulation();
      });
    }
  });

  // The read-data sample edge (CTRL[8]). This exercises the falling-edge read
  // datapath end to end: with CTRL[8] set, the whole read FSM (start-bit hunt,
  // data shift, CRC, and the RX FIFO push) samples DAT on the falling edge, and
  // a card that launched the block on the rising edge with a round-trip delay is
  // still received byte-exact and CRC-clean.
  //
  // NOTE: this cannot show the falling edge being BETTER than the rising edge.
  // A cycle-accurate sim reframes a uniform integer-cycle delay (the start-bit
  // hunt lags with the data, re-syncing the frame), so both edges read clean.
  // The real hardware win is moving the sample point out of the setup/hold
  // transition window, a metastability effect a cycle sim cannot reproduce.
  // That proof is on hardware (LiteSDCard samples read data on a card-fed clock
  // for the same reason).
  group('read-data sample edge (CTRL[8])', () {
    const ctrlEnable = 1;
    const ctrlSampleFall = 1 << 8;
    final block = [0x11, 0x22, 0x33, 0x44, 0xde, 0xad, 0xbe, 0xef];
    final expected = [
      block[0] | block[1] << 8 | block[2] << 16 | block[3] << 24,
      block[4] | block[5] << 8 | block[6] << 16 | block[7] << 24,
    ];

    test(
      'rising-edge-launched card reads byte-exact with falling sample',
      () async {
        final (tb, card) = await _bringUp();
        // Sample the read DAT on the falling edge, half a period after the card
        // launched it on the rising edge.
        await tb.write(_ctrl, ctrlEnable | ctrlSampleFall);
        card.driveDatOnRise = true;
        card.datDelay = 1; // one system cycle of round-trip delay
        card.readBlocks = [block];

        await tb.write(_blkSize, block.length);
        await tb.write(_blkCount, 1);
        await tb.write(_cmdArg, 0);
        await tb.write(
          _cmd,
          _cmdWord(17, respType: _respShort, data: true, read: true),
        );

        final words = await _drain(tb, block.length ~/ 4);
        expect(
          words,
          equals(expected),
          reason: 'falling sample captures rising-launched DAT',
        );

        var ints = 0;
        for (var i = 0; i < 40000; i++) {
          ints = await tb.read(_intStatus);
          if (ints & _intDataDone != 0) break;
        }
        expect(
          ints & _intDataCrcErr,
          equals(0),
          reason: 'no CRC error on the falling-sampled block',
        );

        card.stop = true;
        await Simulator.endSimulation();
      },
    );
  });
}
