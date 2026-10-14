import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';


/// Shared landing content (copy + structure) consumed by both the Web and
/// Mobile landing trees. Pure data — no layout. Business/app layers are
/// untouched; CTAs resolve to existing routes.

abstract final class LandingContent {
  static const String eyebrow = 'Evidence-based F&B location decisions';
  static const String heroTitleA = 'Choose your next ';
  static const String heroTitleEm = 'F&B location';
  static const String heroTitleB = ' with better evidence.';
  static const String heroLead =
      'Sitewise brings your business preferences, commercial property '
      'information and geospatial signals together so you can discover, '
      'compare and understand suitable locations.';
  static const String heroPrimary = 'Find a Suitable Location';
  static const String heroSecondary = 'See How It Works';
  static const String heroNote =
      'Recommendations are explained through clear location factors — '
      'you make the final decision.';

  static const List<(String label, String anchor)> navLinks = [
    ('How It Works', 'how'),
    ('Location Intelligence', 'geo'),
    ('Recommendations', 'recs'),
    ('360° Tours', 'tour'),
  ];

  static const List<RoleCardData> roles = [
    RoleCardData(
      icon: Icons.storefront_outlined,
      title: 'F&B Entrepreneurs',
      body:
          'Define your business preferences, explore verified commercial '
          'properties, compare locations, review suitability factors and '
          'inspect available 360° tours.',
      linkLabel: 'Explore suitable locations',
      role: AppRole.entrepreneur,
      route: '/entrepreneur',
    ),
    RoleCardData(
      icon: Icons.business_outlined,
      title: 'Commercial Property Owners',
      body:
          'Present commercial rental properties with structured details, '
          'availability information and immersive 360° tours for '
          'entrepreneurs evaluating a shortlist.',
      linkLabel: 'See property presentation',
      role: AppRole.owner,
      route: '/owner/tours',
    ),
  ];

  static const List<StepData> steps = [
    StepData(
      num: '01',
      title: 'Define your business',
      body:
          'Set your F&B concept, target customers, budget, size and operating preferences.',
    ),
    StepData(
      num: '02',
      title: 'Analyse the location',
      body:
          'Review population, accessibility, competition and nearby demand-generating places.',
    ),
    StepData(
      num: '03',
      title: 'Compare properties',
      body:
          'See how candidate properties fit your stated requirements and location conditions.',
    ),
    StepData(
      num: '04',
      title: 'Understand why',
      body:
          'Review the factors behind each recommendation before deciding which sites to visit.',
    ),
  ];

  static const List<FeatureData> features = [
    FeatureData(
      icon: Icons.groups_outlined,
      title: 'Population context',
      body:
          'Understand the residential and population environment around the candidate area.',
    ),
    FeatureData(
      icon: Icons.alt_route,
      title: 'Accessibility',
      body:
          'Consider road access, public transport and the practical reach of the location.',
    ),
    FeatureData(
      icon: Icons.storefront_outlined,
      title: 'Competition & demand',
      body:
          'Review nearby F&B presence and demand generators that can influence the catchment.',
    ),
    FeatureData(
      icon: Icons.home_work_outlined,
      title: 'Property-level context',
      body:
          'Connect location signals with rent, floor area, frontage and other property details.',
    ),
  ];

  static const String assessmentProperty = 'Artisan Brew Corner Lot';
  static const double assessmentScore = 86;
  static const List<DriverData> drivers = [
    DriverData(
      title: 'Strong daytime demand',
      body:
          'Nearby offices and education-related activity support daytime demand.',
      tradeoff: false,
    ),
    DriverData(
      title: 'Good accessibility',
      body:
          'Road and public transport access contribute positively to the location context.',
      tradeoff: false,
    ),
    DriverData(
      title: 'Trade-off: Moderate café competition',
      body: 'Existing F&B presence nearby may increase competitive pressure.',
      tradeoff: true,
    ),
  ];

  static const List<(String label, double pct)> weights = [
    ('Morning pedestrian activity', 35),
    ('Direct competition', 25),
    ('Premise suitability', 20),
    ('Rent fit', 20),
  ];

  static const List<(String k, String v)> siteProfile = [
    ('Location', 'SS15, Subang Jaya'),
    ('Monthly rent', 'RM 7,000 – RM 8,000'),
    ('Floor area', '1,200 sq ft'),
    ('Frontage', 'Corner retail lot'),
    ('Transport', 'Good'),
    ('360° tour', 'Available'),
  ];

  static const String ctaTitle =
      'Make your next F&B location decision with better evidence.';
  static const String ctaBody =
      'Start with your business preferences, explore available commercial '
      'properties, and understand the location factors before deciding which '
      'sites deserve a closer look.';

  static final VirtualTour sampleTour = VirtualTour(
    id: 'sample',
    propertyId: 'p-artisan',
    title: 'Artisan Brew corner walkthrough',
    sceneCount: 6,
    capturedAt: DateTime(2025, 11, 2),
    published: true,
  );
}

class RoleCardData {
  final IconData icon;
  final String title;
  final String body;
  final String linkLabel;
  final AppRole role;
  final String route;

  const RoleCardData({
    required this.icon,
    required this.title,
    required this.body,
    required this.linkLabel,
    required this.role,
    required this.route,
  });
}

class StepData {
  final String num;
  final String title;
  final String body;

  const StepData({required this.num, required this.title, required this.body});
}

class FeatureData {
  final IconData icon;
  final String title;
  final String body;

  const FeatureData({
    required this.icon,
    required this.title,
    required this.body,
  });
}

class DriverData {
  final String title;
  final String body;
  final bool tradeoff;

  const DriverData({
    required this.title,
    required this.body,
    required this.tradeoff,
  });
}
