# Harbor

A composable, declarative framework for building RISC-V SoCs using [ROHD](https://github.com/intel/rohd) and [rohd_bridge](https://github.com/intel/rohd_bridge). Harbor provides everything needed to go from SoC definition to silicon - FPGA synthesis, ASIC tapeout flows, Linux kernel drivers, and device tree generation.

## Features

### ISA Model

- Full RVA23 RISC-V profile (RV64IMAFDHCVB + Zicsr, Zifencei, scalar crypto)
- Declarative instruction definitions with resource modeling and micro-op sequences
- Hardware instruction decoder generation from ISA config
- Sv39/Sv48/Sv57 paging with two-stage translation for the H extension

### SoC Infrastructure

- **Bus fabric**: Wishbone, TileLink, AXI4 with arbiters, decoders, bridges, and crossbar generator
- **Cache hierarchy**: Synthesizable L1I, L1D, L2 with MSI/MESI/MOESI coherency
- **MMU**: TLB, hardware page table walker, PMP, PMA checker
- **Clock management**: Clock domains, CDC primitives (sync, handshake, async FIFO), clock gating cells
- **Interrupt routing**: Automatic wiring through PLIC, APLIC, or APLIC+IMSIC (AIA)
- **Power domains**: PMU integration with automatic clock gate insertion per domain
- **Boot sequencer**: Power-on reset through PLL lock, mask ROM, SPI flash load, DDR init, OpenSBI
- **Debug**: JTAG TAP, DTM, RISC-V Debug Module (halt/resume, program buffer), E-Trace encoder

### Peripherals

| Category        | Peripherals                                                                                       |
|-----------------|---------------------------------------------------------------------------------------------------|
| Communication   | UART, SPI, I2C, Ethernet MAC, USB (host/device/OTG)                                               |
| Storage         | Flash, SPI Flash (QSPI), SDIO, DDR3 controller (Xilinx 7-series and ECP5 PHYs), SRAM, MaskROM, eFuse (OTP) |
| Display & Media | Display controller (DRM/KMS), media engine (H.264/H.265/VP9/AV1/JPEG), audio (I2S/TDM/S/PDIF/PDM) |
| System          | GPIO, PWM/Timer, Watchdog, DMA, PCIe (host + endpoint), temperature sensor                        |
| Interrupts      | PLIC, APLIC, CLINT, IMSIC                                                                         |
| Security        | IOMMU, crypto accelerator (AES/SHA/CLMUL), HPM counters, eFuse with configurable unlock key       |
| Power           | PMU with per-domain power gating, reset controller                                                |

### Physical Implementation

- **FPGA**: iCE40, ECP5, Xilinx 7-series with Yosys synthesis scripts, nextpnr commands, constraint files (PCF/LPF/XDC), Makefiles, and vendor primitive blackboxes (PLL, BRAM, DSP, XADC, DTR)
- **ASIC**: Sky130 and GF180MCU PDKs with Yosys synthesis, OpenROAD place-and-route, hierarchical macro hardening (per-tile synthesis/PnR with LEF/LIB generation), metal layer-aware top-level assembly, IO ring/pad frame generation, and KLayout GDS merge/DRC/LVS scripts
- Device tree source (.dts) generation
- SoC topology graphs (Mermaid and Graphviz DOT)

### Linux Support

16 kernel modules for Linux 7.0:

```
harbor_gpio    harbor_spi      harbor_i2c     harbor_sdio
harbor_dma     harbor_pwm      harbor_wdt     harbor_eth
harbor_usb     harbor_display  harbor_pmu     harbor_pcie
harbor_temp    harbor_media    harbor_audio   harbor_efuse
```

OpenSBI platform definition for firmware integration.

### Nix Build Infrastructure

Composable builder functions for hardware projects:

- `harbor.mkIp` - generate RTL and build scripts from a Dart/Harbor SoC definition
- `harbor.mkSynth` - FPGA synthesis + PnR + bitstream (Yosys + nextpnr)
- `harbor.mkTapeout` - ASIC tapeout flow with hierarchical macro hardening (Yosys + OpenROAD + KLayout)

## Quick Start

```dart
import 'dart:io';
import 'package:harbor/harbor.dart';
import 'package:river/river.dart'; // your CPU core

Future<void> main() async {
  final target = HarborFpgaTarget.ecp5(
    device: 'lfe5u-45f', package: 'CABGA381', frequency: 50000000,
    pinMap: {'uart_tx': 'A2', 'uart_rx': 'B1'},
  );

  final soc = HarborSoC(
    name: 'MySoC',
    compatible: 'myproject,mysoc-v1',
    busConfig: WishboneConfig(addressWidth: 32, dataWidth: 32),
    cpus: [HarborDeviceTreeCpu(name: 'rv64', isa: 'rv64imafdc_zicsr_zifencei')],
    target: target,
  );

  // CPU core (River or any BridgeModule with a Wishbone master interface)
  final core = RiverCore(isa: RiscVIsaConfig(
    mxlen: RiscVMxlen.rv64,
    extensions: rva23Extensions,
  ));
  soc.addMaster(core);

  // Peripherals
  soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
  soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000, sources: 32, contexts: 1));
  soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
  soc.addPeripheral(HarborGpio(baseAddress: 0x10001000, pinCount: 16));
  soc.addPeripheral(HarborSpiController(baseAddress: 0x10002000));
  soc.addPeripheral(HarborSram(baseAddress: 0x00000000, size: 64 * 1024));
  soc.addPeripheral(HarborTemperatureSensor.fromTarget(
    baseAddress: 0x10009000, target: target,
  ));

  // Wire interrupts
  final routing = HarborInterruptRouting.plic(
    plic: soc.peripherals.whereType<HarborPlic>().first,
  );
  routing.connectSources(soc.peripherals);

  soc.buildFabric();
  await soc.generateAll(Directory('build/'));
}
```

This generates:
- `rtl/` - SystemVerilog RTL
- `MySoC.dts` - device tree source
- `MySoC.lpf` - ECP5 pin constraints
- `synth.tcl` - Yosys synthesis script (`synth_ecp5`)
- `Makefile` - complete build flow (synth -> nextpnr -> ecppack)
- `MySoC.dot` / `MySoC.mermaid.md` - topology graphs

## Building

### Dart

```sh
dart pub get
dart analyze
dart test
```

### Kernel Modules (Nix)

```sh
nix build .#harbor-kmod
```

### FPGA Synthesis (Nix)

```nix
my-soc-synth = pkgs.harbor.mkSynth {
  ip = my-soc-ip;
  topCell = "MySoC";
  vendor = "ecp5";
  device = "lfe5u-45f";
  package_ = "CABGA381";
  frequency = 50000000;
};
```

### ASIC Tapeout (Nix)

```nix
my-soc-tapeout = pkgs.harbor.mkTapeout {
  ip = my-soc-ip;
  topCell = "MySoC";
  pdk = pkgs.sky130-pdk;
  cellLib = "sky130_fd_sc_hd";
  clockPeriodNs = 20;
  macros = [ "RiverCore" "L2Cache" ];
};
```

## License

Dart library: Apache-2.0

Kernel modules: GPL-2.0-or-later

## Community

- **Contact**: [hello@lilithsemi.com](mailto:hello@lilithsemi.com)
