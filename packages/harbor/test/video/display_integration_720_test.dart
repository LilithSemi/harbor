@Tags(['slow'])
library;

import 'package:test/test.dart';

import 'display_integration_cases.dart';

void main() {
  // Frames 0 and 1 prime the display.
  test(
    'ulx3s: 720p60 at half line (640 pixel) on an sdram scanout port, rgb565 then xrgb8888 through update',
    runUlx3s720,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
