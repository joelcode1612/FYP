import 'package:provider/provider.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/state/app_view_model.dart';
import '../../../../core/routing/mobile_role.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/landing/landing_content.dart';
import '../../../shared/widgets/sitewise_icon.dart';
import '../widgets/landing_mobile_sections.dart';

/// Public pre-auth landing page (Mobile tree): compact header with drawer,
/// stacked sections and footer. Same entry actions as the Web tree.

class LandingMobilePage extends StatefulWidget {
  const LandingMobilePage({super.key});

  @override
  State<LandingMobilePage> createState() => _LandingMobilePageState();
}

class _LandingMobilePageState extends State<LandingMobilePage> {
  final _keys = {
    for (final a in ['top', 'audience', 'how', 'geo', 'recs', 'tour'])
      a: GlobalKey(),
  };

  void _scrollTo(String anchor) {
    Navigator.of(context).maybePop();
    final ctx = _keys[anchor]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  /// Every landing CTA resolves through the mobile role gate. A web-only role
  /// (the Owner card, for instance) opens Sign In, which explains where that
  /// workspace lives, instead of pushing a route the app no longer has.
  void _enter(AppRole role, String route) {
    if (mobileHomeRouteFor(role) == null) {
      _toAuth('login');
      return;
    }
    context.read<AppViewModel>().setRole(role);
    Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
  }

  void _getStarted() =>
      _enter(AppRole.entrepreneur, AppRole.entrepreneur.homeRoute);

  void _toAuth(String tab) =>
      Navigator.of(context).pushNamed('/auth', arguments: tab);

  /// Sign In is the entry point, not a role picker: the account itself
  /// carries the role, and `_enter` keeps non-Entrepreneur accounts on the
  /// auth screen.
  void _login() => _toAuth('login');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SitewiseColors.background,
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: MobileBrand(onTap: () => _scrollTo('top')),
              ),
              const Divider(height: 1),
              for (final link in LandingContent.navLinks)
                ListTile(title: Text(link.$1), onTap: () => _scrollTo(link.$2)),
              const Divider(height: 1),
              ListTile(
                title: const Text(
                  'Log In',
                  style: TextStyle(
                    color: SitewiseColors.action,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onTap: _login,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).maybePop();
                      _getStarted();
                    },
                    child: const Text('Get Started'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            toolbarHeight: 64,
            backgroundColor: SitewiseColors.surface,
            surfaceTintColor: SitewiseColors.surface,
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(1),
              child: Divider(height: 1),
            ),
            automaticallyImplyLeading: false,
            title: MobileBrand(onTap: () => _scrollTo('top')),
            actions: [
              TextButton(
                onPressed: _getStarted,
                child: const Text(
                  'Get Started',
                  style: TextStyle(
                    color: SitewiseColors.action,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              Builder(
                builder: (ctx) => IconButton(
                  tooltip: 'Menu',
                  icon: SitewiseIcon(
                    Icons.menu,
                    intent: SitewiseIconIntent.appBarAction,
                    semanticLabel: 'Open menu',
                  ),
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          SliverToBoxAdapter(
            child: _MobileSection(
              anchorKey: _keys['top'],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MobileHeroCopy(
                    onGetStarted: _getStarted,
                    onSeeHow: () => _scrollTo('how'),
                  ),
                  const SizedBox(height: 24),
                  const MobileHeroVisual(),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _MobileSection(
              anchorKey: _keys['audience'],
              alt: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MobileSectionHead(
                    eyebrow: 'Who Sitewise is for',
                    title: 'One platform, different location needs.',
                    body:
                        'Sitewise supports the people involved in commercial '
                        'F&B property decisions.',
                  ),
                  const SizedBox(height: 20),
                  MobileRoleCards(onEnter: _enter),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _MobileSection(
              anchorKey: _keys['how'],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MobileSectionHead(
                    eyebrow: 'From business needs to location decision',
                    title: 'How Sitewise helps you evaluate a location.',
                    body:
                        'The workflow combines structured business preferences '
                        'with location evidence.',
                  ),
                  const SizedBox(height: 20),
                  const MobileSteps(),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _MobileSection(
              anchorKey: _keys['geo'],
              alt: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MobileSectionHead(
                    eyebrow: '01 — Location intelligence',
                    title: 'See the neighbourhood, not just the unit.',
                    body:
                        'Sitewise combines property context with geospatial '
                        'signals so a location can be evaluated as part of '
                        'its catchment.',
                  ),
                  const SizedBox(height: 20),
                  const MobileGeoVisual(),
                  const MobileGeoFeatures(),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _MobileSection(
              anchorKey: _keys['recs'],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MobileSectionHead(
                    eyebrow: '02 — Explainable recommendations',
                    title: 'Recommendations show their reasons.',
                    body:
                        'Review the factors behind a location assessment '
                        'instead of a black box.',
                  ),
                  const SizedBox(height: 20),
                  const MobileAssessment(),
                  const SizedBox(height: 12),
                  const MobileWeights(),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _MobileSection(
              anchorKey: _keys['tour'],
              alt: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MobileSectionHead(
                    eyebrow: '03 — Property exploration',
                    title: 'Explore the space before the site visit.',
                    body:
                        'Available 360° tours let entrepreneurs inspect a '
                        'shortlisted property alongside its location.',
                  ),
                  const SizedBox(height: 20),
                  MobileTourShowcase(
                    onExplore: () =>
                        _enter(AppRole.entrepreneur, '/entrepreneur/explore'),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _MobileSection(
              child: MobileCtaBox(
                onGetStarted: _getStarted,
                onLearn: () => _scrollTo('how'),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: MobileFooter(
              onNav: _scrollTo,
              onGetStarted: _getStarted,
              onLogin: _login,
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileSection extends StatelessWidget {
  final GlobalKey? anchorKey;
  final bool alt;
  final Widget child;
  const _MobileSection({this.anchorKey, this.alt = false, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: anchorKey,
      color: alt ? const Color(0xFFFAFBFC) : null,
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 16),
      child: child,
    );
  }
}
