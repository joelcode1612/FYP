import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_router/jaspr_router.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../layouts/app_layout.dart';
import 'activity_history_page.dart';
import 'cafe_demand_report_page.dart';
import 'report_activity_demo_data.dart';

/// Route shell for the R01–R12 café demand report. The page supplies its own
/// title, breadcrumb and toolbar, so the shell header is suppressed.
class CafeReportView extends StatelessComponent {
  const CafeReportView({super.key});

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.entrepreneur,
    currentRoute: '/entrepreneur/cafe-report',
    title: 'Café Demand Suitability Report',
    showPageHead: false,
    showBreadcrumbs: false,
    child: CafeDemandReportPage(
      snapshot: demoReportSnapshot,
      onViewLogHistory: () =>
          context.push('/entrepreneur/activity-history'),
    ),
  );
}

/// Route shell for the engine activity history / audit timeline.
class ActivityHistoryView extends StatelessComponent {
  const ActivityHistoryView({super.key});

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.entrepreneur,
    currentRoute: '/entrepreneur/activity-history',
    title: 'Activity History',
    showPageHead: false,
    showBreadcrumbs: false,
    child: ActivityHistoryPage(
      businessName: demoReportSnapshot.businessName,
      assessmentId: demoReportSnapshot.assessmentId,
      activities: demoActivities,
      onBackToReport: () => context.push('/entrepreneur/cafe-report'),
    ),
  );
}
