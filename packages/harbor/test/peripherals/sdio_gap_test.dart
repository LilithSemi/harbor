import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';

const _ctrl = 0x00;
const _status = 0x08;
const _clkDiv = 0x10;
const _cmd = 0x18;
const _cmdArg = 0x20;
const _resp0 = 0x28;
const _intStatus = 0x60;
const _intEnable = 0x68;

List<int> _crc7(List<int> bits) {
  var c = List<int>.filled(7, 0);
  for (final b in bits) {
    final inv = b ^ c[6];
    c = [inv, c[0], c[1], c[2] ^ inv, c[3], c[4], c[5]];
  }
  return [c[6], c[5], c[4], c[3], c[2], c[1], c[0]];
}

List<int> _bitsMsb(int value, int width) => [
  for (var i = width - 1; i >= 0; i--) (value >> i) & 1,
];

int _val(List<int> bits) => bits.fold(0, (a, b) => (a << 1) | b);

List<int> _frame(int index, int arg) {
  final head = [0, 0, ..._bitsMsb(index, 6), ..._bitsMsb(arg, 32)];
  return [...head, ..._crc7(head), 1];
}

// The card model keeps the SD Physical Layer default speed timing. It samples
// CMD on the rising edge and frames a command only after [nrc] high clocks.
// The response start bit has [gap] whole clocks of Z between it and the
// command end bit (gap is Ncr). Gap 0 is the start bit on the falling edge
// that follows the end bit, where the host lets go. With [launchOnRise] the
// card drives on the rising edge, as a high speed card does.
class _Card {
  final int gap;
  final bool launchOnRise;
  final nrc = 8;
  _Card(this.gap, {this.launchOnRise = false});

  var rises = 0;
  var falls = 0;
  var highRun = 1000;
  var rx = false;
  final bits = <int>[];
  List<int>? pending;
  var edgesSinceEnd = 0;
  var oe = false;
  var out = 1;
  var txIdx = 0;

  final framed = <int>[];
  var releaseEdge = -1;
  final cmdStartRise = <int>[];
  final gapBefore = <int>[];

  void onRise(int line) {
    rises++;
    if (!oe && pending == null) {
      if (rx) {
        bits.add(line);
        if (bits.length == 48) {
          rx = false;
          highRun = 0;
          final idx = _val(bits.sublist(2, 8));
          final arg = _val(bits.sublist(8, 40));
          final crcOk =
              _val(_crc7(bits.sublist(0, 40))) == _val(bits.sublist(40, 47));
          final ok = bits[1] == 1 && bits[47] == 1 && crcOk;
          if (ok) {
            framed.add(idx);
            edgesSinceEnd = 0;
            if (idx == 8) pending = _frameR(8, arg & 0xfff);
            if (idx == 55) pending = _frameR(55, 0x120);
          }
        }
      } else if (line == 0) {
        if (highRun >= nrc) {
          rx = true;
          bits
            ..clear()
            ..add(0);
          cmdStartRise.add(rises);
          gapBefore.add(highRun);
        }
        highRun = 0;
      } else {
        highRun++;
      }
    }
    if (launchOnRise) _launch(rises);
  }

  List<int> _frameR(int index, int payload) => _frame(index, payload)..[1] = 0;

  void onFall() {
    falls++;
    if (!launchOnRise) _launch(falls);
  }

  void _launch(int edge) {
    if (pending != null && !oe) {
      edgesSinceEnd++;
      // Default speed: the falls after the end-bit rise are F1, F2, ...
      // Default speed starts on F(gap + 1). High speed starts on R(gap), and
      // R0 counts as 1 here. The host samples it on R(gap + 1) either way.
      final want = gap + 1;
      if (edgesSinceEnd == want) {
        oe = true;
        txIdx = 0;
        out = pending![txIdx++];
      }
    } else if (oe) {
      if (txIdx < pending!.length) {
        out = pending![txIdx++];
      } else {
        oe = false;
        out = 1;
        pending = null;
        releaseEdge = edge;
        highRun = 0;
      }
    }
  }
}

class _Result {
  var overlapCycles = 0;
  int? int8;
  int? resp8;
  int? int55;
  var framed = <int>[];
  var gapBefore = <int>[];
  var firstStartRise = 0;

  // SD clocks from the second enable to the first start bit after it.
  var rearmClocks = 0;
}

void main() {
  late HarborSdioController sdio;
  late Logic clk, reset, stb, we, adr, mosi, cmdIn, datIn, cd;
  late MasterTop top;

  Future<void> busWrite(int addr, int data) async {
    adr.inject(addr);
    mosi.inject(data);
    we.inject(1);
    stb.inject(1);
    await clk.nextPosedge;
    while (top.output('bus_ACK').value.toInt() != 1) {
      await clk.nextPosedge;
    }
    stb.inject(0);
    we.inject(0);
    await clk.nextPosedge;
  }

  Future<int> busRead(int addr) async {
    adr.inject(addr);
    we.inject(0);
    stb.inject(1);
    await clk.nextPosedge;
    while (top.output('bus_ACK').value.toInt() != 1) {
      await clk.nextPosedge;
    }
    final v = top.output('bus_DAT_MISO').value.toInt();
    stb.inject(0);
    await clk.nextPosedge;
    return v;
  }

  Future<_Result> run(
    int gap, {
    int clkDiv = 61,
    bool launchOnRise = false,
    bool rearm = false,
  }) async {
    final res = _Result();
    sdio = HarborSdioController(
      baseAddress: 0x60000000,
      config: const HarborSdioConfig(sampleReadOnFall: true),
    );
    top = MasterTop(
      sdio,
      iface: 'dma',
      kind: HarborFabricKind.wishbone,
      config: const HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: 4,
      ),
    );
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    stb = Logic(name: 'stb');
    we = Logic(name: 'we');
    adr = Logic(name: 'adr', width: 12);
    mosi = Logic(name: 'mosi', width: 32);
    cmdIn = Logic(name: 'cmd_in');
    datIn = Logic(name: 'dat_in', width: 4);
    cd = Logic(name: 'cd');
    top.input('clk').srcConnection! <= clk;
    top.input('reset').srcConnection! <= reset;
    top.input('bus_CYC').srcConnection! <= stb;
    top.input('bus_STB').srcConnection! <= stb;
    top.input('bus_WE').srcConnection! <= we;
    top.input('bus_ADR').srcConnection! <= adr;
    top.input('bus_DAT_MOSI').srcConnection! <= mosi;
    top.input('bus_SEL').srcConnection! <=
        Const(0xF, width: top.input('bus_SEL').width);
    top.input('sd_cmd_in').srcConnection! <= cmdIn;
    top.input('sd_cd').srcConnection! <= cd;
    top.input('sd_dat_in').srcConnection! <= datIn;
    final memory = BeatMemory(top, clk);
    await top.build();

    final cmdOut = top.output('sd_cmd_out');
    final cmdOe = top.output('sd_cmd_oe');
    final sdClk = top.output('sd_clk');

    reset.inject(1);
    stb.inject(0);
    we.inject(0);
    adr.inject(0);
    mosi.inject(0);
    cmdIn.inject(1);
    datIn.inject(0xf);
    cd.inject(1);
    memory.start();
    Simulator.setMaxSimTime(100000000);
    unawaited(Simulator.run());

    final card = _Card(gap, launchOnRise: launchOnRise);
    var stop = false;
    // The card and the wire, evaluated each half cycle after the host flops
    // have settled.
    unawaited(() async {
      var prevClk = 0;
      var inOverlap = false;
      while (!stop) {
        await clk.nextNegedge;
        final c = sdClk.value.isValid ? sdClk.value.toInt() : 0;
        final hOe = cmdOe.value.isValid ? cmdOe.value.toInt() : 0;
        final hOut = cmdOut.value.isValid ? cmdOut.value.toInt() : 1;
        int line() => hOe == 1 && card.oe
            ? (hOut & card.out)
            : hOe == 1
            ? hOut
            : card.oe
            ? card.out
            : 1;
        if (prevClk == 0 && c == 1) {
          card.onRise(line());
        } else if (prevClk == 1 && c == 0) {
          card.onFall();
        }
        if (hOe == 1 && card.oe) {
          inOverlap = true;
          res.overlapCycles++;
        }
        if (!(hOe == 1 && card.oe) && inOverlap) inOverlap = false;
        prevClk = c;
        cmdIn.inject(line());
      }
    }());

    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    Future<void> waitIdle() async {
      for (var i = 0; i < 20000; i++) {
        if ((await busRead(_status) >> 8) & 1 == 0) return;
        for (var j = 0; j < 20; j++) {
          await clk.nextPosedge;
        }
      }
      fail('host stays busy');
    }

    Future<int> cmd(int word, int arg) async {
      await waitIdle();
      await busWrite(_intStatus, 0xfff);
      await busWrite(_cmdArg, arg);
      await busWrite(_cmd, word);
      await clk.nextPosedge;
      await waitIdle();
      return busRead(_intStatus);
    }

    // Conduit init(): 1-bit, enable, poll, 400 kHz.
    await busWrite(_ctrl, 0x1);
    await busWrite(_intEnable, 0);
    await busWrite(_intStatus, 0xfff);
    await busWrite(_clkDiv, clkDiv);

    await cmd(0, 0);
    res.firstStartRise = card.cmdStartRise.first;
    if (rearm) {
      // Clearing enable stops the clock. Setting it again starts the
      // power-up clocks over.
      await busWrite(_ctrl, 0x0);
      for (var i = 0; i < 100; i++) {
        await clk.nextPosedge;
      }
      final starts = card.cmdStartRise.length;
      await busWrite(_ctrl, 0x1);
      final base = card.rises;
      await cmd(0, 0);
      res.rearmClocks = card.cmdStartRise[starts] - base;
    }
    res.int8 = await cmd(8 | (1 << 6), 0x1aa);
    res.resp8 = await busRead(_resp0);
    res.int55 = await cmd(55 | (1 << 6), 0);
    stop = true;
    res.framed = card.framed;
    res.gapBefore = card.gapBefore;
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    await Simulator.reset();
    return res;
  }

  void check(_Result r, {bool rearm = false}) {
    expect(r.int8! & 0xe10, 0, reason: 'R7 misframed');
    expect(r.resp8, 0x1aa);
    expect(r.int55! & 0xe11, 0x1, reason: 'CMD55 not answered');
    expect(r.framed, rearm ? [0, 0, 8, 55] : [0, 8, 55]);
    expect(r.gapBefore, everyElement(greaterThanOrEqualTo(8)));
    expect(r.overlapCycles, 0, reason: 'host and card both drive CMD');
    expect(
      r.firstStartRise,
      greaterThanOrEqualTo(74),
      reason: 'clocks from enable to the first command',
    );
  }

  for (final div in [61, 1]) {
    for (final gap in [0, 8, 64]) {
      test(
        'a strict card frames CMD0, CMD8 and CMD55 back to back, '
        'Ncr $gap, CLK_DIV $div',
        () async => check(await run(gap, clkDiv: div)),
        timeout: const Timeout(Duration(minutes: 20)),
      );
    }
  }

  test('a card that launches on the rising edge, 25 MHz SD clock', () async {
    check(await run(2, clkDiv: 1, launchOnRise: true));
  });

  test('clearing and setting enable starts the 80 clocks again', () async {
    final r = await run(2, clkDiv: 1, rearm: true);
    check(r, rearm: true);
    expect(r.rearmClocks, greaterThanOrEqualTo(74));
  });
}
