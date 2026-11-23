import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/core/di/mobile_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final (ext, mime) in [
    ('pdf', 'application/pdf'),
    ('jpg', 'image/jpeg'),
    ('jpeg', 'image/jpeg'),
    ('png', 'image/png'),
    ('webp', 'image/webp'),
  ]) {
    test('sends authenticated $ext proof with its original bytes', () async {
      final bytes = [0, 128, 255];
      final client = MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer fixture');
        final body = latin1.decode(request.bodyBytes);
        expect(body, contains('name="verification_type"\r\n\r\nownership'));
        expect(body, contains('name="document_type"\r\n\r\nownership_proof'));
        expect(body, contains('content-type: $mime\r\n'));
        expect(
          body,
          contains(
            'name="file"; filename="proof.$ext"\r\n\r\n${latin1.decode(bytes)}',
          ),
        );
        return http.Response('{}', 201);
      });
      await http.runWithClient(
        () => MobileApiClient(bearer: () => 'fixture').uploadMultipart(
          '/api/v1/properties/1/verification/documents',
          fields: {
            'verification_type': 'ownership',
            'document_type': 'ownership_proof',
          },
          fileField: 'file',
          filename: 'proof.$ext',
          bytes: bytes,
          contentType: mime,
        ),
        () => client,
      );
    });
  }
}
