// Type-check harness. NOT part of the app.
//
// Why this exists: `dart analyze` cannot run on this machine (the Windows pipe
// pool is exhausted, so it cannot spawn its analysis server), and `jaspr
// build` needs `jaspr_cli`, which fails to build its executable for the same
// reason. `dart compile js` does work, and it runs the full Dart front end —
// i.e. real static type checking.
//
// So this file references every component so the compiler walks them all, and
// `dart compile js tool/typecheck.dart` then reports genuine type errors in
// the app code. It is a verification aid, never shipped.
//
// IMPORTANT: this harness is a *supplement*, not the primary check. It does not
// import `lib/main.client.dart`, so it cannot catch errors in the entry point —
// an earlier version of this file gave a false all-clear while the entry point
// held two real `ambiguous_import` errors. Always run the real entry point first:
//
//   jaspr build                                          <- primary
//   dart compile js tool/typecheck.dart                    <- extra coverage
//
// Run:
//   dart compile js tool/typecheck.dart -o /tmp/typecheck.js

import 'package:jaspr/jaspr.dart';
import 'package:sitewise_jaspr_web/app.dart';
import 'package:sitewise_jaspr_web/components/ui.dart';
import 'package:sitewise_jaspr_web/layouts/marketing_layout.dart';
import 'package:sitewise_jaspr_web/pages/landing_page.dart';
import 'package:sitewise_jaspr_web/pages/login_page.dart';

void main() {
  // Touching each type forces instantiation of its generic/return types, so
  // the front end resolves every `build()` body in the tree. `SitewiseApp`
  // transitively pulls in every routed page (all admin/owner/entrepreneur
  // pages), so those bodies are checked without listing them here.
  final components = <Component>[
    const SitewiseApp(),
    const LandingPage(),
    const LoginPage(),
    const MarketingLayout(child: LandingPage()),
    const Brand(),
    const Pill('probe'),
    const Eyebrow('probe'),
    const SectionHead(eyebrow: 'a', title: 'b', body: 'c'),
    const ActionLink('probe', href: '/'),
    ActionButton('probe', onClick: () {}),
    const StatCard(label: 'a', value: 'b'),
    const StepCard(num: '01', title: 'a', body: 'b'),
    const FeatureRow(icon: 'groups', title: 'a', body: 'b'),
    const WeightBar(label: 'a', pct: 35),
    const Icon('groups'),
  ];

  // Keep the list from being tree-shaken away before it is checked.
  assert(components.isNotEmpty);
}
