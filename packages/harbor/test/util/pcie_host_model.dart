import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

/// TLP kinds the host model can build and parse.
enum PcieTlpKind {
  memRead32(0x00),
  memRead64(0x20),
  memWrite32(0x40),
  memWrite64(0x60),
  cpl(0x0a),
  cplD(0x4a);

  const PcieTlpKind(this.fmtType);

  /// Format and type, bits 31:24 of DW0.
  final int fmtType;

  bool get isRequest => index < 4;
  bool get hasData => (fmtType & 0x40) != 0;
  bool get is4Dw => (fmtType & 0x20) != 0 && isRequest;
  int get headerDwords => is4Dw ? 4 : 3;
}

/// Completion status values.
enum PcieCplStatus {
  success(0),
  unsupported(1),
  retry(2),
  abort(4);

  const PcieCplStatus(this.code);
  final int code;
}

/// One beat on a [HarborPcieStream].
class PcieBeat {
  final BigInt data;
  final int keep;
  final bool last;

  const PcieBeat(this.data, this.keep, {required this.last});
}

int _dwordFromBytes(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// A transaction layer packet in host form.
///
/// Payload [data] holds bytes in memory order. On the wire each payload DW
/// has its first byte in bits 31:24.
class PcieTlp {
  final PcieTlpKind kind;

  /// Requester of a request, or the requester a completion answers.
  final int requesterId;
  final int completerId;
  final int tag;

  /// Byte address of a request.
  final int address;

  /// Length in DWs. A completion without data has length 0.
  final int lengthDw;
  final int firstBe;
  final int lastBe;
  final Uint8List data;
  final bool poisoned;
  final PcieCplStatus status;
  final int byteCount;
  final int lowerAddress;

  PcieTlp({
    required this.kind,
    this.requesterId = 0,
    this.completerId = 0,
    this.tag = 0,
    this.address = 0,
    this.lengthDw = 0,
    this.firstBe = 0xf,
    this.lastBe = 0,
    Uint8List? data,
    this.poisoned = false,
    this.status = PcieCplStatus.success,
    this.byteCount = 0,
    this.lowerAddress = 0,
  }) : data = data ?? Uint8List(0) {
    if (kind.hasData && this.data.length != lengthDw * 4) {
      throw ArgumentError('data does not match lengthDw $lengthDw');
    }
    if (!kind.hasData && this.data.isNotEmpty) {
      throw ArgumentError('$kind has no payload');
    }
    if (kind.isRequest) {
      if (lengthDw < 1 || lengthDw > 1024) {
        throw RangeError.range(lengthDw, 1, 1024, 'lengthDw');
      }
      if (!kind.is4Dw && address > 0xffffffff) {
        throw ArgumentError('address needs a 4DW header');
      }
    }
  }

  /// A memory write. A 64 bit kind is used above 4 GB or when [wide] is set.
  factory PcieTlp.memWrite({
    required int address,
    required List<int> data,
    int requesterId = 0,
    int tag = 0,
    int firstBe = 0xf,
    int? lastBe,
    bool poisoned = false,
    bool wide = false,
  }) {
    final dwords = data.length ~/ 4;
    return PcieTlp(
      kind: wide || address > 0xffffffff
          ? PcieTlpKind.memWrite64
          : PcieTlpKind.memWrite32,
      requesterId: requesterId,
      tag: tag,
      address: address,
      lengthDw: dwords,
      firstBe: firstBe,
      lastBe: lastBe ?? (dwords > 1 ? 0xf : 0),
      data: Uint8List.fromList(data),
      poisoned: poisoned,
    );
  }

  /// A memory read. A 64 bit kind is used above 4 GB or when [wide] is set.
  factory PcieTlp.memRead({
    required int address,
    required int lengthDw,
    int requesterId = 0,
    int tag = 0,
    int firstBe = 0xf,
    int? lastBe,
    bool wide = false,
  }) => PcieTlp(
    kind: wide || address > 0xffffffff
        ? PcieTlpKind.memRead64
        : PcieTlpKind.memRead32,
    requesterId: requesterId,
    tag: tag,
    address: address,
    lengthDw: lengthDw,
    firstBe: firstBe,
    lastBe: lastBe ?? (lengthDw > 1 ? 0xf : 0),
  );

  /// A completion. It carries data when [data] is not empty.
  factory PcieTlp.completion({
    required int completerId,
    required int requesterId,
    required int tag,
    PcieCplStatus status = PcieCplStatus.success,
    int byteCount = 0,
    int lowerAddress = 0,
    List<int> data = const [],
    bool poisoned = false,
  }) => PcieTlp(
    kind: data.isEmpty ? PcieTlpKind.cpl : PcieTlpKind.cplD,
    completerId: completerId,
    requesterId: requesterId,
    tag: tag,
    lengthDw: data.length ~/ 4,
    data: Uint8List.fromList(data),
    poisoned: poisoned,
    status: status,
    byteCount: byteCount,
    lowerAddress: lowerAddress,
  );

  /// Parses a TLP from wire DWs, header first.
  factory PcieTlp.fromDwords(List<int> dwords) {
    final dw0 = dwords[0];
    final kind = PcieTlpKind.values.firstWhere(
      (k) => k.fmtType == dw0 >> 24,
      orElse: () => throw FormatException('unknown fmt/type in $dw0'),
    );
    final headerDwords = kind.headerDwords;
    if (dwords.length < headerDwords) {
      throw const FormatException('short header');
    }
    final rawLength = dw0 & 0x3ff;
    final length = rawLength == 0 ? 1024 : rawLength;
    final poisoned = ((dw0 >> 14) & 1) == 1;
    final lengthDw = kind.hasData ? length : (kind.isRequest ? length : 0);
    final payloadEnd = headerDwords + (kind.hasData ? lengthDw : 0);
    if (dwords.length != payloadEnd) {
      throw FormatException('expected $payloadEnd DWs, got ${dwords.length}');
    }
    final bytes = Uint8List(kind.hasData ? lengthDw * 4 : 0);
    for (var i = 0; i < lengthDw && kind.hasData; i++) {
      final dw = dwords[headerDwords + i];
      for (var b = 0; b < 4; b++) {
        bytes[i * 4 + b] = (dw >> (24 - 8 * b)) & 0xff;
      }
    }
    final dw1 = dwords[1];
    final dw2 = dwords[2];
    if (kind.isRequest) {
      final address = kind.is4Dw
          ? (dw2 << 32) | (dwords[3] & 0xfffffffc)
          : dw2 & 0xfffffffc;
      return PcieTlp(
        kind: kind,
        requesterId: dw1 >> 16,
        tag: (dw1 >> 8) & 0xff,
        lastBe: (dw1 >> 4) & 0xf,
        firstBe: dw1 & 0xf,
        address: address,
        lengthDw: lengthDw,
        data: bytes,
        poisoned: poisoned,
      );
    }
    final code = (dw1 >> 13) & 7;
    return PcieTlp(
      kind: kind,
      completerId: dw1 >> 16,
      status: PcieCplStatus.values.firstWhere(
        (s) => s.code == code,
        orElse: () => throw FormatException('bad completion status $code'),
      ),
      byteCount: dw1 & 0xfff,
      requesterId: dw2 >> 16,
      tag: (dw2 >> 8) & 0xff,
      lowerAddress: dw2 & 0x7f,
      lengthDw: lengthDw,
      data: bytes,
      poisoned: poisoned,
    );
  }

  /// Parses a TLP from the beats of one packet.
  factory PcieTlp.fromBeats(List<PcieBeat> beats) {
    final dwords = <int>[];
    for (final beat in beats) {
      for (var i = 0; i < beat.keep.bitLength; i += 4) {
        if (((beat.keep >> i) & 0xf) != 0xf) {
          throw const FormatException('partial DW in keep');
        }
        dwords.add(((beat.data >> (i * 8)) & BigInt.from(0xffffffff)).toInt());
      }
    }
    return PcieTlp.fromDwords(dwords);
  }

  /// Wire DWs: header DWs, then payload DWs with swapped bytes.
  List<int> wireDwords() {
    final dw0 =
        (kind.fmtType << 24) |
        (poisoned ? 1 << 14 : 0) |
        (kind.hasData || kind.isRequest ? lengthDw & 0x3ff : 0);
    final List<int> header;
    if (kind.isRequest) {
      final dw1 = (requesterId << 16) | (tag << 8) | (lastBe << 4) | firstBe;
      header = kind.is4Dw
          ? [dw0, dw1, address >> 32, address & 0xfffffffc]
          : [dw0, dw1, address & 0xfffffffc];
    } else {
      header = [
        dw0,
        (completerId << 16) | (status.code << 13) | (byteCount & 0xfff),
        (requesterId << 16) | (tag << 8) | (lowerAddress & 0x7f),
      ];
    }
    return [
      ...header,
      for (var i = 0; i < data.length; i += 4) _dwordFromBytes(data, i),
    ];
  }

  /// Splits the packet into beats of [width] bits.
  List<PcieBeat> toBeats(int width) {
    final dwords = wireDwords();
    final perBeat = width ~/ 32;
    return [
      for (var start = 0; start < dwords.length; start += perBeat)
        () {
          var value = BigInt.zero;
          var keep = 0;
          final end = min(start + perBeat, dwords.length);
          for (var i = start; i < end; i++) {
            value |= BigInt.from(dwords[i]) << (32 * (i - start));
            keep |= 0xf << (4 * (i - start));
          }
          return PcieBeat(value, keep, last: end == dwords.length);
        }(),
    ];
  }

  @override
  String toString() =>
      'PcieTlp(${kind.name} addr=0x${address.toRadixString(16)} '
      'len=$lengthDw tag=$tag)';
}

/// Sparse byte memory of the host. Unwritten bytes read as zero.
class PcieHostMemory {
  final Map<int, int> _bytes = {};

  Uint8List read(int address, int length) => Uint8List.fromList([
    for (var i = 0; i < length; i++) _bytes[address + i] ?? 0,
  ]);

  void write(int address, List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      _bytes[address + i] = bytes[i];
    }
  }

  /// Applies a memory write TLP and honors the byte enables.
  void applyWrite(PcieTlp tlp) {
    for (var dw = 0; dw < tlp.lengthDw; dw++) {
      final enable = dw == 0
          ? tlp.firstBe
          : (dw == tlp.lengthDw - 1 ? tlp.lastBe : 0xf);
      for (var b = 0; b < 4; b++) {
        if (((enable >> b) & 1) == 1) {
          _bytes[tlp.address + dw * 4 + b] = tlp.data[dw * 4 + b];
        }
      }
    }
  }
}

/// Answers memory reads with completions in random order.
///
/// Each read is split at read completion boundary multiples and at the
/// maximum payload size. The completions of one read stay in address order.
/// Completions of different reads interleave in an order from the seed.
class PcieReadResponder {
  final PcieHostMemory memory;
  final Random _random;
  final int completerId;

  /// Read completion boundary in bytes, 64 or 128.
  int rcb;

  /// Maximum payload size in bytes.
  int maxPayload;

  /// Picks a status for a request. Return null for a normal answer.
  PcieCplStatus? Function(PcieTlp request)? statusFor;

  final List<List<PcieTlp>> _pending = [];

  PcieReadResponder({
    required this.memory,
    required int seed,
    this.completerId = 0,
    this.rcb = 64,
    this.maxPayload = 128,
    this.statusFor,
  }) : _random = Random(seed);

  bool get hasPending => _pending.isNotEmpty;

  /// Queues the completions for [request].
  void accept(PcieTlp request) {
    final failure = statusFor?.call(request);
    final firstEnabled = request.firstBe == 0
        ? 0
        : (request.firstBe & -request.firstBe).bitLength - 1;
    final tailBe = request.lengthDw == 1 ? request.firstBe : request.lastBe;
    final tailTrim = tailBe == 0 ? 0 : 4 - tailBe.bitLength;
    final begin = request.address + firstEnabled;
    final end = max(
      begin + 1,
      request.address + request.lengthDw * 4 - tailTrim,
    );

    PcieTlp completion(int start, int stop, {List<int> data = const []}) =>
        PcieTlp.completion(
          completerId: completerId,
          requesterId: request.requesterId,
          tag: request.tag,
          status: failure ?? PcieCplStatus.success,
          byteCount: end - start,
          lowerAddress: start & 0x7f,
          data: data,
        );

    if (failure != null) {
      _pending.add([completion(begin, end)]);
      return;
    }
    final chunks = <PcieTlp>[];
    for (var start = begin; start < end;) {
      final dwStart = start & ~3;
      final boundary = (start ~/ rcb + 1) * rcb;
      final stop = min(min(end, boundary), dwStart + maxPayload);
      final dwStop = (stop + 3) & ~3;
      chunks.add(
        completion(start, stop, data: memory.read(dwStart, dwStop - dwStart)),
      );
      start = stop;
    }
    _pending.add(chunks);
  }

  /// Takes the next completion, or null when none is queued.
  PcieTlp? next() {
    if (_pending.isEmpty) return null;
    final index = _random.nextInt(_pending.length);
    final chunks = _pending[index];
    final tlp = chunks.removeAt(0);
    if (chunks.isEmpty) _pending.removeAt(index);
    return tlp;
  }
}

/// The host side of a PCIe link: memory, read answers, MSI capture and the
/// values the endpoint configuration would hold.
class PcieHostModel {
  final PcieHostMemory memory;
  final PcieReadResponder responder;

  /// Maximum read request size in bytes.
  int maxReadRequest;

  /// Value of the bus master enable bit.
  bool busMasterEnable;

  /// Vectors of received MSIs, in order.
  final List<int> msis = [];

  /// Rule breaks seen in received TLPs.
  final List<String> violations = [];

  /// Completions received from the endpoint.
  final List<PcieTlp> completions = [];

  PcieHostModel({
    int seed = 1,
    int rcb = 64,
    int maxPayload = 128,
    int maxReadRequest = 512,
    bool busMasterEnable = true,
    int completerId = 0,
  }) : this._(
         PcieHostMemory(),
         seed,
         rcb,
         maxPayload,
         maxReadRequest,
         busMasterEnable,
         completerId,
       );

  PcieHostModel._(
    this.memory,
    int seed,
    int rcb,
    int maxPayload,
    this.maxReadRequest,
    this.busMasterEnable,
    int completerId,
  ) : responder = PcieReadResponder(
        memory: memory,
        seed: seed,
        completerId: completerId,
        rcb: rcb,
        maxPayload: maxPayload,
      );

  /// Records an MSI with [vector].
  void recordMsi(int vector) => msis.add(vector);

  /// Handles a TLP sent by the endpoint. Writes go to memory, reads are
  /// queued in the responder and completions are kept in [completions].
  void receive(PcieTlp tlp) {
    if (tlp.kind.isRequest) {
      if (!busMasterEnable) violations.add('$tlp sent without bus master');
      final crosses = (tlp.address & 0xfff) + tlp.lengthDw * 4 > 0x1000;
      if (crosses) violations.add('$tlp crosses a 4 KB boundary');
    }
    switch (tlp.kind) {
      case PcieTlpKind.memWrite32 || PcieTlpKind.memWrite64:
        if (tlp.lengthDw * 4 > responder.maxPayload) {
          violations.add('$tlp is larger than the maximum payload');
        }
        memory.applyWrite(tlp);
      case PcieTlpKind.memRead32 || PcieTlpKind.memRead64:
        if (tlp.lengthDw * 4 > maxReadRequest) {
          violations.add('$tlp is larger than the maximum read request');
        }
        responder.accept(tlp);
      case PcieTlpKind.cpl || PcieTlpKind.cplD:
        completions.add(tlp);
    }
  }
}

/// Pushes TLPs onto a [HarborPcieStream] with random gaps in `valid`.
///
/// Inputs change just after the rising edge. Ready is sampled at the falling
/// edge, so a beat moves when both signals are high at that time.
class PcieStreamDriver {
  final Logic clk;
  final HarborPcieStream stream;
  final Random _random;

  /// Chance of an idle cycle before each beat.
  final double gapChance;

  PcieStreamDriver({
    required this.clk,
    required this.stream,
    required int seed,
    this.gapChance = 0.3,
  }) : _random = Random(seed) {
    stream.valid.inject(0);
    stream.last.inject(0);
    stream.data.inject(0);
    stream.keep.inject(0);
    stream.user.inject(0);
  }

  /// Sends [tlp]. Call it just after a rising edge.
  Future<void> send(PcieTlp tlp, {int user = HarborPcieStream.userBar0}) async {
    for (final beat in tlp.toBeats(stream.width)) {
      while (_random.nextDouble() < gapChance) {
        stream.valid.inject(0);
        await clk.nextPosedge;
      }
      stream.data.inject(beat.data);
      stream.keep.inject(beat.keep);
      stream.last.inject(beat.last ? 1 : 0);
      stream.user.inject(user);
      stream.valid.inject(1);
      var moved = false;
      while (!moved) {
        await clk.nextNegedge;
        moved = stream.ready.value.toBool();
        await clk.nextPosedge;
      }
    }
    stream.valid.inject(0);
    stream.last.inject(0);
  }
}

/// Pulls TLPs from a [HarborPcieStream] with random gaps in `ready`.
class PcieStreamSink {
  final Logic clk;
  final HarborPcieStream stream;
  final Random _random;

  /// Chance that ready is high in a cycle.
  final double readyChance;

  /// Called for each complete TLP.
  void Function(PcieTlp tlp)? onTlp;

  /// Complete TLPs in arrival order.
  final List<PcieTlp> received = [];

  /// The `user` value of the first beat of each received TLP.
  final List<int> receivedUsers = [];

  final List<PcieBeat> _beats = [];
  int _firstUser = 0;
  bool _running = false;

  PcieStreamSink({
    required this.clk,
    required this.stream,
    required int seed,
    this.readyChance = 0.6,
    this.onTlp,
  }) : _random = Random(seed) {
    stream.ready.inject(0);
  }

  /// Starts pulling. Call it just after a rising edge.
  void start() {
    _running = true;
    unawaited(_run());
  }

  void stop() => _running = false;

  /// Waits until [count] TLPs have arrived.
  Future<void> waitFor(int count, {int timeoutCycles = 200000}) async {
    for (var i = 0; received.length < count; i++) {
      if (i >= timeoutCycles) {
        throw TimeoutException('only ${received.length} of $count TLPs');
      }
      await clk.nextPosedge;
    }
  }

  Future<void> _run() async {
    while (_running) {
      final ready = _random.nextDouble() < readyChance;
      stream.ready.inject(ready ? 1 : 0);
      await clk.nextNegedge;
      if (ready && stream.valid.value.toBool()) {
        if (_beats.isEmpty) _firstUser = stream.user.value.toInt();
        _beats.add(
          PcieBeat(
            stream.data.value.toBigInt(),
            stream.keep.value.toInt(),
            last: stream.last.value.toBool(),
          ),
        );
        if (_beats.last.last) {
          final tlp = PcieTlp.fromBeats(_beats);
          _beats.clear();
          received.add(tlp);
          receivedUsers.add(_firstUser);
          onTlp?.call(tlp);
        }
      }
      await clk.nextPosedge;
    }
    stream.ready.inject(0);
  }
}
