import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../blackbox/xilinx/xilinx.dart';
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import 'device_register.dart';

/// Where [HarborUnitId] gets the unit identifier.
enum HarborUnitIdSource {
  /// Xilinx 7-series device DNA, 57 bits, read with the DNA_PORT primitive.
  dna57(1, 57);

  const HarborUnitIdSource(this.code, this.widthBits);

  /// Value of the SOURCE field in the INFO register.
  final int code;

  /// Width of the identifier in bits.
  final int widthBits;
}

/// Read-only block that exposes the unique identifier of the FPGA.
///
/// A small state machine on the bus clock reads the identifier once after
/// reset. For [HarborUnitIdSource.dna57] it loads the DNA_PORT shift register
/// and shifts out 57 bits, MSB first (UG470, Device Identifier and Device
/// DNA). The DNA_PORT clock is the bus clock divided by [clockDivide].
///
/// Register map (each register in its own 64-bit slot):
/// - 0x00: ID_LO  (read-only, identifier bits 31:0, 0 until valid)
/// - 0x08: ID_HI  (read-only, identifier bits 63:32, 0 until valid)
/// - 0x10: INFO   (read-only, bit 0: valid, bits 7:4: source code, bits 15:8:
///   identifier width in bits)
///
/// A unit with no identifier source in its build does not have this block, see
/// [HarborUnitId.fromTarget].
class HarborUnitId extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborSvdPeripheralProvider {
  /// Largest DNA_PORT clock rate in Hz that is valid for every speed grade
  /// (DS181, FDNACK, -2LE grade).
  static const int maxDnaClockHz = 70000000;

  /// Smallest [clockDivide]. The state changes the control signals half a
  /// DNA_PORT period after the rising edge, and at least one bus cycle must
  /// pass before the next rising edge.
  static const int minClockDivide = 4;

  /// Register offsets.
  static const int idLowOffset = 0x00;
  static const int idHighOffset = 0x08;
  static const int infoOffset = 0x10;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Source of the identifier.
  final HarborUnitIdSource source;

  /// Bus clock cycles for each DNA_PORT clock cycle. At least [minClockDivide].
  final int clockDivide;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Smallest [clockDivide] that keeps the DNA_PORT clock at or below
  /// [maxDnaClockHz] when the bus clock runs at [busClockHz].
  static int clockDivideFor(int busClockHz) {
    if (busClockHz <= 0) {
      throw ArgumentError.value(busClockHz, 'busClockHz', 'must be > 0');
    }
    final divide = (busClockHz + maxDnaClockHz - 1) ~/ maxDnaClockHz;
    return divide < minClockDivide ? minClockDivide : divide;
  }

  /// Creates the block for [target], or returns null when the target has no
  /// identifier source.
  ///
  /// [busClockHz] is the rate of the clock the block runs on.
  static HarborUnitId? fromTarget({
    required int baseAddress,
    required HarborDeviceTarget target,
    required int busClockHz,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    int? busAddressWidth,
    int? busDataWidth,
    String? name,
  }) {
    final source = switch (target) {
      HarborFpgaTarget(vendor: HarborFpgaVendor.vivado) ||
      HarborFpgaTarget(
        vendor: HarborFpgaVendor.openXc7,
      ) => HarborUnitIdSource.dna57,
      _ => null,
    };
    if (source == null) return null;
    return HarborUnitId(
      baseAddress: baseAddress,
      source: source,
      clockDivide: clockDivideFor(busClockHz),
      fabricKind: fabricKind,
      crossFabricClock: crossFabricClock,
      busAddressWidth: busAddressWidth,
      busDataWidth: busDataWidth,
      name: name,
    );
  }

  /// [simDnaValue] is the identifier that the simulation model returns.
  HarborUnitId({
    required this.baseAddress,
    this.source = HarborUnitIdSource.dna57,
    this.clockDivide = 4,
    BigInt? simDnaValue,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    int? busAddressWidth,
    int? busDataWidth,
    String? name,
  }) : super(
         harborStableDefinitionName('HarborUnitId', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: busAddressWidth ?? 12,
             dataWidth: busDataWidth ?? 32,
             cross: crossFabricClock,
           ),
           source.name,
           'div$clockDivide',
           if (simDnaValue != null && simDnaValue != BigInt.zero)
             'sv${simDnaValue.toRadixString(16)}',
         ]),
         name: name ?? 'unit_id',
       ) {
    if (clockDivide < minClockDivide) {
      throw ArgumentError.value(
        clockDivide,
        'clockDivide',
        'must be >= $minClockDivide',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final dataWidth = busDataWidth ?? 32;
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: fabricKind,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth ?? 12,
      dataWidth: dataWidth,
      fabricClock: BusSlavePort.fabricClockInputs(
        this,
        cross: crossFabricClock,
      ),
    );

    final clk = input('clk');
    final reset = bus.reset;
    final width = source.widthBits;

    final dnaClk = Logic(name: 'dna_clk');
    final dnaRead = Logic(name: 'dna_read');
    final dnaShift = Logic(name: 'dna_shift');
    final port = addSubModule(
      XilinxDnaPort(
        clk: dnaClk,
        din: Const(0),
        read: dnaRead,
        shift: dnaShift,
        simDnaValue: simDnaValue,
      ),
    );

    // The DNA_PORT clock is high for the first half of each period. The state
    // advances in the middle of the period, away from the DNA_PORT clock edge,
    // so DOUT and the control signals never change together.
    final phaseWidth = (clockDivide - 1).bitLength;
    final phase = Logic(name: 'phase', width: phaseWidth);
    final nextPhase = mux(
      phase.eq(Const(clockDivide - 1, width: phaseWidth)),
      Const(0, width: phaseWidth),
      phase + 1,
    );
    final advance = phase.eq(Const(clockDivide ~/ 2, width: phaseWidth));

    // Step 0 loads the shift register. Steps 1 to [width] each sample DOUT. The
    // step after the last sample is the end.
    final stepWidth = (width + 2).bitLength;
    final step = Logic(name: 'step', width: stepWidth);
    final id = Logic(name: 'id', width: width);
    final valid = Logic(name: 'valid');

    Sequential(clk, [
      If(
        reset,
        then: [
          phase < Const(clockDivide - 1, width: phaseWidth),
          dnaClk < Const(0),
          dnaRead < Const(0),
          dnaShift < Const(0),
          step < Const(0, width: stepWidth),
          id < Const(0, width: width),
          valid < Const(0),
        ],
        orElse: [
          phase < nextPhase,
          dnaClk <
              (nextPhase.lt(Const(clockDivide ~/ 2, width: phaseWidth)) &
                  ~valid),
          If(
            advance,
            then: [
              Case(
                step,
                [
                  CaseItem(Const(0, width: stepWidth), [
                    dnaRead < Const(1),
                    step < Const(1, width: stepWidth),
                  ]),
                  CaseItem(Const(1, width: stepWidth), [
                    id < [id.getRange(0, width - 1), port.dout].concat(),
                    dnaRead < Const(0),
                    dnaShift < Const(1),
                    step < Const(2, width: stepWidth),
                  ]),
                ],
                defaultItem: [
                  If(
                    step.lte(Const(width, width: stepWidth)),
                    then: [
                      id < [id.getRange(0, width - 1), port.dout].concat(),
                      step < step + 1,
                      If(
                        step.eq(Const(width, width: stepWidth)),
                        then: [dnaShift < Const(0), valid < Const(1)],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    final infoWord = [
      Const(0, width: 16),
      Const(width, width: 8),
      Const(source.code, width: 4),
      Const(0, width: 3),
      valid,
    ].concat();
    // 64-bit view of the identifier, 0 until valid.
    final id64 = mux(valid, id.zeroExtend(64), Const(0, width: 64));

    final datOut32 = Logic(name: 'unit_id_dat_out', width: 32);
    bus.dataOut <= datOut32.zeroExtend(bus.dataOut.width);

    final addrField = bus.windowAddr(0x1000);
    Sequential(clk, [
      If(
        reset,
        then: [bus.ack < Const(0), datOut32 < Const(0, width: 32)],
        orElse: [
          bus.ack < Const(0),
          datOut32 < Const(0, width: 32),
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),
              Case(addrField, [
                CaseItem(Const(idLowOffset, width: addrField.width), [
                  datOut32 < id64.getRange(0, 32),
                ]),
                CaseItem(Const(idHighOffset, width: addrField.width), [
                  datOut32 < id64.getRange(32, 64),
                ]),
                CaseItem(Const(infoOffset, width: addrField.width), [
                  datOut32 < infoWord,
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  static const _registers = HarborDeviceRegisterMap(
    name: 'unit_id',
    fields: [
      HarborDeviceField(
        name: 'id_lo',
        width: 4,
        offset: idLowOffset,
        readOnly: true,
      ),
      HarborDeviceField(
        name: 'id_hi',
        width: 4,
        offset: idHighOffset,
        readOnly: true,
      ),
      HarborDeviceField(
        name: 'info',
        width: 4,
        offset: infoOffset,
        readOnly: true,
      ),
    ],
  );

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,unit-id'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'harbor,id-source': source.name},
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'UNIT_ID',
    groupName: 'UNIT_ID',
    description: 'Unique device identifier of the FPGA',
    baseAddress: baseAddress,
    size: 0x1000,
    registers: _registers,
  );
}
