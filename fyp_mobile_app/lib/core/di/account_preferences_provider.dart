// sitewise-expanded-user-preferences-v1
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/features/profile/application/account_discovery_preferences.dart';

/// One server-backed read per active account/provider lifetime. A sign-out or
/// account change invalidates the result; no previous user's settings reused.
final accountDiscoveryPreferencesProvider =
    FutureProvider<AccountDiscoveryPreferences>((ref) async {
  final userId = ref.watch(authNotifierProvider.select((state) => state.user?.id));
  if (!MobileConfig.usesLiveApi || userId == null || userId.isEmpty) {
    return AccountDiscoveryPreferences(null);
  }
  final record = await ServiceLocator.userPreferences.load();
  return AccountDiscoveryPreferences(record.preferences);
});
