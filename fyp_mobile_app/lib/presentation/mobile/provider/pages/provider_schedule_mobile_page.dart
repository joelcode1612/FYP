import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../widgets/m3_kit.dart';
import 'provider_ui.dart';

/// Agent dock's Schedule tab.
///
/// SiteWise does not record viewings, follow-up calls or any other calendar
/// event: there is no schedule endpoint on the backend and no event store on
/// the device. This page therefore renders the workspace's honest empty state
/// — it never invents appointments, and it says WHY the list is empty instead
/// of implying the agent simply has nothing on today.
///
/// If a schedule feature ships later, the page's body is the place to render
/// it; the route, dock slot and refresh affordance already exist.
class ProviderScheduleMobilePage extends ConsumerStatefulWidget {
  const ProviderScheduleMobilePage({super.key});

  @override
  ConsumerState<ProviderScheduleMobilePage> createState() =>
      _ProviderScheduleMobilePageState();
}

class _ProviderScheduleMobilePageState
    extends ConsumerState<ProviderScheduleMobilePage> {
  @override
  Widget build(BuildContext context) {
    final role = ref.watch(authNotifierProvider.select((s) => s.user?.role));
    final isAgent = role == AppRole.agent;
    return Scaffold(
      backgroundColor: SitewiseM3.paper,
      appBar: ProviderPageAppBar(
        title: 'Schedule',
        eyebrow: isAgent ? 'SITEWISE AGENT' : 'SITEWISE PROVIDER',
      ),
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: () async {
          // Nothing to reload yet: the gesture is kept so the affordance is
          // identical to every other tab when schedule data arrives.
          await Future<void>.delayed(const Duration(milliseconds: 250));
        },
        child: providerContent(
          children: [
            M3ScreenHeading(
              eyebrow: 'Your calendar',
              title: 'Today\'s schedule.',
              lead: 'Viewings and follow-up appointments for the listings '
                  'this account manages.',
            ),
            const SizedBox(height: 16),
            ProviderMessage(
              icon: Icons.event_busy_outlined,
              title: 'Nothing scheduled yet',
              body: 'SiteWise does not record viewings or follow-up calls '
                  'yet, so there is no schedule to show. Upcoming property '
                  'viewings and owner call-backs will appear here once '
                  'scheduling is added to the workspace.',
            ),
            M3Banner(
              text:
                  'Enquiries are the closest signal available today — a '
                  'new enquiry often leads to a viewing. Open Enquiries to '
                  'see who is waiting.',
            ),
          ],
        ),
      ),
    );
  }
}
