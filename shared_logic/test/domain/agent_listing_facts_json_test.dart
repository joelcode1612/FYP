import 'package:shared_logic/src/domain/entities/agent_listing.dart';
import 'package:test/test.dart';

/// Regression for the agent-workspace crash:
/// `TypeError: "10000.00", type: 'String' is not a subtype of type 'num'`.
///
/// The operational columns are Postgres `numeric`, but the JSON serialiser has
/// drifted between emitting numbers and numeric strings on this path. The
/// mapper must accept both shapes as a value, and must never invent a default
/// for unparseable text.
void main() {
  Map<String, dynamic> row({
    Object? rentalPrice = 6500.0,
    Object? sizeSqft = 1200.0,
    Object? psf = 5.42,
    Object? floorLevel,
  }) => {
    'id': 89,
    'name': 'USJ 9',
    'rental_price': rentalPrice,
    'size_sqft': sizeSqft,
    'psf': psf,
    'floor_level': floorLevel,
    'verification_status': 'approved',
  };

  group('AgentListingFacts.fromJson numeric tolerance', () {
    test('JSON numbers parse as before', () {
      final facts = AgentListingFacts.fromJson(row());
      expect(facts.rentalPrice, 6500.0);
      expect(facts.sizeSqft, 1200.0);
      expect(facts.psf, closeTo(5.42, 1e-9));
      expect(facts.rentalDisplay, 'RM 6500');
    });

    test('numeric strings (the crash shape) parse to values', () {
      final facts = AgentListingFacts.fromJson(
        row(
          rentalPrice: '10000.00',
          sizeSqft: '4440.00',
          psf: '2.52',
          floorLevel: '12.0',
        ),
      );
      expect(facts.rentalPrice, 10000.0);
      expect(facts.sizeSqft, 4440.0);
      expect(facts.psf, closeTo(2.52, 1e-9));
      expect(facts.floorLevel, 12.0);
      expect(facts.rentalDisplay, 'RM 10000');
    });

    test('null and absent values stay null (no invented defaults)', () {
      final facts = AgentListingFacts.fromJson(row(rentalPrice: null));
      expect(facts.rentalPrice, isNull);
      expect(facts.rentalDisplay, '');
      expect(
        AgentListingFacts.fromJson({
          'id': 1,
          'name': 'x',
          'verification_status': 'draft',
        }).sizeSqft,
        isNull,
      );
    });

    test('unparseable text degrades to null instead of throwing', () {
      final facts = AgentListingFacts.fromJson(row(rentalPrice: 'not-a-number'));
      expect(facts.rentalPrice, isNull);
    });
  });
}
