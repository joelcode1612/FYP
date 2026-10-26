import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web verification detail: property evidence on the left, decision rail on
/// the right.
///
/// Ported from `admin_verification_detail_web_page.dart`. The Flutter page
/// calls `ServiceLocator.verification` directly (no `AdminViewModel`), so this
/// version does the same through [AppLocator.verification] and only uses local
/// state for the confirm step and the post-action success card — the Flutter
/// SnackBar + `pop` becomes an inline success card with a link back to the
/// queue (no auto-navigation).
class VerificationDetailPage extends StatefulComponent {
  final String id;

  const VerificationDetailPage({super.key, required this.id});

  @override
  State<VerificationDetailPage> createState() => _VerificationDetailPageState();
}

class _VerificationDetailPageState extends State<VerificationDetailPage> {
  bool _confirmingReject = false;
  String? _success;

  Future<void> _approve(String id) async {
    await AppLocator.verification.approve(id);
    if (mounted) {
      setState(() {
        _confirmingReject = false;
        _success = 'Listing verified.';
      });
    }
  }

  Future<void> _reject(String id) async {
    await AppLocator.verification.reject(id, 'Incomplete documents');
    if (mounted) {
      setState(() {
        _confirmingReject = false;
        _success =
            'Listing rejected. The owner will be asked to fix the issues and resubmit.';
      });
    }
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/verification',
      title: 'Verification detail',
      eyebrow: 'Verification',
      subtitle:
          'The evidence available for this submission, and the decision you are about to record.',
      child: component.id.isEmpty
          ? _notFound()
          : FutureBuilder<CommercialProperty?>(
              future: AppLocator.properties.detail(component.id),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.done &&
                    snap.data == null) {
                  return _notFound();
                }
                if (!snap.hasData) return _loading();
                return _body(snap.data!);
              },
            ),
    );
  }

  Component _loading() {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading…')]),
    ]);
  }

  Component _notFound() {
    return div(classes: 'card stack', [
      span(classes: 'title', [Component.text('Record not found')]),
      p(classes: 'body', [
        Component.text(
          'No property matches this id. It may have been removed.',
        ),
      ]),
      const ActionLink(
        'Back to verification queue',
        href: '/admin/verification',
        variant: 'secondary',
      ),
    ]);
  }

  Component _body(CommercialProperty property) {
    return div(classes: 'grid-2', [
      div(classes: 'card stack', [
        div(classes: 'row', [
          span(classes: 'grow title', [Component.text(property.title)]),
          Pill(
            property.verification.label,
            tone: toneForVerification(property.verification),
          ),
        ]),
        div(classes: 'small muted', [
          Component.text(
            '${property.address}, ${property.postcode} ${property.city}',
          ),
        ]),
        p(classes: 'body', [
          Component.text(
            'RM${property.rentalRm.toStringAsFixed(0)} · '
            '${property.sizeSqft.toStringAsFixed(0)} sq ft · '
            '${property.propertyType}',
          ),
        ]),
        div(classes: 'divider', []),
        span(classes: 'title', [Component.text('Checklist')]),
        p(classes: 'body', [
          Component.text(
            '• Ownership document provided\n'
            '• Address matches SSM record\n'
            '• Photos show actual unit\n'
            '• Rental within area band',
          ),
        ]),
      ]),
      div(classes: 'card stack', [
        span(classes: 'title', [Component.text('Decision')]),
        if (_success != null) ...[
          div(classes: 'card stack', [
            span(classes: 'small text-success', [Component.text(_success!)]),
            const ActionLink(
              'Back to verification queue',
              href: '/admin/verification',
              variant: 'secondary',
            ),
          ]),
        ] else if (_confirmingReject) ...[
          span(classes: 'title', [Component.text('Reject listing?')]),
          p(classes: 'body', [
            Component.text(
              'The owner will be asked to fix the issues and resubmit.',
            ),
          ]),
          div(classes: 'row', [
            ActionButton(
              'Reject',
              variant: 'secondary',
              onClick: () => unawaited(_reject(property.id)),
            ),
            ActionButton(
              'Cancel',
              variant: 'ghost',
              onClick: () => setState(() => _confirmingReject = false),
            ),
          ]),
        ] else ...[
          ActionButton(
            'Verify listing',
            icon: 'verified',
            onClick: () => unawaited(_approve(property.id)),
          ),
          ActionButton(
            'Reject with reason',
            variant: 'secondary',
            icon: 'close',
            onClick: () => setState(() => _confirmingReject = true),
          ),
        ],
      ]),
    ]);
  }
}
