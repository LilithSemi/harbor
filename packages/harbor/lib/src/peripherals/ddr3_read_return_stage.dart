import 'package:rohd/rohd.dart';

/// One register stage on the ISERDES returns, in the SERDES clock domain.
///
/// The ISERDES sites sit in the I/O column. The controller logic can sit far
/// from them, so a return path that goes through the controller compare logic
/// in one cycle has a long route in it. This stage ends that route at the
/// register, close to the I/O column. The returns arrive one cycle later. The
/// read calibration finds the read latency, so the controller needs no change.
class Ddr3ReadReturnStage extends Module {
  Logic get data => output('o_data');
  Logic get dqs => output('o_dqs');
  Logic get bitslipReference => output('o_bitslip_reference');

  Ddr3ReadReturnStage({
    required Logic clk,
    required Logic data,
    required Logic dqs,
    required Logic bitslipReference,
    super.name = 'ddr3_read_return_stage',
  }) {
    clk = addInput('clk', clk);
    data = addInput('i_data', data, width: data.width);
    dqs = addInput('i_dqs', dqs, width: dqs.width);
    bitslipReference = addInput(
      'i_bitslip_reference',
      bitslipReference,
      width: bitslipReference.width,
    );
    final dataQ = addOutput('o_data', width: data.width);
    final dqsQ = addOutput('o_dqs', width: dqs.width);
    final bitslipQ = addOutput(
      'o_bitslip_reference',
      width: bitslipReference.width,
    );
    Sequential(clk, [dataQ < data, dqsQ < dqs, bitslipQ < bitslipReference]);
  }
}
