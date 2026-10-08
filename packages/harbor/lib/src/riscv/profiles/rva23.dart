import '../extensions/rv32i.dart';
import '../extensions/rv64i.dart';
import '../extensions/rv_a.dart';
import '../extensions/rv_b.dart';
import '../extensions/rv_c.dart';
import '../extensions/rv_d.dart';
import '../extensions/rv_f.dart';
import '../extensions/rv_h.dart';
import '../extensions/rv_m.dart';
import '../extensions/rv_v.dart';
import '../extensions/rv_zicond.dart';
import '../extensions/rv_zicsr.dart';
import '../extensions/rv_zifencei.dart';
import '../extensions/rv_zfhmin.dart';
import '../extensions/rv_misc.dart';
import '../extensions/rv_priv.dart';
import '../isa.dart';
import '../mxlen.dart';
import '../paging.dart';

/// RVA23U64 - The unprivileged RVA23 profile for 64-bit application processors.
///
/// Includes all mandatory extensions per the RISC-V Profiles specification.
final rva23u64 = RiscVIsaConfig(
  mxlen: RiscVMxlen.rv64,
  extensions: [
    // Base
    rv32i, rv64i,
    // Standard
    rvM, rvA, rvF, rvD, rvC, rvZcd, rvV, rvB,
    // Floating-point
    rvZfhmin, rvZfhminD, rvZfa, rvZfaD,
    // CSR and fence
    rvZicsr, rvZicntr, rvZihpm,
    // Hints
    rvZihintpause, rvZihintntl,
    // Conditional
    rvZicond,
    // May-be-ops
    rvZimop, rvZcmop,
    // Compressed extras
    rvZcb,
    // Wait
    rvZawrs,
    // Crypto timing
    rvZkt, rvZvkt,
    // Vector extras
    rvZvfhmin, rvZvbb,
    // Cache
    rvZicbom, rvZicbop, rvZicboz,
    // Coherency
    rvZiccif, rvZiccrse, rvZiccamoa, rvZicclsm,
    rvZa64rs, rvZic64b,
    // Pointer masking
    rvSupm,
  ],
  hasUser: true,
);

/// RVA23S64 - The privileged RVA23 profile for 64-bit application processors.
///
/// Extends RVA23U64 with supervisor mode, hypervisor, and virtual memory.
final rva23s64 = RiscVIsaConfig(
  mxlen: RiscVMxlen.rv64,
  extensions: [
    // All of RVA23U64
    ...rva23u64.extensions,
    // Instruction fence (mandatory for S-mode)
    rvZifencei,
    // Privileged instructions (sret, mret, wfi, sfence.vma)
    rvPriv,
    // Hypervisor
    rvH, rvSha,
    // TLB management
    rvSvinval,
    // Virtual memory
    rvSvbare, rvSvade, rvSvadu, rvSvnapot, rvSvpbmt,
    // Supervisor features
    rvSstc, rvSscofpmf,
    // State-enable CSRs
    rvSmstateen, rvSsstateen,
  ],
  hasSupervisor: true,
  hasUser: true,
  pagingModes: [
    RiscVPagingMode.bare,
    RiscVPagingMode.sv39,
    RiscVPagingMode.sv48,
    RiscVPagingMode.sv57,
  ],
);
