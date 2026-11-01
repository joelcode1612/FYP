import 'dart:convert';
import 'dart:js_interop';

@JS('sitewiseAuth')
external _AuthBridge get _bridge;

extension type _AuthBridge(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get ready;
  external JSString snapshot();
  external JSPromise<JSAny?> google(JSString role, JSBoolean remember);
  external JSPromise<JSAny?> password(
    JSString email,
    JSString password,
    JSBoolean remember,
  );
  external JSPromise<JSString> signup(
    JSString email,
    JSString password,
    JSString name,
    JSString role,
  );
  external JSPromise<JSAny?> complete();
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
  static Map<String, dynamic>? get profile =>
      _state['profile'] as Map<String, dynamic>?;
  static String get error => _state['error'] as String? ?? '';
  static Future<void> initialize() async {
    await _bridge.ready.toDart;
  }

  static Future<void> google([
    String role = 'entrepreneur',
    bool remember = true,
  ]) async {
    await _bridge.google(role.toJS, remember.toJS).toDart;
  }

  static Future<void> password(
    String email,
    String password, [
    bool remember = true,
  ]) async {
    await _bridge.password(email.toJS, password.toJS, remember.toJS).toDart;
  }

  static Future<String> signup(
    String email,
    String password,
    String name,
    String role,
  ) async =>
      (await _bridge
              .signup(email.toJS, password.toJS, name.toJS, role.toJS)
              .toDart)
          .toDart;
  static Future<void> complete() async {
    await _bridge.complete().toDart;
  }

  static Future<void> signout() async {
    await _bridge.signout().toDart;
  }

  static Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async =>
      jsonDecode(
            (await _bridge
                    .request(
                      path.toJS,
                      method.toJS,
                      (body == null ? '' : jsonEncode(body)).toJS,
                    )
                    .toDart)
                .toDart,
          )
          as Map<String, dynamic>;
}
