import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:panorama_viewer/panorama_viewer.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/features/capture_360/data/sphere/panorama_file_check.dart';
import 'package:fyp/features/panorama_viewer/presentation/pages/panorama_fullscreen_page.dart';
import 'package:fyp/features/capture_360/presentation/widgets/capture_theme.dart';

/// Review an unconfirmed panorama candidate before it replaces the active tour.
///
/// The viewer is interactive (horizontal/vertical drag, pinch zoom) and can
/// open the existing panorama alongside it. Nothing is activated by viewing;
/// only [onConfirm] changes the backend assignment.
class PanoramaCandidateReviewScreen extends StatefulWidget {
  const PanoramaCandidateReviewScreen({
    super.key,
    required this.candidatePath,
    required this.candidatePanoramaId,
    required this.sessionId,
    this.activePanoramaId,
    this.qualityStatus,
    required this.onConfirm,
    required this.onCancel,
  });

  final String candidatePath;
  final String candidatePanoramaId;
  final String sessionId;
  final String? activePanoramaId;
  final String? qualityStatus;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onCancel;

  @override
  State<PanoramaCandidateReviewScreen> createState() =>
      _PanoramaCandidateReviewScreenState();
}

class _PanoramaCandidateReviewScreenState
    extends State<PanoramaCandidateReviewScreen> {
  bool _working = false;
  String? _error;

  /// The structural verdict on the candidate file, run once before anything
  /// decodes it. A truncated or foreign-format file is reported with a
  /// readable message instead of a half-decoded bitmap or a crash.
  PanoramaFileIssue? _candidateIssue;

  @override
  void initState() {
    super.initState();
    unawaited(_validateCandidate());
  }

  Future<void> _validateCandidate() async {
    final issue = await PanoramaFileCheck.inspect(widget.candidatePath);
    if (!mounted) return;
    setState(() => _candidateIssue = issue);
  }

  Future<void> _confirm() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onConfirm();
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = 'The panorama could not be accepted: $error';
      });
    }
  }

  Future<void> _cancel() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onCancel();
      if (mounted) Navigator.of(context).pop(false);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = 'The recapture could not be cancelled: $error';
      });
    }
  }

  Future<void> _openCandidateFullscreen() async {
    final bytes = await File(widget.candidatePath).readAsBytes();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PanoramaFullscreenPage(bytes: bytes),
      ),
    );
  }

  Future<void> _openActiveFullscreen() async {
    final id = widget.activePanoramaId;
    if (id == null || id.isEmpty) return;
    try {
      final url = await ServiceLocator.panoramaViews.viewUrl(id);
      final response = await http.get(Uri.parse(url));
      if (!mounted) return;
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PanoramaFullscreenPage(bytes: response.bodyBytes),
          ),
        );
        return;
      }
      if (!mounted) return;
      setState(() => _error = 'The existing panorama could not be loaded.');
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'The existing panorama could not be loaded.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidate = File(widget.candidatePath);
    final candidateUsable =
        _candidateIssue == PanoramaFileIssue.none && candidate.existsSync();
    return Scaffold(
      backgroundColor: CaptureColors.cameraChrome,
      appBar: AppBar(
        backgroundColor: CaptureColors.cameraChrome,
        foregroundColor: Colors.white,
        title: const Text('Review new panorama'),
      ),
      body: _candidateIssue == null
          // The structural check is still running; show nothing yet rather
          // than decoding a file that may be broken.
          ? const Center(child: CircularProgressIndicator())
          : !candidateUsable
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  PanoramaFileCheck.describe(
                    _candidateIssue ?? PanoramaFileIssue.missing,
                  )!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: CaptureColors.mutedOnDark),
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: PanoramaViewer(
                    sensorControl: SensorControl.orientation,
                    // The full-resolution backend panorama is preserved in
                    // storage and uploaded as evidence; the interactive
                    // preview decodes a memory-appropriate 2048-wide image
                    // once and reuses the cached decode across rebuilds
                    // instead of decoding a ~64-megapixel bitmap on the GPU.
                    child: Image.file(
                      candidate,
                      fit: BoxFit.cover,
                      cacheWidth: 2048,
                      errorBuilder: (_, _, _) => const Center(
                        child: Text(
                          'The new panorama could not be displayed.',
                          style: TextStyle(color: CaptureColors.mutedOnDark),
                        ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.qualityStatus case final status?) ...[
                          Text(
                            'Quality verification: $status',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: CaptureColors.mutedOnDark,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                        const Text(
                          'This is an unconfirmed replacement. Your existing '
                          'panorama remains active until you tap Use this '
                          'panorama.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: CaptureColors.mutedOnDark,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _working || !candidateUsable
                                    ? null
                                    : _openCandidateFullscreen,
                                icon: const Icon(Icons.fullscreen_rounded),
                                label: const Text('Full screen'),
                              ),
                            ),
                            if (widget.activePanoramaId != null) ...[
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _working ? null : _openActiveFullscreen,
                                  icon: const Icon(Icons.compare_rounded),
                                  label: const Text('View existing'),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: CaptureColors.warn,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _working ? null : _confirm,
                          icon: _working
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.check_rounded),
                          label: const Text('Use this panorama'),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _working ? null : _cancel,
                          child: const Text('Cancel recapture'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
