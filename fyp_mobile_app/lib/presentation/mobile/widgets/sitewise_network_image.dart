import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Network image with bounded automatic recovery, built on the platform's own
/// image cache (`Image.network`) — no new dependency.
///
/// Lifecycle:
///  1. **Placeholder** renders while the first attempt loads.
///  2. A failed load retries automatically up to [maxAttempts] with
///     exponential backoff plus jitter (bounded — no infinite loops, no
///     request storms). Only network-shaped failures retry; a syntactically
///     invalid URL never reaches the network and renders the fallback at
///     once.
///  3. After the retry budget is spent, [fallback] (or a built-in neutral
///     panel) renders with a manual **Tap to retry** affordance — the user is
///     never shown stack traces, HTTP codes or provider details.
///  4. Pending backoff timers are cancelled in [dispose], so a screen that
///     pops cannot fire setState-after-dispose or keep downloading.
///  5. [cacheKey] lets an upload flow invalidate a stale cached image: pass
///     the replacement's identity (e.g. upload timestamp) and the framework
///     treats it as a different image.
///
/// Every retry re-resolves through `Image.network`, whose HTTP cache still
/// serves unchanged images — so navigation refetches are cheap and already
/// loaded images survive parent rebuilds (the widget keeps its own attempt
/// state across rebuilds via the [State] lifecycle).
class SitewiseNetworkImage extends StatefulWidget {
  /// The image URL. Empty or non-http(s) values render the fallback
  /// immediately without touching the network.
  final String? url;

  final double? width;
  final double? height;
  final BoxFit fit;

  /// Shown during loading and as the backdrop behind the image.
  final Widget? placeholder;

  /// Shown when every attempt failed, the URL is invalid, or the caller
  /// supplied none. Defaults to a neutral on-brand panel with a manual retry.
  final Widget? fallback;

  /// Automatic retry budget. Defaults to 3 (4 attempts total with the first).
  final int maxAttempts;

  /// Base delay for the exponential backoff (doubled each attempt, jittered).
  final Duration baseDelay;

  /// Optional cache-busting identity: when it changes, the widget reloads and
  /// the image cache misses — exactly what a replaced image needs.
  final Object? cacheKey;

  /// Accessible label for the fallback state.
  final String? semanticLabel;

  const SitewiseNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.fallback,
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 600),
    this.cacheKey,
    this.semanticLabel,
  });

  /// True when [url] is a loadable http(s) URL.
  static bool isValidUrl(String? url) {
    if (url == null) return false;
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    return uri != null && (uri.isScheme('http') || uri.isScheme('https'));
  }

  @override
  State<SitewiseNetworkImage> createState() => _SitewiseNetworkImageState();
}

class _SitewiseNetworkImageState extends State<SitewiseNetworkImage> {
  /// Attempt the current load is on (1-based). Incremented by failures.
  int _attempt = 1;

  /// False once every attempt failed and only manual retry can recover.
  bool _exhausted = false;

  /// Set by the manual retry affordance.
  int _manualEpoch = 0;

  Timer? _backoffTimer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (!SitewiseNetworkImage.isValidUrl(widget.url)) _exhausted = true;
  }

  @override
  void didUpdateWidget(covariant SitewiseNetworkImage old) {
    super.didUpdateWidget(old);
    final urlChanged = widget.url != old.url;
    final keyChanged = widget.cacheKey != old.cacheKey;
    if (!urlChanged && !keyChanged) return;
    // A replaced image must never keep showing the old cached content.
    _backoffTimer?.cancel();
    _attempt = 1;
    _manualEpoch++;
    _exhausted = !SitewiseNetworkImage.isValidUrl(widget.url);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _backoffTimer?.cancel();
    super.dispose();
  }

  void _onError(Object error, StackTrace? stack) {
    if (_disposed || !mounted) return;
    if (_attempt >= widget.maxAttempts + 1) {
      // Retry budget spent: stop here. The fallback carries a manual retry,
      // so recovery stays possible without an uncontrolled loop.
      setState(() => _exhausted = true);
      return;
    }
    final attempt = ++_attempt;
    // Exponential backoff with jitter, capped at 4× the base delay so a long
    // outage cannot stack multi-second timers behind each other pointlessly.
    final exponential = widget.baseDelay * (1 << (attempt - 1).clamp(0, 2));
    final jittered = exponential * (0.85 + 0.30 * Random(attempt).nextDouble());
    _backoffTimer = Timer(jittered, () {
      if (_disposed || !mounted) return;
      // Bump the epoch into the image URL's key so Image.network re-attempts
      // instead of replaying a cached failure.
      setState(() {});
    });
  }

  /// Fills the box with the neutral on-brand panel and the manual retry.
  Widget _fallbackBox(BuildContext context) {
    final supplied = widget.fallback;
    if (supplied != null && _attempt <= 1) return supplied;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _exhausted
          ? () {
              if (_disposed || !mounted) return;
              setState(() {
                _exhausted = false;
                _attempt = 1;
                _manualEpoch++;
              });
            }
          : null,
      child: Container(
        color: SitewiseColors.surface,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _exhausted ? Icons.image_not_supported_outlined : Icons.image_outlined,
              size: 28,
              color: SitewiseColors.muted,
            ),
            const SizedBox(height: 6),
            Text(
              _exhausted ? 'Image not available. Tap to retry' : 'Loading image…',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: SitewiseColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url?.trim();
    if (_exhausted || !SitewiseNetworkImage.isValidUrl(url)) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: Semantics(
          label: widget.semanticLabel,
          child: widget.fallback ?? _fallbackBox(context),
        ),
      );
    }

    // cacheKey participates in the framework's cache identity: a new key
    // after a replacement upload forces a real fetch, so a stale image can
    // never survive a successful update.
    final cacheKey =
        '${url!}|${widget.cacheKey ?? ''}|retry:$_attempt|epoch:$_manualEpoch';

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Image.network(
        url,
        key: ValueKey(cacheKey),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        semanticLabel: widget.semanticLabel,
        // Loading placeholder: the caller's or the neutral panel.
        frameBuilder: (context, child, frame, wasSyncLoaded) {
          if (wasSyncLoaded || frame != null) return child;
          return widget.placeholder ?? _fallbackBox(context);
        },
        errorBuilder: (context, error, stackTrace) {
          _onError(error, stackTrace);
          // Render the loading/fallback surface for this frame; the backoff
          // timer (or manual retry) drives the next attempt.
          return _exhausted
              ? (widget.fallback ?? _fallbackBox(context))
              : _fallbackBox(context);
        },
      ),
    );
  }
}
