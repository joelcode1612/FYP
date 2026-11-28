/// Canonical public routes for the single continuous landing page.
///
/// All five paths render the same LandingPage component. They exist so public
/// section links are real, refreshable browser URLs instead of URL fragments.
/// A section id is a DOM target used only for route-aware programmatic
/// scrolling; it is never appended to a public URL.
library;

abstract final class LandingRoutes {
  static const String home = '/home';
  static const String problem = '/problem';
  static const String explore = '/explore';
  static const String assessment = '/assessment';
  static const String recommendations = '/recommendations';

  /// DOM id of the top of the continuous landing page.
  static const String topSectionId = 'top';

  /// Desktop/mobile navigation, in landing page order.
  static const List<(String label, String path, String sectionId)> sections = [
    ('Problem & solution', problem, 'problem'),
    ('Explore', explore, 'explore'),
    ('Assessment', assessment, 'assessment'),
    ('Recommendations', recommendations, 'recommendations'),
  ];

  /// All public landing routes, in page order.
  static const List<String> paths = [
    home,
    problem,
    explore,
    assessment,
    recommendations,
  ];

  /// The DOM section a landing route scrolls to after navigation.
  static String sectionIdForPath(String path) => switch (path) {
        home => topSectionId,
        problem => 'problem',
        explore => 'explore',
        assessment => 'assessment',
        recommendations => 'recommendations',
        _ => topSectionId,
      };
}
