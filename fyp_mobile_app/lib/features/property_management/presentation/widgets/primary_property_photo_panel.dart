import 'package:camera/camera.dart' as camera;
import 'package:file_selector/file_selector.dart' as files;
import 'package:flutter/material.dart';
import 'package:fyp/features/property_management/data/primary_property_photo_service.dart';

Future<SelectedPropertyPhoto?> choosePrimaryPropertyPhoto(BuildContext context) async {
  final source = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Add a property photo', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        ListTile(leading: const Icon(Icons.camera_alt_outlined), title: const Text('Take photo'), onTap: () => Navigator.pop(sheet, 'camera')),
        ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from gallery'), onTap: () => Navigator.pop(sheet, 'gallery')),
      ]),
    ),
  );
  if (source == null || !context.mounted) return null;
  final files.XFile? picked;
  if (source == 'camera') {
    picked = await Navigator.of(context).push<camera.XFile>(MaterialPageRoute(builder: (_) => const _OrdinaryPhotoCamera()));
  } else {
    picked = await files.openFile(acceptedTypeGroups: const [files.XTypeGroup(label: 'Property photos', extensions: ['jpg','jpeg','png','webp'], mimeTypes: ['image/jpeg','image/png','image/webp'])]);
  }
  if (picked == null) return null;
  final lower = picked.name.toLowerCase();
  final type = lower.endsWith('.jpg') || lower.endsWith('.jpeg') ? 'image/jpeg' : lower.endsWith('.png') ? 'image/png' : lower.endsWith('.webp') ? 'image/webp' : null;
  if (type == null) throw const FormatException('Choose a JPG, PNG or WebP photo.');
  final size = await picked.length();
  if (size <= 0 || size > 8 * 1024 * 1024) throw const FormatException('Choose a photo smaller than 8 MB.');
  final bytes = await picked.readAsBytes();
  if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) throw const FormatException('Choose a photo smaller than 8 MB.');
  return SelectedPropertyPhoto(picked.name, bytes, type);
}

/// Ordinary still camera; deliberately does not touch the 360 capture flow.
class _OrdinaryPhotoCamera extends StatefulWidget {
  const _OrdinaryPhotoCamera();
  @override
  State<_OrdinaryPhotoCamera> createState() => _OrdinaryPhotoCameraState();
}

class _OrdinaryPhotoCameraState extends State<_OrdinaryPhotoCamera> with WidgetsBindingObserver {
  camera.CameraController? _controller;
  bool _busy = false;
  bool _failed = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }
  Future<void> _open() async {
    final generation = ++_generation;
    camera.CameraController? candidate;
    try {
      final cameras = await camera.availableCameras();
      if (!mounted || generation != _generation) return;
      if (cameras.isEmpty) throw StateError('No camera');
      final back = cameras.where((item) => item.lensDirection == camera.CameraLensDirection.back);
      candidate = camera.CameraController(back.isEmpty ? cameras.first : back.first, camera.ResolutionPreset.high, enableAudio: false);
      await candidate.initialize();
      if (!mounted || generation != _generation) { await candidate.dispose(); return; }
      setState(() { _controller = candidate; _failed = false; });
    } catch (_) {
      await candidate?.dispose();
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_controller == null) _open();
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      ++_generation;
      final old = _controller;
      if (mounted) setState(() { _controller = null; _busy = false; });
      old?.dispose();
    }
  }
  @override
  void dispose() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }
  Future<void> _capture() async {
    final current = _controller;
    if (current == null || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await current.takePicture();
      if (mounted && identical(_controller, current)) Navigator.pop(context, result);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not take a photo. Try again.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Property photo')),
      body: SafeArea(child: Column(children: [
        Expanded(child: Center(child: controller != null && controller.value.isInitialized
          ? camera.CameraPreview(controller)
          : _failed ? const Text('Camera unavailable. Go back and choose a photo from the gallery.') : const CircularProgressIndicator())),
        Padding(padding: const EdgeInsets.all(16), child: SizedBox(width: double.infinity, height: 52, child: FilledButton.icon(onPressed: controller == null || _busy ? null : _capture, icon: const Icon(Icons.camera_alt_outlined), label: const Text('Take photo')))),
      ])),
    );
  }
}

class PrimaryPropertyPhotoPanel extends StatelessWidget {
  const PrimaryPropertyPhotoPanel({super.key, this.saved, this.selected, required this.busy, required this.known, this.onPick, this.onClear, this.message});
  final PrimaryPropertyPhoto? saved;
  final SelectedPropertyPhoto? selected;
  final bool busy;
  final bool known;
  final VoidCallback? onPick;
  final VoidCallback? onClear;
  final String? message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Property photo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(selected != null ? 'Selected — not uploaded yet' : saved != null ? 'Primary photo uploaded' : known ? 'Add a clear photo before requesting an Agent.' : 'Checking property photo status…'),
      if (selected != null || saved != null) ...[
        const SizedBox(height: 12),
        ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(height: 150, child: selected != null
          ? Image.memory(selected!.bytes, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Center(child: Text('Photo preview unavailable')))
          : Image.network(saved!.url, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Center(child: Text('Photo preview unavailable'))))),
      ],
      if (message != null) ...[const SizedBox(height: 8), Text(message!, style: TextStyle(color: Theme.of(context).colorScheme.error))],
      if (busy) ...[const SizedBox(height: 12), const LinearProgressIndicator(), const SizedBox(height: 6), const Text('Please wait…')],
      if (onPick != null) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: busy ? null : onPick, style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)), icon: const Icon(Icons.add_a_photo_outlined), label: Text(saved != null || selected != null ? 'Replace photo' : 'Upload photo')),
      ],
      if (selected != null && onClear != null) TextButton(onPressed: busy ? null : onClear, child: const Text('Remove selected photo')),
    ]),
  );
}
