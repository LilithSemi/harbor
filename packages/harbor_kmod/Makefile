# Harbor Linux kernel modules
#
# Build out-of-tree:
#   make KDIR=/path/to/linux
#
# Build for installed kernel:
#   make
#
# Install:
#   make install

KDIR ?= /lib/modules/$(shell uname -r)/build

# Each module needs its subsystem in the kernel that it is built against. A
# board can remove a subsystem it has no hardware for. Build a module only when
# its subsystem is present, because a module that has no subsystem does not
# link and stops the build of all the other modules.
#
# Kbuild reads the configuration of the kernel before it reads this file, so
# these variables hold "y", "m" or nothing.
module-if = $(if $(filter y m,$(1)),$(2))

obj-m += $(call module-if,$(CONFIG_GPIOLIB),gpio/harbor_gpio.o)
obj-m += $(call module-if,$(CONFIG_SPI),spi/harbor_spi.o)
obj-m += $(call module-if,$(CONFIG_I2C),i2c/harbor_i2c.o)
obj-m += $(call module-if,$(CONFIG_MMC),sdio/harbor_sdio.o)
obj-m += $(call module-if,$(CONFIG_DMADEVICES),dma/harbor_dma.o)
obj-m += $(call module-if,$(CONFIG_PWM),pwm/harbor_pwm.o)
obj-m += $(call module-if,$(CONFIG_WATCHDOG),watchdog/harbor_wdt.o)
obj-m += $(call module-if,$(CONFIG_PHYLIB),ethernet/harbor_eth.o)
obj-m += $(call module-if,$(CONFIG_USB_GADGET),usb/harbor_usb.o)
obj-m += $(call module-if,$(CONFIG_DRM),display/harbor_display.o)
obj-m += $(call module-if,$(CONFIG_PM_GENERIC_DOMAINS),pmu/harbor_pmu.o)
obj-m += $(call module-if,$(CONFIG_PCI),pcie/harbor_pcie.o)
obj-m += $(call module-if,$(CONFIG_HWMON),hwmon/harbor_temp.o)
obj-m += $(call module-if,$(CONFIG_VIDEO_DEV),media/harbor_media.o)
obj-m += $(call module-if,$(CONFIG_SND_SOC),audio/harbor_audio.o)
obj-m += $(call module-if,$(CONFIG_NVMEM),efuse/harbor_efuse.o)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

.PHONY: all clean install
