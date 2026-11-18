@Tags(['slow'])
library;

import 'package:test/test.dart';

import 'display_integration_cases.dart';

void main() {
  // Frames 0 and 1 prime the display.
  test(
    'ax7203: half line 1024x768 timing on the axi4 fabric, nv12 and xrgb8888 with an xrgb8888 overlay through update',
    runAx7203,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
