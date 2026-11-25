import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

class _DraftClient extends ApiClient {
  _DraftClient(this.response);

  final Map<String, dynamic> response;
  final patches = <Map<String, dynamic>>[];
  String? patchPath;
  AppFailure? readFailure;

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async => response;

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    patchPath = path;
    patches.add(body);
    return {
      'data': {'id': 42, ...body},
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (readFailure case final failure?) throw failure;
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'replayed create applies only later changes to the returned ID',
    () async {
      final client = _DraftClient({
        'data': {'id': 42, 'name': 'First title'},
        'meta': {'replayed': true},
      });
      final repo = ApiOwnerListingRepository(client);

      final saved = await repo.createDraft(
        {'name': 'Edited title', 'draft_request_id': 'existing-request'},
        replayPatch: {'name': 'Edited title'},
      );

      expect(saved.id, '42');
      expect(saved.name, 'Edited title');
      expect(client.patchPath, '/api/v1/properties/listings/42');
      expect(client.patches, [
        {'name': 'Edited title'},
      ]);
    },
  );

  test('a missing property ID cannot acknowledge a successful write', () async {
    final client = _DraftClient({
      'data': {'name': 'Draft'},
    });
    var mutations = 0;
    final repo = ApiOwnerListingRepository(
      client,
      onMutated: () => mutations++,
    );

    await expectLater(
      repo.createDraft({'name': 'Draft'}),
      throwsA(isA<ResponseFormatFailure>()),
    );
    expect(mutations, 0);
  });

  test('resume rejects an ID that belongs to a different property', () async {
    final repo = ApiOwnerListingRepository(
      _DraftClient({
        'data': {'id': 43},
      }),
    );

    await expectLater(
      repo.getListing('42'),
      throwsA(isA<ResponseFormatFailure>()),
    );
  });

  test(
    'recovery distinguishes a missing draft from a network failure',
    () async {
      final client = _DraftClient({
        'data': {'id': 42},
      });
      final repo = ApiOwnerListingRepository(client);

      expect((await repo.recoverDraft('existing-request'))?.id, '42');
      client.readFailure = const NotFoundFailure();
      expect(await repo.recoverDraft('missing-request'), isNull);
      client.readFailure = const NetworkFailure();
      await expectLater(
        repo.recoverDraft('existing-request'),
        throwsA(isA<NetworkFailure>()),
      );
    },
  );
}
