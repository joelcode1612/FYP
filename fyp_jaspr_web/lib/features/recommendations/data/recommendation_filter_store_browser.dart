/// Browser-only persistence for *filter criteria*, not credentials or results.
/// Local storage survives reloads; user id in the key prevents switching
/// accounts in one browser from reusing somebody else's filters.
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/dev_auth_bypass.dart';

@JS('localStorage')
external _LocalStorage get _localStorage;

extension type _LocalStorage(JSObject _) implements JSObject {
  external JSString? getItem(JSString key);
  external void setItem(JSString key, JSString value);
  external void removeItem(JSString key);
}

abstract final class RecommendationFilterStore {
  static const _prefix = 'sitewise:recommendation-filters:v1:';

  static String? get _key {
    // Profile is initialized before SitewiseApp mounts. Anonymous requests
    // must not write to a shared persistent account slot.
    try {
      final userId = WebAuth.profile?['user_id']?.toString().trim() ?? '';
      if (userId.isNotEmpty) return '$_prefix$userId';
      if (devAuthBypassEnabled) return '${_prefix}local-demo';
      return null;
    } on Object {
      return null;
    }
  }

  static RecommendationSearchRequest? read() {
    final key = _key;
    if (key == null) return null;
    try {
      final raw = _localStorage.getItem(key.toJS)?.toDart;
      if (raw == null || raw.isEmpty) return null;
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic> || data['version'] != 1) return null;
      final json = data['criteria'];
      if (json is! Map<String, dynamic>) return null;
      final request = RecommendationSearchRequest.fromJson(json).copyWith(
        clearCursor: true,
        managedOnly: false,
        clearNearby: true,
      );
      return request.isBrowseOnly ? null : request;
    } on Object {
      // Disabled storage, stale schema or invalid JSON: use a fresh form.
      return null;
    }
  }

  static void write(RecommendationSearchRequest request) {
    final key = _key;
    if (key == null) return;
    if (request.isBrowseOnly) {
      clear();
      return;
    }
    try {
      // Never store a pagination cursor or a management scope. After reload
      // the backend must search from page 1 under the current user.
      final safe = request.copyWith(
        clearCursor: true, managedOnly: false, clearNearby: true,
      );
      if (safe.isBrowseOnly) { clear(); return; }
      final payload = jsonEncode({
        'version': 1,
        'criteria': safe.toJson(),
      });
      _localStorage.setItem(key.toJS, payload.toJS);
    } on Object {
      // Storage can be blocked by browser policy; filtering still works.
    }
  }

  static void clear() {
    final key = _key;
    if (key == null) return;
    try {
      _localStorage.removeItem(key.toJS);
    } on Object {
      // Storage can be blocked; do not stop the Clear action.
    }
  }
}
