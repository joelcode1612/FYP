import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' as legacy;
import 'package:shared_logic/shared_logic.dart';
import '../../../application/services/service_locator.dart';
import '../../../core/config/cq_development_access.dart';
import '../../../data/repositories/mobile_api_client.dart';

final cqRepositoryProvider = Provider<ApiCustomerQuestionnaireRepository>(
  (ref) => ApiCustomerQuestionnaireRepository(
    CqDevelopmentAccess.enabled
        ? MobileApiClient(
            bearer: () => CqDevelopmentAccess.bearer,
            baseUrl: CqDevelopmentAccess.apiBaseUrl,
          )
        : ServiceLocator.apiClient,
    allowIsolatedTesting: CqDevelopmentAccess.enabled,
  ),
);
final cqViewModelProvider = legacy.ChangeNotifierProvider.autoDispose
    .family<CqViewModel, String>(
      (ref, id) => CqViewModel(ref.watch(cqRepositoryProvider), id),
    );

/// Owns presentation state only. The server supplies every route and effective
/// answer; local preview drafts are never promoted to customer observations.
class CqViewModel extends ChangeNotifier {
  final ApiCustomerQuestionnaireRepository repository;
  final String sessionId;
  CqViewModel(this.repository, this.sessionId);
  CqSession? session;
  bool busy = false, withdrawn = false;
  String? error;
  final Set<String> selected = {};
  Future<void> Function()? _retry;
  bool _disposed = false;
  bool _mustReload = false;
  static String requestId() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _set(CqSession s) {
    session = s;
    selected.clear();
    final p = s.presentation;
    if (p != null) {
      final row = s.routing.firstWhere((r) => r['slot_id'] == p['slot_id']);
      final value = row['value'];
      if (value is List) selected.addAll(value.cast<String>());
      if (value is String) selected.add(value);
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    _retry = operation;
    _notify();
    try {
      await operation();
      _retry = null;
    } on ConflictFailure catch (e) {
      error = e.message;
      _mustReload = true;
      _retry = null;
    } on ThrottledFailure {
      error =
          'The service is busy. Try again later; no automatic retry was made.';
    } on AppFailure catch (e) {
      error = e.message;
    } on FormatException catch (e) {
      error = e.message;
    } catch (_) {
      error =
          'The questionnaire could not be loaded. Reload the saved session to continue.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _presentNext() async {
    final s = session!;
    if (s.data['next_slot_id'] != null &&
        s.data['next_stimulus_kind'] == null) {
      _set(await repository.present(s));
    }
  }

  Future<void> load() => _run(() async {
    _set(await repository.read(sessionId, previous: session));
    _mustReload = false;
    await _presentNext();
  });
  Future<void> retry() async {
    final action = _retry;
    if (_mustReload) {
      await load();
    } else if (action != null) {
      await _run(action);
    } else {
      await load();
    }
  }

  Future<void> consent() {
    final s = session!, id = requestId();
    return _run(() async {
      _set(await repository.consent(s, id));
      await _presentNext();
    });
  }

  Future<void> stimulus() {
    final s = session!;
    final acknowledgedKind = s.data['next_stimulus_kind'];
    return _run(() async {
      // Delivery has no client authority. On an uncertain response, reload
      // before retrying so a recorded delivery is not sent as a new revision.
      _set(await repository.read(s.id, previous: s));
      final current = session!;
      if (acknowledgedKind != null &&
          current.data['next_stimulus_kind'] == acknowledgedKind) {
        _set(
          await repository.deliverStimulus(
            current,
            current.data['next_stimulus_kind'] as String,
          ),
        );
      }
      await _presentNext();
    });
  }

  Map<String, dynamic>? get question {
    final p = session?.presentation;
    return p == null ? null : session!.question(p['slot_id'] as String);
  }

  void choose(String code) {
    if (busy || error != null) return;
    final q = question!;
    if ((q['type'] as String).startsWith('multi_select')) {
      if (selected.contains(code)) {
        selected.remove(code);
      } else {
        selected.add(code);
      }
    } else {
      selected
        ..clear()
        ..add(code);
    }
    _notify();
  }

  Future<void> answer({bool skip = false}) {
    final s = session!, p = s.presentation!, q = question!, id = requestId();
    final Object? value = skip
        ? null
        : (q['type'] as String).startsWith('multi_select')
        ? selected.toList()
        : selected.firstOrNull;
    final body = {
      'request_id': id,
      'display_id': p['display_id'],
      'slot_id': p['slot_id'],
      'value': value,
    };
    return _run(() async {
      _set(
        await repository.answer(
          s,
          requestId: id,
          displayId: body['display_id'] as String,
          slotId: body['slot_id'] as String,
          value: value,
        ),
      );
      await _presentNext();
    });
  }

  Future<void> edit(String slot) => _run(() async {
    _set(await repository.present(session!, editSlotId: slot));
  });
  Future<void> pause() {
    final s = session!, id = requestId();
    return _run(() async {
      _set(await repository.pause(s, id));
    });
  }

  Future<void> resume() {
    final s = session!, id = requestId();
    return _run(() async {
      _set(await repository.resume(s, id));
      await _presentNext();
    });
  }

  Future<void> acknowledgeRendered(String displayId) {
    final s = session;
    if (s == null ||
        s.presentation?['display_id'] != displayId ||
        s.presentation?['rendered'] == true) {
      return Future.value();
    }
    return _run(() async {
      _set(await repository.rendered(s));
    });
  }

  Future<void> submit() {
    final s = session!, id = requestId();
    return _run(() async {
      _set(await repository.submit(s, id));
    });
  }

  Future<void> withdraw() {
    final s = session!, id = requestId();
    return _run(() async {
      await repository.withdraw(s, id);
      withdrawn = true;
      session = null;
      selected.clear();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
