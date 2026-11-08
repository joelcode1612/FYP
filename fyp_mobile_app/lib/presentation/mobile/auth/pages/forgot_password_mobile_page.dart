import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/config/mobile_endpoints.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_brand.dart';
import '../../../shared/widgets/sitewise_cta_button.dart';
import '../widgets/auth_field.dart';

/// Password recovery.
///
/// Supabase issues the reset email; the link itself is handled by the SiteWise
/// web portal because this build registers no OAuth deep link. Saying so is
/// part of the screen — a button that silently "resets" nothing would be a
/// fake, and the user would wait for an email they cannot use.
class ForgotPasswordMobilePage extends ConsumerStatefulWidget {
  const ForgotPasswordMobilePage({super.key});

  @override
  ConsumerState<ForgotPasswordMobilePage> createState() =>
      _ForgotPasswordMobilePageState();
}

class _ForgotPasswordMobilePageState
    extends ConsumerState<ForgotPasswordMobilePage> {
  final _email = TextEditingController();
  bool _loading = false;
  String? _result;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (!email.contains('@') || email.endsWith('@')) {
      setState(() => _result = 'Please enter a valid email address.');
      return;
    }
    setState(() {
      _loading = true;
      _result = null;
    });
    final message = await ref
        .read(authNotifierProvider.notifier)
        .recoverPassword(email);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _result = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SitewiseColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Reset your password',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: SitewiseColors.ink,
                        letterSpacing: -.7,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'We will email a link to the address on your Sitewise '
                      'account.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: SitewiseColors.muted,
                      ),
                    ),
                    const SizedBox(height: 21),
                    AuthField(
                      label: 'Email address',
                      controller: _email,
                      hint: 'Enter your email',
                      icon: Icons.mail_outline_rounded,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 20),
                    SitewiseCtaButton(
                      label: _loading ? 'Sending…' : 'Send reset link',
                      onPressed: _loading ? null : _submit,
                    ),
                    if (_result != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: SitewiseColors.geoWash,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: SitewiseColors.geoBorder),
                        ),
                        child: Text(
                          _result!,
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: SitewiseColors.ink,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Open the link on this device to finish in the '
                        'SiteWise web portal: ${MobileEndpoints.webBaseUrl}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: SitewiseColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: Row(
        children: [
          Material(
            color: Colors.white,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.of(context).maybePop(),
              child: const SizedBox(
                width: 40,
                height: 40,
                child: Icon(Icons.arrow_back_rounded, size: 19),
              ),
            ),
          ),
          const Spacer(),
          const SitewiseBrand(),
          const Spacer(),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}
