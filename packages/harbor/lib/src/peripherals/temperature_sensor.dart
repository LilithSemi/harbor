import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../pdk/pdk_provider.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';

/// Temperature sensor source backend.
///
/// Automatically determined from the [HarborDeviceTarget] when not
/// specified explicitly.
enum HarborTemperatureSource {
  /// ASIC bandgap reference (PDK-provided analog block).
  bandgap,

  /// Xilinx 7-series XADC (channel 0).
  xilinxXadc,

  /// Lattice ECP5 DTR primitive.
  ecp5Dtr,

  /// External: user provides raw input signals directly.
  external_,
}

/// On-die temperature sensor peripheral.
///
/// Automatically instantiates the correct backend based on the build target:
/// - **Xilinx 7-series**: instantiates [XilinxXadc], reads temperature from channel 0
/// - **ECP5**: instantiates [Ecp5Dtr], reads 8-bit die temperature
/// - **ASIC (Sky130/GF180)**: references the PDK bandgap sensor via
///   [PdkProvider.temperatureSensor]
/// - **iCE40**: not supported (no on-die sensor)
///
/// If no target is given, the sensor exposes raw `temp_raw_in` / `temp_valid_in`
/// ports for manual wiring.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL      (bit 0: enable, bit 1: continuous mode)
/// - 0x08: STATUS    (bit 0: data valid, bit 1: over-temperature)
/// - 0x10: TEMP_RAW  (read-only, raw sensor value, 12 bits)
/// - 0x18: TEMP_C    (read-only, temperature in millidegrees C, signed 32-bit)
/// - 0x20: ALARM_HI  (read/write, high temperature alarm threshold, millidegrees C)
/// - 0x28: ALARM_LO  (read/write, low temperature alarm threshold, millidegrees C)
/// - 0x30: INT_STATUS (read/write-1-to-clear)
/// - 0x38: INT_ENABLE (read/write, interrupt enable mask)
class HarborTemperatureSensor extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Temperature source backend (auto-detected from target if not given).
  final HarborTemperatureSource source;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// The XADC instance (only when targeting Xilinx).
  XilinxXadc? xadc;

  /// The DTR instance (only when targeting ECP5).
  Ecp5Dtr? dtr;

  /// The PDK analog block reference (only when targeting ASIC).
  final PdkProvider? pdk;

  /// Creates a temperature sensor, auto-wiring the backend from [target].
  ///
  /// If [target] is null, the sensor exposes raw `temp_raw_in` and
  /// `temp_valid_in` input ports for manual connection.
  factory HarborTemperatureSensor.fromTarget({
    required int baseAddress,
    required HarborDeviceTarget target,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) {
    final source = switch (target) {
      HarborFpgaTarget(vendor: HarborFpgaVendor.vivado) =>
        HarborTemperatureSource.xilinxXadc,
      HarborFpgaTarget(vendor: HarborFpgaVendor.openXc7) =>
        HarborTemperatureSource.xilinxXadc,
      HarborFpgaTarget(vendor: HarborFpgaVendor.ecp5) =>
        HarborTemperatureSource.ecp5Dtr,
      HarborFpgaTarget(vendor: HarborFpgaVendor.ice40) => throw ArgumentError(
        'iCE40 has no on-die temperature sensor',
      ),
      // Verilator has no die and no vendor sensor primitive. Expose the raw
      // input ports so the harness can drive whatever reading a test wants.
      HarborSimTarget() => HarborTemperatureSource.external_,
      HarborAsicTarget(provider: final pdk) when pdk.hasTemperatureSensor =>
        HarborTemperatureSource.bandgap,
      HarborAsicTarget() => throw ArgumentError(
        'PDK does not provide a temperature sensor',
      ),
    };

    final pdk = target is HarborAsicTarget ? target.provider : null;

    return HarborTemperatureSensor(
      baseAddress: baseAddress,
      source: source,
      pdk: pdk,
      protocol: protocol,
      name: name,
    );
  }

  HarborTemperatureSensor({
    required this.baseAddress,
    this.source = HarborTemperatureSource.external_,
    this.pdk,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborTemperatureSensor', name: name ?? 'temp_sensor') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('interrupt');

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

    // Backend instantiation
    Logic tempRawIn;
    Logic tempValidIn;

    switch (source) {
      case HarborTemperatureSource.xilinxXadc:
        xadc = XilinxXadc(name: 'xadc_temp');
        xadc!.input('DCLK').srcConnection! <= clk;
        xadc!.input('RESET').srcConnection! <= reset;
        xadc!.input('DEN').srcConnection! <= Const(1);
        xadc!.input('DWE').srcConnection! <= Const(0);
        xadc!.input('DADDR').srcConnection! <=
            Const(0, width: 7); // channel 0 = temp
        xadc!.input('DI').srcConnection! <= Const(0, width: 16);
        xadc!.input('CONVST').srcConnection! <= Const(0);
        xadc!.input('CONVSTCLK').srcConnection! <= Const(0);
        xadc!.input('VP').srcConnection! <= Const(0);
        xadc!.input('VN').srcConnection! <= Const(0);
        // XADC DO[15:4] is the 12-bit result
        tempRawIn = xadc!.output('DO').getRange(4, 16);
        tempValidIn = xadc!.output('DRDY');

      case HarborTemperatureSource.ecp5Dtr:
        dtr = Ecp5Dtr(name: 'dtr_temp');
        // Pulse STARTPULSE periodically. Use a simple counter
        final startPulse = Logic(name: 'dtr_start');
        final dtrCounter = Logic(name: 'dtr_counter', width: 20);
        Sequential(clk, [
          If(
            reset,
            then: [dtrCounter < Const(0, width: 20), startPulse < Const(0)],
            orElse: [
              dtrCounter < dtrCounter + 1,
              startPulse < Const(0),
              If(
                dtrCounter.eq(Const(0, width: 20)),
                then: [startPulse < Const(1)],
              ),
            ],
          ),
        ]);
        dtr!.input('STARTPULSE').srcConnection! <= startPulse;
        // DTR provides 8-bit result, zero-extend to 12
        tempRawIn = dtr!.output('DTROUT8').zeroExtend(12);
        // Valid one cycle after start pulse (simplified)
        final dtrValid = Logic(name: 'dtr_valid');
        Sequential(clk, [
          If(
            reset,
            then: [dtrValid < Const(0)],
            orElse: [dtrValid < startPulse],
          ),
        ]);
        tempValidIn = dtrValid;

      case HarborTemperatureSource.bandgap:
      case HarborTemperatureSource.external_:
        // Expose raw ports for external wiring
        createPort('temp_raw_in', PortDirection.input, width: 12);
        tempRawIn = input('temp_raw_in');
        createPort('temp_valid_in', PortDirection.input);
        tempValidIn = input('temp_valid_in');
    }

    // Register logic
    final ctrl = Logic(name: 'ctrl', width: 2);
    final tempRaw = Logic(name: 'temp_raw', width: 12);
    final tempC = Logic(name: 'temp_c', width: 32);
    final dataValid = Logic(name: 'data_valid');
    final overTemp = Logic(name: 'over_temp');
    final alarmHi = Logic(name: 'alarm_hi', width: 32);
    final alarmLo = Logic(name: 'alarm_lo', width: 32);
    final intStatus = Logic(name: 'int_status', width: 3);
    final intEnable = Logic(name: 'int_enable', width: 3);

    interrupt <= (intStatus & intEnable).or();

    Sequential(clk, [
      If(
        reset,
        then: [
          ctrl < Const(0, width: 2),
          tempRaw < Const(0, width: 12),
          tempC < Const(0, width: 32),
          dataValid < Const(0),
          overTemp < Const(0),
          alarmHi < Const(85000, width: 32),
          alarmLo < Const(0, width: 32),
          intStatus < Const(0, width: 3),
          intEnable < Const(0, width: 3),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          // Latch temperature when valid and enabled
          If(
            ctrl[0] & tempValidIn,
            then: [
              tempRaw < tempRawIn,
              dataValid < Const(1),
              intStatus < (intStatus | Const(1, width: 3)),
            ],
          ),

          // Alarm check
          If(
            dataValid & (tempC.gt(alarmHi)),
            then: [
              overTemp < Const(1),
              intStatus < (intStatus | Const(2, width: 3)),
            ],
          ),
          If(
            dataValid & (tempC.lt(alarmLo)),
            then: [intStatus < (intStatus | Const(4, width: 3))],
          ),

          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Decode every address bit of the 0x1000 window and ignore the
              // bits above it, so absolute and relative addresses both work. An
              // unused offset reads 0 and ignores writes.
              Case(bus.windowAddr(0x1000), [
                // 0x00: CTRL
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we,
                    then: [ctrl < bus.selMerge(ctrl, 0x00)],
                    orElse: [bus.dataOut < ctrl.zeroExtend(32)],
                  ),
                ]),
                // 0x08: STATUS
                CaseItem(Const(0x08, width: 12), [
                  bus.dataOut <
                      [Const(0, width: 30), overTemp, dataValid].swizzle(),
                ]),
                // 0x10: TEMP_RAW
                CaseItem(Const(0x10, width: 12), [
                  bus.dataOut < tempRaw.zeroExtend(32),
                ]),
                // 0x18: TEMP_C
                CaseItem(Const(0x18, width: 12), [bus.dataOut < tempC]),
                // 0x20: ALARM_HI
                CaseItem(Const(0x20, width: 12), [
                  If(
                    bus.we,
                    then: [alarmHi < bus.selMerge(alarmHi, 0x20)],
                    orElse: [bus.dataOut < alarmHi],
                  ),
                ]),
                // 0x28: ALARM_LO
                CaseItem(Const(0x28, width: 12), [
                  If(
                    bus.we,
                    then: [alarmLo < bus.selMerge(alarmLo, 0x28)],
                    orElse: [bus.dataOut < alarmLo],
                  ),
                ]),
                // 0x30: INT_STATUS (write-1-to-clear)
                CaseItem(Const(0x30, width: 12), [
                  If(
                    bus.we,
                    then: [intStatus < (intStatus & ~bus.selMasked(0x30, 3))],
                    orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                  ),
                ]),
                // 0x38: INT_ENABLE
                CaseItem(Const(0x38, width: 12), [
                  If(
                    bus.we,
                    then: [intEnable < bus.selMerge(intEnable, 0x38)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(32)],
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
    compatible: ['harbor,temp-sensor'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'#thermal-sensor-cells': 0, 'harbor,source': source.name},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,temp-sensor'],
      '#thermal-sensor-cells': 0,
      'harbor,source': source.name,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'TEMP',
    groupName: 'TEMP',
    description: 'On-die temperature sensor',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
