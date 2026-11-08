/// Sealed route-preview outcome hierarchy.
///
/// `Unavailable` DOMINATES: a client-side unavailable state is distinct from
/// server-side HELD_UNAUTHORIZED / BLOCKED / Rejected. It must never be
/// promoted to Available by a cached snapshot.
library;

import 'route_contract.dart';
import 'route_snapshot.dart';

sealed class RouteOutcome {
  const RouteOutcome();
}

class RouteAvailable extends RouteOutcome {
  final RouteSnapshot snapshot;
  const RouteAvailable(this.snapshot);
}

class RouteUnavailable extends RouteOutcome {
  /// Generic, non-diagnostic reason. Do not mint EN/BM labels for opaque codes.
  final String genericReason;
  const RouteUnavailable(this.genericReason);
}

class RouteRejected extends RouteOutcome {
  final String reason;
  const RouteRejected(this.reason);
}

extension RouteOutcomeView on RouteOutcome {
  /// Only Available may render. Provenance-only snapshots never render.
  bool get isRenderable => switch (this) {
        RouteAvailable() => true,
        RouteUnavailable() => false,
        RouteRejected() => false,
      };

  List<PreviewPermission> get permissions => switch (this) {
        RouteAvailable(snapshot: final s) => s.permissions,
        RouteUnavailable() => const <PreviewPermission>[],
        RouteRejected() => const <PreviewPermission>[],
      };
}
