import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../widgets/m3_kit.dart';
import 'provider_models.dart';
import 'provider_ui.dart';
import 'provider_workspace_service.dart';

/// Shared enquiry inbox for Property Owners and Agents.
///
/// The rows are real messages stored against the properties the signed-in
/// account manages. The server decides that set — owned rows for an owner,
/// assigned rows for an agent — so one provider can never read another
/// provider's inbox, and nothing here filters by role on the client.
///
/// There is deliberately no lead score, no phone deep link and no auto-reply:
/// the enquiry carries the sender's own name and email, and the only actions
/// are the status transitions the backend actually supports.
class ProviderEnquiriesMobilePage extends ConsumerStatefulWidget {
  const ProviderEnquiriesMobilePage({super.key});

  @override
  ConsumerState<ProviderEnquiriesMobilePage> createState() =>
      _ProviderEnquiriesMobilePageState();
}

class _ProviderEnquiriesMobilePageState
    extends ConsumerState<ProviderEnquiriesMobilePage> {
  Future<({List<ProviderEnquiry> enquiries, ProviderEnquiryMetrics metrics})>?
  _future;

  /// `null` = every state. Filtering is a server query, so the counts shown on
  /// the chips and the rows listed can never disagree.
  ProviderEnquiryStatus? _filter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ProviderWorkspaceService.enquiries(status: _filter);
    if (!mounted) return;
    setState(() {
      _future = request;
    });
    await settleRefresh(request);
  }

  void _setFilter(ProviderEnquiryStatus? status) {
    if (_filter == status) return;
    _filter = status;
    _load();
  }

  Future<void> _act(
    ProviderEnquiry enquiry,
    ProviderEnquiryStatus status, {
    String? reply,
  }) async {
    try {
      await ProviderWorkspaceService.updateEnquiry(
        enquiryId: enquiry.id,
        status: status,
        reply: reply,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Enquiry marked ${status.label.toLowerCase()}.'),
        ),
      );
      _load();
    } on AppFailure catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failure.userMessage)));
    }
  }

  Future<void> _reply(ProviderEnquiry enquiry) async {
    final controller = TextEditingController(text: enquiry.providerReply ?? '');
    final submitted = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: SitewiseM3.surface,
        surfaceTintColor: SitewiseM3.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
        ),
        title: const Text(
          'Reply to the enquiry',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontWeight: FontWeight.w800,
            color: SitewiseM3.ink,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'About ${enquiry.propertyTitle}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                color: SitewiseM3.muted,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              maxLines: 5,
              autofocus: true,
              maxLength: 2000,
              decoration: InputDecoration(
                hintText: 'What would you like the enquirer to know?',
                filled: true,
                fillColor: SitewiseM3.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(
                    SitewiseM3.radiusField,
                  ),
                  borderSide: const BorderSide(color: SitewiseM3.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(
                    SitewiseM3.radiusField,
                  ),
                  borderSide: const BorderSide(
                    color: SitewiseColors.action,
                    width: 1.6,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: SitewiseColors.action,
            ),
            child: const Text('Send reply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (submitted == null) return;
    if (submitted.length < 2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Write a reply before sending it.')),
      );
      return;
    }
    await _act(enquiry, ProviderEnquiryStatus.replied, reply: submitted);
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: SitewiseColors.action,
      onRefresh: _load,
      child: FutureBuilder<
        ({
          List<ProviderEnquiry> enquiries,
          ProviderEnquiryMetrics metrics,
        })
      >(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return providerLoadingView();
          }
          if (snapshot.hasError) {
            final error = snapshot.error!;
            return providerContent(
              children: [
                if (isMfaRequired(error))
                  ProviderMfaGate(onReload: _load)
                else
                  ProviderMessage(
                    icon: Icons.inbox_outlined,
                    title: 'Your enquiries could not be loaded',
                    body: error is AppFailure
                        ? error.userMessage
                        : 'The backend did not answer. Please retry.',
                    onRetry: _load,
                  ),
              ],
            );
          }
          final data = snapshot.data!;
          return providerContent(
            children: [
              const M3ScreenHeading(
                eyebrow: 'Messages',
                title: 'Enquiries.',
                lead:
                    'Messages stored against the listings this account '
                    'manages.',
              ),
              const M3SectionRow(
                title: 'Inbox',
                overline: 'SERVER FILTER',
              ),
              _filterRow(data.metrics),
              const SizedBox(height: 14),
              if (data.enquiries.isEmpty)
                ProviderMessage(
                  icon: Icons.inbox_outlined,
                  title: data.metrics.total == 0
                      ? 'No enquiries yet'
                      : 'Nothing in this state',
                  body: data.metrics.total == 0
                      ? 'Enquiries sent to your published listings arrive '
                            'here. Nothing is listed until a message is '
                            'actually stored.'
                      : 'No enquiry currently has the '
                            '"${_filter?.label ?? ''}" status. Choose another '
                            'filter or show all.',
                )
              else
                for (final enquiry in data.enquiries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _EnquiryCard(
                      enquiry: enquiry,
                      onRead: () =>
                          _act(enquiry, ProviderEnquiryStatus.read),
                      onReply: () => _reply(enquiry),
                      onClose: () =>
                          _act(enquiry, ProviderEnquiryStatus.closed),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }

  Widget _filterRow(ProviderEnquiryMetrics metrics) {
    final options = <(ProviderEnquiryStatus?, String, int)>[
      (null, 'All', metrics.total),
      (
        ProviderEnquiryStatus.incoming,
        'New',
        metrics.count(ProviderEnquiryStatus.incoming),
      ),
      (
        ProviderEnquiryStatus.read,
        'Read',
        metrics.count(ProviderEnquiryStatus.read),
      ),
      (
        ProviderEnquiryStatus.replied,
        'Replied',
        metrics.count(ProviderEnquiryStatus.replied),
      ),
      (
        ProviderEnquiryStatus.closed,
        'Closed',
        metrics.count(ProviderEnquiryStatus.closed),
      ),
    ];
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (status, label, count) = options[index];
          final selected = _filter == status;
          return ChoiceChip(
            selected: selected,
            onSelected: (_) => _setFilter(status),
            label: Text('$label · $count'),
            labelStyle: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: selected ? SitewiseM3.surface : SitewiseM3.ink,
            ),
            backgroundColor: SitewiseM3.surface,
            selectedColor: SitewiseColors.action,
            side: const BorderSide(color: SitewiseM3.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
            ),
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );
        },
      ),
    );
  }
}

class _EnquiryCard extends StatelessWidget {
  const _EnquiryCard({
    required this.enquiry,
    required this.onRead,
    required this.onReply,
    required this.onClose,
  });

  final ProviderEnquiry enquiry;
  final VoidCallback onRead;
  final VoidCallback onReply;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final status = enquiry.status;
    return ProviderCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      enquiry.propertyTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: SitewiseM3.ink,
                      ),
                    ),
                    if (enquiry.propertyAddress.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        enquiry.propertyAddress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 11,
                          color: SitewiseM3.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ProviderEnquiryPill(
                label: status.label,
                tone: switch (status) {
                  ProviderEnquiryStatus.incoming => 'action',
                  ProviderEnquiryStatus.read => 'warning',
                  ProviderEnquiryStatus.replied => 'success',
                  _ => 'neutral',
                },
              ),
            ],
          ),
          if (!enquiry.propertyPublished) ...[
            const SizedBox(height: 9),
            const Text(
              'This listing is no longer published. The message is kept as '
              'received.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                height: 1.45,
                color: SitewiseM3.muted,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            enquiry.message,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12.5,
              height: 1.55,
              color: SitewiseM3.ink,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: providerSoft,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  enquiry.senderDisplay,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: SitewiseM3.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  enquiry.enquirerEmail,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 11.5,
                    color: SitewiseM3.muted,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'Received ${enquiry.receivedDisplay}',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 11,
                    color: SitewiseM3.muted,
                  ),
                ),
              ],
            ),
          ),
          if ((enquiry.providerReply ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            _ReplyBlock(enquiry: enquiry),
          ],
          const SizedBox(height: 13),
          _actions(status),
        ],
      ),
    );
  }

  Widget _actions(ProviderEnquiryStatus status) {
    if (status == ProviderEnquiryStatus.unknown) {
      return const Text(
        'This enquiry carries a status this build does not recognise, so no '
        'action is offered.',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          height: 1.45,
          color: SitewiseM3.muted,
        ),
      );
    }
    if (status == ProviderEnquiryStatus.closed) {
      return const Text(
        'Closed. The thread is kept for your records — closed enquiries are '
        'not re-opened.',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          height: 1.45,
          color: SitewiseM3.muted,
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (status == ProviderEnquiryStatus.incoming)
          OutlinedButton(
            onPressed: onRead,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
              side: const BorderSide(color: SitewiseM3.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
              ),
            ),
            child: const Text('Mark as read'),
          ),
        FilledButton(
          onPressed: onReply,
          style: FilledButton.styleFrom(
            backgroundColor: SitewiseColors.action,
            foregroundColor: SitewiseM3.surface,
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
            ),
          ),
          child: Text(
            status == ProviderEnquiryStatus.replied ? 'Update reply' : 'Reply',
          ),
        ),
        TextButton(
          onPressed: onClose,
          style: TextButton.styleFrom(
            foregroundColor: SitewiseM3.muted,
            minimumSize: const Size(0, 44),
          ),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ReplyBlock extends StatelessWidget {
  const _ReplyBlock({required this.enquiry});

  final ProviderEnquiry enquiry;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: providerWash,
      borderRadius: BorderRadius.circular(15),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Your reply',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.action,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          enquiry.providerReply ?? '',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            height: 1.5,
            color: SitewiseM3.ink,
          ),
        ),
        if (enquiry.repliedAt != null) ...[
          const SizedBox(height: 6),
          Text(
            enquiry.repliedDisplay,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 10.5,
              color: SitewiseM3.muted,
            ),
          ),
        ],
      ],
    ),
  );
}
