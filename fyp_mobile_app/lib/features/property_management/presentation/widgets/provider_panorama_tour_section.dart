import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/core/utils/capture_log.dart';
import 'package:fyp/features/capture_360/application/frame_upload_queue.dart';
import 'package:fyp/features/capture_360/data/api_panorama_viewer_repository.dart';
import 'package:fyp/features/capture_360/data/sphere/sitewise_sphere_session_store.dart';
import 'package:fyp/features/panorama_viewer/presentation/pages/panorama_fullscreen_page.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_button.dart';

/// The **360° Property Tour** section of the authorized Agent property
/// detail (spec §9).
///
/// It answers the question "is there a panorama for THIS property?" from
/// every honest source, in priority order:
///
///  1. the CANONICAL `fyp.panoramas` row through FastAPI — what SiteWise
///     actually holds, visible from any device;
///  2. the LOCAL draft — the file this device stitched, when the upload has
///     not been confirmed (or has never run);
///  3. nothing — the **Start 360° Capture** action.
///
/// A local-only draft is displayed ONLY on the device that holds it ("Saved
/// on this device"); on another device the canonical read answers 404 and
/// the section never claims a panorama SiteWise has not received. Pending
/// uploads are resumed here (idempotently) so reopening the property
/// continues the synchronization. Fresh signed viewing URLs are minted on
/// every view — stored URLs expire and are never persisted.
class ProviderPanoramaTourSection extends StatefulWidget {
  const ProviderPanoramaTourSection({
    super.key,
    required this.propertyId,
    required this.onStartCapture,
    this.onOpenWorkflow,
    this.beforeSync,
    this.onSynced,
    this.requiresRecapture = false,
    this.captureHint,
    this.readOnly = false,
  });

  final int propertyId;
  final bool readOnly;

  /// Opens the capture flow (the page's own navigation concern). The capture
  /// host resumes the previous session, so this is also how an existing
  /// capture continues.
  final VoidCallback? onStartCapture;
  final Future<void> Function(String tourId)? onOpenWorkflow;
  final Future<bool> Function()? beforeSync;
  final Future<void> Function()? onSynced;
  final bool requiresRecapture;
  final String? captureHint;

  @override
  State<ProviderPanoramaTourSection> createState() =>
      _ProviderPanoramaTourSectionState();
}

class _ProviderPanoramaTourSectionState
    extends State<ProviderPanoramaTourSection> {
  bool _loading = true;
  bool _lookupFailed = false;
  String? _draftTourId;
  CanonicalPanorama? _canonical;
  String? _localPanoramaPath;
  FrameUploadQueueState? _queueState;
  bool _syncing = false;
  String? _syncError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProviderPanoramaTourSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.beforeSync == null &&
        widget.beforeSync != null &&
        !_loading &&
        !_syncing &&
        _localPanoramaPath != null &&
        _queueState?.panoramaConfirmed != true) {
      unawaited(_syncDraft());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final pid = widget.propertyId;

    VirtualTour? tour;
    try {
      tour = await ServiceLocator.tourRepo.latestInspectionCapture('$pid');
    } on Object catch (error) {
      CaptureLog.log('Tour draft lookup failed for $pid: $error');
    }

    // Restore any unfinished upload for this inspection.
    FrameUploadQueueState? queueState;
    final tourId = tour?.id;
    if (tourId != null && tourId.isNotEmpty) {
      try {
        queueState = await FrameUploadQueue.readState(
          ServiceLocator.frameStore,
          tourId,
        );
      } on Object {
        queueState = null;
      }
    }

    String? localPath;
    // The tour record's panorama pointer first...
    final tourPath = tour?.panoramaPath;
    if (tourPath != null &&
        tourPath.isNotEmpty &&
        await File(tourPath).exists()) {
      localPath = tourPath;
    }
    // ...then the capture session's own stitched record.
    if (localPath == null && tour != null) {
      try {
        final session = await SitewiseSphereSessionStore(
          frameStore: ServiceLocator.frameStore,
          tourId: tour.id,
        ).getSession(tour.id);
        final stitched = session?.localPanoramaPath;
        if (stitched != null &&
            stitched.isNotEmpty &&
            await File(stitched).exists()) {
          localPath = stitched;
        }
      } on Object {
        // No session metadata: the file paths above stay authoritative.
      }
    }

    CanonicalPanorama? canonical;
    var lookupFailed = false;
    try {
      canonical = await ServiceLocator.panoramaViews.latestForProperty(pid);
    } on Object catch (error) {
      lookupFailed = true;
      CaptureLog.log('Canonical panorama read failed for $pid: $error');
    }

    if (!mounted) return;
    setState(() {
      _queueState = queueState;
      _localPanoramaPath = localPath;
      _canonical = canonical;
      _lookupFailed = lookupFailed;
      _draftTourId = tourId;
      _loading = false;
    });
    if (!_syncing &&
        widget.beforeSync != null &&
        localPath != null &&
        queueState?.panoramaConfirmed != true) {
      unawaited(_syncDraft());
      return;
    }
    if (tourId != null &&
        queueState != null &&
        ((widget.onStartCapture != null && !queueState.panoramaConfirmed) ||
            (queueState.panoramaConfirmed &&
                queueState.panorama?.panoramaId == canonical?.panoramaId)) &&
        queueState.anyPending) {
      FrameUploadQueue.forTour(
        frameStore: ServiceLocator.frameStore,
        tourId: tourId,
      ).resumeInBackground();
    }
  }

  /// The honest status chip. "Saved to SiteWise" ONLY after FastAPI has
  /// confirmed the canonical row; a local-only draft never claims cloud
  /// state.
  String get _statusLabel {
    if (_syncing) return 'Syncing 360° tour';
    if (_hasLocalDraft && _queueState?.panoramaConfirmed != true) {
      return 'Saved on this device';
    }
    if (widget.requiresRecapture) return 'New capture required';
    if (_canonical != null) {
      final verification = _canonical!.verificationStatus;
      if (verification == 'approved' || _canonical!.publishedAt != null) {
        return 'Saved to SiteWise';
      }
      return 'Saved to SiteWise — Draft, not yet approved';
    }
    if (_localPanoramaPath != null) {
      if (_queueState != null &&
          _queueState!.panorama != null &&
          !_queueState!.panoramaConfirmed &&
          _queueState!.panorama!.status == FrameUploadState.failedRetryable) {
        return 'Saved on this device — sync needs a retry';
      }
      return 'Saved on this device';
    }
    if (_lookupFailed) return 'Tour status unavailable';
    return _draftTourId != null ? 'Capture draft' : 'No 360° tour yet';
  }

  bool get _hasPanorama =>
      _canonical != null ||
      (_localPanoramaPath != null && _localPanoramaPath!.isNotEmpty);

  Future<void> _syncDraft() async {
    final beforeSync = widget.beforeSync;
    final tourId = _draftTourId;
    final path = _localPanoramaPath;
    if (_syncing || beforeSync == null || tourId == null || path == null) {
      return;
    }
    setState(() {
      _syncing = true;
      _syncError = null;
    });
    try {
      if (!await beforeSync() || !mounted) return;
      final frameStore = ServiceLocator.frameStore;
      final queue = FrameUploadQueue.forTour(
        frameStore: frameStore,
        tourId: tourId,
      );
      final sessions = SitewiseSphereSessionStore(
        frameStore: frameStore,
        tourId: tourId,
      );
      await queue.reconcileFrames(
        await sessions.loadFrames(tourId),
        propertyId: widget.propertyId,
      );
      await queue.enqueuePanorama(path, propertyId: widget.propertyId);
      await queue.resume();
      await _load();
      if (!mounted) return;
      if (_queueState?.panoramaConfirmed != true) {
        setState(
          () => _syncError =
              'The tour is still on this device. Try syncing again.',
        );
      } else {
        await widget.onSynced?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _syncError = readableFailure(
            e,
            fallback: 'The tour could not sync.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Color get _statusColor {
    if (_canonical != null) return SitewiseColors.success;
    if (_localPanoramaPath != null) return SitewiseColors.warning;
    return SitewiseM3.muted;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: SitewiseM3.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.threesixty_outlined,
                size: 20,
                color: SitewiseColors.action,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '360° Property Tour',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: SitewiseM3.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!_loading)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _statusLabel,
                style: TextStyle(
                  color: _statusColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (!_loading) const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_hasPanorama) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 220,
                child: _hasLocalDraft
                    ? _LocalPanoramaBox(
                        path: _localPanoramaPath!,
                        onOpen: _openFullscreen,
                      )
                    : _canonical != null
                    ? _CanonicalPreview(
                        panoramaId: _canonical!.panoramaId,
                        onOpen: _openFullscreen,
                      )
                    : const Center(child: Text('Preview unavailable')),
              ),
            ),
            const SizedBox(height: 12),
            SitewiseButton(
              label: 'View 360° Panorama',
              icon: Icons.fullscreen_rounded,
              onPressed: _openFullscreen,
            ),
            if (_hasLocalDraft &&
                _queueState?.panoramaConfirmed != true &&
                widget.beforeSync != null)
              OutlinedButton(
                onPressed: _syncing ? null : _syncDraft,
                child: Text(
                  _syncError == null ? 'Sync 360° tour' : 'Retry sync',
                ),
              ),
            if (widget.requiresRecapture &&
                !_syncing &&
                (_draftTourId?.isNotEmpty ?? false) &&
                widget.onOpenWorkflow != null)
              TextButton(
                onPressed: () => widget.onOpenWorkflow!(_draftTourId!),
                child: const Text('Recapture 360° tour'),
              ),
            if (_draftTourId == null && widget.onStartCapture != null)
              TextButton(
                onPressed: widget.onStartCapture,
                child: const Text('Start new 360° capture'),
              ),
          ] else if (_lookupFailed) ...[
            const Text('Could not check whether this property has a tour.'),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ] else if (widget.readOnly) ...[
            const Text(
              'No 360° panorama is available for this approved listing.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: SitewiseM3.muted,
              ),
            ),
          ] else ...[
            Text(
              'Capture the 38-point 360° tour for this property. The '
              'panorama is created on this device and saved as a draft '
              'automatically.',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: SitewiseM3.muted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            SitewiseButton(
              label: _draftTourId != null
                  ? 'Open 360° capture'
                  : 'Start 360° capture',
              icon: Icons.camera_alt_outlined,
              onPressed: widget.onStartCapture,
            ),
          ],
          if (widget.captureHint case final hint?) Text(hint),
          if (_syncError case final message?) Text(message),
        ],
      ),
    );
  }

  bool get _hasLocalDraft =>
      _localPanoramaPath != null &&
      _localPanoramaPath!.isNotEmpty &&
      File(_localPanoramaPath!).existsSync();

  /// Fullscreen inspection: the LOCAL draft when this device holds it, the
  /// canonical signed fetch otherwise. The screen re-loads on return, so an
  /// upload that finished while the Agent was viewing is reflected.
  Future<void> _openFullscreen([Uint8List? previewBytes]) async {
    if (previewBytes != null || _hasLocalDraft) {
      final bytes =
          previewBytes ?? await File(_localPanoramaPath!).readAsBytes();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PanoramaFullscreenPage(bytes: bytes),
        ),
      );
      await _load();
      return;
    }
    final panoramaId = _canonical?.panoramaId;
    if (panoramaId == null || panoramaId.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _CanonicalFullscreenPage(panoramaId: panoramaId),
      ),
    );
    await _load();
  }
}

/// The section's capture hook, supplied by the property-detail page so the
/// capture flow stays the page's own navigation concern.
typedef StartCapture = void Function();

/// Reads the local panorama without blocking the UI thread.
class _LocalPanoramaBox extends StatelessWidget {
  const _LocalPanoramaBox({required this.path, required this.onOpen});

  final String path;
  final ValueChanged<Uint8List> onOpen;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: File(path).readAsBytes(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final bytes = snap.data;
        if (bytes == null) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(
              child: Text(
                'The local panorama file could not be read.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          );
        }
        return _PanoramaThumbnail(bytes: bytes, onTap: () => onOpen(bytes));
      },
    );
  }
}

/// Fetches and displays the canonical panorama for one backend panorama id.
/// The viewing URL is minted fresh on every load; an expired-URL response is
/// answered with ONE fresh mint before the honest failure is shown.
class _CanonicalPreview extends StatefulWidget {
  const _CanonicalPreview({required this.panoramaId, required this.onOpen});

  final String panoramaId;
  final VoidCallback onOpen;

  @override
  State<_CanonicalPreview> createState() => _CanonicalPreviewState();
}

class _CanonicalPreviewState extends State<_CanonicalPreview> {
  bool _loading = true;
  Uint8List? _bytes;
  String? _failure;
  bool _reResolvedExpiredUrl = false;

  static const _timeout = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final url = await ServiceLocator.panoramaViews.viewUrl(widget.panoramaId);
      final response = await http.get(Uri.parse(url)).timeout(_timeout);
      if (!mounted) return;
      final status = response.statusCode;
      if (status == 200 && response.bodyBytes.isNotEmpty) {
        setState(() {
          _bytes = response.bodyBytes;
          _loading = false;
        });
        return;
      }
      if (status == 401 || status == 403) {
        if (!_reResolvedExpiredUrl) {
          _reResolvedExpiredUrl = true;
          return _load();
        }
        setState(() {
          _loading = false;
          _failure = 'The Sitewise panorama link is not usable right now.';
        });
        return;
      }
      setState(() {
        _loading = false;
        _failure =
            'The Sitewise panorama could not be reached '
            '(server said $status).';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = 'The Sitewise panorama could not be loaded.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, color: Colors.white70),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  _failure ?? 'The Sitewise panorama could not be loaded.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    return _PanoramaThumbnail(bytes: bytes, onTap: widget.onOpen);
  }
}

class _PanoramaThumbnail extends StatelessWidget {
  const _PanoramaThumbnail({required this.bytes, required this.onTap});

  final Uint8List bytes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(bytes, fit: BoxFit.cover, excludeFromSemantics: true),
            const Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.all(12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.all(Radius.circular(18)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.fullscreen_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Tap for full screen',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fullscreen canonical viewing: mints a fresh signed URL, retries an
/// expired link once, then hands the bytes to the interactive viewer.
class _CanonicalFullscreenPage extends StatefulWidget {
  const _CanonicalFullscreenPage({required this.panoramaId});

  final String panoramaId;

  @override
  State<_CanonicalFullscreenPage> createState() =>
      _CanonicalFullscreenPageState();
}

class _CanonicalFullscreenPageState extends State<_CanonicalFullscreenPage> {
  bool _loading = true;
  Uint8List? _bytes;
  String? _failure;
  bool _reResolvedExpiredUrl = false;

  static const _timeout = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final url = await ServiceLocator.panoramaViews.viewUrl(widget.panoramaId);
      final response = await http.get(Uri.parse(url)).timeout(_timeout);
      if (!mounted) return;
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        setState(() {
          _bytes = response.bodyBytes;
          _loading = false;
        });
        return;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        if (!_reResolvedExpiredUrl) {
          _reResolvedExpiredUrl = true;
          return _load();
        }
        setState(() {
          _loading = false;
          _failure = 'The Sitewise panorama link is not usable right now.';
        });
        return;
      }
      setState(() {
        _loading = false;
        _failure =
            'The Sitewise panorama could not be reached '
            '(server said ${response.statusCode}).';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = 'A network problem stopped the panorama from loading.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, color: Colors.white70),
              const SizedBox(height: 8),
              Text(
                _failure ?? 'The panorama could not be loaded.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    return PanoramaFullscreenPage(bytes: bytes);
  }
}
