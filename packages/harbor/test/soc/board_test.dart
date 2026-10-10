import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborBoard registry', () {
    test('get resolves the ulx3s-85f preset', () {
      final board = HarborBoard.get('ulx3s-85f');
      expect(board.name, equals('ulx3s-85f'));
      expect(board.vendor, equals(HarborFpgaVendor.ecp5));
      expect(board.device, equals('lfe5u-85f'));
      expect(board.package, equals('CABGA381'));
      expect(board.oscillatorHz, equals(25000000));
    });

    test('get throws on an unknown board', () {
      expect(() => HarborBoard.get('nope-1'), throwsArgumentError);
    });

    test('the ulx3s preset has a programming command', () {
      expect(HarborBoard.get('ulx3s-85f').progCommand, isNotNull);
    });

    test('the orangecrab-25f preset exposes the USB, button and LED pins', () {
      final pins = HarborBoard.get('orangecrab-25f').pins;
      expect(pins['usb_dp'], equals('N1 LVCMOS33'));
      expect(pins['usb_dm'], equals('M2 LVCMOS33'));
      expect(pins['usb_pullup'], equals('N2 LVCMOS33'));
      expect(pins['rst_n'], equals('V17 LVCMOS33'));
      expect(pins['led_g'], equals('M3 LVCMOS33'));
    });

    test('the orangecrab-25f clock is the 48 MHz oscillator on A9', () {
      final board = HarborBoard.get('orangecrab-25f');
      expect(board.pins[board.clockPortName], startsWith('A9'));
      expect(board.oscillatorHz, equals(48000000));
      // A9 belongs to the clock entry only, no second pin repeats it.
      final onA9 = board.pins.entries.where(
        (e) => e.value.split(' ').first == 'A9',
      );
      expect(onA9.length, equals(1));
    });

    test('the orangecrab-25f preset carries the 1-bit microSD socket', () {
      final pins = HarborBoard.get('orangecrab-25f').pins;
      expect(pins['sd_clk'], equals('K1 LVCMOS33 PULLMODE=DOWN'));
      expect(pins['sd_cmd'], equals('K2 LVCMOS33 PULLMODE=UP'));
      expect(pins['sd_dat0'], equals('J1 LVCMOS33 PULLMODE=UP'));
      // A 1-bit bus reads DAT0 alone, but all four data balls are here. An
      // SD host holds its command inhibit while DAT[3:0] read busy, and a
      // ball with no constraint has no pull-up and floats, so a design that
      // leaves DAT1 to DAT3 out can look permanently busy to the host. A
      // design that asks for these pins must carry a top-level port for
      // each one, because a site for a port that does not exist makes the
      // place-and-route tool reject the build.
      expect(pins['sd_dat1'], equals('K3 LVCMOS33 PULLMODE=UP'));
      expect(pins['sd_dat2'], equals('L3 LVCMOS33 PULLMODE=UP'));
      expect(pins['sd_dat3'], equals('M1 LVCMOS33 PULLMODE=UP'));
    });

    test('the orangecrab SD clock ball is NOT clock capable', () {
      final board = HarborBoard.get('orangecrab-25f');
      // K1 is a general I/O, so a design that clocks logic from sd_clk must
      // put a clock buffer between the pad and the logic. The oscillator
      // ball is the one this board states reaches a clock net.
      expect(board.siteIsClockCapable(board.pins['sd_clk']!), isFalse);
      expect(board.siteIsClockCapable(board.pins['clk']!), isTrue);
      // A bare ball reads the same as a full catalog entry.
      expect(board.siteIsClockCapable('A9'), isTrue);
      expect(board.siteIsClockCapable('K1'), isFalse);
    });

    test('a board that states nothing has no clock-capable ball', () {
      // The default is empty, so a design puts a clock buffer on every pin
      // it clocks from. That is the safe direction: a buffer that was not
      // necessary costs one global buffer, a missing one gives skew.
      final board = HarborBoard.get('ulx3s-85f');
      expect(board.clockCapableSites, isEmpty);
      expect(board.siteIsClockCapable(board.pins['clk']!), isFalse);
    });

    test('the orangecrab SD pins reach the generated LPF', () {
      final target = HarborBoard.get(
        'orangecrab-25f',
      ).fpgaTarget(pins: ['clk', 'sd_clk', 'sd_cmd', 'sd_dat0']);
      final lpf = target.generateConstraints();
      expect(lpf, contains('LOCATE COMP "sd_clk" SITE "K1";'));
      expect(lpf, contains('LOCATE COMP "sd_cmd" SITE "K2";'));
      expect(lpf, contains('LOCATE COMP "sd_dat0" SITE "J1";'));
      // The pull-up attribute passes through to the LPF verbatim.
      expect(
        lpf,
        contains('IOBUF PORT "sd_cmd" IO_TYPE=LVCMOS33 PULLMODE=UP;'),
      );
      expect(
        lpf,
        contains('IOBUF PORT "sd_dat0" IO_TYPE=LVCMOS33 PULLMODE=UP;'),
      );
    });

    test('the orangecrab DAT1 to DAT3 balls carry a pull-up', () {
      // An SD host holds its command inhibit while DAT[3:0] read busy. A
      // real card holds all four lines high through pull-ups, so a ball
      // with no constraint floats and the host can read a card that never
      // becomes free. The three balls a 1-bit datapath does not read
      // therefore still need the pull-up attribute.
      final target = HarborBoard.get(
        'orangecrab-25f',
      ).fpgaTarget(pins: ['clk', 'sd_dat1', 'sd_dat2', 'sd_dat3']);
      final lpf = target.generateConstraints();
      expect(lpf, contains('LOCATE COMP "sd_dat1" SITE "K3";'));
      expect(lpf, contains('LOCATE COMP "sd_dat2" SITE "L3";'));
      expect(lpf, contains('LOCATE COMP "sd_dat3" SITE "M1";'));
      expect(
        lpf,
        contains('IOBUF PORT "sd_dat1" IO_TYPE=LVCMOS33 PULLMODE=UP;'),
      );
      expect(
        lpf,
        contains('IOBUF PORT "sd_dat2" IO_TYPE=LVCMOS33 PULLMODE=UP;'),
      );
      expect(
        lpf,
        contains('IOBUF PORT "sd_dat3" IO_TYPE=LVCMOS33 PULLMODE=UP;'),
      );
      // The four data balls are four different sites.
      final sites = ['J1', 'K3', 'L3', 'M1'];
      expect(sites.toSet(), hasLength(4));
    });

    test('the orangecrab USB pins reach the generated LPF', () {
      final target = HarborBoard.get(
        'orangecrab-25f',
      ).fpgaTarget(pins: ['clk', 'usb_dp', 'usb_dm', 'usb_pullup']);
      final lpf = target.generateConstraints();
      expect(lpf, contains('LOCATE COMP "usb_dp" SITE "N1";'));
      expect(lpf, contains('LOCATE COMP "usb_dm" SITE "M2";'));
      expect(lpf, contains('IOBUF PORT "usb_pullup" IO_TYPE=LVCMOS33;'));
    });

    test('the ulx3s preset exposes the GPDI pins (LVCMOS33D)', () {
      final pins = HarborBoard.get('ulx3s-85f').pins;
      expect(pins['gpdi_dp[0]'], startsWith('A16'));
      expect(pins['gpdi_dp[1]'], startsWith('A14'));
      expect(pins['gpdi_dp[2]'], startsWith('A12'));
      expect(pins['gpdi_dp[3]'], startsWith('A17')); // clock pair
      expect(pins['gpdi_dp[0]'], contains('LVCMOS33D'));
    });

    test('the ulx3s preset exposes the GPDI sideband pins', () {
      final pins = HarborBoard.get('ulx3s-85f').pins;
      expect(pins['gpdi_sda'], equals('B19 LVCMOS33 DRIVE=4 PULLMODE=UP'));
      expect(pins['gpdi_scl'], equals('E12 LVCMOS33 DRIVE=4 PULLMODE=UP'));
      expect(pins['gpdi_hpd'], equals('B20 LVCMOS33 DRIVE=4'));
      expect(pins['gpdi_cec'], equals('A18 LVCMOS33 DRIVE=4 PULLMODE=UP'));
    });

    test('the ulx3s preset exposes the USB device port pins', () {
      final pins = HarborBoard.get('ulx3s-85f').pins;
      expect(pins['usb_dp'], equals('D15 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
      expect(pins['usb_dm'], equals('E15 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
      expect(pins['usb_pullup'], equals('B12 LVCMOS33 DRIVE=16 PULLMODE=NONE'));
      // The differential-input-only pads and the unused pull-down control
      // are not in the hardware-proven mapping.
      expect(pins.containsKey('usb_fpga_dp'), isFalse);
      expect(pins.containsKey('usb_fpga_pu_dn'), isFalse);
    });

    test('the ulx3s preset exposes the LED pins', () {
      final pins = HarborBoard.get('ulx3s-85f').pins;
      expect(pins['led[0]'], equals('B2 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
      expect(pins['led[1]'], equals('C2 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
      expect(pins['led[2]'], equals('C1 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
      expect(pins['led[3]'], equals('D2 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
      expect(pins['led[4]'], equals('D1 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
      expect(pins['led[5]'], equals('E2 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
      expect(pins['led[6]'], equals('E1 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
      expect(pins['led[7]'], equals('H3 LVCMOS33 DRIVE=4 PULLMODE=NONE'));
    });

    test('the ulx3s preset exposes the button pins', () {
      final pins = HarborBoard.get('ulx3s-85f').pins;
      expect(pins['rst_n'], equals('D6 LVCMOS33 DRIVE=4 PULLMODE=UP'));
      expect(pins['btn_fire1'], equals('R1 LVCMOS33 DRIVE=4 PULLMODE=DOWN'));
      expect(pins['btn_fire2'], equals('T1 LVCMOS33 DRIVE=4 PULLMODE=DOWN'));
      expect(pins['btn_up'], equals('R18 LVCMOS33 DRIVE=4 PULLMODE=DOWN'));
      expect(pins['btn_down'], equals('V1 LVCMOS33 DRIVE=4 PULLMODE=DOWN'));
      expect(pins['btn_left'], equals('U1 LVCMOS33 DRIVE=4 PULLMODE=DOWN'));
      expect(pins['btn_right'], equals('H16 LVCMOS33 DRIVE=4 PULLMODE=DOWN'));
    });
  });

  group('ulx3s sdram pins', () {
    // Sites from emard/ulx3s doc/constraints/ulx3s_v20.lpf.
    const expected = {
      'sdram_clk': 'F19',
      'sdram_cke': 'F20',
      'sdram_cs_n': 'P20',
      'sdram_we_n': 'T20',
      'sdram_ras_n': 'R20',
      'sdram_cas_n': 'T19',
      'sdram_addr[0]': 'M20',
      'sdram_addr[1]': 'M19',
      'sdram_addr[2]': 'L20',
      'sdram_addr[3]': 'L19',
      'sdram_addr[4]': 'K20',
      'sdram_addr[5]': 'K19',
      'sdram_addr[6]': 'K18',
      'sdram_addr[7]': 'J20',
      'sdram_addr[8]': 'J19',
      'sdram_addr[9]': 'H20',
      'sdram_addr[10]': 'N19',
      'sdram_addr[11]': 'G20',
      'sdram_addr[12]': 'G19',
      'sdram_ba[0]': 'P19',
      'sdram_ba[1]': 'N20',
      'sdram_dqm[0]': 'U19',
      'sdram_dqm[1]': 'E20',
      'sdram_dq[0]': 'J16',
      'sdram_dq[1]': 'L18',
      'sdram_dq[2]': 'M18',
      'sdram_dq[3]': 'N18',
      'sdram_dq[4]': 'P18',
      'sdram_dq[5]': 'T18',
      'sdram_dq[6]': 'T17',
      'sdram_dq[7]': 'U20',
      'sdram_dq[8]': 'E19',
      'sdram_dq[9]': 'D20',
      'sdram_dq[10]': 'D19',
      'sdram_dq[11]': 'C20',
      'sdram_dq[12]': 'E18',
      'sdram_dq[13]': 'F18',
      'sdram_dq[14]': 'J18',
      'sdram_dq[15]': 'J17',
    };

    test('the ulx3s preset has the 39 sdram pins', () {
      final pins = HarborBoard.get('ulx3s-85f').pins;
      final sdram = pins.keys.where((k) => k.startsWith('sdram_')).toList();
      expect(sdram, hasLength(39));
      for (final e in expected.entries) {
        expect(pins[e.key], equals('${e.value} LVCMOS33 SLEWRATE=FAST'));
      }
    });

    test('the lpf has 39 sdram locate lines with fast slew', () {
      final target = HarborBoard.get(
        'ulx3s-85f',
      ).fpgaTarget(pins: ['clk', ...expected.keys]);
      final lpf = target.generateConstraints();
      final locates = lpf
          .split('\n')
          .where((l) => l.startsWith('LOCATE COMP "sdram_'));
      expect(locates, hasLength(39));
      for (final e in expected.entries) {
        expect(lpf, contains('LOCATE COMP "${e.key}" SITE "${e.value}";'));
        expect(
          lpf,
          contains('IOBUF PORT "${e.key}" IO_TYPE=LVCMOS33 SLEWRATE=FAST;'),
        );
      }
    });

    test('no ulx3s site is used by two catalog entries', () {
      final pins = HarborBoard.get('ulx3s-85f').pins;
      final bySite = <String, String>{};
      for (final e in pins.entries) {
        final site = e.value.split(' ').first;
        expect(
          bySite[site],
          isNull,
          reason: '$site: ${bySite[site]}, ${e.key}',
        );
        bySite[site] = e.key;
      }
    });
  });

  group('HarborBoard.fpgaTarget', () {
    late HarborBoard board;

    setUp(() {
      board = HarborBoard.get('ulx3s-85f');
    });

    test('carries the board device, package, and vendor', () {
      final target = board.fpgaTarget();
      expect(target.vendor, equals(HarborFpgaVendor.ecp5));
      expect(target.device, equals('lfe5u-85f'));
      expect(target.package, equals('CABGA381'));
    });

    test('frequency defaults to the board oscillator', () {
      expect(board.fpgaTarget().frequency, equals(25000000));
    });

    test('frequency can be overridden', () {
      expect(board.fpgaTarget(frequency: 50000000).frequency, equals(50000000));
    });

    test('selects only the requested pins from the catalog', () {
      final target = board.fpgaTarget(pins: ['clk', 'uart_tx']);
      expect(target.pinMap.keys, containsAll(['clk', 'uart_tx']));
      expect(target.pinMap.containsKey('uart_rx'), isFalse);
      // Sites come from the board catalog.
      expect(target.pinMap['clk'], startsWith('G2'));
    });

    test('all catalog pins are used when none are requested', () {
      final target = board.fpgaTarget();
      expect(target.pinMap.keys, containsAll(['clk', 'uart_tx', 'uart_rx']));
    });

    test('extra pins merge in alongside catalog pins', () {
      final target = board.fpgaTarget(pins: ['clk'], extraPins: {'led0': 'B2'});
      expect(target.pinMap['led0'], equals('B2'));
      expect(target.pinMap.containsKey('clk'), isTrue);
    });

    test('throws when a requested pin is not in the catalog', () {
      expect(
        () => board.fpgaTarget(pins: ['nonexistent']),
        throwsArgumentError,
      );
    });

    test('threads the programming command into the target', () {
      final target = board.fpgaTarget();
      final makefile = target.generateMakefile('my_soc');
      expect(makefile, contains('prog:'));
      expect(makefile, contains('openFPGALoader'));
    });
  });

  group('HarborBoard.fpgaTarget on the Arty S7 (openXC7, Xilinx)', () {
    // Regression: HarborBoard.fpgaTarget builds its target through the
    // plain HarborFpgaTarget constructor, which has no family-specific
    // constructor to set the family from. The prjxray family must still
    // resolve to spartan7 for this board, same as before family tracking
    // was added to HarborFpgaTarget.
    test('generated Makefile uses the spartan7 prjxray family', () {
      final target = HarborBoard.get('arty-s7-50').fpgaTarget();
      final makefile = target.generateMakefile('my_soc');
      expect(makefile, contains('FAMILY = spartan7'));
      expect(
        makefile,
        contains('fasm2frames --db-root \$(XRAY_DB)/\$(FAMILY)'),
      );
      expect(
        makefile,
        contains(
          'xc7frames2bit --part_file \$(XRAY_DB)/\$(FAMILY)/\$(PART)/part.yaml',
        ),
      );
    });
  });

  group('HarborFpgaTarget programming and clock', () {
    test('no prog target without a progCommand', () {
      const target = HarborFpgaTarget.ecp5(
        device: 'lfe5u-85f',
        package: 'CABGA381',
        pinMap: {'clk': 'G2'},
      );
      expect(target.generateMakefile('soc'), isNot(contains('prog:')));
    });

    test('clockPortName drives the LPF frequency constraint', () {
      const target = HarborFpgaTarget.ecp5(
        device: 'lfe5u-85f',
        package: 'CABGA381',
        frequency: 25000000,
        pinMap: {'clk_in': 'G2'},
        clockPortName: 'clk_in',
      );
      expect(target.generateConstraints(), contains('FREQUENCY PORT "clk_in"'));
    });
  });

  group('orangecrab-25f DDR3 pins', () {
    // Sites and attributes from River's packages/river_hdl/lib/src/boards.dart
    // DdrBoard._orangeCrab (r0.2), checked against litex-boards gsd_orangecrab
    // commit 6f70475. Non-DQS pins do not change with the DLL mode.
    const common = {
      'sdram_ck': 'J18 SSTL135_I SLEWRATE=FAST',
      'sdram_ck_n': 'K18 SSTL135_I SLEWRATE=FAST',
      'sdram_cke': 'D18 SSTL135_I SLEWRATE=FAST',
      'sdram_cs_n': 'A12 SSTL135_I SLEWRATE=FAST',
      'sdram_ras_n': 'C12 SSTL135_I SLEWRATE=FAST',
      'sdram_cas_n': 'D13 SSTL135_I SLEWRATE=FAST',
      'sdram_we_n': 'B12 SSTL135_I SLEWRATE=FAST',
      'sdram_odt': 'C13 SSTL135_I SLEWRATE=FAST',
      'sdram_reset_n': 'L18 SSTL135_I SLEWRATE=FAST',
      'sdram_ba[0]': 'D6 SSTL135_I SLEWRATE=FAST',
      'sdram_ba[1]': 'B7 SSTL135_I SLEWRATE=FAST',
      'sdram_ba[2]': 'A6 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[0]': 'C4 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[1]': 'D2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[2]': 'D3 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[3]': 'A3 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[4]': 'A4 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[5]': 'D4 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[6]': 'C3 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[7]': 'B2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[8]': 'B1 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[9]': 'D1 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[10]': 'A7 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[11]': 'C2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[12]': 'B6 SSTL135_I SLEWRATE=FAST',
      'sdram_dm[0]': 'D16 SSTL135_I SLEWRATE=FAST',
      'sdram_dm[1]': 'G16 SSTL135_I SLEWRATE=FAST',
      'sdram_dq[0]': 'C17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[1]': 'D15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[2]': 'B17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[3]': 'C16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[4]': 'A15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[5]': 'B13 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[6]': 'A17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[7]': 'A13 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[8]': 'F17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[9]': 'F16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[10]': 'G15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[11]': 'F15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[12]': 'J16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[13]': 'C18 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[14]': 'H16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[15]': 'F18 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'ddr_vccio[0]': 'K16 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[1]': 'D17 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[2]': 'K15 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[3]': 'K17 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[4]': 'B18 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[5]': 'C6 SSTL135_II SLEWRATE=FAST',
      'ddr_gnd[0]': 'L15 SSTL135_II SLEWRATE=FAST',
      'ddr_gnd[1]': 'L16 SSTL135_II SLEWRATE=FAST',
    };

    const dllOnDqs = {
      'sdram_dqs[0]':
          'B15 SSTL135D_I SLEWRATE=FAST TERMINATION=OFF DIFFRESISTOR=100',
      'sdram_dqs[1]':
          'G18 SSTL135D_I SLEWRATE=FAST TERMINATION=OFF DIFFRESISTOR=100',
    };

    const dllOffDqs = {
      'sdram_dqs[0]': 'B15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dqs[1]': 'G18 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dqs_n[0]': 'A16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dqs_n[1]': 'H17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
    };

    test('DLL-on gives the exact expected site and IO type for every pin', () {
      final board = HarborBoard.get('orangecrab-25f');
      final pins = board.ddrPinsFor(dllOn: true);
      for (final e in {...common, ...dllOnDqs}.entries) {
        expect(pins[e.key], equals(e.value), reason: e.key);
      }
      expect(pins.containsKey('sdram_dqs_n[0]'), isFalse);
      expect(pins.containsKey('sdram_dqs_n[1]'), isFalse);
    });

    test('DLL-off gives the exact expected site and IO type for every pin', () {
      final board = HarborBoard.get('orangecrab-25f');
      final pins = board.ddrPinsFor(dllOn: false);
      for (final e in {...common, ...dllOffDqs}.entries) {
        expect(pins[e.key], equals(e.value), reason: e.key);
      }
    });

    test(
      'DLL-off adds sdram_dqs_n and changes the IO standard of sdram_dqs',
      () {
        final board = HarborBoard.get('orangecrab-25f');
        final on = board.ddrPinsFor(dllOn: true);
        final off = board.ddrPinsFor(dllOn: false);

        expect(on.containsKey('sdram_dqs_n[0]'), isFalse);
        expect(on.containsKey('sdram_dqs_n[1]'), isFalse);
        expect(
          off['sdram_dqs_n[0]'],
          equals('A16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF'),
        );
        expect(
          off['sdram_dqs_n[1]'],
          equals('H17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF'),
        );

        expect(on['sdram_dqs[0]'], contains('SSTL135D_I'));
        expect(on['sdram_dqs[1]'], contains('SSTL135D_I'));
        expect(off['sdram_dqs[0]'], isNot(contains('SSTL135D_I')));
        expect(off['sdram_dqs[0]'], contains('SSTL135_I'));
        expect(off['sdram_dqs[1]'], isNot(contains('SSTL135D_I')));
        expect(off['sdram_dqs[1]'], contains('SSTL135_I'));

        // The site stays the same across both modes, only the IO type changes.
        expect(
          on['sdram_dqs[0]']!.split(' ').first,
          equals(off['sdram_dqs[0]']!.split(' ').first),
        );
      },
    );

    test('non-DQS DDR3 pins are identical in both DLL modes', () {
      final board = HarborBoard.get('orangecrab-25f');
      final on = board.ddrPinsFor(dllOn: true);
      final off = board.ddrPinsFor(dllOn: false);
      for (final key in common.keys) {
        expect(off[key], equals(on[key]), reason: key);
      }
    });

    test('fpgaTarget requires ddrDllOn when sdram_dqs pins are selected', () {
      final board = HarborBoard.get('orangecrab-25f');
      expect(
        () => board.fpgaTarget(pins: ['clk', 'sdram_dqs[0]']),
        throwsArgumentError,
      );
      expect(() => board.fpgaTarget(), throwsArgumentError);
    });

    test('fpgaTarget builds the DLL-on target when asked', () {
      final board = HarborBoard.get('orangecrab-25f');
      final target = board.fpgaTarget(ddrDllOn: true);
      expect(target.pinMap['sdram_dqs[0]'], contains('SSTL135D_I'));
      expect(target.pinMap.containsKey('sdram_dqs_n[0]'), isFalse);
    });

    test('fpgaTarget builds the DLL-off target when asked', () {
      final board = HarborBoard.get('orangecrab-25f');
      final target = board.fpgaTarget(ddrDllOn: false);
      expect(target.pinMap['sdram_dqs[0]'], isNot(contains('SSTL135D_I')));
      expect(
        target.pinMap['sdram_dqs_n[0]'],
        equals('A16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF'),
      );
    });

    test('fpgaTarget does not require ddrDllOn for non-DQS DDR3 pins', () {
      final board = HarborBoard.get('orangecrab-25f');
      final target = board.fpgaTarget(pins: ['clk', 'sdram_ck', 'sdram_cke']);
      expect(target.pinMap['sdram_ck'], equals('J18 SSTL135_I SLEWRATE=FAST'));
    });

    test('no DDR3 pin collides with an existing orangecrab-25f pin', () {
      final board = HarborBoard.get('orangecrab-25f');
      bool isDdr(String key) =>
          key.startsWith('sdram_') ||
          key.startsWith('ddr_vccio') ||
          key.startsWith('ddr_gnd');

      // The non-DDR3 sites are fixed: neither DLL mode touches them.
      final nonDdrSites = board.pins.entries
          .where((e) => !isDdr(e.key))
          .map((e) => e.value.split(' ').first)
          .toSet();
      expect(nonDdrSites, hasLength(20)); // the preset's pre-existing pins

      for (final mode in [true, false]) {
        final ddrSites = board
            .ddrPinsFor(dllOn: mode)
            .entries
            .where((e) => isDdr(e.key))
            .map((e) => e.value.split(' ').first)
            .toSet();
        expect(
          nonDdrSites.intersection(ddrSites),
          isEmpty,
          reason: 'dllOn: $mode',
        );
        // No two DDR3 pins share a site either.
        final ddrPins = board
            .ddrPinsFor(dllOn: mode)
            .entries
            .where((e) => isDdr(e.key))
            .toList();
        final bySite = <String, String>{};
        for (final e in ddrPins) {
          final site = e.value.split(' ').first;
          expect(
            bySite[site],
            isNull,
            reason: '$site: ${bySite[site]}, ${e.key}',
          );
          bySite[site] = e.key;
        }
      }
    });

    test('a board with no DLL-dependent DQS pad ignores ddrDllOn', () {
      // ulx3s-85f has no ddrDqsComplementPins, so ddrPinsFor is a no-op and
      // fpgaTarget never demands ddrDllOn.
      final board = HarborBoard.get('ulx3s-85f');
      expect(board.ddrPinsFor(dllOn: true), same(board.pins));
      expect(board.ddrPinsFor(dllOn: false), same(board.pins));
      expect(() => board.fpgaTarget(), returnsNormally);
    });
  });
}
