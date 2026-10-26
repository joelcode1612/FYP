// Ad-hoc check for `splitGraphemes` — the Unicode splitter behind
// `LetterRevealHeading`. Run with:
//
//   dart run tool/lr_grapheme_check.dart
//
// It prints the grapheme split for short text, long text, punctuation,
// diacritics, CJK, emoji with modifiers, and ZWJ/flag sequences so the
// behaviour can be inspected without a browser.
import 'package:sitewise_jaspr_web/components/letter_reveal.dart';

void check(String label, String input, int expected) {
  final parts = splitGraphemes(input);
  final ok = parts.length == expected;
  final rendered = parts.map((p) => '[$p]').join();
  print(
    '${ok ? 'PASS' : 'FAIL'}  $label  n=${parts.length} expected=$expected',
  );
  print('      $rendered');
}

void main() {
  check('short word', 'Hello', 5);
  check('punctuation', 'Hi, there!', 10);
  check(
    'long sentence',
    'Choosing a location is more than choosing a property.',
    53,
  );
  check('multiline source (newline kept as char)', 'Line one\nLine two', 17);
  check('precomposed accents', 'Café', 4);
  check('combining accent', 'Cafe\u0301', 4);
  check('CJK', '你好世界', 4);
  check('emoji (single code point)', '🚀', 1);
  check('emoji + skin tone', '👍🏽', 1);
  check('ZWJ family', '👨\u200D👩\u200D👧\u200D👦', 1);
  check('flag (regional indicators)', '🇲🇾', 1);
  check('mixed', 'Hi 你好 🚀', 7);
}
