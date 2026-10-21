import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Safety / bricking-class regression tests for the [HarborSpiFlashController]
/// WRITE/ERASE engine:
///  - B1: a wr_req fired mid-read-frame must NOT seize the SPI pins. The read
///        frame completes cleanly, THEN the write runs.
///  - B2: the read FSM must not advance/ack during a write.
///  - I3: a 4-byte-address part lands the write at the right address.
///  - I4: a stuck WIP times out (wr_err) instead of hanging forever.
///  - Minor: invalid page-program (len==0 / page-cross) raises wr_err, no pins.
///
/// Standard SPI is used so MISO is a plain INPUT (drivable from the testbench
/// without an inout co-sim), the write engine drives standard single-bit DQ0
/// regardless of read mode, so this is representative.
///
/// These are long flash-protocol tests (erase/program/poll sequences, a
/// watchdog timeout), driven mostly through the wr_req sideband, so they stay
/// on Wishbone only rather than looping three times over.

/// Configurable-address behavioral SPI NOR model (3- or 4-byte addressing).
class _SpiNorModel {
  _SpiNorModel({this.addressBytes = 3, this.stuckWip = false});

  final int addressBytes;
  final bool stuckWip; // if true, WIP never clears (models a dead part)

  final storage = <int, int>{};
  bool wel = false;
  int wipCounter = 0;
  int rdsrCount = 0;

  int curByte = 0;
  int bitsInByte = 0;
  final cmdBytes = <int>[];
  int cmd = 0;
  int addr = 0;
  bool servingStatus = false;
  int statusByte = 0;

  int read(int a) => storage[a] ?? 0xFF;

  void csRise() {
    if (cmd == 0x20 || cmd == 0x02) wel = false;
    curByte = 0;
    bitsInByte = 0;
    cmdBytes.clear();
    cmd = 0;
    addr = 0;
    servingStatus = false;
    statusByte = 0;
  }

  void csFall() {
    curByte = 0;
    bitsInByte = 0;
    cmdBytes.clear();
    cmd = 0;
    servingStatus = false;
    statusByte = 0;
  }

  int misoBitAt(int idx) {
    if (servingStatus) {
      final d = idx - 8;
      if (d >= 0 && d < 8) return (statusByte >> (7 - d)) & 1;
    }
    return 0;
  }

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
        wel = true;
      } else if (cmd == 0x05) {
        final wip = (wipCounter > 0 || stuckWip) ? 1 : 0;
        if (wipCounter > 0) wipCounter--;
        rdsrCount++;
        statusByte = wip | (wel ? 2 : 0);
        servingStatus = true;
      }
      return;
    }
    final lastAddrByte = 1 + addressBytes; // cmdBytes.length of final addr byte
    if (cmd == 0x20 || cmd == 0x02) {
      if (cmdBytes.length >= 2 && cmdBytes.length <= lastAddrByte) {
        addr = (addr << 8) | b;
        if (cmd == 0x20 && cmdBytes.length == lastAddrByte) _erase(addr);
        return;
      }
      if (cmd == 0x02 && cmdBytes.length > lastAddrByte) {
        final dataIdx = cmdBytes.length - (lastAddrByte + 1);
        _program(addr + dataIdx, b);
      }
    }
  }

  void _erase(int sectorAddr) {
    if (!wel) return;
    final base = sectorAddr & ~0xFFF;
    for (var i = 0; i < 4096; i++) {
      storage[base + i] = 0xFF;
    }
    wipCounter = stuckWip ? 0 : 3;
  }

  void _program(int a, int b) {
    if (!wel) return;
    storage[a] = (storage[a] ?? 0xFF) & b;
    wipCounter = stuckWip ? 0 : 3;
  }
}

/// Test harness wiring + a background SPI-model driver. Reused across tests.
class _Harness {
  _Harness({
    required this.addressBytes,
    bool stuckWip = false,
    int size = 1024 * 1024,
    int writePollLimit = (1 << 20) - 1,
  }) : model = _SpiNorModel(addressBytes: addressBytes, stuckWip: stuckWip) {
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    stb = Logic(name: 'stb');
    rdAddr = Logic(name: 'rd_addr', width: 32);
    wrReq = Logic(name: 'wr_req');
    wrOp = Logic(name: 'wr_op');
    wrAddr = Logic(name: 'wr_addr', width: addressBytes * 8);
    wrLen = Logic(name: 'wr_len', width: 9);
    wrData = Logic(name: 'wr_data', width: 8);
    miso = Logic(name: 'miso');

    flash = HarborSpiFlashController(
      config: HarborSpiFlashConfig(
        size: size,
        mode: HarborSpiFlashMode.standard,
        readCommand: 0x03,
        addressBytes: addressBytes,
        dummyCycles: 0,
      ),
      baseAddress: 0x20000000,
      busAddressWidth: 32,
      busDataWidth: 32,
      writePollLimit: writePollLimit,
    );
  }

  final int addressBytes;
  final _SpiNorModel model;
  late final Logic clk;
  late final Logic reset, stb, rdAddr;
  late final Logic wrReq, wrOp, wrAddr, wrLen, wrData, miso;
  late final HarborSpiFlashController flash;

  late final Logic spiClk, csN, mosi, wrBusy, wrDone, wrErr, wrDataIndex;
  late final Logic ack, misoWord;

  bool _modelRunning = false;
  Future<void>? _modelProc;

  Future<void> build() async {
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

    spiClk = flash.output('spi_clk');
    csN = flash.output('spi_cs_n');
    mosi = flash.output('spi_mosi');
    wrBusy = flash.output('wr_busy');
    wrDone = flash.output('wr_done');
    wrErr = flash.output('wr_err');
    wrDataIndex = flash.output('wr_data_index');
    ack = flash.output('bus_ACK');
    misoWord = flash.output('bus_DAT_MISO');

    reset.inject(1);
    stb.inject(0);
    rdAddr.inject(0);
    miso.inject(0);
    wrReq.inject(0);
    wrOp.inject(0);
    wrAddr.inject(0);
    wrLen.inject(0);
    wrData.inject(0);

    Simulator.setMaxSimTime(40000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    // Let the startup clocks finish before the first request.
    for (var i = 0; i < 2 * HarborSpiFlashController.startupClocks + 2; i++) {
      await clk.nextPosedge;
    }
  }

  /// Background process: drive the behavioral model from the SPI pins.
  void startModel() {
    _modelRunning = true;
    var prevClk = 0;
    var prevCs = 1;
    var riseIdx = 0;
    _modelProc = () async {
      while (_modelRunning) {
        await clk.nextPosedge;
        final cs = csN.value.isValid ? csN.value.toInt() : 1;
        final sc = spiClk.value.isValid ? spiClk.value.toInt() : 0;
        final dq0 = mosi.value.isValid ? mosi.value.toInt() : 0;
        if (cs == 0 && prevCs == 1) {
          model.csFall();
          riseIdx = 0;
        }
        if (cs == 1 && prevCs == 0) {
          model.csRise();
          riseIdx = 0;
        }
        if (cs == 0 && sc == 1 && prevClk == 0) {
          miso.inject(model.misoBitAt(riseIdx));
          model.clkRise(dq0);
          miso.inject(model.misoBitAt(riseIdx));
          riseIdx++;
        }
        prevClk = cs == 0 ? sc : 0;
        prevCs = cs;
      }
    }();
  }

  Future<void> stopModel() async {
    _modelRunning = false;
    await _modelProc;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // I3: building with an unsupported address width fails loudly.
  test('I3: addressBytes other than 3/4 throws at construction', () {
    expect(
      () => HarborSpiFlashController(
        config: const HarborSpiFlashConfig(
          size: 1024 * 1024,
          mode: HarborSpiFlashMode.standard,
          addressBytes: 2,
        ),
        baseAddress: 0x20000000,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  // I3: a 4-byte-address part programs at the correct (full 32-bit) address.
  test('I3: 4-byte addressing programs at the right sector', () async {
    final h = _Harness(addressBytes: 4, size: 32 * 1024 * 1024);
    await h.build();
    h.startModel();

    // Address above the 24-bit boundary: a 3-byte engine would drop 0x02 and
    // land at 0x031000 instead of 0x02031000 -> wrong sector -> brick.
    const target = 0x02031000;
    final progBytes = [0xCA, 0xFE];
    h.wrOp.inject(1);
    h.wrAddr.inject(target);
    h.wrLen.inject(progBytes.length);
    h.wrReq.inject(1);
    await h.clk.nextPosedge;
    h.wrReq.inject(0);

    var guard = 0;
    while (true) {
      if (++guard > 200000) fail('write never completed');
      final idx = h.wrDataIndex.value.isValid ? h.wrDataIndex.value.toInt() : 0;
      if (idx < progBytes.length) h.wrData.inject(progBytes[idx]);
      if (h.wrDone.value.isValid && h.wrDone.value.toBool()) break;
      await h.clk.nextPosedge;
    }
    await h.stopModel();

    expect(
      h.wrErr.value.toInt(),
      equals(0),
      reason: 'no error on valid 4B prog',
    );
    expect(h.model.read(target), equals(0xCA), reason: 'byte0 at 32-bit addr');
    expect(h.model.read(target + 1), equals(0xFE), reason: 'byte1');
    // Prove it did NOT land at the 24-bit-truncated address.
    expect(
      h.model.read(0x031000),
      equals(0xFF),
      reason: 'must not land at the truncated 24-bit address',
    );

    await Simulator.endSimulation();
  });

  // B1 + B2: a wr_req fired mid-read-frame must not seize the pins. The read
  // completes cleanly first, then the write runs. ack never fires during write.
  test('B1/B2: wr_req mid-read-frame holds; read completes, then write runs', () async {
    final h = _Harness(addressBytes: 3);
    await h.build();
    // This test drives BOTH the read-MISO responder and the write-engine model
    // from a single loop (no background model proc) so the two never fight over
    // miso.inject: while NOT wr_busy we serve read data, while wr_busy we serve
    // the write model (RDSR status etc.).

    final rbytes = [0x11, 0x22, 0x33, 0x44];
    final expectedRead =
        rbytes[0] | (rbytes[1] << 8) | (rbytes[2] << 16) | (rbytes[3] << 24);
    final dataBits = <int>[
      for (final b in rbytes)
        for (var i = 7; i >= 0; i--) (b >> i) & 1,
    ];
    const dataStart = 8 + 24;

    // Pre-fill a sector so the (later) erase is observable.
    h.model.storage[0x2000] = 0x00;

    h.rdAddr.inject(0x40);
    h.stb.inject(1);

    var prevClk = 0;
    var prevCs = 1;
    var rdRise = 0; // read-frame rising-edge index (only valid when !wr_busy)
    var wrRise = 0; // write-frame rising-edge index (within a CS-low frame)
    var ackDuringWrite = false;
    var seenWrBusy = false;
    var readData = 0;
    var readGot = false;
    var wrReqFired = false;
    var wrAccepted = false;
    var pinsSeizedMidRead = false;
    var writeDone = false;

    for (var i = 0; i < 20000; i++) {
      await h.clk.nextPosedge;
      final cs = h.csN.value.isValid ? h.csN.value.toInt() : 1;
      final sc = h.spiClk.value.isValid ? h.spiClk.value.toInt() : 0;
      final busy = h.wrBusy.value.isValid ? h.wrBusy.value.toInt() : 0;
      final dq0 = h.mosi.value.isValid ? h.mosi.value.toInt() : 0;

      if (busy == 0) {
        // READ-MISO responder (read FSM owns the pins).
        if (cs == 1) {
          rdRise = 0;
        } else {
          if (prevCs == 1) rdRise = 0;
          if (sc == 1 && prevClk == 0) {
            final idx = rdRise - dataStart;
            h.miso.inject(
              idx >= 0 && idx < dataBits.length ? dataBits[idx] : 0,
            );
            rdRise++;
          }
        }
      } else {
        // WRITE model (write engine owns the pins): track CS edges, present
        // RDSR status on MISO, sample MOSI command/addr/data bits.
        if (cs == 0 && prevCs == 1) {
          h.model.csFall();
          wrRise = 0;
        }
        if (cs == 1 && prevCs == 0) {
          h.model.csRise();
          wrRise = 0;
        }
        if (cs == 0 && sc == 1 && prevClk == 0) {
          h.miso.inject(h.model.misoBitAt(wrRise));
          h.model.clkRise(dq0);
          h.miso.inject(h.model.misoBitAt(wrRise));
          wrRise++;
        }
      }

      // Fire wr_req a few rising edges INTO the read frame, hold until accepted.
      if (!wrReqFired && busy == 0 && cs == 0 && rdRise > 6) {
        h.wrOp.inject(0); // sector erase
        h.wrAddr.inject(0x2000);
        h.wrLen.inject(0);
        h.wrReq.inject(1);
        wrReqFired = true;
      }

      // B1: until the read retires (readGot), the write must NOT own the pins.
      if (wrReqFired && !readGot && busy == 1) pinsSeizedMidRead = true;

      // Capture the read result (the in-flight read must complete cleanly).
      if (!readGot && h.ack.value.isValid && h.ack.value.toBool()) {
        readData = h.misoWord.value.toInt();
        readGot = true;
        h.stb.inject(0); // no more reads, let the held write proceed
      }

      // Once the write is accepted, drop wr_req (engine has latched it).
      if (busy == 1 && !wrAccepted) {
        wrAccepted = true;
        h.wrReq.inject(0);
      }

      // B2: ack must never assert while a write owns the pins.
      if (busy == 1) {
        seenWrBusy = true;
        if (h.ack.value.isValid && h.ack.value.toBool()) ackDuringWrite = true;
      }

      if (h.wrDone.value.isValid && h.wrDone.value.toBool() && seenWrBusy) {
        writeDone = true;
        break;
      }

      prevClk = (cs == 0) ? sc : 0;
      prevCs = cs;
    }

    expect(readGot, isTrue, reason: 'read frame never completed');
    expect(
      pinsSeizedMidRead,
      isFalse,
      reason: 'B1: write seized the pins mid-read-frame',
    );
    expect(
      readData,
      equals(expectedRead),
      reason: 'B1: read corrupted, got 0x${readData.toRadixString(16)}',
    );
    expect(
      ackDuringWrite,
      isFalse,
      reason: 'B2: read FSM asserted ack during a write',
    );
    expect(seenWrBusy, isTrue, reason: 'write never started after read');
    expect(writeDone, isTrue, reason: 'write never completed');
    expect(h.wrErr.value.toInt(), equals(0), reason: 'no error expected');
    expect(
      h.model.read(0x2000),
      equals(0xFF),
      reason: 'erase ran after the read (sector cleared)',
    );

    await Simulator.endSimulation();
  });

  // I4: WIP never clears -> watchdog times out, wr_err set, wr_busy drops.
  test('I4: stuck WIP times out (wr_err), does not hang', () async {
    // Small watchdog bound so the timeout is reached quickly in simulation.
    final h = _Harness(addressBytes: 3, stuckWip: true, writePollLimit: 8);
    await h.build();
    h.startModel();

    h.wrOp.inject(0); // erase
    h.wrAddr.inject(0x3000);
    h.wrLen.inject(0);
    h.wrReq.inject(1);
    await h.clk.nextPosedge;
    h.wrReq.inject(0);

    var done = false;
    for (var i = 0; i < 100000; i++) {
      await h.clk.nextPosedge;
      if (h.wrDone.value.isValid && h.wrDone.value.toBool()) {
        done = true;
        break;
      }
    }
    await h.stopModel();

    expect(done, isTrue, reason: 'I4: engine hung on stuck WIP (no wr_done)');
    expect(
      h.wrErr.value.toInt(),
      equals(1),
      reason: 'I4: wr_err not raised on timeout',
    );
    await h.clk.nextPosedge;
    expect(
      h.wrBusy.value.toInt(),
      equals(0),
      reason: 'I4: wr_busy stuck high after timeout',
    );

    await Simulator.endSimulation();
  });

  // Minor: invalid page-program inputs raise wr_err without touching the pins.
  test('Minor: zero-length program raises wr_err, no SPI frame', () async {
    final h = _Harness(addressBytes: 3);
    await h.build();
    h.startModel();

    h.wrOp.inject(1); // program
    h.wrAddr.inject(0x100);
    h.wrLen.inject(0); // invalid
    h.wrReq.inject(1);

    // wr_done should pulse the cycle the reject is sampled (with wr_err set) and
    // no SPI frame should be issued. Poll across the request edge so the
    // single-cycle pulse is not missed, then deassert wr_req.
    var done = false;
    for (var i = 0; i < 1000; i++) {
      await h.clk.nextPosedge;
      if (i == 0) h.wrReq.inject(0);
      if (h.wrDone.value.isValid && h.wrDone.value.toBool()) {
        done = true;
        break;
      }
    }
    await h.stopModel();

    expect(done, isTrue, reason: 'rejected program never signalled done');
    expect(
      h.wrErr.value.toInt(),
      equals(1),
      reason: 'zero-length program must raise wr_err',
    );
    expect(
      h.model.cmdBytes.isEmpty,
      isTrue,
      reason: 'no SPI command framed for a rejected program',
    );

    await Simulator.endSimulation();
  });

  test('Minor: page-crossing program raises wr_err, no SPI frame', () async {
    final h = _Harness(addressBytes: 3);
    await h.build();
    h.startModel();

    // (0x80 & 0xFF) + 200 = 328 > 256 -> would wrap the page on real flash.
    h.wrOp.inject(1);
    h.wrAddr.inject(0x80);
    h.wrLen.inject(200);
    h.wrReq.inject(1);

    var done = false;
    for (var i = 0; i < 1000; i++) {
      await h.clk.nextPosedge;
      if (i == 0) h.wrReq.inject(0);
      if (h.wrDone.value.isValid && h.wrDone.value.toBool()) {
        done = true;
        break;
      }
    }
    await h.stopModel();

    expect(done, isTrue, reason: 'rejected program never signalled done');
    expect(
      h.wrErr.value.toInt(),
      equals(1),
      reason: 'page-crossing program must raise wr_err',
    );
    expect(
      h.model.cmdBytes.isEmpty,
      isTrue,
      reason: 'no SPI command framed for a rejected program',
    );

    await Simulator.endSimulation();
  });
}
