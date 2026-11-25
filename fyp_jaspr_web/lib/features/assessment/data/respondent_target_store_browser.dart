/// Browser-only persistence for the *respondent target*, not credentials and not
/// results.
///
/// The user id is part of the key so switching accounts in one browser cannot
/// inherit somebody else's target. Local storage survives reloads, which is the
/// point: the report gate must not reset every time the page is refreshed.
library;

import 'dart:js_interop';

import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/dev_auth_bypass.dart';

@JS('localStorage')
external _LocalStorage get _localStorage;

extension type _LocalStorage(JSObject _) implements JSObject {
  external JSString? getItem(JSString key);
  external void setItem(JSString key, JSString value);
  external void removeItem(JSString key);
}

abstract final class RespondentTargetStore {
  /// Smallest and largest accepted target. Mirrored in the stub so both
  /// implementations agree on the range the UI advertises.
  static const int minTarget = 1;
  static const int maxTarget = 9999;

  static const _prefix = 'sitewise:respondent-target:v1:';

  static String? _key(String assessmentId) {
    final id = assessmentId.trim();
    if (id.isEmpty) return null;
    // Profile is initialized before SitewiseApp mounts. Anonymous requests must
    // not write to a shared persistent slot.
    try {
      final userId = WebAuth.profile?['user_id']?.toString().trim() ?? '';
      if (userId.isNotEmpty) return '$_prefix$userId:$id';
      if (devAuthBypassEnabled) return '${_prefix}local-demo:$id';
      return null;
    } on Object {
      return null;
    }
  }

  /// The stored target, or null when none has been set.
  ///
  /// An out-of-range or unparseable value is treated as unset rather than
  /// clamped: a corrupt entry must not silently become a target the
  /// entrepreneur never chose.
  static int? read(String assessmentId) {
    final key = _key(assessmentId);
    if (key == null) return null;
    try {
      final raw = _localStorage.getItem(key.toJS)?.toDart;
      if (raw == null || raw.isEmpty) return null;
      final value = int.tryParse(raw.trim());
      if (value == null || value < minTarget || value > maxTarget) return null;
      return value;
    } on Object {
      // Storage can be blocked by browser policy; the target then reads unset.
      return null;
    }
  }

  static void write(String assessmentId, int value) {
    final key = _key(assessmentId);
    if (key == null) return;
    if (value < minTarget || value > maxTarget) return;
    try {
      _localStorage.setItem(key.toJS, '$value'.toJS);
    } on Object {
      // Storage can be blocked; the in-memory target still gates this session.
    }
  }

  static void clear(String assessmentId) {
    final key = _key(assessmentId);
    if (key == null) return;
    try {
      _localStorage.removeItem(key.toJS);
    } on Object {
      // Storage can be blocked; do not stop the caller.
    }
  }
}
