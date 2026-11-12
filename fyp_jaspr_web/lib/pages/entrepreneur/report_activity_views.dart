import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../layouts/app_layout.dart';
import '../../components/project1_read_panel.dart';

/// Route shell for the R01–R12 café demand report. The page supplies its own
/// title, breadcrumb and toolbar, so the shell header is suppressed.
class CafeReportView extends StatelessComponent {
  final String assessmentId;
  const CafeReportView({super.key, this.assessmentId = ''});

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.entrepreneur,
    currentRoute: '/entrepreneur/cafe-report',
    title: 'Café Demand Suitability Report',
    showPageHead: false,
    showBreadcrumbs: false,
    child: div(classes: 'stack stack--md', [
      Project1ReadPanel(assessmentId: assessmentId, section: 'report'),
      a(href: '/entrepreneur/activity-history${assessmentId.isEmpty ? '' : '?assessment=${Uri.encodeQueryComponent(assessmentId)}'}',
        [Component.text('View activity history')]),
    ]),
  );
}

/// Route shell for the engine activity history / audit timeline.
class ActivityHistoryView extends StatelessComponent {
  final String assessmentId;
  const ActivityHistoryView({super.key, this.assessmentId = ''});

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.entrepreneur,
    currentRoute: '/entrepreneur/activity-history',
    title: 'Activity History',
    showPageHead: false,
    showBreadcrumbs: false,
    child: Project1ReadPanel(assessmentId: assessmentId, section: 'activity'),
  );
}
