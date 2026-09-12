import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/wishbone/wishbone_interface.dart';
import '../clock/cdc.dart';
import 'spi_flash.dart';
import 'usb_phy.dart';

/// A single USB descriptor entry: the (desc_type, desc_index) key that selects
/// it and the byte list that makes it up.
///
/// [bytes.length] is the descriptor's true byte count and is what
/// [UsbDescriptorRom] reports on `length`. The constructor asserts that the
/// descriptor's own bLength-derived total (the wTotalLength field for a
/// CONFIGURATION descriptor, or bLength otherwise) agrees with the actual
/// byte count, so a transcription error in a length field fails at build time
/// rather than silently shipping a malformed descriptor.
///
/// This is PUBLIC so a caller (e.g. a vendor-class device) can supply its OWN
/// descriptor set to [UsbDescriptorRom] / [UsbEp0Engine] instead of the
/// hard-coded DFU descriptors, while still reusing the proven combinational ROM
/// + ch9 EP0 control FSM unchanged.
class UsbDescriptorEntry {
  /// bDescriptorType (DEVICE=1, CONFIGURATION=2, STRING=3, ...).
  final int type;

  /// The descriptor index (descriptor index for STRING, 0 for DEVICE/CONFIG).
  final int index;

  /// The raw descriptor bytes, in wire order (LE multi-byte fields).
  final List<int> bytes;

  const UsbDescriptorEntry(this.type, this.index, this.bytes);
}

/// Builds a STRING descriptor (bDescriptorType 0x03) for [s] as UTF-16LE. A
/// shared helper so callers constructing an injected descriptor set produce
/// byte-identical STRING descriptors to the built-in DFU ones.
List<int> usbStringDescriptor(String s) {
  final units = s.codeUnits;
  final out = <int>[2 + 2 * units.length, 0x03];
  for (final u in units) {
    out.add(u & 0xFF);
    out.add((u >> 8) & 0xFF);
  }
  return out;
}

/// STRING index 0: supported LANGID list (English-US 0x0409). Reused by both
/// the built-in DFU descriptor set and injected vendor sets.
const List<int> usbStringLangIdEnUs = [4, 0x03, 0x09, 0x04];

/// Combinational ROM of the USB DFU device's standard descriptors.
///
/// This is pure data: no clock, no reset, no state. Given a descriptor key
/// (`desc_type`, `desc_index`) and a byte `offset`, it returns:
///   - `present` : 1 if the (type, index) pair is a known descriptor, else 0.
///   - `length`  : the total byte count of the selected descriptor (0 if not
///                 present).
///   - `data`    : the byte at `offset` within the selected descriptor, or 0
///                 if the descriptor is absent or `offset` is out of range.
///
/// The descriptor bytes are held as Dart `List<int>`s (built from the USB 2.0
/// ch9 + DFU 1.1 field tables) and compiled into combinational selection logic:
/// a per-descriptor key match drives the length/present outputs, and the data
/// output is an indexed mux over each descriptor's bytes selected by the same
/// match. No clock is required (and none is created).
class UsbDescriptorRom extends BridgeModule {
  /// DEVICE descriptor (bDescriptorType 0x01), 18 bytes.
  static const List<int> deviceDescriptor = [
    18, // bLength
    0x01, // bDescriptorType = DEVICE
    0x00, 0x02, // bcdUSB = 0x0200 (LE)
    0x00, // bDeviceClass
    0x00, // bDeviceSubClass
    0x00, // bDeviceProtocol
    64, // bMaxPacketSize0
    0x09, 0x12, // idVendor = 0x1209 (LE)
    0xF1, 0x5B, // idProduct = 0x5BF1 (LE)
    0x00, 0x01, // bcdDevice = 0x0100 (LE)
    1, // iManufacturer
    2, // iProduct
    0, // iSerialNumber
    1, // bNumConfigurations
  ];

  /// CONFIGURATION descriptor (bDescriptorType 0x02): the full configuration
  /// tree (config header + interface alt0 + interface alt1 + DFU functional),
  /// 36 bytes, as returned by GET_DESCRIPTOR(CONFIGURATION).
  static const List<int> configDescriptor = [
    // Configuration header (9 bytes).
    9, // bLength
    0x02, // bDescriptorType = CONFIGURATION
    0x24, 0x00, // wTotalLength = 36 (LE)
    1, // bNumInterfaces
    1, // bConfigurationValue
    0, // iConfiguration
    0x80, // bmAttributes
    50, // bMaxPower
    // Interface descriptor, alt setting 0 (9 bytes).
    9, // bLength
    0x04, // bDescriptorType = INTERFACE
    0, // bInterfaceNumber
    0, // bAlternateSetting
    0, // bNumEndpoints
    0xFE, // bInterfaceClass (Application Specific)
    0x01, // bInterfaceSubClass (DFU)
    0x02, // bInterfaceProtocol (DFU mode)
    4, // iInterface
    // Interface descriptor, alt setting 1 (9 bytes).
    9, // bLength
    0x04, // bDescriptorType = INTERFACE
    0, // bInterfaceNumber
    1, // bAlternateSetting
    0, // bNumEndpoints
    0xFE, // bInterfaceClass
    0x01, // bInterfaceSubClass
    0x02, // bInterfaceProtocol
    5, // iInterface
    // DFU functional descriptor (9 bytes).
    9, // bLength
    0x21, // bDescriptorType = DFU FUNCTIONAL
    0x05, // bmAttributes (CAN_DNLOAD | MANIFEST_TOLERANT)
    0xFF, 0x00, // wDetachTimeOut = 0x00FF (LE)
    0x40, 0x00, // wTransferSize = 64 (LE)
    0x10, 0x01, // bcdDFUVersion = 0x0110 (LE)
  ];

  /// Builds a STRING descriptor (bDescriptorType 0x03) for [s] as UTF-16LE.
  static List<int> _stringDescriptor(String s) => usbStringDescriptor(s);

  /// STRING index 0: supported LANGID list (English-US 0x0409).
  static const List<int> stringLangId = usbStringLangIdEnUs;

  /// When true, append a TEST-ONLY 64-byte STRING descriptor at index 6. 64 is
  /// an exact multiple of the EP0 max packet size, so a device-limited
  /// GET_DESCRIPTOR for it exercises the terminating-ZLP path (Important #2).
  /// It is purely additive (a new key) and OFF by default, so production and
  /// every existing test are unaffected.
  final bool includeTestDescriptor;

  /// A 31-character ASCII string -> 2 + 2*31 = 64-byte STRING descriptor.
  static const String _testStr64 = 'River DFU 64-byte ZLP test desc';

  /// The built-in DFU descriptor set (DEVICE + CONFIGURATION + STRINGs). This
  /// is the default table when no [descriptors] are injected, preserving the
  /// historical DFU behaviour exactly.
  static List<UsbDescriptorEntry> dfuDescriptors({
    bool includeTestDescriptor = false,
  }) => <UsbDescriptorEntry>[
    const UsbDescriptorEntry(0x01, 0, deviceDescriptor),
    const UsbDescriptorEntry(0x02, 0, configDescriptor),
    const UsbDescriptorEntry(0x03, 0, stringLangId),
    UsbDescriptorEntry(0x03, 1, _stringDescriptor('River')),
    UsbDescriptorEntry(0x03, 2, _stringDescriptor('River DFU')),
    UsbDescriptorEntry(0x03, 4, _stringDescriptor('RAM')),
    UsbDescriptorEntry(0x03, 5, _stringDescriptor('SPI flash')),
    if (includeTestDescriptor)
      UsbDescriptorEntry(0x03, 6, _stringDescriptor(_testStr64)),
  ];

  /// Optional CALLER-SUPPLIED descriptor set. When non-null this REPLACES the
  /// built-in DFU table, so the same proven combinational ROM (and the
  /// [UsbEp0Engine] control FSM that reads it) serves a vendor device's
  /// descriptors. When null the DFU table is used (backward compatible).
  final List<UsbDescriptorEntry>? injectedDescriptors;

  UsbDescriptorRom({
    String? name,
    this.includeTestDescriptor = false,
    List<UsbDescriptorEntry>? descriptors,
  }) : injectedDescriptors = descriptors,
       super('UsbDescriptorRom', name: name ?? 'usb_desc_rom') {
    createPort('desc_type', PortDirection.input, width: 8);
    createPort('desc_index', PortDirection.input, width: 8);
    createPort('offset', PortDirection.input, width: 8);
    addOutput('data', width: 8);
    addOutput('length', width: 16);
    addOutput('present');

    // The full descriptor table. An injected set REPLACES the DFU default.
    // Order is irrelevant to correctness as keys are matched explicitly. The
    // includeTestDescriptor knob only augments the built-in DFU set (it is a
    // DFU-test-only hook and does not apply to an injected set).
    final descs =
        descriptors ??
        dfuDescriptors(includeTestDescriptor: includeTestDescriptor);
    if (descs.isEmpty) {
      throw ArgumentError('UsbDescriptorRom requires at least one descriptor');
    }

    // DESCRIPTOR SIZE CEILING: the IN-data ROM read offset is an 8-bit port
    // (`offset`), and UsbEp0Engine computes ROM offsets as `(inSent +
    // payload_index)[7:0]`. A descriptor longer than 255 bytes would wrap that
    // 8-bit offset and alias bytes, so no standard descriptor served here may
    // exceed 255 bytes. (USB single-descriptor bLength is itself 8-bit, the
    // CONFIGURATION tree's wTotalLength could in principle exceed 255, which is
    // out of scope for this DFU device's small config.)
    for (final d in descs) {
      assert(
        d.bytes.length <= 255,
        'descriptor (type=${d.type}, index=${d.index}) exceeds the 255-byte '
        'ROM offset ceiling (8-bit offset port)',
      );
    }

    // Build-time integrity checks: every byte must be a legal 0..255 value, and
    // each descriptor's declared length field must equal its real byte count.
    for (final d in descs) {
      for (final b in d.bytes) {
        if (b < 0 || b > 0xFF) {
          throw ArgumentError(
            'descriptor (type=${d.type}, index=${d.index}) has out-of-range '
            'byte $b',
          );
        }
      }
      if (d.bytes.isEmpty) {
        throw ArgumentError(
          'descriptor (type=${d.type}, index=${d.index}) is empty',
        );
      }
      // bLength (byte 0) must equal the actual length for non-config
      // descs. The CONFIGURATION descriptor instead carries the total in
      // wTotalLength (bytes 2..3), with byte 0 being just the header length.
      if (d.type == 0x02) {
        final wTotalLength = d.bytes[2] | (d.bytes[3] << 8);
        if (wTotalLength != d.bytes.length) {
          throw ArgumentError(
            'CONFIGURATION descriptor wTotalLength=$wTotalLength does not '
            'match actual byte count ${d.bytes.length}',
          );
        }
      } else {
        if (d.bytes[0] != d.bytes.length) {
          throw ArgumentError(
            'descriptor (type=${d.type}, index=${d.index}) bLength='
            '${d.bytes[0]} does not match actual byte count '
            '${d.bytes.length}',
          );
        }
      }
    }

    final descType = input('desc_type');
    final descIndex = input('desc_index');
    final offset = input('offset');

    // Per-descriptor key match.
    final matches = <Logic>[
      for (final d in descs)
        (descType.eq(Const(d.type, width: 8)) &
                descIndex.eq(Const(d.index, width: 8)))
            .named('match_t${d.type}_i${d.index}'),
    ];

    // present = OR of all key matches.
    Logic presentLocal = Const(0);
    for (final m in matches) {
      presentLocal = presentLocal | m;
    }
    output('present') <= presentLocal;

    // length = the matched descriptor's byte count (0 if no match). Built as a
    // priority-free OR-mux: keys are mutually exclusive by construction.
    Logic lengthLocal = Const(0, width: 16);
    for (var i = 0; i < descs.length; i++) {
      lengthLocal = mux(
        matches[i],
        Const(descs[i].bytes.length, width: 16),
        lengthLocal,
      );
    }
    output('length') <= lengthLocal;

    // data = byte at `offset` within the matched descriptor, else 0. For each
    // descriptor build an indexed mux over its bytes (offset out of range -> 0),
    // then select the matched descriptor's byte.
    Logic dataLocal = Const(0, width: 8);
    for (var i = 0; i < descs.length; i++) {
      final bytes = descs[i].bytes;
      // Indexed byte select for this descriptor.
      Logic byteSel = Const(0, width: 8);
      for (var off = 0; off < bytes.length; off++) {
        byteSel = mux(
          offset.eq(Const(off, width: 8)),
          Const(bytes[off], width: 8),
          byteSel,
        );
      }
      dataLocal = mux(matches[i], byteSel, dataLocal);
    }
    output('data') <= dataLocal;
  }
}

/// PHY-facing packet receiver: collects ONE received packet from a
/// [HarborUsbFsPhyRx] into a PID byte plus a payload byte buffer.
///
/// Runs in the 48 MHz USB domain. It takes the PhyRx framing outputs as INPUTS
/// (rather than instantiating PhyRx) so the EP0 control FSM and this collector
/// can share a single PhyRx instance:
///   in:  clk, reset, rx_data, rx_valid, rx_sop, rx_eop, rd_index
///   out: pid, byte_count, rd_byte, pkt_done
///
/// PhyRx contract (see [HarborUsbFsPhyRx]): the SYNC field is already stripped,
/// so the body it forwards is PID byte, then payload bytes, then the 2 CRC
/// bytes. Bits arrive LSB-first within a byte, one per `rx_valid` pulse.
/// `rx_sop` pulses once at start-of-packet (before any body bit) and `rx_eop`
/// once at end.
///
/// Assembly:
///   - On `rx_sop` the bit/byte assembler is reset (bit index 0, byte index 0).
///   - Each `rx_valid` shifts the decoded bit into a bit accumulator at its
///     LSB-first position. After 8 bits a byte is complete: byte 0 latches into
///     [pid]. Bytes 1.. are written into the payload buffer and [byte_count]
///     (the number of payload bytes AFTER the PID, INCLUDING the 2 trailing CRC
///     bytes) increments.
///   - On `rx_eop`, [pkt_done] pulses for one cycle so the consumer can latch
///     [pid]/[byte_count]/the buffer.
///
/// [rd_index] -> [rd_byte] is a combinational read port over the payload buffer
/// (out-of-range reads 0). CRC verification is intentionally NOT performed here
/// (the PHY framing is trusted in sim). CRC-check is deferred to a later
/// hardening pass.
class UsbPacketRx extends BridgeModule {
  /// Payload buffer depth in bytes (payload + 2 CRC). 16 covers a SETUP data
  /// packet (8 payload + 2 CRC) with margin.
  final int bufBytes;

  UsbPacketRx({this.bufBytes = 16, String? name})
    : super('UsbPacketRx', name: name ?? 'usb_pkt_rx') {
    assert(bufBytes > 0 && bufBytes <= 256, 'bufBytes out of range');
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('rx_data', PortDirection.input);
    createPort('rx_valid', PortDirection.input);
    createPort('rx_sop', PortDirection.input);
    createPort('rx_eop', PortDirection.input);
    createPort('rd_index', PortDirection.input, width: 8);
    addOutput('pid', width: 8);
    addOutput('byte_count', width: 8);
    addOutput('rd_byte', width: 8);
    addOutput('pkt_done');

    final clk = input('clk');
    final reset = input('reset');
    final rxData = input('rx_data');
    final rxValid = input('rx_valid');
    final rxSop = input('rx_sop');
    final rxEop = input('rx_eop');
    final rdIndex = input('rd_index');

    // Bit-within-byte counter (0..7) and the LSB-first accumulator.
    final bitIdx = Logic(name: 'bit_idx', width: 3);
    final acc = Logic(name: 'byte_acc', width: 8);
    // Byte index across the whole body: 0 = PID, 1.. = payload[0..].
    final byteIdx = Logic(name: 'byte_idx', width: 9);

    // Registered outputs / storage.
    final pidReg = Logic(name: 'pid_reg', width: 8);
    final countReg = Logic(name: 'byte_count_reg', width: 8);
    final doneReg = Logic(name: 'pkt_done_reg');
    // Payload byte buffer.
    final buf = [
      for (var i = 0; i < bufBytes; i++) Logic(name: 'buf_$i', width: 8),
    ];

    // The completed-byte value on the cycle the 8th bit arrives: accumulator
    // with the incoming bit placed at its LSB-first position (bit 7).
    final fullByte = [rxData, acc.slice(7, 1)].swizzle();
    // True on the rx_valid that completes a byte (bitIdx has reached 7).
    final byteDone = rxValid & bitIdx.eq(Const(7, width: 3));
    // Payload byte slot index for a completing byte: byteIdx - 1 (PID is 0).
    final payIdx = (byteIdx - Const(1, width: 9)).slice(7, 0);

    Sequential(clk, [
      If(
        reset,
        then: [
          bitIdx < Const(0, width: 3),
          acc < Const(0, width: 8),
          byteIdx < Const(0, width: 9),
          pidReg < Const(0, width: 8),
          countReg < Const(0, width: 8),
          doneReg < Const(0),
          for (final b in buf) b < Const(0, width: 8),
        ],
        orElse: [
          // pkt_done is a one-cycle pulse.
          doneReg < Const(0),

          // Timing contract: PhyRx must pulse rx_sop at least one cycle BEFORE the
          // first body-bit rx_valid (true for HarborUsbFsPhyRx). If sop and the
          // first valid ever coincided, the rx_valid assembler block would stomp
          // the sop reset (ROHD last-write-wins) and mis-align byte assembly.
          If(
            rxSop,
            then: [
              // Restart the assembler for a fresh packet.
              bitIdx < Const(0, width: 3),
              byteIdx < Const(0, width: 9),
              countReg < Const(0, width: 8),
            ],
          ),

          If(
            rxValid,
            then: [
              // Shift the decoded bit into the LSB-first accumulator.
              acc < [rxData, acc.slice(7, 1)].swizzle(),
              If(
                byteDone,
                then: [
                  bitIdx < Const(0, width: 3),
                  byteIdx < byteIdx + 1,
                  If(
                    byteIdx.eq(Const(0, width: 9)),
                    then: [
                      // Byte 0 is the PID.
                      pidReg < fullByte,
                    ],
                    orElse: [
                      // Payload byte (incl. trailing CRC): store and bump the count.
                      countReg < countReg + 1,
                      // Guard the buffer write with the full 9-bit byteIdx so an
                      // over-long packet (byteIdx > bufBytes) cannot wrap payIdx and
                      // alias into a live slot. UsbEp0Engine sizes its pktRx buffer at
                      // dfuTransferSize + 2 = 66, so every byte of a max-size DNLOAD
                      // block fits. This guard is only reached for truly malformed
                      // over-length packets.
                      If(
                        byteIdx.lte(Const(bufBytes, width: 9)),
                        then: [
                          for (var i = 0; i < bufBytes; i++)
                            If(
                              payIdx.eq(Const(i, width: 8)),
                              then: [buf[i] < fullByte],
                            ),
                        ],
                      ),
                    ],
                  ),
                ],
                orElse: [bitIdx < bitIdx + 1],
              ),
            ],
          ),

          If(rxEop, then: [doneReg < Const(1)]),
        ],
      ),
    ]);

    output('pid') <= pidReg;
    output('byte_count') <= countReg;
    output('pkt_done') <= doneReg;

    // Combinational read port over the payload buffer (out-of-range -> 0).
    Logic rd = Const(0, width: 8);
    for (var i = 0; i < bufBytes; i++) {
      rd = mux(rdIndex.eq(Const(i, width: 8)), buf[i], rd);
    }
    output('rd_byte') <= rd;
  }
}

/// PHY-facing packet transmitter: serializes ONE packet onto a
/// [HarborUsbFsPhyTx].
///
/// Runs in the 48 MHz USB domain. It owns only the bit ORDERING and CRC16. The
/// PhyTx owns NRZI/bit-stuffing/EOP at the wire level. It drives the PhyTx host
/// interface exactly as a manual host would: present a data bit with
/// `tx_data_valid`, and advance the bit pointer on the PhyTx accept edge
/// (`tx_ready & tx_oe`), which is the proven pacing contract from the PHY
/// round-trip tests.
///   in:  clk, reset, send, is_data, pid, payload_len, payload_byte,
///        tx_ready, tx_oe
///   out: payload_index, tx_data, tx_data_valid, tx_eop_req, busy, done
///
/// Bit stream serialized (all LSB-first within a byte):
///   SYNC byte 0x80 (8 bits) , PID byte (8 bits) , then for a DATA packet
///   (`is_data`=1): each payload byte (payload_len bytes) , then the 2 CRC16
///   bytes. A handshake packet (`is_data`=0) stops after the PID (no payload,
///   no CRC). After the last bit, [tx_eop_req] asserts so the PhyTx runs an EOP.
///
/// Payload source: the consumer supplies bytes through a read-callback port -
/// this module drives [payload_index] and reads [payload_byte] combinationally
/// (the consumer wires it to its buffer / the descriptor ROM).
///
/// CRC16 (data packets): reflected poly 0xA001, init 0xFFFF, over the PAYLOAD
/// bytes only (NOT SYNC, NOT PID). Computed bit-by-bit in hardware as each
/// payload bit is consumed. At the end the residual is bit-inverted and sent
/// LSB-first as the 2 CRC bytes.
///
/// [busy] is high for the whole serialization. [done] pulses for one cycle when
/// the last bit has been accepted and [tx_eop_req] is asserted.
class UsbPacketTx extends BridgeModule {
  UsbPacketTx({String? name})
    : super('UsbPacketTx', name: name ?? 'usb_pkt_tx') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('send', PortDirection.input);
    createPort('is_data', PortDirection.input);
    createPort('pid', PortDirection.input, width: 8);
    createPort('payload_len', PortDirection.input, width: 8);
    createPort('payload_byte', PortDirection.input, width: 8);
    createPort('tx_ready', PortDirection.input);
    createPort('tx_oe', PortDirection.input);
    addOutput('payload_index', width: 8);
    addOutput('tx_data');
    addOutput('tx_data_valid');
    addOutput('tx_eop_req');
    addOutput('busy');
    addOutput('done');

    final clk = input('clk');
    final reset = input('reset');
    final send = input('send');
    final isDataIn = input('is_data');
    final pidIn = input('pid');
    final payLenIn = input('payload_len');
    final payByte = input('payload_byte');
    final txReady = input('tx_ready');
    final txOe = input('tx_oe');

    final busyReg = Logic(name: 'busy_reg');
    final isData = Logic(name: 'is_data_reg');
    final pidReg = Logic(name: 'pid_reg', width: 8);
    final plen = Logic(name: 'plen_reg', width: 8); // payload byte count
    // Bit pointer across the whole serialized stream (12 bits: well past any
    // EP0 packet, SYNC+PID+64B payload+CRC = 16 + 512 + 16 = 544 < 4096).
    final bitIndex = Logic(name: 'bit_index', width: 12);
    // Running CRC16 over payload bytes (reflected).
    final crc = Logic(name: 'crc16', width: 16);
    final doneReg = Logic(name: 'done_reg');

    // payload bit count = plen * 8.
    final payloadBits = [plen, Const(0, width: 3)].swizzle().zeroExtend(12);
    final headerBits = Const(16, width: 12); // SYNC(8) + PID(8)
    final crcStart = headerBits + payloadBits; // first CRC bit index
    final dataTotal = crcStart + Const(16, width: 12); // SYNC+PID+payload+CRC
    final total = mux(isData, dataTotal, headerBits);

    // In-region predicates.
    final inSync = bitIndex.lt(Const(8, width: 12));
    final inPid =
        bitIndex.gte(Const(8, width: 12)) & bitIndex.lt(Const(16, width: 12));
    final inPayload =
        isData & bitIndex.gte(Const(16, width: 12)) & bitIndex.lt(crcStart);

    // SYNC byte in the data-bit domain is 0x80 (LSB-first 0,0,0,0,0,0,0,1).
    final syncByte = Const(0x80, width: 8);

    // Bit offset within the current byte for sync/pid/payload (0..7).
    final syncBitOff = bitIndex.slice(2, 0);
    final pidBitOff = (bitIndex - Const(8, width: 12)).slice(2, 0);
    final payRel = bitIndex - Const(16, width: 12);
    final payByteOff = payRel.slice(2, 0); // bit within payload byte
    final payByteIdx = payRel.slice(10, 3); // payload byte number (8-bit)

    // payload_index drives the consumer's read port for the current payload bit.
    output('payload_index') <= payByteIdx;

    // CRC bytes: inverted residual, sent LSB-first.
    final crcOut = ~crc;
    final crcBitIndex = (bitIndex - crcStart).slice(3, 0); // 0..15

    // Select the current bit to present.
    Logic bitAt(Logic byte, Logic off) =>
        (byte >> off.zeroExtend(8)).slice(0, 0);
    final curBit = mux(
      inSync,
      bitAt(syncByte, syncBitOff),
      mux(
        inPid,
        bitAt(pidReg, pidBitOff),
        mux(
          inPayload,
          bitAt(payByte, payByteOff),
          // CRC region (or past end): pick the CRC bit.
          (crcOut >> crcBitIndex.zeroExtend(16)).slice(0, 0),
        ),
      ),
    );

    // We are presenting a real data bit whenever bits remain.
    final bitsRemain = bitIndex.lt(total);
    final dataValidLocal = busyReg & bitsRemain;
    // EOP is requested once all bits are sent (busy, no bits remain).
    final eopReqLocal = busyReg & ~bitsRemain;

    // Accept edge: the cycle on which the PhyTx CONSUMES the presented bit, so
    // the bit pointer advances in exact lockstep with what the wire carries.
    //
    // The PhyTx consumes a bit on TWO kinds of edge:
    //   1. The KICKOFF: while it is idle (oe low) it holds `ready` level-high and
    //      ENCODES the first presented bit the moment we raise data_valid (the
    //      idle->send transition). At that registered posedge oe is still 0, so a
    //      plain `ready & oe` test MISSES this consume.
    //   2. Steady state: a one-cycle `ready` pulse at the end of each bit time,
    //      where oe is already high.
    // The old `ready & oe` gate counted only (2). It missed the kickoff, so the
    // pointer lagged the wire by one bit: the PhyTx re-read bit 0 at the end of
    // bit 0's time and TRANSMITTED THE FIRST SYNC BIT TWICE. That shifted the
    // whole packet by a bit, so the SYNC field went out as KJKJKJKJ instead of
    // KJKJKJKK. Harbor's sliding-window RX tolerated the shift, but a real host
    // rejects the malformed SYNC -> "device descriptor read/64, error -32".
    // Counting the kickoff (busy, ready, not yet driving) realigns the pointer so
    // the SYNC field is bit-exact.
    final kickoff = busyReg & txReady & ~txOe;
    final accept = (txReady & txOe) | kickoff;

    // CRC update for the bit being consumed when it is a payload bit. Reflected
    // poly 0xA001: xorIn = crc[0] ^ bit, crc >>= 1, if xorIn crc ^= 0xA001.
    final xorIn = crc.slice(0, 0) ^ curBit;
    final crcShifted = crc.slice(15, 1).zeroExtend(16);
    final crcNext = mux(
      xorIn,
      crcShifted ^ Const(0xA001, width: 16),
      crcShifted,
    );

    Sequential(clk, [
      If(
        reset,
        then: [
          busyReg < Const(0),
          isData < Const(0),
          pidReg < Const(0, width: 8),
          plen < Const(0, width: 8),
          bitIndex < Const(0, width: 12),
          crc < Const(0xFFFF, width: 16),
          doneReg < Const(0),
        ],
        orElse: [
          doneReg < Const(0),
          If(
            ~busyReg,
            then: [
              If(
                send,
                then: [
                  busyReg < Const(1),
                  isData < isDataIn,
                  pidReg < pidIn,
                  plen < payLenIn,
                  bitIndex < Const(0, width: 12),
                  crc < Const(0xFFFF, width: 16),
                ],
              ),
            ],
            orElse: [
              // Active serialization.
              If(
                eopReqLocal,
                then: [
                  // All bits sent. We have asserted tx_eop_req. Wait for the PhyTx to
                  // take the EOP (oe drops) then finish.
                  If(~txOe, then: [busyReg < Const(0), doneReg < Const(1)]),
                ],
                orElse: [
                  // Pace each bit on the PhyTx accept edge.
                  If(
                    accept,
                    then: [
                      bitIndex < bitIndex + 1,
                      // Update CRC only for an accepted payload bit.
                      If(inPayload, then: [crc < crcNext]),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    output('tx_data') <= curBit;
    output('tx_data_valid') <= dataValidLocal;
    output('tx_eop_req') <= eopReqLocal;
    output('busy') <= busyReg;
    output('done') <= doneReg;
  }
}

/// EP0 control-transfer FSM: the heart of the USB DFU device that makes it
/// ENUMERATE. Composes the B1/B2a building blocks ([UsbDescriptorRom],
/// [UsbPacketRx], [UsbPacketTx]) and the full-speed PHY ([HarborUsbFsPhyRx],
/// [HarborUsbFsPhyTx]) into a single self-contained endpoint-0 engine.
///
/// Runs in the 48 MHz USB domain.
///
/// Ports
///   in:  clk, reset, dp, dm  (dp/dm are the USB line pads into the PhyRx)
///   out: dp_out, dm_out, oe  (driven by the PhyTx)
///   out: usb_pullup          (tied high: the D+ pull-up enable, connect-when-on)
///   out: dev_addr[7]         (current device address, 0 until SET_ADDRESS lands)
///   out: configured          (1 after SET_CONFIGURATION)
///   out: alt_setting[8]      (current SET_INTERFACE alternate setting)
///   out: class_setup         (1-cycle strobe when a class/interface SETUP lands)
///   out: setup0..setup7      (the captured 8 SETUP bytes, for B3 to inspect)
///   out: setup_valid         (level: high once a SETUP has been captured)
///
/// Control-transfer protocol (USB 2.0 ch9):
///   SETUP stage   : a SETUP token (PID 0x2D) then a DATA0 (PID 0xC3) with the 8
///                   setup bytes [bmRequestType, bRequest, wValueLo, wValueHi,
///                   wIndexLo, wIndexHi, wLengthLo, wLengthHi]. The engine
///                   captures them and replies ACK (handshake PID 0xD2).
///   DATA stage    : IN data (PID 0x69 token then device sends a DATA1/DATA0
///                   packet, up to 64 bytes/chunk, toggling, until min(respLen,
///                   wLength) bytes are sent, a short/zero final chunk ends it).
///   STATUS stage  : IN-data requests take an OUT status (OUT token + zero-length
///                   DATA1 from host, device ACKs). No-data requests take an IN
///                   status (IN token, device sends a zero-length DATA1, host
///                   ACKs).
///
/// Standard requests implemented:
///   GET_DESCRIPTOR(6)    : descriptor from the ROM, truncated to wLength, 64-chunked.
///   SET_ADDRESS(5)       : capture wValue, do IN status, then APPLY dev_addr
///                          AFTER the status stage (spec-correct ordering).
///   SET_CONFIGURATION(9) : IN status, set configured=1.
///   SET_INTERFACE(11)    : IN status, alt_setting = wValue.
///   GET_STATUS(0)        : IN 2 bytes 0x0000.
///   GET_CONFIGURATION(8) : IN 1 byte (configured ? 1 : 0).
///   GET_INTERFACE(10)    : IN 1 byte (alt_setting).
/// Any other standard request and (for B2b) any class/vendor request are STALLed
/// (handshake PID 0x1E). A class/interface SETUP additionally pulses
/// [class_setup] and latches the 8 bytes on setup0..7 so B3 can pick it up.
///
/// Data toggle: SETUP data is always DATA0. The first DATA-stage packet is DATA1
/// and toggles thereafter. The status-stage zero-length packet is DATA1.
class UsbEp0Engine extends BridgeModule {
  // (Widened from 4-bit to 5-bit in B3 to make room for the OUT-data control
  // transfer phase + the DFU DNLOAD sink-streaming / manifest states.)
  /// Idle: line up, waiting for the next token/packet to complete.
  static const int _stIdle = 0;

  /// A SETUP token was seen. Waiting for the following DATA0 setup packet.
  static const int _stSetupData = 1;

  /// Walking the UsbPacketRx buffer to snapshot the 8 setup bytes.
  static const int _stSetupCapture = 12;

  /// Sending the ACK handshake that closes the SETUP stage.
  static const int _stSetupAck = 2;

  /// IN data stage: waiting for an IN token before sending the next chunk.
  static const int _stInWaitToken = 3;

  /// IN data stage: sending a DATA chunk.
  static const int _stInSendData = 4;

  /// IN data stage: waiting for the host's ACK of the chunk.
  static const int _stInWaitAck = 5;

  /// OUT status stage (after IN data): waiting for the zero-length OUT DATA.
  static const int _stOutStatus = 6;

  /// OUT status stage: sending the ACK handshake.
  static const int _stOutStatusAck = 7;

  /// IN status stage (no-data request): waiting for the IN token.
  static const int _stInStatusToken = 8;

  /// IN status stage: sending the zero-length DATA1 packet.
  static const int _stInStatusData = 9;

  /// IN status stage: waiting for the host's ACK.
  static const int _stInStatusAck = 10;

  /// Sending a STALL handshake for an unsupported request.
  static const int _stStall = 11;

  /// OUT data stage: waiting for the OUT token (PID 0xE1) of a data packet.
  static const int _stOutDataToken = 13;

  /// OUT data stage: waiting for the DATA packet that carries the payload.
  static const int _stOutDataPkt = 14;

  /// OUT data stage: streaming the captured payload out the sink, one byte/cyc.
  static const int _stSinkStream = 15;

  /// OUT data stage: sending the ACK handshake for the received DATA packet.
  static const int _stOutDataAck = 16;

  /// Got an OUT/EP1 token. Awaiting the bulk OUT DATA packet.
  static const int _stEp1OutData = 17;

  /// Bulk OUT: sending the ACK handshake for the received DATA packet.
  static const int _stEp1OutAck = 18;

  /// Got an IN/EP1 token. Sending the response DATA packet.
  static const int _stEp1InData = 19;

  /// Bulk IN: awaiting the host ACK of the IN DATA packet.
  static const int _stEp1InWaitAck = 20;

  /// Bulk IN: sending a NAK (no response byte ready).
  static const int _stEp1Nak = 21;

  /// Bulk OUT: draining the already-ACKed OUT DATA payload into cmd_* at the
  /// cmd engine's own pace (decoupled from the host-visible ACK timing).
  static const int _stEp1OutDrain = 22;

  /// Bulk IN: GATHER all currently-available response bytes from the resp_*
  /// stream into the IN payload buffer (up to 64) BEFORE sending one DATA
  /// packet, so the host receives the full response in a single transfer
  /// instead of a 1-byte short packet per IN token.
  static const int _stEp1InGather = 23;

  static const int _pidSetup = 0x2D;
  static const int _pidIn = 0x69;
  static const int _pidOut = 0xE1; // OUT token PID (host->device, status stage)
  static const int _pidData0 = 0xC3;
  static const int _pidData1 = 0x4B;
  static const int _pidAck = 0xD2;
  static const int _pidNak = 0x5A; // NAK handshake (bulk IN with no data)
  static const int _pidStall = 0x1E;

  /// EP0 max packet size (full speed bMaxPacketSize0 = 64).
  static const int _maxPacket = 64;

  /// DFU wTransferSize: the maximum DNLOAD block payload in bytes (64). This
  /// must match the wTransferSize field in [UsbDescriptorRom.configDescriptor]
  /// (bytes 32..33 of the DFU functional descriptor, LE: 0x40, 0x00).
  /// The receive buffer is sized dfuTransferSize + 2 CRC bytes.
  static const int dfuTransferSize = 64;

  static const int _dfuDnload = 1;
  // ignore: unused_field
  static const int _dfuUpload = 2;
  static const int _dfuGetStatus = 3;
  static const int _dfuClrStatus = 4;
  static const int _dfuGetState = 5;
  static const int _dfuAbort = 6;

  static const int _dfuIDLE = 2;
  // ignore: unused_field, constant_identifier_names
  static const int _dfuDNLOAD_SYNC = 3;
  // ignore: unused_field, constant_identifier_names
  static const int _dfuDNBUSY = 4;
  // ignore: constant_identifier_names
  static const int _dfuDNLOAD_IDLE = 5;
  // ignore: unused_field, constant_identifier_names
  static const int _dfuMANIFEST_SYNC = 6;
  // ignore: unused_field, constant_identifier_names
  static const int _dfuMANIFEST = 7;
  // ignore: unused_field, constant_identifier_names
  static const int _dfuERROR = 10;

  /// When true, the descriptor ROM includes a TEST-ONLY 64-byte STRING
  /// descriptor (STRING index 6). OFF by default. Used only to exercise the
  /// terminating-ZLP data-stage path (Important #2) in the unit test.
  final bool includeTestDescriptor;

  /// Optional CALLER-SUPPLIED descriptor set. When non-null this REPLACES the
  /// built-in DFU descriptor table, so the SAME proven ch9 EP0 control FSM
  /// (SET_ADDRESS / GET_DESCRIPTOR incl. STRING indexing / SET_CONFIGURATION /
  /// data-toggle / ZLP) serves a different device's descriptors (e.g. a vendor
  /// device with bulk endpoints). When null the DFU descriptors are used,
  /// preserving the historical behaviour exactly.
  final List<UsbDescriptorEntry>? descriptors;

  /// When true, the engine exposes a BULK endpoint pair on EP1 (host->device
  /// bulk OUT command stream + device->host bulk IN response stream), routed by
  /// the incoming token's endpoint field. OFF by default, so the DFU build and
  /// every existing test keep an EP0-only interface (no extra ports, no FSM
  /// change). The bulk endpoints and the DFU OUT-data (DNLOAD) sink are mutually
  /// exclusive paths in the FSM: a vendor device uses the bulk endpoints, a DFU
  /// device uses the sink. See [_stEp1OutData].. states below.
  final bool bulkEndpoints;

  /// When true, the EP1 BULK IN/OUT token routing only fires for tokens whose
  /// device-address field matches our assigned [dev_addr]. Required on a real
  /// SHARED bus so we do not drive the bus answering endpoint-1 tokens meant for
  /// ANOTHER device (contention -> the host xHCI HALTs our bulk EPs). It ONLY
  /// gates the two EP1 bulk routing conditions in IDLE (where cap_idx is held at
  /// 0 so rxByte presents the token's addr/endp byte). The CONTROL / SETUP / EP0
  /// path is never touched, so enumeration is unaffected. OFF by default.
  final bool filterByAddress;

  UsbEp0Engine({
    String? name,
    this.includeTestDescriptor = false,
    this.descriptors,
    this.bulkEndpoints = false,
    this.filterByAddress = false,
  }) : super('UsbEp0Engine', name: name ?? 'usb_ep0') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    // B1 back-pressure: the firmware sink asserts sink_ready when it can accept
    // another byte. The engine only pulses sink_valid / advances the stream
    // walk while this is high, so the sink's CDC FIFO can never overflow. It is
    // tied to 1 internally when the SoC does not wire a sink (so the existing
    // engine-only tests, which never drive it, stream unthrottled as before).
    createPort('sink_ready', PortDirection.input);
    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('usb_pullup');
    addOutput('dev_addr', width: 7);
    addOutput('configured');
    addOutput('alt_setting', width: 8);
    addOutput('class_setup');
    addOutput('setup_valid');
    for (var i = 0; i < 8; i++) {
      addOutput('setup$i', width: 8);
    }
    // USB bus-reset level (SE0 held past the PHY threshold). Surfaced so a
    // downstream consumer (e.g. a bulk command engine) can also snap back to
    // its Default state on a host re-enumeration, exactly as this engine does.
    // Held high for the whole SE0 window, a registered LEVEL, glitch-debounced
    // by the PHY's resetTicks counter.
    addOutput('bus_reset');

    // cmd_*  : bulk OUT, host->device. The engine pushes each received OUT DATA
    //          payload byte onto cmd_data with a cmd_valid pulse while cmd_ready
    //          (the byte-granular OUT NAK gate) is high, then ACKs the packet.
    // resp_* : bulk IN, device->host. On an IN token the engine offers the
    //          response byte stream (resp_data/resp_valid) as a DATA packet, or
    //          NAKs when no response byte is ready.
    if (bulkEndpoints) {
      addOutput('cmd_data', width: 8);
      addOutput('cmd_valid');
      createPort('cmd_ready', PortDirection.input);
      createPort('resp_data', PortDirection.input, width: 8);
      createPort('resp_valid', PortDirection.input);
      // resp_last: asserted (with resp_valid) on the FINAL response byte of the
      // current command's response. The EP1-IN packet assembler drains response
      // bytes into ONE bulk IN DATA packet and stops after the byte on which
      // resp_last is high (or at the 64-byte max-packet ceiling). A bulk IN must
      // return ALL available response bytes in a single DATA packet (up to
      // wMaxPacketSize=64). A 1-byte DATA packet is a SHORT packet that ends the
      // host transfer prematurely. resp_last lets us pack the whole response.
      // Tied to 0 in build() if unwired (then the assembler falls back to the
      // resp_valid-low boundary, preserving single-word behaviour).
      createPort('resp_last', PortDirection.input);
      addOutput('resp_ready');
      // cmd_start: a one-cycle pulse the instant a NEW bulk OUT TRANSFER
      // (a fresh command) is accepted. A transfer is one or more packets: it
      // ends on a packet that is shorter than wMaxPacketSize, so a packet that
      // follows a full-size packet continues the same command and gives NO
      // pulse. A downstream command engine that may be
      // mid-RESPONSE (e.g. a multi-byte READ whose bytes the host only partially
      // drained before issuing a new command) MUST preempt that stale response
      // so it can accept the new command: otherwise the engine holds cmd_ready
      // low (busy emitting the old response) while this engine sits in
      // _stEp1OutDrain waiting for cmd_ready, and the two DEADLOCK (the
      // OUT-after-partial-read wedge: OUT ACKs but every following IN times out).
      // Wire this to the command engine's preempt/abort so a new command always
      // wins, exactly as USB bulk semantics intend (a new OUT supersedes a
      // response the host walked away from).
      addOutput('cmd_start');
    }

    // sink_valid pulses once per captured DNLOAD payload byte (in order). The
    // byte is on sink_data and the current DNLOAD block number is on sink_block.
    addOutput('sink_data', width: 8);
    addOutput('sink_valid');
    addOutput('sink_block', width: 16);
    // dnload_done pulses for one cycle when a zero-length DNLOAD completes (the
    // whole image has been received). image_target latches the alt_setting at
    // that moment (0 = RAM, 1 = SPI flash). dfu_state surfaces the DFU bState.
    addOutput('dnload_done');
    addOutput('image_target', width: 8);
    addOutput('dfu_state', width: 4);

    final clk = input('clk');
    final reset = input('reset');

    // B1 back-pressure input. Captured here so the FSM can gate on it. If the
    // SoC never wires it, build() ties it off to 1 (stream unthrottled), so
    // engine-only tests that do not drive a sink are unaffected.
    final sinkReady = input('sink_ready');

    // The pull-up is simply tied on (the engine is always "connected" here).
    output('usb_pullup') <= Const(1);

    // Sub-modules: one PhyRx, one PhyTx, one UsbPacketRx, one UsbPacketTx
    // and the descriptor ROM. PhyRx framing is shared into UsbPacketRx.
    // PhyTx is driven by UsbPacketTx.
    final phyRx = HarborUsbFsPhyRx(name: 'ep0_phyrx', squelchable: true);
    addSubModule(phyRx);
    phyRx.input('clk').srcConnection! <= clk;
    phyRx.input('reset').srcConnection! <= reset;
    phyRx.input('dp').srcConnection! <= input('dp');
    phyRx.input('dm').srcConnection! <= input('dm');

    final phyTx = HarborUsbFsPhyTx(name: 'ep0_phytx');
    addSubModule(phyTx);
    phyTx.input('clk').srcConnection! <= clk;
    phyTx.input('reset').srcConnection! <= reset;

    // RX squelch: isolate the receiver from our own transmitter. On the real
    // OrangeCrab the D+/D- pads are a single BIDIRECTIONAL ball each (the
    // LoomTop inout shim: dp = oe?dp_out:host, the device always reads back the
    // resolved pad), so without this the PhyRx would self-decode every packet we
    // transmit, fire a spurious sop/pkt_done mid-TX and advance the control FSM
    // into the wrong state, after which the GET_DESCRIPTOR IN-DATA stage never
    // starts and the host reports "device descriptor read/64, error -32".
    phyRx.input('squelch').srcConnection! <= phyTx.output('tx_data_active');

    final pktRx = UsbPacketRx(name: 'ep0_pktrx', bufBytes: dfuTransferSize + 2);
    // Build-time guard: the receive buffer MUST cover a full DFU transfer block
    // plus 2 CRC bytes. If dfuTransferSize is raised without resizing the
    // buffer, the over-range write guard in UsbPacketRx silently drops tail
    // bytes and sends zeros, producing invisible firmware corruption.
    if (pktRx.bufBytes < dfuTransferSize + 2) {
      throw ArgumentError(
        'UsbEp0Engine pktRx bufBytes (${pktRx.bufBytes}) is smaller than '
        'dfuTransferSize + 2 (${dfuTransferSize + 2}); tail bytes of a '
        'DNLOAD block would be silently dropped.',
      );
    }
    addSubModule(pktRx);
    pktRx.input('clk').srcConnection! <= clk;
    pktRx.input('reset').srcConnection! <= reset;
    pktRx.input('rx_data').srcConnection! <= phyRx.output('data');
    pktRx.input('rx_valid').srcConnection! <= phyRx.output('valid');
    pktRx.input('rx_sop').srcConnection! <= phyRx.output('sop');
    pktRx.input('rx_eop').srcConnection! <= phyRx.output('eop');

    final pktTx = UsbPacketTx(name: 'ep0_pkttx');
    addSubModule(pktTx);
    pktTx.input('clk').srcConnection! <= clk;
    pktTx.input('reset').srcConnection! <= reset;

    // UsbPacketTx <-> PhyTx host handshake (the proven pacing contract).
    phyTx.input('data').srcConnection! <= pktTx.output('tx_data');
    phyTx.input('data_valid').srcConnection! <= pktTx.output('tx_data_valid');
    phyTx.input('eop_req').srcConnection! <= pktTx.output('tx_eop_req');
    pktTx.input('tx_ready').srcConnection! <= phyTx.output('ready');
    pktTx.input('tx_oe').srcConnection! <= phyTx.output('oe');

    output('dp_out') <= phyTx.output('dp_out');
    output('dm_out') <= phyTx.output('dm_out');
    output('oe') <= phyTx.output('oe');

    final rom = UsbDescriptorRom(
      name: 'ep0_rom',
      includeTestDescriptor: includeTestDescriptor,
      descriptors: descriptors,
    );
    addSubModule(rom);

    final rxPid = pktRx.output('pid');
    final rxDone = pktRx.output('pkt_done');
    final rxByteCount = pktRx.output('byte_count');
    final txDone = pktTx.output('done');
    final txBusy = pktTx.output('busy');

    final state = Logic(name: 'ep0_state', width: 5);

    // The 8 captured SETUP bytes.
    final setup = [
      for (var i = 0; i < 8; i++) Logic(name: 'setup_$i', width: 8),
    ];
    final setupValid = Logic(name: 'setup_valid_reg');
    final classSetup = Logic(name: 'class_setup_reg');

    // Status outputs.
    final devAddr = Logic(name: 'dev_addr_reg', width: 7);
    final configured = Logic(name: 'configured_reg');
    final altSetting = Logic(name: 'alt_setting_reg', width: 8);

    // Pending new device address from SET_ADDRESS, applied after IN status.
    final pendingAddr = Logic(name: 'pending_addr', width: 7);
    final addrPending = Logic(name: 'addr_pending');
    // Pending configured/alt updates, applied after their IN status completes.
    final pendingConfigured = Logic(name: 'pending_configured');
    final setConfigPending = Logic(name: 'set_config_pending');
    final pendingAlt = Logic(name: 'pending_alt', width: 8);
    final setAltPending = Logic(name: 'set_alt_pending');

    // IN-data bookkeeping.
    // Total bytes the device will return for this request = min(respLen, wLen).
    final inTotal = Logic(name: 'in_total', width: 16);
    // The DEVICE's true response length (descriptor/response byte count BEFORE
    // wLength truncation). Tracked separately from [inWLength] so we can tell a
    // transfer that ended because the device ran out of data (respTotal) from
    // one that ended because the host capped it (wLength). Only the former can
    // owe a terminating ZLP.
    final respTotal = Logic(name: 'resp_total', width: 16);
    // The host's requested wLength latched for this IN-data transfer.
    final inWLength = Logic(name: 'in_wlength', width: 16);
    // Bytes already sent across completed chunks.
    final inSent = Logic(name: 'in_sent', width: 16);
    // Current chunk's byte length (0..64).
    final chunkLen = Logic(name: 'chunk_len', width: 8);
    // Data toggle for the next DATA-stage packet (0 -> DATA0, 1 -> DATA1).
    final dataToggle = Logic(name: 'data_toggle');
    // Descriptor selection latched for IN-data ROM reads.
    final inDescType = Logic(name: 'in_desc_type', width: 8);
    final inDescIndex = Logic(name: 'in_desc_index', width: 8);
    // Source select for IN data: 0 = descriptor ROM, 1 = small internal bytes.
    final inSrcSmall = Logic(name: 'in_src_small');
    // Small internal response bytes (GET_STATUS / GET_CONFIG / GET_INTERFACE).
    final small0 = Logic(name: 'small0', width: 8);
    final small1 = Logic(name: 'small1', width: 8);
    // Source select for IN data: when high, the IN-data payload comes from the
    // DFU response array [dfuResp] instead of the descriptor ROM or small bytes.
    // Used for DFU_GETSTATUS (6 bytes) and DFU_GETSTATE (1 byte).
    final inSrcDfu = Logic(name: 'in_src_dfu');
    // DFU response byte array, up to 6 bytes (GETSTATUS payload). For GETSTATE
    // only [dfuResp[0]] is used.
    final dfuResp = [
      for (var i = 0; i < 6; i++) Logic(name: 'dfu_resp_$i', width: 8),
    ];

    // The DFU bState register (DFU 1.1 Table 4.1). Starts dfuIDLE.
    final dfuState = Logic(name: 'dfu_state_reg', width: 4);
    // wBlockNum of the DNLOAD in flight (latched from wValue at SETUP decode),
    // surfaced on sink_block while its payload streams.
    final dfuBlock = Logic(name: 'dfu_block', width: 16);
    // Latched image target (= alt_setting at dnload_done, 0 = RAM, 1 = flash).
    final imageTarget = Logic(name: 'image_target_reg', width: 8);

    final sinkData = Logic(name: 'sink_data_reg', width: 8);
    final sinkValid = Logic(name: 'sink_valid_reg');
    final dnloadDone = Logic(name: 'dnload_done_reg');
    // The number of payload bytes captured in the current OUT data packet (the
    // DNLOAD block byte count). Latched from byte_count - 2 (drop the 2 CRC
    // bytes) when the DATA packet completes.
    final dfuPayLen = Logic(name: 'dfu_pay_len', width: 8);

    // SETUP-capture walk index into the UsbPacketRx buffer. The buffer holds
    // its bytes after pkt_done (it only clears on the next rx_sop), so we can
    // read it back combinationally one byte per cycle. Widened to 8 bits in B3
    // so the same walk index can stream up to a full 64-byte DNLOAD payload
    // out the sink (the SETUP capture only uses 0..7).
    final capIdx = Logic(name: 'cap_idx', width: 8);
    pktRx.input('rd_index').srcConnection! <= capIdx;
    final rxByte = pktRx.output('rd_byte');

    // TX command strobe / latches (single-cycle send to UsbPacketTx).
    final txSend = Logic(name: 'tx_send');
    final txIsData = Logic(name: 'tx_is_data');
    final txPid = Logic(name: 'tx_pid_reg', width: 8);
    final txLen = Logic(name: 'tx_len_reg', width: 8);

    // These are null in the EP0-only (DFU) build so no dead logic is created.
    Logic? ep1OutToggle;
    Logic? ep1InToggle;
    Logic? ep1OutIdx;
    Logic? ep1OutLen;
    Logic? cmdDataReg;
    Logic? cmdValidReg;
    Logic? respReadyReg;
    Logic? cmdStartReg;
    Logic? ep1XfrOpen;
    Logic? ep1PktFull;
    Logic? ep1InAckWait;
    Logic? ep1OutRecovery;
    Logic? cmdReady;
    Logic? respData;
    Logic? respValid;
    Logic? respLast;
    // A bulk IN must return all currently-available response bytes in ONE DATA
    // packet (up to wMaxPacketSize = 64). The old path latched a SINGLE byte
    // (txLen = 1) per IN token, so the host saw a 1-byte SHORT packet and ended
    // the transfer after one byte. These hold a small 64-byte payload buffer that
    // the assembler fills by draining the resp_* stream, plus the gathered count.
    final List<Logic> ep1InBuf = [];
    Logic? ep1InCount;
    if (bulkEndpoints) {
      // Bulk DATA0/DATA1 toggles per endpoint (USB 2.0 bulk alternation).
      ep1OutToggle = Logic(name: 'ep1_out_toggle');
      ep1InToggle = Logic(name: 'ep1_in_toggle');
      // Walk index + length for streaming the captured OUT DATA payload into
      // cmd_*. The walk reuses pktRx's combinational read port via capIdx.
      ep1OutIdx = Logic(name: 'ep1_out_idx', width: 8);
      ep1OutLen = Logic(name: 'ep1_out_len', width: 8);
      cmdDataReg = Logic(name: 'cmd_data_reg', width: 8);
      cmdValidReg = Logic(name: 'cmd_valid_reg');
      respReadyReg = Logic(name: 'resp_ready_reg');
      cmdStartReg = Logic(name: 'cmd_start_reg');
      // Bulk OUT transfer boundary. A USB bulk TRANSFER that is longer than
      // wMaxPacketSize arrives as more than one packet: full-size packets,
      // then a packet that is shorter (a zero-length packet when the
      // transfer length divides by the packet size). ep1XfrOpen holds the
      // size class of the last accepted EP1 OUT packet, so it is high while
      // a transfer stays open across a packet boundary. ep1PktFull is the
      // size class of the packet that is in the pktRx buffer now: byte_count
      // holds the payload bytes plus the 2 CRC16 bytes, so a full packet
      // shows _maxPacket + 2. Together they make cmd_start mark the start of
      // a transfer instead of the start of a packet.
      ep1XfrOpen = Logic(name: 'ep1_xfr_open');
      ep1PktFull = rxByteCount
          .eq(Const(_maxPacket + 2, width: 8))
          .named('ep1_pkt_full');
      // Bulk IN ACK-wait watchdog. After we transmit an EP1 IN DATA packet we
      // wait for the host ACK in _stEp1InWaitAck. If that ACK never arrives:
      // the host gave up on this IN, the ACK was lost, or (the silicon failure
      // mode) the IN-DATA was corrupted on the bidirectional pad so the host
      // never decoded it and so never ACKs. We must NOT wait forever: a stuck
      // _stEp1InWaitAck makes the device deaf to the host's next IN token, so
      // every subsequent IN times out (the errno 110 first-read wedge). This
      // free-running counter bounds the wait. On expiry we drop back to IDLE
      // WITHOUT flipping the IN toggle, so the host's re-IN resends the same
      // byte on the toggle it still expects.
      ep1InAckWait = Logic(name: 'ep1_in_ack_wait', width: 16);
      // Recovery cooldown after an IN response: NAK EP1 OUT tokens for
      // this many cycles after leaving _stEp1InWaitAck. The ACK-wait
      // exit (ACK confirmed or non-ACK fallback) happens one cycle after
      // the packet lands. If the host's next OUT token arrives within
      // that window, the token decode can read a stale buffer or the
      // FSM can miss the transition. A short cooldown forces the host
      // to retry (the retry lands after the cooldown), which the bulk
      // protocol handles transparently. 32 cycles = ~667 ns, well under
      // the host's retry interval (the host retries after seeing the
      // NAK handshake, which takes ~10 bit times).
      ep1OutRecovery = Logic(name: 'ep1_out_recovery', width: 6);
      cmdReady = input('cmd_ready');
      respData = input('resp_data');
      respValid = input('resp_valid');
      respLast = input('resp_last');
      // 64-byte IN DATA payload buffer + the gathered byte count.
      for (var i = 0; i < _maxPacket; i++) {
        ep1InBuf.add(Logic(name: 'ep1_in_buf_$i', width: 8));
      }
      ep1InCount = Logic(name: 'ep1_in_count', width: 8);
    }

    final bmRequestType = setup[0];
    final bRequest = setup[1];
    final wValueLo = setup[2];
    final wValueHi = setup[3];
    final wLengthLo = setup[6];
    final wLengthHi = setup[7];
    final wLength = [wLengthHi, wLengthLo].swizzle();

    final dirIn = bmRequestType.slice(7, 7); // 1 = device->host (IN data)
    final reqType = bmRequestType.slice(6, 5); // 0 std, 1 class, 2 vendor
    final isStandard = reqType.eq(Const(0, width: 2));
    final hasWLength = wLength.gt(Const(0, width: 16));

    // Standard request matches.
    final isGetStatus = bRequest.eq(Const(0, width: 8));
    final isSetAddress = bRequest.eq(Const(5, width: 8));
    final isGetDescriptor = bRequest.eq(Const(6, width: 8));
    final isGetConfig = bRequest.eq(Const(8, width: 8));
    final isSetConfig = bRequest.eq(Const(9, width: 8));
    final isGetInterface = bRequest.eq(Const(10, width: 8));
    final isSetInterface = bRequest.eq(Const(11, width: 8));

    // An IN-data standard request (device returns data this transfer).
    final isInDataReq =
        isStandard &
        dirIn.eq(Const(1)) &
        hasWLength &
        (isGetDescriptor | isGetStatus | isGetConfig | isGetInterface);
    // A no-data standard request (status stage is IN, device sends ZLP DATA1).
    final isNoDataReq =
        isStandard &
        dirIn.eq(Const(0)) &
        (isSetAddress | isSetConfig | isSetInterface);

    // DFU class request decode (DFU 1.1, recipient = interface). reqType==1
    // (class). The recipient (bmRequestType[4:0]) is not enforced here: this
    // device exposes a single DFU interface, so a class request is necessarily
    // the DFU one. bRequest selects the operation.
    final isClass = reqType.eq(Const(1, width: 2));
    final isDfuDnload = bRequest.eq(Const(_dfuDnload, width: 8));
    // DFU_UPLOAD is unsupported: it falls through the class decode to the STALL
    // fallback in _stSetupAck (it is neither DNLOAD, an IN-data GETSTATUS/STATE,
    // nor a no-data CLRSTATUS/ABORT), so no explicit match signal is needed.
    final isDfuGetStatus = bRequest.eq(Const(_dfuGetStatus, width: 8));
    final isDfuClrStatus = bRequest.eq(Const(_dfuClrStatus, width: 8));
    final isDfuGetState = bRequest.eq(Const(_dfuGetState, width: 8));
    final isDfuAbort = bRequest.eq(Const(_dfuAbort, width: 8));

    // DFU_DNLOAD with a non-zero payload runs the OUT-data (host->device) phase.
    final isDfuDnloadData =
        isClass & isDfuDnload & dirIn.eq(Const(0)) & hasWLength;
    // DFU_DNLOAD with wLength==0: the END of the download (manifest).
    final isDfuDnloadEnd =
        isClass & isDfuDnload & dirIn.eq(Const(0)) & ~hasWLength;
    // DFU IN-data class requests (device returns data): GETSTATUS (6), GETSTATE
    // (1). Direction must be IN and wLength>0.
    final isDfuInData =
        isClass &
        dirIn.eq(Const(1)) &
        hasWLength &
        (isDfuGetStatus | isDfuGetState);
    // DFU no-data class requests (IN status only): CLRSTATUS, ABORT.
    final isDfuNoData =
        isClass & dirIn.eq(Const(0)) & (isDfuClrStatus | isDfuAbort);

    // ROM lookup for GET_DESCRIPTOR: response length = ROM length (already the
    // descriptor's true byte count). For the small requests the length is
    // fixed. We compute the candidate response length combinationally on the
    // captured setup so it can be latched at SETUP-decode time.
    rom.input('desc_type').srcConnection! <= wValueHi;
    rom.input('desc_index').srcConnection! <= wValueLo;

    // Compute the response length for the decoded request.
    // GET_DESCRIPTOR -> ROM length. GET_STATUS -> 2. GET_CONFIG/IF -> 1.
    final romLen = rom.output('length');
    final respLen = mux(
      isGetDescriptor,
      romLen,
      mux(
        isGetStatus,
        Const(2, width: 16),
        mux(
          // DFU_GETSTATUS returns 6 bytes.
          isClass & isDfuGetStatus,
          Const(6, width: 16),
          mux(
            // DFU_GETSTATE returns 1 byte.
            isClass & isDfuGetState,
            Const(1, width: 16),
            // GET_CONFIGURATION / GET_INTERFACE return 1 byte.
            Const(1, width: 16),
          ),
        ),
      ),
    );
    // Truncate to wLength.
    final truncLen = mux(
      respLen.gt(wLength),
      wLength,
      respLen,
    ).named('trunc_len');

    // A terminating zero-length packet (ZLP) is owed ONLY when the data stage
    // ends because the DEVICE ran out of data (respLen), that response was an
    // exact multiple of the max packet size (64), AND it was strictly shorter
    // than the host's wLength. If the stage ends because inSent reached wLength
    // (host-capped), the host already knows the transfer is over and the device
    // must NOT send a ZLP. respLen==0 cannot owe a ZLP. Computed combinationally
    // on the live decode and latched into [needZlp] at SETUP-ack time.
    final owesZlpComb =
        (respLen.lt(wLength) &
                respLen.slice(5, 0).eq(Const(0, width: 6)) &
                respLen.gt(Const(0, width: 16)))
            .named('owes_zlp');

    // IN-data payload source. UsbPacketTx drives payload_index. We present
    // payload_byte. For descriptors, byte = ROM[offset = inSent + index]. The
    // ROM offset port is shared: during IN-data the ROM's type/index come from
    // the latched descriptor selection, and the offset is the absolute byte.
    final txPayIndex = pktTx.output('payload_index');
    final absOffset = (inSent + txPayIndex.zeroExtend(16)).slice(7, 0);
    // The ROM type/index are wired from wValueHi/Lo above. During IN-data those
    // setup bytes are still latched, so they continue to select the descriptor.
    rom.input('offset').srcConnection! <= absOffset;

    // Small-source byte: index 0 -> small0, else small1 (GET_STATUS 2 bytes,
    // GET_CONFIG/IF use index 0 only).
    final smallByte = mux(txPayIndex.eq(Const(0, width: 8)), small0, small1);
    // DFU-source byte: index 0..5 -> dfuResp[0..5] (GETSTATUS 6 bytes, GETSTATE
    // uses index 0 only).
    Logic dfuByte = Const(0, width: 8);
    for (var i = 0; i < 6; i++) {
      dfuByte = mux(txPayIndex.eq(Const(i, width: 8)), dfuResp[i], dfuByte);
    }
    // Source priority: DFU array, else small bytes, else descriptor ROM.
    final ep0PayloadByte = mux(
      inSrcDfu,
      dfuByte,
      mux(inSrcSmall, smallByte, rom.output('data')),
    );
    // When the bulk IN endpoint is sending its DATA packet, the payload byte is
    // the assembled IN buffer byte selected by the TX engine's payload_index
    // (the multi-byte packet the gather state built). Otherwise the EP0
    // control-IN source above.
    final Logic payloadByte;
    if (bulkEndpoints) {
      // Indexed read of the 64-byte IN buffer by the current payload byte index,
      // built as a BALANCED binary mux TREE (depth log2(64)=6) rather than a
      // linear 64-deep mux chain. The linear chain was the place-and-route
      // critical path (it pushed Fmax below the 48 MHz USB clock). The balanced
      // tree selects on one index bit per level, so its delay is ~6 muxes. The
      // index width is 8 (payload_index), only the low 6 bits address 64 slots.
      var level = <Logic>[for (final b in ep1InBuf) b];
      var bit = 0;
      while (level.length > 1) {
        final sel = txPayIndex.slice(bit, bit);
        final next = <Logic>[];
        for (var i = 0; i < level.length; i += 2) {
          // Pair (i, i+1): sel bit picks the odd (i+1) over the even (i). With
          // _maxPacket a power of two there is always a pair.
          next.add(mux(sel, level[i + 1], level[i]));
        }
        level = next;
        bit++;
      }
      final ep1InBufByte = level[0];
      payloadByte = mux(
        state.eq(Const(_stEp1InData, width: 5)),
        ep1InBufByte,
        ep0PayloadByte,
      );
    } else {
      payloadByte = ep0PayloadByte;
    }
    pktTx.input('payload_byte').srcConnection! <= payloadByte;

    pktTx.input('send').srcConnection! <= txSend;
    pktTx.input('is_data').srcConnection! <= txIsData;
    pktTx.input('pid').srcConnection! <= txPid;
    pktTx.input('payload_len').srcConnection! <= txLen;

    // Remaining bytes still to send for the IN-data transfer.
    final remaining = (inTotal - inSent).named('in_remaining');
    // Next chunk length = min(remaining, 64).
    final nextChunk = mux(
      remaining.gt(Const(_maxPacket, width: 16)),
      Const(_maxPacket, width: 8),
      remaining.slice(7, 0),
    ).named('next_chunk');
    // "A terminating ZLP is still owed for this transfer." Latched from
    // [owesZlpComb] at SETUP-ack time (a property of respLen vs wLength, NOT of
    // any individual chunk), and cleared once the ZLP has actually been sent.
    // The data stage keeps going while bytes remain OR needZlp is set. When both
    // are exhausted the stage ends. This correctly suppresses the spurious ZLP
    // that the old per-chunk "last chunk was 64" heuristic produced when the
    // host capped wLength at an exact multiple of 64.
    final needZlp = Logic(name: 'need_zlp');

    // A USB token packet carries 2 payload bytes after the PID: byte0 =
    // addr[6:0] | endp[0]<<7. The pktRx read port is combinational on capIdx.
    // capIdx is held at 0 the whole time the FSM is in IDLE (see the IDLE
    // CaseItem), so rxByte already presents the token's payload byte 0. This
    // device exposes only EP0 and EP1, so endp[0] (bit 7 of byte 0)
    // disambiguates them. (A stale capIdx would mis-decode this: the IDLE
    // hold-at-0 is the fix for the intermittent -71 routing bug.)
    final tokEndp0 = rxByte.slice(7, 7);
    // Token device-address field (byte0 bits[6:0]). Gates ONLY EP1 bulk routing.
    final tokAddrMatch = filterByAddress
        ? rxByte.slice(6, 0).eq(devAddr).named('tok_addr_match')
        : Const(1);

    // USB BUS RESET (SE0 held >= PHY resetTicks). The host drives a bus reset
    // before EVERY enumeration attempt and on every retry. USB 2.0 (7.1.7.5 +
    // 9.1.1.6) REQUIRES the device to return to the Default state on a bus
    // reset: address -> 0, NOT configured, all control/endpoint state cleared,
    // data toggles cleared. The PHY (HarborUsbLineRx) already detects SE0 and
    // exposes bus_reset (a registered LEVEL held high while SE0 is past the
    // threshold), and HarborUsbFsPhyRx passes it straight through.
    //
    // We fold it into the FSM's reset arm as a SYNCHRONOUS USB-protocol reset
    // ALONGSIDE the FPGA `reset`. Treating it as a level that holds the
    // protocol state in its Default/IDLE values for the whole SE0 window (and
    // releases when the host stops driving SE0) is exactly the spec behaviour
    // and is glitch-safe (an isolated SE0 cannot trip it, it is gated by the
    // PHY's resetTicks counter). The PHY sub-modules themselves are NOT reset by
    // it (they must keep running to observe the END of SE0). Only the
    // higher-level protocol/endpoint state is.
    //
    // Without this, the engine carried stale state (a non-zero devAddr, a
    // mid-control-transfer FSM state, stale data toggles, configured=1) across
    // the host's reset+retry cycles, which is the root cause of the real
    // hardware "device descriptor read/64, error -32" (STALL) and "device not
    // accepting address N, error -71" enumeration failures: the device kept
    // answering its OLD address (or none) after the host bus-reset it back to
    // address 0. (The old lenient sim never drove a bus reset, so it never
    // caught this.)
    final busReset = phyRx.output('bus_reset');
    // Synchronous protocol reset: FPGA reset OR a USB bus reset. The control
    // FSM, address, configured flag, data toggles, pending SET_* side effects,
    // DFU state and (when present) the EP1 bulk endpoint state all snap back to
    // their Default-state values on either.
    final protoReset = (reset | busReset).named('proto_reset');

    Sequential(clk, [
      If(
        protoReset,
        then: [
          state < Const(_stIdle, width: 5),
          for (final s in setup) s < Const(0, width: 8),
          setupValid < Const(0),
          classSetup < Const(0),
          devAddr < Const(0, width: 7),
          configured < Const(0),
          altSetting < Const(0, width: 8),
          pendingAddr < Const(0, width: 7),
          addrPending < Const(0),
          pendingConfigured < Const(0),
          setConfigPending < Const(0),
          pendingAlt < Const(0, width: 8),
          setAltPending < Const(0),
          inTotal < Const(0, width: 16),
          respTotal < Const(0, width: 16),
          inWLength < Const(0, width: 16),
          inSent < Const(0, width: 16),
          chunkLen < Const(0, width: 8),
          dataToggle < Const(0),
          inDescType < Const(0, width: 8),
          inDescIndex < Const(0, width: 8),
          inSrcSmall < Const(0),
          small0 < Const(0, width: 8),
          small1 < Const(0, width: 8),
          txSend < Const(0),
          txIsData < Const(0),
          txPid < Const(0, width: 8),
          txLen < Const(0, width: 8),
          needZlp < Const(0),
          capIdx < Const(0, width: 8),
          // DFU / sink reset.
          inSrcDfu < Const(0),
          for (final d in dfuResp) d < Const(0, width: 8),
          dfuState < Const(_dfuIDLE, width: 4),
          dfuBlock < Const(0, width: 16),
          imageTarget < Const(0, width: 8),
          sinkData < Const(0, width: 8),
          sinkValid < Const(0),
          dnloadDone < Const(0),
          dfuPayLen < Const(0, width: 8),
          // EP1 bulk reset (only present when bulkEndpoints).
          if (bulkEndpoints) ...[
            ep1OutToggle! < Const(0),
            ep1InToggle! < Const(0),
            ep1OutIdx! < Const(0, width: 8),
            ep1OutLen! < Const(0, width: 8),
            cmdDataReg! < Const(0, width: 8),
            cmdValidReg! < Const(0),
            respReadyReg! < Const(0),
            cmdStartReg! < Const(0),
            // No transfer is open after a reset or a bus reset, so the first
            // packet that follows starts a new command.
            ep1XfrOpen! < Const(0),
            ep1InAckWait! < Const(0, width: 16),
            ep1OutRecovery! < Const(0, width: 6),
            // EP1-IN packet assembler.
            ep1InCount! < Const(0, width: 8),
            for (final b in ep1InBuf) b < Const(0, width: 8),
          ],
        ],
        orElse: [
          // txSend, classSetup, sinkValid and dnloadDone are single-cycle
          // strobes. Self-clear each cycle.
          txSend < Const(0),
          classSetup < Const(0),
          sinkValid < Const(0),
          dnloadDone < Const(0),
          // EP1 bulk single-cycle strobes self-clear each cycle.
          if (bulkEndpoints) ...[
            cmdValidReg! < Const(0),
            respReadyReg! < Const(0),
            cmdStartReg! < Const(0),
          ],

          // GLOBAL SETUP catch (USB 2.0 ch9): the host may begin a NEW control
          // transfer by sending a SETUP token in ANY state. If a packet
          // completes with PID == SETUP we abort whatever transfer is in flight
          // and restart from the state that waits for the SETUP DATA0 (the same
          // path IDLE takes). This is the high-priority override: it wins over
          // the per-state Case below by wrapping it in an else-arm, so the two
          // can never double-assign the same register on this cycle.
          //
          // It cannot corrupt the SETUP capture that follows: this fires only on
          // the SETUP TOKEN packet (pid 0x2D). The DATA0 that carries the 8
          // setup bytes has pid 0xC3, so the catch is inert for it and the
          // normal _stSetupData -> _stSetupCapture path runs untouched.
          If(
            rxDone & rxPid.eq(Const(_pidSetup, width: 8)),
            then: [
              // Restart the control transfer.
              state < Const(_stSetupData, width: 5),
              // Clear all in-flight transfer state so a half-done previous
              // transfer cannot leak into the new one. The new SETUP fully
              // abandons the prior request (incl. any pending SET_* side effect
              // whose status stage never completed).
              inSent < Const(0, width: 16),
              inTotal < Const(0, width: 16),
              respTotal < Const(0, width: 16),
              inWLength < Const(0, width: 16),
              chunkLen < Const(0, width: 8),
              dataToggle < Const(0),
              needZlp < Const(0),
              capIdx < Const(0, width: 8),
              addrPending < Const(0),
              setConfigPending < Const(0),
              setAltPending < Const(0),
              // Clear any DFU-transfer-in-flight state too: a new SETUP mid-DNLOAD
              // abandons the captured OUT-data payload and its source select. The
              // persistent dfuState is left untouched (a SETUP does not reset the
              // DFU state machine: only CLRSTATUS/ABORT/manifest do).
              inSrcDfu < Const(0),
              dfuPayLen < Const(0, width: 8),
            ],
            orElse: [
              Case(state, [
                CaseItem(Const(_stIdle, width: 5), [
                  // Hold the buffer-walk index at 0 the whole time we are in IDLE so
                  // the EP1 token-endpoint decode (tokEndp0 = rxByte[7]) always reads
                  // the token's payload byte 0. A SETUP capture walks capIdx to 7 and
                  // the normal return-to-IDLE paths below re-zero it. This belt-and-
                  // suspenders hold guarantees a correct token decode even if some
                  // path forgot to (the intermittent -71 routing bug).
                  if (bulkEndpoints) capIdx < Const(0, width: 8),
                  // Decrement the OUT recovery cooldown (if armed).
                  if (bulkEndpoints) ...[
                    If(
                      ~ep1OutRecovery!.eq(Const(0, width: 6)),
                      then: [
                        ep1OutRecovery < ep1OutRecovery! - Const(1, width: 6),
                      ],
                    ),
                  ],
                  If(
                    rxDone,
                    then: [
                      If(
                        rxPid.eq(Const(_pidSetup, width: 8)),
                        then: [
                          // SETUP token -> wait for the DATA0 setup packet.
                          state < Const(_stSetupData, width: 5),
                        ],
                        orElse: [
                          // EP1 BULK token routing (only when bulkEndpoints). An IN/OUT
                          // token whose endpoint field selects EP1 enters the bulk path.
                          // EP0 IN/OUT only occur inside a control transfer, so a stray
                          // EP0 IN/OUT at IDLE is ignored.
                          if (bulkEndpoints) ...[
                            If(
                              rxPid.eq(Const(_pidIn, width: 8)) &
                                  tokEndp0.eq(Const(1)) &
                                  tokAddrMatch,
                              then: [
                                // Bulk IN: if the cmd engine has a response byte ready,
                                // GATHER all currently-available response bytes into one
                                // DATA packet (a bulk IN must return up to wMaxPacketSize
                                // bytes in a SINGLE DATA packet, a 1-byte short packet
                                // ends the host transfer prematurely). If no byte is
                                // ready, NAK. The IN DATA toggle picks DATA0/DATA1.
                                If(
                                  respValid!,
                                  then: [
                                    // A response byte is available: GATHER the whole response
                                    // into the IN buffer before sending one DATA packet. The
                                    // cmd engine presents resp_data COMBINATIONALLY
                                    // (byte[count]) and holds it until it sees resp_ready, so
                                    // the gather drives a continuously-held resp_ready and
                                    // captures one fresh byte per cycle. Enter the gather
                                    // state with the slot index at 0.
                                    ep1InCount! < Const(0, width: 8),
                                    state < Const(_stEp1InGather, width: 5),
                                  ],
                                  orElse: [
                                    txSend < Const(1),
                                    txIsData < Const(0),
                                    txPid < Const(_pidNak, width: 8),
                                    txLen < Const(0, width: 8),
                                    state < Const(_stEp1Nak, width: 5),
                                  ],
                                ),
                              ],
                            ),
                            If(
                              rxPid.eq(Const(_pidOut, width: 8)) &
                                  tokEndp0.eq(Const(1)) &
                                  tokAddrMatch,
                              then: [
                                If(
                                  ~ep1OutRecovery!.eq(Const(0, width: 6)),
                                  then: [
                                    // Bulk OUT during the recovery cooldown
                                    // after an IN response: NAK so the host
                                    // retries after the cooldown expires. The
                                    // retry lands with the FSM fully settled.
                                    txSend < Const(1),
                                    txIsData < Const(0),
                                    txPid < Const(_pidNak, width: 8),
                                    txLen < Const(0, width: 8),
                                    state < Const(_stEp1Nak, width: 5),
                                  ],
                                  orElse: [
                                    // Bulk OUT: await the DATA packet carrying the command.
                                    state < Const(_stEp1OutData, width: 5),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                      // Any other packet at idle (stray IN/OUT/ACK) is ignored.
                    ],
                  ),
                ]),

                CaseItem(Const(_stSetupData, width: 5), [
                  If(
                    rxDone,
                    then: [
                      If(
                        rxPid.eq(Const(_pidData0, width: 8)),
                        then: [
                          // Begin the 8-byte snapshot walk: drive rd_index from 0 and
                          // latch one byte per cycle in _stSetupCapture.
                          capIdx < Const(0, width: 8),
                          state < Const(_stSetupCapture, width: 5),
                        ],
                        orElse: [
                          // Unexpected packet: bail back to idle.
                          state < Const(_stIdle, width: 5),
                        ],
                      ),
                    ],
                  ),
                ]),

                // SETUP capture: rd_index = capIdx selects buffer byte capIdx
                // combinationally, latch rxByte into setup[capIdx] and advance.
                // After byte 7 is latched, ACK and move on.
                CaseItem(Const(_stSetupCapture, width: 5), [
                  // Latch the byte the buffer is presenting for the current capIdx.
                  // (rd_index was driven from capIdx last cycle / this cycle, the read
                  // port is combinational so rxByte already reflects capIdx.)
                  for (var i = 0; i < 8; i++)
                    If(
                      capIdx.eq(Const(i, width: 8)),
                      then: [setup[i] < rxByte],
                    ),
                  If(
                    capIdx.eq(Const(7, width: 8)),
                    then: [
                      setupValid < Const(1),
                      // Reply ACK to close the SETUP stage.
                      txSend < Const(1),
                      txIsData < Const(0),
                      txPid < Const(_pidAck, width: 8),
                      txLen < Const(0, width: 8),
                      state < Const(_stSetupAck, width: 5),
                    ],
                    orElse: [capIdx < capIdx + 1],
                  ),
                ]),

                // SETUP ACK: wait for the handshake to finish, then branch on the
                // decoded request. The decode signals are combinational on `setup`,
                // which is now latched.
                CaseItem(Const(_stSetupAck, width: 5), [
                  If(
                    txDone,
                    then: [
                      // Flag a class/vendor SETUP for B3 (strobe). Standard requests
                      // proceed, unsupported ones STALL.
                      If(~isStandard, then: [classSetup < Const(1)]),
                      If(
                        isInDataReq | isDfuInData,
                        then: [
                          // Prepare an IN data transfer (standard OR DFU GETSTATUS/STATE).
                          inSent < Const(0, width: 16),
                          inTotal < truncLen.zeroExtend(16),
                          // Latch the true response length and wLength separately so the
                          // data-stage end can tell "device ran out of data" from "host
                          // capped wLength" (only the former owes a ZLP).
                          respTotal < respLen,
                          inWLength < wLength,
                          // First DATA-stage packet is DATA1.
                          dataToggle < Const(1),
                          // Owe a terminating ZLP iff the device data is a non-zero exact
                          // multiple of 64 AND strictly shorter than the host's wLength.
                          needZlp < owesZlpComb,
                          // Source select + descriptor latch. DFU GETSTATUS/GETSTATE use
                          // the DFU response array, otherwise descriptor ROM or small.
                          If(
                            isDfuInData,
                            then: [
                              inSrcDfu < Const(1),
                              inSrcSmall < Const(0),
                              // DFU_GETSTATUS: bStatus=0(OK), bwPollTimeout=0 (3 LE bytes),
                              // bState=current dfuState, iString=0.
                              // DFU_GETSTATE: byte0 = current dfuState.
                              If(
                                isDfuGetStatus,
                                then: [
                                  dfuResp[0] <
                                      Const(0, width: 8), // bStatus = OK
                                  dfuResp[1] <
                                      Const(
                                        0,
                                        width: 8,
                                      ), // bwPollTimeout LE [0]
                                  dfuResp[2] <
                                      Const(
                                        0,
                                        width: 8,
                                      ), // bwPollTimeout LE [1]
                                  dfuResp[3] <
                                      Const(
                                        0,
                                        width: 8,
                                      ), // bwPollTimeout LE [2]
                                  dfuResp[4] < dfuState.zeroExtend(8), // bState
                                  dfuResp[5] < Const(0, width: 8), // iString
                                ],
                                orElse: [
                                  // DFU_GETSTATE
                                  dfuResp[0] < dfuState.zeroExtend(8),
                                  for (var i = 1; i < 6; i++)
                                    dfuResp[i] < Const(0, width: 8),
                                ],
                              ),
                            ],
                            orElse: [
                              inSrcDfu < Const(0),
                              If(
                                isGetDescriptor,
                                then: [
                                  inSrcSmall < Const(0),
                                  inDescType < wValueHi,
                                  inDescIndex < wValueLo,
                                ],
                                orElse: [
                                  inSrcSmall < Const(1),
                                  // GET_STATUS -> 0x0000, GET_CONFIG -> configured, GET_IF ->
                                  // alt. Lay out into small0/small1.
                                  If(
                                    isGetStatus,
                                    then: [
                                      small0 < Const(0, width: 8),
                                      small1 < Const(0, width: 8),
                                    ],
                                    orElse: [
                                      If(
                                        isGetConfig,
                                        then: [
                                          small0 < configured.zeroExtend(8),
                                        ],
                                        orElse: [
                                          // GET_INTERFACE
                                          small0 < altSetting,
                                        ],
                                      ),
                                      small1 < Const(0, width: 8),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                          state < Const(_stInWaitToken, width: 5),
                        ],
                        orElse: [
                          If(
                            isNoDataReq | isDfuNoData,
                            then: [
                              // Latch the pending side effects, apply AFTER status stage.
                              If(
                                isSetAddress,
                                then: [
                                  pendingAddr < wValueLo.slice(6, 0),
                                  addrPending < Const(1),
                                ],
                              ),
                              If(
                                isSetConfig,
                                then: [
                                  pendingConfigured < Const(1),
                                  setConfigPending < Const(1),
                                ],
                              ),
                              If(
                                isSetInterface,
                                then: [
                                  pendingAlt < wValueLo,
                                  setAltPending < Const(1),
                                ],
                              ),
                              // DFU CLRSTATUS / ABORT both return the state machine to
                              // dfuIDLE (CLRSTATUS additionally clears any error). Applied
                              // immediately. The IN status stage just acknowledges.
                              If(
                                isDfuClrStatus | isDfuAbort,
                                then: [dfuState < Const(_dfuIDLE, width: 4)],
                              ),
                              state < Const(_stInStatusToken, width: 5),
                            ],
                            orElse: [
                              If(
                                isDfuDnloadData,
                                then: [
                                  // DFU_DNLOAD with payload: run the OUT-data phase. Latch the
                                  // block number (wValue) for the sink, capture wLength as the
                                  // expected byte count.
                                  dfuBlock < [wValueHi, wValueLo].swizzle(),
                                  inWLength < wLength,
                                  state < Const(_stOutDataToken, width: 5),
                                ],
                                orElse: [
                                  If(
                                    isDfuDnloadEnd,
                                    then: [
                                      // Zero-length DNLOAD = end of the image. Run the manifest
                                      // sequence: dfuMANIFEST_SYNC -> dfuMANIFEST, then pulse
                                      // dnload_done and latch image_target = alt_setting, and
                                      // return to dfuIDLE. Collapsed here into a single step
                                      // (the host polls GETSTATUS to observe progress, a
                                      // manifest-tolerant device may complete promptly).
                                      dnloadDone < Const(1),
                                      imageTarget < altSetting,
                                      dfuState < Const(_dfuIDLE, width: 4),
                                      // No data stage: go straight to the IN status stage.
                                      state < Const(_stInStatusToken, width: 5),
                                    ],
                                    orElse: [
                                      // Unsupported (incl. DFU_UPLOAD) / vendor: STALL.
                                      state < Const(_stStall, width: 5),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stInWaitToken, width: 5), [
                  If(
                    rxDone,
                    then: [
                      If(
                        rxPid.eq(Const(_pidIn, width: 8)),
                        then: [
                          // Launch a DATA packet with this chunk.
                          chunkLen < nextChunk,
                          txSend < Const(1),
                          txIsData < Const(1),
                          txPid <
                              mux(
                                dataToggle,
                                Const(_pidData1, width: 8),
                                Const(_pidData0, width: 8),
                              ),
                          txLen < nextChunk,
                          state < Const(_stInSendData, width: 5),
                        ],
                      ),
                      // An unexpected packet here is ignored (host will retry IN).
                    ],
                  ),
                ]),

                CaseItem(Const(_stInSendData, width: 5), [
                  If(
                    txDone,
                    then: [
                      // Account for the bytes just sent. NOTE: the data toggle is NOT
                      // flipped here. It is flipped only AFTER the host ACK is confirmed
                      // (in _stInWaitAck), so a lost/garbled ACK that rewinds and
                      // resends this chunk re-sends it with the SAME toggle the host
                      // expects (Important #3). Flipping early made the retry carry the
                      // wrong toggle and a real host would reject the duplicate forever.
                      inSent < inSent + chunkLen.zeroExtend(16),
                      // If we just sent the terminating ZLP (a 0-length chunk), the ZLP
                      // debt is paid. Clear it so the next ACK ends the stage.
                      If(
                        chunkLen.eq(Const(0, width: 8)),
                        then: [needZlp < Const(0)],
                      ),
                      state < Const(_stInWaitAck, width: 5),
                    ],
                  ),
                ]),

                CaseItem(Const(_stInWaitAck, width: 5), [
                  If(
                    rxDone,
                    then: [
                      If(
                        rxPid.eq(Const(_pidAck, width: 8)),
                        then: [
                          // ACK confirmed: NOW flip the data toggle for the next chunk
                          // (Important #3: deferring the flip to here keeps a resent
                          // chunk on the correct toggle if an earlier ACK was lost).
                          dataToggle < ~dataToggle,
                          // Continue while bytes remain OR a terminating ZLP is still
                          // owed, otherwise the data stage is complete.
                          If(
                            remaining.gt(Const(0, width: 16)) | needZlp,
                            then: [state < Const(_stInWaitToken, width: 5)],
                            orElse: [
                              // IN data done -> OUT status stage.
                              state < Const(_stOutStatus, width: 5),
                            ],
                          ),
                        ],
                        orElse: [
                          // A NAK/lost/garbled ACK: resend the SAME chunk. Rewind inSent
                          // by the chunk we just (advanced for and) sent, and leave
                          // dataToggle untouched so the resent chunk carries the original
                          // toggle the host still expects.
                          inSent < inSent - chunkLen.zeroExtend(16),
                          state < Const(_stInWaitToken, width: 5),
                        ],
                      ),
                    ],
                  ),
                ]),

                // OUT status (after IN data): wait for the zero-length OUT DATA,
                // then ACK. We accept the OUT token then the DATA1. The simplest
                // robust approach is to ACK on the DATA packet completion.
                CaseItem(Const(_stOutStatus, width: 5), [
                  If(
                    rxDone,
                    then: [
                      // The host sends OUT token then a zero-length DATA1. ACK once we
                      // see the DATA packet (PID DATA1/DATA0). Ignore the bare token.
                      If(
                        rxPid.eq(Const(_pidData1, width: 8)) |
                            rxPid.eq(Const(_pidData0, width: 8)),
                        then: [
                          txSend < Const(1),
                          txIsData < Const(0),
                          txPid < Const(_pidAck, width: 8),
                          txLen < Const(0, width: 8),
                          state < Const(_stOutStatusAck, width: 5),
                        ],
                      ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stOutStatusAck, width: 5), [
                  If(
                    txDone,
                    then: [
                      setupValid < Const(0),
                      state < Const(_stIdle, width: 5),
                    ],
                  ),
                ]),

                CaseItem(Const(_stInStatusToken, width: 5), [
                  If(
                    rxDone,
                    then: [
                      If(
                        rxPid.eq(Const(_pidIn, width: 8)),
                        then: [
                          txSend < Const(1),
                          txIsData < Const(1),
                          txPid < Const(_pidData1, width: 8),
                          txLen < Const(0, width: 8),
                          state < Const(_stInStatusData, width: 5),
                        ],
                      ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stInStatusData, width: 5), [
                  If(txDone, then: [state < Const(_stInStatusAck, width: 5)]),
                ]),

                CaseItem(Const(_stInStatusAck, width: 5), [
                  If(
                    rxDone,
                    then: [
                      If(
                        rxPid.eq(Const(_pidAck, width: 8)),
                        then: [
                          // The status stage is complete: NOW apply pending side effects.
                          If(
                            addrPending,
                            then: [
                              devAddr < pendingAddr,
                              addrPending < Const(0),
                            ],
                          ),
                          If(
                            setConfigPending,
                            then: [
                              configured < pendingConfigured,
                              setConfigPending < Const(0),
                            ],
                          ),
                          If(
                            setAltPending,
                            then: [
                              altSetting < pendingAlt,
                              setAltPending < Const(0),
                            ],
                          ),
                          setupValid < Const(0),
                          state < Const(_stIdle, width: 5),
                        ],
                      ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stOutDataToken, width: 5), [
                  If(
                    rxDone,
                    then: [
                      // Wait for the OUT token (PID 0xE1). Any other packet is ignored
                      // (a re-tried token, or a stray IN). The global SETUP catch above
                      // handles an aborting SETUP.
                      If(
                        rxPid.eq(Const(_pidOut, width: 8)),
                        then: [state < Const(_stOutDataPkt, width: 5)],
                      ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stOutDataPkt, width: 5), [
                  If(
                    rxDone,
                    then: [
                      // The DATA packet (DATA1 first, then toggling, PID 0x4B/0xC3)
                      // carries the payload. byte_count = payload + 2 CRC bytes.
                      If(
                        rxPid.eq(Const(_pidData1, width: 8)) |
                            rxPid.eq(Const(_pidData0, width: 8)),
                        then: [
                          // Payload byte count = byte_count - 2 (drop the trailing CRC).
                          // Guard the subtraction: a malformed <2-byte packet yields 0.
                          If(
                            pktRx.output('byte_count').gt(Const(2, width: 8)),
                            then: [
                              dfuPayLen <
                                  (pktRx.output('byte_count') -
                                      Const(2, width: 8)),
                              // Begin the sink-stream walk from byte 0.
                              capIdx < Const(0, width: 8),
                              state < Const(_stSinkStream, width: 5),
                            ],
                            orElse: [
                              // No payload bytes: nothing to stream, just ACK.
                              dfuPayLen < Const(0, width: 8),
                              txSend < Const(1),
                              txIsData < Const(0),
                              txPid < Const(_pidAck, width: 8),
                              txLen < Const(0, width: 8),
                              state < Const(_stOutDataAck, width: 5),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ]),

                // Stream the captured payload out the sink, one byte per cycle. The
                // UsbPacketRx read port is combinational on rd_index (= capIdx), so
                // rxByte already presents payload[capIdx]. Emit it on sink_data with
                // a sink_valid pulse, tagged with the current DNLOAD block on
                // sink_block. Advance until the last byte, then ACK the DATA packet.
                CaseItem(Const(_stSinkStream, width: 5), [
                  // Present the current payload byte. B1: only PUSH it (pulse
                  // sink_valid) and advance the walk while the sink can accept it
                  // (sink_ready high). When sink_ready is low we HOLD this byte (no
                  // valid pulse, no advance, no ACK) until the sink drains and ready
                  // returns, making the stream self-pacing and the sink FIFO unable to
                  // overflow. (sink_valid self-clears each cycle in the strobe block.)
                  sinkData < rxByte,
                  If(
                    sinkReady,
                    then: [
                      sinkValid < Const(1),
                      If(
                        capIdx.eq((dfuPayLen - Const(1, width: 8))),
                        then: [
                          // Last payload byte streamed: ACK the OUT DATA packet.
                          txSend < Const(1),
                          txIsData < Const(0),
                          txPid < Const(_pidAck, width: 8),
                          txLen < Const(0, width: 8),
                          state < Const(_stOutDataAck, width: 5),
                        ],
                        orElse: [capIdx < capIdx + 1],
                      ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stOutDataAck, width: 5), [
                  If(
                    txDone,
                    then: [
                      // The OUT data stage is acknowledged. A DNLOAD block landed, so
                      // the DFU state advances to dfuDNLOAD_IDLE. Then run the IN status
                      // stage (host IN token -> device ZLP DATA1 -> host ACK).
                      dfuState < Const(_dfuDNLOAD_IDLE, width: 4),
                      state < Const(_stInStatusToken, width: 5),
                    ],
                  ),
                ]),

                CaseItem(Const(_stStall, width: 5), [
                  // Issue the STALL once (guard with ~busy so we don't re-fire).
                  If(
                    ~txBusy & ~txDone,
                    then: [
                      txSend < Const(1),
                      txIsData < Const(0),
                      txPid < Const(_pidStall, width: 8),
                      txLen < Const(0, width: 8),
                    ],
                  ),
                  If(
                    txDone,
                    then: [
                      setupValid < Const(0),
                      state < Const(_stIdle, width: 5),
                    ],
                  ),
                ]),

                // EP1 BULK endpoint states (only present when bulkEndpoints). The
                // capIdx hold-at-0 in IDLE keeps the token decode honest. These
                // states re-use pktRx's combinational read port (rd_index = capIdx)
                // to walk the OUT DATA payload into the cmd stream, and drive a
                // single-byte IN DATA packet from the latched response byte.
                if (bulkEndpoints) ...[
                  // EP1 OUT: receive the DATA packet, ACK PROMPTLY, then drain.
                  // The previous design streamed the payload into cmd_* byte-by-byte
                  // and only ACKed AFTER the last byte was accepted. That coupled the
                  // host-visible ACK to cmd_ready: if the cmd engine ever held
                  // cmd_ready low (busy on a Wishbone access) the ACK was delayed or
                  // never sent, and on real xHCI hardware a bulk OUT with no prompt
                  // handshake is HALTed by the host (the EPIPE/STALL the user saw -
                  // the device wedged in this state with no ACK/NAK). USB requires a
                  // bulk OUT DATA to be answered with ACK/NAK within the packet
                  // turnaround, INDEPENDENT of downstream backpressure.
                  //
                  // Fix: as soon as a valid OUT DATA packet (CRC-good, correct toggle)
                  // is in the pktRx buffer, send the ACK IMMEDIATELY (it does not
                  // depend on cmd_ready), then move to _stEp1OutDrain to walk the
                  // captured payload into cmd_* at the cmd engine's own pace. The
                  // pktRx buffer holds the payload until the next rx_sop, and a host
                  // only issues its next token AFTER it has seen our ACK, so the
                  // buffer is stable for the whole drain.
                  CaseItem(Const(_stEp1OutData, width: 5), [
                    If(
                      rxDone,
                      then: [
                        If(
                          rxPid.eq(Const(_pidData1, width: 8)) |
                              rxPid.eq(Const(_pidData0, width: 8)),
                          then: [
                            // Payload byte count = byte_count - 2 (drop the 2 CRC bytes).
                            If(
                              rxByteCount.gt(Const(2, width: 8)),
                              then: [
                                ep1OutLen! < (rxByteCount - Const(2, width: 8)),
                                capIdx < Const(0, width: 8),
                                ep1OutIdx! < Const(0, width: 8),
                              ],
                              orElse: [
                                // Zero-payload OUT DATA: nothing to drain.
                                ep1OutLen < Const(0, width: 8),
                                capIdx < Const(0, width: 8),
                                ep1OutIdx < Const(0, width: 8),
                              ],
                            ),
                            // ACK now (independent of cmd_ready) and advance the OUT
                            // toggle. Then drain the captured payload into cmd_*.
                            ep1OutToggle! < ~ep1OutToggle,
                            txSend < Const(1),
                            txIsData < Const(0),
                            txPid < Const(_pidAck, width: 8),
                            txLen < Const(0, width: 8),
                            // Pulse cmd_start: a fresh command has arrived. The command
                            // engine must preempt any response still in flight (e.g. a
                            // multi-byte READ the host only partially drained) so it is
                            // back to accepting bytes (cmd_ready high) before we reach
                            // _stEp1OutDrain. Without this, a busy engine holds cmd_ready
                            // low forever and the drain deadlocks (the OUT-after-partial-
                            // read wedge).
                            //
                            // cmd_start marks the start of a bulk TRANSFER, not the
                            // start of a packet. A command frame that is longer than
                            // wMaxPacketSize arrives as more than one packet, and a
                            // packet that comes after a full-size packet CONTINUES the
                            // command that is open. A pulse on such a packet tells the
                            // command engine to drop the parse state of the command it
                            // is reading, which silently loses every byte after the
                            // first packet.
                            //
                            // The preempt above stays intact: the FIRST packet of every
                            // new command still pulses, because the last packet of the
                            // command before it was short or zero-length, which clears
                            // ep1XfrOpen. Only continuation packets are quiet, and there
                            // the command in flight IS the one the engine is parsing, so
                            // there is no stale response to drop and no deadlock.
                            //
                            // A host that ends a transfer whose length is an exact
                            // multiple of wMaxPacketSize must send the terminating
                            // zero-length packet, as USB requires. Without it the next
                            // command looks like a continuation.
                            cmdStartReg! < ~ep1XfrOpen!,
                            ep1XfrOpen < ep1PktFull!,
                            state < Const(_stEp1OutAck, width: 5),
                          ],
                        ),
                      ],
                    ),
                  ]),
                  CaseItem(Const(_stEp1OutAck, width: 5), [
                    If(
                      txDone,
                      then: [
                        // ACK sent. If there is payload, drain it into cmd_*, else done.
                        If(
                          ep1OutLen.gt(Const(0, width: 8)),
                          then: [state < Const(_stEp1OutDrain, width: 5)],
                          orElse: [state < Const(_stIdle, width: 5)],
                        ),
                      ],
                    ),
                  ]),
                  // EP1 OUT drain: walk the captured payload (held in the pktRx
                  // buffer) into cmd_*, one byte per cmd_ready handshake. The ACK has
                  // already been sent, so any backpressure here only paces the cmd
                  // engine. It can never delay a handshake or wedge the endpoint.
                  //
                  // The byte and its valid are driven COMBINATIONALLY from the
                  // current capIdx (see the output wiring below), mirroring the
                  // resp_data pattern on the response side: the byte at capIdx is
                  // presented for as long as the command engine has not consumed
                  // it, and the indexes advance only on an actual consumption
                  // (cmd_ready, with valid implied by the drain state itself).
                  // The command engine dips cmd_ready for one cycle between its
                  // header collect and its data stage (the DISPATCH state). The
                  // previous design pulsed a REGISTERED valid one cycle after
                  // each cmd_ready sample and advanced the index on the same
                  // sample: a byte offered during a not-ready cycle was dropped
                  // and the index skipped past it, so every WRITE command lost
                  // a data byte and the command engine then waited forever for
                  // a byte that never came (the write never reached the bus,
                  // and the next OUT packet found the endpoint still draining:
                  // no handshake, host halt, EPIPE). A held combinational offer
                  // makes the handshake a real valid/ready contract: no byte is
                  // lost, none is duplicated.
                  CaseItem(Const(_stEp1OutDrain, width: 5), [
                    If(
                      cmdReady!,
                      then: [
                        If(
                          (ep1OutIdx + Const(1, width: 8)).eq(ep1OutLen),
                          then: [
                            // Last payload byte consumed -> back to idle.
                            state < Const(_stIdle, width: 5),
                          ],
                          orElse: [
                            ep1OutIdx < ep1OutIdx + 1,
                            capIdx < capIdx + 1,
                          ],
                        ),
                      ],
                    ),
                  ]),

                  // EP1 IN GATHER: drain all currently-available response bytes
                  // into the IN payload buffer, then send ONE DATA packet. A bulk IN
                  // must return up to wMaxPacketSize (64) bytes in a single DATA
                  // packet. The old 1-byte-per-IN path produced a short packet that
                  // ended the host transfer after one byte.
                  //
                  // Handshake: a standard valid/ready drain. The cmd engine presents
                  // resp_data COMBINATIONALLY (byte[count]) and HOLDS each byte until it
                  // sees resp_ready, advancing the next cycle. resp_ready is driven
                  // COMBINATIONALLY for this state (output wiring: resp_ready =
                  // respReadyReg | (gather & resp_valid)) so the cmd engine samples it
                  // the SAME cycle we capture. It advances next cycle and presents the
                  // next byte, captured next cycle. A registered ready would lag and the
                  // engine would still hold the same byte, duplicating it. We latch each
                  // offered byte into the buffer. On the cycle resp_last is high (the
                  // engine offering its final byte) we send the assembled DATA packet
                  // (txLen = bytes gathered). Across a multi-WORD read resp_valid drops
                  // while the engine fetches the next word. The combinational resp_ready
                  // falls with it and we just do not capture until the next byte is
                  // offered. resp_valid==0 is NOT the end. resp_last is. We also stop at
                  // the 64-byte (wMaxPacketSize) ceiling.
                  CaseItem(Const(_stEp1InGather, width: 5), [
                    If(
                      respValid!,
                      then: [
                        // Latch the offered byte into the current buffer slot.
                        for (var i = 0; i < _maxPacket; i++)
                          If(
                            ep1InCount!.eq(Const(i, width: 8)),
                            then: [ep1InBuf[i] < respData!],
                          ),
                        If(
                          respLast! |
                              ep1InCount!.eq(Const(_maxPacket - 1, width: 8)),
                          then: [
                            // Last byte (or final buffer slot): send the assembled DATA
                            // packet. txLen = count + 1 = number of bytes gathered.
                            txSend < Const(1),
                            txIsData < Const(1),
                            txPid <
                                mux(
                                  ep1InToggle!,
                                  Const(_pidData1, width: 8),
                                  Const(_pidData0, width: 8),
                                ),
                            txLen < (ep1InCount + Const(1, width: 8)),
                            state < Const(_stEp1InData, width: 5),
                          ],
                          orElse: [
                            // More bytes to come: advance the slot. The combinational
                            // resp_ready keeps the next byte coming each cycle.
                            ep1InCount < ep1InCount + Const(1, width: 8),
                          ],
                        ),
                      ],
                    ),
                  ]),

                  CaseItem(Const(_stEp1InData, width: 5), [
                    If(
                      txDone,
                      then: [
                        // Start the ACK-wait watchdog fresh for this IN DATA packet.
                        ep1InAckWait! < Const(0, width: 16),
                        state < Const(_stEp1InWaitAck, width: 5),
                      ],
                    ),
                  ]),
                  CaseItem(Const(_stEp1InWaitAck, width: 5), [
                    If(
                      rxDone,
                      then: [
                        If(
                          rxPid.eq(Const(_pidAck, width: 8)),
                          then: [
                            // ACK confirmed: flip the IN toggle for the next IN DATA.
                            ep1InToggle < ~ep1InToggle,
                            ep1OutRecovery! < Const(32, width: 6),
                            state < Const(_stIdle, width: 5),
                          ],
                          orElse: [
                            // Not an ACK. This is almost always the host's ACK
                            // itself arriving garbled (a bit-recovery slip at
                            // the TX->RX turnaround: the ACK PID 0xD2 shifted
                            // by one bit reads as the IN PID 0x69), or the
                            // OUT token of the host's next command after a
                            // turnaround miss. In both stories the host
                            // received our data and its ACK is simply
                            // invisible to us: assume the ACK happened, flip
                            // the toggle so the data toggles stay in sync,
                            // and drop to IDLE. Do NOT re-send the packet:
                            // an unsolicited transmit right after the host
                            // acknowledged is a babble the host will halt
                            // the endpoint for. The token consumed here is
                            // re-issued by the host (an OUT with no
                            // handshake is retried), so the command flow
                            // survives at the cost of one retry.
                            ep1InToggle < ~ep1InToggle,
                            ep1OutRecovery! < Const(32, width: 6),
                            state < Const(_stIdle, width: 5),
                          ],
                        ),
                      ],
                      orElse: [
                        // No packet yet: bound the wait. If the host's ACK never comes
                        // (it gave up, the ACK was lost, or (the silicon failure) our
                        // IN-DATA was corrupted on the bidirectional pad so the host
                        // never decoded it and never ACKs), DO NOT stay deaf here: a
                        // stuck _stEp1InWaitAck ignores the host's next IN token and
                        // every following IN times out (the errno 110 wedge). On timeout
                        // fall back to IDLE WITHOUT flipping the toggle so the next IN
                        // re-emits the same byte. The window is generous (a real ACK
                        // returns within a couple of bit-times) so this never fires on a
                        // healthy transfer.
                        If(
                          ep1InAckWait.lt(Const(0xFFFF, width: 16)),
                          then: [
                            ep1InAckWait < ep1InAckWait + Const(1, width: 16),
                          ],
                          orElse: [state < Const(_stIdle, width: 5)],
                        ),
                      ],
                    ),
                  ]),
                  CaseItem(Const(_stEp1Nak, width: 5), [
                    If(txDone, then: [state < Const(_stIdle, width: 5)]),
                  ]),
                ],
              ]),
            ],
          ), // close the global-SETUP-catch else-arm.
        ],
      ),
    ]);

    output('dev_addr') <= devAddr;
    output('configured') <= configured;
    output('alt_setting') <= altSetting;
    output('bus_reset') <= busReset;
    output('class_setup') <= classSetup;
    output('setup_valid') <= setupValid;
    for (var i = 0; i < 8; i++) {
      output('setup$i') <= setup[i];
    }

    output('sink_data') <= sinkData;
    output('sink_valid') <= sinkValid;
    output('sink_block') <= dfuBlock;
    output('dnload_done') <= dnloadDone;
    output('image_target') <= imageTarget;
    output('dfu_state') <= dfuState;

    if (bulkEndpoints) {
      // cmd_data / cmd_valid: COMBINATIONAL during the EP1 OUT drain (the
      // byte at the current capIdx, held until consumed), the idle registers
      // (constant 0) otherwise. See the drain state comment for why the offer
      // must be combinational and held.
      output('cmd_data') <=
          mux(state.eq(Const(_stEp1OutDrain, width: 5)), rxByte, cmdDataReg!);
      output('cmd_valid') <=
          mux(
            state.eq(Const(_stEp1OutDrain, width: 5)),
            Const(1),
            cmdValidReg!,
          );
      // resp_ready: the registered handshake strobe (used by the OUT-drain path)
      // OR a COMBINATIONAL accept while gathering an IN packet. The gather term
      // must be combinational so the cmd engine (which holds each resp_data byte
      // until it sees ready, advancing the next cycle) advances in lockstep with
      // our per-cycle capture. A registered ready would lag and duplicate bytes.
      // We accept only while resp_valid so we never assert ready into a between-
      // words gap.
      final gatherAccept =
          (state.eq(Const(_stEp1InGather, width: 5)) & respValid!).named(
            'ep1_in_gather_accept',
          );
      output('resp_ready') <= respReadyReg! | gatherAccept;
      output('cmd_start') <= cmdStartReg!;
    }
  }

  @override
  Future<void> build() async {
    // B1: if the SoC did not wire the back-pressure input, tie it to 1 so the
    // engine streams unthrottled (the historical behaviour). Connections are
    // resolved after construction but before build, so this is the right place
    // to detect an undriven sink_ready. When a real sink IS wired, this leaves
    // the external driver untouched.
    // input('sink_ready') is the engine-internal receiver. Its srcConnection is
    // the port-level Logic, whose own srcConnection is the EXTERNAL driver (null
    // when the SoC left it unwired).
    final portLogic = input('sink_ready').srcConnection;
    if (portLogic == null || portLogic.srcConnection == null) {
      port('sink_ready').tieOff(value: 1);
    }
    // resp_last MUST be driven by the command engine when the bulk endpoints are
    // present: the EP1-IN packet assembler uses it to know the response is
    // exhausted and stop gathering. Loom's LoomUsbCmdEngine drives it. The
    // tie-off below only guards the (untested) case where a caller enables bulk
    // endpoints but leaves resp_last unwired, so connection resolution does not
    // fail at build. A real consumer always wires it.
    if (bulkEndpoints) {
      final rl = input('resp_last').srcConnection;
      if (rl == null || rl.srcConnection == null) {
        port('resp_last').tieOff(value: 0);
      }
    }
    await super.build();
  }
}

/// B4: DFU firmware-image RAM sink.
///
/// Consumes the [UsbEp0Engine] firmware-byte SINK stream (48 MHz USB domain)
/// and DMA-writes the whole image into RAM over a Wishbone B4 MASTER bus
/// (12 MHz sys / bus domain). When the complete image has landed it raises a
/// one-cycle [image_ready] strobe and holds [entry_addr] = [loadBase].
///
/// This module is the RAM half of the DFU back-end: it only acts when
/// `alt_setting == 0` (RAM). When the target is anything else (1 = SPI flash,
/// handled by B5) it stays idle and never touches the bus. The gate is
/// `alt_setting` (the engine's SET_INTERFACE alt, stable for the whole transfer),
/// NOT `image_target`. The engine only latches `image_target` at `dnload_done`
/// (it reads 0/RAM during streaming), so gating on it would push flash bytes into
/// RAM. `image_target` is an observability-only input here (see its port comment).
/// The engine and this sink are wired together at SoC level in B6. Here the
/// sink's USB-domain stream inputs are taken as plain inputs.
///
/// Back-pressure: the engine's sink stream is paced 1 byte/USB-clk, faster than
/// the bus drains, so the sink drives `sink_ready` (= NOT FIFO-almost-full,
/// margin 2 = the engine->FIFO in-flight latency) back to the engine, which HOLDS
/// the byte when low. This makes overflow impossible. A sticky `overflow` output
/// surfaces any drop as belt-and-suspenders (should never fire).
///
/// Clock-domain crossing
/// The sink stream arrives in the 48 MHz USB domain but the bus runs in the
/// 12 MHz sys domain, so every stream element is funneled through a
/// [HarborCdcFifo] of width `dataWidth = 9`: bits [7:0] carry a payload byte
/// and bit 8 is an "is_done_marker" flag. On each `sink_valid` (and only when
/// `alt_setting == 0`) a byte entry `{0, sink_data}` is pushed. On
/// `dnload_done` (RAM target) a marker entry `{1, 0x00}` is pushed. Because
/// both pushes go through the SAME FIFO they keep their relative order, so the
/// bus side is guaranteed to see every image byte BEFORE the done marker.
///
/// Bus write strategy
/// Byte-at-a-time. Each payload byte popped from the FIFO is written with a
/// standard Wishbone single write: the byte is replicated/placed into its lane
/// of `dat_mosi`, `sel` carries a one-hot byte-lane mask selecting that lane,
/// `adr` is the word-aligned address of the byte (`loadBase + (offset &
/// ~(bytesPerWord-1))`), and cyc+stb+we are asserted until `ack`. This sidesteps
/// the partial-final-word accumulation problem entirely: the final (possibly
/// partial) word is just a run of single-byte writes whose `sel` masks the live
/// lanes, so there is never a half-formed word to flush. The running byte
/// offset increments by one per acked write and drives both the address and the
/// lane.
///
/// On the done marker reaching the bus side (after all preceding bytes have
/// been acked, which the in-order FIFO guarantees), [image_ready] pulses for one
/// bus-clock cycle with the bus idle.
class UsbDfuRamSink extends BridgeModule {
  /// The RAM load address that image byte 0 is written to.
  final int loadBase;

  /// Wishbone address bus width.
  final int busAddressWidth;

  /// Wishbone data bus width (8, 16, 32 or 64).
  final int busDataWidth;

  /// Depth of the CDC FIFO (power of two). Must comfortably exceed the largest
  /// uninterrupted byte burst the USB side can push before the slower bus side
  /// drains it. The USB engine streams at most one DFU transfer block (64 bytes
  /// for this device) back-to-back between control-transfer turnarounds, so the
  /// default of 128 holds a full block with margin and the FIFO never overflows
  /// in normal DNLOAD traffic. If it ever did fill, a push would be silently
  /// dropped (the engine has no back-pressure path), corrupting the image, so
  /// this is sized conservatively rather than minimally.
  final int fifoDepth;

  /// Number of byte lanes on the bus.
  int get bytesPerWord => busDataWidth ~/ 8;

  UsbDfuRamSink({
    this.loadBase = 0x80000000,
    this.busAddressWidth = 32,
    this.busDataWidth = 32,
    this.fifoDepth = 128,
    String? name,
  }) : super('UsbDfuRamSink', name: name ?? 'usb_dfu_ram_sink') {
    if (![8, 16, 32, 64].contains(busDataWidth)) {
      throw ArgumentError(
        'busDataWidth must be one of [8,16,32,64], got '
        '$busDataWidth',
      );
    }
    if (busAddressWidth < 1 || busAddressWidth > 64) {
      throw ArgumentError('busAddressWidth out of range: $busAddressWidth');
    }
    if (loadBase < 0 || loadBase >= (BigInt.one << busAddressWidth).toInt()) {
      throw ArgumentError(
        'loadBase 0x${loadBase.toRadixString(16)} does not '
        'fit in $busAddressWidth address bits',
      );
    }
    if (fifoDepth < 2 || (fifoDepth & (fifoDepth - 1)) != 0) {
      throw ArgumentError('fifoDepth must be a power of two >= 2');
    }

    final selWidth = bytesPerWord;
    // Log2 of bytesPerWord: how many low address bits are the in-word byte
    // offset (0 for an 8-bit bus).
    var wordShift = 0;
    for (var v = bytesPerWord; v > 1; v >>= 1) {
      wordShift++;
    }

    // NOTE on clock domains (B6 wiring): `usb_clk` MUST be the SAME 48 MHz USB
    // clock the engine runs on, because the gating/handshake signals below
    // (`alt_setting`, `sink_valid`, `dnload_done`, and the `sink_ready` we drive
    // back) are all engine USB-domain signals consumed/produced combinationally
    // here with no synchronizer. Crossing to the slower bus domain happens only
    // inside the CDC FIFO. Wiring `usb_clk` to anything other than the engine's
    // 48 MHz domain would make `sink_ready` an unsynchronized cross-domain
    // signal and break the back-pressure contract.
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('sink_data', PortDirection.input, width: 8);
    createPort('sink_valid', PortDirection.input);
    createPort('dnload_done', PortDirection.input);
    // OBSERVABILITY-ONLY: deliberately NOT used to gate the RAM push (the engine
    // latches it only at dnload_done, reading 0/RAM during streaming). Gate on
    // `alt_setting` below instead. Do not re-wire this into the push path (B2).
    createPort('image_target', PortDirection.input, width: 8);
    // The current SET_INTERFACE alternate setting from the engine (0 = RAM,
    // 1 = SPI flash). Unlike `image_target` (which the engine only latches at
    // dnload_done), `alt_setting` is STABLE for the whole transfer, so it is
    // the correct signal to gate the RAM push on (B2). Same USB clock domain as
    // `usb_clk`, so no synchronizer is needed.
    createPort('alt_setting', PortDirection.input, width: 8);

    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);

    final busRef = addInterface(
      WishboneInterface(
        WishboneConfig(addressWidth: busAddressWidth, dataWidth: busDataWidth),
      ),
      name: 'bus',
      role: PairRole.provider, // master
    );
    final bus = busRef.internalInterface!;

    addOutput('image_ready');
    addOutput('entry_addr', width: busAddressWidth);
    addOutput('bytes_written', width: 32);

    // sink_ready (USB domain): the engine may push a byte/marker only while this
    // is high. It deasserts when the FIFO is within a small margin of full, so
    // the in-flight pushes the engine has already committed to cannot overflow.
    addOutput('sink_ready');
    // overflow (USB domain, sticky): set if a push was ever attempted while the
    // FIFO was full (a dropped byte/marker). With back-pressure in place this
    // must never fire. It is a belt-and-suspenders observability latch so a drop
    // is never silent.
    addOutput('overflow');

    final usbClk = input('usb_clk');
    final usbReset = input('usb_reset');
    final busClk = input('bus_clk');
    final busReset = input('bus_reset');

    final sinkData = input('sink_data');
    final sinkValid = input('sink_valid');
    final dnloadDone = input('dnload_done');
    final altSetting = input('alt_setting');

    // CDC FIFO: width 9 = {is_done_marker, byte[7:0]}. Pushed in the USB
    // domain, drained in the bus domain. Only RAM-targeted streams enter the
    // FIFO. A non-RAM target leaves this module entirely idle.
    // B2: gate on alt_setting (STABLE for the whole transfer), NOT image_target
    // (which the engine only latches at dnload_done, it reads 0/RAM during the
    // streaming of a FLASH download, so gating on it would wrongly push flash
    // bytes into RAM). alt_setting == 0 means the RAM interface is selected.
    final isRam = altSetting.eq(Const(0, width: 8));
    // almostFullMargin = 2: when sink_ready drops the engine has at most one
    // already-committed push left (it holds on the next USB edge), so two free
    // entries are enough to guarantee no overflow.
    final fifo = HarborCdcFifo(
      name: 'sink_fifo',
      dataWidth: 9,
      depth: fifoDepth,
      almostFullMargin: 2,
    );
    addSubModule(fifo);

    // A push happens on a byte (sink_valid) or a done marker (dnload_done),
    // gated by the RAM target. The marker entry carries bit8=1, data=0.
    final pushByte = sinkValid & isRam;
    final pushDone = dnloadDone & isRam;
    final wrEn = pushByte | pushDone;
    // Engine invariant (documented + sim-checked below): sink_valid (a payload
    // byte) and dnload_done (its own zero-length DNLOAD) are produced on
    // distinct cycles and never coincide, so a push is never both a byte and a
    // marker at once. A ROHD simulation assertion enforces it during sim.
    final bothPush = (pushByte & pushDone).named('both_push_invariant');
    bothPush.changed.listen((e) {
      assert(
        !(e.newValue.isValid && e.newValue.toBool()),
        'UsbDfuRamSink: pushByte & pushDone asserted simultaneously - the '
        'engine sink_valid/dnload_done never-coincide invariant was violated',
      );
    });
    // If a byte and the done marker ever coincided we would lose one. They are
    // distinct cycles in the engine (dnload_done is its own zero-length DNLOAD,
    // never simultaneous with a payload byte), so a simple priority is safe:
    // prefer the byte, since data must precede the marker.
    final isDoneEntry = pushDone & ~pushByte;
    final wrData = [isDoneEntry, sinkData].swizzle(); // {marker, byte}

    fifo.input('wr_clk').srcConnection! <= usbClk;
    fifo.input('wr_reset').srcConnection! <= usbReset;
    fifo.input('wr_data').srcConnection! <= wrData;
    fifo.input('wr_en').srcConnection! <= wrEn;

    fifo.input('rd_clk').srcConnection! <= busClk;
    fifo.input('rd_reset').srcConnection! <= busReset;

    // sink_ready = NOT almost-full: deassert when fewer than the margin of free
    // entries remain so the engine's in-flight pushes can't overflow.
    final fifoAlmostFull = fifo.output('wr_almost_full');
    output('sink_ready') <= ~fifoAlmostFull;
    // Sticky overflow: latch high if a push is ever attempted while the FIFO is
    // genuinely full. With back-pressure this can never happen. It surfaces a
    // would-be silent drop. Lives in the USB (write) clock domain.
    final fifoFull = fifo.output('wr_full');
    final overflowReg = Logic(name: 'overflow_reg');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [overflowReg < Const(0)],
        orElse: [
          If(fifoFull & wrEn, then: [overflowReg < Const(1)]),
        ],
      ),
    ]);
    output('overflow') <= overflowReg;

    final fifoEmpty = fifo.output('rd_empty');
    final fifoRdData = fifo.output('rd_data'); // first-word-fall-through
    final fifoByte = fifoRdData.slice(7, 0);
    final fifoIsDone = fifoRdData.slice(8, 8);

    // Bus write FSM (bus domain). Single-write-at-a-time, byte granular.
    const stIdle = 0; // FIFO empty / waiting for the next entry.
    const stWrite = 1; // driving a Wishbone single write, waiting for ack.
    const stPop = 2; // pop the FIFO entry just consumed (1-cyc rd_en pulse).
    const stDone = 3; // image fully written: pulse image_ready, then idle.

    final fsm = Logic(name: 'sink_fsm', width: 2);
    final byteOff = Logic(name: 'byte_off', width: 32); // running byte offset

    // Master drive registers.
    final cycReg = Logic(name: 'cyc_reg');
    final stbReg = Logic(name: 'stb_reg');
    final weReg = Logic(name: 'we_reg');
    final adrReg = Logic(name: 'adr_reg', width: busAddressWidth);
    final datReg = Logic(name: 'dat_reg', width: busDataWidth);
    final selReg = Logic(name: 'sel_reg', width: selWidth);
    final rdEnReg = Logic(name: 'rd_en_reg');
    final readyReg = Logic(name: 'image_ready_reg');

    // Combinational geometry for the byte currently at the FIFO head.
    // Lane = byteOff mod bytesPerWord, word-aligned address = loadBase +
    // (byteOff & ~(bytesPerWord-1)).
    final laneSel = bytesPerWord == 1
        ? Const(0, width: 1)
        : byteOff.slice(wordShift - 1, 0);
    // One-hot byte-lane select mask.
    Logic selMask = Const(1, width: selWidth);
    if (selWidth > 1) {
      selMask = (Const(1, width: selWidth) << laneSel.zeroExtend(selWidth))
          .named('sel_mask');
    }
    // Byte placed in its lane of the data word.
    final laneShiftBits = (laneSel.zeroExtend(32) * Const(8, width: 32)).named(
      'lane_shift_bits',
    );
    final datPlaced = bytesPerWord == 1
        ? fifoByte
        : (fifoByte.zeroExtend(busDataWidth) <<
                  laneShiftBits.slice(busDataWidth.bitLength - 1, 0))
              .named('dat_placed');
    // Word-aligned absolute address. byteOff is a 32-bit running offset. The
    // address arithmetic is done at the bus address width so a 64-bit address
    // bus (RV64 SoCs) does not over-slice a 32-bit constant. The offset is
    // zero-extended (or truncated) to the bus width before adding loadBase.
    final wordBase32 = bytesPerWord == 1
        ? byteOff
        : [byteOff.slice(31, wordShift), Const(0, width: wordShift)].swizzle();
    final wordBase = busAddressWidth >= 32
        ? wordBase32.zeroExtend(busAddressWidth)
        : wordBase32.slice(busAddressWidth - 1, 0);
    final adrNext = (Const(loadBase, width: busAddressWidth) + wordBase).named(
      'adr_next',
    );

    Sequential(busClk, [
      If(
        busReset,
        then: [
          fsm < Const(stIdle, width: 2),
          byteOff < Const(0, width: 32),
          cycReg < Const(0),
          stbReg < Const(0),
          weReg < Const(0),
          adrReg < Const(0, width: busAddressWidth),
          datReg < Const(0, width: busDataWidth),
          selReg < Const(0, width: selWidth),
          rdEnReg < Const(0),
          readyReg < Const(0),
        ],
        orElse: [
          // image_ready and rd_en are single-cycle strobes.
          readyReg < Const(0),
          rdEnReg < Const(0),
          Case(fsm, [
            CaseItem(Const(stIdle, width: 2), [
              If(
                ~fifoEmpty,
                then: [
                  If(
                    fifoIsDone.eq(Const(1)),
                    then: [
                      // Done marker reached the head with all bytes already written.
                      // Pop it and finish.
                      rdEnReg < Const(1),
                      fsm < Const(stDone, width: 2),
                    ],
                    orElse: [
                      // Launch a single byte write for the head entry.
                      cycReg < Const(1),
                      stbReg < Const(1),
                      weReg < Const(1),
                      adrReg < adrNext,
                      datReg < datPlaced,
                      selReg < (selWidth == 1 ? Const(1, width: 1) : selMask),
                      fsm < Const(stWrite, width: 2),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(stWrite, width: 2), [
              If(
                bus.ack,
                then: [
                  // Transfer accepted: drop the strobes, advance the byte offset,
                  // and pop the consumed FIFO entry.
                  cycReg < Const(0),
                  stbReg < Const(0),
                  weReg < Const(0),
                  byteOff < byteOff + Const(1, width: 32),
                  rdEnReg < Const(1),
                  fsm < Const(stPop, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(stPop, width: 2), [
              // rd_en pulsed last cycle. The FIFO head now presents the next
              // entry. Return to idle to classify it.
              fsm < Const(stIdle, width: 2),
            ]),
            CaseItem(Const(stDone, width: 2), [
              // The done marker was popped. The whole image is in RAM and the bus
              // is idle. Pulse image_ready and go back to idle for any next image.
              readyReg < Const(1),
              fsm < Const(stIdle, width: 2),
            ]),
          ]),
        ],
      ),
    ]);

    bus.cyc <= cycReg;
    bus.stb <= stbReg;
    bus.we <= weReg;
    bus.adr <= adrReg;
    bus.datMosi <= datReg;
    bus.sel <= selReg;
    // datMiso / ack are consumer (slave->master) inputs. ack is read above.

    fifo.input('rd_en').srcConnection! <= rdEnReg;

    output('image_ready') <= readyReg;
    output('entry_addr') <= Const(loadBase, width: busAddressWidth);
    output('bytes_written') <= byteOff;
  }
}

/// B5b: programs the DFU firmware-byte sink stream into SPI flash by driving the
/// B5a write/erase engine on a [HarborSpiFlashController].
///
/// This is the flash analog of [UsbDfuRamSink] (B4). It takes the same USB-domain
/// sink stream from [UsbEp0Engine] (`sink_data`/`sink_valid` (one byte/cycle),
/// `dnload_done` (image complete) and `alt_setting`) but instead of doing
/// Wishbone single-byte writes into RAM it accumulates the image into a 256-byte
/// PAGE buffer and drives the flash controller's write command interface
/// (`wr_req`/`wr_op`/`wr_addr`/`wr_len` + the `wr_data`/`wr_data_index`
/// read-callback) to ERASE and PAGE-PROGRAM the image at `flashBase`.
///
/// Target gating
/// The DFU device exposes alt setting 0 = RAM and alt setting 1 = SPI flash. This
/// sink is gated on `alt_setting == 1`: when a different (RAM) target is selected
/// it stays FULLY IDLE: nothing enters the FIFO, `wr_req` never asserts, `busy`
/// stays low. (B4's [UsbDfuRamSink] gates on `alt_setting == 0` symmetrically, so
/// exactly one of the two consumes any given download.)
///
/// Clock-domain crossing
/// The sink stream arrives in the 48 MHz USB domain. The flash controller's write
/// engine runs in the bus/sys (e.g. 12 MHz) domain. Every stream element crosses
/// through a [HarborCdcFifo] of width 9 = {is_done_marker, byte[7:0]}, exactly
/// like B4: on each `sink_valid` (and only when `alt_setting == 1`) a byte entry
/// `{0, sink_data}` is pushed. On `dnload_done` a marker entry `{1, 0x00}` is
/// pushed. Both go through the SAME FIFO so the bus side sees every image byte
/// BEFORE the done marker. `sink_ready` = NOT almost-full (margin 2) provides the
/// engine back-pressure: the flash side is FAR slower than the USB stream (a
/// sector erase plus the WIP poll is hundreds of bus cycles), so the FIFO fills
/// and `sink_ready` drops, stalling the producer exactly as the real DFU host
/// waits on GETSTATUS dfuDNBUSY between blocks (the busy->bwPollTimeout coupling
/// is wired in B6).
///
/// Erase-as-you-go + page-program sequencing
/// A bus-domain FSM:
///  1. FILL: pop FIFO bytes into the page buffer at `fillCount` (0..255),
///     incrementing `fillCount`. The flush of the accumulated page is triggered
///     when EITHER the buffer reaches the next 256-byte page boundary (the write
///     address `flashBase + bytesWritten + fillCount` becomes page-aligned) OR
///     the done marker reaches the FIFO head (final, possibly partial page). The
///     done marker is NOT popped until the final flush completes.
///  2. ERASE-AS-YOU-GO: the first time the current write address falls in a NEW
///     4 KB sector, a sector-erase (`wr_op=0`) is issued for that sector BEFORE
///     any byte of it is programmed. The last-erased sector index is tracked so
///     each sector is erased exactly once (16 pages share one erase).
///  3. PROGRAM: a page-program (`wr_op=1`) of the `fillCount` buffered bytes at
///     the page start address. Because the flush is forced at every 256-byte page
///     boundary, a program never crosses a page (which B5a would reject with
///     `wr_err`). The page buffer feeds `wr_data` combinationally at the engine's
///     `wr_data_index`.
///  4. Each `wr_req` is HELD until the engine accepts it (`wr_busy` rises), then
///     the FSM waits for the one-cycle `wr_done`. `busy` is held high for the
///     whole erase+program (so B6 can map it to dfuDNBUSY/bwPollTimeout).
///  5. On the done marker reaching the bus side AND the final partial page being
///     programmed, `image_ready` pulses for one bus cycle.
///  6. `wr_err` (page-cross, zero-len, WIP-timeout) latches into the sticky
///     `error` output and STOPS further programming (the FSM parks).
class UsbDfuFlashSink extends BridgeModule {
  /// The flash byte offset the image's byte 0 is written at (e.g. a Weir image
  /// region). Must be sector-aligned for the erase-as-you-go bookkeeping to be
  /// exact (a non-aligned base would erase the sector the base falls in, which
  /// also clears bytes below the base: asserted against at build time).
  final int flashBase;

  /// Flash sector size in bytes (erase granularity, typically 4096). Pulled from
  /// the controller's config when constructed via [fromController].
  final int sectorSize;

  /// Flash page size in bytes (program granularity, typically 256). Pulled from
  /// the controller's config when constructed via [fromController].
  final int pageSize;

  /// Width of the flash write-address bus (`wr_addr`), = addressBytes*8 (24 or
  /// 32). Pulled from the controller's config (`addressBytes`).
  final int addrWidth;

  /// Depth of the CDC FIFO (power of two >= 2). Sized to absorb the USB burst
  /// while the slow flash side drains it. 128 holds a full DFU block with margin.
  final int fifoDepth;

  /// Build a flash sink whose sector/page/address geometry is taken from a
  /// [HarborSpiFlashController]'s config, so the two cannot drift.
  factory UsbDfuFlashSink.fromController(
    HarborSpiFlashController controller, {
    required int flashBase,
    int fifoDepth = 128,
    String? name,
  }) => UsbDfuFlashSink(
    flashBase: flashBase,
    sectorSize: controller.config.sectorSize,
    pageSize: controller.config.pageSize,
    addrWidth: controller.config.addressBytes * 8,
    fifoDepth: fifoDepth,
    name: name,
  );

  UsbDfuFlashSink({
    required this.flashBase,
    this.sectorSize = 4096,
    this.pageSize = 256,
    this.addrWidth = 24,
    this.fifoDepth = 128,
    String? name,
  }) : super('UsbDfuFlashSink', name: name ?? 'usb_dfu_flash_sink') {
    if (pageSize != 256) {
      // The page buffer / fillCount counter and the 256-byte boundary math are
      // built for a 256-byte page (the universal SPI NOR page). A different page
      // size would need a re-parameterized counter width and boundary mask.
      throw ArgumentError(
        'UsbDfuFlashSink only supports a 256-byte page, got '
        '$pageSize',
      );
    }
    if (sectorSize <= 0 || (sectorSize & (sectorSize - 1)) != 0) {
      throw ArgumentError('sectorSize must be a power of two, got $sectorSize');
    }
    if (sectorSize < pageSize) {
      throw ArgumentError(
        'sectorSize ($sectorSize) must be >= pageSize '
        '($pageSize)',
      );
    }
    if (addrWidth != 24 && addrWidth != 32) {
      throw ArgumentError('addrWidth must be 24 or 32, got $addrWidth');
    }
    if (flashBase < 0 || flashBase >= (BigInt.one << addrWidth).toInt()) {
      throw ArgumentError(
        'flashBase 0x${flashBase.toRadixString(16)} does not '
        'fit in $addrWidth address bits',
      );
    }
    if (flashBase % sectorSize != 0) {
      throw ArgumentError(
        'flashBase 0x${flashBase.toRadixString(16)} must be '
        'sector-aligned (sectorSize=$sectorSize) so erase-as-you-go does not '
        'clear bytes below the image',
      );
    }
    if (fifoDepth < 2 || (fifoDepth & (fifoDepth - 1)) != 0) {
      throw ArgumentError('fifoDepth must be a power of two >= 2');
    }

    // log2(sectorSize): the number of low address bits inside a sector. The
    // sector index is the address with those low bits dropped.
    var sectorShift = 0;
    for (var v = sectorSize; v > 1; v >>= 1) {
      sectorShift++;
    }

    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('sink_data', PortDirection.input, width: 8);
    createPort('sink_valid', PortDirection.input);
    createPort('dnload_done', PortDirection.input);
    // The current SET_INTERFACE alternate setting (0 = RAM, 1 = SPI flash).
    // STABLE for the whole transfer, so it is the correct gate (B4 documents
    // why image_target, latched only at dnload_done, must NOT be used). Same USB
    // clock domain, so no synchronizer needed.
    createPort('alt_setting', PortDirection.input, width: 8);

    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);

    // Flash write-engine command interface (drives HarborSpiFlashController,
    // B5a). Bus domain.
    addOutput('wr_req');
    addOutput('wr_op'); // 0 = sector-erase, 1 = page-program
    addOutput('wr_addr', width: addrWidth);
    addOutput('wr_len', width: 9); // 1..256 program bytes
    addOutput('wr_data', width: 8); // page-buffer byte at wr_data_index
    createPort('wr_data_index', PortDirection.input, width: 9);
    createPort('wr_busy', PortDirection.input);
    createPort('wr_done', PortDirection.input);
    createPort('wr_err', PortDirection.input);

    addOutput('image_ready'); // 1-cyc pulse when the whole image is programmed
    addOutput('busy'); // high while erasing/programming (feeds B6 dfuDNBUSY)
    addOutput('error'); // sticky: wr_err OR FIFO overflow
    addOutput('bytes_written', width: 32);

    addOutput('sink_ready');
    addOutput('overflow');

    final usbClk = input('usb_clk');
    final usbReset = input('usb_reset');
    final busClk = input('bus_clk');
    final busReset = input('bus_reset');

    final sinkData = input('sink_data');
    final sinkValid = input('sink_valid');
    final dnloadDone = input('dnload_done');
    final altSetting = input('alt_setting');

    // CDC FIFO: width 9 = {is_done_marker, byte[7:0]}. Only FLASH-targeted
    // streams enter. A non-flash target leaves this module entirely idle.
    // alt_setting == 1 selects the SPI-flash interface (B4 uses == 0 for RAM).
    final isFlash = altSetting.eq(Const(1, width: 8));
    final fifo = HarborCdcFifo(
      name: 'sink_fifo',
      dataWidth: 9,
      depth: fifoDepth,
      almostFullMargin: 2,
    );
    addSubModule(fifo);

    final pushByte = sinkValid & isFlash;
    final pushDone = dnloadDone & isFlash;
    final wrEn = pushByte | pushDone;
    // Engine invariant (same as B4): a payload byte and the zero-length DNLOAD
    // done marker are produced on distinct cycles. Sim-checked.
    final bothPush = (pushByte & pushDone).named('both_push_invariant');
    bothPush.changed.listen((e) {
      assert(
        !(e.newValue.isValid && e.newValue.toBool()),
        'UsbDfuFlashSink: pushByte & pushDone asserted simultaneously - the '
        'engine sink_valid/dnload_done never-coincide invariant was violated',
      );
    });
    final isDoneEntry = pushDone & ~pushByte;
    final wrData = [isDoneEntry, sinkData].swizzle(); // {marker, byte}

    fifo.input('wr_clk').srcConnection! <= usbClk;
    fifo.input('wr_reset').srcConnection! <= usbReset;
    fifo.input('wr_data').srcConnection! <= wrData;
    fifo.input('wr_en').srcConnection! <= wrEn;
    fifo.input('rd_clk').srcConnection! <= busClk;
    fifo.input('rd_reset').srcConnection! <= busReset;

    final fifoAlmostFull = fifo.output('wr_almost_full');
    output('sink_ready') <= ~fifoAlmostFull;
    final fifoFull = fifo.output('wr_full');
    final overflowReg = Logic(name: 'overflow_reg');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [overflowReg < Const(0)],
        orElse: [
          If(fifoFull & wrEn, then: [overflowReg < Const(1)]),
        ],
      ),
    ]);
    output('overflow') <= overflowReg;

    final fifoEmpty = fifo.output('rd_empty');
    final fifoRdData = fifo.output('rd_data'); // first-word-fall-through
    final fifoByte = fifoRdData.slice(7, 0);
    final fifoIsDone = fifoRdData.slice(8, 8);

    const stFill = 0; // accumulate FIFO bytes into the page buffer
    const stEraseReq = 1; // assert wr_req (erase), hold until wr_busy rises
    const stEraseWait = 2; // wait for wr_done of the erase
    const stProgReq = 3; // assert wr_req (program), hold until wr_busy rises
    const stProgWait = 4; // wait for wr_done of the program
    const stFinish = 5; // pop the done marker, pulse image_ready
    const stError = 6; // a write op failed: park (sticky error already set)
    const stFillPop = 7; // one-cycle gap after a byte pop so the FWFT head
    // advances before the next FILL read (rd_en is registered, so the head only
    // updates the cycle after the pulse. Reading back-to-back would re-read the
    // same head byte and double-count it).

    final fsm = Logic(name: 'flash_fsm', width: 3);

    // 256-byte page buffer.
    final pageBuf = [
      for (var i = 0; i < pageSize; i++) Logic(name: 'page_$i', width: 8),
    ];
    // Number of bytes accumulated in the page buffer (0..256).
    final fillCount = Logic(name: 'fill_count', width: 9);
    // Total bytes programmed so far (the running flash offset past flashBase).
    final bytesProg = Logic(name: 'bytes_prog', width: 32);
    // True once the done marker has been seen at the FIFO head (a final flush is
    // owed). Latched so the FSM remembers across the flush ops.
    final donePending = Logic(name: 'done_pending');
    // The last 4 KB sector index that has been erased (valid only when
    // [haveErased] is set). Erase-as-you-go compares the current sector to this.
    final lastSector = Logic(name: 'last_sector', width: 32);
    final haveErased = Logic(name: 'have_erased');

    // Command-drive registers (bus domain) for the flash write engine.
    final reqReg = Logic(name: 'wr_req_reg');
    final opReg = Logic(name: 'wr_op_reg');
    final addrReg = Logic(name: 'wr_addr_reg', width: addrWidth);
    final lenReg = Logic(name: 'wr_len_reg', width: 9);
    final rdEnReg = Logic(name: 'rd_en_reg'); // FIFO pop strobe
    final readyReg = Logic(name: 'image_ready_reg');
    final busyReg = Logic(name: 'busy_reg');
    final errReg = Logic(name: 'error_reg'); // sticky

    final wrBusy = input('wr_busy');
    final wrDone = input('wr_done');
    final wrErr = input('wr_err');

    // The absolute flash address of the byte currently being accumulated /
    // the start of the page about to be programmed.
    final pageStart = (Const(flashBase, width: 32) + bytesProg)
        .slice(addrWidth - 1, 0)
        .named('page_start');
    // Sector index of the page about to be programmed.
    final curSector = (Const(flashBase, width: 32) + bytesProg).getRange(0, 32);
    final curSectorIdx = curSector
        .slice(31, sectorShift)
        .zeroExtend(32)
        .named('cur_sector');
    // This sector still needs erasing (never erased, or a different sector).
    final needErase = (~haveErased | ~curSectorIdx.eq(lastSector)).named(
      'need_erase',
    );

    // The byte that completes the current page: fillCount has reached pageSize.
    final pageFull = fillCount.eq(Const(pageSize, width: 9));

    // Page-buffer read-back for the program data callback: present the byte at
    // the engine's requested index (out of range -> 0).
    final wrIdx = input('wr_data_index');
    Logic dataMux = Const(0, width: 8);
    for (var i = 0; i < pageSize; i++) {
      dataMux = mux(wrIdx.eq(Const(i, width: 9)), pageBuf[i], dataMux);
    }
    output('wr_data') <= dataMux;

    // A new byte is available at the FIFO head and it is a real payload byte.
    final haveByte = ~fifoEmpty & fifoIsDone.eq(Const(0));
    // The done marker is at the FIFO head.
    final haveDone = ~fifoEmpty & fifoIsDone.eq(Const(1));

    Sequential(busClk, [
      If(
        busReset,
        then: [
          fsm < Const(stFill, width: 3),
          for (final b in pageBuf) b < Const(0, width: 8),
          fillCount < Const(0, width: 9),
          bytesProg < Const(0, width: 32),
          donePending < Const(0),
          lastSector < Const(0, width: 32),
          haveErased < Const(0),
          reqReg < Const(0),
          opReg < Const(0),
          addrReg < Const(0, width: addrWidth),
          lenReg < Const(0, width: 9),
          rdEnReg < Const(0),
          readyReg < Const(0),
          busyReg < Const(0),
          errReg < Const(0),
        ],
        orElse: [
          // image_ready and rd_en are one-cycle strobes.
          readyReg < Const(0),
          rdEnReg < Const(0),

          // A failed write op latches the sticky error and stops everything.
          If(wrErr, then: [errReg < Const(1)]),

          Case(fsm, [
            CaseItem(Const(stFill, width: 3), [
              busyReg < Const(0),
              If(
                errReg,
                then: [fsm < Const(stError, width: 3)],
                orElse: [
                  If(
                    pageFull,
                    then: [
                      // A full 256-byte page is buffered: flush it (erase first if its
                      // sector is new, else straight to program).
                      If(
                        needErase,
                        then: [fsm < Const(stEraseReq, width: 3)],
                        orElse: [fsm < Const(stProgReq, width: 3)],
                      ),
                    ],
                    orElse: [
                      If(
                        haveByte,
                        then: [
                          // Store the head byte into the page buffer and pop it, then
                          // take a one-cycle gap (stFillPop) for the FWFT head to
                          // advance before the next read.
                          for (var i = 0; i < pageSize; i++)
                            If(
                              fillCount.eq(Const(i, width: 9)),
                              then: [pageBuf[i] < fifoByte],
                            ),
                          fillCount < fillCount + 1,
                          rdEnReg < Const(1),
                          fsm < Const(stFillPop, width: 3),
                        ],
                        orElse: [
                          If(
                            haveDone,
                            then: [
                              // Image complete. Latch the pending-done flag (do NOT pop the
                              // marker yet) and flush the final partial page if any.
                              donePending < Const(1),
                              If(
                                fillCount.gt(Const(0, width: 9)),
                                then: [
                                  If(
                                    needErase,
                                    then: [fsm < Const(stEraseReq, width: 3)],
                                    orElse: [fsm < Const(stProgReq, width: 3)],
                                  ),
                                ],
                                orElse: [
                                  // Empty image (or already flush-aligned): nothing left to
                                  // program, go straight to finish.
                                  fsm < Const(stFinish, width: 3),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),

            // FILL_POP: one-cycle gap so the popped FWFT head advances, then
            // back to FILL. busy stays low (we are not erasing/programming).
            CaseItem(Const(stFillPop, width: 3), [
              busyReg < Const(0),
              fsm < Const(stFill, width: 3),
            ]),

            // ERASE request: hold wr_req until the engine accepts it
            // (wr_busy rises), driving op=erase and the sector base address.
            CaseItem(Const(stEraseReq, width: 3), [
              busyReg < Const(1),
              reqReg < Const(1),
              opReg < Const(0), // sector-erase
              // Erase the sector the current page falls in (page start with the
              // in-sector bits cleared).
              addrReg <
                  [
                    pageStart.slice(addrWidth - 1, sectorShift),
                    Const(0, width: sectorShift),
                  ].swizzle(),
              lenReg < Const(0, width: 9), // len ignored for erase
              If(
                wrBusy,
                then: [
                  // Accepted: drop the request and wait for completion.
                  reqReg < Const(0),
                  fsm < Const(stEraseWait, width: 3),
                ],
              ),
            ]),

            CaseItem(Const(stEraseWait, width: 3), [
              busyReg < Const(1),
              If(
                wrDone,
                then: [
                  If(
                    wrErr,
                    then: [fsm < Const(stError, width: 3)],
                    orElse: [
                      lastSector < curSectorIdx,
                      haveErased < Const(1),
                      fsm < Const(stProgReq, width: 3),
                    ],
                  ),
                ],
              ),
            ]),

            // PROGRAM request: hold wr_req until accepted, driving
            // op=program, the page start address and the buffered byte count.
            CaseItem(Const(stProgReq, width: 3), [
              busyReg < Const(1),
              reqReg < Const(1),
              opReg < Const(1), // page-program
              addrReg < pageStart,
              lenReg < fillCount, // 1..256 bytes accumulated for this page
              If(
                wrBusy,
                then: [reqReg < Const(0), fsm < Const(stProgWait, width: 3)],
              ),
            ]),

            CaseItem(Const(stProgWait, width: 3), [
              busyReg < Const(1),
              If(
                wrDone,
                then: [
                  If(
                    wrErr,
                    then: [fsm < Const(stError, width: 3)],
                    orElse: [
                      bytesProg < bytesProg + fillCount.zeroExtend(32),
                      fillCount < Const(0, width: 9),
                      busyReg < Const(0),
                      If(
                        donePending,
                        then: [
                          // The final page just programmed: finish.
                          fsm < Const(stFinish, width: 3),
                        ],
                        orElse: [fsm < Const(stFill, width: 3)],
                      ),
                    ],
                  ),
                ],
              ),
            ]),

            CaseItem(Const(stFinish, width: 3), [
              busyReg < Const(0),
              rdEnReg < Const(1), // pop the done marker
              donePending < Const(0),
              readyReg < Const(1),
              fsm < Const(stFill, width: 3),
            ]),

            // ERROR: a write op failed. Park here. Error is sticky. Do not
            // touch the flash again.
            CaseItem(Const(stError, width: 3), [
              busyReg < Const(0),
              reqReg < Const(0),
            ]),
          ]),
        ],
      ),
    ]);

    output('wr_req') <= reqReg;
    output('wr_op') <= opReg;
    output('wr_addr') <= addrReg;
    output('wr_len') <= lenReg;

    fifo.input('rd_en').srcConnection! <= rdEnReg;

    output('image_ready') <= readyReg;
    output('busy') <= busyReg;
    output('error') <= errReg;
    output('bytes_written') <= bytesProg;
  }
}
