import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Behavioral standard-mode SPI NOR flash model + the [HarborSpiFlashController]
/// WRITE/ERASE engine (task B5a). Standard SPI is used so MISO is a plain INPUT
/// (drivable from the testbench without an inout co-sim). The write engine
/// always drives standard single-bit DQ0 regardless of read mode, so this is
/// representative.
///
/// This is a long flash-protocol test (erase, program, WREN, then one XIP
/// read) driven through the wr_req sideband, not the register port, so it
/// stays on Wishbone only rather than looping three times over.
///
/// The model is a clocked-by-the-testbench SPI slave that:
///  - tracks CS (resets its byte/bit accumulator on CS rising edge),
///  - samples MOSI on each spi_clk RISING edge (MSB-first into bytes),
///  - decodes 0x06 WREN (sets WEL), 0x20 erase-4KB, 0x02 page-program,
///    0x05 RDSR (drives status back on MISO),
///  - models WIP busy for a few "transactions" after erase/program then clears,
///  - rejects erase/program if WEL is not set (so a missing WREN fails a test),
///  - AND-merges programmed bytes into existing storage (NOR clears bits only).
class _SpiNorModel {
  final storage = <int, int>{}; // byte address -> value (default 0xFF)
  bool wel = false;
  int wipCounter = 0; // >0 means WIP set; decremented on each RDSR read
  int rdsrCount = 0; // number of RDSR transactions served

  // Shift state, advanced by the testbench on SPI clock edges.
  int curByte = 0; // bits accumulated for the current byte (MSB-first)
  int bitsInByte = 0;
  final cmdBytes = <int>[];
  int cmd = 0;
  int addr = 0;
  bool servingStatus = false; // RDSR data phase active
  int statusByte = 0; // the status byte being shifted out (MSB-first)

  int read(int a) => storage[a] ?? 0xFF;

  /// CS rising edge: a transaction ended. Reset the shift accumulators.
  void csRise() {
    // If a program/erase command was framed, WEL self-clears after execution.
    if (cmd == 0x20 || cmd == 0x02) {
      wel = false;
    }
    curByte = 0;
    bitsInByte = 0;
    cmdBytes.clear();
    cmd = 0;
    addr = 0;
    servingStatus = false;
    statusByte = 0;
  }

  /// CS falling edge: a new transaction begins.
  void csFall() {
    curByte = 0;
    bitsInByte = 0;
    cmdBytes.clear();
    cmd = 0;
    servingStatus = false;
    statusByte = 0;
  }

  /// The MISO bit to present at a rising edge, given the rising-edge index
  /// within the current CS-low transaction (0-based). Mirrors the read-path
  /// testbench: during the RDSR data phase (rising edges 8..15) drive status
  /// bit (idx-8) MSB-first. The controller captures on the following falling
  /// edge. Returns 0 outside the status phase.
  int misoBitAt(int idx) {
    if (servingStatus) {
      final d = idx - 8; // 8 opcode bits precede the data phase
      if (d >= 0 && d < 8) {
        return (statusByte >> (7 - d)) & 1;
      }
    }
    return 0;
  }

  /// SPI clock rising edge: sample one MOSI command/address/data bit (MSB-first)
  /// while in the command/address/data phase. MOSI is ignored once we are
  /// serving status back (DQ0 is released by the controller then).
  void clkRise(int mosi) {
    if (!servingStatus) {
      curByte = ((curByte << 1) | (mosi & 1)) & 0xFF;
      bitsInByte++;
      if (bitsInByte == 8) {
        _byteComplete(curByte);
        curByte = 0;
        bitsInByte = 0;
      }
    }
  }

  void _byteComplete(int b) {
    cmdBytes.add(b);
    if (cmdBytes.length == 1) {
      cmd = b;
      if (cmd == 0x06) {
        wel = true; // WREN
      } else if (cmd == 0x05) {
        // RDSR: present the status byte on MISO. bit0=WIP, bit1=WEL.
        final wip = wipCounter > 0 ? 1 : 0;
        // Each RDSR transaction decrements the WIP "busy" timer so the engine
        // sees busy for a few polls then clear.
        if (wipCounter > 0) wipCounter--;
        rdsrCount++;
        statusByte = (wip) | (wel ? 2 : 0);
        servingStatus = true;
      }
      return;
    }
    // Address bytes (3) for erase/program.
    if (cmd == 0x20 || cmd == 0x02) {
      if (cmdBytes.length >= 2 && cmdBytes.length <= 4) {
        addr = (addr << 8) | b;
        if (cmd == 0x20 && cmdBytes.length == 4) {
          _erase(addr);
        }
        return;
      }
      // Program data bytes (cmdBytes index >= 4).
      if (cmd == 0x02 && cmdBytes.length > 4) {
        final dataIdx = cmdBytes.length - 5;
        _program(addr + dataIdx, b);
      }
    }
  }

  void _erase(int sectorAddr) {
    if (!wel) return; // rejected without WREN
    final base = sectorAddr & ~0xFFF; // 4KB align
    for (var i = 0; i < 4096; i++) {
      storage[base + i] = 0xFF;
    }
    wipCounter = 3; // busy for a few RDSR polls
  }

  void _program(int a, int b) {
    if (!wel) return; // rejected without WREN
    final existing = storage[a] ?? 0xFF;
    storage[a] = existing & b; // NOR can only clear bits
    wipCounter = 3;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'write/erase engine: erase, program, WREN-required, XIP still works',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');

      // Read-side bus
      final stb = Logic(name: 'stb');
      final rdAddr = Logic(name: 'rd_addr', width: 32);

      // Write command interface
      final wrReq = Logic(name: 'wr_req');
      final wrOp = Logic(name: 'wr_op');
      final wrAddr = Logic(name: 'wr_addr', width: 24);
      final wrLen = Logic(name: 'wr_len', width: 9);
      final wrData = Logic(name: 'wr_data', width: 8);

      // MISO driven by the model.
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
      flash.input('bus_ADR').srcConnection! <= rdAddr;
      flash.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 32);
      flash.input('bus_SEL').srcConnection! <=
          Const(0xF, width: flash.input('bus_SEL').width);
      flash.input('spi_miso').srcConnection! <= miso;
      flash.input('wr_req').srcConnection! <= wrReq;
      flash.input('wr_op').srcConnection! <= wrOp;
      flash.input('wr_addr').srcConnection! <= wrAddr;
      flash.input('wr_len').srcConnection! <= wrLen;
      flash.input('wr_data').srcConnection! <= wrData;

      await flash.build();

      final spiClk = flash.output('spi_clk');
      final csN = flash.output('spi_cs_n');
      final mosi = flash.output('spi_mosi');
      final wrBusy = flash.output('wr_busy');
      final wrDone = flash.output('wr_done');
      final wrDataIndex = flash.output('wr_data_index');
      final ack = flash.output('bus_ACK');
      final misoWord = flash.output('bus_DAT_MISO');

      final model = _SpiNorModel();

      reset.inject(1);
      stb.inject(0);
      rdAddr.inject(0);
      miso.inject(0);
      wrReq.inject(0);
      wrOp.inject(0);
      wrAddr.inject(0);
      wrLen.inject(0);
      wrData.inject(0);

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      // Let the startup clocks finish before the first request.
      for (var i = 0; i < 2 * HarborSpiFlashController.startupClocks + 2; i++) {
        await clk.nextPosedge;
      }

      // Background process: drive the behavioral flash model from the SPI pins.
      // - sample MOSI on spi_clk rising edges,
      // - present MISO (status) and advance on falling edges,
      // - track CS edges.
      var prevClk = 0;
      var prevCs = 1;
      var riseIdx =
          0; // rising-edge index within the current CS-low transaction
      var modelRunning = true;
      final modelProc = () async {
        while (modelRunning) {
          await clk.nextPosedge;
          // Sample combinationally-settled values just after the posedge.
          final cs = csN.value.isValid ? csN.value.toInt() : 1;
          final sc = spiClk.value.isValid ? spiClk.value.toInt() : 0;
          final dq0 = mosi.value.isValid ? mosi.value.toInt() : 0;

          // CS edges.
          if (cs == 0 && prevCs == 1) {
            model.csFall();
            riseIdx = 0;
          }
          if (cs == 1 && prevCs == 0) {
            model.csRise();
            riseIdx = 0;
          }

          if (cs == 0 && sc == 1 && prevClk == 0) {
            // Rising edge. Mirror the read-path testbench: present the MISO bit
            // for THIS rising index (captured by the controller on the following
            // falling edge), sample MOSI, then advance the index.
            miso.inject(model.misoBitAt(riseIdx));
            model.clkRise(dq0);
            // Re-evaluate MISO in case this rising edge just entered the status
            // phase (the RDSR opcode completed on this very edge).
            miso.inject(model.misoBitAt(riseIdx));
            riseIdx++;
          }
          prevClk = cs == 0 ? sc : 0;
          prevCs = cs;
        }
      }();

      Future<void> issueWrite(
        int op,
        int address,
        int length,
        List<int> bytes,
      ) async {
        // Drive program-data via the read-callback: present wr_data at the
        // index the engine requests on wr_data_index.
        wrOp.inject(op);
        wrAddr.inject(address);
        wrLen.inject(length);
        wrReq.inject(1);
        // Present byte for current index continuously.
        await clk.nextPosedge;
        wrReq.inject(0);
        // Service the data callback until done.
        var guard = 0;
        while (true) {
          guard++;
          if (guard > 200000) {
            fail('write did not complete');
          }
          final idx = wrDataIndex.value.isValid ? wrDataIndex.value.toInt() : 0;
          if (op == 1 && idx < bytes.length) {
            wrData.inject(bytes[idx]);
          }
          if (wrDone.value.isValid && wrDone.value.toBool()) {
            break;
          }
          await clk.nextPosedge;
        }
      }

      // Pre-fill some bytes in the sector with non-0xFF to prove the erase.
      model.storage[0x1000] = 0x00;
      model.storage[0x1FFF] = 0x55;
      expect(wrBusy.value.toInt(), equals(0), reason: 'busy before erase');
      await issueWrite(0, 0x1000, 0, const []);
      // After wr_done, busy must drop on the next cycle.
      await clk.nextPosedge;
      expect(wrBusy.value.toInt(), equals(0), reason: 'busy after erase done');
      expect(model.read(0x1000), equals(0xFF), reason: 'sector start erased');
      expect(model.read(0x1FFF), equals(0xFF), reason: 'sector end erased');
      expect(
        model.read(0x2000),
        equals(0xFF),
        reason: 'next sector untouched (default 0xFF)',
      );
      // The model held WIP busy for 3 RDSR polls after erase, so the engine must
      // have polled RDSR multiple times before completing (it WAITED for busy).
      expect(
        model.rdsrCount,
        greaterThanOrEqualTo(2),
        reason: 'engine did not poll WIP for the erase',
      );
      expect(
        model.wipCounter,
        equals(0),
        reason: 'engine completed before WIP cleared (erase)',
      );
      final rdsrAfterErase = model.rdsrCount;

      final progBytes = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04];
      await issueWrite(1, 0x1000, progBytes.length, progBytes);
      await clk.nextPosedge;
      expect(
        wrBusy.value.toInt(),
        equals(0),
        reason: 'busy after program done',
      );
      for (var i = 0; i < progBytes.length; i++) {
        expect(
          model.read(0x1000 + i),
          equals(progBytes[i]),
          reason: 'programmed byte $i',
        );
      }
      // WIP must have been polled to clear: model.wipCounter back to 0, and the
      // program issued its own round of RDSR polls on top of the erase's.
      expect(model.wipCounter, equals(0), reason: 'WIP polled to completion');
      expect(
        model.rdsrCount - rdsrAfterErase,
        greaterThanOrEqualTo(2),
        reason: 'engine did not poll WIP for the program',
      );

      // 3. WREN-required: drive a program when the model has WEL cleared by
      // construction. The engine always issues WREN, so it should succeed. To
      // prove WREN actually happens, temporarily make the model reject if WEL is
      // not seen. We assert success here, then separately prove the model would
      // reject without WREN.
      // Program a fresh region.
      final progBytes2 = [0xAA, 0xBB];
      await issueWrite(1, 0x1010, progBytes2.length, progBytes2);
      await clk.nextPosedge;
      expect(model.read(0x1010), equals(0xAA));
      expect(model.read(0x1011), equals(0xBB));

      // Negative control: directly exercise the model with WEL unset to confirm
      // it would reject (so the success above proves WREN was sent).
      final m2 = _SpiNorModel();
      m2.wel = false;
      m2.csFall();
      // feed 0x02 + addr + data WITHOUT a preceding WREN
      void feedByte(int b) {
        for (var i = 7; i >= 0; i--) {
          m2.clkRise((b >> i) & 1);
        }
      }

      feedByte(0x02);
      feedByte(0x00);
      feedByte(0x20);
      feedByte(0x00);
      feedByte(0x42);
      m2.csRise();
      expect(
        m2.read(0x2000),
        equals(0xFF),
        reason: 'model rejects program without WREN',
      );

      final rbytes = [0x12, 0x34, 0x56, 0x78];
      final expectedRead =
          rbytes[0] | (rbytes[1] << 8) | (rbytes[2] << 16) | (rbytes[3] << 24);
      final dataBits = <int>[
        for (final b in rbytes)
          for (var i = 7; i >= 0; i--) (b >> i) & 1,
      ];
      const dataStart = 8 + 24;

      // Pause the write model process. Drive a read with a dedicated MISO model.
      modelRunning = false;
      await modelProc;

      rdAddr.inject(0x40);
      stb.inject(1);
      var prevClk2 = 0;
      var riseCount = 0;
      var prevCs2 = 1;
      var got = false;
      var data = 0;
      for (var i = 0; i < 2000; i++) {
        await clk.nextPosedge;
        final cs = csN.value.toInt();
        final sc = spiClk.value.toInt();
        if (cs == 1) {
          riseCount = 0;
        } else {
          if (prevCs2 == 1) riseCount = 0;
          if (sc == 1 && prevClk2 == 0) {
            final idx = riseCount - dataStart;
            miso.inject(idx >= 0 && idx < dataBits.length ? dataBits[idx] : 0);
            riseCount++;
          }
        }
        prevClk2 = sc;
        prevCs2 = cs;
        if (ack.value.isValid && ack.value.toBool()) {
          data = misoWord.value.toInt();
          got = true;
          break;
        }
      }
      stb.inject(0);
      expect(got, isTrue, reason: 'XIP read never acked after writes');
      expect(
        data,
        equals(expectedRead),
        reason: 'XIP read regressed: got 0x${data.toRadixString(16)}',
      );

      await Simulator.endSimulation();
    },
  );
}
