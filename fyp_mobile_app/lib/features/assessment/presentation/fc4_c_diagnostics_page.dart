import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyp/core/config/cq_development_access.dart';
import 'package:fyp/features/assessment/presentation/viewmodels/cq_view_model.dart';

/// Development-only, read-only FC4-C probe. It never edits an answer and is
/// unreachable unless the isolated CQ lab dart-defines are present in a debug
/// build. Every value is taken from the server-held CqSession view.
class Fc4CDiagnosticsPage extends ConsumerStatefulWidget {
  const Fc4CDiagnosticsPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<Fc4CDiagnosticsPage> createState() => _Fc4CDiagnosticsPageState();
}

class _Fc4CDiagnosticsPageState extends ConsumerState<Fc4CDiagnosticsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) ref.read<CqViewModel>(cqViewModelProvider(widget.sessionId)).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!CqDevelopmentAccess.enabled) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'FC4-C diagnostics are unavailable. This screen requires an '
              'explicit debug-only isolated CQ lab configuration.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final vm = ref.watch<CqViewModel>(cqViewModelProvider(widget.sessionId));
    final session = vm.session;
    final presentation = session?.presentation;
    final currentSlot = (presentation?['slot_id'] as String?) ??
        (session?.data['next_slot_id'] as String?) ??
        'NONE';
    final row = session?.routing.cast<Map<String, dynamic>>().where(
      (r) => r['slot_id'] == currentSlot,
    ).toList();
    final route = (row == null || row.isEmpty) ? null : row.first;
    final stimulus = session?.data['next_stimulus_kind'] as String?;
    final receipt = session?.data['receipt'] as Map<String, dynamic>?;
    final rendered = presentation?['rendered'] == true;
    final next = stimulus != null
        ? 'STIMULUS:$stimulus'
        : (session?.data['next_slot_id'] as String? ?? 'NONE');
    final evidence = <String>[
      if (session != null) 'revision=${session.revision}',
      if (session != null) 'status=${session.data['status']}',
      if (presentation != null) 'display=${presentation['display_id']}',
      'render_ack=$rendered',
      if (session != null) 'adapter=${session.data['stimulus_adapter'] ?? 'NONE'}',
      if (receipt != null) 'receipt=${receipt['receipt_id']}',
    ].join('\n');

    Widget line(String key, String value, {Key? widgetKey}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 132, child: Text(key, style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: SelectableText(value, key: widgetKey)),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('FC4-C routing diagnostics')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'DEVELOPER ONLY · synthetic, not reportable',
                style: TextStyle(fontWeight: FontWeight.w800, color: Colors.deepOrange),
              ),
              const SizedBox(height: 12),
              if (vm.busy) const LinearProgressIndicator(),
              if (vm.error != null) Text('ERROR: ${vm.error}'),
              line('session', widget.sessionId),
              line(
                'policy_version',
                '${session?.data['policy_version'] ?? session?.manifest['policy_version'] ?? 'NONE'}',
                widgetKey: const Key('fc4c-policy-version'),
              ),
              line(
                'policy_sha256',
                '${session?.data['policy_sha256'] ?? 'NONE'}',
              ),
              line('current_question', currentSlot, widgetKey: const Key('fc4c-current-question')),
              line(
                'wording',
                currentSlot == 'NONE' || session == null
                    ? '-'
                    : '${session.question(currentSlot)['wording']['EN']}',
              ),
              line('answer_state', '${route?['state'] ?? 'NONE'}', widgetKey: const Key('fc4c-answer-state')),
              line('routing_verdict', '${route?['verdict'] ?? 'NONE'}', widgetKey: const Key('fc4c-verdict')),
              line('reason_code', '${route?['reason'] ?? 'NONE'}', widgetKey: const Key('fc4c-reason')),
              line('next_question', next, widgetKey: const Key('fc4c-next-question')),
              const SizedBox(height: 12),
              const Text('Evidence', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              SelectableText(evidence, key: const Key('fc4c-evidence-status')),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('fc4c-open-questionnaire'),
                onPressed: widget.sessionId.isEmpty
                    ? null
                    : () => Navigator.of(context).pushNamed('/questionnaire'),
                child: const Text('Open questionnaire'),
              ),
              const SizedBox(height: 10),
              FilledButton(
                key: const Key('fc4c-reload'),
                onPressed: vm.busy ? null : vm.load,
                child: const Text('Reload server view'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
