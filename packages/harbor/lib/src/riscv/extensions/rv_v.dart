import '../../encoding/riscv_vector.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

/// V extension: Vector operations.
///
/// Core vector arithmetic and memory operations. The vector unit
/// is parameterized by VLEN (vector register width) at elaboration
/// time. Operations here define encoding and resource usage,
/// the actual vector execution logic is CPU-specific.
///
/// The microcode of each op is a placeholder that only advances the pc.
const rvV = RiscVExtension(
  name: 'V',
  key: 'V',
  misaBit: 21,
  operations: [
    // Vector configuration
    RiscVOperation(
      mnemonic: 'vsetvli',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opcfg,
      format: vsetType,
      matchMask: 0x80000000, // bit 31 = 0
      matchValue: 0x00000000,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vsetivli',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opcfg,
      format: vsetType,
      matchMask: 0xC0000000, // bits 31:30 = 11
      matchValue: 0xC0000000,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vsetvl',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opcfg,
      funct7: 0x40,
      format: vsetType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Integer arithmetic (VV). funct6 is bits 31:26.
    RiscVOperation(
      mnemonic: 'vadd.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: VectorFunct6.vadd << 26,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vsub.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: VectorFunct6.vsub << 26,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vand.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: VectorFunct6.vand << 26,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vor.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: VectorFunct6.vor << 26,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vxor.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: VectorFunct6.vxor << 26,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Integer arithmetic (VX: vector-scalar)
    RiscVOperation(
      mnemonic: 'vadd.vx',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivx,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: VectorFunct6.vadd << 26,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vsub.vx',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivx,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: VectorFunct6.vsub << 26,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Integer arithmetic (VI: vector-immediate)
    RiscVOperation(
      mnemonic: 'vadd.vi',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivi,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: VectorFunct6.vadd << 26,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Vector loads, unit stride: nf, mew, mop and lumop are zero.
    RiscVOperation(
      mnemonic: 'vle8.v',
      opcode: vectorLoadOpcode,
      funct3: 0x0,
      format: vLoadStoreType,
      matchMask: 0xFDF00000,
      matchValue: 0x00000000,
      resources: [VectorResource(), MemoryResource.load()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vle16.v',
      opcode: vectorLoadOpcode,
      funct3: 0x5,
      format: vLoadStoreType,
      matchMask: 0xFDF00000,
      matchValue: 0x00000000,
      resources: [VectorResource(), MemoryResource.load()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vle32.v',
      opcode: vectorLoadOpcode,
      funct3: 0x6,
      format: vLoadStoreType,
      matchMask: 0xFDF00000,
      matchValue: 0x00000000,
      resources: [VectorResource(), MemoryResource.load()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vle64.v',
      opcode: vectorLoadOpcode,
      funct3: 0x7,
      format: vLoadStoreType,
      matchMask: 0xFDF00000,
      matchValue: 0x00000000,
      resources: [VectorResource(), MemoryResource.load()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Vector stores, unit stride: nf, mew, mop and sumop are zero.
    RiscVOperation(
      mnemonic: 'vse8.v',
      opcode: vectorStoreOpcode,
      funct3: 0x0,
      format: vLoadStoreType,
      matchMask: 0xFDF00000,
      matchValue: 0x00000000,
      resources: [VectorResource(), MemoryResource.store()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vse16.v',
      opcode: vectorStoreOpcode,
      funct3: 0x5,
      format: vLoadStoreType,
      matchMask: 0xFDF00000,
      matchValue: 0x00000000,
      resources: [VectorResource(), MemoryResource.store()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vse32.v',
      opcode: vectorStoreOpcode,
      funct3: 0x6,
      format: vLoadStoreType,
      matchMask: 0xFDF00000,
      matchValue: 0x00000000,
      resources: [VectorResource(), MemoryResource.store()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vse64.v',
      opcode: vectorStoreOpcode,
      funct3: 0x7,
      format: vLoadStoreType,
      matchMask: 0xFDF00000,
      matchValue: 0x00000000,
      resources: [VectorResource(), MemoryResource.store()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // FP vector (VV)
    RiscVOperation(
      mnemonic: 'vfadd.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opfvv,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: 0x00 << 26,
      resources: [VectorResource(), FpuResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vfmul.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opfvv,
      format: vArithType,
      matchMask: 0xFC000000,
      matchValue: 0x24 << 26,
      resources: [VectorResource(), FpuResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
  ],
);
