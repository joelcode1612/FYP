import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Terms of Service / Privacy Policy consent row for Sign Up.
///
/// [onOpenTerms] / [onOpenPrivacy] are optional: the mobile app has no
/// bundled legal pages yet, so the caller supplies the graceful fallback. The
/// linked words are still real tap targets (not coloured plain text), and the
/// gesture recognizers are disposed with the widget.
class AuthTermsRow extends StatefulWidget {
  const AuthTermsRow({
    super.key,
    required this.value,
    required this.onChanged,
    this.onOpenTerms,
    this.onOpenPrivacy,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onOpenTerms;
  final VoidCallback? onOpenPrivacy;

  @override
  State<AuthTermsRow> createState() => _AuthTermsRowState();
}

class _AuthTermsRowState extends State<AuthTermsRow> {
  late final TapGestureRecognizer _termsRecognizer;
  late final TapGestureRecognizer _privacyRecognizer;

  @override
  void initState() {
    super.initState();
    _termsRecognizer = TapGestureRecognizer()
      ..onTap = () => _openDocument('Terms of Service', widget.onOpenTerms);
    _privacyRecognizer = TapGestureRecognizer()
      ..onTap = () => _openDocument('Privacy Policy', widget.onOpenPrivacy);
  }

  @override
  void dispose() {
    _termsRecognizer.dispose();
    _privacyRecognizer.dispose();
    super.dispose();
  }

  /// No legal pages are bundled in the mobile app yet. When the caller has
  /// not supplied a destination, say so honestly instead of leaving a dead
  /// link (or silently pretending the document opened).
  void _openDocument(String document, VoidCallback? onOpen) {
    if (onOpen != null) {
      onOpen();
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(document),
        content: Text(
          'The $document is not bundled in the mobile app yet. '
          'Please contact SiteWise support for a copy.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Checkbox(
        value: widget.value,
        onChanged: (v) => widget.onChanged(v ?? false),
        activeColor: SitewiseColors.action,
        visualDensity: VisualDensity.compact,
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text.rich(
            TextSpan(
              style: const TextStyle(
                fontSize: 11.3,
                height: 1.35,
                color: SitewiseColors.muted,
              ),
              children: <InlineSpan>[
                const TextSpan(text: 'I agree to the '),
                TextSpan(
                  text: 'Terms of Service',
                  recognizer: _termsRecognizer,
                  style: const TextStyle(
                    color: SitewiseColors.action,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(text: ' and '),
                TextSpan(
                  text: 'Privacy Policy',
                  recognizer: _privacyRecognizer,
                  style: const TextStyle(
                    color: SitewiseColors.action,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(text: '.'),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}
