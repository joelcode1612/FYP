import 'dart:typed_data';

import 'package:shared_logic/shared_logic.dart';

/// Uses the existing authenticated owner photo endpoints. No new storage path.
class PrimaryPropertyPhoto {
  const PrimaryPropertyPhoto(this.id, this.url);
  final String id;
  final String url;

  static PrimaryPropertyPhoto? fromRow(Object? value) {
    if (value is! Map || value['is_primary'] != true) return null;
    final id = value['id']?.toString() ?? '';
    final url = value['url']?.toString().trim() ?? '';
    return id.isEmpty || url.isEmpty ? null : PrimaryPropertyPhoto(id, url);
  }
}

class SelectedPropertyPhoto {
  const SelectedPropertyPhoto(this.name, this.bytes, this.contentType);
  final String name;
  final Uint8List bytes;
  final String contentType;
}

class PrimaryPropertyPhotoService {
  const PrimaryPropertyPhotoService(this.api);
  final ApiClient api;

  String _path(String propertyId) => '/api/v1/properties/listings/$propertyId/photos';

  Future<PrimaryPropertyPhoto?> read(String propertyId) async {
    final response = await api.get(_path(propertyId));
    final data = response['data'];
    if (data is! List) throw StateError('Photo status unavailable.');
    for (final row in data) {
      final primary = PrimaryPropertyPhoto.fromRow(row);
      if (primary != null) return primary;
    }
    return null;
  }

  Future<PrimaryPropertyPhoto> upload(String propertyId, SelectedPropertyPhoto photo) async {
    final response = await api.uploadMultipart(
      _path(propertyId),
      fields: const {'caption': '', 'is_primary': 'true'},
      fileField: 'file',
      filename: photo.name,
      bytes: photo.bytes,
      contentType: photo.contentType,
    );
    final primary = PrimaryPropertyPhoto.fromRow(response['data']);
    if (primary == null) throw StateError('Could not confirm the uploaded photo.');
    return primary;
  }

  Future<Map<String, dynamic>> addPhoto(
    String propertyId,
    SelectedPropertyPhoto photo, {
    required bool isPrimary,
  }) async {
    final response = await api.uploadMultipart(
      _path(propertyId),
      fields: {'caption': '', 'is_primary': isPrimary ? 'true' : 'false'},
      fileField: 'file',
      filename: photo.name,
      bytes: photo.bytes,
      contentType: photo.contentType,
    );
    final row = response['data'];
    if (row is! Map<String, dynamic>) {
      throw StateError('The property photo was not confirmed.');
    }
    return row;
  }

  Future<void> removePhoto(String propertyId, String photoId) async {
    await api.delete('${_path(propertyId)}/$photoId');
  }
}
