
import 'package:flutter/foundation.dart';
import 'mobile_runtime_config.dart';

bool get devAuthBypassEnabled =>
    kDebugMode &&
        MobileRuntimeConfig.boolean(
          'SITEWISE_DEV_AUTH_BYPASS',
          // Fail closed. Bypassing the route guard must be an EXPLICIT opt-in
          // (dart-define or runtime config), never a default. The old `true`
          // default made AuthGuard a no-op, which broke the signed-out
          // assessment regression test and let a debug build reach workspace
          // routes without a session.
          fallback: const bool.fromEnvironment(
            'SITEWISE_DEV_AUTH_BYPASS',
            defaultValue: false,
          ),
        );
