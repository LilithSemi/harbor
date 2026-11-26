import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _Top extends Module {
  _Top() : super(name: 'top') {
    addInput('clk', Logic());
    addInput('rst_n', Logic());
    addInput('btn', Logic(width: 2), width: 2);
    addOutput('led', width: 3);
    addOutput('sd_out', width: 2);
    addOutput('sd_oe', width: 2);
    addInput('sd_in', Logic(width: 2), width: 2);
    addInput('vref', Logic());
  }
}

final _gf180 = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD');

HarborPadPlan _plan() => HarborPadPlan.build(
  ports: HarborPadPort.fromModule(_Top(), clocks: {'clk'}, analog: {'vref'}),
  library: _gf180.padLibrary,
);

HarborAsicTarget _padTarget() =>
    HarborAsicTarget(provider: _gf180, topCell: 'top', padPlan: _plan());

// Generator output before the pad ring existed.
const _coreSynth = r'''
yosys -import
# Auto-generated Yosys synthesis for top
# PDK: GlobalFoundries GF180MCU
# Run by asix.mkTapeout (yosys -c). The standard-cell liberty
# comes from $::env(LIB_FILE); RTL/stubs are read relative to
# this script via [info script] so the flow is location-agnostic.

set ipdir [file dirname [info script]]
read_verilog -sv $ipdir/rtl/*.sv
read_verilog -lib $ipdir/blackboxes.v
hierarchy -top top -keep_portwidths
synth -top top -flatten
dfflibmap -liberty $::env(LIB_FILE)
abc -liberty $::env(LIB_FILE)
hilomap -hicell gf180mcu_fd_sc_mcu7t5v0__tieh Z -locell gf180mcu_fd_sc_mcu7t5v0__tiel ZN
opt_clean -purge
write_verilog -noattr top_synth.v
stat -liberty $::env(LIB_FILE)
''';

const _corePnr = r'''
# Auto-generated OpenROAD P&R for top
# PDK: GlobalFoundries GF180MCU
# Run by asix.mkTapeout (openroad -exit). All PDK paths and
# floorplan knobs come from the env: LIB_FILE/TECH_LEF/
# CELL_LEF_DIR/SYNTH_V/SDC_FILE/SITE_NAME/UTILIZATION/
# MACRO_HALO/PLACEMENT_DENSITY/DROUTE_END_ITER (+optional DIE_AREA,
# CORE_MARGIN_UM, LAYER_ADJ_*).

read_liberty $::env(LIB_FILE)
if {[info exists ::env(TECH_LEF)] && $::env(TECH_LEF) ne ""} {
    read_lef $::env(TECH_LEF)
}
foreach _lef [lsort [glob -nocomplain $::env(CELL_LEF_DIR)/*.lef]] {
    if {[string match *tech* [file tail $_lef]]} { continue }
    read_lef $_lef
}

read_verilog $::env(SYNTH_V)
link_design top
read_sdc $::env(SDC_FILE)
if {[info exists ::env(RC_TCL)]} {
    source $::env(RC_TCL)
} else {
    set_wire_rc -layer Metal2
}

if {[info exists ::env(CORE_MARGIN_UM)]} {
    set _m $::env(CORE_MARGIN_UM)
}
if {[info exists ::env(DIE_AREA)]} {
    lassign $::env(DIE_AREA) _dx0 _dy0 _dx1 _dy1
    if {[info exists _m]} {
        set _cx0 [expr {$_dx0 + $_m}]
        set _cy0 [expr {$_dy0 + $_m}]
        set _cx1 [expr {$_dx1 - $_m}]
        set _cy1 [expr {$_dy1 - $_m}]
    } else {
        set _block [ord::get_db_block]
        set _dbu [$_block getDbUnitsPerMicron]
        set _halo [expr {[info exists ::env(MACRO_HALO)] ? $::env(MACRO_HALO) : 0}]
        set _cells 0.0
        set _macros 0.0
        foreach _inst [$_block getInsts] {
            set _master [$_inst getMaster]
            set _w [expr {double([$_master getWidth]) / $_dbu}]
            set _h [expr {double([$_master getHeight]) / $_dbu}]
            if {[$_master isBlock]} {
                set _macros [expr {$_macros + ($_w + 2 * $_halo) * ($_h + 2 * $_halo)}]
            } else {
                set _cells [expr {$_cells + $_w * $_h}]
            }
        }
        set _side [expr {max(80.0, sqrt($_cells / $::env(UTILIZATION) + $_macros))}]
        set _cx0 [expr {int(($_dx0 + $_dx1 - $_side) / 2)}]
        set _cy0 [expr {int(($_dy0 + $_dy1 - $_side) / 2)}]
        set _cx1 [expr {$_cx0 + ceil($_side)}]
        set _cy1 [expr {$_cy0 + ceil($_side)}]
    }
    initialize_floorplan \
        -die_area "$_dx0 $_dy0 $_dx1 $_dy1" \
        -core_area "$_cx0 $_cy0 $_cx1 $_cy1" \
        -site $::env(SITE_NAME)
} else {
    if {![info exists _m]} { set _m 10 }
    initialize_floorplan \
        -utilization $::env(UTILIZATION) \
        -core_space $_m \
        -site $::env(SITE_NAME)
}
make_tracks
foreach _name [array names ::env LAYER_ADJ_*] {
    set_global_routing_layer_adjustment [string range $_name 10 end] $::env($_name)
}

add_global_connection -net VDD -pin_pattern {^VDD$} -power
add_global_connection -net VDD -pin_pattern {^VNW$} -power
add_global_connection -net VSS -pin_pattern {^VSS$} -ground
add_global_connection -net VSS -pin_pattern {^VPW$} -ground
global_connect

tapcell -distance 20 \
    -tapcell_master gf180mcu_fd_sc_mcu7t5v0__filltie \
    -endcap_master gf180mcu_fd_sc_mcu7t5v0__endcap
global_connect

set_voltage_domain -name CORE -power VDD -ground VSS
define_pdn_grid -name stdcell -voltage_domains CORE -pins {Metal4 Metal5}
add_pdn_stripe -grid stdcell -layer Metal1 -width 0.6 -followpins
add_pdn_stripe -grid stdcell -layer Metal4 -width 1.6 -pitch 40 -offset 10 -spacing 1.7 -starts_with POWER
add_pdn_stripe -grid stdcell -layer Metal5 -width 1.6 -pitch 153.18 -offset 16.65 -spacing 1.7 -starts_with POWER
add_pdn_connect -grid stdcell -layers {Metal1 Metal4}
add_pdn_connect -grid stdcell -layers {Metal4 Metal5}
pdngen

global_placement -density $::env(PLACEMENT_DENSITY) -skip_io
place_pins -hor_layers Metal3 -ver_layers Metal2
global_placement -density $::env(PLACEMENT_DENSITY)
detailed_placement

estimate_parasitics -placement
clock_tree_synthesis -buf_list {gf180mcu_fd_sc_mcu7t5v0__clkbuf_2 gf180mcu_fd_sc_mcu7t5v0__clkbuf_4 gf180mcu_fd_sc_mcu7t5v0__clkbuf_8 gf180mcu_fd_sc_mcu7t5v0__clkbuf_16}
set_propagated_clock [all_clocks]
detailed_placement

estimate_parasitics -placement
repair_timing -hold
detailed_placement

global_route -allow_congestion
set _diode gf180mcu_fd_sc_mcu7t5v0__antenna
repair_antennas $_diode -iterations 3 -ratio_margin 10 -allow_congestion
if {[info exists ::env(DROUTE_END_ITER)]} {
    detailed_route -droute_end_iter $::env(DROUTE_END_ITER)
} else {
    detailed_route
}
for {set _i 0} {$_i < 3 && [check_antennas]} {incr _i} {
    if {![repair_antennas $_diode -ratio_margin 10 -allow_congestion]} { break }
if {[info exists ::env(DROUTE_END_ITER)]} {
    detailed_route -droute_end_iter $::env(DROUTE_END_ITER)
} else {
    detailed_route
}
}
check_antennas

filler_placement {gf180mcu_fd_sc_mcu7t5v0__fillcap_* gf180mcu_fd_sc_mcu7t5v0__fill_1 gf180mcu_fd_sc_mcu7t5v0__fill_2 gf180mcu_fd_sc_mcu7t5v0__fill_4}

global_connect
report_checks -path_delay min_max > timing.rpt
tee -file area.rpt {report_design_area}
report_power > power.rpt
write_def top_final.def
write_verilog top_final.v
write_verilog -include_pwr_gnd top_final_pwr.v
''';

const _hierPnr = r'''
# Auto-generated OpenROAD P&R for top
# PDK: GlobalFoundries GF180MCU
# Run by asix.mkTapeout (openroad -exit). All PDK paths and
# floorplan knobs come from the env: LIB_FILE/TECH_LEF/
# CELL_LEF_DIR/SYNTH_V/SDC_FILE/SITE_NAME/UTILIZATION/
# MACRO_HALO/PLACEMENT_DENSITY/DROUTE_END_ITER (+optional DIE_AREA,
# CORE_MARGIN_UM, LAYER_ADJ_*).
# Mode: hierarchical assembly (1 pre-hardened macros)

read_liberty $::env(LIB_FILE)
if {[info exists ::env(TECH_LEF)] && $::env(TECH_LEF) ne ""} {
    read_lef $::env(TECH_LEF)
}
foreach _lef [lsort [glob -nocomplain $::env(CELL_LEF_DIR)/*.lef]] {
    if {[string match *tech* [file tail $_lef]]} { continue }
    read_lef $_lef
}

# Read hardened macro abstracts
read_lef Tile.lef
read_liberty Tile.lib

read_verilog $::env(SYNTH_V)
link_design top
read_sdc $::env(SDC_FILE)
if {[info exists ::env(RC_TCL)]} {
    source $::env(RC_TCL)
} else {
    set_wire_rc -layer Metal2
}

if {[info exists ::env(CORE_MARGIN_UM)]} {
    set _m $::env(CORE_MARGIN_UM)
} else {
    set _m 40
}
if {[info exists ::env(DIE_AREA)]} {
    lassign $::env(DIE_AREA) _dx0 _dy0 _dx1 _dy1
    if {[info exists _m]} {
        set _cx0 [expr {$_dx0 + $_m}]
        set _cy0 [expr {$_dy0 + $_m}]
        set _cx1 [expr {$_dx1 - $_m}]
        set _cy1 [expr {$_dy1 - $_m}]
    } else {
        set _block [ord::get_db_block]
        set _dbu [$_block getDbUnitsPerMicron]
        set _halo [expr {[info exists ::env(MACRO_HALO)] ? $::env(MACRO_HALO) : 0}]
        set _cells 0.0
        set _macros 0.0
        foreach _inst [$_block getInsts] {
            set _master [$_inst getMaster]
            set _w [expr {double([$_master getWidth]) / $_dbu}]
            set _h [expr {double([$_master getHeight]) / $_dbu}]
            if {[$_master isBlock]} {
                set _macros [expr {$_macros + ($_w + 2 * $_halo) * ($_h + 2 * $_halo)}]
            } else {
                set _cells [expr {$_cells + $_w * $_h}]
            }
        }
        set _side [expr {max(80.0, sqrt($_cells / $::env(UTILIZATION) + $_macros))}]
        set _cx0 [expr {int(($_dx0 + $_dx1 - $_side) / 2)}]
        set _cy0 [expr {int(($_dy0 + $_dy1 - $_side) / 2)}]
        set _cx1 [expr {$_cx0 + ceil($_side)}]
        set _cy1 [expr {$_cy0 + ceil($_side)}]
    }
    initialize_floorplan \
        -die_area "$_dx0 $_dy0 $_dx1 $_dy1" \
        -core_area "$_cx0 $_cy0 $_cx1 $_cy1" \
        -site $::env(SITE_NAME)
} else {
    if {![info exists _m]} { set _m 10 }
    initialize_floorplan \
        -utilization $::env(UTILIZATION) \
        -core_space $_m \
        -site $::env(SITE_NAME)
}
make_tracks
foreach _name [array names ::env LAYER_ADJ_*] {
    set_global_routing_layer_adjustment [string range $_name 10 end] $::env($_name)
}

# Macro placement with halos
set_macro_halo -halo_x $::env(MACRO_HALO) -halo_y $::env(MACRO_HALO) [get_cells -hierarchical -filter "ref_name == Tile"]
macro_placement

add_global_connection -net VDD -pin_pattern {^VDD$} -power
add_global_connection -net VDD -pin_pattern {^VNW$} -power
add_global_connection -net VSS -pin_pattern {^VSS$} -ground
add_global_connection -net VSS -pin_pattern {^VPW$} -ground
global_connect

cut_rows -halo_width_x $::env(MACRO_HALO) -halo_width_y $::env(MACRO_HALO)
tapcell -distance 20 \
    -tapcell_master gf180mcu_fd_sc_mcu7t5v0__filltie \
    -endcap_master gf180mcu_fd_sc_mcu7t5v0__endcap
global_connect

set_voltage_domain -name CORE -power VDD -ground VSS
define_pdn_grid -name stdcell -voltage_domains CORE -pins {Metal4 Metal5}
add_pdn_stripe -grid stdcell -layer Metal1 -width 0.6 -followpins
add_pdn_stripe -grid stdcell -layer Metal4 -width 1.6 -pitch 40 -offset 10 -spacing 1.7 -starts_with POWER
add_pdn_stripe -grid stdcell -layer Metal5 -width 1.6 -pitch 153.18 -offset 16.65 -spacing 1.7 -starts_with POWER
add_pdn_connect -grid stdcell -layers {Metal1 Metal4}
add_pdn_connect -grid stdcell -layers {Metal4 Metal5}
define_pdn_grid -name macros -macro -cells {Tile} -voltage_domains CORE -grid_over_boundary
add_pdn_connect -grid macros -layers {Metal4 Metal5}
pdngen

global_placement -density $::env(PLACEMENT_DENSITY) -skip_io
place_pins -hor_layers Metal3 -ver_layers Metal2
global_placement -density $::env(PLACEMENT_DENSITY)
detailed_placement

estimate_parasitics -placement
clock_tree_synthesis -buf_list {gf180mcu_fd_sc_mcu7t5v0__clkbuf_2 gf180mcu_fd_sc_mcu7t5v0__clkbuf_4 gf180mcu_fd_sc_mcu7t5v0__clkbuf_8 gf180mcu_fd_sc_mcu7t5v0__clkbuf_16}
set_propagated_clock [all_clocks]
detailed_placement

estimate_parasitics -placement
repair_timing -hold
detailed_placement

# Skip Metal1-1 (used internally by macros)
set_global_routing_layer_adjustment Metal1-Metal1 1.0
global_route -allow_congestion
set _diode gf180mcu_fd_sc_mcu7t5v0__antenna
repair_antennas $_diode -iterations 3 -ratio_margin 10 -allow_congestion
if {[info exists ::env(DROUTE_END_ITER)]} {
    detailed_route -droute_end_iter $::env(DROUTE_END_ITER)
} else {
    detailed_route
}
for {set _i 0} {$_i < 3 && [check_antennas]} {incr _i} {
    if {![repair_antennas $_diode -ratio_margin 10 -allow_congestion]} { break }
if {[info exists ::env(DROUTE_END_ITER)]} {
    detailed_route -droute_end_iter $::env(DROUTE_END_ITER)
} else {
    detailed_route
}
}
check_antennas

filler_placement {gf180mcu_fd_sc_mcu7t5v0__fillcap_* gf180mcu_fd_sc_mcu7t5v0__fill_1 gf180mcu_fd_sc_mcu7t5v0__fill_2 gf180mcu_fd_sc_mcu7t5v0__fill_4}

global_connect
report_checks -path_delay min_max > timing.rpt
tee -file area.rpt {report_design_area}
report_power > power.rpt
write_def top_final.def
write_verilog top_final.v
write_verilog -include_pwr_gnd top_final_pwr.v
''';

void main() {
  test('core-only scripts do not change', () {
    final flat = HarborAsicTarget(provider: _gf180, topCell: 'top');
    expect(flat.generateYosysTcl(hasBlackboxes: true), _coreSynth);
    expect(flat.generateOpenroadTcl(), _corePnr);
    final hier = HarborAsicTarget(
      provider: _gf180,
      topCell: 'top',
      dieMarginUm: 40,
      macros: const [HarborAsicMacro(moduleName: 'Tile')],
    );
    expect(hier.generateOpenroadTcl(), _hierPnr);
  });

  test('synth reads the pad blackboxes and flattens chip_top', () {
    final tcl = _padTarget().generateYosysTcl();
    expect(
      tcl,
      contains(
        r'read_verilog -lib $::env(IO_DIR)/verilog/'
        r'$::env(IO_LIB_NAME)__blackbox.v',
      ),
    );
    expect(tcl, contains(r'read_verilog -sv $ipdir/rtl/*.sv'));
    expect(tcl, contains(r'read_verilog $ipdir/chip_top.v'));
    expect(tcl, contains('synth -top chip_top -flatten'));
    expect(tcl, contains('write_verilog -noattr chip_top_synth.v'));
    expect(tcl, isNot(contains('synth -top top ')));
  });

  test('pnr places the pad ring and the core power ring', () {
    final plan = _plan();
    final tcl = _padTarget().generateOpenroadTcl();

    for (final env in [
      'DIE_AREA',
      'IO_DIR',
      'IO_LIB_NAME',
      'TECH_LEF',
      'LIB_CORNER',
    ]) {
      expect(tcl, contains('if {![info exists ::env($env)]} {'));
      expect(tcl, contains('puts stderr "The pad ring needs the $env'));
    }
    expect(
      tcl,
      contains(
        r'source $io_pdk_dir/libs.tech/librelane/$::env(IO_LIB_NAME)/config.tcl',
      ),
    );
    expect(tcl, contains(r'dict for {site size} $::env(PAD_FAKE_SITES) {'));
    expect(
      tcl,
      contains(
        r'read_liberty $::env(IO_DIR)/lib/'
        r'$::env(IO_LIB_NAME)__$::env(LIB_CORNER).lib',
      ),
    );
    expect(tcl, contains('link_design chip_top'));

    for (final edge in HarborPadPlan.sideOrder) {
      final insts = [for (final p in plan.side(edge)) p.inst].join(' ');
      expect(tcl, contains('set pads(${edge.name}) {$insts}'));
    }
    for (final line in [
      'set ring_offset 6',
      'set ring_width 25',
      'set ring_space 1.7',
      'set pad_clearance 30',
      'set power_masters {gf180mcu_fd_io__dvdd gf180mcu_fd_io__dvss}',
      r'set ring_extent [expr $ring_offset + 2 * $ring_width + $ring_space]',
      r'set cx0 [expr int(ceil($dx0 + $corner_w + $ring_extent + $pad_clearance))]',
      r'set cy1 [expr int(floor($dy1 - $corner_h - $ring_extent - $pad_clearance))]',
      r'  -core_area [list $cx0 $cy0 $cx1 $cy1] \',
      r'  -die_area $::env(DIE_AREA) \',
      'proc pad_slots { side } {',
      r'set gap [expr floor($free / ([llength $pads($side)] + 1))]',
      r'place_pad -row IO_[string toupper $side] -location $pos $name -master $master',
      r'place_corners $::env(PAD_CORNER)',
      r'place_io_fill -row IO_[string toupper $side] {*}$::env(PAD_FILLERS)',
      'connect_by_abutment',
      r'place_io_terminals $name/$terminal_pin',
      'remove_io_rows',
      'add_global_connection -net VDD -pin_pattern {^DVDD\$} -power',
      'add_global_connection -net VSS -pin_pattern {^DVSS\$} -ground',
      'add_pdn_stripe -grid stdcell -layer Metal4 -width 1.6 -pitch 40 '
          '-offset 10 -spacing 1.7 -starts_with POWER -extend_to_core_ring',
      'add_pdn_stripe -grid stdcell -layer Metal5 -width 1.6 -pitch 153.18 '
          '-offset 16.65 -spacing 1.7 -starts_with POWER -extend_to_core_ring',
      r'add_pdn_ring -grid stdcell -layers {Metal4 Metal3} '
          r'-widths [list $ring_width $ring_width] \',
      '  -connect_to_pads -connect_to_pad_layers Metal2',
      'add_pdn_connect -grid stdcell -layers {Metal1 Metal4}',
      'add_pdn_connect -grid stdcell -layers {Metal4 Metal5}',
      'add_pdn_connect -grid stdcell -layers {Metal4 Metal3}',
      'add_pdn_connect -grid stdcell -layers {Metal4 Metal2}',
      'add_pdn_connect -grid stdcell -layers {Metal3 Metal2}',
      'write_def chip_top_final.def',
    ]) {
      expect(tcl, contains(line));
    }

    for (final msg in [
      r'The pads of the $side side are wider than the side',
      r'The power ring does not span the pad $name',
      'The core does not fit inside the pad ring',
    ]) {
      expect(tcl, contains('puts stderr "$msg"'));
    }
    expect(RegExp(r'exit 1').allMatches(tcl).length, 8);
    expect(tcl, isNot(contains('place_pins')));

    final order = [
      'initialize_floorplan',
      'make_io_sites',
      'place_pad ',
      'place_corners',
      'remove_io_rows',
      'tapcell',
      'pdngen',
      'global_placement',
      'clock_tree_synthesis',
      'detailed_route',
      'write_def',
    ];
    final at = [for (final s in order) tcl.indexOf(s)];
    expect(at, isNot(contains(-1)));
    expect(at, orderedEquals([...at]..sort()));
  });

  test('a sky130 pad ring throws', () {
    final target = HarborAsicTarget(
      provider: Sky130Provider(pdkRoot: '/pdk/sky130A'),
      topCell: 'top',
      padPlan: _plan(),
    );
    expect(
      () => target.generateOpenroadTcl(),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'sky130 pad cells are not verified',
        ),
      ),
    );
    expect(() => target.generateYosysTcl(), throwsArgumentError);
  });

  test('generateAll writes chip_top.v for a pad ring', () async {
    HarborSoC soc(HarborPadPlan? plan) => HarborSoC(
      name: 'PadSoc',
      compatible: 'test,pad-soc',
      target: HarborAsicTarget(
        provider: _gf180,
        topCell: 'PadSoc',
        padPlan: plan,
      ),
    )..addPeripheral(HarborUart(baseAddress: 0x10000000));

    final probe = soc(null);
    await probe.build();
    final plan = HarborPadPlan.build(
      ports: HarborPadPort.fromModule(probe, clocks: {'clk'}),
      library: _gf180.padLibrary,
    );
    final padSoc = soc(plan);
    final dir = await Directory.systemTemp.createTemp('harbor_pad_ring');
    addTearDown(() => dir.delete(recursive: true));
    await padSoc.generateAll(dir);

    final top = File('${dir.path}/chip_top.v').readAsStringSync();
    expect(top, contains('module chip_top ('));
    expect(top, contains('PadSoc i_core ('));
    expect(
      File('${dir.path}/synth.tcl').readAsStringSync(),
      contains('synth -top chip_top -flatten'),
    );
    expect(
      File('${dir.path}/klayout/def2gds.py').readAsStringSync(),
      contains('chip_top_final.def'),
    );
  });
}
