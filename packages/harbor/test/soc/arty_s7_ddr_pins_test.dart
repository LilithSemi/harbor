import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

/// The Arty S7-50 DDR3L pad table.
///
/// A wrong ball here builds and places cleanly and then fails on the bench,
/// which no simulation can catch, so the shape of the table is checked rather
/// than trusted. The sites come from the litex/migen `arty_s7` platform for the
/// Micron MT41K128M16.
void main() {
  final board = HarborBoard.get('arty-s7-50');

  test('carries a complete DDR3 pad set', () {
    for (final signal in const [
      'sdram_ck',
      'sdram_ck_n',
      'sdram_cke',
      'sdram_cs_n',
      'sdram_ras_n',
      'sdram_cas_n',
      'sdram_we_n',
      'sdram_odt',
      'sdram_reset_n',
    ]) {
      expect(board.pins, contains(signal), reason: '$signal has no site');
    }

    // x16 part: 14 row lines, 3 bank lines, 16 data lines, 2 byte lanes.
    for (var i = 0; i < 14; i++) {
      expect(board.pins, contains('sdram_addr[$i]'));
    }
    for (var i = 0; i < 3; i++) {
      expect(board.pins, contains('sdram_ba[$i]'));
    }
    for (var i = 0; i < 16; i++) {
      expect(board.pins, contains('sdram_dq[$i]'));
    }
    for (var i = 0; i < 2; i++) {
      expect(board.pins, contains('sdram_dm[$i]'));
      expect(board.pins, contains('sdram_dqs[$i]'));
      // The PHY drives the complement rail itself. Dropping it fails
      // place-and-route with "no IOSTANDARD", not with anything about DQS.
      expect(board.pins, contains('sdram_dqs_n[$i]'));
    }
  });

  test('every ball is used once', () {
    final ddr = board.pins.entries.where((e) => e.key.startsWith('sdram_'));
    final byBall = <String, List<String>>{};
    for (final e in ddr) {
      byBall.putIfAbsent(e.value.split(' ').first, () => []).add(e.key);
    }
    final shared = byBall.entries.where((e) => e.value.length > 1);
    expect(
      shared,
      isEmpty,
      reason:
          'two DDR signals on one ball short together: '
          '${shared.map((e) => '${e.key} <- ${e.value}').join('; ')}',
    );
  });

  test('the display and the DDR do not fight over a ball', () {
    final ddrBalls = {
      for (final e in board.pins.entries)
        if (e.key.startsWith('sdram_')) e.value.split(' ').first,
    };
    final gpdiBalls = {
      for (final e in board.pins.entries)
        if (e.key.startsWith('gpdi_')) e.value.split(' ').first,
    };
    expect(ddrBalls.intersection(gpdiBalls), isEmpty);
  });

  test('a build can ask for the DDR pads by name', () {
    final target = board.fpgaTarget(
      pins: ['clk', 'sdram_ck', 'sdram_dq[0]', 'gpdi_dp[0]'],
    );
    expect(target.pinMap['sdram_ck'], startsWith('R5'));
    expect(target.vendor, HarborFpgaVendor.openXc7);
  });

  test('the TMDS adapter sits on Pmod JA and leaves JB free', () {
    const sites = {
      'gpdi_dn[2]': 'L17',
      'gpdi_dn[1]': 'L18',
      'gpdi_dn[0]': 'M14',
      'gpdi_dn[3]': 'N14',
      'gpdi_dp[2]': 'M16',
      'gpdi_dp[1]': 'M17',
      'gpdi_dp[0]': 'M18',
      'gpdi_dp[3]': 'N18',
    };
    sites.forEach((signal, site) {
      expect(board.pins[signal], equals('$site LVCMOS33'), reason: signal);
    });

    final ja = board.interfaces['pmod@ja']!;
    final jb = board.interfaces['pmod@jb']!;
    final display = {
      for (final s in sites.keys) board.pins[s]!.split(' ').first,
    };
    expect(display, hasLength(8));
    expect(
      jb.values.map((p) => p.split(' ').first).toSet().intersection(display),
      isEmpty,
    );
    expect(
      ja.values.map((p) => p.split(' ').first).toSet().difference(display),
      isEmpty,
    );
  });

  test('pmod@jd uses the JD sites and collides with nothing', () {
    final jd = board.interfaces['pmod@jd']!;
    expect(jd['cs'], equals('V15 LVCMOS33'));
    expect(jd['mosi'], equals('U12 LVCMOS33'));
    expect(jd['miso'], equals('V13 LVCMOS33 PULLTYPE=PULLUP'));
    expect(jd['sck'], equals('T12 LVCMOS33'));

    String site(String p) => p.split(' ').first;
    final jdSites = jd.values.map(site).toSet();
    expect(jdSites, hasLength(4));
    for (final other in const ['pmod@ja', 'pmod@jb']) {
      final sites = board.interfaces[other]!.values.map(site).toSet();
      expect(jdSites.intersection(sites), isEmpty, reason: other);
    }
    final named = board.pins.entries
        .where((e) => e.key.startsWith('gpdi_'))
        .map((e) => site(e.value))
        .toSet();
    expect(jdSites.intersection(named), isEmpty);
  });
}
