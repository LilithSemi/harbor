{
  lib,
  stdenv,
  flakever,
  kernel,
  kernelModuleMakeFlags,
}:
stdenv.mkDerivation {
  pname = "harbor-kmod";
  inherit (flakever) version;

  src = lib.fileset.toSource {
    root = ../../packages/harbor_kmod;
    fileset = lib.fileset.unions [
      ../../packages/harbor_kmod/Makefile
      ../../packages/harbor_kmod/gpio
      ../../packages/harbor_kmod/spi
      ../../packages/harbor_kmod/i2c
      ../../packages/harbor_kmod/sdio
      ../../packages/harbor_kmod/dma
      ../../packages/harbor_kmod/pwm
      ../../packages/harbor_kmod/watchdog
      ../../packages/harbor_kmod/ethernet
      ../../packages/harbor_kmod/usb
      ../../packages/harbor_kmod/display
      ../../packages/harbor_kmod/pmu
      ../../packages/harbor_kmod/pcie
      ../../packages/harbor_kmod/hwmon
      ../../packages/harbor_kmod/media
      ../../packages/harbor_kmod/audio
      ../../packages/harbor_kmod/efuse
    ];
  };

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = kernelModuleMakeFlags ++ [
    "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
  ];

  # Kbuild installs the selected modules and their signing certificates.
  # Copying only .ko files drops the .ko.cer files needed by NixOS's module tree.
  installFlags = [
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=extra/harbor"
  ];

  # Kbuild strips modules before signing them; do not modify them afterwards.
  dontStrip = true;

  # The enabled kernel subsystems determine which modules are built.
  preInstall = ''
    modules=$(find . -name '*.ko' -print)
    if [ -z "$modules" ]; then
      echo "harbor-kmod: the build made no modules" >&2
      exit 1
    fi

    echo "harbor-kmod: installing$(echo "$modules" | sed 's|^\./| |' | tr -d '\n')"
  '';

  meta = {
    description = "Linux kernel modules for Harbor SoC peripherals";
    homepage = "https://github.com/LilithSemi/harbor";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
}
