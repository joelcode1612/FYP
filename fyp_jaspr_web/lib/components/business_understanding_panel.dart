import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../data/auth_service.dart';
import 'ui.dart';

/// Review setup is read from the authenticated server. Preview answers are
/// never sent to the provider and a web workspace id is never used as an M2 id.
class BusinessUnderstandingPanel extends StatefulComponent {
  const BusinessUnderstandingPanel({super.key});

  @override
  State<BusinessUnderstandingPanel> createState() => _BusinessUnderstandingState();
}

class _BusinessUnderstandingState extends State<BusinessUnderstandingPanel> {
  String _message = 'Business review is waiting for its required setup.';
  bool _busy = false;
  Map<String, dynamic>? _audit;
  String? _auditMessage;

  Future<void> _check() async {
    setState(() => _busy = true);
    final result = await WebAuth.requestDetailed('/api/v1/project1-workflow/setup');
    if (!mounted) return;
    final body = result['body'];
    setState(() {
      _busy = false;
      _message = result['ok'] == true && body is Map
          ? '${body['message']}'
          : switch (result['status']) {
              401 => 'Sign in to check your business review.',
              403 => 'This account cannot access business review.',
              _ => 'Business review is waiting for its required setup.',
            };
    });
  }

  Future<void> _readAudit() async {
    final result = await WebAuth.requestDetailed(
      '/api/v1/project1-workflow/technical-audit',
    );
    if (!mounted) return;
    setState(() {
      final body = result['body'];
      _audit = result['ok'] == true && body is Map<String, dynamic> ? body : null;
      _auditMessage = _audit == null
          ? 'Technical audit requires authorized staff access and completed verification.'
          : null;
    });
  }

  @override
  Component build(BuildContext context) {
    final role = WebAuth.profile?['role'];
    return section(classes: 'panel stack stack--sm', [
      h3([Component.text('Business Understanding')]),
      p(attributes: {'role': 'status', 'aria-live': 'polite'}, [Component.text(_message)]),
      p(classes: 'small asw-muted', [Component.text(
        'Your original Business Description stays as written. Suggested '
        'clarifications need your review. Research questions need separate approval.',
      )]),
      ActionButton(_busy ? 'Checking…' : 'Check review availability',
        variant: 'secondary', onClick: _busy ? null : _check),
      if (role == 'admin' || role == 'administrator') ...[
        ActionButton('View technical audit', variant: 'secondary', onClick: _readAudit),
        if (_auditMessage != null) p([Component.text(_auditMessage!)]),
        if (_audit != null) dl([
          dt([Component.text('Contract reconciliation')]),
          dd([Component.text('${_audit!['status_contract']}')]),
          dt([Component.text('Cloud execution through this review')]),
          dd([Component.text(_audit!['cloud_http_execution'] == true ? 'Enabled' : 'Withheld')]),
          dt([Component.text('Required setup')]),
          dd([Component.text((_audit!['unresolved'] as List? ?? []).join(', '))]),
        ]),
      ],
    ]);
  }
}
