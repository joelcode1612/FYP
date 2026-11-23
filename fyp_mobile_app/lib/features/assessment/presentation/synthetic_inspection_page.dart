import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';
import '../../../../core/di/service_locator.dart';
import 'widgets/cq_ui_primitives.dart';
import 'synthetic_session_host.dart';

/// Reads the operator-granted import through the normal authenticated API.
class SyntheticInspectionPage extends StatefulWidget {
  const SyntheticInspectionPage({
    super.key,
    required this.runId,
    this.repository,
  });
  final String runId;
  final ApiSyntheticInspectionRepository? repository;
  @override
  State<SyntheticInspectionPage> createState() =>
      _SyntheticInspectionPageState();
}

class _SyntheticInspectionPageState extends State<SyntheticInspectionPage> {
  Map<String, dynamic>? data;
  String? error;
  bool busy = false;
  String? selectedSession;
  List<Map<String, dynamic>> cases = [];
  late final repository =
      widget.repository ??
      ApiSyntheticInspectionRepository(ServiceLocator.apiClient);
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      busy = true;
      error = null;
      data = null;
    });
    try {
      final value = await repository.inspect(widget.runId);
      List<Map<String, dynamic>> available = [];
      try {
        available = await repository.cases(widget.runId);
      } catch (_) {
        /* Separate execution permission. */
      }
      if (mounted) {
        setState(() {
          data = value;
          cases = available;
          final sessions = value['sessions'] as List;
          if (!sessions.any((s) => s['id'] == selectedSession)) {
            selectedSession = sessions.isEmpty
                ? null
                : sessions.first['id'] as String;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'Developer inspection is unavailable or not authorized.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String value(Object? v) => const JsonEncoder.withIndent('  ').convert(v);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Developer inspection')),
    body: CqPageFrame(
      children: [
        const CqNotice(
          message:
              'SYNTHETIC / NOT REPORTABLE\nNonhuman fixtures. No participant collection or real report release.',
          tone: CqNoticeTone.warning,
        ),
        SelectableText('Import run ${widget.runId}'),
        if (busy) const LinearProgressIndicator(),
        if (error != null) CqNotice(message: error!, tone: CqNoticeTone.error),
        if (data != null) ...[
          for (final c in cases)
            CqPanel(
              title: 'Interactive synthetic case · ${c['case_key']}',
              child: Column(
                children: [
                  Text(
                    '${c['scenario']} — TEST ONLY. No human eligibility decision.',
                  ),
                  TextButton(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SyntheticSessionHost(
                            runId: widget.runId,
                            sessionId: c['session_id'] as String,
                          ),
                        ),
                      );
                      if (mounted) await _load();
                    },
                    child: const Text('Open synthetic questionnaire'),
                  ),
                ],
              ),
            ),
          CqPanel(
            title: 'Stored Dss records',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${(data!['sessions'] as List).length} sessions · ${(data!['snapshots'] as List).length} diagnostic snapshots',
                ),
                SelectableText('Package SHA-256: ${data!['package_sha256']}'),
                const Text(
                  'Stored diagnostics. Interactive cases use the separately authorized synthetic flow above.',
                ),
              ],
            ),
          ),
          if ((data!['sessions'] as List).isNotEmpty)
            DropdownButton<String>(
              isExpanded: true,
              value: selectedSession,
              hint: const Text('Select stored synthetic session'),
              items: [
                for (final s in data!['sessions'] as List)
                  DropdownMenuItem<String>(
                    value: s['id'] as String,
                    child: Text(
                      '${s['status']} · ${s['eligibility']} · ${s['id']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (id) => setState(() => selectedSession = id),
            ),
          for (final raw in (data!['sessions'] as List).where(
            (s) => s['id'] == selectedSession,
          ))
            _session(raw as Map<String, dynamic>),
          for (final raw in data!['snapshots'] as List)
            _snapshot(raw as Map<String, dynamic>),
        ],
        TextButton.icon(
          onPressed: busy ? null : _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Reload from Dss'),
        ),
      ],
    ),
  );
  Widget _session(Map<String, dynamic> s) => CqPanel(
    title: 'Session · ${s['lifecycle_status'] ?? s['status']}',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          '${s['id']}\nCampaign ${s['campaign_id']}\nRelease ${s['release_id']}',
        ),
        Text(
          'Revision ${s['revision']} · ${s['eligibility']}\n${s['classification_reason']}',
        ),
        if (s['lifecycle_status'] != null)
          Text('Stored status ${s['state']} · ${s['case_key']} · ${s['scenario']}'),
        const Text(
          'SCREENED_OUT: adopted predicate unresolved. No geography or preference screenout inferred.',
        ),
        ExpansionTile(
          title: Text(
            'Effective answers (${(s['effective_answers'] as List).length})',
          ),
          children: [SelectableText(value(s['effective_answers']))],
        ),
        ExpansionTile(
          title: Text(
            'Answer revisions (${(s['answer_history'] as List).length})',
          ),
          children: [SelectableText(value(s['answer_history']))],
        ),
      ],
    ),
  );
  Widget _snapshot(Map<String, dynamic> row) {
    final m = row['measurement'] as Map<String, dynamic>;
    final context = row['explanation_context'] as Map<String, dynamic>;
    return CqPanel(
      title: 'Synthetic diagnostic · ${m['slot_id']}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${(m['metadata_json'] as Map)['rule']}\nQ / S / A / V: ${m['q']} / ${m['s']} / ${m['a']} / ${m['v']}',
          ),
          SelectableText(
            'Snapshot ${m['id']}\nCutoff ${m['cutoff']}\nFingerprint ${m['fingerprint']}',
          ),
          for (final c in m['cells'] as List)
            Text(
              '${c['code']}: ${c['x']} / ${c['v']} · diagnostic ${c['diagnostic_percentage'] ?? 'NOT_ESTIMABLE'}% · official ${c['status']}',
            ),
          const CqNotice(
            message:
                'Official percentages and report findings remain withheld.',
            tone: CqNoticeTone.warning,
          ),
          ExpansionTile(
            title: const Text('Stored explanation context and gates'),
            children: [SelectableText(value(context))],
          ),
        ],
      ),
    );
  }
}
