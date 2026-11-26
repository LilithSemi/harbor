# mkSynth - FPGA synthesis, place-and-route, and bitstream generation.
#
# Takes an IP package (from mkIp) and runs the FPGA toolchain:
#   Yosys synthesis -> nextpnr PnR -> bitstream packing
#
# Usage:
#   harbor.mkSynth {
#     name = "my-soc-synth";
#     ip = myIp;                  # Output of mkIp
#     topCell = "MySoC";
#     # Target-specific (detected from ip if synth.tcl exists)
#     vendor = "ecp5";            # "ice40", "ecp5", "xilinx"
#     device = "lfe5u-45f";
#     package = "CABGA381";
#     frequency = 50000000;
#     speedGrade = "6";           # ECP5 only: "6", "7" or "8"
#   }
#
# Outputs:
#   $out/<top>.json     - Synthesized netlist
#   $out/<top>.config   - PnR output (ECP5) or <top>.asc (iCE40)
#   $out/<top>.bit      - Bitstream
#   $out/synth.log      - Yosys log
#   $out/pnr.log        - nextpnr log
{
  lib,
  stdenv,
  yosys,
  nextpnr,
  icestorm,
  trellis,
}:

lib.extendMkDerivation {
  constructDrv = stdenv.mkDerivation;

  excludeDrvArgNames = [
    "ip"
    "topCell"
    "vendor"
    "device"
    "package_"
    "frequency"
    "speedGrade"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      name ? "harbor-synth",
      ip,
      topCell ? "top",
      vendor ? "ecp5",
      device ? "",
      package_ ? "",
      frequency ? 0,
      speedGrade ? "6",
      ...
    }@args:

    let
      isIce40 = vendor == "ice40";
      isEcp5 = vendor == "ecp5";

      nextpnrBin =
        if isIce40 then
          "${nextpnr}/bin/nextpnr-ice40"
        else if isEcp5 then
          "${nextpnr}/bin/nextpnr-ecp5"
        else
          "${nextpnr}/bin/nextpnr-generic";

      packCmd =
        if isIce40 then
          "${icestorm}/bin/icepack"
        else if isEcp5 then
          "${trellis}/bin/ecppack"
        else
          null;

      constraintExt =
        if isIce40 then
          "pcf"
        else if isEcp5 then
          "lpf"
        else
          "xdc";

      bitstreamExt = if isIce40 then "bin" else "bit";

      intermediateExt = if isIce40 then "asc" else "config";

      freqFlag = lib.optionalString (frequency > 0) "--freq ${toString (frequency / 1000000)}";

      speedFlag = lib.optionalString isEcp5 "--speed ${speedGrade}";
    in
    builtins.removeAttrs args [
      "ip"
      "topCell"
      "vendor"
      "device"
      "package_"
      "frequency"
      "speedGrade"
    ]
    // {
      dontUnpack = true;
      dontConfigure = true;

      nativeBuildInputs =
        (args.nativeBuildInputs or [ ])
        ++ [ yosys ]
        ++ lib.optional (isIce40 || isEcp5) nextpnr
        ++ lib.optional isIce40 icestorm
        ++ lib.optional isEcp5 trellis;

      buildPhase = ''
        runHook preBuild

        # Find the SV file
        SV_FILE=$(find ${ip}/rtl -name '*.sv' -print -quit 2>/dev/null || echo "")
        if [ -z "$SV_FILE" ]; then
          SV_FILE=$(find ${ip} -name '*.sv' -print -quit)
        fi

        echo "=== Synthesis ==="
        if [ -f "${ip}/synth.tcl" ]; then
          export SV_FILE
          yosys -c ${ip}/synth.tcl 2>&1 | tee synth.log
        else
          yosys -p "read_verilog -sv $SV_FILE; synth_${vendor} -top ${topCell} -json ${topCell}.json" \
            2>&1 | tee synth.log
        fi

        echo "=== Place and Route ==="
        if [ -f "${topCell}.json" ]; then
          CONSTRAINT=""
          if [ -f "${ip}/${topCell}.${constraintExt}" ]; then
            CONSTRAINT="--${constraintExt} ${ip}/${topCell}.${constraintExt}"
          fi

          ${nextpnrBin} \
            --${device} \
            --package ${package_} \
            --json ${topCell}.json \
            $CONSTRAINT \
            ${if isIce40 then "--asc ${topCell}.asc" else "--textcfg ${topCell}.config"} \
            ${freqFlag} \
            ${speedFlag} \
            2>&1 | tee pnr.log

          ${lib.optionalString (packCmd != null) ''
            echo "=== Bitstream ==="
            ${packCmd} ${
              if isIce40 then
                "${topCell}.asc ${topCell}.${bitstreamExt}"
              else
                "--input ${topCell}.config --bit ${topCell}.${bitstreamExt}"
            }
          ''}
        fi

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp ${topCell}.json $out/ 2>/dev/null || true
        cp ${topCell}.${intermediateExt} $out/ 2>/dev/null || true
        cp ${topCell}.${bitstreamExt} $out/ 2>/dev/null || true
        cp synth.log $out/ 2>/dev/null || true
        cp pnr.log $out/ 2>/dev/null || true
        runHook postInstall
      '';

      passthru = {
        inherit
          ip
          topCell
          vendor
          device
          ;
      }
      // (args.passthru or { });
    };
}
