/// Read-only address preview returned by
/// `POST /api/v1/properties/address-preview`.
///
/// The backend resolves the typed Malaysian address through its provider
/// chain (Google Address Validation first, then the Malaysian fallback
/// geocoder), classifies the match against the typed components, and — when
/// a usable location was found — returns an HMAC-signed confirmation token
/// bound to the exact canonical address. Nothing is persisted by the call;
/// the token is later accepted by the draft endpoints only while the stored
/// address still hashes identically.
///
/// Coordinates and the formatted address are SERVER-derived evidence. No
/// client-side latitude/longitude is ever trusted by the backend.
library;

/// How well the provider result matches the typed address.
enum AddressMatchClass {
  precise,
  approximate,
  ambiguous,
  notFound,
  serviceUnavailable;

  static AddressMatchClass fromWire(String? value) => switch (value) {
    'precise' => precise,
    'approximate' => approximate,
    'ambiguous' => ambiguous,
    'not_found' => notFound,
    'service_unavailable' => serviceUnavailable,
    _ => serviceUnavailable,
  };

  /// Short, non-technical status line for the preview panel.
  String get label => switch (this) {
    precise => 'Precise match found',
    approximate => 'Approximate match found',
    ambiguous => 'Possible other location — check carefully',
    notFound => 'No matching location found',
    serviceUnavailable => 'Address service unavailable',
  };
}

/// Signature payload the draft endpoints accept as
/// `address_confirmation_token` after the user confirms the location.
class AddressConfirmation {
  final String token;
  final int expiresInSeconds;
  final String addressHash;

  const AddressConfirmation({
    required this.token,
    required this.expiresInSeconds,
    required this.addressHash,
  });

  static AddressConfirmation? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final token = json['token'];
    if (token is! String || token.isEmpty) return null;
    return AddressConfirmation(
      token: token,
      expiresInSeconds: (json['expires_in_seconds'] as num?)?.toInt() ?? 0,
      addressHash: json['address_hash'] is String
          ? json['address_hash'] as String
          : '',
    );
  }
}

class AddressPreview {
  final AddressMatchClass matchClass;
  final String? provider;
  final String? status;
  final String? formattedAddress;
  final String? normalizedAddress;
  final Map<String, String> enteredAddress;
  final DateTime? verifiedAt;
  final double? latitude;
  final double? longitude;
  final String? precision;

  /// Component agreement between the typed address and the provider result.
  final Map<String, bool> components;
  final List<String> notes;
  final String addressHash;
  final AddressConfirmation? confirmation;

  const AddressPreview({
    required this.matchClass,
    required this.components,
    required this.notes,
    required this.addressHash,
    this.provider,
    this.status,
    this.formattedAddress,
    this.normalizedAddress,
    this.enteredAddress = const {},
    this.verifiedAt,
    this.latitude,
    this.longitude,
    this.precision,
    this.confirmation,
  });

  bool get hasLocation {
    final lat = latitude;
    final lon = longitude;
    return lat != null &&
        lon != null &&
        lat.isFinite &&
        lon.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lon >= -180 &&
        lon <= 180 &&
        (lat != 0 || lon != 0) &&
        (formattedAddress?.trim().isNotEmpty ?? false);
  }

  /// A confirmation the user can accept: a located match with signed
  /// evidence. `ambiguous` results stay confirmable on purpose — the UI
  /// must warn, and the user decides whether the shown place is right.
  bool get confirmable => hasLocation && confirmation != null;

  /// Whether the location was matched at premise level by the provider.
  bool get isPrecise => matchClass == AddressMatchClass.precise;

  static AddressPreview fromJson(Map<String, dynamic> json) => AddressPreview(
    matchClass: AddressMatchClass.fromWire(json['match_class'] as String?),
    provider: json['provider'] as String?,
    status: json['status'] as String?,
    formattedAddress: json['formatted_address'] as String?,
    normalizedAddress: json['normalized_address'] as String?,
    enteredAddress:
        (json['entered_address'] as Map?)?.cast<String, String>() ?? const {},
    verifiedAt: DateTime.tryParse(json['verified_at']?.toString() ?? ''),
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
    precision: json['precision'] as String?,
    components: Map<String, bool>.from(
      (json['components'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value == true),
          ) ??
          const {},
    ),
    notes: [
      for (final note in (json['notes'] as List?) ?? const [])
        if (note is String && note.isNotEmpty) note,
    ],
    addressHash: json['address_hash'] is String
        ? json['address_hash'] as String
        : '',
    confirmation: AddressConfirmation.fromJson(
      json['confirmation'] is Map
          ? (json['confirmation'] as Map).cast<String, dynamic>()
          : null,
    ),
  );
}
