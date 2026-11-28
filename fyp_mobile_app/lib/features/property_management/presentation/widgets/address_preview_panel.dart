import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_logic/shared_logic.dart';

/// Address status and scroll-safe location preview for Add Property.
class AddressPreviewPanel extends StatelessWidget {
  const AddressPreviewPanel({
    super.key,
    required this.status,
    required this.pending,
    required this.verified,
    required this.locationAvailable,
    required this.confirmed,
    required this.retry,
    this.preview,
    this.formattedAddress,
    this.errorText,
    this.onVerify,
    this.mapHeight = 160,
  });

  final String status;
  final bool pending;
  final bool verified;
  final bool locationAvailable;
  final bool confirmed;
  final bool retry;
  final AddressPreview? preview;
  final String? formattedAddress;
  final String? errorText;
  final VoidCallback? onVerify;

  /// Compact height for the Review step's read-before-save preview.
  final double mapHeight;

  @override
  Widget build(BuildContext context) {
    final data = preview;
    final precision = locationAvailable ? data?.precision : null;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: verified ? SitewiseM3.greenWash : SitewiseM3.surface,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusField),
        border: Border.all(color: SitewiseM3.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              status,
              style: TextStyle(
                color: verified ? SitewiseM3.green : SitewiseM3.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (pending) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          if (errorText case final String message)
            Text(message, style: const TextStyle(color: SitewiseM3.muted)),
          if (formattedAddress case final String address) Text(address),
          if (precision case final String value)
            Text(
              'Location confidence: $value',
              style: const TextStyle(color: SitewiseM3.muted),
            ),
          if (locationAvailable && data != null && data.hasLocation) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: double.infinity,
                height: mapHeight,
                child: IgnorePointer(
                  child: _buildMap(data, interactive: false),
                ),
              ),
            ),
            _attribution,
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _openFullMap(context, data),
                icon: const Icon(Icons.open_in_full),
                label: const Text('Open full map'),
              ),
            ),
          ],
          if (confirmed) const Text('Location confirmed'),
          if (onVerify != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onVerify,
                child: Text(retry ? 'Retry verification' : 'Verify address'),
              ),
            ),
        ],
      ),
    );
  }

  static const _attribution = Text(
    'Map data © OpenStreetMap contributors.',
    style: TextStyle(fontSize: 11, color: SitewiseM3.muted),
  );

  void _openFullMap(BuildContext context, AddressPreview data) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Property location')),
          body: _buildMap(data, interactive: true),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(data.formattedAddress!), _attribution],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMap(AddressPreview data, {required bool interactive}) {
    final LatLng point = LatLng(data.latitude!, data.longitude!);
    // Keyed on the point so a fresh match recentres deterministically.
    return FlutterMap(
      key: ValueKey<LatLng>(point),
      options: MapOptions(
        initialCenter: point,
        initialZoom: 16,
        interactionOptions: InteractionOptions(
          flags: interactive
              ? InteractiveFlag.drag |
                    InteractiveFlag.pinchZoom |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.scrollWheelZoom
              : InteractiveFlag.none,
        ),
      ),
      children: <Widget>[
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'app.sitewise.fyp',
        ),
        MarkerLayer(
          markers: <Marker>[
            Marker(
              width: 36,
              height: 46,
              point: point,
              alignment: Alignment.topCenter,
              child: const Icon(
                Icons.location_on,
                size: 36,
                color: SitewiseM3.primary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
