import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../application/services/service_locator.dart';
import '../../../core/config/mobile_config.dart';

final project1ReadRepositoryProvider = Provider<ApiProject1ReadRepository>(
  (ref) => ApiProject1ReadRepository(ServiceLocator.apiClient),
);

/// Local preview drafts never become invitations, consent or observations.
class CollectionAvailabilityPage extends ConsumerStatefulWidget {
  const CollectionAvailabilityPage({super.key});
  @override
  ConsumerState<CollectionAvailabilityPage> createState() => _CollectionAvailabilityState();
}

class _CollectionAvailabilityState extends ConsumerState<CollectionAvailabilityPage> {
  Future<Project1Readiness>? _future;
  @override
  void initState() {
    super.initState();
    if (MobileConfig.usesLiveApi) _future = _read();
  }

  Future<Project1Readiness> _read() => ref.read(project1ReadRepositoryProvider).read();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Customer questionnaires')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: _future == null
          ? const Text('Questionnaire service unavailable. Configure the application connection before checking availability.')
          : FutureBuilder<Project1Readiness>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.hasError ? null : snapshot.data;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(data == null ? 'Availability could not be verified' : 'Questionnaire held',
                      style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    Text(data?.questionnaire.message ??
                      'Check your sign-in and connection, then try again. No questionnaire has been loaded.'),
                    const SizedBox(height: 20),
                    FilledButton(onPressed: () => setState(() { _future = _read(); }),
                      child: Text(data == null ? 'Retry' : 'Check again')),
                  ],
                );
              },
            ),
    ),
  );
}
