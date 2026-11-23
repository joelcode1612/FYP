"""Pure contract tests; no database/network calls."""
import unittest
from unittest.mock import Mock
from generate_demand_generators import (
    POI_CATEGORIES, CATEGORY_COLUMNS, TOTAL_COLUMNS, coordinate_hash, valid_coords,
    measure, POI_SQL, SUBJECT_SQL, csv_safe, parse_ids
)

class FakeConn:
    def __init__(self, row): self.row=row
    def execute(self, query, params=None):
        out=Mock()
        out.mappings.return_value.one.return_value=self.row
        return out

class DemandTest(unittest.TestCase):
    def test_expected_seven_categories_and_radii(self):
        self.assertEqual(len(POI_CATEGORIES), 7)
        self.assertEqual(len(CATEGORY_COLUMNS), 14)
        self.assertEqual(TOTAL_COLUMNS, ('demand_generator_count_500m', 'demand_generator_count_1km'))
        self.assertNotIn('OFFICE_BUILDING', POI_CATEGORIES.values())

    def test_measurement_valid(self):
        subject=FakeConn({'c500':2,'c1000':5})
        poi=FakeConn({'pois_in_window':10, **{col:1 for col in CATEGORY_COLUMNS}})
        out=measure(subject,poi,3.1,101.7)
        self.assertEqual(out['values']['demand_generator_count_500m'], 2)
        self.assertEqual(out['values']['office_pois_500m'], 1)
        self.assertEqual(out['poi_coverage'],'measured')

    def test_empty_window_must_not_be_zero(self):
        subject=FakeConn({'c500':0,'c1000':0})
        poi=FakeConn({'pois_in_window':0, **{col:0 for col in CATEGORY_COLUMNS}})
        out=measure(subject,poi,3.1,101.7)
        self.assertEqual(out['values']['demand_generator_count_500m'], 0)
        self.assertIsNone(out['values']['office_pois_500m'])
        self.assertEqual(out['poi_coverage'],'unavailable_no_nearby_source_rows')

    def test_coordinate_hash_contract(self):
        import hashlib
        self.assertEqual(coordinate_hash(3.12345,101.23456), hashlib.sha256(
            b'3.123450,101.234560,property-enrichment-v2').hexdigest())

    def test_coords_validation_and_csv_safety(self):
        self.assertTrue(valid_coords(3.1,101.7))
        self.assertFalse(valid_coords(0,0))
        self.assertFalse(valid_coords(None,101.7))
        self.assertEqual(csv_safe('=SUM(1,1)'), "'=SUM(1,1)")
        self.assertEqual(parse_ids('4, 2,4'),[4,2])

    def test_sql_contract(self):
        sql=str(POI_SQL)
        self.assertIn('demand_gen.pois_master',sql)
        self.assertIn('rep_geom::geography',sql)
        self.assertIn('poi_category',sql)
        self.assertIn("cat = 'OFFICE'",sql)
        self.assertIn('ST_Expand(origin.point, 0.012)',sql)
        self.assertIn('demand_gen.subjects',str(SUBJECT_SQL))

if __name__=='__main__': unittest.main()
