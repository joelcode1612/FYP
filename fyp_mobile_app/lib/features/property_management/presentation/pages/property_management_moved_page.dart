import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/shared/presentation/components/provider_ui.dart';

/// Reached only through a legacy deep link (`/entrepreneur/add-property`).
///
/// Property management moved to the Owner / Agent workspace, so an
/// Entrepreneur account is denied here rather than silently keeping a working
/// management form. A provider account is forwarded to the real flow.
///
/// The decision uses the backend-assigned role from the authenticated session;
/// no route argument or local flag can grant access.
class PropertyManagementMovedPage extends ConsumerWidget {
  const PropertyManagementMovedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authNotifierProvider).user?.role;
    final isProvider = role == AppRole.owner || role == AppRole.agent;

    return Scaffold(
      backgroundColor: providerCanvas,
      appBar: AppBar(
        backgroundColor: providerCanvas,
        elevation: 0,
        title: const Text(
          'Property management',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: providerInk,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ProviderMessage(
            icon: Icons.mobile_friendly_rounded,
            title: isProvider
                ? 'Continue in the provider workspace'
                : 'Property management is not available for this account',
            body: isProvider
                ? 'Adding and managing commercial properties now lives in the '
                      'Owner / Agent workspace.'
                : 'Entrepreneur accounts discover and assess properties. '
                      'Listing creation, media upload and submission belong to '
                      'a verified Property Owner / Agent account.',
          ),
          const SizedBox(height: 16),
          if (isProvider)
            FilledButton(
              onPressed: () => Navigator.of(context).pushReplacementNamed(
                '/provider/add-property',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: providerBrand,
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Open Add Property'),
            )
          else
            OutlinedButton(
              onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(
                '/entrepreneur',
                (_) => false,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Back to my workspace'),
            ),
        ],
      ),
    );
  }
}
