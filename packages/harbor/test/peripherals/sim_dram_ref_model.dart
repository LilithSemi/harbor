import 'package:rohd/rohd.dart';

/// Procedural reference model of [HarborSimDram]'s bus and scanout port
/// timing, for driving plain ROHD tests.
///
/// [HarborSimDram] itself has no ROHD body: it only carries a generated
/// SystemVerilog string a Verilator build runs, so it cannot drive a plain
/// `Simulator.run()` test. This model mirrors the same equations (one
/// memory array behind a Wishbone bus port with a registered-feedback
/// burst, and a scanout port that streams 16-bit words from it) in plain
/// Dart, the same way [SdramPinModel] stands in for real sdram pins.
///
/// Inputs are sampled on [Simulator.preTick], before anything in this
/// simulation tick has moved, the same moment a real flop samples its D
/// input. A client such as [HarborScanoutFetcher] also reacts to `clk`
/// and may still be settling its own output in this same tick; reading it
/// straight from `clk.posedge` can catch it mid-settle. Sampling on
/// preTick instead always sees the value that was stable through the
/// previous cycle, so a client's own clocked logic and this model agree
/// on what a take and its address were.
class SimDramRefModel {
  final Logic clk;
  final Logic reset;
  final Logic stb;
  final Logic we;
  final Logic adr;
  final Logic datW;
  final Logic sel;
  final Logic cti;
  final Logic scanRqValid;
  final Logic scanRqAddr;
  final Logic scanRqWords;

  final int readLatency;
  final int writeLatency;
  final int scanoutMaxInFlight;

  final ack = Logic(name: 'sim_dram_ref_ack');
  final datR = Logic(name: 'sim_dram_ref_dat_r', width: 32);
  final scanRqReady = Logic(name: 'sim_dram_ref_scan_rq_ready');
  final scanRdValid = Logic(name: 'sim_dram_ref_scan_rd_valid');
  final scanRdData = Logic(name: 'sim_dram_ref_scan_rd_data', width: 16);

  /// Every 32-bit word in the array, by word index. Missing entries read 0.
  final Map<int, int> mem = {};

  var _busy = false;
  var _left = 0;
  var _burstActive = false;

  var _curAddr = 0;
  var _curLeft = 0;
  var _scanReady = false;

  /// Wishbone bus accesses acked, classic and burst beats both.
  int acks = 0;

  /// Cycles the ack cadence watcher below saw a beat ack with no wait state
  /// after the one before it (back to back, registered-feedback style).
  int backToBackAcks = 0;

  // Pre-tick snapshots of every input, taken before this tick moves
  // anything. _onPosedge reads these, never the live signals.
  var _reset = LogicValue.zero;
  var _stb = LogicValue.zero;
  var _we = LogicValue.zero;
  var _adr = LogicValue.zero;
  var _datW = LogicValue.zero;
  var _sel = LogicValue.zero;
  var _cti = LogicValue.zero;
  var _scanRqValid = LogicValue.zero;
  var _scanRqAddr = LogicValue.zero;
  var _scanRqWords = LogicValue.zero;

  SimDramRefModel({
    required this.clk,
    required this.reset,
    required this.stb,
    required this.we,
    required this.adr,
    required this.datW,
    required this.sel,
    required this.cti,
    required this.scanRqValid,
    required this.scanRqAddr,
    required this.scanRqWords,
    this.readLatency = 1,
    this.writeLatency = 1,
    this.scanoutMaxInFlight = 3,
  }) {
    ack.put(0);
    datR.put(0);
    scanRqReady.put(0);
    scanRdValid.put(0);
    scanRdData.put(0);
    Simulator.preTick.listen((_) => _capture());
    clk.posedge.listen((_) => _onPosedge());
  }

  void _capture() {
    _reset = reset.value;
    _stb = stb.value;
    _we = we.value;
    _adr = adr.value;
    _datW = datW.value;
    _sel = sel.value;
    _cti = cti.value;
    _scanRqValid = scanRqValid.value;
    _scanRqAddr = scanRqAddr.value;
    _scanRqWords = scanRqWords.value;
  }

  /// The 32-bit word at a plain index, defaulting missing entries to 0.
  int word(int idx) => mem[idx] ?? 0;

  /// Direct peek/poke of the memory array, for setting up test fixtures or
  /// checking a write the bus port made.
  int peek(int idx) => word(idx);
  void poke(int idx, int value) => mem[idx] = value & 0xffffffff;

  int _toInt(LogicValue v) => v.isValid ? v.toInt() : 0;
  bool _bit(LogicValue v) => v.isValid && v.toInt() == 1;

  void _writeBytes(int idx, int datW, int sel) {
    var w = word(idx);
    for (var b = 0; b < 4; b++) {
      if ((sel >> b) & 1 == 1) {
        final mask = 0xff << (b * 8);
        w = (w & ~mask) | (datW & mask);
      }
    }
    mem[idx] = w & 0xffffffff;
  }

  void _onPosedge() {
    if (_bit(_reset)) {
      _busy = false;
      _left = 0;
      _burstActive = false;
      _curAddr = 0;
      _curLeft = 0;
      _scanReady = false;
      ack.put(0);
      scanRqReady.put(0);
      scanRdValid.put(0);
      return;
    }

    // Bus port: pre-edge register snapshot, same as the SV wires.
    final stbV = _bit(_stb);
    final weV = _bit(_we);
    final ackV = _bit(ack.value);
    final busyV = _busy;
    final burstV = _burstActive;
    final ctiV = _toInt(_cti);
    final idx = _toInt(_adr) >> 2;

    final start = stbV && !ackV && !busyV && !burstV;
    final lat = weV ? writeLatency : readLatency;

    bool fire;
    bool nextBurst;
    bool nextBusy;
    int nextLeft;
    if (burstV) {
      fire = false;
      nextBurst = stbV ? ctiV == 0x2 : burstV;
      nextBusy = busyV;
      nextLeft = _left;
    } else {
      fire = start ? lat == 1 : (busyV && stbV && _left == 0);
      nextBurst = fire ? ctiV == 0x2 : burstV;
      if (start && !fire) {
        nextBusy = true;
        nextLeft = lat - 2;
      } else if (busyV) {
        nextBusy = !(fire || !stbV);
        nextLeft = (fire || !stbV) ? _left : _left - 1;
      } else {
        nextBusy = busyV;
        nextLeft = _left;
      }
    }
    final nextAck = burstV ? stbV : fire;
    final doWrite = burstV ? (stbV && weV) : (fire && weV);
    if (doWrite) _writeBytes(idx, _toInt(_datW), _toInt(_sel));
    if (nextAck) {
      acks++;
      if (burstV) backToBackAcks++;
    }

    _busy = nextBusy;
    _left = nextLeft;
    _burstActive = nextBurst;
    ack.put(nextAck ? 1 : 0);
    datR.put(word(idx));

    // Scanout port: same equations as _writeScanPorts. There is no queue:
    // ready reopens one word before the current burst ends (next_left <=
    // 1), so a take then only overwrites addr/left for the next burst,
    // after this cycle has already read the old burst's last word.
    final rqValid = _bit(_scanRqValid);
    final take = rqValid && _scanReady;
    final nextRdValid = _curLeft != 0;
    final w = word(_curAddr >> 1);
    final nextRdData = (_curAddr & 1) != 0 ? (w >> 16) & 0xffff : w & 0xffff;

    final scanNextLeft = take
        ? _toInt(_scanRqWords)
        : (_curLeft != 0 ? _curLeft - 1 : _curLeft);

    // Last write wins, same order as the SV: the left!=0 advance is
    // overridden by a take's new address.
    var newAddr = _curAddr;
    if (_curLeft != 0) newAddr = _curAddr + 1;
    if (take) newAddr = _toInt(_scanRqAddr);

    final nextReady = scanNextLeft <= 1 && !take;

    _curAddr = newAddr;
    _curLeft = scanNextLeft;
    _scanReady = nextReady;
    scanRqReady.put(nextReady ? 1 : 0);
    scanRdValid.put(nextRdValid ? 1 : 0);
    scanRdData.put(nextRdData);
  }
}
