import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Which auth view the mobile auth page is showing.

enum AuthTab { login, signUp }

/// Segmented Log In / Sign Up switch.
class AuthTabs extends StatelessWidget {
  final AuthTab tab;
  final ValueChanged<AuthTab> onChanged;

  const AuthTabs({super.key, required this.tab, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 45,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F7),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Expanded(
            child: _AuthTab(
              selected: tab == AuthTab.login,
              label: 'Log In',
              onTap: () => onChanged(AuthTab.login),
            ),
          ),
          Expanded(
            child: _AuthTab(
              selected: tab == AuthTab.signUp,
              label: 'Sign Up',
              onTap: () => onChanged(AuthTab.signUp),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthTab extends StatelessWidget {
  final bool selected;
  final String label;
  final VoidCallback onTap;

  const _AuthTab({
    required this.selected,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? Colors.white : Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: selected ? SitewiseColors.action : SitewiseColors.muted,
          ),
        ),
      ),
    ),
  );
}
