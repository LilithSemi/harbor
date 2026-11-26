import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _Top extends Module {
  _Top() : super(name: 'top') {
    addInput('clk', Logic());
    addInput('rst_n', Logic());
    addOutput('led', width: 3);
  }
}

final _gf180 = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD');

HarborPadPlan _plan() => HarborPadPlan.build(
  ports: HarborPadPort.fromModule(_Top(), clocks: {'clk'}),
  library: _gf180.padLibrary,
);

// Three SRAM instances of two masters, and a cell that is not an SRAM.
const _leaves = [
  'gf180mcu_fd_ip_sram__sram512x8m8wm1',
  'gf180mcu_fd_ip_sram__sram64x8m8wm1',
  'gf180mcu_fd_ip_sram__sram64x8m8wm1',
  'some_pll',
];

HarborAsicTarget _target({List<HarborMacroPin> pins = const []}) =>
    HarborAsicTarget(
      provider: _gf180,
      topCell: 'top',
      padPlan: _plan(),
      macroPins: pins,
    );

void main() {
  test('reads the lef and liberty of each sram master once', () {
    final tcl = _target().generateOpenroadTcl(leafCells: _leaves);
    for (final cell in ['sram512x8m8wm1', 'sram64x8m8wm1']) {
      final lef =
          'read_lef \$::env(SRAM_DIR)/lef/\$::env(SRAM_LIB_NAME)__$cell.lef';
      final lib =
          'read_liberty \$::env(SRAM_DIR)/lib/'
          '\$::env(SRAM_LIB_NAME)__${cell}__\$::env(LIB_CORNER).lib';
      expect(lef.allMatches(tcl).length, 1);
      expect(lib.allMatches(tcl).length, 1);
      expect(tcl.indexOf(lef), lessThan(tcl.indexOf('link_design')));
      expect(tcl.indexOf(lib), lessThan(tcl.indexOf('link_design')));
    }
    expect(tcl, isNot(contains('some_pll')));
    for (final env in ['SRAM_DIR', 'SRAM_LIB_NAME', 'TECH_LEF', 'LIB_CORNER']) {
      expect(
        tcl,
        contains('puts stderr "The pad ring needs the $env env var"'),
      );
    }
  });

  test('places every sram by rule inside the pad ring', () {
    final tcl = _target().generateOpenroadTcl(leafCells: _leaves);
    for (final line in [
      'set halo [expr {[info exists ::env(MACRO_HALO)] ? '
          r'$::env(MACRO_HALO) : 10}]',
      'set sram_lift 40',
      'set macro_channel 20',
      'set sram_pins {}',
      r'  if { [string match $::env(SRAM_LIB_NAME)__* '
          r'[[$inst getMaster] getName]] } {',
      // South macros are lifted. North macros are at halo from the edge
      // and keep the lift free below their pins.
      r'    set y [expr $cy0 + $halo + $sram_lift]',
      r'    set y [expr $cy1 - $halo - $h]',
      r'    set y0 [expr $y - $sram_lift]',
      r'  if { $x < $cx0 + $halo || $x + $w + $halo > $cx1 || '
          r'$y0 < $cy0 + $halo || $y + $h + $halo > $cy1 } {',
      r'    if { $x < $rx1 + $macro_channel && $x + $w + $macro_channel > '
          r'$rx0 && $y0 < $ry1 + $macro_channel && $y + $h + $macro_channel > '
          r'$ry0 } {',
      // Both edges use R0, so the bottom-edge signal pins face the core.
      r'  place_macro -macro_name $name -location [list $x $y] -orientation R0',
      r'  lappend sram_rects [list $x $y0 [expr $x + $w] [expr $y + $h]]',
      r'    set x [expr $result + $macro_channel]',
      // South first, then north, never automatic placement.
      r'  if { [sram_pack $name south] ne "placed" && '
          r'[sram_pack $name north] ne "placed" } {',
      r'cut_rows -halo_width_x $halo -halo_width_y $halo',
      r'define_pdn_grid -name sram -macro -instances $srams '
          '-voltage_domains CORE -grid_over_boundary',
      'add_pdn_connect -grid sram -layers {Metal3 Metal4}',
      '  foreach pin {VDD VSS} {',
      r'    if { $iterm eq "NULL" || [$iterm getNet] eq "NULL" } {',
      r'  if { [catch {check_power_grid -net $net -floorplanning '
          r'-dont_require_terminals -error_file $pg_report} err] } {',
      r'      set floating [regexp -all -inline {inst:\S+} [read $fh]]',
      r'      if { "inst:$name" in $floating } {',
    ]) {
      expect(tcl, contains(line));
    }
    for (final msg in [
      r'The netlist has no SRAM of $::env(SRAM_LIB_NAME)',
      r'The pinned SRAM $name is not in the netlist',
      r'The SRAM $name does not fit in the core',
      r'The SRAM pin $name/$pin has no net',
      r'The SRAM $name is not connected to the $net power grid',
      r'The $net power grid is not connected: $err',
    ]) {
      expect(tcl, contains('puts stderr "$msg"\n'));
    }
    expect(tcl, isNot(contains('MX')));
    expect(tcl, isNot(contains('macro_placement')));
    expect(tcl, isNot(contains('rtl_macro_placer')));
    expect(tcl, isNot(contains('MACRO_HALO) -halo_width_y')));

    final order = [
      'remove_io_rows',
      'proc sram_try',
      r'foreach name $srams {',
      'cut_rows',
      'tapcell',
      'define_pdn_grid -name stdcell',
      'define_pdn_grid -name sram',
      'pdngen',
      '  foreach pin {VDD VSS} {',
      'check_power_grid',
      'global_placement',
    ];
    final at = [for (final s in order) tcl.indexOf(s)];
    expect(at, isNot(contains(-1)));
    expect(at, orderedEquals([...at]..sort()));
  });

  test('three srams fill the south edge, then the north edge', () {
    const three = [
      'gf180mcu_fd_ip_sram__sram512x8m8wm1',
      'gf180mcu_fd_ip_sram__sram256x8m8wm1',
      'gf180mcu_fd_ip_sram__sram64x8m8wm1',
    ];
    final tcl = _target().generateOpenroadTcl(leafCells: three);
    for (final cell in ['sram512x8m8wm1', 'sram256x8m8wm1', 'sram64x8m8wm1']) {
      expect(
        tcl,
        contains(
          'read_lef \$::env(SRAM_DIR)/lef/\$::env(SRAM_LIB_NAME)__$cell.lef',
        ),
      );
    }
    // Each macro tries the south edge from west to east, past the macros in
    // the way, then the north edge. With no free location the flow stops.
    final pack = tcl.substring(tcl.indexOf('proc sram_pack'));
    expect(pack, contains(r'  set x [expr $cx0 + $halo]'));
    expect(
      pack,
      contains(
        r'    if { $result eq "placed" || $result eq "full" } '
        r'{ return $result }',
      ),
    );
    expect(pack, contains(r'    set x [expr $result + $macro_channel]'));
    final rule = tcl.substring(tcl.indexOf(r'foreach name $srams {'));
    expect(
      rule,
      startsWith(
        r'foreach name $srams {'
        '\n'
        r'  if { [lsearch -index 0 $sram_pins $name] >= 0 } { continue }'
        '\n'
        r'  if { [sram_pack $name south] ne "placed" && '
        r'[sram_pack $name north] ne "placed" } {'
        '\n'
        r'    puts stderr "The SRAM $name does not fit in the core"'
        '\n'
        '    exit 1\n',
      ),
    );
  });

  test('a macro out of the core or on another sram stops the flow', () {
    final tcl = _target(
      pins: const [
        HarborMacroPin(
          inst: 'ram',
          edge: HarborIoPadEdge.south,
          offsetUm: 5000,
        ),
      ],
    ).generateOpenroadTcl(leafCells: _leaves);
    expect(
      tcl,
      contains(
        r'  if { $result eq "full" } {'
        '\n'
        r'    puts stderr "The SRAM $name does not fit in the core"'
        '\n'
        '    exit 1\n'
        '  }\n'
        r'  if { $result ne "placed" } {'
        '\n'
        r'    puts stderr "The SRAM $name overlaps another SRAM"'
        '\n'
        '    exit 1\n',
      ),
    );
    expect(tcl, contains('    return full\n'));
    expect(tcl, contains(r'      return $rx1'));
  });

  test('pinned srams go first at their edge', () {
    final tcl = _target(
      pins: const [
        HarborMacroPin(inst: 'i_core.ram_a', edge: HarborIoPadEdge.north),
        HarborMacroPin(
          inst: 'i_core.ram_b',
          edge: HarborIoPadEdge.south,
          offsetUm: 120.5,
        ),
      ],
    ).generateOpenroadTcl(leafCells: _leaves);
    expect(
      tcl,
      contains(
        'set sram_pins {{i_core.ram_a north {}} {i_core.ram_b south {120.5}}}',
      ),
    );
    expect(tcl, contains(r'    set result [sram_pack $name $edge]'));
    expect(
      tcl,
      contains(r'    set result [sram_try $name $edge [expr $cx0 + $offset]]'),
    );
    expect(
      tcl,
      contains(
        r'  if { [lsearch -index 0 $sram_pins $name] >= 0 } { continue }',
      ),
    );
    expect(
      tcl.indexOf(r'foreach pin $sram_pins {'),
      lessThan(tcl.indexOf(r'foreach name $srams {')),
    );
  });

  test('macro pins refuse a flow they cannot be placed in', () {
    const north = HarborMacroPin(inst: 'ram', edge: HarborIoPadEdge.north);
    Matcher fails(String message) => throwsA(
      isA<ArgumentError>().having((e) => e.message, 'message', message),
    );
    expect(
      () => HarborAsicTarget(
        provider: _gf180,
        topCell: 'top',
        macroPins: const [north],
      ).generateOpenroadTcl(leafCells: _leaves),
      fails('Macro pins need a pad ring'),
    );
    expect(
      () => _target(pins: const [north]).generateOpenroadTcl(),
      fails('Macro pins need SRAM macros in the netlist'),
    );
    expect(
      () => _target(
        pins: const [HarborMacroPin(inst: 'ram', edge: HarborIoPadEdge.east)],
      ).generateOpenroadTcl(leafCells: _leaves),
      fails('The SRAM ram must be on the south or north core edge'),
    );
    expect(
      () => HarborAsicTarget(
        provider: _gf180,
        topCell: 'top',
        padPlan: _plan(),
        macros: const [HarborAsicMacro(moduleName: 'Tile')],
      ).generateOpenroadTcl(leafCells: _leaves),
      fails(
        'A pad ring cannot have hardened macros: macro_placement would '
        'move the SRAM macros',
      ),
    );
  });

  test('flows without an sram in the pad ring do not change', () {
    final core = HarborAsicTarget(provider: _gf180, topCell: 'top');
    expect(
      core.generateOpenroadTcl(leafCells: _leaves),
      core.generateOpenroadTcl(),
    );
    final pad = _target();
    final tcl = pad.generateOpenroadTcl(leafCells: const ['some_pll']);
    expect(tcl, pad.generateOpenroadTcl());
    expect(tcl, isNot(contains('sram')));
    expect(tcl, isNot(contains('SRAM')));
    expect(tcl, isNot(contains('halo')));
  });
}
