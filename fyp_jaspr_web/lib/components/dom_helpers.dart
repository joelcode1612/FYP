import 'package:jaspr/jaspr.dart';

/// Returns a single, always-present text node for [value].
///
/// Jaspr's server renderer drops an *empty* string (`text('')` produces no DOM
/// node), while the client creates an empty text node — that desyncs hydration.
/// And a child list that flips between `[]` and `[text]` makes Jaspr's
/// reconciler append a phantom duplicate node on `setState`.
///
/// Rendering one real text node at all times — a space when [value] is empty, so
/// both server and client agree and re-renders only *update* the node's content
/// rather than insert/remove — avoids both failure modes. Callers hide the empty
/// state with an `is-hidden` class (see `web/styles.css`).
Component textNode(String? value) =>
    Component.text(value == null || value.isEmpty ? ' ' : value);
