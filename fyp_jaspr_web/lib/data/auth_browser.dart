import 'dart:convert';
import 'dart:js_interop';

@JS('sitewiseAuth')
external _AuthBridge get _bridge;

extension type _AuthBridge(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get ready;
  external JSString snapshot();
  external JSPromise<JSAny?> google(JSBoolean remember);
  external JSPromise<JSAny?> password(
    JSString email,
    JSString password,
    JSBoolean remember,
    JSString mfaCode,
    JSString expectedPortal,
  );
  // Native Supabase TOTP enrollment ("Secure Your Staff Account").
  external JSPromise<JSString> mfaChallengeStart();
  external JSPromise<JSAny?> mfaChallengeVerify(JSString code);
  external JSPromise<JSAny?> mfaEnrollStart();
  external JSPromise<JSAny?> mfaEnrollVerify(JSString code);
  // Native Supabase password recovery + update (both portals).
  external JSPromise<JSString> resetPassword(JSString email);
  external JSPromise<JSAny?> updatePassword(JSString password);
  external JSPromise<JSString> signup(
    JSString email,
    JSString password,
    JSString name,
  );
  external JSPromise<JSAny?> complete([JSString next]);
  external JSPromise<JSAny?> signout();
  external JSPromise<JSString> request(
    JSString path,
    JSString method,
    JSString body,
  );
}

abstract final class WebAuth {
  static Map<String, dynamic> get _state =>
      jsonDecode(_bridge.snapshot().toDart) as Map<String, dynamic>;
  static bool get configured => _state['configured'] == true;
  /// True when the last password sign-in returned a TOTP MFA challenge that
  /// still needs the verification code. The staff form reveals its code field
  /// on this signal rather than showing it unprompted.
  static bool get mfaRequired => _state['mfaRequired'] == true;
  /// True when the signed-in staff account has no verified TOTP factor and is
  /// therefore required to complete the enrollment screen first.
  static bool get mfaEnrollmentRequired =>
      _state['mfaEnrollmentRequired'] == true;
  /// Supabase-generated QR code (SVG data URI) for TOTP enrollment.
  static String? get mfaEnrollQr => _state['mfaEnrollQr'] as String?;
  /// TOTP secret for manual authenticator entry (shown only to the enrolling
  /// user during setup; never persisted server-side by Sitewise).
  static String? get mfaEnrollSecret => _state['mfaEnrollSecret'] as String?;
  static Map<String, dynamic>? get profile =>
      _state['profile'] as Map<String, dynamic>?;
  static String get error => _state['error'] as String? ?? '';
  static Future<void> initialize() async {
    await _bridge.ready.toDart;
  }

  static Future<void> google([bool remember = true]) async {
    await _bridge.google(remember.toJS).toDart;
  }

  /// [expectedPortal] is a validation context only ('entrepreneur' | 'staff'):
  /// the JS bridge rejects an account whose backend-assigned role does not
  /// belong to the selected portal. It never grants or changes a role.
  static Future<void> password(
    String email,
    String password, [
    bool remember = true,
    String? mfaCode,
    String? expectedPortal,
  ]) async {
    await _bridge
        .password(
          email.toJS,
          password.toJS,
          remember.toJS,
          (mfaCode ?? '').toJS,
          (expectedPortal ?? '').toJS,
        )
        .toDart;
  }

  static Future<String> mfaChallengeStart() async =>
      (await _bridge.mfaChallengeStart().toDart).toDart;

  static Future<void> mfaChallengeVerify(String code) async {
    await _bridge.mfaChallengeVerify(code.toJS).toDart;
  }

  static Future<void> mfaEnrollStart() async {
    await _bridge.mfaEnrollStart().toDart;
  }

  static Future<void> mfaEnrollVerify(String code) async {
    await _bridge.mfaEnrollVerify(code.toJS).toDart;
  }

  /// Sends the native Supabase recovery email; returns the confirmation
  /// message for the UI.
  static Future<String> resetPassword(String email) async =>
      (await _bridge.resetPassword(email.toJS).toDart).toDart;

  /// Sets a new password using the current Supabase session (recovery or
  /// invite link), then routes by the server-assigned role.
  static Future<void> updatePassword(String password) async {
    await _bridge.updatePassword(password.toJS).toDart;
  }

  static Future<String> signup(
    String email,
    String password,
    String name,
  ) async =>
      (await _bridge.signup(email.toJS, password.toJS, name.toJS).toDart).toDart;
  static Future<void> complete([String? next]) async {
    await _bridge.complete((next ?? '').toJS).toDart;
  }

  static Future<void> signout() async {
    await _bridge.signout().toDart;
  }

  static Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final decoded = jsonDecode(
      (await _bridge
              .request(
                path.toJS,
                method.toJS,
                (body == null ? '' : jsonEncode(body)).toJS,
              )
              .toDart)
          .toDart,
    );
    // GET /users/ returns a bare array; wrap it exactly as the VM bridge does
    // so callers see one shape on both platforms (a Map cast would throw here).
    if (decoded is Map<String, dynamic>) return decoded;
    return {'data': decoded};
  }
}
