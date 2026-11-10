import 'package:flutter/foundation.dart';

const bool _requested = bool.fromEnvironment(
  'SITEWISE_DEV_AUTH_BYPASS',
  defaultValue: false,
);

bool get devAuthBypassEnabled => kDebugMode && _requested;