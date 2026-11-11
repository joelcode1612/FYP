#!/usr/bin/env python3
"""Repair missing SiteWise Add Property address symbols and web API method.

Use on your LOCAL FYP repository; does not change the uploaded Dart page.
The original files are backed up before any changes. Re-running is idempotent.
"""
from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import re
import shutil
import sys

STATE = '''
/// Shared address-verification state; Google verification is not ownership approval.
enum AddressVerificationState {
  unverified,
  verifying,
  validatedPendingConfirmation,
  verified,
  partiallyValidated,
  unconfirmed,
  serviceError,
}
'''

SNAPSHOT = '''
/// Exact address and verified coordinates; changes make a verification stale.
class AddressSnapshot {
  const AddressSnapshot({
    required this.address,
    required this.city,
    required this.state,
    required this.postcode,
    this.latitude,
    this.longitude,
  });

  final String address;
  final String city;
  final String state;
  final String postcode;
  final double? latitude;
  final double? longitude;

  @override
  bool operator ==(Object other) =>
      other is AddressSnapshot &&
      other.address == address &&
      other.city == city &&
      other.state == state &&
      other.postcode == postcode &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode =>
      Object.hash(address, city, state, postcode, latitude, longitude);
}
'''

RESULT = '''
/// Normalised verdict from the existing backend Google address adapter.
class AddressValidationResult {
  const AddressValidationResult({
    required this.status,
    this.formattedAddress,
    this.granularity,
    this.postalCode,
    this.latitude,
    this.longitude,
    this.provider,
  });

  final String status;
  final String? formattedAddress;
  final String? granularity;
  final String? postalCode;
  final double? latitude;
  final double? longitude;
  final String? provider;

  bool get confirmed => status == 'validated';

  bool get hasCoordinates =>
      latitude != null && longitude != null &&
      latitude!.isFinite && longitude!.isFinite &&
      latitude! >= -90 && latitude! <= 90 &&
      longitude! >= -180 && longitude! <= 180;

  factory AddressValidationResult.fromData(Map<String, dynamic> data) =>
      AddressValidationResult(
        status: '${data['status'] ?? 'unconfirmed'}',
        formattedAddress: data['formatted_address'] as String?,
        granularity: data['validation_granularity'] as String?,
        postalCode: data['postal_code'] as String?,
        latitude: (data['latitude'] as num?)?.toDouble(),
        longitude: (data['longitude'] as num?)?.toDouble(),
        provider: data['provider'] as String?,
      );
}
'''

COPY = '''
/// User-facing messages shared by the web and mobile address verification UI.
abstract final class AddressVerificationCopy {
  static const String validated =
      'Address validated. Please confirm the location shown below.';
  static const String partiallyValidated =
      'We found the general location, but cannot confirm the exact property '
      'address. Please check the building, unit number or postcode.';
  static const String unconfirmed =
      "We couldn't verify this address. Please check your address details and "
      'try again.';
  static const String unavailable =
      'Address verification is temporarily unavailable. Please retry.';
  static const String invalidRequest =
      'The address could not be checked. Review the address details and try again.';
  static const String required =
      'Verify and confirm the address before submitting.';
  static const String stale =
      'Address details changed — verify the address again.';
}
'''

METHOD = '''
  /// Checks an address through FastAPI; never exposes the Google API key.
  /// A validated address is NOT proof of property ownership or approval.
  Future<AddressValidationResult> validateAddress({
    required List<String> addressLines,
    String? city,
    String? state,
    String? postcode,
  }) async {
    final response = await WebAuth.request(
      '/api/v1/properties/validate-address',
      method: 'POST',
      body: {
        'address_lines': addressLines
            .where((line) => line.trim().isNotEmpty)
            .toList(),
        if (city != null && city.trim().isNotEmpty) 'city': city.trim(),
        if (state != null && state.trim().isNotEmpty) 'state': state.trim(),
        if (postcode != null && postcode.trim().isNotEmpty)
          'postcode': postcode.trim(),
        'region_code': 'MY',
      },
    );
    final data =
        (response['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AddressValidationResult.fromData(data);
  }
'''


def transform(files: dict[str, str]) -> tuple[dict[str, str], list[str]]:
    changed: dict[str, str] = {}
    log: list[str] = []
    rules_path = 'shared_logic/lib/src/domain/data/add_property_rules.dart'
    export_path = 'shared_logic/lib/shared_logic.dart'
    repo_path = 'fyp_jaspr_web/lib/data/api_property_repository.dart'

    rules = files[rules_path]
    missing = []
    for symbol, code in (
        ('AddressVerificationState', STATE),
        ('AddressSnapshot', SNAPSHOT),
        ('AddressValidationResult', RESULT),
        ('AddressVerificationCopy', COPY),
    ):
        if not re.search(r'\b(?:enum|class|abstract\s+final\s+class)\s+' + symbol + r'\b', rules):
            rules = rules.rstrip() + '\n\n' + code.strip() + '\n'
            missing.append(symbol)
    if missing:
        changed[rules_path] = rules
        log.append('Add shared definitions: ' + ', '.join(missing))
    else:
        log.append('Shared address definitions already present')

    exports = files[export_path]
    export_line = "export 'src/domain/data/add_property_rules.dart';"
    if export_line not in exports:
        lines = exports.splitlines(keepends=True)
        insert_at = next((i for i, s in enumerate(lines) if s.startswith('export ')), None)
        if insert_at is None:
            raise ValueError(f'Cannot safely locate exports in {export_path}')
        lines.insert(insert_at, export_line + '\n')
        changed[export_path] = ''.join(lines)
        log.append('Expose address definitions through shared_logic.dart')
    else:
        log.append('shared_logic.dart already exports add_property_rules.dart')

    repo = files[repo_path]
    class_name = 'class ApiPropertyRepository'
    start = repo.find(class_name)
    if start < 0:
        raise ValueError(f'Cannot find {class_name} in {repo_path}; refusing guess')
    # Find the top-level class-closing brace: method braces are indented.
    closing = repo.find('\n}\n', start)
    if closing < 0:
        raise ValueError(f'Cannot locate ApiPropertyRepository class end in {repo_path}')
    body = repo[start:closing]
    if re.search(r'\bvalidateAddress\s*\(', body):
        log.append('ApiPropertyRepository.validateAddress already exists')
    else:
        if 'WebAuth.request(' not in body:
            raise ValueError('This repository does not use WebAuth.request; cannot safely insert API method')
        repo = repo[:closing] + '\n' + METHOD.rstrip() + repo[closing:]
        if "import 'auth_service.dart';" not in repo:
            repo = "import 'auth_service.dart';\n" + repo
        changed[repo_path] = repo
        log.append('Add ApiPropertyRepository.validateAddress (FastAPI endpoint)')
    return changed, log


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True, help='SiteWise/FYP repository root')
    parser.add_argument('--apply', action='store_true', help='Write changes with backups (default is check-only)')
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    paths = [
        'shared_logic/lib/src/domain/data/add_property_rules.dart',
        'shared_logic/lib/shared_logic.dart',
        'fyp_jaspr_web/lib/data/api_property_repository.dart',
    ]
    missing = [p for p in paths if not (root / p).is_file()]
    if missing:
        print('Cannot continue; the following repo files are missing:')
        for p in missing:
            print('  ' + p)
        print('Restore them from the same SiteWise Git branch before retrying.')
        return 2
    files = {p: (root / p).read_text(encoding='utf-8') for p in paths}
    try:
        changed, log = transform(files)
    except ValueError as exc:
        print('Aborted safely: ' + str(exc))
        return 3
    print('FYP root:', root)
    for msg in log:
        print(' -', msg)
    if not changed:
        print('No changes needed. If your editor still shows errors, run dart pub get and restart the analyzer.')
        return 0
    if not args.apply:
        print('Check only: no files changed. Add --apply to make these repairs.')
        return 0
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    for path, content in changed.items():
        target = root / path
        backup = target.with_name(target.name + f'.bak_{timestamp}')
        shutil.copy2(target, backup)
        target.write_text(content, encoding='utf-8')
        print('Updated:', target)
        print('Backup: ', backup)
    print('Next: from your FYP repo root run: dart pub get')
    print('Then: cd fyp_jaspr_web && dart analyze lib/pages/entrepreneur/add_property_page.dart')
    return 0

if __name__ == '__main__':
    sys.exit(main())
