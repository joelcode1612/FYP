import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import 'provider_models.dart';

/// Shared visual constants for the Owner / Agent workspace.
///
/// These are no longer a private second palette. Every token points at the
/// SAME SiteWise design system the entrepreneur mobile workspace uses, so a
/// future change to `SitewiseColors` / `SitewiseM3` restyles both workspaces
/// together instead of letting the Provider screens drift into another visual
/// language.
const Color providerBrand = SitewiseColors.action; // #1D4ED8
const Color providerBrandStrong = SitewiseM3.primary; // #1D4ED8
const Color providerCanvas = SitewiseM3.paper; // #FFFFFF
const Color providerInk = SitewiseM3.ink; // #0B0F19
const Color providerMuted = SitewiseM3.muted; // #64748B
const Color providerBorder = SitewiseM3.line; // #E7E8EA

/// Light-blue wash for icon badges and inset blocks.
const Color providerWash = SitewiseM3.quiet; // #DBEAFE

/// Quiet blue-tinted inset surface, used only inside a white card.
const Color providerSoft = Color(0xFFF4F7FB);

/// Standard page gutters and bottom clearance for the floating dock.
const double providerGutter = SitewiseM3.gutter;
const double providerDockClearance = 122;

/// Shared scroll surface for a Provider tab.
///
/// `AlwaysScrollableScrollPhysics` keeps pull-to-refresh alive even when a
/// loading / error / empty state is shorter than the viewport; the bottom
/// inset clears the floating dock exactly as `M3Content` does.
Widget providerContent({required List<Widget> children}) => ListView(
  physics: const AlwaysScrollableScrollPhysics(),
  padding: const EdgeInsets.fromLTRB(
    providerGutter,
    20,
    providerGutter,
    providerDockClearance,
  ),
  children: children,
);

/// A loading state that still permits the swipe-down reload gesture.
///
/// `RefreshIndicator` needs a scrollable descendant that can overscroll. A
/// bare centred spinner cannot, so a swipe made while a request is in flight
/// would be ignored. `AlwaysScrollableScrollPhysics` keeps the gesture live
/// even when the content is shorter than the screen.
Widget providerLoadingView() => ListView(
  physics: const AlwaysScrollableScrollPhysics(),
  children: const [
    SizedBox(
      height: 280,
      child: Center(
        child: CircularProgressIndicator(color: SitewiseColors.action),
      ),
    ),
  ],
);

/// Waits for [request] to settle without rethrowing its error.
///
/// A pull-to-refresh gesture must stay active until the request completes, but
/// the `FutureBuilder` that owns the request is the one that renders a failure.
/// Rethrowing here would turn a visible error card into an unhandled async
/// exception.
Future<void> settleRefresh(Future<dynamic> request) async {
  try {
    await request;
  } catch (_) {
    // Rendered by the owning FutureBuilder.
  }
}

/// M3 header shared by Provider drill-in pages.
///
/// An eyebrow + title keeps the page name visible on pushed routes (the tab
/// host itself uses the brand-lockup header), while the paper surface,
/// hairline divider, 62px height and Archivo type match the entrepreneur
/// chrome. A custom [leading] is used by the MFA gate's close button; every
/// other page keeps the platform back affordance.
class ProviderPageAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const ProviderPageAppBar({
    super.key,
    required this.title,
    this.eyebrow = 'SITEWISE PROVIDER',
    this.leading,
  });

  final String title;
  final String eyebrow;
  final Widget? leading;

  @override
  Size get preferredSize => const Size.fromHeight(62);

  @override
  Widget build(BuildContext context) => AppBar(
    automaticallyImplyLeading: leading == null,
    leading: leading,
    backgroundColor: SitewiseM3.paper,
    surfaceTintColor: SitewiseM3.paper,
    foregroundColor: SitewiseM3.ink,
    elevation: 0,
    scrolledUnderElevation: 0,
    toolbarHeight: 62,
    titleSpacing: leading == null ? 20 : 12,
    shape: const Border(
      bottom: BorderSide(color: SitewiseM3.divider, width: 1),
    ),
    title: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          eyebrow,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
            color: SitewiseColors.action,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: SitewiseM3Type.h2,
        ),
      ],
    ),
  );
}

/// Status chip used everywhere a listing state is shown.
class ProviderStatusPill extends StatelessWidget {
  const ProviderStatusPill({super.key, required this.stage, this.compact = false});

  final ProviderStage stage;

  /// Compact rendering for dense dashboard cards: the same states and colours,
  /// short labels so a card row never wraps ("Pending Review" instead of
  /// "Pending verification").
  final bool compact;

  String get _label => compact
      ? switch (stage) {
          ProviderStage.pending => 'Pending Review',
          _ => stage.filterLabel,
        }
      : stage.label;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (stage) {
      ProviderStage.draft => (SitewiseM3.quiet, const Color(0xFF3B4A5F)),
      ProviderStage.pending => (SitewiseM3.amberWash, SitewiseM3.amber),
      ProviderStage.approved => (SitewiseM3.greenWash, SitewiseM3.green),
      ProviderStage.rejected => (
        SitewiseColors.dangerWash,
        SitewiseColors.danger,
      ),
      ProviderStage.unknown => (providerSoft, providerMuted),
    };
    return Semantics(
      label: 'Listing status: ${stage.label}',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: compact ? 5 : 6,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
          border: Border.all(color: bg),
        ),
        child: Text(
          _label,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: compact ? 9.5 : 10,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      ),
    );
  }
}

/// One KPI tile. [value] is a real server count — never a placeholder.
class ProviderKpi extends StatelessWidget {
  const ProviderKpi({
    super.key,
    required this.label,
    required this.value,
    this.tone,
    this.icon,
  });

  final String label;
  final int value;
  final Color? tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
        border: Border.all(color: SitewiseM3.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: providerWash,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 19, color: SitewiseColors.action),
              ),
            ),
          Text(
            '$value',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              height: 1.05,
              letterSpacing: -1,
              color: tone ?? SitewiseM3.ink,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: SitewiseM3.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Error / empty surface with an optional retry.
class ProviderMessage extends StatelessWidget {
  const ProviderMessage({
    super.key,
    required this.title,
    required this.body,
    this.onRetry,
    this.retryLabel = 'Try again',
    this.icon = Icons.info_outline_rounded,
  });

  final String title;
  final String body;
  final VoidCallback? onRetry;
  final String retryLabel;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
        border: Border.all(color: SitewiseM3.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: providerWash,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: SitewiseColors.action, size: 23),
          ),
          const SizedBox(height: 13),
          Text(
            title,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: SitewiseM3.ink,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            body,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              height: 1.55,
              color: SitewiseM3.muted,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 15),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: SitewiseColors.action,
                side: const BorderSide(color: SitewiseColors.action),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
                ),
                minimumSize: const Size(0, 44),
              ),
              child: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// The MFA gate shown when the backend answers `staff_mfa_required`.
///
/// The workspace does not attempt to bypass the assurance level: the primary
/// action opens the authenticator screen, which elevates the session with the
/// authentication provider itself, and the refused request is retried on
/// return. Nothing is shown until the server confirms the elevated session.
class ProviderMfaGate extends StatelessWidget {
  const ProviderMfaGate({super.key, required this.onReload});

  /// Re-runs the refused request. Called after the authenticator screen
  /// reports an elevated session, and by the manual retry action.
  final VoidCallback onReload;

  Future<void> _openAuthenticator(BuildContext context) async {
    final elevated = await Navigator.of(
      context,
    ).pushNamed<bool>('/provider/mfa');
    if (elevated == true) onReload();
  }

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: SitewiseM3.surface,
      borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
      border: Border.all(color: SitewiseM3.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: providerWash,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(
            Icons.shield_outlined,
            color: SitewiseColors.action,
            size: 23,
          ),
        ),
        const SizedBox(height: 13),
        const Text(
          'Two-factor authentication required',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: SitewiseM3.ink,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'Property management is protected by a second factor. Set up or '
          'enter your authenticator code for this account — the workspace '
          'loads nothing until the server confirms the elevated session.',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            height: 1.55,
            color: SitewiseM3.muted,
          ),
        ),
        const SizedBox(height: 15),
        FilledButton(
          onPressed: () => _openAuthenticator(context),
          style: FilledButton.styleFrom(
            backgroundColor: SitewiseColors.action,
            foregroundColor: SitewiseM3.surface,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
            ),
          ),
          child: const Text('Set up or enter code'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: onReload,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
            ),
          ),
          child: const Text('I have completed the step'),
        ),
      ],
    ),
  );
}

/// Status pill for an enquiry. Same shape as [ProviderStatusPill] so the two
/// states read as one system rather than two.
class ProviderEnquiryPill extends StatelessWidget {
  const ProviderEnquiryPill({
    super.key,
    required this.label,
    required this.tone,
  });

  /// One of: incoming | read | replied | closed. Anything else is neutral —
  /// an unrecognised state is reported as itself, never colour-coded into a
  /// state the server did not send.
  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (tone) {
      'action' => (SitewiseM3.quiet, SitewiseColors.action),
      'warning' => (SitewiseM3.amberWash, SitewiseM3.amber),
      'success' => (SitewiseM3.greenWash, SitewiseM3.green),
      _ => (providerSoft, providerMuted),
    };
    return Semantics(
      label: 'Enquiry status: $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
          border: Border.all(color: bg),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      ),
    );
  }
}

/// A titled white card — the Provider counterpart of `M3Card`.
///
/// Used by the enquiries, performance and verification screens so they share
/// one surface, radius, hairline and typography with the dashboard.
class ProviderCard extends StatelessWidget {
  const ProviderCard({
    super.key,
    required this.child,
    this.title,
    this.trailing,
  });

  final Widget child;
  final String? title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: SitewiseM3.surface,
      borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
      border: Border.all(color: SitewiseM3.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  title!.toUpperCase(),
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: SitewiseColors.action,
                    letterSpacing: 0.9,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
        ],
        child,
      ],
    ),
  );
}
