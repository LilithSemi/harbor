import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _artix = HarborFpgaTarget.artix7(
  device: 'xc7a200t',
  package: 'fbg484',
  speedGrade: '2',
  frequency: 100000000,
);

/// Registers of a generated design as Vivado names them: the instance path
/// below the top, then the register name with `_reg`.
List<String> _vivadoRegs(String sv, String top, String topInstance) {
  final bodies = <String, String>{};
  for (final m in RegExp(
    r'^module\s+(\w+)\s*(.*?)^endmodule',
    multiLine: true,
    dotAll: true,
  ).allMatches(sv)) {
    bodies[m.group(1)!] = m.group(2)!;
  }
  final regs = <String>[];
  void walk(String def, String path) {
    final body = bodies[def];
    if (body == null) return;
    for (final line in body.split('\n')) {
      final a = RegExp(r'^\s*(\w+)\s*(\[[^\]]*\])?\s*<=').firstMatch(line);
      if (a != null && !line.trimLeft().startsWith('assign')) {
        regs.add('$path/${a.group(1)}_reg');
      }
    }
    for (final i in RegExp(
      r'^\s*(\w+)\s+(?:#\(.*?\)\s*)?(\w+)\s*\(',
      multiLine: true,
    ).allMatches(body)) {
      final d = i.group(1)!;
      if (bodies.containsKey(d)) walk(d, '$path/${i.group(2)}');
    }
  }

  walk(top, topInstance);
  return regs.toSet().toList();
}

/// Vivado `=~` match: `*` is any run of characters, `?` is one.
bool _glob(String pattern, String name) {
  final re = RegExp(
    '^${pattern.split('').map((c) => switch (c) {
      '*' => '.*',
      '?' => '.',
      _ => RegExp.escape(c),
    }).join()}\$',
  );
  return re.hasMatch(name);
}

/// Vivado instance path of [m] below [top], with [top] as `eth0`.
String _modPath(Module top, Module m) {
  final parts = <String>[];
  for (Module? p = m; p != null && p != top; p = p.parent) {
    parts.insert(0, p.uniqueInstanceName);
  }
  return ['eth0', ...parts].join('/');
}

/// Vivado name of the register [l].
String _regName(Module top, Logic l) =>
    '${_modPath(top, l.parentModule!)}/${l.name}_reg';

/// The registers that feed [start] through combinational logic.
Set<String> _sourceRegs(Module top, Logic start) {
  final out = <String>{};
  final seen = <Logic>{};
  void go(Logic l, Logic? prev) {
    if (!seen.add(l)) return;
    final src = l.srcConnection;
    if (src != null) {
      go(src, l);
      return;
    }
    final mod = l.parentModule;
    if (mod == null || !l.isOutput) return;
    if (mod is Sequential || mod is FlipFlop) {
      out.add(_regName(top, prev ?? l));
      return;
    }
    for (final i in mod.inputs.values) {
      go(i, null);
    }
  }

  go(start, null);
  return out;
}

Iterable<Module> _all(Module m) sync* {
  for (final s in m.subModules) {
    yield s;
    yield* _all(s);
  }
}

/// Checks the cell patterns of [m] against its generated registers.
Future<void> _check(HarborEthernetMac m) async {
  await m.build();
  final regs = _vivadoRegs(m.generateSynth(), m.definitionName, 'eth0');
  final list = [
    ...m.constraints(topPort: (p) => 'eth0_$p', instance: 'eth0'),
    ...m.cdcConstraints(sysPeriodNs: 8, instance: 'eth0'),
  ];
  final maxDelays = list.where(
    (c) => c.kind == HarborEthClockConstraintKind.maxDelay,
  );
  final toCells = <String>[];
  final prePins = <String>[];
  for (final c in list) {
    final local = c.kind == HarborEthClockConstraintKind.multicyclePath;
    for (final p in [...c.fromCells, ...c.toCells]) {
      final hit = regs.any(
        (r) => local ? _glob(p, r.split('/').last) : _glob(p, r),
      );
      expect(hit, isTrue, reason: 'cell pattern $p matches no register');
    }
    if (c.kind == HarborEthClockConstraintKind.maxDelay) {
      toCells.addAll(c.toCells);
    }
    for (final p in c.toPins) {
      expect(p.endsWith('/PRE'), isTrue, reason: 'pin pattern $p');
      final cell = p.substring(0, p.length - 4);
      expect(
        regs.any((r) => _glob(cell, r)),
        isTrue,
        reason: 'pin pattern $p matches no register',
      );
      prePins.add(cell);
    }
  }

  // Synchronizer first stages. The MDIO input comes from a pin, not from a
  // clock of the MAC, so it has no crossing constraint.
  final firstStages = regs.where(
    (r) =>
        !r.contains('/mdio_in_sync/') &&
        (r.endsWith('/sync_stage_0_reg') ||
            RegExp(r'_frame_fifo/\w+_s0_reg$').hasMatch(r)),
  );
  expect(firstStages, isNotEmpty);
  for (final r in firstStages) {
    expect(
      toCells.any((p) => _glob(p, r)),
      isTrue,
      reason: 'synchronizer first stage $r has no max delay',
    );
  }
  // Each register that feeds a synchronizer is in the max delay of that
  // synchronizer.
  final syncs = _all(
    m,
  ).whereType<HarborCdcSync>().where((x) => x.name != 'mdio_in_sync');
  expect(syncs, isNotEmpty);
  for (final x in syncs) {
    final stage = '${_modPath(m, x)}/sync_stage_0_reg';
    final sources = _sourceRegs(m, x.input('async_in'));
    expect(sources, isNotEmpty, reason: '${x.name} has no source register');
    for (final r in sources) {
      expect(
        maxDelays.any(
          (c) =>
              c.toCells.any((p) => _glob(p, stage)) &&
              c.fromCells.any((p) => _glob(p, r)),
        ),
        isTrue,
        reason: 'source $r of ${x.name} has no max delay to $stage',
      );
    }
  }

  final resetSyncs = regs.where(
    (r) => RegExp(r'(_rst|join_reset)_sync_\d+_reg$').hasMatch(r),
  );
  expect(resetSyncs, isNotEmpty);
  for (final r in resetSyncs) {
    expect(
      prePins.any((p) => _glob(p, r)),
      isTrue,
      reason: 'reset synchronizer $r has no false path',
    );
  }
}

HarborEthernetMac _mac(HarborEthernetConfig c) => HarborEthernetMac(
  baseAddress: 0x40000000,
  config: c,
  fabricKind: HarborFabricKind.wishbone,
  target: _artix,
  name: 'eth0',
);

void main() {
  test('RGMII full: every cell pattern matches a register', () async {
    await _check(_mac(HarborEthernetConfig.full(phy: HarborEthPhy.rgmii)));
  });

  test('MII basic: every cell pattern matches a register', () async {
    await _check(_mac(HarborEthernetConfig.basic(phy: HarborEthPhy.mii)));
  });
}
