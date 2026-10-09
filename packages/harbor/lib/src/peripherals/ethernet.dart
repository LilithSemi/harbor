import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../util/pretty_string.dart';

/// Ethernet PHY interface type.
enum HarborEthernetPhyInterface {
  /// MII (Media Independent Interface, 10/100 Mbps).
  mii,

  /// RMII (Reduced MII, 10/100 Mbps).
  rmii,

  /// GMII (Gigabit MII, 10/100/1000 Mbps).
  gmii,

  /// RGMII (Reduced GMII, 10/100/1000 Mbps).
  rgmii,

  /// SGMII (Serial GMII, 10/100/1000 Mbps).
  sgmii,
}

/// Ethernet speed.
enum HarborEthernetSpeed {
  /// 10 Mbps.
  speed10(10),

  /// 100 Mbps.
  speed100(100),

  /// 1000 Mbps (Gigabit).
  speed1000(1000);

  final int mbps;
  const HarborEthernetSpeed(this.mbps);
}

/// Ethernet MAC configuration.
class HarborEthernetConfig with HarborPrettyString {
  /// Maximum speed supported.
  final HarborEthernetSpeed maxSpeed;

  /// PHY interface type.
  final HarborEthernetPhyInterface phyInterface;

  /// Number of TX descriptor ring entries.
  final int txDescriptors;

  /// Number of RX descriptor ring entries.
  final int rxDescriptors;

  /// TX FIFO depth in bytes.
  final int txFifoSize;

  /// RX FIFO depth in bytes.
  final int rxFifoSize;

  /// Whether hardware checksum offload is supported.
  final bool checksumOffload;

  const HarborEthernetConfig({
    this.maxSpeed = HarborEthernetSpeed.speed1000,
    this.phyInterface = HarborEthernetPhyInterface.rgmii,
    this.txDescriptors = 64,
    this.rxDescriptors = 64,
    this.txFifoSize = 2048,
    this.rxFifoSize = 2048,
    this.checksumOffload = false,
  });

  @override
  String toString() =>
      'HarborEthernetConfig(${maxSpeed.mbps} Mbps, ${phyInterface.name})';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborEthernetConfig(\n');
    buf.writeln('${c}speed: ${maxSpeed.mbps} Mbps,');
    buf.writeln('${c}phy: ${phyInterface.name},');
    buf.writeln('${c}txDesc: $txDescriptors, rxDesc: $rxDescriptors,');
    buf.writeln('${c}txFifo: $txFifoSize, rxFifo: $rxFifoSize,');
    if (checksumOffload) buf.writeln('${c}checksum offload,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// Ethernet MAC controller.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x000: MAC_CTRL    (enable, speed, duplex, loopback)
/// - 0x008: MAC_STATUS  (link, speed_actual, rx_ready, tx_ready)
/// - 0x010: MAC_ADDR_LO (MAC address bytes 0-3)
/// - 0x018: MAC_ADDR_HI (MAC address bytes 4-5)
/// - 0x020: INT_STATUS  (W1C)
/// - 0x028: INT_ENABLE
/// - 0x040: TX_CTRL     (enable, descriptor ring base)
/// - 0x048: TX_STATUS   (busy, descriptors used)
/// - 0x050: TX_DESC_BASE (TX descriptor ring base address)
/// - 0x060: RX_CTRL     (enable, descriptor ring base)
/// - 0x068: RX_STATUS   (busy, descriptors available)
/// - 0x070: RX_DESC_BASE (RX descriptor ring base address)
/// - 0x080: MDIO_CTRL   (PHY management: addr, reg, write, busy)
/// - 0x088: MDIO_DATA   (PHY management data)
class HarborEthernetMac extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// MAC configuration.
  final HarborEthernetConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port (register access).
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborEthernetMac({
    required this.config,
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborEthernetMac', name: name ?? 'ethernet') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('interrupt');

    // MDIO management interface
    addOutput('mdc'); // Management clock
    createPort('mdio_in', PortDirection.input);
    addOutput('mdio_out');
    addOutput('mdio_oe');

    // PHY interface pins (RGMII shown, other interfaces would differ)
    addOutput('tx_clk');
    addOutput('tx_en');
    addOutput(
      'txd',
      width: config.maxSpeed == HarborEthernetSpeed.speed1000 ? 8 : 4,
    );
    createPort('rx_clk', PortDirection.input);
    createPort('rx_dv', PortDirection.input);
    createPort(
      'rxd',
      PortDirection.input,
      width: config.maxSpeed == HarborEthernetSpeed.speed1000 ? 8 : 4,
    );

    // DMA master interface for descriptor/data access
    addOutput('dma_addr', width: 32);
    addOutput('dma_wdata', width: 32);
    createPort('dma_rdata', PortDirection.input, width: 32);
    addOutput('dma_we');
    addOutput('dma_stb');
    createPort('dma_ack', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Registers
    final macEnable = Logic(name: 'mac_enable');
    final macAddrLo = Logic(name: 'mac_addr_lo', width: 32);
    final macAddrHi = Logic(name: 'mac_addr_hi', width: 16);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final txEnable = Logic(name: 'tx_enable');
    final rxEnable = Logic(name: 'rx_enable');
    final txDescBase = Logic(name: 'tx_desc_base', width: 32);
    final rxDescBase = Logic(name: 'rx_desc_base', width: 32);
    final mdioCtrl = Logic(name: 'mdio_ctrl', width: 32);
    final mdioData = Logic(name: 'mdio_data', width: 16);

    // MDIO management engine. Serializes the IEEE 802.3 clause-22 frame on a
    // divided MDC: drive mdio on the MDC falling edge, sample on the rising.
    const mShift = 1; // FSM: shifting the frame (idle == 0)
    const intMdioDone = 0x01;
    const mdcDiv =
        1; // MDC half-period in (mdcDiv+1) sysclks, real PHYs need slower
    final mdioBusy = Logic(name: 'mdio_busy');
    final mdioOpRead = Logic(name: 'mdio_op_read');
    final mdioState = Logic(name: 'mdio_state');
    final mdioShift = Logic(name: 'mdio_shift', width: 64);
    final mdioBitCnt = Logic(name: 'mdio_bit_cnt', width: 7);
    final mdioRdData = Logic(name: 'mdio_rd_data', width: 16);
    final mdcReg = Logic(name: 'mdc_reg');
    final mdcDivCnt = Logic(name: 'mdc_div_cnt', width: 8);
    final mdioOutReg = Logic(name: 'mdio_out_reg');
    final mdioOeReg = Logic(name: 'mdio_oe_reg');
    final mdioIn = input('mdio_in');

    // MDC strobes (single sysclk domain, MDC is a gated divide).
    final mdcTick = mdcDivCnt.eq(Const(0, width: 8)).named('mdc_tick');
    final mdcRise = (mdcTick & ~mdcReg).named('mdc_rise');
    final mdcFall = (mdcTick & mdcReg).named('mdc_fall');

    // Outgoing 64-bit frame built from the CTRL write: preamble (32 ones),
    // ST(01), OP(write 01 / read 10), PHYAD(5), REGAD(5), TA(10), DATA(16).
    final wrPhy = bus.dataIn.getRange(5, 10);
    final wrReg = bus.dataIn.getRange(0, 5);
    final frameWrite = [
      Const(0xFFFFFFFF, width: 32),
      Const(0x1, width: 2), // ST
      Const(0x1, width: 2), // OP write
      wrPhy,
      wrReg,
      Const(0x2, width: 2), // TA
      mdioData,
    ].swizzle();
    final frameRead = [
      Const(0xFFFFFFFF, width: 32),
      Const(0x1, width: 2), // ST
      Const(0x2, width: 2), // OP read
      wrPhy,
      wrReg,
      Const(0, width: 18), // TA + data driven by the PHY
    ].swizzle();

    // TX framing engine. Emits preamble + SFD, the payload (PIO from a one-word
    // holding register), then the CRC32 FCS, on txd/tx_en. Bytes go out
    // LSB-first (low nibble first on a 4-bit MII bus). One W-bit group per
    // cycle, tx_clk toggles for show (the real MII rate is a board concern).
    final txW = config.maxSpeed == HarborEthernetSpeed.speed1000 ? 8 : 4;
    const tIdle = 0;
    const tPre = 1; // preamble + SFD
    const tData = 2; // payload bytes (CRC accumulated)
    const tFcs = 3; // 4-byte CRC32 FCS
    const intTxDone = 0x02;
    const intTxReq = 0x04;

    final txLenReg = Logic(name: 'tx_len', width: 16);
    final txState = Logic(name: 'tx_state', width: 2);
    final txByte = Logic(name: 'tx_byte', width: 8); // emission shift register
    final curByte = Logic(name: 'tx_cur_byte', width: 8); // byte under CRC
    final txBits = Logic(name: 'tx_bits', width: 4); // bits left in this byte
    final preCnt = Logic(
      name: 'tx_pre_cnt',
      width: 4,
    ); // preamble+SFD bytes left
    final txLenCnt = Logic(name: 'tx_len_cnt', width: 16);
    final fcsCnt = Logic(name: 'tx_fcs_cnt', width: 3);
    final crc32 = Logic(name: 'tx_crc32', width: 32);
    final fcsShift = Logic(name: 'tx_fcs_shift', width: 32);
    final txWord = Logic(name: 'tx_word', width: 32);
    final txWordValid = Logic(name: 'tx_word_valid');
    final txByteInWord = Logic(name: 'tx_byte_in_word', width: 2);
    final txBusy = Logic(name: 'tx_busy');
    final txEnReg = Logic(name: 'tx_en_reg');
    final txClkReg = Logic(name: 'tx_clk_reg');
    final txdReg = Logic(name: 'txd_reg', width: txW);

    final byteDone = txBits.eq(Const(txW, width: 4)).named('tx_byte_done');
    // Emission shift: drop the W bits just sent (low-first).
    final txByteShifted = txW < 8
        ? txByte.getRange(txW, 8).zeroExtend(8)
        : Const(0, width: 8);
    final bitsNextTx = mux(
      byteDone,
      Const(8, width: 4),
      txBits - Const(txW, width: 4),
    );
    // Next byte of the holding word, selected by the (current) byte index.
    final nextPayload = mux(
      txByteInWord.eq(Const(0, width: 2)),
      txWord.getRange(8, 16),
      mux(
        txByteInWord.eq(Const(1, width: 2)),
        txWord.getRange(16, 24),
        txWord.getRange(24, 32),
      ),
    );
    // CRC32 including the byte being completed, and the resulting FCS.
    final crcWithLast = _crc32Byte(crc32, curByte);
    final fcsVal = crcWithLast ^ Const(0xFFFFFFFF, width: 32);

    // RX framing engine. Hunts the SFD, deserializes rxd LSB-first, runs every
    // byte (payload + FCS) through CRC32 and checks the standard residue. The
    // first word is captured for readback. Full streaming is the DMA phase.
    // rxd/rx_dv are sampled in the system-clock domain (a real rx_clk crossing
    // is a follow-up).
    const rxIdle = 0;
    const rxPre = 1; // hunting preamble/SFD
    const rxRecv = 2; // collecting bytes after the SFD
    const intRxDone = 0x08;
    const rxResidue = 0xDEBB20E3; // CRC32 register value over a valid msg+FCS
    final rxDv = input('rx_dv');
    final rxd = input('rxd');
    final rxState = Logic(name: 'rx_state', width: 2);
    final rxByteAsm = Logic(name: 'rx_byte_asm', width: 8);
    final rxBits = Logic(name: 'rx_bits', width: 4);
    final rxByteCount = Logic(name: 'rx_byte_count', width: 16);
    final rxCrc = Logic(name: 'rx_crc', width: 32);
    final rxWordAsm = Logic(name: 'rx_word_asm', width: 32);
    final rxData0 = Logic(name: 'rx_data0', width: 32);
    final rxLenReg = Logic(name: 'rx_len', width: 16);
    final rxGood = Logic(name: 'rx_good');
    final rxBad = Logic(name: 'rx_bad');
    final rxBusy = Logic(name: 'rx_busy');

    // Deserialize: shift the W-bit group into the byte from the top (LSB-first).
    final rxByteAsmNext = txW < 8
        ? (rxByteAsm.getRange(txW, 8).zeroExtend(8) |
              (rxd.zeroExtend(8) << Const(8 - txW, width: 8)))
        : rxd.zeroExtend(8);
    final rxByteDone = rxBits.eq(Const(8 - txW, width: 4));
    final rxWordAsmNext = [
      rxByteAsmNext,
      rxWordAsm.getRange(8, 32),
    ].swizzle(); // (>>8) | byte<<24

    // Descriptor DMA engine (shared master port, one direction at a time).
    // A descriptor is two words: [buffer address, length]. TX reads a buffer
    // and feeds the TX framing engine. RX drains received words to a buffer.
    const dIdle = 0;
    const dTxD0 = 1; // read TX descriptor word 0 (buffer address)
    const dTxD1 = 2; // read TX descriptor word 1 (length)
    const dTxLoad = 3; // fetch the first buffer word and start the TX engine
    const dTxFeed = 4; // refill the TX word as the engine consumes it
    const dTxWb = 5; // write the TX descriptor status back
    const dRxD0 = 6; // read RX descriptor word 0 (buffer address)
    const dRxDrain = 7; // store received words to the buffer
    const dRxWb = 8; // write the RX descriptor length back
    final dmaState = Logic(name: 'eth_dma_state', width: 4);
    final descPtr = Logic(name: 'eth_desc_ptr', width: 32);
    final dmaCurAddr = Logic(name: 'eth_dma_cur', width: 32);
    final dmaAddrReg = Logic(name: 'eth_dma_addr_reg', width: 32);
    final dmaWdataReg = Logic(name: 'eth_dma_wdata_reg', width: 32);
    final dmaWeReg = Logic(name: 'eth_dma_we_reg');
    final dmaStbReg = Logic(name: 'eth_dma_stb_reg');
    final txDmaPend = Logic(name: 'eth_tx_dma_pend');
    final rxDmaPend = Logic(name: 'eth_rx_dma_pend');
    final rxDmaEn = Logic(name: 'eth_rx_dma_en');
    final rxWord = Logic(name: 'eth_rx_word', width: 32);
    final rxValid = Logic(name: 'eth_rx_valid');
    final dmaAck = input('dma_ack');
    final dmaRdata = input('dma_rdata');

    interrupt <= (intStatus & intEnable).or();

    output('tx_clk') <= txClkReg;
    output('tx_en') <= txEnReg;
    output('txd') <= txdReg;
    output('mdc') <= mdcReg;
    output('mdio_out') <= mdioOutReg;
    output('mdio_oe') <= mdioOeReg;
    output('dma_addr') <= dmaAddrReg;
    output('dma_wdata') <= dmaWdataReg;
    output('dma_we') <= dmaWeReg;
    output('dma_stb') <= dmaStbReg;

    Sequential(clk, [
      If(
        reset,
        then: [
          macEnable < Const(0),
          macAddrLo < Const(0, width: 32),
          macAddrHi < Const(0, width: 16),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          txEnable < Const(0),
          rxEnable < Const(0),
          txDescBase < Const(0, width: 32),
          rxDescBase < Const(0, width: 32),
          mdioCtrl < Const(0, width: 32),
          mdioData < Const(0, width: 16),
          mdioBusy < Const(0),
          mdioOpRead < Const(0),
          mdioState < Const(0),
          mdioShift < Const(0, width: 64),
          mdioBitCnt < Const(0, width: 7),
          mdioRdData < Const(0, width: 16),
          mdcReg < Const(0),
          mdcDivCnt < Const(0, width: 8),
          mdioOutReg < Const(0),
          mdioOeReg < Const(0),
          txLenReg < Const(0, width: 16),
          txState < Const(tIdle, width: 2),
          txByte < Const(0, width: 8),
          curByte < Const(0, width: 8),
          txBits < Const(8, width: 4),
          preCnt < Const(0, width: 4),
          txLenCnt < Const(0, width: 16),
          fcsCnt < Const(0, width: 3),
          crc32 < Const(0, width: 32),
          fcsShift < Const(0, width: 32),
          txWord < Const(0, width: 32),
          txWordValid < Const(0),
          txByteInWord < Const(0, width: 2),
          txBusy < Const(0),
          txEnReg < Const(0),
          txClkReg < Const(0),
          txdReg < Const(0, width: txW),
          rxState < Const(rxIdle, width: 2),
          rxByteAsm < Const(0, width: 8),
          rxBits < Const(0, width: 4),
          rxByteCount < Const(0, width: 16),
          rxCrc < Const(0, width: 32),
          rxWordAsm < Const(0, width: 32),
          rxData0 < Const(0, width: 32),
          rxLenReg < Const(0, width: 16),
          rxGood < Const(0),
          rxBad < Const(0),
          rxBusy < Const(0),
          dmaState < Const(dIdle, width: 4),
          descPtr < Const(0, width: 32),
          dmaCurAddr < Const(0, width: 32),
          dmaAddrReg < Const(0, width: 32),
          dmaWdataReg < Const(0, width: 32),
          dmaWeReg < Const(0),
          dmaStbReg < Const(0),
          txDmaPend < Const(0),
          rxDmaPend < Const(0),
          rxDmaEn < Const(0),
          rxWord < Const(0, width: 32),
          rxValid < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // MDC divider (free-running while the engine is busy).
          If(
            mdioBusy,
            then: [
              If(
                mdcDivCnt.eq(Const(0, width: 8)),
                then: [mdcDivCnt < Const(mdcDiv, width: 8), mdcReg < ~mdcReg],
                orElse: [mdcDivCnt < (mdcDivCnt - Const(1, width: 8))],
              ),
            ],
          ),

          // MDIO shift engine: drive on the falling MDC edge, sample on rising.
          If(
            mdioState.eq(Const(mShift)),
            then: [
              If(
                mdcFall,
                then: [
                  mdioOutReg < mdioShift[63],
                  mdioShift < [mdioShift.getRange(0, 63), Const(0)].swizzle(),
                  mdioBitCnt < (mdioBitCnt - Const(1, width: 7)),
                  // For a read, release the line for the TA + data window (last
                  // 18 bits), a write drives the whole frame.
                  mdioOeReg <
                      (~mdioOpRead | mdioBitCnt.gt(Const(18, width: 7))),
                  If(
                    mdioBitCnt.eq(Const(1, width: 7)),
                    then: [
                      mdioState < Const(0),
                      mdioBusy < Const(0),
                      mdioOeReg < Const(0),
                      If(mdioOpRead, then: [mdioData < mdioRdData]),
                      intStatus < (intStatus | Const(intMdioDone, width: 8)),
                    ],
                  ),
                ],
              ),
              // Capture PHY-driven read data on the rising edge (last 16 bits).
              If(
                mdcRise & mdioOpRead & mdioBitCnt.lte(Const(16, width: 7)),
                then: [
                  mdioRdData < [mdioRdData.getRange(0, 15), mdioIn].swizzle(),
                ],
              ),
            ],
          ),

          // tx_clk toggles while transmitting (cosmetic, the MII rate is set on
          // the board, like the SDIO/DDR clocks).
          If(txBusy, then: [txClkReg < ~txClkReg]),

          // TX framing engine: one W-bit group emitted per cycle, LSB-first.
          Case(txState, [
            // Idle: line driver off (tx_en deasserts the cycle after the last
            // nibble, so it covers the whole frame).
            CaseItem(Const(tIdle, width: 2), [txEnReg < Const(0)]),
            // Preamble (7x 0x55) + SFD (0xD5).
            CaseItem(Const(tPre, width: 2), [
              txEnReg < Const(1),
              txdReg < txByte.getRange(0, txW),
              txByte < txByteShifted,
              txBits < bitsNextTx,
              If(
                byteDone,
                then: [
                  If(
                    preCnt.eq(Const(1, width: 4)),
                    then: [
                      // SFD sent: start the payload.
                      txState < Const(tData, width: 2),
                      txByte < txWord.getRange(0, 8),
                      curByte < txWord.getRange(0, 8),
                      txBits < Const(8, width: 4),
                      txByteInWord < Const(0, width: 2),
                    ],
                    orElse: [
                      preCnt < (preCnt - Const(1, width: 4)),
                      // Next byte is the SFD when one preamble byte remains.
                      txByte <
                          mux(
                            preCnt.eq(Const(2, width: 4)),
                            Const(0xD5, width: 8),
                            Const(0x55, width: 8),
                          ),
                      txBits < Const(8, width: 4),
                    ],
                  ),
                ],
              ),
            ]),
            // Payload: emit each byte and fold it into the CRC.
            CaseItem(Const(tData, width: 2), [
              txEnReg < Const(1),
              txdReg < txByte.getRange(0, txW),
              txByte < txByteShifted,
              txBits < bitsNextTx,
              If(
                byteDone,
                then: [
                  crc32 < crcWithLast,
                  txLenCnt < (txLenCnt - Const(1, width: 16)),
                  txByteInWord < (txByteInWord + Const(1, width: 2)),
                  If(
                    txLenCnt.eq(Const(1, width: 16)),
                    then: [
                      // Last payload byte: emit the FCS next.
                      txState < Const(tFcs, width: 2),
                      fcsCnt < Const(4, width: 3),
                      txByte < fcsVal.getRange(0, 8),
                      fcsShift < fcsVal.getRange(8, 32).zeroExtend(32),
                      txBits < Const(8, width: 4),
                    ],
                    orElse: [
                      txByte < nextPayload,
                      curByte < nextPayload,
                      txBits < Const(8, width: 4),
                      If(
                        txByteInWord.eq(Const(3, width: 2)),
                        then: [
                          txWordValid < Const(0),
                          intStatus < (intStatus | Const(intTxReq, width: 8)),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // FCS: 4 CRC32 bytes, low byte first.
            CaseItem(Const(tFcs, width: 2), [
              txEnReg < Const(1),
              txdReg < txByte.getRange(0, txW),
              txByte < txByteShifted,
              txBits < bitsNextTx,
              If(
                byteDone,
                then: [
                  If(
                    fcsCnt.eq(Const(1, width: 3)),
                    then: [
                      txState < Const(tIdle, width: 2),
                      txBusy < Const(0),
                      intStatus < (intStatus | Const(intTxDone, width: 8)),
                    ],
                    orElse: [
                      fcsCnt < (fcsCnt - Const(1, width: 3)),
                      txByte < fcsShift.getRange(0, 8),
                      fcsShift < fcsShift.getRange(8, 32).zeroExtend(32),
                      txBits < Const(8, width: 4),
                    ],
                  ),
                ],
              ),
            ]),
          ]),

          // RX framing engine: hunt SFD, deserialize, CRC-residue FCS check.
          Case(rxState, [
            CaseItem(Const(rxIdle, width: 2), [
              If(rxDv, then: [rxState < Const(rxPre, width: 2)]),
            ]),
            CaseItem(Const(rxPre, width: 2), [
              If(
                ~rxDv,
                then: [rxState < Const(rxIdle, width: 2)],
                orElse: [
                  // SFD ends the preamble (0xD high nibble / 0xD5 byte).
                  If(
                    txW < 8
                        ? rxd.eq(Const(0xD, width: txW))
                        : rxd.eq(Const(0xD5, width: txW)),
                    then: [
                      rxState < Const(rxRecv, width: 2),
                      rxBits < Const(0, width: 4),
                      rxByteCount < Const(0, width: 16),
                      rxCrc < Const(0xFFFFFFFF, width: 32),
                      rxByteAsm < Const(0, width: 8),
                      rxWordAsm < Const(0, width: 32),
                      rxBusy < Const(1),
                      rxGood < Const(0),
                      rxBad < Const(0),
                      // Kick the RX DMA to grab a buffer descriptor.
                      If(rxDmaEn, then: [rxDmaPend < Const(1)]),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(rxRecv, width: 2), [
              If(
                ~rxDv,
                then: [
                  // Frame end: a valid frame leaves the CRC at the residue.
                  rxState < Const(rxIdle, width: 2),
                  rxBusy < Const(0),
                  If(
                    rxCrc.eq(Const(rxResidue, width: 32)),
                    then: [rxGood < Const(1)],
                    orElse: [rxBad < Const(1)],
                  ),
                  rxLenReg < (rxByteCount - Const(4, width: 16)), // minus FCS
                  intStatus < (intStatus | Const(intRxDone, width: 8)),
                ],
                orElse: [
                  rxByteAsm <
                      mux(rxByteDone, Const(0, width: 8), rxByteAsmNext),
                  rxBits <
                      mux(
                        rxByteDone,
                        Const(0, width: 4),
                        rxBits + Const(txW, width: 4),
                      ),
                  If(
                    rxByteDone,
                    then: [
                      rxCrc < _crc32Byte(rxCrc, rxByteAsmNext),
                      rxWordAsm < rxWordAsmNext,
                      rxByteCount < (rxByteCount + Const(1, width: 16)),
                      If(
                        rxByteCount.eq(Const(3, width: 16)),
                        then: [rxData0 < rxWordAsmNext],
                      ),
                      // Every fourth byte completes a word, hand it to the DMA.
                      If(
                        rxByteCount.getRange(0, 2).eq(Const(3, width: 2)),
                        then: [rxWord < rxWordAsmNext, rxValid < Const(1)],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
          ]),

          // Descriptor DMA engine: shared master port, TX or RX at a time.
          Case(dmaState, [
            CaseItem(Const(dIdle, width: 4), [
              If(
                txDmaPend,
                then: [
                  txDmaPend < Const(0),
                  descPtr < txDescBase,
                  dmaState < Const(dTxD0, width: 4),
                ],
                orElse: [
                  If(
                    rxDmaPend,
                    then: [
                      rxDmaPend < Const(0),
                      descPtr < rxDescBase,
                      dmaState < Const(dRxD0, width: 4),
                    ],
                  ),
                ],
              ),
            ]),
            // TX: read descriptor [addr, len], feed the framing engine, write
            // the status back.
            CaseItem(Const(dTxD0, width: 4), [
              dmaAddrReg < descPtr,
              dmaWeReg < Const(0),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  dmaCurAddr < dmaRdata,
                  dmaStbReg < Const(0),
                  dmaState < Const(dTxD1, width: 4),
                ],
              ),
            ]),
            CaseItem(Const(dTxD1, width: 4), [
              dmaAddrReg < (descPtr + Const(4, width: 32)),
              dmaWeReg < Const(0),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  txLenReg < dmaRdata.getRange(0, 16),
                  dmaStbReg < Const(0),
                  dmaState < Const(dTxLoad, width: 4),
                ],
              ),
            ]),
            CaseItem(Const(dTxLoad, width: 4), [
              dmaAddrReg < dmaCurAddr,
              dmaWeReg < Const(0),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  txWord < dmaRdata,
                  txWordValid < Const(1),
                  dmaCurAddr < (dmaCurAddr + Const(4, width: 32)),
                  dmaStbReg < Const(0),
                  // Start the TX framing engine.
                  txState < Const(tPre, width: 2),
                  preCnt < Const(8, width: 4),
                  txByte < Const(0x55, width: 8),
                  txBits < Const(8, width: 4),
                  txBusy < Const(1),
                  crc32 < Const(0xFFFFFFFF, width: 32),
                  txLenCnt < txLenReg,
                  txByteInWord < Const(0, width: 2),
                  txClkReg < Const(0),
                  dmaState < Const(dTxFeed, width: 4),
                ],
              ),
            ]),
            CaseItem(Const(dTxFeed, width: 4), [
              If(
                ~txBusy,
                then: [dmaState < Const(dTxWb, width: 4)],
                orElse: [
                  If(
                    ~txWordValid,
                    then: [
                      dmaAddrReg < dmaCurAddr,
                      dmaWeReg < Const(0),
                      dmaStbReg < Const(1),
                      If(
                        dmaAck,
                        then: [
                          txWord < dmaRdata,
                          txWordValid < Const(1),
                          dmaCurAddr < (dmaCurAddr + Const(4, width: 32)),
                          dmaStbReg < Const(0),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(dTxWb, width: 4), [
              dmaAddrReg < (descPtr + Const(4, width: 32)),
              dmaWdataReg < Const(0, width: 32), // clear OWN / mark sent
              dmaWeReg < Const(1),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  dmaStbReg < Const(0),
                  dmaWeReg < Const(0),
                  intStatus < (intStatus | Const(intTxDone, width: 8)),
                  dmaState < Const(dIdle, width: 4),
                ],
              ),
            ]),
            // RX: read the buffer address, store words as they arrive, write
            // the length back.
            CaseItem(Const(dRxD0, width: 4), [
              dmaAddrReg < descPtr,
              dmaWeReg < Const(0),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  dmaCurAddr < dmaRdata,
                  dmaStbReg < Const(0),
                  dmaState < Const(dRxDrain, width: 4),
                ],
              ),
            ]),
            CaseItem(Const(dRxDrain, width: 4), [
              If(
                rxValid,
                then: [
                  dmaAddrReg < dmaCurAddr,
                  dmaWdataReg < rxWord,
                  dmaWeReg < Const(1),
                  dmaStbReg < Const(1),
                  If(
                    dmaAck,
                    then: [
                      dmaCurAddr < (dmaCurAddr + Const(4, width: 32)),
                      rxValid < Const(0),
                      dmaStbReg < Const(0),
                      dmaWeReg < Const(0),
                    ],
                  ),
                ],
                orElse: [
                  If(~rxBusy, then: [dmaState < Const(dRxWb, width: 4)]),
                ],
              ),
            ]),
            CaseItem(Const(dRxWb, width: 4), [
              dmaAddrReg < (descPtr + Const(4, width: 32)),
              dmaWdataReg < rxLenReg.zeroExtend(32),
              dmaWeReg < Const(1),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  dmaStbReg < Const(0),
                  dmaWeReg < Const(0),
                  intStatus < (intStatus | Const(intRxDone, width: 8)),
                  dmaState < Const(dIdle, width: 4),
                ],
              ),
            ]),
          ]),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Decode every address bit of the 0x1000 window and ignore the
              // bits above it, so absolute and relative addresses both work. An
              // unused offset reads 0 and ignores writes.
              Case(bus.windowAddr(0x1000), [
                // 0x000: MAC_CTRL
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we & bus.selAny(0x00, 1),
                    then: [macEnable < bus.dataIn[0]],
                    orElse: [bus.dataOut < macEnable.zeroExtend(32)],
                  ),
                ]),
                // 0x008: MAC_STATUS
                CaseItem(Const(0x08, width: 12), [
                  bus.dataOut <
                      txEnable.zeroExtend(32) |
                          (rxEnable.zeroExtend(32) << Const(1, width: 32)),
                ]),
                // 0x010: MAC_ADDR_LO
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we,
                    then: [macAddrLo < bus.selMerge(macAddrLo, 0x10)],
                    orElse: [bus.dataOut < macAddrLo],
                  ),
                ]),
                // 0x018: MAC_ADDR_HI
                CaseItem(Const(0x18, width: 12), [
                  If(
                    bus.we,
                    then: [macAddrHi < bus.selMerge(macAddrHi, 0x18)],
                    orElse: [bus.dataOut < macAddrHi.zeroExtend(32)],
                  ),
                ]),
                // 0x020: INT_STATUS (W1C)
                CaseItem(Const(0x20, width: 12), [
                  If(
                    bus.we,
                    then: [intStatus < (intStatus & ~bus.selMasked(0x20, 8))],
                    orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                  ),
                ]),
                // 0x028: INT_ENABLE
                CaseItem(Const(0x28, width: 12), [
                  If(
                    bus.we,
                    then: [intEnable < bus.selMerge(intEnable, 0x28)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                  ),
                ]),
                // 0x040: TX_CTRL ([0] enable, [1] PIO start, [2] DMA start).
                CaseItem(Const(0x40, width: 12), [
                  If(
                    bus.we & bus.selAny(0x40, 1),
                    then: [
                      txEnable < bus.dataIn[0],
                      If(
                        bus.dataIn[2] &
                            ~txBusy &
                            dmaState.eq(Const(dIdle, width: 4)),
                        then: [txDmaPend < Const(1)],
                      ),
                      If(
                        bus.dataIn[1] & ~txBusy,
                        then: [
                          txState < Const(tPre, width: 2),
                          preCnt < Const(8, width: 4),
                          txByte < Const(0x55, width: 8),
                          txBits < Const(8, width: 4),
                          txBusy < Const(1),
                          crc32 < Const(0xFFFFFFFF, width: 32),
                          txLenCnt < txLenReg,
                          txByteInWord < Const(0, width: 2),
                          txClkReg < Const(0),
                        ],
                      ),
                    ],
                    orElse: [bus.dataOut < txEnable.zeroExtend(32)],
                  ),
                ]),
                // 0x048: TX_STATUS ([0] busy).
                CaseItem(Const(0x48, width: 12), [
                  bus.dataOut < txBusy.zeroExtend(32),
                ]),
                // 0x058: TX_LEN (payload byte count).
                CaseItem(Const(0x58, width: 12), [
                  If(
                    bus.we,
                    then: [txLenReg < bus.selMerge(txLenReg, 0x58)],
                    orElse: [bus.dataOut < txLenReg.zeroExtend(32)],
                  ),
                ]),
                // 0x090: TX_DATA (PIO payload, one word at a time).
                CaseItem(Const(0x90, width: 12), [
                  If(
                    bus.we,
                    then: [
                      txWord < bus.selMerge(txWord, 0x90),
                      txWordValid < Const(1),
                    ],
                  ),
                ]),
                // 0x098: RX_DATA (first received word).
                CaseItem(Const(0x98, width: 12), [bus.dataOut < rxData0]),
                // 0x0A0: RX_LEN (received payload byte count).
                CaseItem(Const(0xA0, width: 12), [
                  bus.dataOut < rxLenReg.zeroExtend(32),
                ]),
                // 0x050: TX_DESC_BASE
                CaseItem(Const(0x50, width: 12), [
                  If(
                    bus.we,
                    then: [txDescBase < bus.selMerge(txDescBase, 0x50)],
                    orElse: [bus.dataOut < txDescBase],
                  ),
                ]),
                // 0x060: RX_CTRL ([0] enable, [1] RX DMA enable).
                CaseItem(Const(0x60, width: 12), [
                  If(
                    bus.we & bus.selAny(0x60, 1),
                    then: [rxEnable < bus.dataIn[0], rxDmaEn < bus.dataIn[1]],
                    orElse: [
                      bus.dataOut <
                          rxEnable.zeroExtend(32) |
                              (rxDmaEn.zeroExtend(32) << Const(1, width: 32)),
                    ],
                  ),
                ]),
                // 0x068: RX_STATUS ([0] FCS good, [1] FCS bad, [2] busy).
                CaseItem(Const(0x68, width: 12), [
                  bus.dataOut <
                      rxGood.zeroExtend(32) |
                          (rxBad.zeroExtend(32) << Const(1, width: 32)) |
                          (rxBusy.zeroExtend(32) << Const(2, width: 32)),
                ]),
                // 0x070: RX_DESC_BASE
                CaseItem(Const(0x70, width: 12), [
                  If(
                    bus.we,
                    then: [rxDescBase < bus.selMerge(rxDescBase, 0x70)],
                    orElse: [bus.dataOut < rxDescBase],
                  ),
                ]),
                // 0x080: MDIO_CTRL. [4:0] reg, [9:5] phy, [10] read, [11]
                // start (kicks the engine), [12] busy (read-only).
                CaseItem(Const(0x80, width: 12), [
                  If(
                    bus.we,
                    then: [
                      mdioCtrl < bus.selMerge(mdioCtrl, 0x80),
                      // The start bit lives in byte 1, so only fire the
                      // engine when that byte was actually written.
                      If(
                        bus.dataIn[11] & ~mdioBusy & bus.selAny(0x81, 1),
                        then: [
                          mdioOpRead < bus.dataIn[10],
                          mdioShift <
                              mux(bus.dataIn[10], frameRead, frameWrite),
                          mdioBitCnt < Const(64, width: 7),
                          mdioOutReg < Const(1),
                          mdioOeReg < Const(1),
                          mdioBusy < Const(1),
                          mdcReg < Const(0),
                          mdcDivCnt < Const(mdcDiv, width: 8),
                          mdioState < Const(mShift),
                        ],
                      ),
                    ],
                    orElse: [
                      bus.dataOut <
                          (mdioCtrl |
                              (mdioBusy.zeroExtend(32) <<
                                  Const(12, width: 32))),
                    ],
                  ),
                ]),
                // 0x088: MDIO_DATA
                CaseItem(Const(0x88, width: 12), [
                  If(
                    bus.we,
                    then: [mdioData < bus.selMerge(mdioData, 0x88)],
                    orElse: [bus.dataOut < mdioData.zeroExtend(32)],
                  ),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  /// One byte folded into the Ethernet FCS CRC32 (reflected, polynomial
  /// 0xEDB88320), processing bits LSB-first. Seed with 0xFFFFFFFF per frame.
  /// The transmitted FCS is the ones-complement of the final value.
  Logic _crc32Byte(Logic crc, Logic byte) {
    var c = crc;
    for (var i = 0; i < 8; i++) {
      final x = byte[i] ^ c[0];
      final sh = c.getRange(1, 32).zeroExtend(32); // c >> 1
      c = mux(x, sh ^ Const(0xEDB88320, width: 32), sh);
    }
    return c;
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,ethernet'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'phy-mode': config.phyInterface.name,
      'max-speed': config.maxSpeed.mbps,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,ethernet'],
      'phy-mode': config.phyInterface.name,
      'max-speed': config.maxSpeed.mbps,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'ETH',
    groupName: 'ETH',
    description: 'Ethernet MAC controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
