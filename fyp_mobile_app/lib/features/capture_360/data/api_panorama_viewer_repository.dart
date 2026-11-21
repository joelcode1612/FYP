import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/mobile_api_client.dart';

/// One backend-stitched panorama, exactly what
/// `GET /api/v1/360/properties/{id}/panorama` returns. This is the canonical
/// record — the row the durable worker writes when a job succeeds — not a
/// device-local mirror of it.
class CanonicalPanorama {
  const CanonicalPanorama({
    required this.panoramaId,
    required this.sessionId,
    required this.propertyId,
    required this.storagePath,
    required this.format,
    required this.width,
    required this.height,
    required this.verificationStatus,
    this.publishedAt,
    required this.createdAt,
  });

  final String panoramaId;
  final String sessionId;
  final int propertyId;
  final String storagePath;
  final String format;
  final int width;
  final int height;
  final String verificationStatus;
  final DateTime? publishedAt;
  final DateTime createdAt;

  factory CanonicalPanorama.fromJson(Map<String, dynamic> json) {
    return CanonicalPanorama(
      panoramaId: json['panoramaId'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      propertyId: (json['propertyId'] as num?)?.toInt() ?? 0,
      storagePath: json['storagePath'] as String? ?? '',
      format: json['format'] as String? ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      verificationStatus: json['verificationStatus'] as String? ?? '',
      publishedAt: _date(json['publishedAt']),
      createdAt: _date(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static DateTime? _date(Object? value) =>
      value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
}

/// Authorized reads of the canonical panorama for the viewers (spec §14).
///
/// The metadata endpoint and the view endpoint are both provider-scoped
/// (owner, assigned agent, administrator) — the client sends no identity of
/// its own and never sees a storage key it could reuse: every viewing URL is
/// minted fresh by the backend and expires.
class ApiPanoramaViewerRepository {
  ApiPanoramaViewerRepository(this._client);

  final MobileApiClient _client;

  /// The property's latest canonical panorama, `null` when the backend has
  /// none for this property yet (which is the honest "not captured" state —
  /// the 404 IS the answer, not an error).
  Future<CanonicalPanorama?> latestForProperty(int propertyId) async {
    try {
      final payload = await _client.get(
        '/api/v1/360/properties/$propertyId/panorama',
      );
      return CanonicalPanorama.fromJson(payload);
    } on NotFoundFailure {
      return null;
    }
  }

  /// A fresh temporary viewing URL for [panoramaId]. Signed URLs expire, so
  /// a viewer that hits 401/403 must call this again rather than retrying the
  /// stale URL.
  Future<String> viewUrl(String panoramaId) async {
    final payload = await _client.get('/api/v1/360/panoramas/$panoramaId/view');
    final url = payload['viewUrl'];
    if (url is String && url.isNotEmpty) return url;
    throw const ResponseFormatFailure(
      'The Sitewise service stored the panorama but returned no viewing URL.',
    );
  }
}
