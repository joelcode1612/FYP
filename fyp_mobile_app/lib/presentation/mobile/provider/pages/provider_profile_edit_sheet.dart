import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';

/// Edit Profile sheet for the Owner / Agent workspace.
///
/// Edits ONLY the fields the backend authorizes for self-service through
/// `PATCH /api/v1/users/me` — `full_name` and `phone_number`. Role, account
/// status, email verification, professional verification status and listing
/// ownership approval are server-authoritative; the backend answers 403 if a
/// client attempts them, so they are not editable fields here.
///
/// The profile picture is deliberately excluded: the backend accepts the URL
/// but this build has no image-upload pipeline, so offering the field would
/// promise an edit it cannot deliver.
class ProviderProfileEditSheet extends StatefulWidget {
  const ProviderProfileEditSheet({
    super.key,
    required this.currentName,
    required this.currentPhone,
  });

  /// Current server values, shown as the starting point of each field.
  final String currentName;
  final String currentPhone;

  /// Opens the sheet. Resolves `true` when the server accepted an update, so
  /// the caller can reload the profile; `false` when it was dismissed.
  static Future<bool> show(
    BuildContext context, {
    required String currentName,
    required String currentPhone,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SitewiseM3.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => ProviderProfileEditSheet(
        currentName: currentName,
        currentPhone: currentPhone,
      ),
    );
    return result == true;
  }

  @override
  State<ProviderProfileEditSheet> createState() =>
      _ProviderProfileEditSheetState();
}

class _ProviderProfileEditSheetState extends State<ProviderProfileEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.currentName);
  late final TextEditingController _phone =
      TextEditingController(text: widget.currentPhone);
  bool _saving = false;
  String? _error;

  static final RegExp _phonePattern = RegExp(r'^\+?[0-9][0-9\s()\-.]{5,19}$');

  String? _validateName(String? value) {
    final name = value?.trim() ?? '';
    if (name.isEmpty) return 'Please enter your full name.';
    if (name.length < 2) return 'Please enter your full name.';
    if (name.length > 120) return 'Name must be 120 characters or fewer.';
    return null;
  }

  String? _validatePhone(String? value) {
    final phone = value?.trim() ?? '';
    if (phone.isEmpty) return null; // Optional field.
    if (!_phonePattern.hasMatch(phone)) {
      return 'Enter a valid phone number, e.g. +60 12-345 6789.';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ServiceLocator.apiClient.patch('/api/v1/users/me', {
        'full_name': _name.text.trim(),
        'phone_number': _phone.text.trim(),
      });
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _friendlyError(error);
      });
    }
  }

  /// The transport collapses server detail into the message; surface the
  /// meaningful sentence rather than the exception type.
  static String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('403') || text.toLowerCase().contains('cannot')) {
      return 'The server refused this change: $text';
    }
    if (text.contains('SocketException') ||
        text.contains('Connection refused') ||
        text.contains('Failed host lookup')) {
      return 'Could not reach SiteWise. Check your connection and try again.';
    }
    return 'Could not save your profile: $text';
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      // Keyboard handling: keep the form above the keyboard, and the sheet
      // content inside the safe area.
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Edit profile',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: SitewiseM3.ink,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close_rounded, size: 20),
                      style: IconButton.styleFrom(
                        backgroundColor: SitewiseM3.quiet,
                        foregroundColor: SitewiseM3.ink,
                        minimumSize: const Size(36, 36),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Only the details SiteWise lets you change are editable. '
                  'Verification and account role are managed by SiteWise.',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    height: 1.5,
                    color: SitewiseM3.muted,
                  ),
                ),
                const SizedBox(height: 16),
                _label('Full name'),
                const SizedBox(height: 7),
                TextFormField(
                  controller: _name,
                  enabled: !_saving,
                  maxLength: 120,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: _validateName,
                  textCapitalization: TextCapitalization.words,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    color: SitewiseM3.ink,
                  ),
                  decoration: _decoration('Your full name', 120),
                ),
                const SizedBox(height: 6),
                _label('Phone number'),
                const SizedBox(height: 7),
                TextFormField(
                  controller: _phone,
                  enabled: !_saving,
                  maxLength: 20,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: _validatePhone,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    color: SitewiseM3.ink,
                  ),
                  decoration: _decoration('e.g. +60 12-345 6789', 20),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: SitewiseColors.dangerWash,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12,
                        height: 1.45,
                        color: SitewiseColors.danger,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: SitewiseM3.ink,
                          minimumSize: const Size(0, 48),
                          side: const BorderSide(color: SitewiseM3.line),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: SitewiseColors.action,
                          foregroundColor: SitewiseM3.surface,
                          disabledBackgroundColor: SitewiseM3.quiet,
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: SitewiseColors.action,
                                ),
                              )
                            : const Text('Save changes'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      fontFamily: kFontFamily,
      fontSize: 12,
      fontWeight: FontWeight.w800,
      color: SitewiseM3.ink,
    ),
  );

  InputDecoration _decoration(String hint, int maxLength) => InputDecoration(
    hintText: hint,
    counterText: '',
    filled: true,
    fillColor: SitewiseM3.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SitewiseM3.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SitewiseM3.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SitewiseColors.action, width: 1.6),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SitewiseColors.danger),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SitewiseColors.danger, width: 1.6),
    ),
    errorStyle: const TextStyle(
      fontFamily: kFontFamily,
      fontSize: 11,
      color: SitewiseColors.danger,
    ),
  );
}
