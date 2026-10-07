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
}
