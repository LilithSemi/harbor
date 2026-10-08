import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// RISC-V IOMMU translation mode.
enum HarborIommuMode {
  /// Pass-through (no translation).
  bare,

  /// Single-stage (device virtual to physical).
  sv39,
  sv48,
  sv57,

  /// Two-stage (device virtual -> guest physical -> physical).
  sv39x4,
  sv48x4,
  sv57x4,
}

/// RISC-V IOMMU (I/O Memory Management Unit).
///
/// Provides address translation and protection for DMA-capable
/// devices. Required for:
/// - H extension guest isolation (two-stage translation)
/// - Device assignment to VMs
/// - DMA protection (PCI ATS/PRI)
///
/// Implements the RISC-V IOMMU specification with:
/// - Device directory (DD) for per-device translation config
/// - IOTLB for caching translations
/// - Hardware page table walker
/// - Fault/event queue
/// - MSI translation (MSI page table)
/// - Command queue for software-issued invalidations
///
/// Register map:
/// - 0x000: capabilities   0x008: fctl       0x010: ddtp
/// - 0x028: cqb            0x030: cqh        0x034: cqt
/// - 0x038: fqb            0x040: fqh        0x044: fqt
/// - 0x048: pqb            0x050: pqh        0x054: pqt
/// - 0x058: cqcsr          0x05C: fqcsr      0x060: pqcsr
/// - 0x064: ipsr           0x100: iohpmcycles
/// - 0x108-0x1F8: iohpmctr/iohpmevt
class HarborIommu extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address for IOMMU registers.
  final int baseAddress;

  /// Number of IOTLB entries.
  final int iotlbEntries;

  /// Maximum supported translation mode.
  final HarborIommuMode maxMode;

  /// Number of device directory entries.
  final int numDevices;

  /// Command queue depth.
  final int cmdQueueDepth;

  /// Fault queue depth.
  final int faultQueueDepth;

  /// Whether to support MSI translation.
  final bool msiTranslation;

  /// Whether to support ATS (Address Translation Services).
  final bool atsSupport;

  /// Bus slave port for register access.
  late final BusSlavePort regBus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborIommu({
    required this.baseAddress,
    this.iotlbEntries = 64,
    this.maxMode = HarborIommuMode.sv48x4,
    this.numDevices = 256,
    this.cmdQueueDepth = 64,
    this.faultQueueDepth = 64,
    this.msiTranslation = true,
    this.atsSupport = false,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborIommu', name: name ?? 'iommu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('interrupt');

    // Register interface
    regBus = BusSlavePort.create(
      module: this,
      name: 'reg',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 64,
    );

    // DMA request input (from device)
    createPort('dma_addr', PortDirection.input, width: 64);
    createPort('dma_valid', PortDirection.input);
    createPort('dma_write', PortDirection.input);
    createPort('dma_device_id', PortDirection.input, width: 24);

    // Translated DMA output (to memory)
    addOutput('dma_translated_addr', width: 64);
    addOutput('dma_translated_valid');
    addOutput('dma_fault');
    addOutput('dma_fault_cause', width: 8);

    // Memory interface (for page table walks)
    addOutput('ptw_addr', width: 64);
    addOutput('ptw_read');
    createPort('ptw_data', PortDirection.input, width: 64);
    createPort('ptw_valid', PortDirection.input);

    // MSI translation output
    if (msiTranslation) {
      addOutput('msi_addr', width: 64);
      addOutput('msi_data', width: 32);
      addOutput('msi_valid');
    }

    final clk = input('clk');
    final reset = input('reset');
    final dmaAddr = input('dma_addr');
    final dmaValid = input('dma_valid');
    final dmaWrite = input('dma_write');
    final ptwData = input('ptw_data');
    final ptwValidIn = input('ptw_valid');

    // Translation FSM states.
    const sIdle = 0;
    const sWalk = 1; // issue a PTE read for the current level
    const sPte = 2; // consume the returned PTE

    // Fault causes (RISC-V IOMMU subset).
    const faultPageFault = 1; // invalid PTE
    const faultPermFault = 2; // R/W permission denied

    // IOMMU registers. ddtp[0] enables translation (else bare passthrough),
    // ddtp[63:12] is the Sv39 root page-table address (page-aligned). This is a
    // single-context simplification of the full per-device directory.
    final capabilities = Logic(name: 'capabilities', width: 64);
    final fctl = Logic(name: 'fctl', width: 64);
    final ddtp = Logic(name: 'ddtp', width: 64);
    final ipsr = Logic(name: 'ipsr', width: 32);

    // Direct-mapped IOTLB: VPN -> PPN with R/W permissions.
    final idxBits = iotlbEntries <= 1 ? 1 : (iotlbEntries - 1).bitLength;
    final n = 1 << idxBits;
    final tlbValid = [for (var i = 0; i < n; i++) Logic(name: 'tlb_v$i')];
    final tlbTag = [
      for (var i = 0; i < n; i++) Logic(name: 'tlb_tag$i', width: 27),
    ];
    final tlbPpn = [
      for (var i = 0; i < n; i++) Logic(name: 'tlb_ppn$i', width: 44),
    ];
    final tlbR = [for (var i = 0; i < n; i++) Logic(name: 'tlb_r$i')];
    final tlbW = [for (var i = 0; i < n; i++) Logic(name: 'tlb_w$i')];

    // Translation engine state.
    final ioState = Logic(name: 'io_state', width: 2);
    final walkLevel = Logic(name: 'walk_level', width: 2);
    final walkBase = Logic(name: 'walk_base', width: 64); // table base address
    final reqVa = Logic(name: 'req_va', width: 64);
    final reqWrite = Logic(name: 'req_write');
    final transAddrReg = Logic(name: 'trans_addr_reg', width: 64);
    final transValidReg = Logic(name: 'trans_valid_reg');
    final faultReg = Logic(name: 'fault_reg');
    final faultCauseReg = Logic(name: 'fault_cause_reg', width: 8);
    final ptwAddrReg = Logic(name: 'ptw_addr_reg', width: 64);
    final ptwReadReg = Logic(name: 'ptw_read_reg');

    // VA decomposition (Sv39).
    final offset = reqVa.getRange(0, 12);
    final vpn = reqVa.getRange(12, 39); // 27-bit virtual page number
    final vpn0 = reqVa.getRange(12, 21);
    final vpn1 = reqVa.getRange(21, 30);
    final vpn2 = reqVa.getRange(30, 39);
    final tlbIndex = vpn.getRange(0, idxBits);
    final tlbTagOf = vpn.getRange(idxBits, 27).zeroExtend(27);

    // IOTLB lookup (indexed read).
    Logic tlbMux(List<Logic> arr) {
      Logic out = arr[0];
      for (var i = 1; i < n; i++) {
        out = mux(tlbIndex.eq(Const(i, width: idxBits)), arr[i], out);
      }
      return out;
    }

    final hitValid = tlbMux(tlbValid);
    final hitTag = tlbMux(tlbTag);
    final hitPpn = tlbMux(tlbPpn);
    final hitR = tlbMux(tlbR);
    final hitW = tlbMux(tlbW);
    final tlbHit = (hitValid & hitTag.eq(tlbTagOf)).named('tlb_hit');

    // Sv39 root and per-level VPN.
    final rootAddr = [ddtp.getRange(12, 64), Const(0, width: 12)].swizzle();
    final levelVpn = mux(
      walkLevel.eq(Const(2, width: 2)),
      vpn2,
      mux(walkLevel.eq(Const(1, width: 2)), vpn1, vpn0),
    );
    // PTE fields of the returned word.
    final pteV = ptwData[0];
    final pteR = ptwData[1];
    final pteW = ptwData[2];
    final pteX = ptwData[3];
    final ptePpn = ptwData.getRange(10, 54); // 44-bit PPN
    final pteLeaf = (pteR | pteX).named('pte_leaf');

    final translatedPpnOffset = [
      hitPpn,
      offset,
    ].swizzle().zeroExtend(64); // {ppn, offset}
    final walkPpnOffset = [ptePpn, offset].swizzle().zeroExtend(64);

    interrupt <= ipsr.or();

    output('dma_translated_addr') <= transAddrReg;
    output('dma_translated_valid') <= transValidReg;
    output('dma_fault') <= faultReg;
    output('dma_fault_cause') <= faultCauseReg;
    output('ptw_addr') <= ptwAddrReg;
    output('ptw_read') <= ptwReadReg;
    if (msiTranslation) {
      output('msi_addr') <= Const(0, width: 64);
      output('msi_data') <= Const(0, width: 32);
      output('msi_valid') <= Const(0);
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          // Capability register: report Sv39 single-stage support (version 1.0).
          capabilities < Const(0x0102, width: 64),
          fctl < Const(0, width: 64),
          ddtp < Const(0, width: 64),
          ipsr < Const(0, width: 32),
          for (var i = 0; i < n; i++) ...[
            tlbValid[i] < Const(0),
            tlbTag[i] < Const(0, width: 27),
            tlbPpn[i] < Const(0, width: 44),
            tlbR[i] < Const(0),
            tlbW[i] < Const(0),
          ],
          ioState < Const(sIdle, width: 2),
          walkLevel < Const(0, width: 2),
          walkBase < Const(0, width: 64),
          reqVa < Const(0, width: 64),
          reqWrite < Const(0),
          transAddrReg < Const(0, width: 64),
          transValidReg < Const(0),
          faultReg < Const(0),
          faultCauseReg < Const(0, width: 8),
          ptwAddrReg < Const(0, width: 64),
          ptwReadReg < Const(0),
          regBus.ack < Const(0),
          regBus.dataOut < Const(0, width: 64),
        ],
        orElse: [
          // Single-cycle pulses by default.
          transValidReg < Const(0),
          faultReg < Const(0),

          // Translation engine.
          Case(ioState, [
            CaseItem(Const(sIdle, width: 2), [
              If(
                dmaValid,
                then: [
                  reqVa < dmaAddr,
                  reqWrite < dmaWrite,
                  If(
                    ~ddtp[0],
                    // Bare: pass the address through untranslated.
                    then: [transAddrReg < dmaAddr, transValidReg < Const(1)],
                    orElse: [
                      // Translate. Try the IOTLB first.
                      If(
                        tlbHit,
                        then: [
                          If(
                            dmaWrite & ~hitW | ~dmaWrite & ~hitR,
                            then: [
                              faultReg < Const(1),
                              faultCauseReg < Const(faultPermFault, width: 8),
                            ],
                            orElse: [
                              transAddrReg < translatedPpnOffset,
                              transValidReg < Const(1),
                            ],
                          ),
                        ],
                        // Miss: walk the page table from the root.
                        orElse: [
                          walkBase < rootAddr,
                          walkLevel < Const(2, width: 2),
                          ioState < Const(sWalk, width: 2),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sWalk, width: 2), [
              ptwAddrReg <
                  (walkBase + (levelVpn.zeroExtend(64) << Const(3, width: 64))),
              ptwReadReg < Const(1),
              ioState < Const(sPte, width: 2),
            ]),
            CaseItem(Const(sPte, width: 2), [
              If(
                ptwValidIn,
                then: [
                  ptwReadReg < Const(0),
                  If(
                    ~pteV,
                    // Invalid PTE -> page fault.
                    then: [
                      faultReg < Const(1),
                      faultCauseReg < Const(faultPageFault, width: 8),
                      ioState < Const(sIdle, width: 2),
                    ],
                    orElse: [
                      If(
                        pteLeaf,
                        then: [
                          // Leaf: fill the IOTLB and translate (or perm-fault).
                          for (var i = 0; i < n; i++)
                            If(
                              tlbIndex.eq(Const(i, width: idxBits)),
                              then: [
                                tlbValid[i] < Const(1),
                                tlbTag[i] < tlbTagOf,
                                tlbPpn[i] < ptePpn,
                                tlbR[i] < pteR,
                                tlbW[i] < pteW,
                              ],
                            ),
                          If(
                            reqWrite & ~pteW | ~reqWrite & ~pteR,
                            then: [
                              faultReg < Const(1),
                              faultCauseReg < Const(faultPermFault, width: 8),
                            ],
                            orElse: [
                              transAddrReg < walkPpnOffset,
                              transValidReg < Const(1),
                            ],
                          ),
                          ioState < Const(sIdle, width: 2),
                        ],
                        orElse: [
                          // Pointer to the next level.
                          If(
                            walkLevel.eq(Const(0, width: 2)),
                            // No leaf at the last level -> fault.
                            then: [
                              faultReg < Const(1),
                              faultCauseReg < Const(faultPageFault, width: 8),
                              ioState < Const(sIdle, width: 2),
                            ],
                            orElse: [
                              walkBase <
                                  [
                                    ptePpn,
                                    Const(0, width: 12),
                                  ].swizzle().zeroExtend(64),
                              walkLevel < (walkLevel - Const(1, width: 2)),
                              ioState < Const(sWalk, width: 2),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
          ]),

          // Register access (64-bit registers, 8-byte aligned: index addr[6:3]).
          // Match the full address, not just enough low bits for the registers
          // defined today, so an address outside the map reads 0 and ignores
          // writes instead of aliasing a register.
          regBus.ack < Const(0),
          regBus.dataOut < Const(0, width: 64),
          If(
            regBus.stb & ~regBus.ack,
            then: [
              regBus.ack < Const(1),
              Case(regBus.addr.getRange(3, 12), [
                // 0x000: capabilities (read-only).
                CaseItem(Const(0, width: 9), [regBus.dataOut < capabilities]),
                // 0x008: fctl.
                CaseItem(Const(1, width: 9), [
                  If(
                    regBus.we,
                    then: [fctl < regBus.selMerge(fctl, 0x008)],
                    orElse: [regBus.dataOut < fctl],
                  ),
                ]),
                // 0x010: ddtp.
                CaseItem(Const(2, width: 9), [
                  If(
                    regBus.we,
                    then: [ddtp < regBus.selMerge(ddtp, 0x010)],
                    orElse: [regBus.dataOut < ddtp],
                  ),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['riscv,iommu'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      '#iommu-cells': 1,
      'riscv,iotlb-entries': iotlbEntries,
      'riscv,max-mode': maxMode.name,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['riscv,iommu'],
      '#iommu-cells': 1,
      'riscv,iotlb-entries': iotlbEntries,
      'riscv,max-mode': maxMode.name,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'IOMMU',
    groupName: 'IOMMU',
    description: 'RISC-V I/O Memory Management Unit',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
