import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/sitewise_button.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile admin profile: full-width account card.

class AdminProfileMobilePage extends StatelessWidget {
  final AppCubit appState;
  const AdminProfileMobilePage({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      appState: appState,
      title: 'Profile',
      currentRoute: '/admin/profile',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CircleAvatar(
                  radius: 30,
                  child: Text('A', style: TextStyle(fontSize: 24)),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Aina Razak',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
                ),
                const Text('aina@sitewise.my · Administrator'),
                const SizedBox(height: 16),
                const TextField(
                  decoration: InputDecoration(labelText: 'Display name'),
                ),
                const SizedBox(height: 12),
                const TextField(
                  decoration: InputDecoration(labelText: 'Contact number'),
                ),
                const SizedBox(height: 16),
                SitewiseButton(
                  label: 'Save changes',
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Profile updated.')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
