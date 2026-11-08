import 'question.dart';

/// MOCK-UI-1 is a UI demonstration. It neither calls nor configures C0/C1.
class MockRouting {
  static const affiliationCodes = {
    'LIVE',
    'WORK',
    'STUDY',
    'RUN_BUSINESS',
    'VISIT_PURPOSE',
    'PASS_THROUGH',
  };
  static const purchaseCodes = {'ONE', 'TWO_THREE', 'FOUR_SEVEN', 'EIGHT_PLUS'};

  static bool hasDemoAffiliation(Map<String, Answer> answers) =>
      answers['Q01']?.codes.any(affiliationCodes.contains) ?? false;

  static bool hasPastPurchase(Map<String, Answer> answers) =>
      answers['Q04']?.codes.any(purchaseCodes.contains) ?? false;

  static LocalText? exclusion(
    String id,
    Map<String, Answer> answers,
    DemoConfig config,
  ) {
    if (id == 'Q01' || id == 'Q02') return null;
    if (!hasDemoAffiliation(answers)) {
      return const LocalText(
        'No affiliation selected in Q01 under the mock screen rule.',
        'Tiada hubungan dipilih dalam Q01 mengikut peraturan saringan contoh.',
      );
    }
    if (['Q11', 'Q12', 'Q13'].contains(id) && !config.optionalQuestions) {
      return const LocalText(
        'Optional context disabled in demo settings.',
        'Konteks pilihan dimatikan dalam tetapan contoh.',
      );
    }
    if (['Q03', 'Q05', 'Q06', 'Q07', 'Q09', 'Q10', 'Q11', 'Q13'].contains(id) &&
        !config.concept) {
      return const LocalText(
        'Demo café concept is unavailable.',
        'Konsep kafe contoh tidak tersedia.',
      );
    }
    if (id == 'Q06' && !config.menu) {
      return const LocalText(
        'Demo menu unavailable.',
        'Menu contoh tidak tersedia.',
      );
    }
    if (['Q07', 'Q13'].contains(id) && !config.offer) {
      return const LocalText(
        'Defined demo offer unavailable.',
        'Tawaran contoh khusus tidak tersedia.',
      );
    }
    if (id == 'Q08' && !hasPastPurchase(answers)) {
      return const LocalText(
        'Q04 has no qualifying positive past-purchase band.',
        'Q04 tiada julat pembelian lalu positif yang berkenaan.',
      );
    }
    if (id == 'Q09' && !config.occasions) {
      return const LocalText(
        'Demo future-occasion module disabled.',
        'Modul tujuan lawatan akan datang dimatikan.',
      );
    }
    if (id == 'Q10' && !config.features) {
      return const LocalText(
        'Synthetic feature bank unavailable.',
        'Bank ciri rekaan tidak tersedia.',
      );
    }
    return null;
  }

  static List<Question> route(
    List<Question> bank,
    Map<String, Answer> answers,
    DemoConfig config,
  ) => List.unmodifiable(
    bank.where((q) => exclusion(q.id, answers, config) == null),
  );
}
