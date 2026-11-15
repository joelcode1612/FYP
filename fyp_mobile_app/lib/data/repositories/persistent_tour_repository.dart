import 'dart:async';

import 'package:shared_logic/shared_logic.dart';

import '../datasources/local/draft_local_data_source.dart';

/// Device-backed [TourRepository] for the mobile capture flow.
///
/// Capture JPEGs and the AR metadata already live in the app documents
/// directory. This repository persists the small tour record that links those
/// files to a property, so an interrupted capture can be found after the app
/// process is restarted. The records are scoped to the signed-in account (or
/// `device` before sign-in); no access token or other sensitive material is
/// written here.
///
/// This is deliberately a local durability layer, not a pretend replacement
/// for the backend virtual-tour API. The current server schema has a different
/// contract, so a remote repository must be introduced only with its own
/// authenticated API mapping.
class PersistentTourRepository implements TourRepository {
  PersistentTourRepository(
    this._local, {
    List<VirtualTour> Function()? initialTours,
  }) : _initialTours = initialTours ?? _defaultInitialTours;

  static const _workflow = 'virtual_tours_v1';
  static const _schemaVersion = 1;

  final DraftLocalDataSource _local;
  final List<VirtualTour> Function() _initialTours;

  String _namespace = 'device';
  final Map<String, List<VirtualTour>> _stores = {};
  final Map<String, Future<List<VirtualTour>>> _loads = {};
  Future<void> _writeTail = Future.value();

  /// Switches the persistence namespace without deleting another account's
  /// records. The app composition root calls this whenever auth resolves.
  void setAccount(String? userId) {
    final id = userId?.trim();
    _namespace = (id == null || id.isEmpty) ? 'device' : id;
  }

  static List<VirtualTour> _defaultInitialTours() =>
      List<VirtualTour>.from(DemoData.tours);

  @override
  Future<List<VirtualTour>> getToursByOwner(String ownerId) async {
    final store = await _storeFor(_namespace);

    // Persisted mobile records are already account-scoped. A signed-in owner
    // can therefore see every tour in their own namespace, including a newly
    // created listing which is not present in the static demo property list.
    if (_namespace != 'device' && ownerId == _namespace) {
      return List<VirtualTour>.unmodifiable(store);
    }

    // Retain the old demo behaviour before auth is known and for callers
    // asking about another account.
    final ownedPropertyIds = DemoData.properties
        .where((property) => property.ownerId == ownerId)
        .map((property) => property.id)
        .toSet();
    return List<VirtualTour>.unmodifiable(
      store.where((tour) => ownedPropertyIds.contains(tour.propertyId)),
    );
  }

  @override
  Future<VirtualTour?> getTourByProperty(String propertyId) async {
    final store = await _storeFor(_namespace);
    for (final tour in store) {
      if (tour.propertyId == propertyId &&
          tour.published &&
          tour.status == VirtualTourStatus.approved) {
        return tour;
      }
    }
    return null;
  }

  @override
  Future<VirtualTour?> tourForPropertyDraft(String propertyId) async {
    final store = await _storeFor(_namespace);
    VirtualTour? best;
    for (final tour in store) {
      if (tour.propertyId != propertyId ||
          (tour.status != VirtualTourStatus.draft &&
              tour.status != VirtualTourStatus.processing)) {
        continue;
      }
      if (best == null ||
          tour.capturedAt.isAfter(best.capturedAt) ||
          (tour.capturedAt == best.capturedAt &&
              tour.id.compareTo(best.id) > 0)) {
        best = tour;
      }
    }
    return best;
  }

  @override
  Future<VirtualTour?> tourById(String id) async {
    final store = await _storeFor(_namespace);
    for (final tour in store) {
      if (tour.id == id) return tour;
    }
    return null;
  }

  @override
  Future<List<VirtualTour>> pendingTours() async =>
      List<VirtualTour>.unmodifiable(
        (await _storeFor(_namespace)).where(
          (tour) => tour.status == VirtualTourStatus.pendingVerification,
        ),
      );

  @override
  Future<VirtualTour> createDraft({
    required String propertyId,
    required String title,
    required int frameCount,
  }) => _mutate((store) {
    final tour = VirtualTour(
      id: 't-${DateTime.now().microsecondsSinceEpoch}',
      propertyId: propertyId,
      title: title,
      sceneCount: frameCount,
      capturedAt: DateTime.now(),
      published: false,
      status: VirtualTourStatus.draft,
      frameCount: frameCount,
    );
    store.add(tour);
    return tour;
  });

  @override
  Future<void> updateTour(VirtualTour tour) => _mutate((store) {
    final index = store.indexWhere((existing) => existing.id == tour.id);
    if (index >= 0) store[index] = tour;
  });

  @override
  Future<void> deleteTour(String id) => _mutate((store) {
    store.removeWhere((tour) => tour.id == id);
  });

  Future<List<VirtualTour>> _storeFor(String namespace) {
    final cached = _stores[namespace];
    if (cached != null) return Future.value(cached);
    return _loads.putIfAbsent(namespace, () async {
      final payload = await _local.read(namespace, _workflow);
      // Always own a mutable copy: callers may deliberately provide a const
      // empty seed in tests, while mutations below must remain possible.
      final store = _decode(payload) ?? List<VirtualTour>.from(_initialTours());
      _stores[namespace] = store;
      return store;
    });
  }

  /// Serialises mutations so rapid frame-progress callbacks cannot overwrite a
  /// newer tour record with an older in-memory snapshot.
  Future<T> _mutate<T>(T Function(List<VirtualTour> store) action) {
    final namespace = _namespace;
    final result = Completer<T>();

    Future<void> run() async {
      try {
        final store = await _storeFor(namespace);
        final value = action(store);
        await _local.write(namespace, _workflow, _encode(store));
        result.complete(value);
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }

    _writeTail = _writeTail.then<void>((_) => run(), onError: (_, _) => run());
    return result.future;
  }

  Map<String, dynamic> _encode(List<VirtualTour> tours) => {
    'version': _schemaVersion,
    'tours': [
      for (final tour in tours)
        {
          'id': tour.id,
          'property_id': tour.propertyId,
          'title': tour.title,
          'scene_count': tour.sceneCount,
          'captured_at': tour.capturedAt.toIso8601String(),
          'published': tour.published,
          'status': tour.status.name,
          'panorama_path': tour.panoramaPath,
          'frame_count': tour.frameCount,
        },
    ],
  };

  List<VirtualTour>? _decode(Map<String, dynamic>? payload) {
    if (payload == null || payload['version'] != _schemaVersion) return null;
    final rawTours = payload['tours'];
    if (rawTours is! List) return null;

    final tours = <VirtualTour>[];
    for (final raw in rawTours) {
      final record = _stringKeyedMap(raw);
      final tour = record == null ? null : _tourFromRecord(record);
      if (tour != null) tours.add(tour);
    }
    return tours;
  }

  Map<String, dynamic>? _stringKeyedMap(Object? raw) {
    if (raw is! Map) return null;
    return {for (final entry in raw.entries) '${entry.key}': entry.value};
  }

  VirtualTour? _tourFromRecord(Map<String, dynamic> record) {
    final id = record['id'] as String?;
    final propertyId = record['property_id'] as String?;
    final title = record['title'] as String?;
    final capturedAt = DateTime.tryParse(
      record['captured_at'] as String? ?? '',
    );
    final statusName = record['status'] as String?;
    if (id == null ||
        id.isEmpty ||
        propertyId == null ||
        propertyId.isEmpty ||
        title == null ||
        capturedAt == null ||
        statusName == null) {
      return null;
    }

    final status = switch (statusName) {
      'draft' => VirtualTourStatus.draft,
      'processing' => VirtualTourStatus.processing,
      'ready' => VirtualTourStatus.ready,
      'pendingVerification' => VirtualTourStatus.pendingVerification,
      'approved' => VirtualTourStatus.approved,
      'rejected' => VirtualTourStatus.rejected,
      _ => null,
    };
    if (status == null) return null;

    return VirtualTour(
      id: id,
      propertyId: propertyId,
      title: title,
      sceneCount: (record['scene_count'] as num?)?.toInt() ?? 0,
      capturedAt: capturedAt,
      published: record['published'] == true,
      status: status,
      panoramaPath: record['panorama_path'] is String
          ? record['panorama_path'] as String
          : null,
      frameCount: (record['frame_count'] as num?)?.toInt() ?? 0,
    );
  }
}
