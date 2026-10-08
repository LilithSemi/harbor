import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);

RiscVOperation _csrRw(String mnemonic, int funct3, {bool isImm = false}) =>
    RiscVOperation(
      mnemonic: mnemonic,
      opcode: RiscvOpcode.system,
      funct3: funct3,
      format: iType,
      resources: [
        if (!isImm) RfResource(_int, rs1),
        RfResource(_int, rd),
        CsrResource(),
      ],
      microcode: [
        if (!isImm) RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVCopyField(RiscVMicroOpField.imm, RiscVMicroOpField.rd),
        RiscVReadCsr(RiscVMicroOpField.imm),
        RiscVWriteCsr(RiscVMicroOpField.rd, RiscVMicroOpSource.rs1),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.imm),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    );

RiscVOperation _csrSet(String mnemonic, int funct3, {bool isImm = false}) =>
    RiscVOperation(
      mnemonic: mnemonic,
      opcode: RiscvOpcode.system,
      funct3: funct3,
      format: iType,
      resources: [
        if (!isImm) RfResource(_int, rs1),
        RfResource(_int, rd),
        CsrResource(),
      ],
      microcode: [
        if (!isImm) RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVCopyField(RiscVMicroOpField.imm, RiscVMicroOpField.rd),
        RiscVReadCsr(RiscVMicroOpField.imm),
        RiscVAlu(
          RiscVAluFunct.or_,
          RiscVMicroOpField.imm,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteCsr(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.imm),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    );

RiscVOperation _csrClear(
  String mnemonic,
  int funct3, {
  bool isImm = false,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: RiscvOpcode.system,
  funct3: funct3,
  format: iType,
  resources: [
    if (!isImm) RfResource(_int, rs1),
    RfResource(_int, rd),
    CsrResource(),
  ],
  microcode: [
    if (!isImm) RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVCopyField(RiscVMicroOpField.imm, RiscVMicroOpField.rd),
    RiscVReadCsr(RiscVMicroOpField.imm),
    RiscVAlu(RiscVAluFunct.and_, RiscVMicroOpField.imm, RiscVMicroOpField.rs1),
    RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rs2),
    RiscVAlu(RiscVAluFunct.xor_, RiscVMicroOpField.imm, RiscVMicroOpField.rs2),
    RiscVWriteCsr(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.imm),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

final rvZicsr = RiscVExtension(
  name: 'Zicsr',
  key: null,
  misaBit: null,
  operations: [
    _csrRw('csrrw', CsrFunct3.csrrw),
    _csrSet('csrrs', CsrFunct3.csrrs),
    _csrClear('csrrc', CsrFunct3.csrrc),
    _csrRw('csrrwi', CsrFunct3.csrrwi, isImm: true),
    _csrSet('csrrsi', CsrFunct3.csrrsi, isImm: true),
    _csrClear('csrrci', CsrFunct3.csrrci, isImm: true),
  ],
);
