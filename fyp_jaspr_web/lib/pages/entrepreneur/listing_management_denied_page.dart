import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Denied landing for `My Properties` inside the Entrepreneur workspace.
///
/// An entrepreneur browses, compares and assesses the catalogue; creating and
/// managing listings belongs to a verified Property Owner / Agent account and
/// runs in the SiteWise mobile Provider workspace. The two former routes
/// (`/entrepreneur/my-properties`, `/entrepreneur/add-property`) stay registered
/// so an old bookmark, an in-app link or a shared URL explains the change
/// instead of failing with a bare 404 — and so nothing renders a listing, a
/// draft or another account's data.
///
/// It renders inside the ordinary entrepreneur shell on purpose: the reader
/// keeps their own navigation and role, and the page carries no record, no
/// listing id and no ownership claim.
class ListingManagementDeniedPage extends StatelessComponent {
  const ListingManagementDeniedPage({super.key});

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.entrepreneur,
    currentRoute: '/entrepreneur',
    title: 'My Properties',
    eyebrow: 'Workspace',
    subtitle: 'Listing management is not an Entrepreneur capability.',
    child: div(classes: 'stack stack--sections', [
      const EmptyState(
        title: 'Listing management is not part of this workspace',
        body:
            'The Entrepreneur workspace is for finding and assessing commercial '
            'property. Registering, publishing and managing a listing is a '
            'verified Property Owner / Agent job, and it now lives in the '
            'SiteWise mobile application — the same workspace owners and agents '
            'share.',
        action: ActionLink(
          'Back to Recommendations',
          href: '/entrepreneur/recommendations',
        ),
      ),
    ]),
  );
}
