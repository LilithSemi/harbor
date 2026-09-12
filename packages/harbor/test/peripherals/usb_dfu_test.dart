import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

// Independent re-derivation of the descriptor byte tables FROM the field
// tables (USB 2.0 ch9 + DFU 1.1). These are built by hand here rather than
// imported from the module, so a transcription error in the module is caught.

// Little-endian 16-bit helper.
List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

// USB CRC16: reflected poly 0xA001, init 0xFFFF, LSB first per byte. Ported
// from usb_test.dart / usb_phy_test.dart so the test can independently compute
// the expected CRC bytes that the UsbPacketTx hardware must produce.
int _crc16(List<int> bytes) {
  var crc = 0xFFFF;
  for (final b in bytes) {
    for (var i = 0; i < 8; i++) {
      final bit = (b >> i) & 1;
      final xorIn = (crc & 1) ^ bit;
      crc >>= 1;
      if (xorIn != 0) crc ^= 0xA001;
    }
  }
  return (~crc) & 0xFFFF;
}

// UTF-16LE encode an ASCII string (each char + 0x00).
List<int> _utf16le(String s) {
  final out = <int>[];
  for (final u in s.codeUnits) {
    out.add(u & 0xFF);
    out.add((u >> 8) & 0xFF);
  }
  return out;
}

// DEVICE descriptor, 18 bytes.
final List<int> expectedDevice = [
  18, // bLength
  0x01, // bDescriptorType
  ..._le16(0x0200), // bcdUSB
  0, // bDeviceClass
  0, // bDeviceSubClass
  0, // bDeviceProtocol
  64, // bMaxPacketSize0
  ..._le16(0x1209), // idVendor
  ..._le16(0x5BF1), // idProduct
  ..._le16(0x0100), // bcdDevice
  1, // iManufacturer
  2, // iProduct
  0, // iSerialNumber
  1, // bNumConfigurations
];

// CONFIGURATION tree, 36 bytes.
final List<int> expectedConfigHeader = [
  9,
  0x02,
  ..._le16(36),
  1,
  1,
  0,
  0x80,
  50,
];
final List<int> expectedIfaceAlt0 = [9, 0x04, 0, 0, 0, 0xFE, 0x01, 0x02, 4];
final List<int> expectedIfaceAlt1 = [9, 0x04, 0, 1, 0, 0xFE, 0x01, 0x02, 5];
final List<int> expectedDfuFunctional = [
  9,
  0x21,
  0x05,
  ..._le16(0x00FF),
  ..._le16(64),
  ..._le16(0x0110),
];
final List<int> expectedConfig = [
  ...expectedConfigHeader,
  ...expectedIfaceAlt0,
  ...expectedIfaceAlt1,
  ...expectedDfuFunctional,
];

// STRING descriptors.
final List<int> expectedStr0 = [4, 0x03, ..._le16(0x0409)];
List<int> _expectedString(String s) => [2 + 2 * s.length, 0x03, ..._utf16le(s)];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // The heavy host-model engine groups (enumeration + DFU class layer) are
  // declared FIRST, before the lighter descriptor-ROM and packet round-trip
  // unit groups. In a single-isolate run ROHD pins every built wire's pre-tick
  // listener onto the live Simulator across `Simulator.reset()`, so each test's
  // armed wires inflate every later test's per-tick fan-out. Running the engine
  // groups while the accumulated wire set is still small (plus sharing one
  // harness per group) keeps their per-tick cost low, the cheap unit groups
  // tolerate the residual accumulation that follows.

  // PID bytes (USB 2.0).
  const pidSetup = 0x2D;
  const pidIn = 0x69;
  const pidOut = 0xE1;
  const pidData0 = 0xC3;
  const pidData1 = 0x4B;
  const pidAck = 0xD2;

  group('UsbDfuFlashSink (drives real HarborSpiFlashController + SPI NOR model)', () {
    test('programs an image spanning two pages within one sector: '
        'erase-first, byte-exact, image_ready, bytes_written, error stays 0', () async {
      const flashBase = 0x1000; // sector-aligned (4KB)
      final sink = UsbDfuFlashSink(
        name: 'flash_sink',
        flashBase: flashBase,
        sectorSize: 4096,
        pageSize: 256,
        addrWidth: 24,
        fifoDepth: 128,
      );
      final flash = HarborSpiFlashController(
        name: 'flash_ctrl',
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
        // Lower the WIP-poll watchdog far below default so a stuck part trips
        // fast, the healthy model clears WIP in a few polls, well under this.
        writePollLimit: 4096,
      );
      final top = _FlashSinkTop(sink: sink, flash: flash);

      final usbClk = SimpleClockGenerator(10).clk;
      final busClk = SimpleClockGenerator(40).clk;
      top.port('usb_clk').getsLogic(usbClk);
      top.port('bus_clk').getsLogic(busClk);

      await top.build();

      final usbReset = top.input('usb_reset');
      final busReset = top.input('bus_reset');
      final sinkData = top.input('sink_data');
      final sinkValid = top.input('sink_valid');
      final dnloadDone = top.input('dnload_done');
      final altSetting = top.input('alt_setting');
      final miso = top.input('spi_miso');

      // Behavioral SPI NOR model wired to the controller's SPI pins.
      final spiClk = top.output('spi_clk');
      final csN = top.output('spi_cs_n');
      final mosi = top.output('spi_mosi');
      final model = _SpiNorModel();

      // Pre-fill the target region with non-0xFF so the erase is observable:
      // these MUST read 0xFF after the erase and then the image bytes after the
      // program.
      final image = <int>[
        for (var i = 0; i < 300; i++) (0xA0 + i) & 0xFF, // 300 bytes => 2 pages
      ];
      expect(image.length, equals(300));
      for (var i = 0; i < image.length; i++) {
        model.storage[flashBase + i] = 0x00; // start dirty
      }
      // Snapshot: confirm the region is dirty before programming.
      expect(model.read(flashBase), equals(0x00));
      expect(model.read(flashBase + 299), equals(0x00));

      Simulator.setMaxSimTime(200000000);
      unawaited(Simulator.run());

      usbReset.inject(1);
      busReset.inject(1);
      sinkData.inject(0);
      sinkValid.inject(0);
      dnloadDone.inject(0);
      altSetting.inject(1); // FLASH interface selected
      miso.inject(0);
      for (var i = 0; i < 5; i++) {
        await busClk.nextPosedge;
      }
      usbReset.put(0);
      busReset.put(0);
      await busClk.nextPosedge;

      // Background: drive the SPI NOR model off the controller's pins, exactly
      // like spi_flash_write_test.dart (sample MOSI + present status MISO on
      // rising edges, track CS edges).
      var prevClk = 0;
      var prevCs = 1;
      var riseIdx = 0;
      var modelRunning = true;
      final modelProc = () async {
        while (modelRunning) {
          await busClk.nextPosedge;
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

      // Stream the 300-byte image with realistic gaps, honor sink_ready so the
      // (slow) flash side back-pressures the producer like the DFU host waits on
      // GETSTATUS between blocks.
      for (final b in image) {
        var guard = 0;
        while (top.output('sink_ready').value.toInt() == 0 && guard < 2000000) {
          guard++;
          await usbClk.nextPosedge;
        }
        sinkData.put(b);
        sinkValid.put(1);
        await usbClk.nextPosedge;
        sinkValid.put(0);
        sinkData.put(0);
        await usbClk.nextPosedge;
      }
      // Wait for sink_ready before the done marker, then pulse it.
      var g2 = 0;
      while (top.output('sink_ready').value.toInt() == 0 && g2 < 2000000) {
        g2++;
        await usbClk.nextPosedge;
      }
      dnloadDone.put(1);
      await usbClk.nextPosedge;
      dnloadDone.put(0);

      // Wait for image_ready in the bus domain (generous: 2 erases worth of WIP
      // polls + 2 page programs).
      var readySeen = false;
      for (var i = 0; i < 2000000; i++) {
        await busClk.nextPosedge;
        if (top.output('image_ready').value.isValid &&
            top.output('image_ready').value.toInt() == 1) {
          readySeen = true;
          break;
        }
      }
      expect(readySeen, isTrue, reason: 'image_ready pulsed after the image');

      modelRunning = false;
      await modelProc;

      // error stays 0, bytes_written == image length.
      expect(
        top.output('error').value.toInt(),
        equals(0),
        reason: 'no error on a healthy program',
      );
      expect(
        top.output('bytes_written').value.toInt(),
        equals(image.length),
        reason: 'bytes_written counts every programmed byte',
      );

      // The image is byte-exact in flash at flashBase..
      for (var i = 0; i < image.length; i++) {
        expect(
          model.read(flashBase + i),
          equals(image[i]),
          reason: 'flash byte[$i] @ 0x${(flashBase + i).toRadixString(16)}',
        );
      }
      // The sector was erased exactly once: the model only programmed the 300
      // bytes, bytes ABOVE the image within the same erased sector are 0xFF
      // (erased), proving the erase ran (they were never re-dirtied).
      expect(
        model.read(flashBase + 300),
        equals(0xFF),
        reason: 'tail of the erased sector is 0xFF (erase happened)',
      );
      expect(
        model.read(flashBase + 4095),
        equals(0xFF),
        reason: 'end of the erased sector is 0xFF',
      );

      await Simulator.endSimulation();
    });

    test(
      'flash-idle: a RAM target (alt_setting=0) leaves the sink fully idle - '
      'wr_req never asserts, busy/image_ready stay low',
      () async {
        const flashBase = 0x2000;
        final sink = UsbDfuFlashSink(
          name: 'flash_sink_idle',
          flashBase: flashBase,
          addrWidth: 24,
          fifoDepth: 64,
        );
        final flash = HarborSpiFlashController(
          name: 'flash_ctrl_idle',
          config: const HarborSpiFlashConfig(
            size: 1024 * 1024,
            mode: HarborSpiFlashMode.standard,
            readCommand: 0x03,
            addressBytes: 3,
          ),
          baseAddress: 0x20000000,
          busAddressWidth: 32,
          busDataWidth: 32,
          writePollLimit: 4096,
        );
        final top = _FlashSinkTop(sink: sink, flash: flash);

        final usbClk = SimpleClockGenerator(10).clk;
        final busClk = SimpleClockGenerator(40).clk;
        top.port('usb_clk').getsLogic(usbClk);
        top.port('bus_clk').getsLogic(busClk);

        await top.build();

        final usbReset = top.input('usb_reset');
        final busReset = top.input('bus_reset');
        final sinkData = top.input('sink_data');
        final sinkValid = top.input('sink_valid');
        final dnloadDone = top.input('dnload_done');
        final altSetting = top.input('alt_setting');
        top.input('spi_miso').inject(0);

        // Watch wr_req: it must NEVER assert for a RAM target.
        var wrReqEverHigh = false;
        sink.output('wr_req').changed.listen((_) {
          final v = sink.output('wr_req').value;
          if (v.isValid && v.toInt() == 1) wrReqEverHigh = true;
        });

        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());

        usbReset.inject(1);
        busReset.inject(1);
        sinkData.inject(0);
        sinkValid.inject(0);
        dnloadDone.inject(0);
        altSetting.inject(0); // RAM interface -> flash sink stays idle
        for (var i = 0; i < 5; i++) {
          await busClk.nextPosedge;
        }
        usbReset.put(0);
        busReset.put(0);
        await busClk.nextPosedge;

        for (final b in [0x11, 0x22, 0x33, 0x44, 0x55]) {
          await usbClk.nextPosedge;
          sinkData.put(b);
          sinkValid.put(1);
          await usbClk.nextPosedge;
          sinkValid.put(0);
          await usbClk.nextPosedge;
        }
        await usbClk.nextPosedge;
        dnloadDone.put(1);
        await usbClk.nextPosedge;
        dnloadDone.put(0);

        for (var i = 0; i < 200; i++) {
          await busClk.nextPosedge;
          expect(
            top.output('busy').value.toInt(),
            equals(0),
            reason: 'busy stays low for a RAM target',
          );
          expect(
            top.output('image_ready').value.toInt(),
            equals(0),
            reason: 'no image_ready for a RAM target',
          );
          expect(
            top.output('bytes_written').value.toInt(),
            equals(0),
            reason: 'nothing programmed for a RAM target',
          );
        }
        expect(
          wrReqEverHigh,
          isFalse,
          reason: 'wr_req never asserts for a RAM target',
        );
        expect(
          top.output('overflow').value.toInt(),
          equals(0),
          reason: 'no overflow on an idle flash sink',
        );
        expect(
          top.output('error').value.toInt(),
          equals(0),
          reason: 'no error on an idle flash sink',
        );

        await Simulator.endSimulation();
      },
    );

    test('WIP-timeout error path: a stuck part latches error and stops '
        'programming', () async {
      const flashBase = 0x3000;
      final sink = UsbDfuFlashSink(
        name: 'flash_sink_err',
        flashBase: flashBase,
        addrWidth: 24,
        fifoDepth: 64,
      );
      final flash = HarborSpiFlashController(
        name: 'flash_ctrl_err',
        config: const HarborSpiFlashConfig(
          size: 1024 * 1024,
          mode: HarborSpiFlashMode.standard,
          readCommand: 0x03,
          addressBytes: 3,
        ),
        baseAddress: 0x20000000,
        busAddressWidth: 32,
        busDataWidth: 32,
        // Tiny watchdog so a never-clearing WIP trips wr_err quickly.
        writePollLimit: 4,
      );
      final top = _FlashSinkTop(sink: sink, flash: flash);

      final usbClk = SimpleClockGenerator(10).clk;
      final busClk = SimpleClockGenerator(40).clk;
      top.port('usb_clk').getsLogic(usbClk);
      top.port('bus_clk').getsLogic(busClk);

      await top.build();

      final usbReset = top.input('usb_reset');
      final busReset = top.input('bus_reset');
      final sinkData = top.input('sink_data');
      final sinkValid = top.input('sink_valid');
      final dnloadDone = top.input('dnload_done');
      final altSetting = top.input('alt_setting');
      final miso = top.input('spi_miso');

      final spiClk = top.output('spi_clk');
      final csN = top.output('spi_cs_n');
      final mosi = top.output('spi_mosi');
      // STUCK part: WIP never clears (wipCounter pinned high), so the engine's
      // RDSR poll hits the watchdog and raises wr_err on the first erase.
      final model = _SpiNorModel(stuckWip: true);

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      usbReset.inject(1);
      busReset.inject(1);
      sinkData.inject(0);
      sinkValid.inject(0);
      dnloadDone.inject(0);
      altSetting.inject(1);
      miso.inject(0);
      for (var i = 0; i < 5; i++) {
        await busClk.nextPosedge;
      }
      usbReset.put(0);
      busReset.put(0);
      await busClk.nextPosedge;

      var prevClk = 0;
      var prevCs = 1;
      var riseIdx = 0;
      var modelRunning = true;
      final modelProc = () async {
        while (modelRunning) {
          await busClk.nextPosedge;
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

      // Stream a small image (one page worth is plenty: the first erase fails).
      final image = List<int>.generate(8, (i) => 0x10 + i);
      for (final b in image) {
        var guard = 0;
        while (top.output('sink_ready').value.toInt() == 0 && guard < 200000) {
          guard++;
          await usbClk.nextPosedge;
        }
        sinkData.put(b);
        sinkValid.put(1);
        await usbClk.nextPosedge;
        sinkValid.put(0);
        await usbClk.nextPosedge;
      }
      await usbClk.nextPosedge;
      dnloadDone.put(1);
      await usbClk.nextPosedge;
      dnloadDone.put(0);

      // error must latch, image_ready must NOT fire.
      var errSeen = false;
      var readySeen = false;
      for (var i = 0; i < 200000; i++) {
        await busClk.nextPosedge;
        if (top.output('error').value.isValid &&
            top.output('error').value.toInt() == 1) {
          errSeen = true;
        }
        if (top.output('image_ready').value.isValid &&
            top.output('image_ready').value.toInt() == 1) {
          readySeen = true;
        }
        if (errSeen) break;
      }
      modelRunning = false;
      await modelProc;

      expect(errSeen, isTrue, reason: 'error latched on the WIP timeout');
      expect(
        readySeen,
        isFalse,
        reason: 'image_ready never fires after an error',
      );
      // error is sticky: stays high.
      await busClk.nextPosedge;
      expect(
        top.output('error').value.toInt(),
        equals(1),
        reason: 'error is sticky',
      );

      await Simulator.endSimulation();
    });
  });

  group('UsbEp0Engine enumeration (host model)', () {
    // Builds the engine + host model ONCE and returns the host helpers plus a
    // `resetDut` that returns the DUT to a pristine state via its reset port
    // (no rebuild). All enumeration scenarios share this single harness.
    //
    // Why share: in a single-isolate run ROHD pins every wire's pre-tick
    // listener onto the live Simulator across `Simulator.reset()`, so building
    // a fresh engine+host PHY stack per `test` makes each later sim tick fan
    // out to all wires from every prior test: an unbounded per-tick slowdown
    // that eventually reads as a hang. One shared harness keeps the armed-wire
    // set constant, so per-tick cost stays flat. `includeTestDescriptor` is
    // additive (it only adds STRING index 6) so a single engine built with it
    // serves every scenario, including the ZLP one.
    Future<Map<String, dynamic>> buildEnumHarness() async {
      final eng = UsbEp0Engine(name: 'ep0_eng', includeTestDescriptor: true);
      final htx = UsbPacketTx(name: 'host_ptx');
      final hphyTx = HarborUsbFsPhyTx(name: 'host_phytx');
      final hphyRx = HarborUsbFsPhyRx(name: 'host_phyrx');
      final hrx = UsbPacketRx(name: 'host_prx', bufBytes: 80);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final hSend = Logic(name: 'h_send');
      final hIsData = Logic(name: 'h_is_data');
      final hPid = Logic(name: 'h_pid', width: 8);
      final hPayLen = Logic(name: 'h_payload_len', width: 8);
      final hPayByte = Logic(name: 'h_payload_byte', width: 8);
      final hRdIndex = Logic(name: 'h_rd_index', width: 8);

      htx.input('clk').srcConnection! <= clk;
      htx.input('reset').srcConnection! <= reset;
      htx.input('send').srcConnection! <= hSend;
      htx.input('is_data').srcConnection! <= hIsData;
      htx.input('pid').srcConnection! <= hPid;
      htx.input('payload_len').srcConnection! <= hPayLen;
      htx.input('payload_byte').srcConnection! <= hPayByte;

      hphyTx.input('clk').srcConnection! <= clk;
      hphyTx.input('reset').srcConnection! <= reset;
      hphyTx.input('data').srcConnection! <= htx.output('tx_data');
      hphyTx.input('data_valid').srcConnection! <= htx.output('tx_data_valid');
      hphyTx.input('eop_req').srcConnection! <= htx.output('tx_eop_req');
      htx.input('tx_ready').srcConnection! <= hphyTx.output('ready');
      htx.input('tx_oe').srcConnection! <= hphyTx.output('oe');

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('dp').srcConnection! <= hphyTx.output('dp_out');
      eng.input('dm').srcConnection! <= hphyTx.output('dm_out');

      hphyRx.input('clk').srcConnection! <= clk;
      hphyRx.input('reset').srcConnection! <= reset;
      hphyRx.input('dp').srcConnection! <= eng.output('dp_out');
      hphyRx.input('dm').srcConnection! <= eng.output('dm_out');

      hrx.input('clk').srcConnection! <= clk;
      hrx.input('reset').srcConnection! <= reset;
      hrx.input('rx_data').srcConnection! <= hphyRx.output('data');
      hrx.input('rx_valid').srcConnection! <= hphyRx.output('valid');
      hrx.input('rx_sop').srcConnection! <= hphyRx.output('sop');
      hrx.input('rx_eop').srcConnection! <= hphyRx.output('eop');
      hrx.input('rd_index').srcConnection! <= hRdIndex;

      await eng.build();
      await htx.build();
      await hphyTx.build();
      await hphyRx.build();
      await hrx.build();

      reset.inject(1);
      hSend.inject(0);
      hIsData.inject(0);
      hPid.inject(0);
      hPayLen.inject(0);
      hPayByte.inject(0);
      hRdIndex.inject(0);
      Simulator.setMaxSimTime(160000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 20; i++) {
        await clk.nextPosedge;
      }

      // Current host send payload (served combinationally by payload_index).
      List<int> curPayload = const [];
      void serve() {
        if (curPayload.isEmpty) return;
        final i = htx.output('payload_index').value;
        final idx = i.isValid ? i.toInt() : 0;
        hPayByte.inject(idx < curPayload.length ? curPayload[idx] : 0);
      }

      // Send one host packet (handshake if payload empty & !isData).
      Future<void> hostSend({
        required int pid,
        required bool isData,
        List<int> payload = const [],
      }) async {
        curPayload = payload;
        hIsData.inject(isData ? 1 : 0);
        hPid.inject(pid);
        hPayLen.inject(payload.length);
        serve();
        hSend.inject(1);
        await clk.nextPosedge;
        hSend.inject(0);
        serve();
        // Wait for the host TX to finish driving the packet.
        var guard = 0;
        // Allow it to assert busy first.
        while (htx.output('busy').value.toInt() == 0 && guard < 50) {
          guard++;
          serve();
          await clk.nextPosedge;
        }
        guard = 0;
        while (htx.output('done').value.toInt() == 0 && guard < 4000) {
          guard++;
          serve();
          await clk.nextPosedge;
        }
        // Tail so the engine PhyRx sees the EOP and pkt_done.
        for (var i = 0; i < 30; i++) {
          await clk.nextPosedge;
        }
      }

      // Send a token (PID only, the engine ignores addr/CRC5 in B2b).
      Future<void> hostToken(int pid) => hostSend(pid: pid, isData: false);

      // Wait for and capture ONE device DATA packet on the host RX. Returns
      // {pid, bytes} where bytes excludes the 2 trailing CRC16 bytes.
      Future<Map<String, dynamic>> hostExpectData({int timeout = 6000}) async {
        var guard = 0;
        while (guard < timeout) {
          guard++;
          await clk.nextPosedge;
          if (hrx.output('pkt_done').value.toInt() == 1) {
            // Latch pid/count, then read the buffer.
            final pid = hrx.output('pid').value.toInt();
            final count = hrx.output('byte_count').value.toInt();
            final bytes = <int>[];
            for (var i = 0; i < count; i++) {
              hRdIndex.inject(i);
              await clk.nextPosedge;
              bytes.add(hrx.output('rd_byte').value.toInt());
            }
            hRdIndex.inject(0);
            // Drop the 2 CRC bytes if present.
            final payload = count >= 2 ? bytes.sublist(0, count - 2) : <int>[];
            return {'pid': pid, 'bytes': payload, 'raw': bytes};
          }
        }
        return {'pid': -1, 'bytes': <int>[], 'raw': <int>[]};
      }

      // Run a SETUP stage: SETUP token + DATA0(8 bytes), device should ACK.
      Future<Map<String, dynamic>> setupStage(List<int> bytes) async {
        await hostToken(pidSetup);
        await hostSend(pid: pidData0, isData: true, payload: bytes);
        // Capture the device ACK handshake.
        return hostExpectData();
      }

      // Return the DUT to a pristine, just-reset state without rebuilding.
      Future<void> resetDut() async {
        reset.inject(1);
        hSend.inject(0);
        hIsData.inject(0);
        hPid.inject(0);
        hPayLen.inject(0);
        hPayByte.inject(0);
        hRdIndex.inject(0);
        curPayload = const [];
        for (var i = 0; i < 8; i++) {
          await clk.nextPosedge;
        }
        reset.inject(0);
        for (var i = 0; i < 20; i++) {
          await clk.nextPosedge;
        }
      }

      // Advance the shared clock by [n] cycles (used where scenarios need to
      // wait for a post-status side effect to land).
      Future<void> settle(int n) async {
        for (var i = 0; i < n; i++) {
          await clk.nextPosedge;
        }
      }

      return {
        'eng': eng,
        'hostSend': hostSend,
        'hostToken': hostToken,
        'hostExpectData': hostExpectData,
        'setupStage': setupStage,
        'resetDut': resetDut,
        'settle': settle,
      };
    }

    test('enumeration + abort/restart + lost-ACK toggle + ZLP rules', () async {
      final h = await buildEnumHarness();
      final eng = h['eng'] as UsbEp0Engine;
      final hostSend =
          h['hostSend']
              as Future<void> Function({
                required int pid,
                required bool isData,
                List<int> payload,
              });
      final hostToken = h['hostToken'] as Future<void> Function(int);
      final hostExpectData =
          h['hostExpectData']
              as Future<Map<String, dynamic>> Function({int timeout});
      final setupStage =
          h['setupStage'] as Future<Map<String, dynamic>> Function(List<int>);
      final resetDut = h['resetDut'] as Future<void> Function();
      final settle = h['settle'] as Future<void> Function(int);

      // bmRequestType=0x80 (IN,std,device), bRequest=6, wValue=0x0100
      // (DEVICE,index0), wIndex=0, wLength=18.
      final setupDev = [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00];
      final ack0 = await setupStage(setupDev);
      expect(
        ack0['pid'],
        equals(pidAck),
        reason: 'device ACKs the GET_DESCRIPTOR(device) SETUP',
      );
      expect(
        eng.output('setup_valid').value.toInt(),
        equals(1),
        reason: 'setup captured',
      );
      // Confirm the captured setup bytes are visible for B3.
      for (var i = 0; i < 8; i++) {
        expect(
          eng.output('setup$i').value.toInt(),
          equals(setupDev[i]),
          reason: 'engine setup byte[$i]',
        );
      }

      // IN token -> device sends an 18-byte DATA1 chunk.
      await hostToken(pidIn);
      final dev = await hostExpectData();
      expect(
        dev['pid'],
        equals(pidData1),
        reason: 'first IN-data packet is DATA1',
      );
      final devBytes = dev['bytes'] as List<int>;
      expect(
        devBytes.length,
        equals(18),
        reason: 'device descriptor is 18 bytes (wLength)',
      );
      for (var i = 0; i < 18; i++) {
        expect(
          devBytes[i],
          equals(expectedDevice[i]),
          reason: 'device descriptor byte[$i]',
        );
      }
      // Host ACKs the data, device then expects OUT status.
      await hostSend(pid: pidAck, isData: false);
      // OUT status: OUT token + zero-length DATA1, device ACKs.
      await hostToken(pidOut);
      final st0 = await setupStatusOut(hostSend, hostExpectData, pidData1);
      expect(
        st0['pid'],
        equals(pidAck),
        reason: 'device ACKs the OUT status (device desc)',
      );

      // bmRequestType=0x00 (OUT,std,device), bRequest=5, wValue=7.
      expect(
        eng.output('dev_addr').value.toInt(),
        equals(0),
        reason: 'dev_addr still 0 before SET_ADDRESS',
      );
      final setupAddr = [0x00, 0x05, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00];
      final ackA = await setupStage(setupAddr);
      expect(
        ackA['pid'],
        equals(pidAck),
        reason: 'device ACKs the SET_ADDRESS SETUP',
      );
      // Address must NOT be applied yet (only after the IN status stage).
      expect(
        eng.output('dev_addr').value.toInt(),
        equals(0),
        reason: 'dev_addr still 0 during SET_ADDRESS status',
      );
      // IN status: IN token -> device sends zero-length DATA1, host ACKs.
      await hostToken(pidIn);
      final zlp = await hostExpectData();
      expect(zlp['pid'], equals(pidData1), reason: 'IN status is a DATA1 ZLP');
      expect(
        (zlp['bytes'] as List<int>).length,
        equals(0),
        reason: 'IN status ZLP carries no payload',
      );
      await hostSend(pid: pidAck, isData: false);
      // Address applied AFTER the status stage.
      await settle(10);
      expect(
        eng.output('dev_addr').value.toInt(),
        equals(7),
        reason: 'dev_addr == 7 after the SET_ADDRESS status stage',
      );

      // wValue=0x0200 (CONFIGURATION, index 0), wLength=36.
      final setupCfg = [0x80, 0x06, 0x00, 0x02, 0x00, 0x00, 0x24, 0x00];
      final ackC = await setupStage(setupCfg);
      expect(
        ackC['pid'],
        equals(pidAck),
        reason: 'device ACKs the GET_DESCRIPTOR(config) SETUP',
      );
      await hostToken(pidIn);
      final cfg = await hostExpectData();
      expect(
        cfg['pid'],
        equals(pidData1),
        reason: 'config IN-data first packet DATA1',
      );
      final cfgBytes = cfg['bytes'] as List<int>;
      expect(cfgBytes.length, equals(36), reason: 'config tree is 36 bytes');
      for (var i = 0; i < 36; i++) {
        expect(
          cfgBytes[i],
          equals(expectedConfig[i]),
          reason: 'config byte[$i]',
        );
      }
      await hostSend(pid: pidAck, isData: false);
      await hostToken(pidOut);
      final st1 = await setupStatusOut(hostSend, hostExpectData, pidData1);
      expect(
        st1['pid'],
        equals(pidAck),
        reason: 'device ACKs the OUT status (config desc)',
      );

      expect(
        eng.output('configured').value.toInt(),
        equals(0),
        reason: 'not configured before SET_CONFIGURATION',
      );
      final setupSetCfg = [0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
      final ackS = await setupStage(setupSetCfg);
      expect(
        ackS['pid'],
        equals(pidAck),
        reason: 'device ACKs the SET_CONFIGURATION SETUP',
      );
      await hostToken(pidIn);
      final zlp2 = await hostExpectData();
      expect(
        zlp2['pid'],
        equals(pidData1),
        reason: 'SET_CONFIGURATION IN status DATA1 ZLP',
      );
      await hostSend(pid: pidAck, isData: false);
      await settle(10);
      expect(
        eng.output('configured').value.toInt(),
        equals(1),
        reason: 'configured == 1 after SET_CONFIGURATION',
      );

      // SCENARIO 2: a SETUP token arriving mid-transfer must abort the
      // in-flight control transfer and start a fresh one. Before the global
      // SETUP-catch the engine only watched for SETUP in IDLE, so a new SETUP
      // in a data/status-wait state was dropped and EP0 wedged forever.
      //
      // Begin GET_DESCRIPTOR(device) and pull the first IN-data packet, then
      // WITHOUT finishing the transfer (no host ACK, no OUT status) send a
      // fresh SETUP for GET_DESCRIPTOR(config). The engine must service the
      // NEW request and return the 36-byte config descriptor.
      await resetDut();

      await hostToken(pidSetup);
      await hostSend(pid: pidData0, isData: true, payload: setupDev);
      final ack0b = await hostExpectData();
      expect(
        ack0b['pid'],
        equals(pidAck),
        reason: 'device ACKs the first SETUP',
      );

      await hostToken(pidIn);
      final devB = await hostExpectData();
      expect(
        devB['pid'],
        equals(pidData1),
        reason: 'device sends the device descriptor IN-data',
      );
      expect(
        (devB['bytes'] as List<int>).length,
        equals(18),
        reason: 'device descriptor is 18 bytes',
      );

      // WITHOUT finishing, start a NEW transfer with a fresh SETUP for CONFIG.
      await hostToken(pidSetup);
      await hostSend(pid: pidData0, isData: true, payload: setupCfg);
      final ackCb = await hostExpectData();
      expect(
        ackCb['pid'],
        equals(pidAck),
        reason: 'engine ACKs the mid-transfer SETUP (abort+restart)',
      );

      await hostToken(pidIn);
      final cfgB = await hostExpectData();
      expect(
        cfgB['pid'],
        equals(pidData1),
        reason: 'new transfer first IN-data is DATA1',
      );
      final cfgBytesB = cfgB['bytes'] as List<int>;
      expect(
        cfgBytesB.length,
        equals(36),
        reason:
            'engine returns the 36-byte config descriptor for the '
            'restarted transfer, proving abort/restart',
      );
      for (var i = 0; i < 36; i++) {
        expect(
          cfgBytesB[i],
          equals(expectedConfig[i]),
          reason: 'restarted-transfer config byte[$i]',
        );
      }

      // Lost ACK keeps the data toggle. After the device sends the
      // first IN-data chunk, the host does NOT ACK and instead re-INs, the
      // engine must resend the SAME chunk with the SAME data toggle (DATA1).
      await resetDut();

      await hostToken(pidSetup);
      await hostSend(pid: pidData0, isData: true, payload: setupDev);
      final ack0c = await hostExpectData();
      expect(ack0c['pid'], equals(pidAck), reason: 'device ACKs the SETUP');

      // First IN: device sends the 18-byte chunk as DATA1.
      await hostToken(pidIn);
      final first = await hostExpectData();
      expect(
        first['pid'],
        equals(pidData1),
        reason: 'first IN-data chunk is DATA1',
      );
      final firstBytes = first['bytes'] as List<int>;
      expect(firstBytes.length, equals(18));

      // The host's ACK is "lost": the first re-IN makes the engine treat the
      // missing ACK as a NAK and rewind to wait for a fresh IN token, the
      // second re-IN drives the actual resend. The resent chunk must carry the
      // SAME toggle (DATA1).
      await hostToken(pidIn); // consumed by wait-ack -> rewind to wait-token.
      await hostToken(pidIn); // drives the resend from wait-token.
      final retry = await hostExpectData();
      expect(
        retry['pid'],
        equals(pidData1),
        reason: 'resent chunk keeps the original DATA1 toggle, not DATA0',
      );
      final retryBytes = retry['bytes'] as List<int>;
      expect(
        retryBytes.length,
        equals(18),
        reason: 'resent chunk is the same 18-byte payload',
      );
      for (var i = 0; i < 18; i++) {
        expect(
          retryBytes[i],
          equals(firstBytes[i]),
          reason: 'resent chunk byte[$i] identical to the first attempt',
        );
      }

      // Now ACK for real, the transfer completes cleanly and accepts OUT status.
      await hostSend(pid: pidAck, isData: false);
      await hostToken(pidOut);
      final stC = await setupStatusOut(hostSend, hostExpectData, pidData1);
      expect(
        stC['pid'],
        equals(pidAck),
        reason: 'device ACKs the OUT status after the retried data stage',
      );

      // ZLP owed only on device-limited exact-multiple, not
      // host-capped. Uses the TEST-ONLY 64-byte STRING descriptor (index 6).
      //   Case A (device-limited): wLength=128 > respLen=64 -> 64-byte chunk
      //           THEN a terminating ZLP.
      //   Case B (host-capped):    wLength=64 == respLen=64 -> the 64-byte
      //           chunk and NO spurious ZLP.
      await resetDut();

      // Expected 64-byte STRING #6 descriptor (must match the module's table).
      final expected64 = _expectedString('River DFU 64-byte ZLP test desc');
      expect(
        expected64.length,
        equals(64),
        reason: 'sanity: the test descriptor is exactly 64 bytes',
      );

      final ackZA = await setupStage([
        0x80,
        0x06,
        0x06,
        0x03,
        0x00,
        0x00,
        0x80,
        0x00,
      ]);
      expect(ackZA['pid'], equals(pidAck), reason: 'device ACKs SETUP (A)');

      await hostToken(pidIn);
      final chunkA = await hostExpectData();
      expect(
        chunkA['pid'],
        equals(pidData1),
        reason: 'first IN-data chunk DATA1',
      );
      final aBytes = chunkA['bytes'] as List<int>;
      expect(aBytes.length, equals(64), reason: 'full 64-byte chunk');
      for (var i = 0; i < 64; i++) {
        expect(
          aBytes[i],
          equals(expected64[i]),
          reason: '64-byte descriptor byte[$i]',
        );
      }
      await hostSend(pid: pidAck, isData: false);

      // Device owes a terminating ZLP: next IN must yield a ZERO-length DATA0.
      await hostToken(pidIn);
      final zlpA = await hostExpectData();
      expect(
        zlpA['pid'],
        equals(pidData0),
        reason: 'ZLP toggles to DATA0 after the DATA1 chunk',
      );
      expect(
        (zlpA['bytes'] as List<int>).length,
        equals(0),
        reason: 'terminating ZLP carries no payload',
      );
      await hostSend(pid: pidAck, isData: false);

      // OUT status completes the transfer.
      await hostToken(pidOut);
      final stA = await setupStatusOut(hostSend, hostExpectData, pidData1);
      expect(
        stA['pid'],
        equals(pidAck),
        reason: 'device ACKs OUT status (device-limited case)',
      );

      final ackZB = await setupStage([
        0x80,
        0x06,
        0x06,
        0x03,
        0x00,
        0x00,
        0x40,
        0x00,
      ]);
      expect(ackZB['pid'], equals(pidAck), reason: 'device ACKs SETUP (B)');

      await hostToken(pidIn);
      final chunkB = await hostExpectData();
      expect(
        chunkB['pid'],
        equals(pidData1),
        reason: 'host-capped first chunk DATA1',
      );
      expect(
        (chunkB['bytes'] as List<int>).length,
        equals(64),
        reason: 'host-capped chunk is the full 64 bytes',
      );
      await hostSend(pid: pidAck, isData: false);

      // No ZLP: the device must accept the OUT status directly.
      await hostToken(pidOut);
      final stB = await setupStatusOut(hostSend, hostExpectData, pidData1);
      expect(
        stB['pid'],
        equals(pidAck),
        reason: 'host-capped transfer: device ACKs OUT status with no ZLP',
      );

      await Simulator.endSimulation();
    });
  });

  // B3: DFU class layer. A dfu-util-style host model drives the engine through
  // the real PHY and runs a DNLOAD sequence (download blocks + GETSTATUS polls
  // + a zero-length DNLOAD that finishes the image), then asserts the sink
  // stream reassembles the image, the DFU state transitions, the GETSTATUS
  // 6-byte response, and dnload_done / image_target.
  // DFU class bRequest codes.
  const dfuDnload = 1;
  const dfuGetStatus = 3;
  const dfuGetState = 5;
  const dfuClrStatus = 4;
  const dfuAbort = 6;
  // DFU bState values.
  const dfuIdle = 2;
  const dfuDnloadIdle = 5;

  group('UsbEp0Engine DFU class layer (host model)', () {
    // Builds the engine + host model, returns a bundle of helpers and the
    // captured sink stream. The sink is sampled on EVERY posedge so a
    // sink_valid pulse is never missed.
    Future<Map<String, dynamic>> buildDfuHarness(String tag) async {
      final eng = UsbEp0Engine(name: 'ep0_dfu_$tag');
      final htx = UsbPacketTx(name: 'htx_dfu_$tag');
      final hphyTx = HarborUsbFsPhyTx(name: 'hphytx_dfu_$tag');
      final hphyRx = HarborUsbFsPhyRx(name: 'hphyrx_dfu_$tag');
      final hrx = UsbPacketRx(name: 'hrx_dfu_$tag', bufBytes: 80);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final hSend = Logic(name: 'h_send');
      final hIsData = Logic(name: 'h_is_data');
      final hPid = Logic(name: 'h_pid', width: 8);
      final hPayLen = Logic(name: 'h_payload_len', width: 8);
      final hPayByte = Logic(name: 'h_payload_byte', width: 8);
      final hRdIndex = Logic(name: 'h_rd_index', width: 8);

      htx.input('clk').srcConnection! <= clk;
      htx.input('reset').srcConnection! <= reset;
      htx.input('send').srcConnection! <= hSend;
      htx.input('is_data').srcConnection! <= hIsData;
      htx.input('pid').srcConnection! <= hPid;
      htx.input('payload_len').srcConnection! <= hPayLen;
      htx.input('payload_byte').srcConnection! <= hPayByte;

      hphyTx.input('clk').srcConnection! <= clk;
      hphyTx.input('reset').srcConnection! <= reset;
      hphyTx.input('data').srcConnection! <= htx.output('tx_data');
      hphyTx.input('data_valid').srcConnection! <= htx.output('tx_data_valid');
      hphyTx.input('eop_req').srcConnection! <= htx.output('tx_eop_req');
      htx.input('tx_ready').srcConnection! <= hphyTx.output('ready');
      htx.input('tx_oe').srcConnection! <= hphyTx.output('oe');

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('dp').srcConnection! <= hphyTx.output('dp_out');
      eng.input('dm').srcConnection! <= hphyTx.output('dm_out');

      hphyRx.input('clk').srcConnection! <= clk;
      hphyRx.input('reset').srcConnection! <= reset;
      hphyRx.input('dp').srcConnection! <= eng.output('dp_out');
      hphyRx.input('dm').srcConnection! <= eng.output('dm_out');

      hrx.input('clk').srcConnection! <= clk;
      hrx.input('reset').srcConnection! <= reset;
      hrx.input('rx_data').srcConnection! <= hphyRx.output('data');
      hrx.input('rx_valid').srcConnection! <= hphyRx.output('valid');
      hrx.input('rx_sop').srcConnection! <= hphyRx.output('sop');
      hrx.input('rx_eop').srcConnection! <= hphyRx.output('eop');
      hrx.input('rd_index').srcConnection! <= hRdIndex;

      await eng.build();
      await htx.build();
      await hphyTx.build();
      await hphyRx.build();
      await hrx.build();

      reset.inject(1);
      hSend.inject(0);
      hIsData.inject(0);
      hPid.inject(0);
      hPayLen.inject(0);
      hPayByte.inject(0);
      hRdIndex.inject(0);
      Simulator.setMaxSimTime(200000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 20; i++) {
        await clk.nextPosedge;
      }

      // Captured DNLOAD sink stream (data + block) and dnload_done events.
      final sink = <Map<String, int>>[];
      var dnloadDoneCount = 0;
      var imageTargetAtDone = -1;

      // A single clock step that samples the sink on the way past. Used by all
      // the host helpers so no sink_valid pulse is missed.
      Future<void> tick() async {
        await clk.nextPosedge;
        if (eng.output('sink_valid').value.toInt() == 1) {
          sink.add({
            'data': eng.output('sink_data').value.toInt(),
            'block': eng.output('sink_block').value.toInt(),
          });
        }
        if (eng.output('dnload_done').value.toInt() == 1) {
          dnloadDoneCount++;
          imageTargetAtDone = eng.output('image_target').value.toInt();
        }
      }

      List<int> curPayload = const [];
      void serve() {
        if (curPayload.isEmpty) return;
        final i = htx.output('payload_index').value;
        final idx = i.isValid ? i.toInt() : 0;
        hPayByte.inject(idx < curPayload.length ? curPayload[idx] : 0);
      }

      Future<void> hostSend({
        required int pid,
        required bool isData,
        List<int> payload = const [],
      }) async {
        curPayload = payload;
        hIsData.inject(isData ? 1 : 0);
        hPid.inject(pid);
        hPayLen.inject(payload.length);
        serve();
        hSend.inject(1);
        await tick();
        hSend.inject(0);
        serve();
        var guard = 0;
        while (htx.output('busy').value.toInt() == 0 && guard < 50) {
          guard++;
          serve();
          await tick();
        }
        guard = 0;
        while (htx.output('done').value.toInt() == 0 && guard < 4000) {
          guard++;
          serve();
          await tick();
        }
        for (var i = 0; i < 30; i++) {
          await tick();
        }
      }

      Future<void> hostToken(int pid) => hostSend(pid: pid, isData: false);

      Future<Map<String, dynamic>> hostExpectData({int timeout = 6000}) async {
        var guard = 0;
        while (guard < timeout) {
          guard++;
          await tick();
          if (hrx.output('pkt_done').value.toInt() == 1) {
            final pid = hrx.output('pid').value.toInt();
            final count = hrx.output('byte_count').value.toInt();
            final bytes = <int>[];
            for (var i = 0; i < count; i++) {
              hRdIndex.inject(i);
              await tick();
              bytes.add(hrx.output('rd_byte').value.toInt());
            }
            hRdIndex.inject(0);
            final payload = count >= 2 ? bytes.sublist(0, count - 2) : <int>[];
            return {'pid': pid, 'bytes': payload, 'raw': bytes};
          }
        }
        return {'pid': -1, 'bytes': <int>[], 'raw': <int>[]};
      }

      // SETUP + 8-byte DATA0, capture the device ACK.
      Future<Map<String, dynamic>> setupStage(List<int> bytes) async {
        await hostToken(pidSetup);
        await hostSend(pid: pidData0, isData: true, payload: bytes);
        return hostExpectData();
      }

      // A DFU_DNLOAD block: SETUP(DNLOAD, wValue=block, wLength=payload.len),
      // OUT token + DATA1 payload, expect device ACK, then IN status ZLP.
      // Returns true if every handshake matched.
      Future<bool> dfuDnloadBlock(int block, List<int> payload) async {
        final setup = [
          0x21, // bmRequestType: OUT, class, interface
          dfuDnload,
          block & 0xFF, (block >> 8) & 0xFF, // wValue = wBlockNum
          0x00, 0x00, // wIndex = interface 0
          payload.length & 0xFF, (payload.length >> 8) & 0xFF, // wLength
        ];
        final ack = await setupStage(setup);
        if (ack['pid'] != pidAck) return false;
        // OUT data stage: OUT token + DATA1 carrying the payload.
        await hostToken(pidOut);
        await hostSend(pid: pidData1, isData: true, payload: payload);
        final dataAck = await hostExpectData();
        if (dataAck['pid'] != pidAck) return false;
        // IN status: device sends a ZLP DATA1, host ACKs.
        await hostToken(pidIn);
        final zlp = await hostExpectData();
        if (zlp['pid'] != pidData1) return false;
        if ((zlp['bytes'] as List<int>).isNotEmpty) return false;
        await hostSend(pid: pidAck, isData: false);
        for (var i = 0; i < 10; i++) {
          await tick();
        }
        return true;
      }

      // DFU_GETSTATUS: SETUP(GETSTATUS, wLength=6) + IN data (6 bytes) + ACK +
      // OUT status. Returns the 6 status bytes.
      Future<List<int>> dfuGetStatusReq() async {
        final setup = [
          0xA1, // bmRequestType: IN, class, interface
          dfuGetStatus,
          0x00, 0x00, // wValue
          0x00, 0x00, // wIndex
          0x06, 0x00, // wLength = 6
        ];
        final ack = await setupStage(setup);
        expect(ack['pid'], equals(pidAck), reason: 'GETSTATUS SETUP ACK');
        await hostToken(pidIn);
        final data = await hostExpectData();
        expect(
          data['pid'],
          equals(pidData1),
          reason: 'GETSTATUS IN-data is DATA1',
        );
        final bytes = (data['bytes'] as List<int>);
        await hostSend(pid: pidAck, isData: false);
        // OUT status (IN-data request takes an OUT status): host sends a
        // zero-length OUT DATA1 and the device ACKs.
        final st = await setupStatusOut(hostSend, hostExpectData, pidData1);
        expect(st['pid'], equals(pidAck), reason: 'GETSTATUS OUT status ACK');
        return bytes;
      }

      // DFU_GETSTATE: SETUP(GETSTATE, wLength=1) + IN data (1 byte). Returns it.
      Future<int> dfuGetStateReq() async {
        final setup = [0xA1, dfuGetState, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00];
        final ack = await setupStage(setup);
        expect(ack['pid'], equals(pidAck), reason: 'GETSTATE SETUP ACK');
        await hostToken(pidIn);
        final data = await hostExpectData();
        expect(data['pid'], equals(pidData1));
        final b = (data['bytes'] as List<int>);
        await hostSend(pid: pidAck, isData: false);
        await hostToken(pidOut);
        await hostSend(pid: pidData1, isData: true, payload: const []);
        await hostExpectData();
        return b.isNotEmpty ? b[0] : -1;
      }

      // A no-data DFU request (CLRSTATUS / ABORT): SETUP + IN status ZLP.
      Future<bool> dfuNoData(int bRequest) async {
        final setup = [0x21, bRequest, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
        final ack = await setupStage(setup);
        if (ack['pid'] != pidAck) return false;
        await hostToken(pidIn);
        final zlp = await hostExpectData();
        if (zlp['pid'] != pidData1) return false;
        await hostSend(pid: pidAck, isData: false);
        for (var i = 0; i < 10; i++) {
          await tick();
        }
        return true;
      }

      // A zero-length DFU_DNLOAD = end of image. SETUP(DNLOAD, wLength=0) + IN
      // status ZLP. dnload_done should pulse during this.
      Future<bool> dfuDnloadEnd() async {
        final setup = [0x21, dfuDnload, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
        final ack = await setupStage(setup);
        if (ack['pid'] != pidAck) return false;
        await hostToken(pidIn);
        final zlp = await hostExpectData();
        if (zlp['pid'] != pidData1) return false;
        await hostSend(pid: pidAck, isData: false);
        for (var i = 0; i < 10; i++) {
          await tick();
        }
        return true;
      }

      // SET_INTERFACE(alt): standard no-data request.
      Future<void> setInterface(int alt) async {
        final setup = [0x01, 0x0B, alt & 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00];
        final ack = await setupStage(setup);
        expect(ack['pid'], equals(pidAck), reason: 'SET_INTERFACE ACK');
        await hostToken(pidIn);
        final zlp = await hostExpectData();
        expect(zlp['pid'], equals(pidData1));
        await hostSend(pid: pidAck, isData: false);
        for (var i = 0; i < 10; i++) {
          await tick();
        }
      }

      // Restore the harness to a pristine, just-reset state WITHOUT rebuilding
      // any modules. Pulsing the engine's reset port clears every engine
      // register (DFU state -> dfuIDLE, address/config/alt, all IN/OUT-data
      // bookkeeping), and we clear the captured sink stream + dnload_done
      // counters so each scenario starts clean. This lets all DFU scenarios
      // share ONE built harness: ROHD pins every wire's pre-tick listener onto
      // the live Simulator across Simulator.reset(), so rebuilding the harness
      // per test makes each later test's per-tick fan-out grow without bound
      // (an O(total-wires-ever) slowdown that eventually reads as a hang).
      // Reusing one harness keeps the armed-wire set constant and the per-tick
      // cost flat.
      Future<void> resetDut() async {
        reset.inject(1);
        hSend.inject(0);
        hIsData.inject(0);
        hPid.inject(0);
        hPayLen.inject(0);
        hPayByte.inject(0);
        hRdIndex.inject(0);
        for (var i = 0; i < 8; i++) {
          await clk.nextPosedge;
        }
        reset.inject(0);
        for (var i = 0; i < 20; i++) {
          await clk.nextPosedge;
        }
        sink.clear();
        dnloadDoneCount = 0;
        imageTargetAtDone = -1;
      }

      return {
        'eng': eng,
        'sink': sink,
        'dnloadDoneCount': () => dnloadDoneCount,
        'imageTargetAtDone': () => imageTargetAtDone,
        'dfuDnloadBlock': dfuDnloadBlock,
        'dfuGetStatusReq': dfuGetStatusReq,
        'dfuGetStateReq': dfuGetStateReq,
        'dfuNoData': dfuNoData,
        'dfuDnloadEnd': dfuDnloadEnd,
        'setInterface': setInterface,
        'resetDut': resetDut,
      };
    }

    // All three DFU scenarios share ONE built harness and reset the DUT (via
    // its reset port) between them. They were three separate `test`s, each
    // rebuilding the full engine+host PHY stack. In a single-isolate run ROHD
    // pins every wire's pre-tick listener onto the live Simulator across
    // `Simulator.reset()`, so each successive rebuild made every later sim
    // tick fan out to all wires from all prior tests: an unbounded
    // per-tick slowdown that made the GETSTATUS scenario (running late in the
    // file) appear to hang. Reusing one harness keeps the armed-wire set
    // constant, so per-tick cost stays flat and this test completes fast on its
    // own. It is tagged slow because the engine+PHY harnesses built by the
    // earlier groups in this file stay pinned to the live Simulator across
    // Simulator.reset() (a ROHD limitation), so when this test runs late in a
    // full-file pass every tick fans out across all of them and the many DFU
    // transactions here push it past the per-test budget, run it in isolation.
    test('DFU class requests over one shared harness', tags: 'slow', () async {
      final h = await buildDfuHarness('dfu_shared');
      final eng = h['eng'] as UsbEp0Engine;
      final sink = h['sink'] as List<Map<String, int>>;
      final dnloadBlock =
          h['dfuDnloadBlock'] as Future<bool> Function(int, List<int>);
      final getStatus = h['dfuGetStatusReq'] as Future<List<int>> Function();
      final getState = h['dfuGetStateReq'] as Future<int> Function();
      final dnloadEnd = h['dfuDnloadEnd'] as Future<bool> Function();
      final setInterface = h['setInterface'] as Future<void> Function(int);
      final noData = h['dfuNoData'] as Future<bool> Function(int);
      final dnloadDoneCount = h['dnloadDoneCount'] as int Function();
      final imageTargetAtDone = h['imageTargetAtDone'] as int Function();
      final resetDut = h['resetDut'] as Future<void> Function();

      // Scenario 1: GETSTATUS reports the 6-byte status block when idle.
      expect(
        eng.output('dfu_state').value.toInt(),
        equals(dfuIdle),
        reason: 'DFU starts in dfuIDLE',
      );
      final status = await getStatus();
      expect(status.length, equals(6), reason: 'GETSTATUS returns 6 bytes');
      expect(status[0], equals(0), reason: 'bStatus = OK (0)');
      expect(status[1], equals(0), reason: 'bwPollTimeout LE byte 0');
      expect(status[2], equals(0), reason: 'bwPollTimeout LE byte 1');
      expect(status[3], equals(0), reason: 'bwPollTimeout LE byte 2');
      expect(status[4], equals(dfuIdle), reason: 'bState = dfuIDLE');
      expect(status[5], equals(0), reason: 'iString = 0');

      // Scenario 2: DNLOAD sequence: blocks stream to the sink, GETSTATUS
      // tracks state, zero-length DNLOAD finishes the image (image_target=RAM).
      await resetDut();

      // Select alt 0 (RAM) so image_target latches 0 at the end.
      await setInterface(0);
      expect(eng.output('alt_setting').value.toInt(), equals(0));
      expect(eng.output('dfu_state').value.toInt(), equals(dfuIdle));

      // The image: 3 blocks of a few bytes each.
      final blocks = <List<int>>[
        [0x11, 0x22, 0x33, 0x44],
        [0x55, 0x66],
        [0x77, 0x88, 0x99, 0xAA, 0xBB],
      ];
      final fullImage = <int>[for (final b in blocks) ...b];

      for (var n = 0; n < blocks.length; n++) {
        final ok = await dnloadBlock(n, blocks[n]);
        expect(ok, isTrue, reason: 'DNLOAD block $n handshakes (ACK + status)');
        // After a block the engine is in dfuDNLOAD_IDLE.
        expect(
          eng.output('dfu_state').value.toInt(),
          equals(dfuDnloadIdle),
          reason: 'block $n -> dfuDNLOAD_IDLE',
        );

        // GETSTATUS between blocks reflects dfuDNLOAD_IDLE.
        final blockStatus = await getStatus();
        expect(blockStatus[0], equals(0), reason: 'block $n bStatus OK');
        expect(
          blockStatus[4],
          equals(dfuDnloadIdle),
          reason: 'block $n GETSTATUS bState = dfuDNLOAD_IDLE',
        );
        // GETSTATE agrees.
        final state = await getState();
        expect(
          state,
          equals(dfuDnloadIdle),
          reason: 'block $n GETSTATE = dfuDNLOAD_IDLE',
        );
      }

      // Final zero-length DNLOAD: dnload_done pulses, image_target = RAM (0).
      final endOk = await dnloadEnd();
      expect(endOk, isTrue, reason: 'zero-length DNLOAD handshakes');
      expect(
        dnloadDoneCount(),
        equals(1),
        reason: 'dnload_done pulsed exactly once',
      );
      expect(
        imageTargetAtDone(),
        equals(0),
        reason: 'image_target latched = alt 0 (RAM)',
      );
      expect(
        eng.output('dfu_state').value.toInt(),
        equals(dfuIdle),
        reason: 'after the zero-length DNLOAD -> dfuIDLE',
      );

      // The sink-captured stream must reassemble the full image, in order, and
      // each byte must be tagged with its block number.
      expect(
        sink.length,
        equals(fullImage.length),
        reason: 'every payload byte streamed to the sink exactly once',
      );
      final reassembled = [for (final s in sink) s['data']!];
      expect(
        reassembled,
        equals(fullImage),
        reason: 'sink stream reassembles the sent image in order',
      );
      // Per-byte block tags.
      var idx = 0;
      for (var n = 0; n < blocks.length; n++) {
        for (var b = 0; b < blocks[n].length; b++) {
          expect(
            sink[idx]['block'],
            equals(n),
            reason: 'sink byte $idx tagged with block $n',
          );
          idx++;
        }
      }

      // Scenario 3: CLRSTATUS and ABORT both return DFU to dfuIDLE.
      await resetDut();

      // Push a block to leave dfuDNLOAD_IDLE, then ABORT back to idle.
      expect(await dnloadBlock(0, [0xDE, 0xAD]), isTrue);
      expect(eng.output('dfu_state').value.toInt(), equals(dfuDnloadIdle));
      expect(await noData(dfuAbort), isTrue, reason: 'ABORT handshakes');
      expect(
        eng.output('dfu_state').value.toInt(),
        equals(dfuIdle),
        reason: 'ABORT -> dfuIDLE',
      );

      // Another block, then CLRSTATUS back to idle.
      expect(await dnloadBlock(1, [0xBE, 0xEF, 0x01]), isTrue);
      expect(eng.output('dfu_state').value.toInt(), equals(dfuDnloadIdle));
      expect(
        await noData(dfuClrStatus),
        isTrue,
        reason: 'CLRSTATUS handshakes',
      );
      expect(
        eng.output('dfu_state').value.toInt(),
        equals(dfuIdle),
        reason: 'CLRSTATUS -> dfuIDLE',
      );

      // Scenario 4: full 64-byte DNLOAD block (buffer boundary test).
      // This is the regression guard for the silent-data-corruption bug where
      // pktRx was sized at 16 bytes (bufBytes=16), so bytes 15..63 of a
      // 64-byte payload were silently dropped and streamed as zeros. The
      // engine now uses bufBytes = dfuTransferSize + 2 = 66, so all 64
      // payload bytes must survive.
      await resetDut();

      // A 64-byte payload: bytes [0, 1, 2, ..., 63].
      final fullBlock = List<int>.generate(64, (i) => i);
      final blockOk = await dnloadBlock(0, fullBlock);
      expect(
        blockOk,
        isTrue,
        reason: 'full 64-byte DNLOAD block handshakes (ACK + status)',
      );
      expect(
        eng.output('dfu_state').value.toInt(),
        equals(dfuDnloadIdle),
        reason: 'after 64-byte block -> dfuDNLOAD_IDLE',
      );
      // The sink stream must contain all 64 bytes in order, none replaced by
      // zeros. With the old bufBytes=16 only bytes 0..13 would be correct,
      // bytes 14..63 would all be zero.
      expect(
        sink.length,
        equals(64),
        reason: 'all 64 payload bytes streamed to sink',
      );
      for (var i = 0; i < 64; i++) {
        expect(
          sink[i]['data'],
          equals(i),
          reason: 'sink byte[$i] = $i (not zero-filled by undersized buffer)',
        );
      }

      await Simulator.endSimulation();
    });
  });

  // EP1 bulk OUT transfer framing.
  //
  // cmd_start must mark the start of a bulk TRANSFER, not the start of a
  // packet. A command frame that is longer than wMaxPacketSize (64) arrives as
  // more than one packet, and the transfer only ends on a packet that is
  // shorter than 64 bytes (a zero-length packet when the length divides by 64).
  // A consumer resets its command parse state on cmd_start, so a pulse on every
  // packet chops the frame at each packet boundary: the bytes still arrive on
  // cmd_data, but the consumer throws away everything before the last packet.
  // This is the hardware failure that was seen on the sibling endpoint (writes
  // broke the moment they were longer than one packet, with no error).
  group('UsbEp0Engine EP1 bulk OUT framing (host model)', () {
    test('a 3-packet command frame gives ONE cmd_start and every byte in '
        'order, and a new command after a short packet pulses again', () async {
      // The engine's EP1 wMaxPacketSize (UsbEp0Engine._maxPacket).
      const maxPacket = 64;

      final eng = UsbEp0Engine(name: 'ep1_eng', bulkEndpoints: true);
      final htx = UsbPacketTx(name: 'bulk_host_ptx');
      final hphyTx = HarborUsbFsPhyTx(name: 'bulk_host_phytx');
      final hphyRx = HarborUsbFsPhyRx(name: 'bulk_host_phyrx');
      final hrx = UsbPacketRx(name: 'bulk_host_prx', bufBytes: 80);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final hSend = Logic(name: 'h_send');
      final hIsData = Logic(name: 'h_is_data');
      final hPid = Logic(name: 'h_pid', width: 8);
      final hPayLen = Logic(name: 'h_payload_len', width: 8);
      final hPayByte = Logic(name: 'h_payload_byte', width: 8);
      final hRdIndex = Logic(name: 'h_rd_index', width: 8);

      htx.input('clk').srcConnection! <= clk;
      htx.input('reset').srcConnection! <= reset;
      htx.input('send').srcConnection! <= hSend;
      htx.input('is_data').srcConnection! <= hIsData;
      htx.input('pid').srcConnection! <= hPid;
      htx.input('payload_len').srcConnection! <= hPayLen;
      htx.input('payload_byte').srcConnection! <= hPayByte;

      hphyTx.input('clk').srcConnection! <= clk;
      hphyTx.input('reset').srcConnection! <= reset;
      hphyTx.input('data').srcConnection! <= htx.output('tx_data');
      hphyTx.input('data_valid').srcConnection! <= htx.output('tx_data_valid');
      hphyTx.input('eop_req').srcConnection! <= htx.output('tx_eop_req');
      htx.input('tx_ready').srcConnection! <= hphyTx.output('ready');
      htx.input('tx_oe').srcConnection! <= hphyTx.output('oe');

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('dp').srcConnection! <= hphyTx.output('dp_out');
      eng.input('dm').srcConnection! <= hphyTx.output('dm_out');

      // Command sink: always ready, so the OUT drain runs at one byte per
      // cycle. No response is ever offered, so the engine NAKs any IN token
      // and the OUT recovery cooldown never arms.
      eng.input('cmd_ready').srcConnection! <= Const(1);
      eng.input('resp_data').srcConnection! <= Const(0, width: 8);
      eng.input('resp_valid').srcConnection! <= Const(0);
      eng.input('resp_last').srcConnection! <= Const(0);

      hphyRx.input('clk').srcConnection! <= clk;
      hphyRx.input('reset').srcConnection! <= reset;
      hphyRx.input('dp').srcConnection! <= eng.output('dp_out');
      hphyRx.input('dm').srcConnection! <= eng.output('dm_out');

      hrx.input('clk').srcConnection! <= clk;
      hrx.input('reset').srcConnection! <= reset;
      hrx.input('rx_data').srcConnection! <= hphyRx.output('data');
      hrx.input('rx_valid').srcConnection! <= hphyRx.output('valid');
      hrx.input('rx_sop').srcConnection! <= hphyRx.output('sop');
      hrx.input('rx_eop').srcConnection! <= hphyRx.output('eop');
      hrx.input('rd_index').srcConnection! <= hRdIndex;

      await eng.build();
      await htx.build();
      await hphyTx.build();
      await hphyRx.build();
      await hrx.build();

      reset.inject(1);
      hSend.inject(0);
      hIsData.inject(0);
      hPid.inject(0);
      hPayLen.inject(0);
      hPayByte.inject(0);
      hRdIndex.inject(0);
      Simulator.setMaxSimTime(160000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 20; i++) {
        await clk.nextPosedge;
      }

      int engOut(String port) {
        final v = eng.output(port).value;
        return v.isValid ? v.toInt() : 0;
      }

      // Downstream consumer model. It appends every accepted cmd byte to the
      // frame it is parsing and DROPS that frame on cmd_start, which is what a
      // command engine does when it is told a new command has started. So the
      // frame that is left at the end is what the consumer really sees.
      final frame = <int>[];
      var startPulses = 0;
      var monitorOn = true;
      unawaited(() async {
        while (monitorOn) {
          // Sample at the negedge: registered and combinational outputs are
          // both settled in the middle of the cycle.
          await clk.nextNegedge;
          if (engOut('cmd_start') == 1) {
            startPulses++;
            frame.clear();
          }
          if (engOut('cmd_valid') == 1) {
            frame.add(engOut('cmd_data'));
          }
        }
      }());

      // Current host send payload (served combinationally by payload_index).
      List<int> curPayload = const [];
      void serve() {
        if (curPayload.isEmpty) return;
        final i = htx.output('payload_index').value;
        final idx = i.isValid ? i.toInt() : 0;
        hPayByte.inject(idx < curPayload.length ? curPayload[idx] : 0);
      }

      Future<void> hostSend({
        required int pid,
        required bool isData,
        List<int> payload = const [],
      }) async {
        curPayload = payload;
        hIsData.inject(isData ? 1 : 0);
        hPid.inject(pid);
        hPayLen.inject(payload.length);
        serve();
        hSend.inject(1);
        await clk.nextPosedge;
        hSend.inject(0);
        serve();
        var guard = 0;
        while (htx.output('busy').value.toInt() == 0 && guard < 50) {
          guard++;
          serve();
          await clk.nextPosedge;
        }
        guard = 0;
        while (htx.output('done').value.toInt() == 0 && guard < 8000) {
          guard++;
          serve();
          await clk.nextPosedge;
        }
        for (var i = 0; i < 30; i++) {
          await clk.nextPosedge;
        }
      }

      // Wait for one device packet on the host RX and return its PID.
      Future<int> hostExpectPid({int timeout = 8000}) async {
        var guard = 0;
        while (guard < timeout) {
          guard++;
          await clk.nextPosedge;
          if (hrx.output('pkt_done').value.toInt() == 1) {
            return hrx.output('pid').value.toInt();
          }
        }
        return -1;
      }

      // Send one EP1 bulk OUT packet: the OUT token, then the DATA packet, then
      // wait for the device ACK and let the drain finish.
      //
      // The token carries its 2 address/endpoint bytes, so it goes out through
      // the DATA path of the host TX (the handshake path sends the PID only).
      // Byte 0 is addr[6:0] | endp[0]<<7 = 0x80, which selects EP1. The engine
      // does not check a token CRC, so the trailing CRC16 is harmless.
      Future<int> ep1OutPacket(List<int> payload, {required bool data1}) async {
        await hostSend(pid: pidOut, isData: true, payload: const [0x80, 0x00]);
        await hostSend(
          pid: data1 ? pidData1 : pidData0,
          isData: true,
          payload: payload,
        );
        final ack = await hostExpectPid();
        // The drain runs at one byte per cycle once the ACK is sent.
        for (var i = 0; i < payload.length + 40; i++) {
          await clk.nextPosedge;
        }
        return ack;
      }

      try {
        // ----------------------------------------------------------------
        // Phase 1: one command frame of 144 bytes = 64 + 64 + 16. Three
        // packets covers the first, a middle and the last packet of a
        // transfer.
        // ----------------------------------------------------------------
        final cmd1 = [for (var i = 0; i < 144; i++) (i + 1) & 0xFF];
        expect(
          await ep1OutPacket(cmd1.sublist(0, maxPacket), data1: false),
          equals(pidAck),
          reason: 'packet 1 of 3 (full size) is ACKed',
        );
        expect(
          await ep1OutPacket(
            cmd1.sublist(maxPacket, 2 * maxPacket),
            data1: true,
          ),
          equals(pidAck),
          reason: 'packet 2 of 3 (full size) is ACKed',
        );
        expect(
          await ep1OutPacket(cmd1.sublist(2 * maxPacket), data1: false),
          equals(pidAck),
          reason: 'packet 3 of 3 (short, ends the transfer) is ACKed',
        );

        expect(
          frame,
          equals(cmd1),
          reason:
              'the consumer sees the whole 144-byte command frame in order. '
              'A pulse on each packet makes it drop everything before the '
              'last packet, which is the silent data loss seen on hardware',
        );
        expect(
          startPulses,
          equals(1),
          reason:
              'cmd_start marks the start of a TRANSFER: the two packets that '
              'follow a full-size packet continue the same command and must '
              'not pulse',
        );

        // ----------------------------------------------------------------
        // Phase 2: the transfer above ended on a short packet, so the next
        // packet is a genuinely NEW command and must pulse cmd_start. This is
        // the preempt path: a new command always wins over a stale response.
        // ----------------------------------------------------------------
        final cmd2 = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7];
        expect(
          await ep1OutPacket(cmd2, data1: true),
          equals(pidAck),
          reason: 'the new command packet is ACKed',
        );
        expect(
          startPulses,
          equals(2),
          reason:
              'a packet after a short packet starts a new command, so it '
              'pulses cmd_start',
        );
        expect(
          frame,
          equals(cmd2),
          reason: 'the new command replaces the frame before it',
        );
      } finally {
        monitorOn = false;
        await Simulator.endSimulation();
      }
    });
  });

  // B4: UsbDfuRamSink: DMA the DFU firmware-byte sink stream into RAM over a
  // Wishbone MASTER bus, crossing 48 MHz USB -> 12 MHz bus via a CDC FIFO.
  group('UsbDfuRamSink (Wishbone master + CDC)', () {
    test('streams an image into RAM byte-exact, raises image_ready, '
        'and stays idle for a flash target', () async {
      const loadBase = 0x80000000;
      const busDataWidth = 32;
      const busAddrWidth = 32;
      const bytesPerWord = busDataWidth ~/ 8;

      final sink = UsbDfuRamSink(
        name: 'ram_sink',
        loadBase: loadBase,
        busAddressWidth: busAddrWidth,
        busDataWidth: busDataWidth,
        fifoDepth: 64,
      );

      // Behavioral Wishbone slave RAM (consumer role): on a write cycle it
      // stores each selected byte lane into a Dart-visible word array and acks
      // for one cycle. Built as a tiny BridgeModule so the two interfaces can
      // be wired with connectInterfaces, mirroring the test_harness pattern.
      final slave = _BehavioralWbSlaveRam(
        addressWidth: busAddrWidth,
        dataWidth: busDataWidth,
        loadBase: loadBase,
        words: 32,
      );

      // Top wrapper: two clocks (usb 10ns, bus 40ns => 4:1), stream inputs
      // pulled up, master<->slave connected.
      final top = _RamSinkTop(sink: sink, slave: slave);
      final usbClk = SimpleClockGenerator(10).clk;
      final busClk = SimpleClockGenerator(40).clk;

      top.port('usb_clk').getsLogic(usbClk);
      top.port('bus_clk').getsLogic(busClk);

      await top.build();

      final usbReset = top.input('usb_reset');
      final busReset = top.input('bus_reset');
      final sinkData = top.input('sink_data');
      final sinkValid = top.input('sink_valid');
      final dnloadDone = top.input('dnload_done');
      final imageTarget = top.input('image_target');
      final altSetting = top.input('alt_setting');

      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());

      // Drive a deterministic image: a known prefix + a ramp, 22 bytes total
      // (5.5 words => a partial final word exercising the sel mask).
      final image = <int>[
        0xDE, 0xAD, 0xBE, 0xEF, // word 0
        0x01, 0x02, 0x03, 0x04, // word 1
        0x10, 0x20, 0x30, 0x40, // word 2
        0xA5, 0x5A, 0xC3, 0x3C, // word 3
        0x11, 0x22, 0x33, 0x44, // word 4
        0x77, 0x88, // word 5 (partial: 2 bytes)
      ];
      expect(image.length, equals(22));

      // Hold both resets across several bus-clock posedges, then release.
      usbReset.inject(1);
      busReset.inject(1);
      sinkData.inject(0);
      sinkValid.inject(0);
      dnloadDone.inject(0);
      imageTarget.inject(
        0,
      ); // RAM (observability only, gating is on alt_setting)
      altSetting.inject(0); // RAM interface selected for the whole transfer
      for (var i = 0; i < 5; i++) {
        await busClk.nextPosedge;
      }
      usbReset.put(0);
      busReset.put(0);
      await busClk.nextPosedge;

      // Drive the sink stream in the USB domain: one sink_valid pulse per byte,
      // spaced a couple of usb cycles apart like the real engine streams.
      for (final b in image) {
        await usbClk.nextPosedge;
        sinkData.put(b);
        sinkValid.put(1);
        await usbClk.nextPosedge;
        sinkValid.put(0);
        sinkData.put(0);
        await usbClk.nextPosedge;
      }
      // Then the zero-length DNLOAD completion marker.
      await usbClk.nextPosedge;
      dnloadDone.put(1);
      await usbClk.nextPosedge;
      dnloadDone.put(0);

      // Wait for image_ready (bus domain). Generous bound: CDC + per-byte
      // single writes at 4:1.
      var readySeen = false;
      for (var i = 0; i < 2000; i++) {
        await busClk.nextPosedge;
        if (top.output('image_ready').value.isValid &&
            top.output('image_ready').value.toInt() == 1) {
          readySeen = true;
          break;
        }
      }
      expect(readySeen, isTrue, reason: 'image_ready pulsed after the image');

      // Let a couple more cycles settle.
      await busClk.nextPosedge;
      await busClk.nextPosedge;

      // entry_addr == loadBase.
      expect(
        top.output('entry_addr').value.toInt(),
        equals(loadBase),
        reason: 'entry_addr holds loadBase',
      );
      // bytes_written == image length.
      expect(
        top.output('bytes_written').value.toInt(),
        equals(image.length),
        reason: 'bytes_written counts every byte',
      );

      // Read back the slave RAM byte-exact, including the partial final word.
      for (var i = 0; i < image.length; i++) {
        final word = slave.wordAt(i ~/ bytesPerWord);
        final lane = i % bytesPerWord;
        final got = (word >> (lane * 8)) & 0xFF;
        expect(
          got,
          equals(image[i]),
          reason: 'RAM byte[$i] (word ${i ~/ bytesPerWord} lane $lane)',
        );
      }
      // The unwritten lanes of the partial final word were never selected, so
      // they must remain at the slave's reset value (0).
      final lastWord = slave.wordAt((image.length - 1) ~/ bytesPerWord);
      expect(
        (lastWord >> (2 * 8)) & 0xFF,
        equals(0),
        reason: 'partial-final-word lane 2 untouched',
      );
      expect(
        (lastWord >> (3 * 8)) & 0xFF,
        equals(0),
        reason: 'partial-final-word lane 3 untouched',
      );

      await Simulator.endSimulation();
    });

    // B1 regression: a slow Wishbone slave drains the FIFO far slower than the
    // engine streams (64 bytes in 64 USB cycles vs ~1 byte per many bus cycles),
    // so without back-pressure the small FIFO overflows and bytes are dropped /
    // the done marker is lost (a corrupt image and a hung DMA). With the
    // sink_ready handshake the producer self-paces and NO byte is dropped.
    //
    // Two phases over the SAME built harness (one module build):
    //   Phase A: honor sink_ready -> byte-exact, image_ready fires, overflow 0.
    //   Phase B (old-code-fails proof): IGNORE sink_ready (force the producer to
    //            stream regardless, == the old unstoppable engine) -> the sticky
    //            overflow flag MUST latch, proving a drop would have happened.
    test('slow-ack slave: sink_ready back-pressure prevents FIFO overflow / '
        'dropped firmware bytes', () async {
      const loadBase = 0x80000000;
      const busDataWidth = 32;
      const busAddrWidth = 32;
      const bytesPerWord = busDataWidth ~/ 8;

      // Deliberately SHALLOW FIFO so a 64-byte block cannot fit, forcing the
      // overflow condition the back-pressure must defuse.
      final sink = UsbDfuRamSink(
        name: 'ram_sink_slow',
        loadBase: loadBase,
        busAddressWidth: busAddrWidth,
        busDataWidth: busDataWidth,
        fifoDepth: 8,
      );
      // Slow slave: each write acks only after a long wait, so the bus side
      // drains ~1 byte per dozen-plus bus cycles.
      final slave = _BehavioralWbSlaveRam(
        addressWidth: busAddrWidth,
        dataWidth: busDataWidth,
        loadBase: loadBase,
        words: 32,
        ackDelay: 12,
      );
      final top = _RamSinkTop(sink: sink, slave: slave);

      final usbClk = SimpleClockGenerator(10).clk;
      final busClk = SimpleClockGenerator(40).clk;
      top.port('usb_clk').getsLogic(usbClk);
      top.port('bus_clk').getsLogic(busClk);

      await top.build();

      final usbReset = top.input('usb_reset');
      final busReset = top.input('bus_reset');
      final sinkData = top.input('sink_data');
      final sinkValid = top.input('sink_valid');
      final dnloadDone = top.input('dnload_done');
      final imageTarget = top.input('image_target');
      final altSetting = top.input('alt_setting');

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      // A full 64-byte block: bytes [0..63].
      final image = List<int>.generate(64, (i) => i);

      Future<void> doReset() async {
        usbReset.inject(1);
        busReset.inject(1);
        sinkData.inject(0);
        sinkValid.inject(0);
        dnloadDone.inject(0);
        imageTarget.inject(0);
        altSetting.inject(0); // RAM
        for (var i = 0; i < 5; i++) {
          await busClk.nextPosedge;
        }
        usbReset.put(0);
        busReset.put(0);
        await busClk.nextPosedge;
        await usbClk.nextPosedge;
      }

      // Stream the block one byte at a time on the USB clock. When [honorReady]
      // is true (the real, fixed behaviour) we wait for sink_ready before each
      // push and HOLD while it is low: self-pacing. When false we model the old
      // unstoppable engine and push regardless.
      Future<void> streamBlock({required bool honorReady}) async {
        for (final b in image) {
          if (honorReady) {
            var guard = 0;
            while (top.output('sink_ready').value.toInt() == 0 &&
                guard < 100000) {
              guard++;
              await usbClk.nextPosedge;
            }
          }
          sinkData.put(b);
          sinkValid.put(1);
          await usbClk.nextPosedge;
          sinkValid.put(0);
          sinkData.put(0);
          await usbClk.nextPosedge;
        }
        // The done marker, also paced behind sink_ready when honoring it.
        if (honorReady) {
          var guard = 0;
          while (top.output('sink_ready').value.toInt() == 0 &&
              guard < 100000) {
            guard++;
            await usbClk.nextPosedge;
          }
        }
        dnloadDone.put(1);
        await usbClk.nextPosedge;
        dnloadDone.put(0);
      }

      // Phase A: honor back-pressure -> byte-exact, no drop.
      await doReset();
      await streamBlock(honorReady: true);

      var readySeen = false;
      for (var i = 0; i < 20000; i++) {
        await busClk.nextPosedge;
        if (top.output('image_ready').value.isValid &&
            top.output('image_ready').value.toInt() == 1) {
          readySeen = true;
          break;
        }
      }
      expect(
        readySeen,
        isTrue,
        reason: 'image_ready fires - the done marker survived (no hang)',
      );
      expect(
        top.output('overflow').value.toInt(),
        equals(0),
        reason: 'back-pressure kept the FIFO from ever overflowing',
      );
      expect(
        top.output('bytes_written').value.toInt(),
        equals(image.length),
        reason: 'every one of the 64 bytes was written',
      );
      // Byte-exact read-back of the whole block.
      for (var i = 0; i < image.length; i++) {
        final word = slave.wordAt(i ~/ bytesPerWord);
        final lane = i % bytesPerWord;
        final got = (word >> (lane * 8)) & 0xFF;
        expect(
          got,
          equals(image[i]),
          reason: 'RAM byte[$i] exact (no FIFO drop under slow ack)',
        );
      }

      // Phase B: old-code proof -> ignore ready, overflow latches.
      // This reproduces the pre-fix engine (sink_valid unstoppable). The sticky
      // overflow flag MUST fire, demonstrating that without the handshake a byte
      // would have been silently dropped. (Run after a fresh reset so the FIFO
      // and overflow latch start clean.)
      await doReset();
      expect(
        top.output('overflow').value.toInt(),
        equals(0),
        reason: 'overflow clears on reset',
      );
      await streamBlock(honorReady: false);
      // Give the bus side time to keep draining, overflow is sticky so once set
      // it stays set.
      var overflowSeen = false;
      for (var i = 0; i < 200; i++) {
        await usbClk.nextPosedge;
        if (top.output('overflow').value.toInt() == 1) {
          overflowSeen = true;
          break;
        }
      }
      expect(
        overflowSeen,
        isTrue,
        reason:
            'ignoring sink_ready (the OLD unstoppable engine) overflows '
            'the FIFO and the sticky overflow flag catches the drop - this '
            'is the bug the back-pressure handshake fixes',
      );

      await Simulator.endSimulation();
    });

    // B2 regression: a FLASH download (alt 1) must NOT write RAM, modelled the
    // way the REAL engine drives the sink. The engine only latches image_target
    // at dnload_done, during the whole streaming phase image_target holds its
    // reset value 0 (RAM). The stable target is alt_setting, which is 1 for the
    // flash interface from the SET_INTERFACE before the download. So we drive
    // alt_setting = 1 while image_target reads 0 during streaming: exactly what
    // the engine does. Gating on alt_setting (the fix) keeps RAM idle, the OLD
    // image_target-gating logic would push every byte into RAM and FAIL this.
    test('flash download (alt_setting==1, image_target==0 mid-stream) '
        'writes nothing to RAM', () async {
      const loadBase = 0x80000000;
      final sink = UsbDfuRamSink(
        name: 'ram_sink_flash',
        loadBase: loadBase,
        busAddressWidth: 32,
        busDataWidth: 32,
      );
      final slave = _BehavioralWbSlaveRam(
        addressWidth: 32,
        dataWidth: 32,
        loadBase: loadBase,
        words: 16,
      );
      final top = _RamSinkTop(sink: sink, slave: slave);

      final usbClk = SimpleClockGenerator(10).clk;
      final busClk = SimpleClockGenerator(40).clk;
      top.port('usb_clk').getsLogic(usbClk);
      top.port('bus_clk').getsLogic(busClk);

      await top.build();
      slave.watchAcks(busClk);

      final usbReset = top.input('usb_reset');
      final busReset = top.input('bus_reset');
      final sinkData = top.input('sink_data');
      final sinkValid = top.input('sink_valid');
      final dnloadDone = top.input('dnload_done');
      final imageTarget = top.input('image_target');
      final altSetting = top.input('alt_setting');

      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());

      usbReset.inject(1);
      busReset.inject(1);
      sinkData.inject(0);
      sinkValid.inject(0);
      dnloadDone.inject(0);
      // THE TRUTHFUL ENGINE MODEL: during streaming image_target is still 0
      // (RAM), it has NOT been latched yet, while alt_setting is the stable
      // flash selection (1). The old gate (image_target==0) would wrongly admit
      // every byte, the new gate (alt_setting==0) correctly rejects them.
      imageTarget.inject(0);
      altSetting.inject(1); // FLASH interface -> sink must stay idle
      for (var i = 0; i < 5; i++) {
        await busClk.nextPosedge;
      }
      usbReset.put(0);
      busReset.put(0);
      await busClk.nextPosedge;

      // Drive a stream + done, with a flash target nothing should be pushed and
      // the master must never assert cyc.
      for (final b in [0x11, 0x22, 0x33, 0x44, 0x55]) {
        await usbClk.nextPosedge;
        sinkData.put(b);
        sinkValid.put(1);
        await usbClk.nextPosedge;
        sinkValid.put(0);
        await usbClk.nextPosedge;
      }
      // At dnload_done the engine WOULD latch image_target = alt_setting = 1,
      // model that too. Gating is on alt_setting, so the done marker is also
      // rejected and image_ready never fires.
      await usbClk.nextPosedge;
      imageTarget.put(1);
      dnloadDone.put(1);
      await usbClk.nextPosedge;
      dnloadDone.put(0);

      // Watch for any bus write or image_ready over a healthy window.
      for (var i = 0; i < 200; i++) {
        await busClk.nextPosedge;
        expect(
          slave.writeCount,
          equals(0),
          reason: 'no RAM write for a flash target',
        );
        expect(
          top.output('image_ready').value.toInt(),
          equals(0),
          reason: 'no image_ready for a flash target',
        );
        expect(
          top.output('bytes_written').value.toInt(),
          equals(0),
          reason: 'master never asserts cyc (bytes_written stays 0)',
        );
      }
      // overflow must never set in any healthy flow.
      expect(
        top.output('overflow').value.toInt(),
        equals(0),
        reason: 'no overflow on an idle flash sink',
      );

      await Simulator.endSimulation();
    });
  });

  // B5b: UsbDfuFlashSink: program the DFU firmware-byte sink stream into SPI
  // flash by driving the B5a write/erase engine on a REAL
  // HarborSpiFlashController, against a behavioral standard-mode SPI NOR model.

  // Reads the full descriptor from the ROM for a given (type, index): walks
  // offset 0..length-1 and returns the assembled bytes plus present/length.
  Future<Map<String, dynamic>> readDescriptor(int type, int index) async {
    final dut = UsbDescriptorRom(
      name:
          'rom_${type}_${index}_'
          '${DateTime.now().microsecondsSinceEpoch & 0xFFFFFF}',
    );
    final descType = Logic(name: 'desc_type', width: 8);
    final descIndex = Logic(name: 'desc_index', width: 8);
    final offset = Logic(name: 'offset', width: 8);

    dut.input('desc_type').srcConnection! <= descType;
    dut.input('desc_index').srcConnection! <= descIndex;
    dut.input('offset').srcConnection! <= offset;

    await dut.build();

    final clk = SimpleClockGenerator(10).clk;
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());

    descType.inject(type);
    descIndex.inject(index);
    offset.inject(0);
    await clk.nextPosedge;

    final present = dut.output('present').value.toInt();
    final length = dut.output('length').value.toInt();

    final bytes = <int>[];
    for (var o = 0; o < length; o++) {
      offset.inject(o);
      await clk.nextPosedge;
      bytes.add(dut.output('data').value.toInt());
    }
    // Also read one byte past the end to confirm out-of-range reads as 0.
    offset.inject(length);
    await clk.nextPosedge;
    final pastEnd = dut.output('data').value.toInt();

    await Simulator.endSimulation();

    return {
      'present': present,
      'length': length,
      'bytes': bytes,
      'pastEnd': pastEnd,
    };
  }

  group('UsbDescriptorRom', () {
    test('module is purely combinational (no clk/reset port)', () async {
      final dut = UsbDescriptorRom(name: 'rom_comb');
      // A pure-combinational ROM exposes only the data ports.
      expect(dut.tryInput('clk'), isNull, reason: 'no clk port');
      expect(dut.tryInput('reset'), isNull, reason: 'no reset port');
      expect(dut.tryInput('desc_type'), isNotNull);
      expect(dut.tryInput('desc_index'), isNotNull);
      expect(dut.tryInput('offset'), isNotNull);
    });

    test('DEVICE descriptor: present, length 18, byte-for-byte', () async {
      final r = await readDescriptor(0x01, 0);
      expect(r['present'], equals(1), reason: 'device descriptor present');
      expect(r['length'], equals(18), reason: 'device length 18');
      expect(
        expectedDevice.length,
        equals(18),
        reason: 'sanity: re-derived device is 18 bytes',
      );
      final bytes = r['bytes'] as List<int>;
      for (var i = 0; i < 18; i++) {
        expect(bytes[i], equals(expectedDevice[i]), reason: 'device byte[$i]');
      }
      expect(r['pastEnd'], equals(0), reason: 'out-of-range data is 0');

      // Explicit VID/PID LE field checks at their device-descriptor offsets.
      expect(bytes[7], equals(64), reason: 'bMaxPacketSize0 at offset 7');
      // idVendor at offsets 8..9 = 0x1209 LE => 0x09, 0x12.
      expect(bytes[8], equals(0x09), reason: 'idVendor LE low');
      expect(bytes[9], equals(0x12), reason: 'idVendor LE high');
      expect(
        bytes[8] | (bytes[9] << 8),
        equals(0x1209),
        reason: 'VID 0x1209 LE',
      );
      // idProduct at offsets 10..11 = 0x5BF1 LE => 0xF1, 0x5B.
      expect(bytes[10], equals(0xF1), reason: 'idProduct LE low');
      expect(bytes[11], equals(0x5B), reason: 'idProduct LE high');
      expect(
        bytes[10] | (bytes[11] << 8),
        equals(0x5BF1),
        reason: 'PID 0x5BF1 LE',
      );
    });

    test(
      'CONFIGURATION descriptor: length 36, key offsets, sub-lengths sum',
      () async {
        final r = await readDescriptor(0x02, 0);
        expect(r['present'], equals(1), reason: 'config present');
        expect(r['length'], equals(36), reason: 'config length 36');
        final bytes = r['bytes'] as List<int>;
        expect(bytes.length, equals(36));

        // Full byte-for-byte against the independent re-derivation.
        for (var i = 0; i < 36; i++) {
          expect(
            bytes[i],
            equals(expectedConfig[i]),
            reason: 'config byte[$i]',
          );
        }

        // Config header.
        expect(bytes[0], equals(9), reason: 'config header bLength 9');
        expect(bytes[1], equals(0x02), reason: 'config descriptor type');
        expect(
          bytes[2] | (bytes[3] << 8),
          equals(36),
          reason: 'wTotalLength 36 (LE)',
        );

        // Interface alt0 begins at offset 9.
        expect(bytes[9 + 1], equals(0x04), reason: 'alt0 INTERFACE type');
        expect(bytes[9 + 3], equals(0), reason: 'alt0 bAlternateSetting 0');
        expect(bytes[9 + 5], equals(0xFE), reason: 'alt0 bInterfaceClass 0xFE');
        expect(
          bytes[9 + 6],
          equals(0x01),
          reason: 'alt0 bInterfaceSubClass 0x01',
        );
        expect(
          bytes[9 + 7],
          equals(0x02),
          reason: 'alt0 bInterfaceProtocol 0x02',
        );

        // Interface alt1 begins at offset 18.
        expect(bytes[18 + 1], equals(0x04), reason: 'alt1 INTERFACE type');
        expect(bytes[18 + 3], equals(1), reason: 'alt1 bAlternateSetting 1');

        // DFU functional descriptor begins at offset 27.
        expect(bytes[27 + 0], equals(9), reason: 'DFU func bLength 9');
        expect(
          bytes[27 + 1],
          equals(0x21),
          reason: 'DFU functional descriptor type 0x21',
        );
        expect(bytes[27 + 2], equals(0x05), reason: 'DFU bmAttributes 0x05');
        // wTransferSize at DFU offset 5..6 = 64 (LE).
        expect(
          bytes[27 + 5] | (bytes[27 + 6] << 8),
          equals(64),
          reason: 'DFU wTransferSize 64 (LE)',
        );

        // The three sub-descriptors (after the 9-byte header) plus header sum.
        expect(
          expectedConfigHeader.length +
              expectedIfaceAlt0.length +
              expectedIfaceAlt1.length +
              expectedDfuFunctional.length,
          equals(36),
          reason: 'header(9)+alt0(9)+alt1(9)+dfu(9) = 36',
        );
      },
    );

    test('STRING 0 (LANGID): length 4, bytes [4,3,0x09,0x04]', () async {
      final r = await readDescriptor(0x03, 0);
      expect(r['present'], equals(1));
      expect(r['length'], equals(4));
      expect(
        r['bytes'],
        equals([4, 0x03, 0x09, 0x04]),
        reason: 'LANGID descriptor bytes',
      );
      expect(r['bytes'], equals(expectedStr0));
    });

    test('STRING 1 (Manufacturer "River"): length 12, UTF-16LE', () async {
      final r = await readDescriptor(0x03, 1);
      expect(r['present'], equals(1));
      expect(r['length'], equals(12), reason: '2 + 2*5 = 12');
      final bytes = r['bytes'] as List<int>;
      expect(bytes, equals(_expectedString('River')));
      expect(bytes[0], equals(12), reason: 'bLength');
      expect(bytes[1], equals(0x03), reason: 'STRING type');
      // "River" UTF-16LE: R(0x52),0, i(0x69),0, v(0x76),0, ...
      expect(bytes[2], equals(0x52), reason: "'R' low byte");
      expect(bytes[3], equals(0x00), reason: "'R' high byte");
      expect(bytes[4], equals(0x69), reason: "'i' low byte");
      expect(bytes[5], equals(0x00), reason: "'i' high byte");
    });

    test('STRING 2 (Product "River DFU"): length 20', () async {
      final r = await readDescriptor(0x03, 2);
      expect(r['present'], equals(1));
      expect(r['length'], equals(20), reason: '2 + 2*9 = 20');
      expect(r['bytes'], equals(_expectedString('River DFU')));
    });

    test('STRING 4 (Interface alt0 "RAM"): length 8', () async {
      final r = await readDescriptor(0x03, 4);
      expect(r['present'], equals(1));
      expect(r['length'], equals(8), reason: '2 + 2*3 = 8');
      expect(r['bytes'], equals(_expectedString('RAM')));
    });

    test('STRING 5 (Interface alt1 "SPI flash"): length 20', () async {
      final r = await readDescriptor(0x03, 5);
      expect(r['present'], equals(1));
      expect(r['length'], equals(20), reason: '2 + 2*9 = 20');
      expect(r['bytes'], equals(_expectedString('SPI flash')));
    });

    test('STRING 3 not present', () async {
      final r = await readDescriptor(0x03, 3);
      expect(r['present'], equals(0), reason: 'string index 3 absent');
      expect(r['length'], equals(0), reason: 'absent length 0');
    });

    test('unknown descriptor type (0x05): not present', () async {
      final r = await readDescriptor(0x05, 0);
      expect(r['present'], equals(0));
      expect(r['length'], equals(0));
      expect(r['pastEnd'], equals(0), reason: 'data 0 for unknown');
    });

    test('out-of-range offset reads 0 for a known descriptor', () async {
      final dut = UsbDescriptorRom(name: 'rom_oob');
      final descType = Logic(name: 'desc_type', width: 8);
      final descIndex = Logic(name: 'desc_index', width: 8);
      final offset = Logic(name: 'offset', width: 8);
      dut.input('desc_type').srcConnection! <= descType;
      dut.input('desc_index').srcConnection! <= descIndex;
      dut.input('offset').srcConnection! <= offset;
      await dut.build();

      final clk = SimpleClockGenerator(10).clk;
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());

      descType.inject(0x01); // DEVICE
      descIndex.inject(0);
      offset.inject(18); // exactly one past the last valid byte
      await clk.nextPosedge;
      expect(
        dut.output('data').value.toInt(),
        equals(0),
        reason: 'offset == length reads 0',
      );
      offset.inject(200);
      await clk.nextPosedge;
      expect(
        dut.output('data').value.toInt(),
        equals(0),
        reason: 'far out-of-range reads 0',
      );

      await Simulator.endSimulation();
    });
  });

  // B2a: UsbPacketTx + UsbPacketRx, proven by a full round-trip through the
  // real PHY: UsbPacketTx -> HarborUsbFsPhyTx -> (dp/dm) -> HarborUsbFsPhyRx
  // -> UsbPacketRx.
  group('UsbPacketTx + UsbPacketRx round-trip', () {
    // Drives one packet end-to-end. `payload` is empty for a handshake.
    Future<Map<String, dynamic>> roundTrip({
      required int pid,
      required bool isData,
      List<int> payload = const [],
    }) async {
      final tag = '${pid}_${isData}_${payload.hashCode & 0xFFFF}';
      final ptx = UsbPacketTx(name: 'ptx_$tag');
      final phyTx = HarborUsbFsPhyTx(name: 'phytx_$tag');
      final phyRx = HarborUsbFsPhyRx(name: 'phyrx_$tag');
      final prx = UsbPacketRx(name: 'prx_$tag');

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final send = Logic(name: 'send');
      final isDataL = Logic(name: 'is_data');
      final pidL = Logic(name: 'pid', width: 8);
      final payLen = Logic(name: 'payload_len', width: 8);
      final payByte = Logic(name: 'payload_byte', width: 8);
      final rdIndex = Logic(name: 'rd_index', width: 8);

      // UsbPacketTx command + payload-source wiring.
      ptx.input('clk').srcConnection! <= clk;
      ptx.input('reset').srcConnection! <= reset;
      ptx.input('send').srcConnection! <= send;
      ptx.input('is_data').srcConnection! <= isDataL;
      ptx.input('pid').srcConnection! <= pidL;
      ptx.input('payload_len').srcConnection! <= payLen;
      ptx.input('payload_byte').srcConnection! <= payByte;

      // UsbPacketTx <-> PhyTx host handshake.
      phyTx.input('clk').srcConnection! <= clk;
      phyTx.input('reset').srcConnection! <= reset;
      phyTx.input('data').srcConnection! <= ptx.output('tx_data');
      phyTx.input('data_valid').srcConnection! <= ptx.output('tx_data_valid');
      phyTx.input('eop_req').srcConnection! <= ptx.output('tx_eop_req');
      ptx.input('tx_ready').srcConnection! <= phyTx.output('ready');
      ptx.input('tx_oe').srcConnection! <= phyTx.output('oe');

      // PhyTx line -> PhyRx line.
      phyRx.input('clk').srcConnection! <= clk;
      phyRx.input('reset').srcConnection! <= reset;
      phyRx.input('dp').srcConnection! <= phyTx.output('dp_out');
      phyRx.input('dm').srcConnection! <= phyTx.output('dm_out');

      // PhyRx framing -> UsbPacketRx.
      prx.input('clk').srcConnection! <= clk;
      prx.input('reset').srcConnection! <= reset;
      prx.input('rx_data').srcConnection! <= phyRx.output('data');
      prx.input('rx_valid').srcConnection! <= phyRx.output('valid');
      prx.input('rx_sop').srcConnection! <= phyRx.output('sop');
      prx.input('rx_eop').srcConnection! <= phyRx.output('eop');
      prx.input('rd_index').srcConnection! <= rdIndex;

      await ptx.build();
      await phyTx.build();
      await phyRx.build();
      await prx.build();

      reset.inject(1);
      send.inject(0);
      isDataL.inject(isData ? 1 : 0);
      pidL.inject(pid);
      payLen.inject(payload.length);
      payByte.inject(0);
      rdIndex.inject(0);
      Simulator.setMaxSimTime(8000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      // Let the line idle at J so the Rx DLL/destuff settle.
      for (var i = 0; i < 16; i++) {
        await clk.nextPosedge;
      }

      // Keep payload_byte combinationally tracking the requested payload_index.
      void servePayload() {
        if (payload.isEmpty) return;
        final i = ptx.output('payload_index').value;
        final idx = i.isValid ? i.toInt() : 0;
        payByte.inject(idx < payload.length ? payload[idx] : 0);
      }

      servePayload();

      // Strobe send for one cycle.
      send.inject(1);
      await clk.nextPosedge;
      send.inject(0);
      servePayload();

      var pktDoneSeen = 0;
      var guard = 0;
      var drain = -1;
      while (guard < 8000) {
        guard++;
        servePayload();
        await clk.nextPosedge;
        servePayload();
        if (prx.output('pkt_done').value.toInt() == 1) pktDoneSeen++;
        // Once UsbPacketTx reports done, drain a tail so pkt_done lands.
        if (ptx.output('done').value.toInt() == 1 && drain < 0) {
          drain = 80;
        }
        if (drain > 0) {
          drain--;
        } else if (drain == 0) {
          break;
        }
      }

      final pidRx = prx.output('pid').value.toInt();
      final byteCount = prx.output('byte_count').value.toInt();

      // Read back the received payload buffer (byte_count bytes).
      final rxBytes = <int>[];
      for (var i = 0; i < byteCount; i++) {
        rdIndex.inject(i);
        await clk.nextPosedge;
        rxBytes.add(prx.output('rd_byte').value.toInt());
      }

      await Simulator.endSimulation();

      return {
        'pid': pidRx,
        'byteCount': byteCount,
        'rxBytes': rxBytes,
        'pktDoneSeen': pktDoneSeen,
      };
    }

    test(
      'DATA0 packet (SETUP-like 8-byte payload) round-trips with CRC16',
      () async {
        const payload = [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00];
        final crc = _crc16(payload);
        final r = await roundTrip(pid: 0xC3, isData: true, payload: payload);

        expect(
          r['pktDoneSeen'],
          greaterThanOrEqualTo(1),
          reason: 'pkt_done pulsed',
        );
        expect(r['pid'], equals(0xC3), reason: 'DATA0 PID received');
        expect(r['byteCount'], equals(10), reason: '8 payload + 2 CRC bytes');
        final rx = r['rxBytes'] as List<int>;
        // First 8 bytes equal the payload.
        for (var i = 0; i < 8; i++) {
          expect(rx[i], equals(payload[i]), reason: 'payload byte[$i]');
        }
        // The 2 CRC bytes the hardware computed equal the test-computed CRC16.
        expect(rx[8], equals(crc & 0xFF), reason: 'CRC16 low byte');
        expect(rx[9], equals((crc >> 8) & 0xFF), reason: 'CRC16 high byte');
      },
    );

    test(
      'DATA0 packet with a 0xFF byte exercises bit-stuffing through the PHY',
      () async {
        const payload = [0xFF, 0x00, 0xFF, 0x55];
        final crc = _crc16(payload);
        final r = await roundTrip(pid: 0xC3, isData: true, payload: payload);

        expect(r['pid'], equals(0xC3), reason: 'DATA0 PID');
        expect(r['byteCount'], equals(6), reason: '4 payload + 2 CRC');
        final rx = r['rxBytes'] as List<int>;
        for (var i = 0; i < 4; i++) {
          expect(
            rx[i],
            equals(payload[i]),
            reason: 'stuffed payload byte[$i] survives',
          );
        }
        expect(rx[4], equals(crc & 0xFF), reason: 'CRC16 low (stuffed case)');
        expect(
          rx[5],
          equals((crc >> 8) & 0xFF),
          reason: 'CRC16 high (stuffed case)',
        );
      },
    );

    test('handshake ACK packet (no payload, no CRC) round-trips', () async {
      final r = await roundTrip(pid: 0xD2, isData: false);
      expect(
        r['pktDoneSeen'],
        greaterThanOrEqualTo(1),
        reason: 'pkt_done pulsed',
      );
      expect(r['pid'], equals(0xD2), reason: 'ACK PID received');
      expect(
        r['byteCount'],
        equals(0),
        reason: 'handshake has no payload bytes',
      );
    });
  });
}

// Helper for the OUT status stage: host sends a zero-length DATA packet (the
// OUT token was already sent) and captures the device ACK.
Future<Map<String, dynamic>> setupStatusOut(
  Future<void> Function({
    required int pid,
    required bool isData,
    List<int> payload,
  })
  hostSend,
  Future<Map<String, dynamic>> Function({int timeout}) hostExpectData,
  int dataPid,
) async {
  await hostSend(pid: dataPid, isData: true, payload: const []);
  return hostExpectData();
}

// B4 test support: a behavioral Wishbone slave RAM and a two-clock top wrapper
// that wires a UsbDfuRamSink master to it.

/// A minimal behavioral Wishbone B4 slave RAM (consumer role) for the B4 test.
///
/// On a write cycle (cyc & stb & we) it stores each SELECTED byte lane of
/// dat_mosi into a word array at index `(adr - loadBase) / bytesPerWord` and
/// acks for one cycle. Reads are unsupported (DFU only writes). The word array
/// is exposed to Dart via [wordAt] for byte-exact read-back.
class _BehavioralWbSlaveRam extends BridgeModule {
  final int addressWidth;
  final int dataWidth;
  final int loadBase;
  final int words;

  /// Extra wait cycles inserted before each write is acked. 0 = the original
  /// fast slave (ack the cycle after the request). A larger value models a slow
  /// memory whose ack lags the request by [ackDelay] cycles, so the USB-side
  /// producer must wait far longer than it streams: the B1 overflow scenario.
  final int ackDelay;
  int get bytesPerWord => dataWidth ~/ 8;

  late final List<Logic> _mem;
  Logic get _busAck => output('dbg_ack');

  /// Number of acked writes observed (for the flash-idle assertion).
  int writeCount = 0;

  /// The current stored value of RAM word [i].
  int wordAt(int i) => _mem[i].value.isValid ? _mem[i].value.toInt() : 0;

  _BehavioralWbSlaveRam({
    required this.addressWidth,
    required this.dataWidth,
    required this.loadBase,
    required this.words,
    this.ackDelay = 0,
  }) : super('_BehavioralWbSlaveRam', name: 'wb_slave_ram') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final ref = addInterface(
      WishboneInterface(
        WishboneConfig(addressWidth: addressWidth, dataWidth: dataWidth),
      ),
      name: 'bus',
      role: PairRole.consumer, // slave
    );
    final bus = ref.internalInterface!;

    final clk = input('clk');
    final reset = input('reset');
    final selWidth = dataWidth ~/ 8;
    var wordShift = 0;
    for (var v = bytesPerWord; v > 1; v >>= 1) {
      wordShift++;
    }

    _mem = [
      for (var i = 0; i < words; i++) Logic(name: 'mem_$i', width: dataWidth),
    ];

    final wrEn = bus.cyc & bus.stb & bus.we;
    // Word index = (adr - loadBase) >> wordShift.
    final byteIdx = (bus.adr - Const(loadBase, width: addressWidth));
    final wordIdx =
        (bytesPerWord == 1
                ? byteIdx
                : byteIdx
                      .slice(addressWidth - 1, wordShift)
                      .zeroExtend(addressWidth))
            .named('word_idx');

    // ack: single-cycle, registered on the write request.
    final ackReg = Logic(name: 'ack_reg');
    addOutput('dbg_ack');
    output('dbg_ack') <= ackReg;

    // Slow-ack wait counter (only used when ackDelay > 0): counts active-cycle
    // cycles before the ack is allowed to fire.
    final waitW = ackDelay < 2 ? 1 : (ackDelay + 1).bitLength;
    final waitCnt = Logic(name: 'wait_cnt', width: waitW);

    // Per-lane masked write: new byte iff sel[lane], otherwise keep.
    Logic mergedFor(Logic cur) {
      var out = cur;
      for (var lane = 0; lane < selWidth; lane++) {
        final lo = lane * 8;
        final newByte = bus.datMosi.slice(lo + 7, lo);
        final keepByte = cur.slice(lo + 7, lo);
        final laneByte = mux(
          bus.sel.slice(lane, lane).eq(Const(1)),
          newByte,
          keepByte,
        );
        out = (lane == 0)
            ? laneByte
            : [laneByte, out.slice(lo - 1, 0)].swizzle();
      }
      return out;
    }

    // True the cycle the write is actually accepted (and acked).
    final accept = ackDelay == 0
        ? (wrEn & ~ackReg)
        : (wrEn & ~ackReg & waitCnt.eq(Const(ackDelay, width: waitW)));

    Sequential(clk, [
      If(
        reset,
        then: [
          ackReg < Const(0),
          waitCnt < Const(0, width: waitW),
          for (final w in _mem) w < Const(0, width: dataWidth),
        ],
        orElse: [
          // ack pulses for exactly one cycle per accepted write request.
          ackReg < accept,
          // Wait-counter bookkeeping for the slow slave: count up while a write
          // request is pending and not yet acked, reset once accepted or idle.
          If(
            ackDelay == 0 ? Const(0) : (wrEn & ~ackReg & ~accept),
            then: [waitCnt < waitCnt + 1],
            orElse: [waitCnt < Const(0, width: waitW)],
          ),
          If(
            accept,
            then: [
              for (var i = 0; i < words; i++)
                If(
                  wordIdx.eq(Const(i, width: addressWidth)),
                  then: [_mem[i] < mergedFor(_mem[i])],
                ),
            ],
          ),
        ],
      ),
    ]);

    bus.ack <= ackReg;
    bus.datMiso <= Const(0, width: dataWidth);
  }

  /// Hook the simulator so [writeCount] tracks acked writes from Dart.
  void watchAcks(Logic busClk) {
    _busAck.changed.listen((_) {
      if (_busAck.value.isValid && _busAck.value.toInt() == 1) {
        writeCount++;
      }
    });
  }
}

/// Two-clock top wrapper: a [UsbDfuRamSink] master connected to a behavioral
/// Wishbone slave RAM, with the USB-domain stream inputs and the sink's
/// observability outputs pulled to the top.
class _RamSinkTop extends BridgeModule {
  final UsbDfuRamSink sink;
  final _BehavioralWbSlaveRam slave;

  _RamSinkTop({required this.sink, required this.slave})
    : super('_RamSinkTop', name: 'ram_sink_top') {
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);
    createPort('sink_data', PortDirection.input, width: 8);
    createPort('sink_valid', PortDirection.input);
    createPort('dnload_done', PortDirection.input);
    createPort('image_target', PortDirection.input, width: 8);
    createPort('alt_setting', PortDirection.input, width: 8);

    addSubModule(sink);
    addSubModule(slave);

    connectPorts(port('usb_clk'), sink.port('usb_clk'));
    connectPorts(port('usb_reset'), sink.port('usb_reset'));
    connectPorts(port('bus_clk'), sink.port('bus_clk'));
    connectPorts(port('bus_reset'), sink.port('bus_reset'));
    connectPorts(port('sink_data'), sink.port('sink_data'));
    connectPorts(port('sink_valid'), sink.port('sink_valid'));
    connectPorts(port('dnload_done'), sink.port('dnload_done'));
    connectPorts(port('image_target'), sink.port('image_target'));
    connectPorts(port('alt_setting'), sink.port('alt_setting'));

    connectPorts(port('bus_clk'), slave.port('clk'));
    connectPorts(port('bus_reset'), slave.port('reset'));

    connectInterfaces(sink.interface('bus'), slave.interface('bus'));

    addOutput('image_ready') <= sink.output('image_ready');
    addOutput('entry_addr', width: sink.busAddressWidth) <=
        sink.output('entry_addr');
    addOutput('bytes_written', width: 32) <= sink.output('bytes_written');
    addOutput('sink_ready') <= sink.output('sink_ready');
    addOutput('overflow') <= sink.output('overflow');
  }
}

/// Behavioral standard-mode SPI NOR flash model (ported from
/// spi_flash_write_test.dart) for the B5b UsbDfuFlashSink test. A clocked-by-the-
/// testbench SPI slave that decodes WREN/erase-4KB/page-program/RDSR, models WIP
/// busy after erase/program, requires WREN, and AND-merges programmed bytes.
///
/// [stuckWip]: when true the WIP busy flag NEVER clears, so the controller's
/// RDSR poll hits its watchdog and raises wr_err: exercising the error path.
class _SpiNorModel {
  final storage = <int, int>{};
  bool wel = false;
  int wipCounter = 0;
  int rdsrCount = 0;
  final bool stuckWip;

  int curByte = 0;
  int bitsInByte = 0;
  final cmdBytes = <int>[];
  int cmd = 0;
  int addr = 0;
  bool servingStatus = false;
  int statusByte = 0;

  _SpiNorModel({this.stuckWip = false});

  int read(int a) => storage[a] ?? 0xFF;

  void csRise() {
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
      if (d >= 0 && d < 8) {
        return (statusByte >> (7 - d)) & 1;
      }
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
        final wip = wipCounter > 0 ? 1 : 0;
        // A stuck part never clears WIP, a healthy one decrements toward 0.
        if (wipCounter > 0 && !stuckWip) wipCounter--;
        rdsrCount++;
        statusByte = (wip) | (wel ? 2 : 0);
        servingStatus = true;
      }
      return;
    }
    if (cmd == 0x20 || cmd == 0x02) {
      if (cmdBytes.length >= 2 && cmdBytes.length <= 4) {
        addr = (addr << 8) | b;
        if (cmd == 0x20 && cmdBytes.length == 4) {
          _erase(addr);
        }
        return;
      }
      if (cmd == 0x02 && cmdBytes.length > 4) {
        final dataIdx = cmdBytes.length - 5;
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
    wipCounter = stuckWip ? 0x7FFFFFFF : 3;
  }

  void _program(int a, int b) {
    if (!wel) return;
    final existing = storage[a] ?? 0xFF;
    storage[a] = existing & b;
    wipCounter = stuckWip ? 0x7FFFFFFF : 3;
  }
}

/// Two-clock top wrapper for the B5b test: a [UsbDfuFlashSink] driving a real
/// [HarborSpiFlashController]'s write/erase command interface, with the USB-
/// domain stream inputs, the SPI pins, and the sink's observability outputs
/// pulled to the top.
class _FlashSinkTop extends BridgeModule {
  final UsbDfuFlashSink sink;
  final HarborSpiFlashController flash;

  _FlashSinkTop({required this.sink, required this.flash})
    : super('_FlashSinkTop', name: 'flash_sink_top') {
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);
    createPort('sink_data', PortDirection.input, width: 8);
    createPort('sink_valid', PortDirection.input);
    createPort('dnload_done', PortDirection.input);
    createPort('alt_setting', PortDirection.input, width: 8);
    createPort('spi_miso', PortDirection.input);

    addSubModule(sink);
    addSubModule(flash);

    // Clocks / resets.
    connectPorts(port('usb_clk'), sink.port('usb_clk'));
    connectPorts(port('usb_reset'), sink.port('usb_reset'));
    connectPorts(port('bus_clk'), sink.port('bus_clk'));
    connectPorts(port('bus_reset'), sink.port('bus_reset'));
    // The flash controller runs in the bus domain.
    connectPorts(port('bus_clk'), flash.port('clk'));
    connectPorts(port('bus_reset'), flash.port('reset'));

    // USB-domain stream inputs into the sink.
    connectPorts(port('sink_data'), sink.port('sink_data'));
    connectPorts(port('sink_valid'), sink.port('sink_valid'));
    connectPorts(port('dnload_done'), sink.port('dnload_done'));
    connectPorts(port('alt_setting'), sink.port('alt_setting'));

    // The sink drives the flash controller's write-engine command interface.
    connectPorts(sink.port('wr_req'), flash.port('wr_req'));
    connectPorts(sink.port('wr_op'), flash.port('wr_op'));
    connectPorts(sink.port('wr_addr'), flash.port('wr_addr'));
    connectPorts(sink.port('wr_len'), flash.port('wr_len'));
    connectPorts(sink.port('wr_data'), flash.port('wr_data'));
    // The engine presents the index it wants, the sink presents the byte.
    connectPorts(flash.port('wr_data_index'), sink.port('wr_data_index'));
    connectPorts(flash.port('wr_busy'), sink.port('wr_busy'));
    connectPorts(flash.port('wr_done'), sink.port('wr_done'));
    connectPorts(flash.port('wr_err'), sink.port('wr_err'));

    // Tie off the CPU read-side Wishbone slave bus: B5b never reads, so park
    // cyc/stb low and zero the rest (the controller's read FSM stays idle).
    flash.input('bus_CYC').srcConnection! <= Const(0);
    flash.input('bus_STB').srcConnection! <= Const(0);
    flash.input('bus_WE').srcConnection! <= Const(0);
    flash.input('bus_ADR').srcConnection! <=
        Const(0, width: flash.input('bus_ADR').width);
    flash.input('bus_DAT_MOSI').srcConnection! <=
        Const(0, width: flash.input('bus_DAT_MOSI').width);
    flash.input('bus_SEL').srcConnection! <=
        Const(0, width: flash.input('bus_SEL').width);

    // SPI pins out, MISO in (standard mode).
    connectPorts(port('spi_miso'), flash.port('spi_miso'));
    addOutput('spi_clk') <= flash.output('spi_clk');
    addOutput('spi_cs_n') <= flash.output('spi_cs_n');
    addOutput('spi_mosi') <= flash.output('spi_mosi');

    // Observability outputs from the sink.
    addOutput('image_ready') <= sink.output('image_ready');
    addOutput('busy') <= sink.output('busy');
    addOutput('error') <= sink.output('error');
    addOutput('bytes_written', width: 32) <= sink.output('bytes_written');
    addOutput('sink_ready') <= sink.output('sink_ready');
    addOutput('overflow') <= sink.output('overflow');
  }
}
