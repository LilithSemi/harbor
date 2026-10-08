import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../util/pretty_string.dart';

/// PCIe generation.
enum HarborPcieGen {
  /// PCIe Gen 1 (2.5 GT/s per lane).
  gen1(1, 2500),

  /// PCIe Gen 2 (5 GT/s per lane).
  gen2(2, 5000),

  /// PCIe Gen 3 (8 GT/s per lane).
  gen3(3, 8000),

  /// PCIe Gen 4 (16 GT/s per lane).
  gen4(4, 16000),

  /// PCIe Gen 5 (32 GT/s per lane).
  gen5(5, 32000);

  /// Generation number.
  final int gen;

  /// Transfer rate in MT/s per lane.
  final int mtPerSecond;

  const HarborPcieGen(this.gen, this.mtPerSecond);

  /// Bandwidth per lane in MB/s (approximate, accounting for encoding).
  double get bandwidthPerLaneMBs => switch (this) {
    HarborPcieGen.gen1 => 250,
    HarborPcieGen.gen2 => 500,
    HarborPcieGen.gen3 => 984.6,
    HarborPcieGen.gen4 => 1969,
    HarborPcieGen.gen5 => 3938,
  };
}

/// PCIe lane width.
enum HarborPcieLanes {
  x1(1),
  x2(2),
  x4(4),
  x8(8),
  x16(16);

  final int count;
  const HarborPcieLanes(this.count);
}

/// PCIe controller role.
enum HarborPcieRole {
  /// Root complex (host).
  rootComplex,

  /// Endpoint (device).
  endpoint,
}

/// PCIe controller configuration.
class HarborPcieConfig with HarborPrettyString {
  /// Maximum PCIe generation supported.
  final HarborPcieGen maxGen;

  /// Maximum lane width.
  final HarborPcieLanes maxLanes;

  /// Controller role.
  final HarborPcieRole role;

  /// Number of MSI vectors supported.
  final int msiVectors;

  /// Number of MSI-X vectors supported.
  final int msixVectors;

  /// Whether IOMMU/ATS is supported.
  final bool supportsAts;

  /// PCIe configuration space size per function (4KB standard, 4MB extended).
  final int configSpaceSize;

  const HarborPcieConfig({
    this.maxGen = HarborPcieGen.gen3,
    this.maxLanes = HarborPcieLanes.x4,
    this.role = HarborPcieRole.rootComplex,
    this.msiVectors = 32,
    this.msixVectors = 0,
    this.supportsAts = false,
    this.configSpaceSize = 4096,
  });

  /// Total bandwidth in MB/s.
  double get totalBandwidthMBs => maxGen.bandwidthPerLaneMBs * maxLanes.count;

  @override
  String toString() =>
      'HarborPcieConfig(Gen${maxGen.gen} x${maxLanes.count}, '
      '${role.name})';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborPcieConfig(\n');
    buf.writeln('${c}gen: ${maxGen.gen},');
    buf.writeln('${c}lanes: x${maxLanes.count},');
    buf.writeln('${c}role: ${role.name},');
    buf.writeln('${c}bandwidth: ${totalBandwidthMBs.toStringAsFixed(0)} MB/s,');
    buf.writeln('${c}msi: $msiVectors vectors,');
    if (msixVectors > 0) buf.writeln('${c}msix: $msixVectors vectors,');
    if (supportsAts) buf.writeln('${c}ATS/IOMMU,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// PCIe Root Complex / Endpoint controller.
///
/// For root complex mode, provides:
/// - ECAM configuration space access (memory-mapped PCIe config)
/// - Memory and I/O BAR windows
/// - MSI/MSI-X interrupt handling
/// - LTSSM link training state machine
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x000: CTRL       (enable, gen, lanes, role)
/// - 0x004: STATUS     (link_up, negotiated gen/lanes, ltssm_state)
/// - 0x008: LINK_CTRL  (link training, speed change, retrain)
/// - 0x00C: INT_STATUS (W1C: link_up, link_down, msi, error)
/// - 0x010: INT_ENABLE
/// - 0x014: ERR_STATUS (correctable, uncorrectable, fatal)
/// - 0x020: BAR0_BASE  (BAR 0 base address)
/// - 0x024: BAR0_MASK  (BAR 0 address mask / size)
/// - 0x028: BAR1_BASE
/// - 0x02C: BAR1_MASK
/// - 0x040: MSI_ADDR   (MSI target address)
/// - 0x044: MSI_DATA   (MSI data value)
/// - 0x048: MSI_MASK   (MSI vector mask)
/// - 0x04C: MSI_PEND   (MSI pending bits)
///
/// ECAM space is mapped at a separate memory region for config access.
class HarborPcieController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// PCIe configuration.
  final HarborPcieConfig config;

  /// Base address for controller registers.
  final int baseAddress;

  /// Base address for ECAM configuration space.
  final int ecamBase;

  /// ECAM size in bytes (256MB for 256 buses).
  final int ecamSize;

  /// Bus slave port (register access).
  late final BusSlavePort bus;

  /// ECAM configuration-space slave port.
  late final BusSlavePort ecam;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborPcieController({
    required this.config,
    required this.baseAddress,
    required this.ecamBase,
    this.ecamSize = 256 * 1024 * 1024,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborPcieController', name: name ?? 'pcie') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('interrupt');

    // PCIe PHY signals (directly active)
    addOutput('perst_n'); // PCIe reset (active low)
    addOutput('clkreq_n'); // Clock request (active low)
    createPort('wake_n', PortDirection.input); // Wake (active low)

    // PCIe PIPE interface (simplified: real impl uses PIPE PHY)
    for (var i = 0; i < config.maxLanes.count; i++) {
      createPort('rxp_$i', PortDirection.input);
      createPort('rxn_$i', PortDirection.input);
      addOutput('txp_$i');
      addOutput('txn_$i');
    }

    // Downstream master port. The TLP engine drives memory requests into PCIe
    // address space here. In simulation a memory model backs it (the endpoint).
    // Single-beat handshake: stb asserts a request, ack completes it.
    addOutput('pcie_m_addr', width: 64);
    addOutput('pcie_m_wdata', width: 32);
    addOutput('pcie_m_we');
    addOutput('pcie_m_stb');
    createPort('pcie_m_rdata', PortDirection.input, width: 32);
    createPort('pcie_m_ack', PortDirection.input);

    // Endpoint inbound target. A host MWr/MRd to one of this function's BAR
    // windows arrives here as a request. The endpoint performs it against its
    // local memory (ep_m_*) and, for reads, returns the completion data.
    if (config.role == HarborPcieRole.endpoint) {
      createPort('ep_req_valid', PortDirection.input);
      createPort('ep_req_write', PortDirection.input);
      createPort('ep_req_addr', PortDirection.input, width: 32);
      createPort('ep_req_wdata', PortDirection.input, width: 32);
      addOutput('ep_req_ack'); // request complete (one cycle)
      addOutput('ep_cpl_data', width: 32); // read completion data
      addOutput('ep_m_addr', width: 32); // local-memory port
      addOutput('ep_m_wdata', width: 32);
      addOutput('ep_m_we');
      addOutput('ep_m_stb');
      createPort('ep_m_rdata', PortDirection.input, width: 32);
      createPort('ep_m_ack', PortDirection.input);
    }

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
    );

    // ECAM configuration-space port. The fabric strips the byte offset, so the
    // address is a dword index laid out as {bus[7:0], dev[4:0], fn[2:0],
    // reg[9:0]} = 26 bits. The root complex answers config accesses to its own
    // host-bridge function (00:00.0) and master-aborts everything else.
    ecam = BusSlavePort.create(
      module: this,
      name: 'ecam',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 26,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Registers
    final enable = Logic(name: 'enable');
    final linkUp = Logic(name: 'link_up');
    final negGen = Logic(name: 'neg_gen', width: 3);
    final negLanes = Logic(name: 'neg_lanes', width: 5);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final errStatus = Logic(name: 'err_status', width: 8);
    final bar0Base = Logic(name: 'bar0_base', width: 32);
    final bar0Mask = Logic(name: 'bar0_mask', width: 32);
    final bar1Base = Logic(name: 'bar1_base', width: 32);
    final bar1Mask = Logic(name: 'bar1_mask', width: 32);
    final msiAddr = Logic(name: 'msi_addr', width: 32);
    final msiData = Logic(name: 'msi_data', width: 16);
    final msiMask = Logic(name: 'msi_mask', width: 32);
    final msiPend = Logic(name: 'msi_pend', width: 32);

    // Link training state machine (LTSSM). The major states are modelled with
    // a short dwell in each training state. On real silicon these are driven by
    // ordered-set exchange and electrical timers, here a few cycles each is
    // enough to verify the bring-up sequence and the status/interrupt plumbing.
    const sDetect = 0;
    const sPolling = 1;
    const sConfig = 2;
    const sL0 = 3;
    const sRecovery = 4;
    const trainDwell = 4;

    final ltssm = Logic(name: 'ltssm', width: 3);
    final dwell = Logic(name: 'ltssm_dwell', width: 4);
    final retrainReq = Logic(name: 'retrain_req');
    final linkDisable = Logic(name: 'link_disable');
    final txTog = Logic(name: 'tx_tog');

    // Host-bridge (00:00.0) configuration-space state. The identity registers
    // are constants. Command and the bus-number register are written by
    // enumeration software.
    final cfgCommand = Logic(name: 'cfg_command', width: 16);
    final cfgBusNumbers = Logic(name: 'cfg_bus_numbers', width: 32);

    // Configuration-space identity. A root complex presents a PCI-to-PCI
    // bridge (Type 1) at 00:00.0. An endpoint presents a Type 0 function.
    final isEndpoint = config.role == HarborPcieRole.endpoint;
    final cfgVendorDevice = isEndpoint ? 0x10EF1AF4 : 0x00081B36;
    final cfgClassRev = isEndpoint ? 0x12000001 : 0x06040001;
    final cfgHeaderType = isEndpoint ? 0x00000000 : 0x00010000;
    const cfgCapPtr = 0x00000040; // first capability at byte 0x40
    const cfgMsiCap = 0x00800005; // MSI cap: id 0x05, msgctrl 0x0080

    // TLP engine: assembles Memory Write / Memory Read transaction-layer
    // packets and moves the payload over the downstream master port. The
    // requester ID is the root complex function 00:00.0.
    const tlpDepth = 8; // data buffer depth in DWords
    const tIdle = 0;
    const tWrite = 1;
    const tRead = 2;

    final tlpAddrLo = Logic(name: 'tlp_addr_lo', width: 32);
    final tlpAddrHi = Logic(name: 'tlp_addr_hi', width: 32);
    final tlpLen = Logic(name: 'tlp_len', width: 4); // up to tlpDepth DWords
    final tlpState = Logic(name: 'tlp_state', width: 2);
    final tlpBusy = Logic(name: 'tlp_busy');
    final tlpDone = Logic(name: 'tlp_done');
    final tlpTag = Logic(name: 'tlp_tag', width: 8);
    final tlpIdx = Logic(name: 'tlp_idx', width: 4);
    final tlpWrPtr = Logic(name: 'tlp_wr_ptr', width: 4);
    final tlpRdPtr = Logic(name: 'tlp_rd_ptr', width: 4);
    final hdr0 = Logic(name: 'tlp_hdr0', width: 32);
    final hdr1 = Logic(name: 'tlp_hdr1', width: 32);
    final hdr2 = Logic(name: 'tlp_hdr2', width: 32);
    final msiBusy = Logic(name: 'msi_busy');
    final msiVec = Logic(name: 'msi_vec', width: 5);
    final mAddrReg = Logic(name: 'm_addr_reg', width: 64);
    final mWdataReg = Logic(name: 'm_wdata_reg', width: 32);
    final mWeReg = Logic(name: 'm_we_reg');
    final mStbReg = Logic(name: 'm_stb_reg');
    final dbuf = List.generate(
      tlpDepth,
      (i) => Logic(name: 'tlp_dbuf_$i', width: 32),
    );

    final mAck = input('pcie_m_ack');
    final mRdata = input('pcie_m_rdata');
    final tlpBase = [tlpAddrHi, tlpAddrLo].swizzle().named('tlp_base');
    // Data-buffer read mux for the next beat and for software reads.
    Logic dbufAt(Logic idx) {
      Logic v = Const(0, width: 32);
      for (var i = tlpDepth - 1; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: 4)), dbuf[i], v);
      }
      return v;
    }

    output('pcie_m_addr') <= mAddrReg;
    output('pcie_m_wdata') <= mWdataReg;
    output('pcie_m_we') <= mWeReg;
    output('pcie_m_stb') <= mStbReg;

    // Endpoint inbound-target state.
    const epIdle = 0;
    const epAccess = 1;
    final epState = Logic(name: 'ep_state');
    final epWrite = Logic(name: 'ep_write');
    final epAckReg = Logic(name: 'ep_ack_reg');
    final epCplReg = Logic(name: 'ep_cpl_reg', width: 32);
    final epMAddrReg = Logic(name: 'ep_m_addr_reg', width: 32);
    final epMWdataReg = Logic(name: 'ep_m_wdata_reg', width: 32);
    final epMWeReg = Logic(name: 'ep_m_we_reg');
    final epMStbReg = Logic(name: 'ep_m_stb_reg');
    if (isEndpoint) {
      output('ep_req_ack') <= epAckReg;
      output('ep_cpl_data') <= epCplReg;
      output('ep_m_addr') <= epMAddrReg;
      output('ep_m_wdata') <= epMWdataReg;
      output('ep_m_we') <= epMWeReg;
      output('ep_m_stb') <= epMStbReg;
    }

    // A receiver is present when the partner holds its lane-0 differential out
    // of the all-low electrical-idle state. Tests drive rxn high to attach.
    final rxPresent = input('rxn_0').named('rx_present');
    final training =
        (ltssm.eq(Const(sPolling, width: 3)) |
                ltssm.eq(Const(sConfig, width: 3)) |
                ltssm.eq(Const(sRecovery, width: 3)))
            .named('ltssm_training');
    final linkActive = (training | linkUp).named('link_active');

    interrupt <= (intStatus & intEnable).or();
    output('perst_n') <= enable;
    output('clkreq_n') <= ~enable;

    // TX lanes carry a toggling training/idle pattern while the link is active,
    // and sit in electrical idle (p low, n high) otherwise.
    for (var i = 0; i < config.maxLanes.count; i++) {
      output('txp_$i') <= (linkActive & txTog);
      output('txn_$i') <= ~(linkActive & txTog);
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          enable < Const(0),
          linkUp < Const(0),
          negGen < Const(0, width: 3),
          negLanes < Const(0, width: 5),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          errStatus < Const(0, width: 8),
          bar0Base < Const(0, width: 32),
          bar0Mask < Const(0, width: 32),
          bar1Base < Const(0, width: 32),
          bar1Mask < Const(0, width: 32),
          msiAddr < Const(0, width: 32),
          msiData < Const(0, width: 16),
          msiMask < Const(0, width: 32),
          msiPend < Const(0, width: 32),
          ltssm < Const(sDetect, width: 3),
          dwell < Const(0, width: 4),
          retrainReq < Const(0),
          linkDisable < Const(0),
          txTog < Const(0),
          cfgCommand < Const(0, width: 16),
          cfgBusNumbers < Const(0, width: 32),
          tlpAddrLo < Const(0, width: 32),
          tlpAddrHi < Const(0, width: 32),
          tlpLen < Const(0, width: 4),
          tlpState < Const(tIdle, width: 2),
          tlpBusy < Const(0),
          tlpDone < Const(0),
          tlpTag < Const(0, width: 8),
          tlpIdx < Const(0, width: 4),
          tlpWrPtr < Const(0, width: 4),
          tlpRdPtr < Const(0, width: 4),
          hdr0 < Const(0, width: 32),
          hdr1 < Const(0, width: 32),
          hdr2 < Const(0, width: 32),
          msiBusy < Const(0),
          msiVec < Const(0, width: 5),
          mAddrReg < Const(0, width: 64),
          mWdataReg < Const(0, width: 32),
          mWeReg < Const(0),
          mStbReg < Const(0),
          ...List.generate(tlpDepth, (i) => dbuf[i] < Const(0, width: 32)),
          epState < Const(epIdle, width: 1),
          epWrite < Const(0),
          epAckReg < Const(0),
          epCplReg < Const(0, width: 32),
          epMAddrReg < Const(0, width: 32),
          epMWdataReg < Const(0, width: 32),
          epMWeReg < Const(0),
          epMStbReg < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
          ecam.ack < Const(0),
          ecam.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
          ecam.ack < Const(0),
          ecam.dataOut < Const(0, width: 32),
          txTog < ~txTog,

          If(
            ~enable | linkDisable,
            then: [
              // Forced down: drop the link and return to Detect.
              If(
                linkUp,
                then: [intStatus < (intStatus | Const(0x02, width: 8))],
              ),
              ltssm < Const(sDetect, width: 3),
              dwell < Const(0, width: 4),
              linkUp < Const(0),
            ],
            orElse: [
              Case(ltssm, [
                CaseItem(Const(sDetect, width: 3), [
                  If(
                    rxPresent,
                    then: [
                      If(
                        dwell.eq(Const(trainDwell, width: 4)),
                        then: [
                          ltssm < Const(sPolling, width: 3),
                          dwell < Const(0, width: 4),
                        ],
                        orElse: [dwell < (dwell + Const(1, width: 4))],
                      ),
                    ],
                    orElse: [dwell < Const(0, width: 4)],
                  ),
                ]),
                CaseItem(Const(sPolling, width: 3), [
                  If(
                    dwell.eq(Const(trainDwell, width: 4)),
                    then: [
                      ltssm < Const(sConfig, width: 3),
                      dwell < Const(0, width: 4),
                    ],
                    orElse: [dwell < (dwell + Const(1, width: 4))],
                  ),
                ]),
                CaseItem(Const(sConfig, width: 3), [
                  If(
                    dwell.eq(Const(trainDwell, width: 4)),
                    then: [
                      ltssm < Const(sL0, width: 3),
                      dwell < Const(0, width: 4),
                      linkUp < Const(1),
                      negGen < Const(config.maxGen.gen, width: 3),
                      negLanes < Const(config.maxLanes.count, width: 5),
                      intStatus < (intStatus | Const(0x01, width: 8)),
                    ],
                    orElse: [dwell < (dwell + Const(1, width: 4))],
                  ),
                ]),
                CaseItem(Const(sL0, width: 3), [
                  If(
                    ~rxPresent,
                    then: [
                      ltssm < Const(sDetect, width: 3),
                      linkUp < Const(0),
                      intStatus < (intStatus | Const(0x02, width: 8)),
                    ],
                    orElse: [
                      If(
                        retrainReq,
                        then: [
                          ltssm < Const(sRecovery, width: 3),
                          dwell < Const(0, width: 4),
                          retrainReq < Const(0),
                        ],
                      ),
                    ],
                  ),
                ]),
                CaseItem(Const(sRecovery, width: 3), [
                  If(
                    dwell.eq(Const(trainDwell, width: 4)),
                    then: [
                      ltssm < Const(sL0, width: 3),
                      dwell < Const(0, width: 4),
                    ],
                    orElse: [dwell < (dwell + Const(1, width: 4))],
                  ),
                ]),
              ]),
            ],
          ),

          If(
            mStbReg & mAck,
            then: [
              Case(tlpState, [
                CaseItem(Const(tWrite, width: 2), [
                  If(
                    (tlpIdx + Const(1, width: 4)).eq(tlpLen),
                    then: [
                      mStbReg < Const(0),
                      mWeReg < Const(0),
                      tlpBusy < Const(0),
                      tlpDone < Const(1),
                      tlpState < Const(tIdle, width: 2),
                      If(
                        msiBusy,
                        then: [
                          msiBusy < Const(0),
                          msiPend <
                              (msiPend |
                                  (Const(1, width: 32) <<
                                      msiVec.zeroExtend(32))),
                          intStatus < (intStatus | Const(0x04, width: 8)),
                        ],
                      ),
                    ],
                    orElse: [
                      tlpIdx < (tlpIdx + Const(1, width: 4)),
                      mAddrReg <
                          (tlpBase +
                              ((tlpIdx + Const(1, width: 4)).zeroExtend(64) *
                                  Const(4, width: 64))),
                      mWdataReg < dbufAt(tlpIdx + Const(1, width: 4)),
                    ],
                  ),
                ]),
                CaseItem(Const(tRead, width: 2), [
                  for (var i = 0; i < tlpDepth; i++)
                    If(tlpIdx.eq(Const(i, width: 4)), then: [dbuf[i] < mRdata]),
                  If(
                    (tlpIdx + Const(1, width: 4)).eq(tlpLen),
                    then: [
                      mStbReg < Const(0),
                      tlpBusy < Const(0),
                      tlpDone < Const(1),
                      tlpState < Const(tIdle, width: 2),
                    ],
                    orElse: [
                      tlpIdx < (tlpIdx + Const(1, width: 4)),
                      mAddrReg <
                          (tlpBase +
                              ((tlpIdx + Const(1, width: 4)).zeroExtend(64) *
                                  Const(4, width: 64))),
                    ],
                  ),
                ]),
              ]),
            ],
          ),

          if (isEndpoint)
            Case(epState, [
              CaseItem(Const(epIdle, width: 1), [
                epAckReg < Const(0),
                If(
                  input('ep_req_valid'),
                  then: [
                    epWrite < input('ep_req_write'),
                    epMAddrReg < input('ep_req_addr'),
                    epMWdataReg < input('ep_req_wdata'),
                    epMWeReg < input('ep_req_write'),
                    epMStbReg < Const(1),
                    epState < Const(epAccess, width: 1),
                  ],
                ),
              ]),
              CaseItem(Const(epAccess, width: 1), [
                If(
                  input('ep_m_ack'),
                  then: [
                    epMStbReg < Const(0),
                    epMWeReg < Const(0),
                    // For a read, latch the data for the completion.
                    If(~epWrite, then: [epCplReg < input('ep_m_rdata')]),
                    epAckReg < Const(1),
                    epState < Const(epIdle, width: 1),
                  ],
                ),
              ]),
            ]),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              Case(bus.addr, [
                // 0x000: CTRL
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we & bus.selAny(0x00, 1),
                    then: [enable < bus.dataIn[0]],
                    orElse: [bus.dataOut < enable.zeroExtend(32)],
                  ),
                ]),
                // 0x004: STATUS (link_up, neg gen/lanes, ltssm state)
                CaseItem(Const(0x08, width: 12), [
                  bus.dataOut <
                      linkUp.zeroExtend(32) |
                          (negGen.zeroExtend(32) << Const(4, width: 32)) |
                          (negLanes.zeroExtend(32) << Const(8, width: 32)) |
                          (ltssm.zeroExtend(32) << Const(16, width: 32)),
                ]),
                // 0x008: LINK_CTRL ([0] retrain, [1] link disable)
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we & bus.selAny(0x10, 1),
                    then: [
                      retrainReq < bus.dataIn[0],
                      linkDisable < bus.dataIn[1],
                    ],
                    orElse: [
                      bus.dataOut <
                          linkDisable.zeroExtend(32) << Const(1, width: 32),
                    ],
                  ),
                ]),
                // 0x00C: INT_STATUS (W1C)
                CaseItem(Const(0x18, width: 12), [
                  If(
                    bus.we,
                    then: [intStatus < (intStatus & ~bus.selMasked(0x18, 8))],
                    orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                  ),
                ]),
                // 0x010: INT_ENABLE
                CaseItem(Const(0x20, width: 12), [
                  If(
                    bus.we,
                    then: [intEnable < bus.selMerge(intEnable, 0x20)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                  ),
                ]),
                // 0x014: ERR_STATUS
                CaseItem(Const(0x28, width: 12), [
                  If(
                    bus.we,
                    then: [errStatus < (errStatus & ~bus.selMasked(0x28, 8))],
                    orElse: [bus.dataOut < errStatus.zeroExtend(32)],
                  ),
                ]),
                // 0x020: BAR0_BASE
                CaseItem(Const(0x40, width: 12), [
                  If(
                    bus.we,
                    then: [bar0Base < bus.selMerge(bar0Base, 0x40)],
                    orElse: [bus.dataOut < bar0Base],
                  ),
                ]),
                // 0x024: BAR0_MASK
                CaseItem(Const(0x48, width: 12), [
                  If(
                    bus.we,
                    then: [bar0Mask < bus.selMerge(bar0Mask, 0x48)],
                    orElse: [bus.dataOut < bar0Mask],
                  ),
                ]),
                // 0x028: BAR1_BASE
                CaseItem(Const(0x50, width: 12), [
                  If(
                    bus.we,
                    then: [bar1Base < bus.selMerge(bar1Base, 0x50)],
                    orElse: [bus.dataOut < bar1Base],
                  ),
                ]),
                // 0x02C: BAR1_MASK
                CaseItem(Const(0x58, width: 12), [
                  If(
                    bus.we,
                    then: [bar1Mask < bus.selMerge(bar1Mask, 0x58)],
                    orElse: [bus.dataOut < bar1Mask],
                  ),
                ]),
                // 0x040: MSI_ADDR
                CaseItem(Const(0x80, width: 12), [
                  If(
                    bus.we,
                    then: [msiAddr < bus.selMerge(msiAddr, 0x80)],
                    orElse: [bus.dataOut < msiAddr],
                  ),
                ]),
                // 0x044: MSI_DATA
                CaseItem(Const(0x88, width: 12), [
                  If(
                    bus.we,
                    then: [msiData < bus.selMerge(msiData, 0x88)],
                    orElse: [bus.dataOut < msiData.zeroExtend(32)],
                  ),
                ]),
                // 0x048: MSI_MASK
                CaseItem(Const(0x90, width: 12), [
                  If(
                    bus.we,
                    then: [msiMask < bus.selMerge(msiMask, 0x90)],
                    orElse: [bus.dataOut < msiMask],
                  ),
                ]),
                // 0x04C: MSI_PEND
                CaseItem(Const(0x98, width: 12), [bus.dataOut < msiPend]),
                // 0x050: TLP_ADDR_LO (PCIe target address, low 32 bits)
                CaseItem(Const(0xA0, width: 12), [
                  If(
                    bus.we,
                    then: [tlpAddrLo < bus.selMerge(tlpAddrLo, 0xA0)],
                    orElse: [bus.dataOut < tlpAddrLo],
                  ),
                ]),
                // 0x054: TLP_ADDR_HI
                CaseItem(Const(0xA8, width: 12), [
                  If(
                    bus.we,
                    then: [tlpAddrHi < bus.selMerge(tlpAddrHi, 0xA8)],
                    orElse: [bus.dataOut < tlpAddrHi],
                  ),
                ]),
                // 0x058: TLP_LEN (DWords), a write resets the data pointers
                CaseItem(Const(0xB0, width: 12), [
                  If(
                    bus.we & bus.selAny(0xB0, 1),
                    then: [
                      tlpLen < bus.dataIn.getRange(0, 4),
                      tlpWrPtr < Const(0, width: 4),
                      tlpRdPtr < Const(0, width: 4),
                    ],
                    orElse: [bus.dataOut < tlpLen.zeroExtend(32)],
                  ),
                ]),
                // 0x05C: TLP_CTRL ([0] start, [1] is-write) assembles and sends
                CaseItem(Const(0xB8, width: 12), [
                  If(
                    bus.we & bus.dataIn[0] & bus.selAny(0xB8, 1),
                    then: [
                      tlpBusy < Const(1),
                      tlpDone < Const(0),
                      tlpIdx < Const(0, width: 4),
                      tlpTag < (tlpTag + Const(1, width: 8)),
                      msiBusy < Const(0),
                      hdr0 <
                          (mux(
                                    bus.dataIn[1],
                                    Const(0x40, width: 32),
                                    Const(0x00, width: 32),
                                  ) <<
                                  Const(24, width: 32)) |
                              tlpLen.zeroExtend(32),
                      hdr1 <
                          (tlpTag.zeroExtend(32) << Const(8, width: 32)) |
                              Const(0xFF, width: 32),
                      hdr2 < (tlpAddrLo & Const(0xFFFFFFFC, width: 32)),
                      tlpState <
                          mux(
                            bus.dataIn[1],
                            Const(tWrite, width: 2),
                            Const(tRead, width: 2),
                          ),
                      mAddrReg < tlpBase,
                      mWdataReg < dbufAt(Const(0, width: 4)),
                      mWeReg < bus.dataIn[1],
                      mStbReg < Const(1),
                    ],
                  ),
                ]),
                // 0x060: TLP_DATA (write fills the buffer, read drains it)
                CaseItem(Const(0xC0, width: 12), [
                  If(
                    bus.we,
                    then: [
                      for (var i = 0; i < tlpDepth; i++)
                        If(
                          tlpWrPtr.eq(Const(i, width: 4)),
                          then: [dbuf[i] < bus.selMerge(dbuf[i], 0xC0)],
                        ),
                      tlpWrPtr < (tlpWrPtr + Const(1, width: 4)),
                    ],
                    orElse: [
                      bus.dataOut < dbufAt(tlpRdPtr),
                      tlpRdPtr < (tlpRdPtr + Const(1, width: 4)),
                    ],
                  ),
                ]),
                // 0x064: TLP_STATUS ([0] busy, [1] done, [15:8] tag)
                CaseItem(Const(0xC8, width: 12), [
                  bus.dataOut <
                      tlpBusy.zeroExtend(32) |
                          (tlpDone.zeroExtend(32) << Const(1, width: 32)) |
                          (tlpTag.zeroExtend(32) << Const(8, width: 32)),
                ]),
                // 0x068/0x06C/0x070: assembled TLP header DWords (read-only)
                CaseItem(Const(0xD0, width: 12), [bus.dataOut < hdr0]),
                CaseItem(Const(0xD8, width: 12), [bus.dataOut < hdr1]),
                CaseItem(Const(0xE0, width: 12), [bus.dataOut < hdr2]),
                // 0x074: MSI_TRIGGER (write a vector to emit an MSI mem write)
                CaseItem(Const(0xE8, width: 12), [
                  If(
                    bus.we & bus.selAny(0xE8, 1),
                    then: [
                      tlpBusy < Const(1),
                      tlpDone < Const(0),
                      tlpIdx < Const(0, width: 4),
                      tlpLen < Const(1, width: 4),
                      tlpTag < (tlpTag + Const(1, width: 8)),
                      msiBusy < Const(1),
                      msiVec < bus.dataIn.getRange(0, 5),
                      hdr0 <
                          (Const(0x40, width: 32) << Const(24, width: 32)) |
                              Const(1, width: 32),
                      hdr1 <
                          (tlpTag.zeroExtend(32) << Const(8, width: 32)) |
                              Const(0xFF, width: 32),
                      hdr2 < (msiAddr & Const(0xFFFFFFFC, width: 32)),
                      tlpState < Const(tWrite, width: 2),
                      mAddrReg < msiAddr.zeroExtend(64),
                      mWdataReg <
                          (msiData.zeroExtend(32) |
                              bus.dataIn.getRange(0, 5).zeroExtend(32)),
                      mWeReg < Const(1),
                      mStbReg < Const(1),
                    ],
                  ),
                ]),
              ]),
            ],
          ),

          If(
            ecam.stb & ~ecam.ack,
            then: [
              ecam.ack < Const(1),
              If(
                // Only 00:00.0 (bus/dev/fn fields all zero) is the host bridge.
                ecam.addr.getRange(10, 26).eq(Const(0, width: 16)),
                then: [
                  // Match the full dword index, not just its low bits, so a
                  // reg field outside the map does not alias a defined
                  // register.
                  Case(ecam.addr, [
                    // 0x00: vendor / device ID
                    CaseItem(Const(0x00, width: 26), [
                      ecam.dataOut < Const(cfgVendorDevice, width: 32),
                    ]),
                    // 0x08: command / status
                    CaseItem(Const(0x01, width: 26), [
                      If(
                        ecam.we,
                        then: [cfgCommand < ecam.selMerge(cfgCommand, 0)],
                        orElse: [ecam.dataOut < cfgCommand.zeroExtend(32)],
                      ),
                    ]),
                    // 0x10: class code / revision
                    CaseItem(Const(0x02, width: 26), [
                      ecam.dataOut < Const(cfgClassRev, width: 32),
                    ]),
                    // 0x18: header type (0x01 = bridge)
                    CaseItem(Const(0x03, width: 26), [
                      ecam.dataOut < Const(cfgHeaderType, width: 32),
                    ]),
                    // 0x20: BAR0 (shared with the controller BAR0 register)
                    CaseItem(Const(0x04, width: 26), [
                      If(
                        ecam.we,
                        then: [bar0Base < ecam.selMerge(bar0Base, 0)],
                        orElse: [ecam.dataOut < bar0Base],
                      ),
                    ]),
                    // 0x28: BAR1
                    CaseItem(Const(0x05, width: 26), [
                      If(
                        ecam.we,
                        then: [bar1Base < ecam.selMerge(bar1Base, 0)],
                        orElse: [ecam.dataOut < bar1Base],
                      ),
                    ]),
                    // 0x30: primary/secondary/subordinate bus numbers
                    CaseItem(Const(0x06, width: 26), [
                      If(
                        ecam.we,
                        then: [cfgBusNumbers < ecam.selMerge(cfgBusNumbers, 0)],
                        orElse: [ecam.dataOut < cfgBusNumbers],
                      ),
                    ]),
                    // 0x68: capabilities pointer
                    CaseItem(Const(0x0D, width: 26), [
                      ecam.dataOut < Const(cfgCapPtr, width: 32),
                    ]),
                    // 0x80: MSI capability header
                    CaseItem(Const(0x10, width: 26), [
                      ecam.dataOut < Const(cfgMsiCap, width: 32),
                    ]),
                    // 0x88: MSI address (shared with MSI_ADDR register)
                    CaseItem(Const(0x11, width: 26), [
                      If(
                        ecam.we,
                        then: [msiAddr < ecam.selMerge(msiAddr, 0)],
                        orElse: [ecam.dataOut < msiAddr],
                      ),
                    ]),
                    // 0x98: MSI data (shared with MSI_DATA register)
                    CaseItem(Const(0x13, width: 26), [
                      If(
                        ecam.we,
                        then: [msiData < ecam.selMerge(msiData, 0)],
                        orElse: [ecam.dataOut < msiData.zeroExtend(32)],
                      ),
                    ]),
                  ]),
                ],
                // Any other function: master abort returns all ones on read.
                orElse: [ecam.dataOut < Const(0xFFFFFFFF, width: 32)],
              ),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: config.role == HarborPcieRole.rootComplex
        ? ['harbor,pcie-host', 'pci-host-ecam-generic']
        : ['harbor,pcie-ep'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'device_type': 'pci',
      '#address-cells': 3,
      '#size-cells': 2,
      'max-link-speed': config.maxGen.gen,
      'num-lanes': config.maxLanes.count,
      'msi-parent': true,
      'bus-range': [0, 255],
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': config.role == HarborPcieRole.rootComplex
          ? ['harbor,pcie-host', 'pci-host-ecam-generic']
          : ['harbor,pcie-ep'],
      'device_type': 'pci',
      '#address-cells': 3,
      '#size-cells': 2,
      'max-link-speed': config.maxGen.gen,
      'num-lanes': config.maxLanes.count,
      'msi-parent': true,
      'bus-range': [0, 255],
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'PCIE',
    groupName: 'PCIE',
    description: 'PCIe root complex or endpoint controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
