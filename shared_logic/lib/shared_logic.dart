/// Shared, framework-free logic for the Sitewise FYP.
///
/// This package holds the layers that neither Flutter nor Jaspr owns: the
/// **domain** (entities, repository contracts, use cases) and the **data**
/// implementations that back them. Both apps depend on it, so a change to a
/// business rule or a model happens once instead of twice.
///
/// It is deliberately dependency-free — no Flutter, no Jaspr, no third-party
/// packages. Only `dart:core`, `dart:convert` and `dart:typed_data` are used,
/// which is what makes it consumable from a browser-compiled Jaspr app as well
/// as a Flutter mobile app.
///
/// ## Browser-safety
///
/// A handful of data sources are mobile-only because they touch `dart:io` or
/// Flutter plugins (which do not exist in a browser) — local file persistence
/// for onboarding and captured frames, the OpenCV panorama stitcher, and the
/// file-backed auth session store. Those live in the Flutter app's own data
/// layer (`fyp_mobile_app/lib/data/`), not here, so importing this library can
/// never drag `dart:io` into a web build.
library;

// --- Domain: entities -------------------------------------------------------
export 'src/domain/entities/app_role.dart';
export 'src/domain/entities/capture_config.dart';
export 'src/domain/entities/capture_point.dart';
export 'src/domain/entities/capture_session_state.dart';
export 'src/domain/entities/captured_frame.dart';
export 'src/domain/entities/commercial_property.dart';
export 'src/domain/entities/location_intelligence.dart';
export 'src/domain/entities/recommendation.dart';
export 'src/domain/entities/sitewise_records.dart';
export 'src/domain/entities/user.dart';
export 'src/domain/entities/virtual_tour.dart';

// --- Domain: contracts & services -------------------------------------------
export 'src/domain/repositories/admin_repositories.dart';
export 'src/domain/repositories/auth_repository.dart';
export 'src/domain/repositories/intelligence_repositories.dart';
export 'src/domain/repositories/onboarding_repository.dart';
export 'src/domain/repositories/property_repository.dart';
export 'src/domain/repositories/recommendation_repository.dart';
export 'src/domain/services/panorama_stitcher.dart';

// --- Domain: use cases ------------------------------------------------------
export 'src/domain/usecases/intelligence_usecases.dart';
export 'src/domain/usecases/property_usecases.dart';
export 'src/domain/usecases/recommendation_usecases.dart';
export 'src/domain/usecases/verification_usecases.dart';

// --- Data: browser-safe implementations -------------------------------------
export 'src/data/datasources/local/capture_target_data_source.dart';
export 'src/data/datasources/local/demo_data.dart';
export 'src/data/dtos/property_dto.dart';
export 'src/data/mappers/property_mapper.dart';
export 'src/data/models/commercial_property_model.dart';
export 'src/data/models/location_intelligence_model.dart';
export 'src/data/models/user_model.dart';
export 'src/data/repositories/admin_repositories_impl.dart';
export 'src/data/repositories/intelligence_repositories_impl.dart';
export 'src/data/repositories/property_repository_impl.dart';
export 'src/data/repositories/recommendation_repository_impl.dart';

// --- Core: the three framework-free helpers the layers above depend on ------
//
// Paths mirror the Flutter project's `lib/core/` exactly. That is deliberate:
// the data layer imports them with relative paths (`../../core/constants/...`),
// so preserving the folder shape keeps those imports valid without rewriting.
export 'src/core/config/app_config.dart';
export 'src/core/constants/app_constants.dart';
export 'src/core/errors/app_failure.dart';
export 'src/core/network/api_client.dart';

// --- Application: shared state management -----------------------------------
//
// Built on `package:bloc`, which is pure Dart. Nothing exported here may import
// Flutter or Jaspr — that is what lets the Flutter app consume these cubits via
// `flutter_bloc` while the Jaspr app uses the raw Cubit API.
//
// These replace the Flutter `ChangeNotifier` classes they were ported from:
//   AppCubit            <- AppState (lib/application/state/app_state.dart)
//   EntrepreneurCubit   <- EntrepreneurViewModel
//                          (lib/presentation/shared/viewmodels/)
//   OwnerCubit          <- OwnerViewModel
//   AdminCubit          <- AdminViewModel
export 'src/application/cubits/app_cubit.dart';
export 'src/application/cubits/entrepreneur_cubit.dart';
export 'src/application/cubits/owner_cubit.dart';
export 'src/application/cubits/admin_cubit.dart';
export 'src/application/states/app_state.dart';
export 'src/application/states/entrepreneur_state.dart';
export 'src/application/states/owner_state.dart';
export 'src/application/states/admin_state.dart';
export 'src/application/usecases/filter_properties.dart';

// The structured filter model (budget / size / type / location / verification)
// shared by the Explore and Recommendation screens in both apps.
export 'src/application/usecases/property_filter.dart';

// --- Application: shared services (framework-free orchestration) ------------
//
// Both apps talk to these instead of repositories directly. Moved out of the
// Flutter app's `lib/application/services/` when the Jaspr web tree began
// consuming the same orchestration.
export 'src/application/services/auth_service.dart';
export 'src/application/services/property_service.dart';
export 'src/application/services/recommendation_service.dart';
export 'src/application/services/tour_service.dart';
export 'src/application/services/verification_service.dart';
