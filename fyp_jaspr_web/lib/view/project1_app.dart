import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/question.dart';
import '../model/questionnaire_state.dart';
import '../viewmodel/questionnaire_viewmodel.dart';
import 'components.dart';
import 'welcome_page.dart';
import 'question_page.dart';
import 'review_page.dart';

class Project1App extends ConsumerWidget {
  const Project1App({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(questionnaireProvider);
    return MaterialApp(
      title: 'Project1 Customer · Demo',
      debugShowCheckedModeBanner: false,
      locale: Locale(state.language == AppLanguage.en ? 'en' : 'ms'),
      supportedLocales: const [Locale('en'), Locale('ms')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        fontFamily: 'ProjectRoboto',
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFCFDFF),
        colorScheme: ColorScheme.fromSeed(
          seedColor: navy,
          primary: blue,
          surface: Colors.white,
        ),
        textTheme: ThemeData.light().textTheme.apply(
          fontFamily: 'ProjectRoboto',
          bodyColor: ink,
          displayColor: ink,
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: navy,
            minimumSize: const Size(44, 52),
            side: const BorderSide(color: Color(0xFF91A6C2)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
      home: PopScope(
        canPop: state.page == SurveyPage.welcome,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && state.page != SurveyPage.submitted) {
            ref.read(questionnaireProvider.notifier).previous();
          }
        },
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: switch (state.page) {
                  SurveyPage.welcome => const WelcomePage(),
                  SurveyPage.question => const QuestionPage(),
                  SurveyPage.review => const ReviewPage(),
                  SurveyPage.submitted => const DemoSubmittedPage(),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
