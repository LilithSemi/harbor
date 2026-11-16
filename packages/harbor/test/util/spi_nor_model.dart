import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

/// A SPI NOR model: 0x03 read, 0x06 WREN, 0x05 RDSR, 0x20 sector erase and
/// 0x02 page program with a 3-byte address. WIP stays set for [wipPolls]
/// status reads after each erase or program. Every erase and program goes in
/// [log] as (opcode, address) when its frame ends.
///
/// The model also has a quad enable bit in the place that [quadEnable] says.
/// Fast read 0x0B and 0x0C send the data on IO1 after 8 dummy cycles. Quad
/// output read 0x6B and 0x6C send it on IO3 to IO0 after 8 dummy cycles when
/// the QE bit is set, and send zeros when it is clear. A write of the QE
/// register needs WREN and goes in [qeLog] as (opcode, data bytes) when its
/// frame ends.
class SpiNorModel {
  SpiNorModel({
    this.wipPolls = 3,
    this.stuckWip = false,
    this.quadEnable = HarborSpiFlashQuadEnable.none,
    this.qe = false,
    this.refuseQeWrite = false,
    this.sr1Bits = 0,
    this.reg2Bits = 0,
    int? jedecId,
    this.unstableReads = false,
    this.busyUntilClsr = false,
  }) : jedecId = jedecId ?? _defaultId(quadEnable);

  static int _defaultId(HarborSpiFlashQuadEnable q) => switch (q) {
    HarborSpiFlashQuadEnable.none => 0x20ba18,
    HarborSpiFlashQuadEnable.sr1Bit6 => 0x9d6018,
    HarborSpiFlashQuadEnable.sr2Bit1 => 0xef4018,
    HarborSpiFlashQuadEnable.cr1Bit1 => 0x012018,
  };

  /// The 3 byte JEDEC ID that command 0x9F returns.
  final int jedecId;

  /// Every status register read flips bit 2 against the read before it.
  final bool unstableReads;

  /// A refused QE write leaves WIP and P_ERR set until CLSR 0x30, and reads
  /// return nothing while it does, as an S25FL part does.
  final bool busyUntilClsr;
  bool _stuck = false;
  int _flip = 0;

  /// The bits of status register 1 other than WIP, WEL and QE.
  final int sr1Bits;

  /// The bits of the second register (SR2 or CR1) other than QE.
  final int reg2Bits;

  /// Where the QE bit is.
  final HarborSpiFlashQuadEnable quadEnable;

  /// The QE bit.
  bool qe;

  /// A write of the QE register is accepted and has no effect.
  final bool refuseQeWrite;

  /// The QE register writes as (opcode, data bytes).
  final qeLog = <(int, List<int>)>[];

  /// Every command opcode that started a frame, in order.
  final opcodes = <int>[];

  final int wipPolls;

  /// WIP never clears, as on a dead part.
  final bool stuckWip;
  final storage = <int, int>{};
  final log = <(int, int)>[];
  bool wel = false;
  int wipCounter = 0;

  int _curByte = 0;
  int _bitsInByte = 0;
  final _cmdBytes = <int>[];
  int _cmd = 0;
  int _addr = 0;
  bool _servingStatus = false;
  int _statusByte = 0;
  int _eraseAddr = 0;
  final _programAddrs = <int>[];

  int read(int a) => storage[a] ?? 0xFF;

  void _begin() {
    _curByte = 0;
    _bitsInByte = 0;
    _cmdBytes.clear();
    _cmd = 0;
    _addr = 0;
    _servingStatus = false;
    _statusByte = 0;
  }

  void csFall() => _begin();

  void csRise() {
    if ((_cmd == 0x01 || _cmd == 0x31) && wel && _cmdBytes.length > 1) {
      final data = _cmdBytes.sublist(1);
      qeLog.add((_cmd, data));
      if (!refuseQeWrite) _applyQeWrite(data);
      if (refuseQeWrite && busyUntilClsr) {
        _stuck = true;
      } else {
        wipCounter = wipPolls;
      }
    }
    if (_cmd == 0x01 || _cmd == 0x31) wel = false;
    if (_cmd == 0x20) log.add((0x20, _eraseAddr));
    if (_cmd == 0x02 && _programAddrs.isNotEmpty) {
      log.add((0x02, _programAddrs.first));
    }
    _programAddrs.clear();
    if (_cmd == 0x20 || _cmd == 0x02) wel = false;
    _begin();
  }

  void _applyQeWrite(List<int> data) {
    switch (quadEnable) {
      case HarborSpiFlashQuadEnable.none:
        break;
      case HarborSpiFlashQuadEnable.sr1Bit6:
        if (_cmd == 0x01) qe = (data[0] >> 6) & 1 == 1;
      case HarborSpiFlashQuadEnable.sr2Bit1:
        if (_cmd == 0x31) qe = (data[0] >> 1) & 1 == 1;
      case HarborSpiFlashQuadEnable.cr1Bit1:
        if (_cmd == 0x01 && data.length == 2) qe = (data[1] >> 1) & 1 == 1;
    }
  }

  int get _sr1 {
    final wip = (wipCounter > 0 || stuckWip || _stuck) ? 1 : 0;
    final qeBit = quadEnable == HarborSpiFlashQuadEnable.sr1Bit6 && qe;
    return sr1Bits |
        wip |
        (wel ? 2 : 0) |
        (qeBit ? 0x40 : 0) |
        (_stuck ? 0x40 : 0);
  }

  int get _flipBits {
    if (!unstableReads) return 0;
    _flip ^= 1;
    return _flip * 4;
  }

  int get _sr2 {
    final inSr2 =
        quadEnable == HarborSpiFlashQuadEnable.sr2Bit1 ||
        quadEnable == HarborSpiFlashQuadEnable.cr1Bit1;
    return inSr2 ? reg2Bits | (qe ? 2 : 0) : 0;
  }

  int get _addrLen => (_cmd == 0x0C || _cmd == 0x6C) ? 4 : 3;

  /// The value of IO3 to IO0 to present at the rising edge number [idx] of a
  /// frame. A single line read and the status use IO1.
  int ioAt(int idx) {
    if (_servingStatus) {
      final d = idx - 8;
      if (d >= 0 && d < 8) return ((_statusByte >> (7 - d)) & 1) << 1;
    }
    if (_cmd == 0x9F && _cmdBytes.isNotEmpty) {
      final n = idx - 8;
      if (n >= 0 && n < 24) {
        final b = (jedecId >> (16 - 8 * (n ~/ 8))) & 0xff;
        return ((b >> (7 - n % 8)) & 1) << 1;
      }
    }
    if (_stuck) return 0;
    final single = _cmd == 0x03 || _cmd == 0x0B || _cmd == 0x0C;
    final quad = _cmd == 0x6B || _cmd == 0x6C;
    if ((single || quad) && _cmdBytes.length >= 1 + _addrLen) {
      final dummy = _cmd == 0x03 ? 0 : 8;
      final n = idx - 8 - 8 * _addrLen - dummy;
      if (n < 0) return 0;
      if (single) {
        return ((read(_addr + (n ~/ 8)) >> (7 - n % 8)) & 1) << 1;
      }
      if (!qe && quadEnable != HarborSpiFlashQuadEnable.none) return 0;
      final b = read(_addr + (n ~/ 2));
      return n.isEven ? (b >> 4) & 0xf : b & 0xf;
    }
    return 0;
  }

  /// The MISO bit to present at the rising edge number [idx] of a frame.
  int misoBitAt(int idx) => (ioAt(idx) >> 1) & 1;

  void clkRise(int mosi) {
    if (_servingStatus) return;
    _curByte = ((_curByte << 1) | (mosi & 1)) & 0xFF;
    _bitsInByte++;
    if (_bitsInByte == 8) {
      _byteComplete(_curByte);
      _curByte = 0;
      _bitsInByte = 0;
    }
  }

  void _byteComplete(int b) {
    _cmdBytes.add(b);
    if (_cmdBytes.length == 1) {
      _cmd = b;
      opcodes.add(b);
      if (_cmd == 0x06) {
        wel = true;
      } else if (_cmd == 0x04) {
        wel = false;
      } else if (_cmd == 0x30) {
        _stuck = false;
        wipCounter = 0;
      } else if (_cmd == 0x05) {
        _statusByte = _sr1 ^ _flipBits;
        if (wipCounter > 0) wipCounter--;
        _servingStatus = true;
      } else if (_cmd == 0x35) {
        _statusByte = _sr2 ^ _flipBits;
        _servingStatus = true;
      }
      return;
    }
    const addressed = [0x20, 0x02, 0x03, 0x0B, 0x0C, 0x6B, 0x6C];
    if (!addressed.contains(_cmd)) return;
    if (_cmdBytes.length <= 1 + _addrLen) {
      _addr = (_addr << 8) | b;
      if (_cmd == 0x20 && _cmdBytes.length == 4 && wel) {
        final base = _addr & ~0xFFF;
        _eraseAddr = _addr;
        for (var i = 0; i < 4096; i++) {
          storage[base + i] = 0xFF;
        }
        wipCounter = wipPolls;
      }
      return;
    }
    if (_cmd == 0x02 && wel) {
      final a = _addr + _cmdBytes.length - 5;
      if (_programAddrs.isEmpty) _programAddrs.add(_addr);
      storage[a] = (storage[a] ?? 0xFF) & b;
      wipCounter = wipPolls;
    }
  }

  /// Drives IO3 to IO0 from the split quad pins until stop is called. The
  /// model reads DQ0 from [ioOut] and drives [ioIn].
  SpiNorQuadPins attachQuad({
    required Logic clk,
    required Logic csN,
    required Logic spiClk,
    required Logic ioOut,
    required Logic ioOe,
    required Logic ioIn,
  }) => SpiNorQuadPins._(this, clk, csN, spiClk, ioOut, ioOe, ioIn);

  /// Drives MISO from the SPI pins until stop is called.
  SpiNorPins attach({
    required Logic clk,
    required Logic csN,
    required Logic spiClk,
    required Logic mosi,
    required Logic miso,
  }) => SpiNorPins._(this, clk, csN, spiClk, mosi, miso);
}

/// The pin side of a [SpiNorModel].
class SpiNorPins {
  SpiNorPins._(
    this.model,
    this.clk,
    this.csN,
    this.spiClk,
    this.mosi,
    this.miso,
  ) {
    _proc = _run();
  }

  final SpiNorModel model;
  final Logic clk, csN, spiClk, mosi, miso;
  bool _running = true;
  late final Future<void> _proc;

  Future<void> _run() async {
    var prevClk = 0;
    var prevCs = 1;
    var riseIdx = 0;
    while (_running) {
      await clk.nextPosedge;
      final cs = csN.value.isValid ? csN.value.toInt() : 1;
      final sc = spiClk.value.isValid ? spiClk.value.toInt() : 0;
      final dq0 = mosi.value.isValid ? mosi.value.toInt() : 0;
      if (cs == 0 && prevCs == 1) {
        model.csFall();
        riseIdx = 0;
      }
      if (cs == 1 && prevCs == 0) {
        model.csRise();
        riseIdx = 0;
      }
      if (cs == 0 && sc == 1 && prevClk == 0) {
        miso.inject(model.misoBitAt(riseIdx));
        model.clkRise(dq0);
        miso.inject(model.misoBitAt(riseIdx));
        riseIdx++;
      }
      prevClk = cs == 0 ? sc : 0;
      prevCs = cs;
    }
  }

  Future<void> stop() async {
    _running = false;
    await _proc;
  }
}

/// The pin side of a [SpiNorModel] on split quad pins. [onEdge] runs at every
/// clock edge with the values that the controller drives, to check the pins.
class SpiNorQuadPins {
  SpiNorQuadPins._(
    this.model,
    this.clk,
    this.csN,
    this.spiClk,
    this.ioOut,
    this.ioOe,
    this.ioIn,
  ) {
    _proc = _run();
  }

  final SpiNorModel model;
  final Logic clk, csN, spiClk, ioOut, ioOe, ioIn;

  /// Called every clock with (frame rise index or -1, opcode or -1, io out,
  /// io oe) while the controller is running.
  void Function(int riseIdx, int opcode, int out, int oe)? onEdge;

  bool _running = true;
  late final Future<void> _proc;

  Future<void> _run() async {
    var prevClk = 0;
    var prevCs = 1;
    var riseIdx = 0;
    var opcode = 0;
    while (_running) {
      await clk.nextPosedge;
      final cs = csN.value.isValid ? csN.value.toInt() : 1;
      final sc = spiClk.value.isValid ? spiClk.value.toInt() : 0;
      final out = ioOut.value.isValid ? ioOut.value.toInt() : 0;
      final oe = ioOe.value.isValid ? ioOe.value.toInt() : 0;
      if (cs == 0 && prevCs == 1) {
        model.csFall();
        riseIdx = 0;
        opcode = 0;
      }
      if (cs == 1 && prevCs == 0) {
        model.csRise();
        riseIdx = 0;
      }
      onEdge?.call(cs == 0 ? riseIdx : -1, cs == 0 ? opcode : -1, out, oe);
      if (cs == 0 && sc == 1 && prevClk == 0) {
        ioIn.inject(model.ioAt(riseIdx));
        model.clkRise(out & 1);
        ioIn.inject(model.ioAt(riseIdx));
        if (riseIdx < 8) opcode = (opcode << 1) | (out & 1);
        riseIdx++;
      }
      prevClk = cs == 0 ? sc : 0;
      prevCs = cs;
    }
  }

  Future<void> stop() async {
    _running = false;
    await _proc;
  }
}
