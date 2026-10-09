import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// eFuse bank configuration.
class HarborEfuseConfig {
  /// Total number of fuse bits.
  final int totalBits;

  /// Number of bits per word (read granularity).
  final int bitsPerWord;

  /// Number of independently lockable regions.
  final int regions;

  /// Whether ECC is applied to fuse data.
  final bool hasEcc;

  const HarborEfuseConfig({
    this.totalBits = 256,
    this.bitsPerWord = 32,
    this.regions = 4,
    this.hasEcc = false,
  });

  /// Number of words in the fuse bank.
  int get words => totalBits ~/ bitsPerWord;
}

/// Raw eFuse block: direct interface to the OTP fuse array.
///
/// Provides the low-level read/program signals that connect
/// directly to the PDK eFuse cells. No bus interface or
/// register abstraction: that's [HarborEfuseDevice]'s job.
///
/// On ASIC, the fuse cell interface connects to the analog
/// eFuse macros from `PdkProvider.efuse()`.
/// On FPGA, can be backed by ECP5/Xilinx eFuse primitives.
///
/// Signals:
/// - `addr` (out): word address to read/program
/// - `rdata` (in): read data from fuse array
/// - `wdata` (out): data to program
/// - `read` (out): assert to start a read
/// - `program` (out): assert to start a program cycle
/// - `done` (in): operation complete
/// - `lock` (out): per-region lock (write-once, never clears)
class HarborEfuseBlock extends BridgeModule {
  /// Configuration.
  final HarborEfuseConfig config;

  Logic get addr => output('addr');
  Logic get wdata => output('wdata');
  Logic get read_ => output('read');
  Logic get pgm => output('pgm');
  Logic get rdata => input('rdata');
  Logic get done => input('done');
  Logic get lock => output('lock');

  HarborEfuseBlock({required this.config, String? name})
    : super('HarborEfuseBlock', name: name ?? 'efuse_block') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // Fuse array interface
    addOutput('addr', width: config.words.bitLength);
    addOutput('wdata', width: config.bitsPerWord);
    addOutput('read');
    addOutput('pgm');
    createPort('rdata', PortDirection.input, width: config.bitsPerWord);
    createPort('done', PortDirection.input);
    addOutput('lock', width: config.regions);

    // Request interface (from the device/controller)
    createPort('req_read', PortDirection.input);
    createPort('req_program', PortDirection.input);
    createPort('req_addr', PortDirection.input, width: config.words.bitLength);
    createPort('req_wdata', PortDirection.input, width: config.bitsPerWord);
    addOutput('req_rdata', width: config.bitsPerWord);
    addOutput('req_done');
    addOutput('req_error');
    addOutput('busy');

    final clk = input('clk');
    final reset = input('reset');

    final lockBits = Logic(name: 'lock_bits', width: config.regions);
    final busyReg = Logic(name: 'busy_reg');
    final rdataReg = Logic(name: 'rdata_reg', width: config.bitsPerWord);
    final timing = Logic(name: 'timing', width: 16);
    final counter = Logic(name: 'counter', width: 16);

    output('lock') <= lockBits;
    output('busy') <= busyReg;

    Sequential(clk, [
      If(
        reset,
        then: [
          lockBits < Const(0, width: config.regions),
          busyReg < Const(0),
          rdataReg < Const(0, width: config.bitsPerWord),
          timing < Const(100, width: 16),
          counter < Const(0, width: 16),
          output('addr') < Const(0, width: config.words.bitLength),
          output('wdata') < Const(0, width: config.bitsPerWord),
          output('read') < Const(0),
          output('pgm') < Const(0),
          output('req_done') < Const(0),
          output('req_error') < Const(0),
          output('req_rdata') < Const(0, width: config.bitsPerWord),
        ],
        orElse: [
          output('req_done') < Const(0),
          output('req_error') < Const(0),

          If(
            busyReg,
            then: [
              // Wait for fuse array completion
              If(
                input('done'),
                then: [
                  busyReg < Const(0),
                  output('read') < Const(0),
                  output('pgm') < Const(0),
                  output('req_done') < Const(1),
                  rdataReg < input('rdata'),
                  output('req_rdata') < input('rdata'),
                ],
              ),
              counter < counter + 1,
              If(
                counter.gte(timing),
                then: [
                  busyReg < Const(0),
                  output('read') < Const(0),
                  output('pgm') < Const(0),
                  output('req_error') < Const(1),
                ],
              ),
            ],
            orElse: [
              // Accept new requests
              If(
                input('req_read') & ~busyReg,
                then: [
                  busyReg < Const(1),
                  counter < Const(0, width: 16),
                  output('addr') < input('req_addr'),
                  output('read') < Const(1),
                ],
              ),
              If(
                input('req_program') & ~busyReg,
                then: [
                  busyReg < Const(1),
                  counter < Const(0, width: 16),
                  output('addr') < input('req_addr'),
                  output('wdata') < input('req_wdata'),
                  output('pgm') < Const(1),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// eFuse MMIO device: bus-accessible interface to the fuse block.
///
/// Wraps [HarborEfuseBlock] with a register interface for
/// software access. Provides address/data registers, status,
/// region locking, and a programming unlock key.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL       (bit 0: read start, bit 1: program start,
///                      bits 11:8: region select)
/// - 0x08: STATUS     (bit 0: busy, bit 1: done, bit 2: error,
///                      bit 3: unlocked)
/// - 0x10: ADDR       (word address within the fuse bank)
/// - 0x18: RDATA      (read data, valid after read completes)
/// - 0x20: WDATA      (write data, latched on program start)
/// - 0x28: LOCK       (per-region lock bits, write-1-to-lock)
/// - 0x30: TIMING     (program pulse width in clock cycles)
/// - 0x38: KEY        (write 0x4F545021 to unlock programming)
class HarborEfuseDevice extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// eFuse configuration.
  final HarborEfuseConfig config;

  /// The underlying fuse block.
  late final HarborEfuseBlock block;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output (done / error).
  Logic get interrupt => output('interrupt');

  /// Programming unlock key (must be written to KEY register to
  /// enable programming). Changeable per-instance for security.
  final int programUnlockKey;

  HarborEfuseDevice({
    required this.baseAddress,
    this.config = const HarborEfuseConfig(),
    this.programUnlockKey = 0x4F545021, // "OTP!" default
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborEfuseDevice', name: name ?? 'efuse') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('interrupt');

    // Expose fuse cell pins for connection to PDK analog block
    createPort('fuse_rdata', PortDirection.input, width: config.bitsPerWord);
    createPort('fuse_done', PortDirection.input);
    addOutput('fuse_addr', width: config.words.bitLength);
    addOutput('fuse_wdata', width: config.bitsPerWord);
    addOutput('fuse_read');
    addOutput('fuse_pgm');
    addOutput('fuse_lock', width: config.regions);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Internal state
    final addr = Logic(name: 'addr', width: config.words.bitLength);
    final rdata = Logic(name: 'rdata', width: config.bitsPerWord);
    final wdata = Logic(name: 'wdata', width: config.bitsPerWord);
    final lockBits = Logic(name: 'lock_bits', width: config.regions);
    final timing = Logic(name: 'timing', width: 16);
    final unlocked = Logic(name: 'unlocked');
    final busy = Logic(name: 'busy');
    final doneFlag = Logic(name: 'done_flag');
    final errorFlag = Logic(name: 'error_flag');
    final reqRead = Logic(name: 'req_read');
    final reqProgram = Logic(name: 'req_program');
    final pulseCounter = Logic(name: 'pulse_counter', width: 16);

    interrupt <= doneFlag | errorFlag;

    // Forward fuse cell signals
    output('fuse_addr') <= addr;
    output('fuse_wdata') <= wdata;
    output('fuse_lock') <= lockBits;

    Sequential(clk, [
      If(
        reset,
        then: [
          addr < Const(0, width: config.words.bitLength),
          rdata < Const(0, width: config.bitsPerWord),
          wdata < Const(0, width: config.bitsPerWord),
          lockBits < Const(0, width: config.regions),
          timing < Const(100, width: 16),
          unlocked < Const(0),
          busy < Const(0),
          doneFlag < Const(0),
          errorFlag < Const(0),
          reqRead < Const(0),
          reqProgram < Const(0),
          pulseCounter < Const(0, width: 16),
          output('fuse_read') < Const(0),
          output('fuse_pgm') < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          reqRead < Const(0),
          reqProgram < Const(0),

          // Fuse operation FSM
          If(
            busy,
            then: [
              If(
                input('fuse_done'),
                then: [
                  busy < Const(0),
                  doneFlag < Const(1),
                  output('fuse_read') < Const(0),
                  output('fuse_pgm') < Const(0),
                  rdata < input('fuse_rdata'),
                ],
              ),
              pulseCounter < pulseCounter + 1,
              If(
                pulseCounter.gte(timing),
                then: [
                  busy < Const(0),
                  errorFlag < Const(1),
                  output('fuse_read') < Const(0),
                  output('fuse_pgm') < Const(0),
                ],
              ),
            ],
          ),

          // Start operations
          If(
            reqRead & ~busy,
            then: [
              busy < Const(1),
              pulseCounter < Const(0, width: 16),
              output('fuse_read') < Const(1),
            ],
          ),
          If(
            reqProgram & ~busy & unlocked,
            then: [
              busy < Const(1),
              pulseCounter < Const(0, width: 16),
              output('fuse_pgm') < Const(1),
            ],
          ),

          // Bus registers
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Decode every address bit of the 0x1000 window and ignore the
              // bits above it, so absolute and relative addresses both work. An
              // unused offset reads 0 and ignores writes.
              Case(bus.windowAddr(0x1000), [
                // CTRL
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we & bus.selAny(0x00, 1),
                    then: [
                      If(bus.dataIn[0], then: [reqRead < Const(1)]),
                      If(
                        bus.dataIn[1] & unlocked,
                        then: [reqProgram < Const(1)],
                      ),
                    ],
                  ),
                ]),
                // STATUS
                CaseItem(Const(0x08, width: 12), [
                  bus.dataOut <
                      [
                        Const(0, width: 28),
                        unlocked,
                        errorFlag,
                        doneFlag,
                        busy,
                      ].swizzle(),
                  // Clear done/error on read
                  If(
                    ~bus.we,
                    then: [doneFlag < Const(0), errorFlag < Const(0)],
                  ),
                ]),
                // ADDR
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we,
                    then: [addr < bus.selMerge(addr, 0x10)],
                    orElse: [bus.dataOut < addr.zeroExtend(32)],
                  ),
                ]),
                // RDATA
                CaseItem(Const(0x18, width: 12), [
                  bus.dataOut < rdata.zeroExtend(32),
                ]),
                // WDATA
                CaseItem(Const(0x20, width: 12), [
                  If(
                    bus.we,
                    then: [wdata < bus.selMerge(wdata, 0x20)],
                    orElse: [bus.dataOut < wdata.zeroExtend(32)],
                  ),
                ]),
                // LOCK (write-1-to-lock)
                CaseItem(Const(0x28, width: 12), [
                  If(
                    bus.we,
                    then: [
                      lockBits <
                          (lockBits | bus.selMasked(0x28, config.regions)),
                    ],
                    orElse: [bus.dataOut < lockBits.zeroExtend(32)],
                  ),
                ]),
                // TIMING
                CaseItem(Const(0x30, width: 12), [
                  If(
                    bus.we,
                    then: [timing < bus.selMerge(timing, 0x30)],
                    orElse: [bus.dataOut < timing.zeroExtend(32)],
                  ),
                ]),
                // KEY
                CaseItem(Const(0x38, width: 12), [
                  If(
                    bus.we & bus.selAny(0x38, 4),
                    then: [
                      If(
                        bus.dataIn.eq(Const(programUnlockKey, width: 32)),
                        then: [unlocked < Const(1)],
                        orElse: [unlocked < Const(0)],
                      ),
                    ],
                  ),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,efuse', 'harbor,otp'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'harbor,total-bits': config.totalBits,
      'harbor,bits-per-word': config.bitsPerWord,
      'harbor,regions': config.regions,
      'harbor,unlock-key': programUnlockKey,
      '#address-cells': 1,
      '#size-cells': 1,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,efuse', 'harbor,otp'],
      'harbor,total-bits': config.totalBits,
      'harbor,bits-per-word': config.bitsPerWord,
      'harbor,regions': config.regions,
      'harbor,unlock-key': programUnlockKey,
      '#address-cells': 1,
      '#size-cells': 1,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'EFUSE',
    groupName: 'EFUSE',
    description: 'eFuse OTP MMIO device',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
