/// Development-only gate for the synthetic Q01 report preview.
///
/// Three independent conditions must ALL hold before the preview route exists
/// and before its page will render:
///
/// 1. **Compile time.** The build must be made with
///    `--dart-define=SITEWISE_SYNTHETIC_PREVIEW=true`. The default is `false`,
///    so a normal `jaspr build` compiles the whole branch out and the route is
///    never registered.
/// 2. **Build environment.** `SITEWISE_BUILD_ENV` must be `development`. A
///    production-labelled build refuses even when the flag is present.
/// 3. **Runtime origin.** The page must be served from a local development
///    origin. A flag-carrying artefact deployed to a real hostname is inert.
///
/// The gate is deliberately stricter than [devAuthBypassEnabled], whose opt-in
/// flag defaults to `true`. A synthetic chart is a visual claim about a
/// measurement, so it must be off unless somebody asked for it in the build.
///
/// What the gate does NOT do
/// -------------------------
/// It grants no measurement authority. The chart it unlocks is still
/// `SYNTHETIC_PREVIEW_ONLY` with a `HELD` admission block; the gate only decides
/// whether the demonstration is *visible*, never whether it is *reportable*.
/// Those are separate decisions and this file has no opinion on the second.
library;

import 'package:sitewise_jaspr_web/features/authentication/data/dev_auth_bypass.dart'
    show isLocalDevHost;

/// Opt-in switch, read at compile time from a `--dart-define`.
const bool _previewRequested = bool.fromEnvironment(
  'SITEWISE_SYNTHETIC_PREVIEW',
  defaultValue: false,
);
const bool _developmentBuild =
    String.fromEnvironment('SITEWISE_BUILD_ENV', defaultValue: 'production') ==
    'development';
const bool _productionBuild = bool.fromEnvironment('dart.vm.product');

/// The compile-time half of the gate, without the runtime host check.
const bool syntheticPreviewRequested =
    _previewRequested && _developmentBuild && !_productionBuild;

/// Pure decision function, so the rule is testable without a browser.
bool syntheticPreviewAllowed({
  required bool requested,
  required bool developmentBuild,
  required bool productionBuild,
  required String host,
}) => requested && developmentBuild && !productionBuild && isLocalDevHost(host);

/// True only on a local dev origin in a development build that opted in.
///
/// `Uri.base` is the document URL in a browser build; under the VM it is a file
/// URI with an empty host, so this is false there — which is the safe default.
bool get syntheticPreviewEnabled =>
    syntheticPreviewRequested && isLocalDevHost(Uri.base.host);

/// Server-side equivalent, for a request whose `Host` header is known.
/// [hostHeader] is the raw header value and may include a port.
bool syntheticPreviewForHost(String? hostHeader) {
  if (!syntheticPreviewRequested || hostHeader == null) return false;
  final raw = hostHeader.trim();
  String host = raw;
  if (raw.startsWith('[')) {
    final end = raw.indexOf(']');
    if (end != -1) host = raw.substring(0, end + 1);
  } else {
    final colon = raw.indexOf(':');
    if (colon != -1) host = raw.substring(0, colon);
  }
  return isLocalDevHost(host);
}

/// The route the development harness lives on.
///
/// Namespaced under `/dev/` so it can never be mistaken for a product
/// destination or linked from one. It mounts the real report component with
/// synthetic inputs; it is not a second report.
const String syntheticPreviewPath = '/dev/report';
