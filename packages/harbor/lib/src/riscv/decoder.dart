import 'package:rohd/rohd.dart';

import '../encoding/riscv_formats.dart';
import 'isa.dart';
import 'operation.dart';

/// Hardware instruction decoder generated from an [RiscVIsaConfig].
///
/// Takes a 32-bit instruction input and produces decoded fields,
/// control signals, and validity flags. Handles both 32-bit and
/// 16-bit (compressed) instructions.
///
/// For each instruction in the ISA:
/// - Generates match logic from each operation's decode pattern
/// - Outputs an operation index for microcode ROM lookup
/// - Flags illegal instructions
///
/// ```dart
/// final decoder = RiscVInstructionDecoder(
///   isaConfig,
///   instructionInput: fetchedInstruction,
/// )
/// await decoder.build()
///
/// // Use decoded outputs
/// final isIllegal = decoder.illegal
/// final opIndex = decoder.operationIndex
/// final rdAddr = decoder.rdField
/// ```
class RiscVInstructionDecoder extends Module {
  /// The ISA this decoder was generated from.
  final RiscVIsaConfig isa;

  /// Whether this instruction is illegal (no match found).
  Logic get illegal => output('illegal');

  /// Whether this instruction is compressed (16-bit).
  Logic get isCompressed => output('is_compressed');

  /// Decoded operation index (into [RiscVIsaConfig.allOperations]).
  Logic get operationIndex => output('op_index');

  /// Decoded opcode field (bits 6:0)..
  Logic get opcodeField => output('opcode');

  /// Decoded rd field (bits 11:7)..
  Logic get rdField => output('rd');

  /// Decoded funct3 field (bits 14:12)..
  Logic get funct3Field => output('funct3');

  /// Decoded rs1 field (bits 19:15)..
  Logic get rs1Field => output('rs1');

  /// Decoded rs2 field (bits 24:20)..
  Logic get rs2Field => output('rs2');

  /// Decoded funct7 field (bits 31:25)..
  Logic get funct7Field => output('funct7');

  /// Decoded immediate value (sign-extended, format-dependent).
  Logic get immediateField => output('immediate');

  /// Whether this operation should be microcoded.
  Logic get isMicrocoded => output('is_microcoded');

  /// Whether this operation should be hard-coded.
  Logic get isHardcoded => output('is_hardcoded');

  RiscVInstructionDecoder(
    this.isa, {
    required Logic instructionInput,
    super.name = 'instruction_decoder',
  }) : super(definitionName: 'RiscVInstructionDecoder') {
    final instr = addInput('instruction', instructionInput, width: 32);

    final xlen = isa.mxlen.size;
    final ops = isa.allOperations;
    final indexWidth = ops.isEmpty ? 1 : ops.length.bitLength;

    // Outputs
    addOutput('illegal');
    addOutput('is_compressed');
    addOutput('op_index', width: indexWidth);
    addOutput('opcode', width: 7);
    addOutput('rd', width: 5);
    addOutput('funct3', width: 3);
    addOutput('rs1', width: 5);
    addOutput('rs2', width: 5);
    addOutput('funct7', width: 7);
    addOutput('immediate', width: xlen);
    addOutput('is_microcoded');
    addOutput('is_hardcoded');

    // Compressed detection
    isCompressed <= ~instr[0] | ~instr[1];

    // Extract standard fields using HarborBitStructView
    final view = rType.view(instr);
    opcodeField <= view['opcode'];
    rdField <= view['rd'];
    funct3Field <= view['funct3'];
    rs1Field <= view['rs1'];
    rs2Field <= view['rs2'];
    funct7Field <= view['funct7'];

    // Immediate decode (I-type by default, overridden per format)
    final iImm = instr.getRange(20, 32).signExtend(xlen);
    immediateField <= iImm;

    // RiscVOperation matching: generate a priority case from all operations
    if (ops.isEmpty) {
      illegal <= Const(1);
      operationIndex <= Const(0, width: indexWidth);
      isMicrocoded <= Const(0);
      isHardcoded <= Const(0);
    } else {
      _generateDecodeLogic(instr, ops, indexWidth);
    }
  }

  void _generateDecodeLogic(
    Logic instr,
    List<RiscVOperation> ops,
    int indexWidth,
  ) {
    final matchIllegal = Logic(name: 'match_illegal');
    final matchIndex = Logic(name: 'match_index', width: indexWidth);
    final matchMicrocoded = Logic(name: 'match_microcoded');
    final matchHardcoded = Logic(name: 'match_hardcoded');

    // Build match conditions for each operation
    final conditions = <Conditional>[];

    // Defaults
    conditions.add(matchIllegal < Const(1));
    conditions.add(matchIndex < Const(0, width: indexWidth));
    conditions.add(matchMicrocoded < Const(0));
    conditions.add(matchHardcoded < Const(0));

    // Generate If/ElseIf chain from highest to lowest priority
    // (earlier operations take priority on overlap)
    for (var i = ops.length - 1; i >= 0; i--) {
      final op = ops[i];
      final mode = isa.executionModeFor(op);

      // A compressed op only fixes bits 15:0, and its opcode in bits 1:0 is
      // never 0b11, so the two encoding spaces stay apart.
      Logic cond = (instr & Const(op.decodeMask, width: 32)).eq(
        Const(op.decodeValue, width: 32),
      );
      if (op.nonZeroMask != null) {
        cond = cond & (instr & Const(op.nonZeroMask!, width: 32)).neq(0);
      }
      if (op.zeroMask != null) {
        cond = cond & (instr & Const(op.zeroMask!, width: 32)).eq(0);
      }

      conditions.add(
        If(
          cond,
          then: [
            matchIllegal < Const(0),
            matchIndex < Const(i, width: indexWidth),
            matchMicrocoded <
                Const(
                  mode == RiscVExecutionMode.microcoded ||
                          mode == RiscVExecutionMode.parallel
                      ? 1
                      : 0,
                ),
            matchHardcoded <
                Const(
                  mode == RiscVExecutionMode.hardcoded ||
                          mode == RiscVExecutionMode.parallel
                      ? 1
                      : 0,
                ),
          ],
        ),
      );
    }

    Combinational(conditions);

    illegal <= matchIllegal;
    operationIndex <= matchIndex;
    isMicrocoded <= matchMicrocoded;
    isHardcoded <= matchHardcoded;
  }
}
