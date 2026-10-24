import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Drives the register slave port of a device under test for any fabric
/// kind: Wishbone classic, AXI4-Lite or TileLink-UL.
///
/// Call [RegBus.attach] before the device is built. It connects a driver
/// signal to every input of the port. Call [idle] before the simulation
/// starts. Each access samples the port at the falling edge and changes the
/// inputs just after the rising edge.
class RegBus {
  final BridgeModule dut;
  final Logic clk;
  final String name;
  final HarborFabricKind kind;
  final Map<String, Logic> _in = {};

  /// Cycles an access may wait before it fails the test.
  int timeout = 10000;

  RegBus._(this.dut, this.clk, this.name, this.kind);

  /// Connects a driver to the port [name] of [dut]. The kind comes from the
  /// interface class of the port, or from [kind] when the ports are plain
  /// `<name>_<PORT>` ports with no interface.
  factory RegBus.attach(
    BridgeModule dut,
    Logic clk, {
    String name = 'bus',
    HarborFabricKind? kind,
  }) {
    kind ??= switch (dut.interface(name).interface) {
      WishboneInterface() => HarborFabricKind.wishbone,
      Axi4LiteInterface() => HarborFabricKind.axi4,
      TileLinkInterface() => HarborFabricKind.tilelink,
      final intf => throw ArgumentError('$name is not a register port: $intf'),
    };
    final bus = RegBus._(dut, clk, name, kind);
    final prefix = '${name}_';
    for (final e in dut.inputs.entries) {
      if (!e.key.startsWith(prefix)) continue;
      final l = Logic(name: 'drv_${e.key}', width: e.value.width);
      dut.input(e.key).srcConnection! <= l;
      bus._in[e.key.substring(prefix.length)] = l;
    }
    return bus;
  }

  int get dataWidth => _out(_dataOutPort).width;

  int get _allSel => (1 << (dataWidth ~/ 8)) - 1;

  String get _dataOutPort => switch (kind) {
    HarborFabricKind.wishbone => 'DAT_MISO',
    HarborFabricKind.axi4 => 'RDATA',
    HarborFabricKind.tilelink => 'D_DATA',
  };

  Logic _out(String port) => dut.output('${name}_$port');

  bool _high(String port) {
    final v = _out(port).value;
    return v.isValid && v.toInt() == 1;
  }

  // Read data, or -1 when a bit is X, such as a word never written.
  BigInt _data(String port) {
    final v = _out(port).value;
    return v.isValid ? v.toBigInt() : BigInt.from(-1);
  }

  void _set(String port, Object v) => _in[port]?.inject(v);

  /// Puts every input in its idle state.
  void idle() {
    for (final l in _in.values) {
      l.inject(0);
    }
    if (kind == HarborFabricKind.wishbone) _set('SEL', _allSel);
    _set('BREADY', 1);
    _set('RREADY', 1);
    _set('D_READY', 1);
  }

  /// Writes [data] to [addr] with byte selects [sel] (all bytes when null).
  Future<void> write(int addr, int data, {int? sel}) async {
    await access(addr, data: data, sel: sel ?? _allSel, write: true);
  }

  /// Reads the word at [addr]. With [sel], the read selects only those
  /// byte lanes: Wishbone SEL, the TileLink mask and size, and on AXI4-Lite
  /// the address of the lowest lane (a 32-bit read).
  Future<int> read(int addr, {int? sel}) async =>
      (await access(addr, sel: sel ?? _allSel, write: false)).data;

  // The byte address of the lowest lane in [sel] within the word at [addr].
  int _laneAddr(int addr, int sel) {
    final bytes = dataWidth ~/ 8;
    var lane = 0;
    while (lane < bytes && (sel >> lane) & 1 == 0) {
      lane++;
    }
    return (addr & ~(bytes - 1)) + (lane == bytes ? 0 : lane);
  }

  /// Runs one access and returns its read data and error flag.
  Future<({int data, bool err})> access(
    int addr, {
    int data = 0,
    int? sel,
    required bool write,
  }) async {
    final r = await accessWide(
      addr,
      data: BigInt.from(data),
      sel: sel,
      write: write,
    );
    return (data: r.data.toInt(), err: r.err);
  }

  /// Like [access], with data of any width.
  Future<({BigInt data, bool err})> accessWide(
    int addr, {
    BigInt? data,
    int? sel,
    required bool write,
  }) {
    final d = data ?? BigInt.zero;
    final s = sel ?? _allSel;
    return switch (kind) {
      HarborFabricKind.wishbone => _wishbone(addr, d, s, write),
      HarborFabricKind.axi4 => _axi4(addr, d, s, write),
      HarborFabricKind.tilelink => _tileLink(addr, d, s, write),
    };
  }

  Future<void> _wait(bool Function() done) async {
    for (var i = 0; i < timeout; i++) {
      await clk.nextNegedge;
      if (done()) return;
      await clk.nextPosedge;
    }
    throw StateError('$name: no response in $timeout cycles');
  }

  Future<({BigInt data, bool err})> _wishbone(
    int addr,
    BigInt data,
    int sel,
    bool write,
  ) async {
    _set('ADR', addr);
    _set('DAT_MOSI', data);
    _set('SEL', sel);
    _set('WE', write ? 1 : 0);
    _set('CYC', 1);
    _set('STB', 1);
    final hasErr = dut.outputs.containsKey('${name}_ERR');
    var err = false;
    await _wait(() {
      err = hasErr && _high('ERR');
      return _high('ACK') || err;
    });
    final rdata = _data('DAT_MISO');
    await clk.nextPosedge;
    _set('CYC', 0);
    _set('STB', 0);
    _set('WE', 0);
    return (data: rdata, err: err);
  }

  Future<({BigInt data, bool err})> _axi4(
    int addr,
    BigInt data,
    int sel,
    bool write,
  ) async {
    if (write) {
      _set('AWADDR', addr);
      _set('WDATA', data);
      _set('WSTRB', sel);
      _set('AWVALID', 1);
      _set('WVALID', 1);
      var aw = true;
      var w = true;
      var done = false;
      var err = false;
      for (var i = 0; i < timeout && !done; i++) {
        await clk.nextNegedge;
        final awFire = aw && _high('AWREADY');
        final wFire = w && _high('WREADY');
        if (_high('BVALID')) {
          done = true;
          err = _out('BRESP').value.toInt() != 0;
        }
        await clk.nextPosedge;
        if (awFire) {
          aw = false;
          _set('AWVALID', 0);
        }
        if (wFire) {
          w = false;
          _set('WVALID', 0);
        }
      }
      if (!done) throw StateError('$name: no B in $timeout cycles');
      return (data: BigInt.zero, err: err);
    }
    _set('ARADDR', sel == _allSel ? addr : _laneAddr(addr, sel));
    _set('ARVALID', 1);
    var ar = true;
    for (var i = 0; i < timeout; i++) {
      await clk.nextNegedge;
      final arFire = ar && _high('ARREADY');
      if (_high('RVALID')) {
        final rdata = _data('RDATA');
        final err = _out('RRESP').value.toInt() != 0;
        await clk.nextPosedge;
        return (data: rdata, err: err);
      }
      await clk.nextPosedge;
      if (arFire) {
        ar = false;
        _set('ARVALID', 0);
      }
    }
    throw StateError('$name: no R in $timeout cycles');
  }

  Future<({BigInt data, bool err})> _tileLink(
    int addr,
    BigInt data,
    int sel,
    bool write,
  ) async {
    final bytes = dataWidth ~/ 8;
    // PutFullData with every byte, PutPartialData otherwise, Get to read.
    final op = !write ? 4 : (sel == _allSel ? 0 : 1);
    _set('A_OPCODE', op);
    _set('A_PARAM', 0);
    final narrow = !write && sel != _allSel;
    final lanes = narrow ? sel.toRadixString(2).replaceAll('0', '').length : 0;
    _set('A_SIZE', narrow ? (lanes - 1).bitLength : (bytes - 1).bitLength);
    _set('A_SOURCE', 0);
    _set('A_ADDRESS', narrow ? _laneAddr(addr, sel) : addr);
    _set('A_MASK', sel);
    _set('A_DATA', data);
    _set('A_CORRUPT', 0);
    _set('A_VALID', 1);
    var a = true;
    for (var i = 0; i < timeout; i++) {
      await clk.nextNegedge;
      final aFire = a && _high('A_READY');
      if (_high('D_VALID')) {
        final rdata = _data('D_DATA');
        final err = _high('D_DENIED') || _high('D_CORRUPT');
        await clk.nextPosedge;
        // A response means the request was taken, even when the port took
        // it at an edge this loop did not see.
        _set('A_VALID', 0);
        return (data: rdata, err: err);
      }
      await clk.nextPosedge;
      if (aFire) {
        a = false;
        _set('A_VALID', 0);
      }
    }
    throw StateError('$name: no D in $timeout cycles');
  }
}
