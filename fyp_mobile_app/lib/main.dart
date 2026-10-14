import 'package:shared_logic/shared_logic.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/material.dart';

import 'core/routing/app_routes.dart';
import 'core/theme/sitewise_theme.dart';

void main() {
  runApp(const SitewiseApp());
}

/// Root widget. Boots to the public landing page (/); role entry happens
/// through its Log In / Get Started actions. Holds the single [AppState]
/// (role, preview, saved, compare) and rebuilds the [MaterialApp] when it
/// changes.
class SitewiseApp extends StatefulWidget {
  const SitewiseApp({super.key});

  @override
  State<SitewiseApp> createState() => _SitewiseAppState();
}

class _SitewiseAppState extends State<SitewiseApp> {
  final AppCubit appState = AppCubit();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: appState,
      builder: (ctx, _) => MaterialApp(
        title: 'Sitewise — F&B Location Intelligence',
        debugShowCheckedModeBanner: false,
        theme: sitewiseTheme(),
        // '/' is the startup decision point (mobile onboarding / auth / role
        // home; web redirects to the public landing at '/landing').
        initialRoute: '/',
        onGenerateRoute: (settings) =>
            AppRoutes.onGenerateRoute(settings, appState),
      ),
    );
  }
}
