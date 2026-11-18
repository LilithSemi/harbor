import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

const _warning =
    'Warning: create_clock: target [get_nets {x.y}] matched nothing, so the '
    '10.000 ns constraint was NOT applied (on line 104).';

void main() {
  for (final himbaechel in [false, true]) {
    group('PnR clock constraint check, himbaechel=$himbaechel', () {
      final mk = HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
        useOpenXc7: true,
        useHimbaechel: himbaechel,
        pinMap: const {'clk': 'A1'},
      ).generateMakefile('Top');

      test('nextpnr writes a log and the recipe reads it', () {
        expect(mk, contains(r'-l $(TOP)_pnr.log'));
        expect(mk, contains('matched nothing, so the'));
        expect(mk, contains('constraint was NOT applied'));
        expect(mk, contains('\n.DELETE_ON_ERROR:\n'));
        final lines = mk.split('\n');
        final nextpnr = lines.indexWhere(
          (l) => l.startsWith('\t') && l.contains('nextpnr-'),
        );
        final check = lines.indexWhere((l) => l.contains('matched nothing'));
        expect(check, nextpnr + 1);
      });

      test('the recipe fails on the warning and passes on a clean log', () {
        final recipe = mk
            .split('\n')
            .firstWhere((l) => l.contains('matched nothing'))
            .trim();
        final dir = Directory.systemTemp.createTempSync('pnr_check');
        addTearDown(() => dir.deleteSync(recursive: true));
        int run(String log) {
          File('${dir.path}/Top_pnr.log').writeAsStringSync(log);
          final cmd = recipe
              .replaceAll(r'$$', r'$')
              .replaceAll(r'$(TOP)', '${dir.path}/Top');
          return Process.runSync('sh', ['-c', cmd]).exitCode;
        }

        expect(run('Info: ok\n$_warning\nInfo: done\n'), isNot(0));
        expect(
          run(
            "Warning: net 'x.y' does not exist in design, ignoring clock "
            'constraint\n',
          ),
          isNot(0),
        );
        expect(run('Info: ok\nWarning: other\n'), 0);
      });
    });
  }

  test('require_net raises for every net that the lookup does not find', () {
    final py = Process.runSync('python3', ['-c', '1']);
    if (py.exitCode != 0) {
      markTestSkipped('python3 is not installed');
      return;
    }
    final script = HarborFpgaTarget.artix7(
      device: 'xc7a200t',
      package: 'fbg484',
      useOpenXc7: true,
    ).generatePllClockConstraintPy({'primary': 100, 'alias': 100});
    final def = script.substring(0, script.indexOf('for net, mhz in'));
    final dir = Directory.systemTemp.createTempSync('require_net');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/t.py').writeAsStringSync('''
class Ctx:
    def getNetByAlias(self, n):
        if n in ('primary', 'alias'):
            return object()
        if n == 'key':
            raise KeyError(n)
        if n == 'runtime':
            raise RuntimeError(n)
        return None
ctx = Ctx()
$def
out = []
for n in ('primary', 'alias', 'key', 'runtime', 'none'):
    try:
        require_net(n)
        out.append(n + ':ok')
    except Exception:
        out.append(n + ':raise')
print(' '.join(out))
''');
    final r = Process.runSync('python3', ['-I', '${dir.path}/t.py']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(
      (r.stdout as String).trim(),
      'primary:ok alias:ok key:raise runtime:raise none:raise',
    );
  });
}
