import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// A run of text inside a [LetterRevealHeading].
///
/// `tag` keeps inline semantics intact — the landing hero wraps its second half
/// in `<em>` — while the run still participates in the same character stagger.
class LetterRun {
  const LetterRun(this.text, {this.tag});

  final String text;

  /// `null` renders bare characters. `'em'`, `'strong'`, `'b'` and `'span'`
  /// wrap the run so existing inline styling is preserved.
  final String? tag;
}

/// Per-character reveal for headings.
///
/// ## Why the spans live in the component tree
///
/// Jaspr hydrates the server-rendered DOM and later reconciles it on `setState`.
/// If a script split the heading text into spans *after* hydration, the virtual
/// DOM (plain text) and the real DOM (spans) would disagree and the reconciler
/// could fail. Rendering the spans here means the server and the client emit
/// identical markup, so hydration and re-renders are unaffected. JavaScript
/// only toggles the `is-armed` / `is-visible` classes.
///
/// ## Usage
///
/// ```dart
/// // Above the fold — animates when mounted (pure CSS, no flash).
/// LetterRevealHeading(
///   level: 1,
///   classes: 'page-head__title',
///   runs: [LetterRun(title)],
/// )
///
/// // Further down — animates when scrolled into view.
/// LetterRevealHeading(
///   level: 2,
///   id: 'sectionTitle',
///   runs: const [LetterRun('See what surrounds each property.')],
///   animateOnLoad: false,
/// )
/// ```
///
/// ## Accessibility
///
/// The heading carries `aria-label` with the complete text and the visual
/// character spans are `aria-hidden`, so a screen reader announces one phrase
/// rather than one item per character. Under `prefers-reduced-motion: reduce`
/// the stylesheet never hides the characters. If JavaScript is unavailable the
/// scroll variant is never armed, so the text is simply visible.
class LetterRevealHeading extends StatelessComponent {
  /// Heading level, 1–6. Anything outside that range falls back to `<h6>`.
  final int level;

  final String? id;

  /// Existing classes for the heading (e.g. `page-head__title`).
  final String? classes;

  final List<LetterRun> runs;

  /// `true` → play on mount via CSS (`lr--load`).
  /// `false` → play when scrolled into view via `web/reveal.js` (`lr--scroll`).
  final bool animateOnLoad;

  /// Renders plain, unstyled text with no spans — an explicit opt-out.
  final bool disabled;

  /// Requested stagger between characters, in milliseconds.
  final int staggerMs;

  /// Per-character transition duration, in milliseconds.
  final int durationMs;

  /// Delay before the first character, in milliseconds.
  final int delayMs;

  /// Upper bound for the whole sequence, in milliseconds. Long headings get a
  /// proportionally smaller stagger so they never take longer than this.
  final int maxTotalMs;

  /// Extra attributes for the heading. `aria-label` and `style` are managed by
  /// this component and will override values supplied here.
  final Map<String, String> attributes;

  const LetterRevealHeading({
    super.key,
    required this.level,
    required this.runs,
    this.id,
    this.classes,
    this.animateOnLoad = true,
    this.disabled = false,
    this.staggerMs = 30,
    this.durationMs = 420,
    this.delayMs = 0,
    this.maxTotalMs = 900,
    this.attributes = const {},
  });

  /// Convenience constructor for a single unstyled run.
  factory LetterRevealHeading.text(
    String text, {
    Key? key,
    required int level,
    String? id,
    String? classes,
    bool animateOnLoad = true,
    bool disabled = false,
    int staggerMs = 30,
    int durationMs = 420,
    int delayMs = 0,
    int maxTotalMs = 900,
    Map<String, String> attributes = const {},
  }) => LetterRevealHeading(
    key: key,
    level: level,
    runs: [LetterRun(text)],
    id: id,
    classes: classes,
    animateOnLoad: animateOnLoad,
    disabled: disabled,
    staggerMs: staggerMs,
    durationMs: durationMs,
    delayMs: delayMs,
    maxTotalMs: maxTotalMs,
    attributes: attributes,
  );

  @override
  Component build(BuildContext context) {
    final fullText = runs.map((r) => r.text).join();

    if (disabled) {
      final cls = (classes ?? '').trim();
      return _heading(cls.isEmpty ? null : cls, const {}, [
        Component.text(fullText),
      ]);
    }

    final cls = [
      if (classes != null && classes!.trim().isNotEmpty) classes!.trim(),
      'lr',
      animateOnLoad ? 'lr--load' : 'lr--scroll',
    ].join(' ');

    final step = _effectiveStep(_graphemeCount(fullText));
    final attrs = <String, String>{
      ...attributes,
      'aria-label': fullText,
      'style':
          '--lr-step:${step}ms;--lr-dur:${durationMs}ms;'
          '--lr-delay:${delayMs}ms',
    };

    final inner = <Component>[];
    var index = 0;
    for (final run in runs) {
      final spans = _spans(run.text, index);
      index += _graphemeCount(run.text);
      final tag = run.tag;
      if (tag == null) {
        inner.addAll(spans);
      } else {
        inner.add(_wrap(tag, spans));
      }
    }

    return _heading(cls, attrs, [
      span(
        classes: 'lr-inner',
        attributes: const {'aria-hidden': 'true'},
        inner,
      ),
    ]);
  }

  Component _heading(
    String? cls,
    Map<String, String> attrs,
    List<Component> children,
  ) => switch (level) {
    1 => h1(id: id, classes: cls, attributes: attrs, children),
    2 => h2(id: id, classes: cls, attributes: attrs, children),
    3 => h3(id: id, classes: cls, attributes: attrs, children),
    4 => h4(id: id, classes: cls, attributes: attrs, children),
    5 => h5(id: id, classes: cls, attributes: attrs, children),
    _ => h6(id: id, classes: cls, attributes: attrs, children),
  };

  static Component _wrap(String tag, List<Component> children) => switch (tag) {
    'em' => em(children),
    'strong' => strong(children),
    'b' => b(children),
    _ => span(children),
  };

  /// Builds the word/character spans for [text], starting the stagger at
  /// [start]. Spaces stay as plain text nodes so wrapping and `word-spacing`
  /// behave exactly as they did before.
  List<Component> _spans(String text, int start) {
    final out = <Component>[];
    var i = start;
    final word = <String>[];

    void flush() {
      if (word.isEmpty) return;
      out.add(
        span(classes: 'lr-word', [
          for (final ch in word)
            span(
              classes: 'lr-char',
              attributes: {'style': '--i:${i++}'},
              [Component.text(ch)],
            ),
        ]),
      );
      word.clear();
    }

    for (final ch in splitGraphemes(text)) {
      if (ch == ' ') {
        flush();
        out.add(Component.text(' '));
        i++;
      } else {
        word.add(ch);
      }
    }
    flush();
    return out;
  }

  /// Caps the stagger so a long heading finishes within [maxTotalMs].
  int _effectiveStep(int count) {
    if (count <= 1) return 0;
    final cap = maxTotalMs ~/ (count - 1);
    final step = staggerMs < cap ? staggerMs : cap;
    return step < 3 ? 3 : step;
  }

  static int _graphemeCount(String text) => splitGraphemes(text).length;
}

/// Splits [text] into user-perceived characters without a dependency.
///
/// Iterating `runes` (not `split('')`) keeps astral characters — most emoji —
/// intact, and combining marks, variation selectors and ZWJ sequences stay
/// attached to their base character. CJK text is one code point per glyph and
/// passes through unchanged.
List<String> splitGraphemes(String text) {
  final out = <String>[];
  var buffer = StringBuffer();
  var afterZwj = false;

  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (buffer.isEmpty) {
      buffer.write(ch);
    } else if (afterZwj ||
        _isCombiningMark(rune) ||
        _isVariationSelector(rune) ||
        _isEmojiModifier(rune) ||
        (_isRegionalIndicator(rune) && _isSingleRegionalIndicator(buffer)) ||
        rune == 0x200D) {
      buffer.write(ch);
    } else {
      out.add(buffer.toString());
      buffer = StringBuffer(ch);
    }
    afterZwj = rune == 0x200D;
  }
  if (buffer.isNotEmpty) out.add(buffer.toString());
  return out;
}

bool _isVariationSelector(int rune) =>
    (rune >= 0xFE00 && rune <= 0xFE0F) || (rune >= 0xE0100 && rune <= 0xE01EF);

/// Skin-tone modifiers (U+1F3FB–U+1F3FF) belong to the emoji they follow.
bool _isEmojiModifier(int rune) => rune >= 0x1F3FB && rune <= 0x1F3FF;

/// Regional indicators (U+1F1E6–U+1F1FF) pair up into flag glyphs.
bool _isRegionalIndicator(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;

bool _isSingleRegionalIndicator(StringBuffer buffer) {
  final runes = buffer.toString().runes.toList();
  return runes.length == 1 && _isRegionalIndicator(runes.first);
}

/// Common combining-mark blocks (diacritics, enclosing marks, half marks).
/// A compact table is enough here; full Unicode segmentation would need a
/// dependency this project does not carry.
bool _isCombiningMark(int rune) =>
    (rune >= 0x0300 && rune <= 0x036F) ||
    (rune >= 0x1AB0 && rune <= 0x1AFF) ||
    (rune >= 0x1DC0 && rune <= 0x1DFF) ||
    (rune >= 0x20D0 && rune <= 0x20FF) ||
    (rune >= 0xFE20 && rune <= 0xFE2F);
