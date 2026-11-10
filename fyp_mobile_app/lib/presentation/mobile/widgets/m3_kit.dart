import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_m3.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../shell/entrepreneur_tab_scope.dart';

/// Reusable presentational pieces for the Material 3 entrepreneur workspace.
///
/// Ported 1:1 from the CSS classes in
/// `Sitewise_Mobile_Material3_Mock_Data.html`:
///
/// | CSS class            | widget                                    |
/// |----------------------|-------------------------------------------|
/// | `.app-head`          | [M3BrandHeader]                           |
/// | `.app-brand`         | [M3BrandLockup]                           |
/// | `.home-greeting`     | [M3ScreenHeading]                         |
/// | `.home-feature`      | [M3FeatureCard]                           |
/// | `.metric`            | [M3MetricTile]                            |
/// | `.section-row`       | [M3SectionRow]                            |
/// | `.demo-data-note`    | [M3DataNote]                              |
/// | `.listrow`           | [M3QuickActionRow]                        |
/// | `.btn.full`          | [M3PrimaryButton]                         |
/// | `.banner`            | [M3Banner]                                |
/// | `.card`              | [M3Card]                                  |
///
/// These widgets are deliberately stateless and carry **no data access**; each
/// screen supplies real values from `ServiceLocator` / the Riverpod providers. That keeps
/// the reference's visual language from leaking invented records into the app.

// ── App chrome ────────────────────────────────────────────────────────────────

/// `.app-head` — fixed brand header with two utility buttons.
///
/// Uses the real Sitewise mark (`assets/sitewise-mark-64.png`), the same master
/// asset used by the web app and the launcher icons — never an inline glyph.
class M3BrandHeader extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final List<Widget> actions;

  const M3BrandHeader({super.key, this.title, this.actions = const []});

  @override
  Size get preferredSize => const Size.fromHeight(62);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: SitewiseM3.paper,
      surfaceTintColor: SitewiseM3.paper,
      foregroundColor: SitewiseM3.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 62,
      titleSpacing: 16,
      shape: const Border(
        bottom: BorderSide(color: SitewiseM3.divider, width: 1),
      ),
      title: Row(
        children: [
          const M3BrandLockup(),
          if (title != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: SitewiseM3.muted,
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [...actions, const SizedBox(width: 10)],
    );
  }
}

/// `.app-brand` — logo + `SITEWISE` + `F&B LOCATION INTELLIGENCE` tag.
class M3BrandLockup extends StatelessWidget {
  const M3BrandLockup({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/sitewise-mark-64.png',
          width: 39,
          height: 39,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          errorBuilder: (_, _, _) => Container(
            width: 39,
            height: 39,
            decoration: BoxDecoration(
              color: SitewiseM3.primary,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(width: 9),
        // The AppBar gives the title a bounded width (it shares the row with
        // the utility buttons). Flexible + ellipsis keeps the lockup inside
        // that width on narrow phones instead of overflowing the RenderFlex.
        const Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'SITEWISE',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.94,
                  height: 1.05,
                  color: SitewiseM3.ink,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'F&B LOCATION INTELLIGENCE',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 7,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.63,
                  height: 1.05,
                  color: SitewiseM3.brandTag,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `.circle-btn` — 41px rounded utility button.
class M3CircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const M3CircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: SitewiseM3.circleBtnBg,
          borderRadius: BorderRadius.circular(SitewiseM3.radiusCircle),
          child: InkWell(
            borderRadius: BorderRadius.circular(SitewiseM3.radiusCircle),
            onTap: onTap,
            child: Container(
              width: 41,
              height: 41,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(SitewiseM3.radiusCircle),
                border: Border.all(color: SitewiseM3.circleBtnBorder),
              ),
              child: Icon(icon, size: 21, color: SitewiseM3.circleBtnIcon),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Screen structure ─────────────────────────────────────────────────────────

/// `.eyebrow` + `h1` + `.lead` block used at the top of every tab.
class M3ScreenHeading extends StatelessWidget {
  final String eyebrow;
  final String title;
  final String lead;

  const M3ScreenHeading({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.lead,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(eyebrow.toUpperCase(), style: SitewiseM3Type.eyebrow),
        const SizedBox(height: 7),
        Semantics(header: true, child: Text(title, style: SitewiseM3Type.h1)),
        const SizedBox(height: 8),
        Text(lead, style: SitewiseM3Type.lead),
      ],
    );
  }
}

/// `.section-row` — heading plus an optional right-hand overline / link.
class M3SectionRow extends StatelessWidget {
  final String title;
  final String? overline;
  final String? actionLabel;
  final VoidCallback? onAction;

  const M3SectionRow({
    super.key,
    required this.title,
    this.overline,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 22, 0, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Text(title, style: SitewiseM3Type.h2)),
          if (overline != null)
            Text(
              overline!,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.54,
                color: SitewiseM3.overline,
              ),
            ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: SitewiseM3.primary,
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// `.card` — white 22px-radius surface.
class M3Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const M3Card({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SitewiseM3.surface,
      borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
      child: InkWell(
        borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
        onTap: onTap,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: SitewiseM3.surface,
            borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
            border: Border.all(color: SitewiseM3.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0C276097),
                blurRadius: 20,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

// ── Home feature ─────────────────────────────────────────────────────────────

/// `.home-feature` — the light-blue gradient discovery card.
class M3FeatureCard extends StatelessWidget {
  final String kicker;
  final String title;
  final String body;
  final String ctaLabel;
  final VoidCallback onCta;
  final IconData decoration;

  const M3FeatureCard({
    super.key,
    required this.kicker,
    required this.title,
    required this.body,
    required this.ctaLabel,
    required this.onCta,
    this.decoration = Icons.storefront_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 19, 0, 17),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(SitewiseM3.radiusFeature),
        border: Border.all(color: SitewiseM3.featureBorder),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: [0.0, 0.56, 1.0],
          colors: [
            SitewiseM3.featureStart,
            SitewiseM3.featureMid,
            SitewiseM3.featureEnd,
          ],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x13305DAE),
            blurRadius: 24,
            offset: Offset(0, 7),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -7,
            top: -14,
            child: Opacity(
              opacity: 0.10,
              child: Transform.rotate(
                angle: -0.21,
                child: Icon(decoration, size: 76, color: SitewiseM3.primary),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(19, 19, 19, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Kicker pill. Constrained + ellipsis so a long label cannot
                // overflow the card on a narrow (<=360px) phone.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 270),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x9EFFFFFF),
                      borderRadius: BorderRadius.circular(
                        SitewiseM3.radiusPill,
                      ),
                      border: Border.all(color: const Color(0xFFCEDFFF)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.bar_chart_rounded,
                          size: 16,
                          color: SitewiseM3.kickerText,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            kicker.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: kFontFamily,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.72,
                              color: SitewiseM3.kickerText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 270),
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      height: 1.16,
                      letterSpacing: -0.84,
                      color: SitewiseM3.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Text(
                    body,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      height: 1.6,
                      color: SitewiseM3.featureTitle,
                    ),
                  ),
                ),
                const SizedBox(height: 17),
                M3PrimaryButton(label: ctaLabel, onTap: onCta),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `.btn.full` — full-width blue pill action.
class M3PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final IconData icon;

  const M3PrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = Icons.arrow_forward_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 47,
      child: Material(
        color: SitewiseM3.primary,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        child: InkWell(
          borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: SitewiseM3.primary,
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
              border: Border.all(color: SitewiseM3.primary),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1C1D4ED8),
                  blurRadius: 9,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: SitewiseM3.surface,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Icon(icon, size: 16, color: SitewiseM3.surface),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Metrics / notes / rows ───────────────────────────────────────────────────

/// `.metric` — blue / teal overview tile.
class M3MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final bool teal;

  const M3MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    this.teal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 15, 14, 15),
      decoration: BoxDecoration(
        color: teal ? SitewiseM3.metricTealBg : SitewiseM3.metricBlueBg,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusMetric),
        border: Border.all(
          color: teal
              ? SitewiseM3.metricTealBorder
              : SitewiseM3.metricBlueBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: teal
                  ? SitewiseM3.metricTealIconBg
                  : SitewiseM3.metricIconBg,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              icon,
              size: 22,
              color: teal ? SitewiseM3.metricTealIcon : SitewiseM3.primary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF3A5983),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 27,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.2,
              height: 1.05,
              color: SitewiseM3.metricValue,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 10,
              color: Color(0xFF566E88),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.demo-data-note` — provenance line under the metrics.
class M3DataNote extends StatelessWidget {
  final String text;

  const M3DataNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 13),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: SitewiseM3.noteBg,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: SitewiseM3.noteBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.info_outline_rounded,
              size: 17,
              color: SitewiseM3.primary,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                height: 1.5,
                color: SitewiseM3.noteText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.listrow.home-quick-action` — large tappable row with icon + chevron.
class M3QuickActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const M3QuickActionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusRow),
        child: InkWell(
          borderRadius: BorderRadius.circular(SitewiseM3.radiusRow),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 70),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: SitewiseM3.surface,
              borderRadius: BorderRadius.circular(SitewiseM3.radiusRow),
              border: Border.all(color: SitewiseM3.rowBorder),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x08264D82),
                  blurRadius: 13,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 43,
                  height: 43,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: SitewiseM3.rowIconBg,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(icon, size: 24, color: SitewiseM3.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: SitewiseM3.rowTitle,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 11,
                          color: SitewiseM3.rowDesc,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 16,
                  color: Color(0xFF4E6E9E),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.banner` — quiet explanatory callout.
class M3Banner extends StatelessWidget {
  final String text;
  final IconData icon;

  const M3Banner({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: SitewiseM3.bannerBg,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: SitewiseM3.bannerBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: SitewiseM3.bannerText),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                height: 1.5,
                color: SitewiseM3.bannerText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small status pill (`.tag`) with green / amber / neutral variants.
class M3Tag extends StatelessWidget {
  final String label;
  final bool positive;

  const M3Tag({super.key, required this.label, this.positive = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: positive ? SitewiseM3.greenWash : const Color(0xFFF0F5FF),
        borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        border: Border.all(
          color: positive ? const Color(0xFFB4E9D2) : const Color(0xFFE1E9F8),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: positive ? SitewiseM3.green : const Color(0xFF3E5D84),
        ),
      ),
    );
  }
}

/// Shared padding wrapper matching `.content` (21px/19px gutters).
class M3Content extends StatelessWidget {
  final List<Widget> children;

  const M3Content({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        SitewiseM3.gutter,
        20,
        SitewiseM3.gutter,
        122,
      ),
      children: children,
    );
  }
}

/// Builds the two header utility buttons used across the five tabs.
List<Widget> m3HeaderActions(
  BuildContext context, {
  required VoidCallback onNotifications,
}) => [
  M3CircleButton(
    icon: Icons.notifications_none_rounded,
    tooltip: 'Notifications',
    onTap: onNotifications,
  ),
  M3CircleButton(
    icon: Icons.person_outline_rounded,
    tooltip: 'Profile',
    // Switch to the Profile tab inside the persistent host instead of
    // pushing a second workspace route (which showed a stray back arrow).
    onTap: () => EntrepreneurTabScope.open(context, '/entrepreneur/profile'),
  ),
];

/// Honest "nothing here yet" surface used by the Assess / Spaces tabs.
class M3EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const M3EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return M3Card(
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 30),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: SitewiseM3.quiet,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, size: 28, color: SitewiseM3.primary),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: SitewiseM3.ink,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11.5,
              height: 1.55,
              color: SitewiseM3.muted,
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: M3PrimaryButton(
                label: actionLabel!,
                onTap: onAction ?? () {},
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Convenience for screens that need to show a real `CommercialProperty` line.
String m3PropertyLine(CommercialProperty p) =>
    '${p.city}, ${p.state} · RM${p.rentalRm.toStringAsFixed(0)}/mo';
