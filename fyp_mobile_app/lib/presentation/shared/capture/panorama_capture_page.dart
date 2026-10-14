import 'package:shared_logic/shared_logic.dart';
import 'package:ar_flutter_plugin/ar_flutter_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../application/services/service_locator.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../viewmodels/panorama_capture_viewmodel.dart';
import 'capture_guidance_overlay.dart';

/// On-device AR panorama capture screen (Owner → 360° Tours → Capture).
///
/// Full-screen camera view with minimal overlays: session-state banner,
/// progress header, centred alignment guidance, and a bottom capture bar
/// (manual capture, retake, generate). All capture state lives in
/// [PanoramaCaptureViewModel]; this widget only renders it and owns the
/// camera-polling ticker.

class PanoramaCapturePage extends StatefulWidget {
  final String? propertyId;

  const PanoramaCapturePage({super.key, this.propertyId});

  @override
  State<PanoramaCapturePage> createState() => _PanoramaCapturePageState();
}

class _PanoramaCapturePageState extends State<PanoramaCapturePage>
    with SingleTickerProviderStateMixin {
  late final PanoramaCaptureViewModel _vm;
  late final Ticker _ticker;
  bool _navigatedToPreview = false;

  @override
  void initState() {
    super.initState();
    final pid = widget.propertyId ?? 'unassigned';
    final stored = ServiceLocator.captureSessions.forProperty(pid);
    _vm = PanoramaCaptureViewModel(
      session: stored?.service ?? ServiceLocator.newPanoramaCaptureService(),
      ar: ServiceLocator.newArCaptureService(),
    );
    _vm.startSession(pid);
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration _) {
    _vm.pollCameraPose();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _vm.dispose();
    super.dispose();
  }

  Future<void> _onGenerate() async {
    final ok = await _vm.generatePanorama();
    if (!mounted) return;
    if (ok && _vm.tourId != null && !_navigatedToPreview) {
      _navigatedToPreview = true;
      Navigator.of(
        context,
      ).pushNamed('/owner/tour-preview', arguments: _vm.tourId);
    } else if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_vm.error ?? 'Generation failed.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _vm,
      builder: (context, _) {
        final target = _vm.currentTarget;
        final total = _vm.targets.length;
        final showGenerate =
            _vm.allCaptured &&
            (_vm.sessionState == CaptureSessionState.guiding ||
                _vm.sessionState == CaptureSessionState.stabilizing);
        return Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            foregroundColor: Colors.white,
            title: Text(
              _vm.allCaptured
                  ? 'All frames captured'
                  : 'Frame ${_vm.capturedCount + 1} of $total',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
              ),
            ),
          ),
          body: Stack(
            children: [
              ARView(onARViewCreated: _vm.onARViewCreated),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 64, 16, 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: _vm.progress,
                          minHeight: 6,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation(
                            SitewiseColors.success,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _StateBanner(
                        label: _vm.stateLabel,
                        warning:
                            _vm.positionWarning ||
                            _vm.sessionState == CaptureSessionState.error ||
                            _vm.error != null,
                      ),
                    ],
                  ),
                ),
              ),
              Center(
                child: CaptureGuidanceOverlay(
                  yawDeg: _vm.yawDeg,
                  pitchDeg: _vm.pitchDeg,
                  aligned: _vm.aligned,
                ),
              ),
              if (_vm.generating)
                Container(
                  color: Colors.black54,
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 12),
                            Text(_vm.stage ?? 'Processing…'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (target != null && !_vm.allCaptured)
                          Text(
                            target.name,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              shadows: [
                                Shadow(blurRadius: 8, color: Colors.black54),
                              ],
                            ),
                          ),
                        if (_vm.sessionState == CaptureSessionState.stabilizing)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: SizedBox(
                              width: 160,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: _vm.stability,
                                  minHeight: 5,
                                  backgroundColor: Colors.white24,
                                  valueColor: const AlwaysStoppedAnimation(
                                    SitewiseColors.success,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (_vm.error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _vm.error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.amberAccent,
                                fontSize: 13,
                                shadows: [
                                  Shadow(blurRadius: 4, color: Colors.black54),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        if (showGenerate)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              FloatingActionButton.extended(
                                backgroundColor: SitewiseColors.success,
                                foregroundColor: Colors.white,
                                onPressed: _onGenerate,
                                icon: const Icon(Icons.auto_awesome),
                                label: const Text('Generate panorama'),
                              ),
                            ],
                          )
                        else
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_vm.capturedCount > 0)
                                Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: FloatingActionButton(
                                    heroTag: 'retake',
                                    mini: true,
                                    backgroundColor: Colors.white24,
                                    foregroundColor: Colors.white,
                                    tooltip: 'Retake last frame',
                                    onPressed: _vm.generating
                                        ? null
                                        : () => _vm.retakeLast(),
                                    child: const Icon(Icons.refresh),
                                  ),
                                ),
                              FloatingActionButton.extended(
                                backgroundColor: _vm.aligned
                                    ? SitewiseColors.success
                                    : SitewiseColors.action,
                                foregroundColor: Colors.white,
                                onPressed: _vm.canCapture
                                    ? () => _vm.captureManual()
                                    : null,
                                icon: const Icon(Icons.camera_alt),
                                label: Text(
                                  _vm.sessionState ==
                                          CaptureSessionState.capturing
                                      ? 'Capturing…'
                                      : 'Capture',
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StateBanner extends StatelessWidget {
  final String label;
  final bool warning;

  const _StateBanner({required this.label, required this.warning});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: warning ? Colors.amber.shade700 : Colors.black54,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}
