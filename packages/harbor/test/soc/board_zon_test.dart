import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _kc705Zon = '''
.{
    .vendor = "Lilith Semiconductor",
    .product = "Delta V1",
    .family = "kc705_soc",
    .cpu = .{ .model = "River RC1.f", .isa = "rv64imac", .harts = 2, .clock_hz = 100000000 },
    .memory = .{
        .{ .type = .ddr3, .max_size_bytes = 1073741824, .width_bits = 64, .form_factor = .sodimm },
    },
    .board = .{ .preset = "kc705", .fpga_part = "xc7k325tffg900-2" },
}
''';

const _artyZon = '''
.{
    .family = "arty_soc",
    .cpu = .{ .model = "", .isa = "rv32imac", .harts = 1 },
    .memory = .{
        .{ .type = .ddr3, .size_bytes = 268435456, .width_bits = 16, .form_factor = .chip },
    },
    .board = .{ .preset = "arty-s7-50", .fpga_part = "xc7s50csga324-1" },
}
''';

HarborDdr3 _ddr(
  HarborDdrConfig config, {
  bool socketed = false,
  bool runtime = false,
}) => HarborDdr3(
  config: config,
  memoryFormFactor: socketed
      ? HarborMemoryFormFactor.sodimm
      : HarborMemoryFormFactor.chip,
  runtimeTrainable: runtime,
  baseAddress: 0x80000000,
  clockHz: 100000000,
  busAddressWidth: 32,
  target: const HarborSimTarget(),
  name: 'ddr',
);

void main() {
  tearDown(Simulator.reset);

  test('KC705 with DDR3 gives every field', () {
    final soc = HarborSoC(
      name: 'kc705_soc',
      compatible: 'test,kc705',
      model: 'Delta V1',
      manufacturer: 'Lilith Semiconductor',
      board: HarborBoard.get('kc705'),
      cpus: const [
        HarborCpu(
          hartId: 0,
          isa: 'rv64imac',
          model: 'River RC1.f',
          clockFrequency: 100000000,
        ),
        HarborCpu(
          hartId: 1,
          isa: 'rv64imac',
          model: 'River RC1.f',
          clockFrequency: 100000000,
        ),
      ],
    );
    soc.addPeripheral(
      _ddr(
        const HarborDdrConfig(
          type: HarborDdrType.ddr3,
          size: 1024 * 1024 * 1024,
          dataWidth: 64,
          frequency: 400000000,
        ),
        socketed: true,
      ),
    );
    expect(soc.generateBoardZon(), _kc705Zon);
  });

  test('Arty S7 with DDR3L omits what the SoC does not know', () {
    final soc = HarborSoC(
      name: 'arty_soc',
      compatible: 'test,arty',
      board: HarborBoard.get('arty-s7-50'),
      cpus: const [HarborCpu(hartId: 0, isa: 'rv32imac')],
    );
    soc.addPeripheral(_ddr(const HarborDdrConfig.artyS7()));
    expect(soc.generateBoardZon(), _artyZon);
  });

  test('a second memory on KC705 is a soldered chip', () {
    final soc = HarborSoC(
      name: 'kc705_soc',
      compatible: 'test,kc705',
      board: HarborBoard.get('kc705'),
    );
    soc.addPeripheral(
      _ddr(
        const HarborDdrConfig(
          type: HarborDdrType.ddr3,
          size: 1024 * 1024 * 1024,
          dataWidth: 64,
          frequency: 400000000,
        ),
        socketed: true,
      ),
    );
    soc.addPeripheral(
      HarborSdram(
        config: const HarborSdramConfig.as4c16m16sb6(),
        baseAddress: 0x40000000,
        clockHz: 100000000,
        target: const HarborSimTarget(),
        name: 'sdram',
      ),
    );
    final lines = soc
        .generateBoardZon()
        .split('\n')
        .where((l) => l.contains('.type ='))
        .toList();
    expect(lines, hasLength(2));
    expect(lines[0], contains('.max_size_bytes = 1073741824'));
    expect(lines[0], contains('.form_factor = .sodimm'));
    expect(lines[1], contains('.type = .sdram, .size_bytes = '));
    expect(lines[1], contains('.form_factor = .chip'));
  });

  test('a socketed runtime-train DDR3 reports the whole window', () {
    const config = HarborDdrConfig(
      type: HarborDdrType.ddr3,
      size: 1024 * 1024 * 1024,
      dataWidth: 64,
      frequency: 400000000,
    );
    final info = _ddr(config, socketed: true, runtime: true).memoryInfo;
    expect(info.sizeBytes, config.size - HarborDdr3.trainWindowSize);
    expect(info.maxSizeBytes, config.size);
    final chip = _ddr(config, runtime: true);
    expect(
      HarborBoardZonGenerator(
        family: 'f',
        memories: [chip.memoryInfo],
      ).generate(),
      contains('.size_bytes = ${config.size - HarborDdr3.trainWindowSize},'),
    );
  });

  test('a SoC with no board, vendor, cpu or memory gives the family only', () {
    final soc = HarborSoC(name: 'bare', compatible: 'test,bare');
    expect(soc.generateBoardZon(), '.{\n    .family = "bare",\n}\n');
  });

  test('two memories give a tuple', () {
    const gen = HarborBoardZonGenerator(
      family: 'f',
      memories: [
        HarborMemoryInfo(
          kind: HarborMemoryKind.sdram,
          sizeBytes: 1024,
          widthBits: 16,
        ),
        HarborMemoryInfo(
          kind: HarborMemoryKind.psram,
          sizeBytes: 2048,
          widthBits: 4,
        ),
      ],
    );
    expect(gen.generate(), '''
.{
    .family = "f",
    .memory = .{
        .{ .type = .sdram, .size_bytes = 1024, .width_bits = 16, .form_factor = .chip },
        .{ .type = .other, .size_bytes = 2048, .width_bits = 4, .form_factor = .chip },
    },
}
''');
  });

  test('new memory kinds keep their own tag', () {
    for (final k in [
      HarborMemoryKind.ddr5,
      HarborMemoryKind.lpddr4,
      HarborMemoryKind.lpddr5,
    ]) {
      final z = HarborBoardZonGenerator(
        family: 'f',
        memories: [HarborMemoryInfo(kind: k, sizeBytes: 1, widthBits: 8)],
      ).generate();
      expect(z, contains('.type = .${k.name},'));
    }
  });

  test('a socketed tuple gives a window and no fitted size', () {
    const gen = HarborBoardZonGenerator(
      family: 'f',
      memories: [
        HarborMemoryInfo(
          kind: HarborMemoryKind.ddr3,
          sizeBytes: 4096,
          widthBits: 64,
          formFactor: HarborMemoryFormFactor.sodimm,
        ),
        HarborMemoryInfo(
          kind: HarborMemoryKind.ddr3,
          sizeBytes: 8192,
          maxSizeBytes: 16384,
          widthBits: 64,
          formFactor: HarborMemoryFormFactor.sodimm,
        ),
      ],
    );
    expect(gen.generate(), '''
.{
    .family = "f",
    .memory = .{
        .{ .type = .ddr3, .max_size_bytes = 4096, .width_bits = 64, .form_factor = .sodimm },
        .{ .type = .ddr3, .max_size_bytes = 16384, .width_bits = 64, .form_factor = .sodimm },
    },
}
''');
  });

  test('strings are escaped for Zig', () {
    expect(
      HarborBoardZonGenerator.quote('a"b\\c\nd\te\x01\x7f'),
      r'"a\"b\\c\nd\te\x01\x7f"',
    );
  });

  test('every field and tag is one the firmware reader allows', () {
    const top = {
      'vendor',
      'product',
      'family',
      'version',
      'sku',
      'chassis_type',
      'cpu',
      'memory',
      'board',
    };
    const cpu = {'model', 'isa', 'harts', 'clock_hz'};
    const mem = {
      'type',
      'form_factor',
      'width_bits',
      'size_bytes',
      'max_size_bytes',
    };
    const board = {'preset', 'fpga_part'};
    const types = {
      'other',
      'unknown',
      'dram',
      'sram',
      'sdram',
      'ddr',
      'ddr2',
      'ddr3',
      'ddr4',
      'lpddr4',
      'ddr5',
      'lpddr5',
    };
    const forms = {'other', 'unknown', 'chip', 'dimm', 'sodimm'};
    final texts = [
      _kc705Zon,
      _artyZon,
      for (final k in HarborMemoryKind.values)
        for (final f in HarborMemoryFormFactor.values)
          HarborBoardZonGenerator(
            family: 'f',
            cpus: const [HarborCpu(hartId: 0, isa: 'rv64i')],
            board: HarborBoard.get('kc705'),
            memories: [
              HarborMemoryInfo(
                kind: k,
                sizeBytes: 1,
                widthBits: 8,
                formFactor: f,
              ),
            ],
          ).generate(),
    ];
    final field = RegExp(r'\.([a-z_0-9]+) =');
    final tag = RegExp(r'= \.([a-z0-9]+)\b');
    for (final t in texts) {
      for (final line in t.split('\n')) {
        final names = field.allMatches(line).map((m) => m[1]!).toList();
        final allowed = line.contains('.type =')
            ? mem
            : line.contains('.isa =')
            ? {...cpu, 'cpu'}
            : line.contains('.preset =')
            ? {...board, 'board'}
            : top;
        expect(allowed.containsAll(names), isTrue, reason: line);
      }
      for (final m in tag.allMatches(t)) {
        expect(
          {...types, ...forms}.contains(m[1]),
          isTrue,
          reason: '${m[1]} in $t',
        );
      }
    }
  });

  test('the output parses as Zig', () async {
    final zig = await Process.run('which', ['zig']);
    if (zig.exitCode != 0) {
      markTestSkipped('zig is not in the path');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('board_zon');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/a.zon').writeAsStringSync(_kc705Zon);
    File('${dir.path}/b.zon').writeAsStringSync(_artyZon);
    File('${dir.path}/c.zon').writeAsStringSync(
      HarborBoardZonGenerator(
        vendor: 'q"\\\n',
        family: 'f',
        memories: const [
          HarborMemoryInfo(
            kind: HarborMemoryKind.ddr3,
            sizeBytes: 1,
            widthBits: 8,
          ),
          HarborMemoryInfo(
            kind: HarborMemoryKind.psram,
            sizeBytes: 2,
            widthBits: 4,
          ),
        ],
      ).generate(),
    );
    final r = await Process.run('zig', ['ast-check', '${dir.path}/a.zon']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    for (final f in ['b.zon', 'c.zon']) {
      final p = await Process.run('zig', ['ast-check', '${dir.path}/$f']);
      expect(p.exitCode, 0, reason: '$f ${p.stderr}');
    }
  });
}
