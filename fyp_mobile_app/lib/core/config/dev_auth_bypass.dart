
import 'package:flutter/foundation.dart';
import 'mobile_runtime_config.dart';

bool get devAuthBypassEnabled =>
    kDebugMode &&
        MobileRuntimeConfig.boolean(
          'SITEWISE_DEV_AUTH_BYPASS',
          fallback: const bool.fromEnvironment(
            'SITEWISE_DEV_AUTH_BYPASS',
            defaultValue: false,
          ),
        );
