@Tags(['slow'])
library;

import 'package:test/test.dart';

import 'display_integration_cases.dart';

void main() {
  // Frames 0 and 1 prime the display.
  test(
    'ulx3s: 640x480 timing on an sdram scanout port, xrgb8888 then rgb565 through update',
    runUlx3s640,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
