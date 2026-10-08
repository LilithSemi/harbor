import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'wishbone_interface.dart';

/// Connects a Wishbone [provider] (master side) to a [consumer] (slave side)
/// whose configs can have different optional ports.
///
/// The two modules must have the same parent. An optional input that the
/// other side does not drive is tied to 0. When the consumer can end a
/// transfer with ERR or RTY and the provider has no such port, that
/// termination goes to the provider as ACK with [wishbonePoison] read data.
/// The result is high while such a folded termination shows, or null when
/// none can fold. The caller can keep it as a sticky bus error.
Logic? connectWishbone(
  InterfaceReference provider,
  InterfaceReference consumer,
) {
  final p = provider.interface as WishboneInterface;
  final c = consumer.interface as WishboneInterface;
  final except = <String>{};

  for (final name in wishboneOptionalRequestPorts) {
    final pp = p.tryPort(name);
    final cp = c.tryPort(name);
    if ((pp == null) == (cp == null)) continue;
    except.add(name);
    if (cp != null) cp <= Const(0, width: cp.width);
  }

  final pTgd = p.tgdMiso;
  final cTgd = c.tgdMiso;
  if ((pTgd == null) != (cTgd == null)) {
    except.add('TGD_MISO');
    if (pTgd != null) pTgd <= Const(0, width: pTgd.width);
  }

  final folded = <Logic>[];
  Logic? fold;
  for (final name in ['ERR', 'RTY']) {
    final pp = p.tryPort(name);
    final cp = c.tryPort(name);
    if ((pp == null) == (cp == null)) continue;
    except.add(name);
    if (pp != null) {
      pp <= Const(0);
    } else {
      folded.add(cp!);
    }
  }
  if (folded.isNotEmpty) {
    except.addAll(['ACK', 'DAT_MISO']);
    final bad = folded.reduce((a, b) => a | b);
    fold = bad;
    p.ack <= c.ack | bad;
    p.datMiso <= mux(bad, wishbonePoison(p.config.dataWidth), c.datMiso);
  }

  connectInterfaces(
    provider,
    consumer,
    exceptPorts: except.isEmpty ? null : except,
  );
  return fold;
}
