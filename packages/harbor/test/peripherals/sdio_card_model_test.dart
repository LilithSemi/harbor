import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

/// A host emulation that sends every init command to the simulated SD card of
/// the Verilator harness and checks each response the way the controller does:
/// transmission bit, end bit and CRC7 remainder. R2 is checked over bits 127:8.
const _host = r'''
// Host emulation: drive on falls and release after the end bit plus one clock.
static int crc7rem(const int* b, int n) { int c = 0; for (int i = 0; i < n; i++) { int fb = ((c >> 6) & 1) ^ b[i]; c = (c << 1) & 0x7f; if (fb) c ^= 0x09; } return c; }
static SdCard card("t");
static int sclk = 0;
static void clk(int oe, int out, int* sample) { // one SD period: fall then rise
  sclk = 0; card.tick(sclk, oe, out, 0, 0);
  sclk = 1; card.tick(sclk, oe, out, 0, 0);
  if (sample) *sample = card.cmd_in;
}
static int run(int idx, unsigned arg, int resp) { // 0 none, 1 short, 2 long
  int f[48]; f[0] = 0; f[1] = 1;
  for (int i = 0; i < 6; i++) f[2+i] = (idx >> (5-i)) & 1;
  for (int i = 0; i < 32; i++) f[8+i] = (arg >> (31-i)) & 1;
  int c = crc7rem(f, 40); for (int i = 0; i < 7; i++) f[40+i] = (c >> (6-i)) & 1; f[47] = 1;
  for (int i = 0; i < 48; i++) clk(1, f[i], nullptr);
  if (!resp) { for (int i = 0; i < 20; i++) clk(0, 1, nullptr); return 0; }
  clk(1, 1, nullptr); // sEnd keeps the end bit one clock
  int s = 1, n = 0; for (n = 0; n < 128; n++) { clk(0, 1, &s); if (!s) break; }
  if (s) { printf("cmd%d: no response\n", idx); return 1; }
  int len = resp == 2 ? 136 : 48; int r[136]; r[0] = 0;
  for (int i = 1; i < len; i++) clk(0, 1, &r[i]);
  int bad = 0;
  if (r[1] != 0) { printf("cmd%d: tx bit 1\n", idx); bad = 1; }
  if (r[len-1] != 1) { printf("cmd%d: end bit 0\n", idx); bad = 1; }
  int rem = resp == 2 ? crc7rem(r + 8, 127) : crc7rem(r + 1, 46);
  if (rem) { printf("cmd%d: crc7 remainder 0x%x\n", idx, rem); bad = 1; }
  if (!bad) printf("cmd%d: ok (ncr %d)\n", idx, n + 1);
  for (int i = 0; i < 10; i++) clk(1, 1, nullptr);
  return bad;
}
int main() {
  for (int i = 0; i < 80; i++) clk(1, 1, nullptr);
  int bad = 0;
  bad |= run(0, 0, 0);
  bad |= run(8, 0x1aa, 1);
  bad |= run(55, 0, 1);
  bad |= run(41, 0x40ff8000, 1);
  bad |= run(2, 0, 2);
  bad |= run(3, 0, 1);
  bad |= run(9, 0x10000, 2);
  bad |= run(7, 0x10000, 1);
  return bad;
}
''';

void main() {
  test(
    'the simulated card answers every init command with a good frame',
    () async {
      final dir = Directory.systemTemp.createTempSync('sd_card_model');
      addTearDown(() => dir.deleteSync(recursive: true));
      final source = File('${dir.path}/host.cpp')
        ..writeAsStringSync('${HarborSdioController.simCardHeader}\n$_host');
      final exe = '${dir.path}/host';
      final build = await Process.run('g++', [
        '-std=c++17',
        '-Wall',
        '-o',
        exe,
        source.path,
      ]);
      expect(build.exitCode, equals(0), reason: '${build.stderr}');
      final run = await Process.run(exe, const []);
      final out = '${run.stdout}';
      expect(run.exitCode, equals(0), reason: out);
      for (final cmd in [8, 55, 41, 2, 3, 9, 7]) {
        expect(out, contains('cmd$cmd: ok'), reason: out);
      }
    },
  );
}
