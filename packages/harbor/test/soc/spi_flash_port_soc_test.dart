// A HarborSoC with the SPI flash CPU write port: the port window through the
// fabric, and the device tree, ACPI and SVD text.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

const _xip = 0x20000000;
const _port = 0x21000000;

/// Partitions the way River lays them out on an FPGA target.
const _river = [
  HarborFlashPartition(label: 'fpga-bitstream', offset: 0, size: 0x400000),
  HarborFlashPartition(label: 'river-fsbl', offset: 0x400000, size: 0x10000),
  HarborFlashPartition(
    label: 'river-firmware',
    offset: 0x410000,
    size: 0x300000,
  ),
];

HarborSpiFlashController _flash(
  HarborFabricKind kind, {
  List<HarborFlashPartition> partitions = _river,
  int? port = _port,
}) => HarborSpiFlashController(
  clockHz: 100000000,
  config: HarborSpiFlashConfig.n25q128(partitions: partitions),
  baseAddress: _xip,
  busAddressWidth: 32,
  fabricKind: kind,
  cpuPortBase: port,
);

class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind)
    : super('FlashPortCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true),
      ),
      HarborFabricKind.axi4 => Axi4LiteInterface(
        addressWidth: 32,
        dataWidth: 32,
      ),
      HarborFabricKind.tilelink => TileLinkInterface(
        const TileLinkConfig(addressWidth: 32, dataWidth: 32),
      ),
    };
    final i = addInterface(
      intf,
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_${n.substring(2)}');
    }
  }
}

String _dts(HarborSpiFlashController f) => HarborDeviceTreeGenerator(
  model: 'test',
  compatible: 'test,soc',
  peripherals: [f],
).generate();

String _flashNodes(String dts) =>
    dts.substring(dts.indexOf('        spi-nor@'));

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: the port window is mapped by the SoC', () async {
      final soc = HarborSoC(
        name: 'flash_port_${kind.name}',
        compatible: 'test,flash-port',
        fabricKind: kind,
        target: const HarborSimTarget(frequency: 50000000),
      );
      final cpu = soc.addMaster(_Cpu(kind));
      final flash = soc.addPeripheral(_flash(kind));
      flash.input('spi_io_in').srcConnection! <= Const(0, width: 4);
      flash.input('wr_req').srcConnection! <= Const(0);
      flash.input('wr_op').srcConnection! <= Const(0);
      flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
      flash.input('wr_len').srcConnection! <= Const(0, width: 9);
      flash.input('wr_data').srcConnection! <= Const(0, width: 8);
      cpu.pullUp(soc);
      soc.buildFabric();
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      await soc.build();
      bus.idle();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      await bus.write(_port + 0x10, 0x6);
      await bus.write(_port + 0x10, 0x1);
      expect(await bus.read(_port + 0x10), 0x7);
      expect(await bus.read(_port + 0x1c), 1);
      expect(await bus.read(_port + 0x1c), 0);
      await bus.write(_port + 0x100, 0x04030201);
      expect(await bus.read(_port + 0x100), 0x04030201);
      expect(await bus.read(_port + 0x0c), 0);
      await Simulator.endSimulation();
    });
  }

  test('the device tree text of both nodes', () {
    expect(_flashNodes(_dts(_flash(HarborFabricKind.wishbone))), '''
        spi-nor@20000000 {
            compatible = "jedec,spi-nor";
            reg = <0x20000000 0x1000000 0x21000000 0x1000>;
            spi-max-frequency = <50000000>;
            spi-tx-bus-width = <4>;
            reg-names = "xip", "ctrl";
            partitions {
                compatible = "fixed-partitions";
                #address-cells = <1>;
                #size-cells = <1>;
                partition@0 {
                    reg = <0x0 0x400000>;
                    label = "fpga-bitstream";
                };
                partition@400000 {
                    reg = <0x400000 0x10000>;
                    label = "river-fsbl";
                };
                partition@410000 {
                    reg = <0x410000 0x300000>;
                    label = "river-firmware";
                };
            };
        };

        spi-flash-port@21000000 {
            compatible = "harbor,spi-flash-port";
            reg = <0x21000000 0x1000 0x20000000 0x1000000>;
            reg-names = "ctrl", "xip";
            harbor,flash-size = <16777216>;
            harbor,erase-size = <4096>;
            harbor,page-size = <256>;
            harbor,erase-timeout-ms = <3000>;
            harbor,program-timeout-ms = <50>;
            partitions {
                compatible = "fixed-partitions";
                #address-cells = <1>;
                #size-cells = <1>;
                partition@0 {
                    reg = <0x0 0x400000>;
                    label = "fpga-bitstream";
                };
                partition@400000 {
                    reg = <0x400000 0x10000>;
                    label = "river-fsbl";
                };
                partition@410000 {
                    reg = <0x410000 0x300000>;
                    label = "river-firmware";
                };
            };
        };
    };
};
''');
  });

  test('no Harbor default marks the bitstream partition read-only', () {
    final dts = _dts(_flash(HarborFabricKind.wishbone));
    expect(dts, isNot(contains('read-only')));
    const flagged = [
      HarborFlashPartition(label: 'fpga-bitstream', offset: 0, size: 0x400000),
      HarborFlashPartition(
        label: 'river-fsbl',
        offset: 0x400000,
        size: 0x10000,
        osReadOnly: true,
      ),
    ];
    final text = _dts(_flash(HarborFabricKind.wishbone, partitions: flagged));
    final linux = text.substring(text.indexOf('spi-flash-port@'));
    final jedec = text.substring(0, text.indexOf('spi-flash-port@'));
    expect(RegExp('read-only;').allMatches(linux), hasLength(1));
    expect(
      linux,
      contains('label = "river-fsbl";\n                    read-only;'),
    );
    expect(jedec, isNot(contains('read-only')));
    expect(
      const HarborFlashPartition(label: 'a', offset: 0, size: 1).osReadOnly,
      isFalse,
    );
  });

  test('a build without the port has the single original node', () {
    final dts = _dts(_flash(HarborFabricKind.wishbone, port: null));
    expect(dts, isNot(contains('spi-flash-port')));
    expect(dts, isNot(contains('reg-names')));
    expect(dts, contains('reg = <0x20000000 0x1000000>;'));
  });

  test('ACPI and SVD carry the port', () {
    final f = _flash(HarborFabricKind.wishbone);
    final asl = HarborAcpiGenerator(
      oemId: 'HARBOR',
      oemTableId: 'TEST',
      peripherals: [f],
    ).generate();
    expect(asl, contains('"jedec,spi-nor"'));
    expect(asl, contains('"harbor,spi-flash-port"'));
    expect(asl, contains('Memory32Fixed (ReadWrite, 0x21000000, 0x00001000)'));
    expect(RegExp('PRP0001').allMatches(asl), hasLength(2));
    final svd = HarborSvdGenerator(
      vendor: 'test',
      name: 'test',
      peripherals: [f],
    ).generate();
    expect(svd, contains('<name>SPIFLASH_PORT</name>'));
    expect(svd, contains('<baseAddress>0x21000000</baseAddress>'));
    for (final r in ['ctrl', 'addr', 'len', 'status', 'lock_mask', 'claim']) {
      expect(svd, contains('<name>$r</name>'));
    }
    expect(svd, isNot(contains('lock_base')));
    final off = HarborSvdGenerator(
      vendor: 'test',
      name: 'test',
      peripherals: [_flash(HarborFabricKind.wishbone, port: null)],
    ).generate();
    expect(off, isNot(contains('SPIFLASH_PORT')));
  });

  test('a port window that meets another peripheral fails validate', () {
    final soc = HarborSoC(name: 's', compatible: 't,s');
    soc.addPeripheral(_flash(HarborFabricKind.wishbone));
    soc.addPeripheral(HarborWatchdog(baseAddress: _port + 0x800));
    expect(soc.validate(), isNotEmpty);
  });

  test('validate checks every second window and the extra SVD block', () {
    final soc = HarborSoC(name: 's', compatible: 't,s');
    soc.addPeripheral(_flash(HarborFabricKind.wishbone));
    expect(soc.validate(), isEmpty);
    final a = soc.addPeripheral(HarborWatchdog(baseAddress: 0x40000000));
    final b = soc.addPeripheral(
      HarborWatchdog(baseAddress: 0x40001000, name: 'wdt2'),
    );
    soc.addPeripheralSlave(a, 'bus', const BusAddressRange(0x50000000, 0x1000));
    soc.addPeripheralSlave(b, 'bus', const BusAddressRange(0x50000800, 0x1000));
    expect(soc.validate().where((e) => e.contains('overlaps')), hasLength(1));
  });
}
