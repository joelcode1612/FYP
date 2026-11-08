/// Plain-Dart successor runtime (host: `fyp_mobile_app`).
///
/// The main FYP app uses flutter_bloc — NOT flutter_riverpod — and is part of a
/// shared pub workspace, so this port deliberately adds NO dependency. It keeps
/// the same fail-closed semantics as the Riverpod variant:
///
///   * DEFAULT port = `UnavailableRoutePort` (FAIL CLOSED).
///   * No silent fallback to permissive `MockRouting` (not imported here).
///   * Rendering is gated strictly on `RouteAvailable`; a cached snapshot is
///     provenance-only and never renderable.
library;

import 'route_contract.dart';
import 'route_outcome.dart';
import 'route_port.dart';
import 'successor_flags.dart';

/// Immutable evaluation harness. Default construction is fail-closed.
class SuccessorRuntime {
  final SuccessorFlags flags;
  final RoutePreviewPort port;

  const SuccessorRuntime({
    this.flags = const SuccessorFlags(),
    this.port = const UnavailableRoutePort(),
  });

  /// Explicit dev/review harness: holds a synthetic port but still enables no
  /// production, scientific or bilingual approval.
  const SuccessorRuntime.syntheticReview({
    this.port = const SyntheticRoutePort(),
  }) : flags = const SuccessorFlags.syntheticReview();

  /// Evaluate a preview request through the configured port.
  Future<RouteOutcome> evaluate(RoutePreviewRequest request) => port.preview(request);
}

/// Pure helper: what may actually be rendered.
/// Only `RouteAvailable` yields permissions; everything else is empty.
List<PreviewPermission> renderablePermissions(RouteOutcome outcome) =>
    outcome.permissions
        .where((p) => p.state == RouteItemState.eligibleToShow)
        .toList(growable: false);