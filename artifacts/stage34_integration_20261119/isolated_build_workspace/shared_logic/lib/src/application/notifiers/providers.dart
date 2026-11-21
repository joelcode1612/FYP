import 'package:riverpod/riverpod.dart';

import '../../domain/entities/app_role.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/repositories/admin_repositories.dart';
import '../../domain/repositories/explore_repository.dart';
import '../../domain/repositories/property_verification_repository.dart';
import '../../domain/repositories/recommendation_search_repository.dart';
import '../../domain/repositories/saved_properties_repository.dart';
import '../../domain/usecases/property_usecases.dart';
import '../../domain/usecases/recommendation_usecases.dart';
import '../states/app_state.dart';
import '../services/auth_service.dart';
import '../services/property_service.dart';
import '../services/property_verification_service.dart';
import '../services/tour_service.dart';
import '../services/verification_service.dart';

/// Dependency providers the shared notifiers consume.
///
/// Every provider here is overridden at each app's composition root (the
/// `ProviderScope` in the Flutter app's `main.dart` and the web app's
/// `main.client.dart`), because only the app knows which repository and
/// service implementations to wire. Reading an un-overridden provider is a
/// composition error and fails loudly instead of silently defaulting.
///
/// Tests override the same providers with fakes — this replaces the old
/// `ServiceLocator`/`AppLocator` mutable test seams for state wiring.

final authServiceProvider = Provider<AuthService>(
  (ref) => throw UnimplementedError(
    'authServiceProvider must be overridden at the composition root.',
  ),
);

/// Seeds [AppNotifier] with an initial state (e.g. the cookie-restored
/// selection in the web app). Defaults to an empty state.
final appInitialStateProvider = Provider<AppState?>((ref) => null);

final getPropertiesProvider = Provider<GetProperties>(
  (ref) => throw UnimplementedError(
    'getPropertiesProvider must be overridden at the composition root.',
  ),
);

final getRecommendationsProvider = Provider<GetRecommendations>(
  (ref) => throw UnimplementedError(
    'getRecommendationsProvider must be overridden at the composition root.',
  ),
);

final getLocationAnalysisProvider = Provider<GetLocationAnalysis>(
  (ref) => throw UnimplementedError(
    'getLocationAnalysisProvider must be overridden at the composition root.',
  ),
);

final businessPreferencesProvider = Provider<BusinessPreferences>(
  (ref) => throw UnimplementedError(
    'businessPreferencesProvider must be overridden at the composition root.',
  ),
);

/// Optional server-driven Explore source (`/api/v1/explore/*`, the
/// `fyp.rental_properties` universe). Null — the default — keeps the
/// client-driven path: the full listing loads once and filters run locally
/// (demo data, and the web catalogue whose `EP-xxxxx` ids the saved-list and
/// assessment backends require). Overriding this swaps [loadExplore] to real
/// server-side filtering, sorting and pagination.
final exploreRepositoryProvider = Provider<ExploreRepository?>((ref) => null);

/// Optional authenticated saved-property shortlist
/// (`/api/v1/saved-properties`, catalogue refs). Null — the default — keeps
/// the device-local selection each app already owns. Composition roots wire
/// this where the signed-in account's shortlist lives on the server.
final savedPropertiesRepositoryProvider = Provider<SavedPropertiesRepository?>(
  (ref) => null,
);

/// Optional server-side recommendation search
/// (`POST /api/v1/recommendations/search`, catalogue ids).
///
/// Null — the default — means this platform has no live recommendation
/// backend. The Recommendations page then reports the feature as unavailable
/// instead of sorting a local list and calling it a ranking: the whole point
/// of the endpoint is that the server owns filtering, ordering and paging.
final recommendationSearchRepositoryProvider =
    Provider<RecommendationSearchRepository?>((ref) => null);

/// Write-back hook fired when the entrepreneur updates their preferences.
/// The composition root decides where preferences persist (local file on
/// mobile, nothing on web).
final onPreferencesUpdatedProvider = Provider<void Function(BusinessPreferences)>(
  (ref) => (_) {},
);

final propertyServiceProvider = Provider<PropertyService>(
  (ref) => throw UnimplementedError(
    'propertyServiceProvider must be overridden at the composition root.',
  ),
);

final tourServiceProvider = Provider<TourService>(
  (ref) => throw UnimplementedError(
    'tourServiceProvider must be overridden at the composition root.',
  ),
);

final verificationServiceProvider = Provider<VerificationService>(
  (ref) => throw UnimplementedError(
    'verificationServiceProvider must be overridden at the composition root.',
  ),
);

/// Optional live unified property-verification workflow (`/api/v1/properties/
/// ...verification`, `/api/v1/staff/properties/...`). Null — the default —
/// keeps the demo verification queue; the composition roots wire it where
/// the authenticated API client lives.
final propertyVerificationRepositoryProvider =
    Provider<PropertyVerificationRepository?>((ref) => null);

final propertyVerificationServiceProvider = Provider<PropertyVerificationService?>(
  (ref) {
    final repo = ref.watch(propertyVerificationRepositoryProvider);
    return repo == null ? null : PropertyVerificationService(repo);
  },
);

final adminPropertyReviewServiceProvider = Provider<AdminPropertyReviewService?>(
  (ref) {
    final repo = ref.watch(propertyVerificationRepositoryProvider);
    return repo == null ? null : AdminPropertyReviewService(repo);
  },
);

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => throw UnimplementedError(
    'userRepositoryProvider must be overridden at the composition root.',
  ),
);

/// Role an authenticated session starts in before the user picks one.
/// The composition root supplies its default (mobile: entrepreneur).
final defaultRoleProvider = Provider<AppRole>((ref) => AppRole.entrepreneur);
