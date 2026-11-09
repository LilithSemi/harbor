# mkIp - Generate RTL and build scripts from a Harbor SoC definition.
#
# Takes a Dart package that uses Harbor's `generateAll` to produce
# SystemVerilog RTL, device tree, constraint files, synthesis scripts,
# and topology graphs.
#
# Usage:
#   harbor.mkIp {
#     name = "my-soc";
#     src = ./my-soc;           # Dart package with bin/generate.dart
#     dartEntryPoint = "bin/generate.dart";
#     # Optional: extra Dart args passed to the generator
#     generateArgs = [ "--target" "ecp5" ];
#   }
#
# Outputs:
#   $out/             - RTL, DTS, scripts, graphs
#   $out/rtl/         - SystemVerilog files
#   $out/*.dts        - Device tree source
#   $out/synth.tcl    - Yosys synthesis script
#   $out/Makefile     - Build flow (FPGA targets)
#   $out/pnr.tcl      - OpenROAD PnR script (ASIC targets)
#   $out/klayout/     - KLayout scripts (ASIC targets)
#   $out/macros/      - Per-macro scripts (hierarchical ASIC)
{
  lib,
  stdenvNoCC,
  buildDartApplication,
}:

lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "dartSrc"
    "dartEntryPoint"
    "generateArgs"
    "gitHashes"
    "pubspecLock"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      name ? "harbor-ip",
      dartSrc,
      dartEntryPoint ? "bin/generate.dart",
      generateArgs ? [ ],
      gitHashes ? {
        # rohd_hcl is fetched from git because the published 0.3.0 archive
        # omits the workspace member declared in its pubspec.
        rohd_hcl = "sha256-scU9PpBkBrc8qJ/SZpvWCzrp3iDpcChXlS4GcGm7Q0k=";
      },
      pubspecLock,
      ...
    }@args:

    let
      generator = buildDartApplication {
        pname = "${finalAttrs.name}-generator";
        version = "0.0.0";
        src = dartSrc;
        inherit gitHashes pubspecLock;
        dartEntryPoints."bin/generate" = dartEntryPoint;
      };
    in
    builtins.removeAttrs args [
      "dartSrc"
      "dartEntryPoint"
      "generateArgs"
      "gitHashes"
      "pubspecLock"
    ]
    // {
      dontUnpack = true;
      dontConfigure = true;

      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
        generator
      ];

      buildPhase = ''
        runHook preBuild
        generate ${lib.escapeShellArgs generateArgs} --output "$out"
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        # Output is already in $out from the generator
        runHook postInstall
      '';

      passthru = {
        inherit generator;
      }
      // (args.passthru or { });
    };
}
