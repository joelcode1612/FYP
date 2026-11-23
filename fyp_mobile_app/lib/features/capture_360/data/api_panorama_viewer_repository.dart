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
    final propertyId = int.tryParse('${json['propertyId']}');
    if (propertyId == null || propertyId <= 0) {
      throw const ResponseFormatFailure(
        'The panorama response has an invalid property ID.',
      );
    }
    return CanonicalPanorama(
      panoramaId: json['panoramaId'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      propertyId: propertyId,
      storagePath: json['storagePath'] as String? ?? '',
      format: json['format'] as String? ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      verificationStatus: json['verificationStatus'] as String? ?? '',
      publishedAt: _date(json['publishedAt']),
      createdAt:
          _date(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static DateTime? _date(Object? value) =>
      value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
}

/// One published panorama exactly what
/// `GET /api/v1/360/published/properties/{id}` returns: the SAME
/// authoritative record the Jaspr property-detail viewer reads, resolved
/// through the canonical `fyp.panoramas` row first and the reviewed legacy
/// bridge second. Entrepreneur access needs no owner/agent permission.
class PublishedPanorama {
  const PublishedPanorama({
    required this.panoramaId,
    required this.viewUrl,
    required this.expiresInSeconds,
  });

  final String panoramaId;
  final String viewUrl;
  final int expiresInSeconds;

  factory PublishedPanorama.fromJson(Map<String, dynamic> json) {
    return PublishedPanorama(
      panoramaId: json['panoramaId'] as String? ?? '',
      viewUrl: json['viewUrl'] as String? ?? '',
      expiresInSeconds: (json['expiresInSeconds'] as num?)?.toInt() ?? 0,
    );
  }
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
      final panorama = CanonicalPanorama.fromJson(payload);
      if (panorama.propertyId != propertyId || panorama.panoramaId.isEmpty) {
        throw const ResponseFormatFailure(
          'The panorama response does not identify a tour for this property.',
        );
      }
      return panorama;
    } on NotFoundFailure {
      return null;
    }
  }

  /// The entrepreneur-facing published tour for [propertyRef], `null` when
  /// no approved+published panorama exists. [propertyRef] may be the
  /// operational numeric listing id OR a verified research catalogue ref
  /// (MD-/EP-) — the backend resolves both through verified links and fails
  /// closed on ambiguity. Unpublished and rejected panoramas answer 404 here
  /// by construction — the client cannot leak a private tour by probing.
  Future<PublishedPanorama?> publishedByProperty(String propertyRef) async {
    final reference = propertyRef.trim();
    if (reference.isEmpty || reference.length > 100) return null;
    try {
      final payload = await _client.get(
        '/api/v1/360/published/properties/$reference',
      );
      final parsed = PublishedPanorama.fromJson(payload);
      if (parsed.panoramaId.isEmpty || parsed.viewUrl.isEmpty) return null;
      return parsed;
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
