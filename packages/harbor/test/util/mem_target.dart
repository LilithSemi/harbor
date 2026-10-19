import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/memory_waist_beats.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// A memory slave port of [kind] that runs each beat on plain ports `t_*`
/// through [HarborMemoryBeats].
///
/// Outputs: `t_stb`, `t_we`, `t_addr`, `t_wdata`, `t_sel`. Inputs: `t_ack`
/// and `t_rdata`, and `t_err` when [withErr] is set. See [HarborMemoryBeats]
/// for the beat handshake.
class MemBeatTarget extends BridgeModule {
  MemBeatTarget(
    HarborFabricKind kind,
    HarborMemoryWaistConfig config, {
    int burstBeats = 8,
    bool withErr = false,
  }) : super(
         'MemBeatTarget_${kind.name}_a${config.addressWidth}'
         '_d${config.dataWidth}_i${config.idWidth}_n${config.outstanding}'
         '_b$burstBeats${withErr ? '_e' : ''}',
         name: 'mem_target',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemorySlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: config,
      clk: input('clk'),
      reset: input('reset'),
      wishboneBurstBeats: burstBeats,
    );
    final beats = HarborMemoryBeats(
      clk: input('clk'),
      reset: port.reset,
      waist: port.waist,
      ack: addInput('t_ack', Logic()),
      dataOut: addInput(
        't_rdata',
        Logic(width: config.dataWidth),
        width: config.dataWidth,
      ),
      err: withErr ? addInput('t_err', Logic()) : null,
    );
    addOutput('t_stb') <= beats.stb;
    addOutput('t_we') <= beats.we;
    addOutput('t_addr', width: config.addressWidth) <= beats.addr;
    addOutput('t_wdata', width: config.dataWidth) <= beats.dataIn;
    addOutput('t_sel', width: config.strbWidth) <= beats.sel;
  }
}

/// A device under test whose memory master port [iface] drives a
/// [MemBeatTarget] of the same kind.
///
/// Every other interface of [dut] is pulled up with its own name, and every
/// other port with its own name. The target beat ports come up as `t_*`.
/// `clk` and `reset` drive both.
class MasterTop extends BridgeModule {
  late final MemBeatTarget target;

  MasterTop(
    BridgeModule dut, {
    required String iface,
    required HarborFabricKind kind,
    required HarborMemoryWaistConfig config,
    int burstBeats = 8,
    bool withErr = false,
  }) : super('MasterTop_${dut.definitionName}', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addSubModule(dut);
    target = addSubModule(
      MemBeatTarget(kind, config, burstBeats: burstBeats, withErr: withErr),
    );
    for (final m in [dut, target]) {
      m.input('clk').srcConnection! <= input('clk');
      m.input('reset').srcConnection! <= input('reset');
    }
    connectInterfaces(dut.interface(iface), target.interface('bus'));
    final intfNames = dut.interfaces.keys.toList();
    for (final n in intfNames) {
      if (n == iface) continue;
      pullUpInterface(dut.interface(n), newIntfName: n);
    }
    bool inIntf(String p) => intfNames.any((n) => p.startsWith('${n}_'));
    for (final p in [...dut.inputs.keys, ...dut.outputs.keys]) {
      if (p == 'clk' || p == 'reset' || inIntf(p)) continue;
      pullUpPort(dut.port(p), newPortName: p);
    }
    for (final p in [...target.inputs.keys, ...target.outputs.keys]) {
      if (p.startsWith('t_')) pullUpPort(target.port(p), newPortName: p);
    }
  }
}

/// A byte-addressed memory model on the `t_*` beat ports of [top].
///
/// It answers a beat [latency] cycles after `t_stb` rises, at a falling
/// edge, and holds `t_ack` high for one cycle. Words not written read as
/// [fill] of their word index.
class BeatMemory {
  final Module top;
  final Logic clk;
  final int busBytes;
  final int latency;
  final int Function(int wordIndex) fill;
  final Map<int, int> words = {};
  final Logic _ack;
  final Logic _rdata;

  /// Every beat in order as (write, byte address, data, sel).
  final List<(bool, int, int, int)> log = [];

  int _wait = 0;

  BeatMemory(
    this.top,
    this.clk, {
    this.latency = 0,
    int Function(int wordIndex)? fill,
  }) : busBytes = top.output('t_wdata').width ~/ 8,
       fill = fill ?? ((i) => 0),
       _ack = Logic(name: 'tb_t_ack'),
       _rdata = Logic(name: 'tb_t_rdata', width: top.output('t_wdata').width) {
    top.input('t_ack').srcConnection! <= _ack;
    top.input('t_rdata').srcConnection! <= _rdata;
  }

  /// Sets the start value. Call before the simulation runs.
  void start() {
    _ack.inject(0);
    _rdata.inject(0);
    clk.negedge.listen((_) => _step());
  }

  int readWord(int byteAddr) {
    final i = byteAddr ~/ busBytes;
    return words[i] ?? fill(i);
  }

  void writeWord(int byteAddr, int data, [int? sel]) {
    final i = byteAddr ~/ busBytes;
    final all = (1 << busBytes) - 1;
    final s = sel ?? all;
    var v = readWord(byteAddr);
    for (var b = 0; b < busBytes; b++) {
      if ((s >> b) & 1 == 0) continue;
      final m = 0xff << (8 * b);
      v = (v & ~m) | (data & m);
    }
    words[i] = v;
  }

  /// Reads [bytes] bytes at [byteAddr], little endian.
  int readBytes(int byteAddr, int bytes) {
    var v = 0;
    for (var b = 0; b < bytes; b++) {
      final a = byteAddr + b;
      final byte = (readWord(a) >> (8 * (a % busBytes))) & 0xff;
      v |= byte << (8 * b);
    }
    return v;
  }

  /// Writes the low [bytes] bytes of [value] at [byteAddr], little endian.
  void writeBytes(int byteAddr, int value, int bytes) {
    for (var b = 0; b < bytes; b++) {
      final a = byteAddr + b;
      final lane = a % busBytes;
      writeWord(a, ((value >> (8 * b)) & 0xff) << (8 * lane), 1 << lane);
    }
  }

  void _step() {
    if (_ack.value.toBool()) {
      _ack.inject(0);
      return;
    }
    final stb = top.output('t_stb').value;
    if (!stb.isValid || !stb.toBool()) {
      _wait = 0;
      return;
    }
    if (_wait < latency) {
      _wait++;
      return;
    }
    _wait = 0;
    final addr = top.output('t_addr').value.toInt();
    final we = top.output('t_we').value.toBool();
    final sel = top.output('t_sel').value.toInt();
    if (we) {
      final data = top.output('t_wdata').value.toBigInt().toSigned(64).toInt();
      writeWord(addr, data, sel);
      log.add((true, addr, data, sel));
    } else {
      final data = readWord(addr);
      _rdata.inject(data);
      log.add((false, addr, data, sel));
    }
    _ack.inject(1);
  }
}
