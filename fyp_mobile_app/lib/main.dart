
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'application/providers.dart';
import 'core/bootstrap/app_bootstrap.dart';
import 'core/bootstrap/startup_trace.dart';
import 'core/config/mobile_config.dart';
import 'core/config/mobile_runtime_config.dart';
import 'core/routing/app_routes.dart';
import 'core/theme/sitewise_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load runtime JSON BEFORE Supabase and providers.
  try {
    await MobileRuntimeConfig.load();
  } catch (error) {
    debugPrint(
      'SiteWise: configuration asset loading failed '
          '(${error.runtimeType}).',
    );
  }

  // Copy JSON settings into the shared configuration.
  AppConfig.configureSupabase(
    url: MobileRuntimeConfig.value('SUPABASE_URL'),
    publishableKey: MobileRuntimeConfig.value(
      'SUPABASE_PUBLISHABLE_KEY',
    ),
  );

  // Safe diagnostics: never print the key itself.
  debugPrint(
    'SiteWise JSON configuration: '
        'urlPresent=${AppConfig.supabaseUrl.isNotEmpty}, '
        'keyPresent=${AppConfig.supabaseAnonKey.isNotEmpty}',
  );

  StartupTrace.start();

  WidgetsBinding.instance.addPostFrameCallback((_) {
    StartupTrace.mark('first_frame');
    StartupTrace.report('first_frame');
  });

  // Initialize Supabase only once.
  AppBootstrap.start();

  debugPrint(MobileConfig.statusLine);

  runApp(
    ProviderScope(
      overrides: sitewiseOverrides(),
      child: const SitewiseApp(),
    ),
  );
}

class SitewiseApp extends StatelessWidget {
  const SitewiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sitewise — F&B Location Intelligence',
      debugShowCheckedModeBanner: false,
      theme: sitewiseTheme(),
      initialRoute: '/',
      onGenerateRoute: AppRoutes.onGenerateRoute,
      onGenerateInitialRoutes:
      AppRoutes.generateInitialRoutes,
    );
  }
}
