# Harbor Linux Kernel Modules

Out-of-tree Linux kernel drivers for Harbor SoC peripherals.

## Drivers

| Module | Compatible | Description |
|--------|-----------|-------------|
| `harbor_gpio` | `harbor,gpio` | GPIO controller with IRQ support |
| `harbor_spi` | `harbor,spi` | SPI master controller |
| `harbor_i2c` | `harbor,i2c` | I2C master controller |
| `harbor_sdio` | `harbor,sdio`, `harbor,sdhci` | SD/SDIO/eMMC host controller (ADMA) |
| `harbor_spi_flash` | `harbor,spi-flash-port` | MTD driver for the SPI flash write port |
| `harbor_display` | `harbor,display` | DRM driver for the sdram scanout display, one fixed mode, vblank interrupt. It takes buffers of the full screen size only: a dumb buffer of another size is refused. It needs a device tree `memory-region`. |

## Peripherals with upstream Linux support

These Harbor peripherals use standard compatible strings and work with
existing Linux drivers - no additional modules needed:

| Peripheral | Compatible | Linux Driver |
|-----------|-----------|-------------|
| CLINT | `riscv,clint0` | `timer-clint` |
| PLIC | `sifive,plic-1.0.0` | `irq-sifive-plic` |
| APLIC | `riscv,aplic` | `irq-riscv-aplic` |
| UART | `ns16550a` | `8250/serial` |
| SPI Flash | `jedec,spi-nor` | `spi-nor` |

## Building

```bash
# Against installed kernel headers
make

# Against a specific kernel source tree
make KDIR=/path/to/linux

# Cross-compile for RISC-V
make KDIR=/path/to/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu-

# Install
sudo make install
sudo depmod -a
```

## Device Tree

These drivers are matched via device tree. Harbor's `HarborSoC.generateDts()`
automatically produces the correct device tree nodes. Example:

```dts
gpio@10001000 {
    compatible = "harbor,gpio";
    reg = <0x10001000 0x1000>;
    ngpios = <32>;
    #gpio-cells = <2>;
    gpio-controller;
    interrupt-parent = <&plic>;
    interrupts = <3>;
};
```

## License

GPL-2.0-or-later
