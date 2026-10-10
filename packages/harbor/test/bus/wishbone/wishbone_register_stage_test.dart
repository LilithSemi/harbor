// WishboneRegisterStage.definitionName must carry every up/down config field
// that changes the generated body, so two structurally-different stages
// never collide onto one reserved module name (see harbor_soc.dart's
// per-master `upConfig` stage vs. its plain decoder-side stage).

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  const base = WishboneConfig(addressWidth: 32, dataWidth: 32);

  test('same config gives the same definitionName', () {
    final a = WishboneRegisterStage(config: base);
    final b = WishboneRegisterStage(config: base);
    expect(a.definitionName, equals(b.definitionName));
  });

  test('a down-side useErr difference changes the definitionName', () {
    final plain = WishboneRegisterStage(config: base);
    final withErr = WishboneRegisterStage(
      config: base.copyWith(useErr: true),
    );
    expect(plain.definitionName, isNot(equals(withErr.definitionName)));
  });

  test('an up-only useErr difference changes the definitionName', () {
    final plain = WishboneRegisterStage(config: base);
    final upErr = WishboneRegisterStage(
      config: base,
      upConfig: base.copyWith(useErr: true),
    );
    expect(plain.definitionName, isNot(equals(upErr.definitionName)));
  });

  test('useRty, useCti+useBte and tag widths each change the name', () {
    final plain = WishboneRegisterStage(config: base);
    final withRty = WishboneRegisterStage(
      config: base.copyWith(useRty: true),
    );
    final withCtiBte = WishboneRegisterStage(
      config: base.copyWith(useCti: true, useBte: true),
    );
    final withTga = WishboneRegisterStage(
      config: base.copyWith(tgaWidth: 4),
    );
    final withTgd = WishboneRegisterStage(
      config: base.copyWith(tgdWidth: 8),
    );
    final names = {
      plain.definitionName,
      withRty.definitionName,
      withCtiBte.definitionName,
      withTga.definitionName,
      withTgd.definitionName,
    };
    expect(names, hasLength(5));
  });

  test('a data width difference changes the definitionName', () {
    final w32 = WishboneRegisterStage(
      config: const WishboneConfig(addressWidth: 32, dataWidth: 32),
    );
    final w64 = WishboneRegisterStage(
      config: const WishboneConfig(addressWidth: 32, dataWidth: 64),
    );
    expect(w32.definitionName, isNot(equals(w64.definitionName)));
  });
}
