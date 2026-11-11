# SiteWise one-time setup: auto-load JSON, no Android Studio run arguments.
# Save as sitewise_json_setup.py in FYP root; run: python sitewise_json_setup.py
from pathlib import Path
import json, shutil

root = Path.cwd()
mobile = root / 'fyp_mobile_app'
assert (mobile / 'lib/main.dart').is_file(), 'Run this in the FYP project root.'

def edit(rel, old, new):
    file = root / rel
    source = file.read_text(encoding='utf-8-sig')
    if new in source:
        return
    elif old in source:
        result = source.replace(old, new, 1)
    else:
        raise RuntimeError(f'Code differs in {rel}; check the joel branch.')
    backup = file.with_name(file.name + '.backup')
    if not backup.exists():
        shutil.copy2(file, backup)
    file.write_text(result, encoding='utf-8')
    print('Updated', rel)

# 1. Shared Logic must stay Flutter-free. Only this setter is new.
edit('shared_logic/lib/src/core/config/app_config.dart',
"""  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );""",
"""  static String? _mobileUrl;
  static String? _mobileKey;
  static String get supabaseUrl =>
      _mobileUrl ?? const String.fromEnvironment('SUPABASE_URL');
  static String get supabaseAnonKey =>
      _mobileKey ?? const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static void configureSupabase({required String url, required String publishableKey}) {
    _mobileUrl = url.trim();
    _mobileKey = publishableKey.trim();
  }""")

# 2. Mobile-only Flutter asset loader (not imported by shared_logic).
loader = mobile / 'lib/core/config/mobile_runtime_config.dart'
if not loader.exists():
    loader.write_text("""import 'dart:convert';
import 'package:flutter/services.dart';

abstract final class MobileRuntimeConfig {
  static Map<String, dynamic> _values = const {};
  static Future<void> load() async {
    final decoded = jsonDecode(await rootBundle.loadString('assets/config/sitewise_dev.json'));
    if (decoded is! Map<String, dynamic>) throw const FormatException('Invalid SiteWise JSON config');
    _values = Map.unmodifiable(decoded);
  }
  static String value(String key, {String fallback = ''}) =>
      _values[key]?.toString().trim() ?? fallback;
  static bool boolean(String key, {bool fallback = false}) =>
      _values.containsKey(key) ? value(key).toLowerCase() == 'true' : fallback;
}
""", encoding='utf-8')

# 3. Change endpoint constants to getters, preserving original defaults.
p = 'fyp_mobile_app/lib/core/config/mobile_endpoints.dart'
edit(p, "import 'package:shared_logic/shared_logic.dart';",
        "import 'package:shared_logic/shared_logic.dart';\nimport 'mobile_runtime_config.dart';")
s = (root / p).read_text(encoding='utf-8')
a = '  static const String _apiOverride = String.fromEnvironment('
b = '  static Uri get profileUri =>'
if a in s:
    middle = s[s.index(a):s.index(b)]
    edit(p, middle, """  static String get _apiOverride => MobileRuntimeConfig.value(
    'API_BASE_URL', fallback: const String.fromEnvironment('API_BASE_URL'));
  static String get _webOverride => MobileRuntimeConfig.value(
    'WEB_BASE_URL', fallback: const String.fromEnvironment('WEB_BASE_URL'));
  static String get _hostMode => MobileRuntimeConfig.value(
    'API_HOST_MODE', fallback: const String.fromEnvironment('API_HOST_MODE', defaultValue: 'emulator'));
  static const _emulatorOrigin = 'http://10.0.2.2:8090';
  static const _adbReverseOrigin = 'http://127.0.0.1:8090';
  static String get apiBaseUrl => _apiOverride.isNotEmpty ? _apiOverride
      : (_hostMode == 'adb-reverse' ? _adbReverseOrigin : _emulatorOrigin);
  static String get webBaseUrl => _webOverride.isNotEmpty ? _webOverride : apiBaseUrl;
  static String get hostMode => _hostMode;

""")

# 4. Native Google Sign-In reads the same runtime JSON.
p = 'fyp_mobile_app/lib/data/repositories/supabase_auth_repository.dart'
edit(p, "import '../../core/config/mobile_endpoints.dart';",
        "import '../../core/config/mobile_endpoints.dart';\nimport '../../core/config/mobile_runtime_config.dart';")
edit(p, """  static const String _googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );
  static const String _googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
  );""", """  static String get _googleWebClientId => MobileRuntimeConfig.value(
    'GOOGLE_WEB_CLIENT_ID', fallback: const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'));
  static String get _googleIosClientId => MobileRuntimeConfig.value(
    'GOOGLE_IOS_CLIENT_ID', fallback: const String.fromEnvironment('GOOGLE_IOS_CLIENT_ID'));""")

# 5. Keep debug-only auth bypass guarded by kDebugMode.
edit('fyp_mobile_app/lib/core/config/dev_auth_bypass.dart',
"""import 'package:flutter/foundation.dart';

const bool _requested = bool.fromEnvironment(
  'SITEWISE_DEV_AUTH_BYPASS',
  defaultValue: false,
);

bool get devAuthBypassEnabled => kDebugMode && _requested;""",
"""import 'package:flutter/foundation.dart';
import 'mobile_runtime_config.dart';

bool get devAuthBypassEnabled => kDebugMode && MobileRuntimeConfig.boolean(
  'SITEWISE_DEV_AUTH_BYPASS',
  fallback: const bool.fromEnvironment('SITEWISE_DEV_AUTH_BYPASS', defaultValue: false));""")

# 6. Load before Supabase initialization and before ProviderScope overrides.
p = 'fyp_mobile_app/lib/main.dart'
edit(p, "import 'package:flutter_riverpod/flutter_riverpod.dart';",
        "import 'package:flutter_riverpod/flutter_riverpod.dart';\nimport 'package:shared_logic/shared_logic.dart';")
edit(p, "import 'core/config/mobile_config.dart';",
        "import 'core/config/mobile_config.dart';\nimport 'core/config/mobile_runtime_config.dart';")
edit(p, '  WidgetsFlutterBinding.ensureInitialized();\n  StartupTrace.start();',
"""  WidgetsFlutterBinding.ensureInitialized();
  await MobileRuntimeConfig.load();
  AppConfig.configureSupabase(
    url: MobileRuntimeConfig.value('SUPABASE_URL'),
    publishableKey: MobileRuntimeConfig.value('SUPABASE_PUBLISHABLE_KEY'));
  StartupTrace.start();""")

# 7. Register JSON as an asset, without removing existing images/models/fonts.
p = 'fyp_mobile_app/pubspec.yaml'
if '    - assets/config/sitewise_dev.json' not in (root / p).read_text(encoding='utf-8'):
    edit(p, '  assets:\n', '  assets:\n    - assets/config/sitewise_dev.json\n')

# 8. Copy JSON if provided; otherwise convert your existing local dev.env.
dest = mobile / 'assets/config/sitewise_dev.json'
if not dest.exists():
    source_json = mobile / 'config/sitewise_dev.json'
    if source_json.exists():
        config = json.loads(source_json.read_text(encoding='utf-8-sig'))
    else:
        env = mobile / 'config/dev.env'
        assert env.exists(), 'Missing config: put sitewise_dev.json in fyp_mobile_app/config/ first.'
        config = {}
        for line in env.read_text(encoding='utf-8-sig').splitlines():
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                key, value = line.split('=', 1)
                config[key.strip()] = value.strip()
    assert all(config.get(k) for k in ('SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'API_BASE_URL')), 'Missing required config values.'
    assert 'service_role' not in str(config['SUPABASE_PUBLISHABLE_KEY']).lower() and not str(config['SUPABASE_PUBLISHABLE_KEY']).startswith('sb_secret_'), 'Do not bundle a service-role key.'
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
    print('Generated', dest.relative_to(root))

# 9. Remove the old IDE additional argument.
ide = root / '.idea/runConfigurations/main_dart.xml'
if ide.is_file():
    old = ide.read_text(encoding='utf-8-sig')
    new = ''.join(line for line in old.splitlines(True)
                  if not ('name="additionalArgs"' in line and '--dart-define-from-file' in line))
    if new != old:
        shutil.copy2(ide, ide.with_name(ide.name + '.backup'))
        ide.write_text(new, encoding='utf-8')
        print('Cleared Android Studio additionalArgs')

ignore = root / '.gitignore'
if ignore.exists():
    ignored = ignore.read_text(encoding='utf-8-sig')
    item = '/fyp_mobile_app/assets/config/sitewise_dev.json'
    if item not in ignored:
        ignore.write_text(ignored.rstrip('\n') + '\n' + item + '\n', encoding='utf-8')

print('\nDONE. Run flutter pub get once, then click Run in Android Studio.')
print('For USB phone connectivity, keep the server and adb reverse :8090 running.')
