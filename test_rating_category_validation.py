"""Offline checks for category validation and workbook migration."""
import tempfile
import math
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("retrieve_competitor_rating_features_docker.py")
pipeline = {"__name__": "rating_validation_test"}
exec(compile(SCRIPT.read_text(encoding="utf-8"), str(SCRIPT), "exec"), pipeline)


def place(category, rating="4", reviews="20", **extra):
    row = {"place_id": f"id-{category}", "title": "Example business",
           "category": category, "latitude": "3.1", "longitude": "101.6",
           "review_rating": rating, "review_count": reviews}
    row.update(extra)
    return row


class CategoryValidationTests(unittest.TestCase):
    def test_rm_price_parsing_is_explicit_and_auditable(self):
        parse = pipeline["parse_price_rm"]
        for text, expected in [("RM10–20", 15), ("RM 10 - RM 30 per person", 20),
                               ("MYR 12.50", 12.5), ("Price per person: RM 20–40", 30),
                               ("RM1,000–2,000", 1500)]:
            with self.subTest(text=text):
                self.assertEqual(parse(text)[0], expected)
        for text in ("", "$$", "$10–20", "SGD 10–20", "10–20", "RM100+",
                     "RM0", "RM30–10", "RM1,00", "RM NaN", "under RM20"):
            with self.subTest(text=text):
                self.assertIsNone(parse(text)[0])

    def test_price_means_use_each_group_and_both_radii_without_rating_requirement(self):
        def north(metres):
            return 3.1 + math.degrees(metres / 6_371_008.8)
        records = [
            place("Cafe", price_range="RM10–20"),
            place("Cafe", price_range="RM10–20"),  # same place, counted once
            place("Coffee shop", rating="", price_range="RM 30", latitude=str(north(750))),
            place("Restaurant", price_range="RM20–40", latitude=str(north(499.99))),
            place("Indian restaurant", price_range="RM40–60", latitude=str(north(500.01))),
            place("Fast food restaurant", price_range="RM12"),
            place("Bakery", price_range="RM5–15"),
            place("Dessert shop", price_range="$$"),
            place("Hotel", price_range="RM1000"),
            place("Cake shop", price_range="RM100", latitude=str(north(1000.01))),
        ]
        metrics, _ = pipeline["compute_rating_features"](3.1, 101.6, records, 1000)
        self.assertEqual(metrics["avg_cafe_price_500m_rm"], 15)
        self.assertEqual(metrics["avg_cafe_price_1km_rm"], 22.5)
        self.assertEqual(metrics["cafe_priced_count_500m"], 1)
        self.assertEqual(metrics["cafe_priced_count_1km"], 2)
        self.assertEqual(metrics["avg_restaurant_price_500m_rm"], 30)
        self.assertEqual(metrics["avg_restaurant_price_1km_rm"], 40)
        self.assertEqual(metrics["restaurant_priced_count_1km"], 2)
        self.assertEqual(metrics["avg_fast_food_price_1km_rm"], 12)
        self.assertEqual(metrics["fast_food_priced_count_500m"], 1)
        self.assertEqual(metrics["avg_bakery_dessert_beverage_price_1km_rm"], 10)
        self.assertEqual(metrics["bakery_dessert_beverage_priced_count_1km"], 1)

    def test_missing_prices_are_not_zero_price_estimates_and_failed_rows_are_blank(self):
        metrics, status = pipeline["compute_rating_features"](3.1, 101.6, [place("Cafe")], 1000)
        for header in pipeline["PRICE_HEADERS"]:
            self.assertEqual(metrics[header], None if header.startswith("avg_") else 0)
        wb = pipeline["Workbook"]()
        ws = wb.active
        ws.append(pipeline["OUTPUT_HEADERS"])
        pipeline["apply_metrics_to_group"](ws, [2], metrics, status)
        pipeline["clear_metrics_for_group"](ws, [2], "FAILED")
        for col in range(14, 30):
            self.assertIsNone(ws.cell(2, col).value)
        wb.close()

    def test_price_columns_persist_beyond_column_z_and_audit_keeps_price_source(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "prices.xlsx"
            source = [{"canonical_property_id": "P1", "latitude": 3.1,
                       "longitude": 101.6, "state": "Selangor"}]
            wb, ws = pipeline["create_or_resume_output"](path, source)
            pipeline["prepare_output_method"](wb, ws, path, 1000)
            metrics, status = pipeline["compute_rating_features"](
                3.1, 101.6, [place("Bakery", price_range="RM10–20")], 1000)
            pipeline["save_category_audit"](wb, 3.1, 101.6, metrics, "price-job")
            pipeline["apply_metrics_to_group"](ws, [2], metrics, status)
            pipeline["format_output_sheet"](ws)
            wb.save(path)
            wb.close()
            wb = pipeline["load_workbook"](path, data_only=True)
            ws = wb["rating_features"]
            self.assertEqual([c.value for c in ws[1]], pipeline["OUTPUT_HEADERS"])
            self.assertEqual(ws["AC2"].value, 1)
            self.assertEqual(ws["T2"].value, 15)
            self.assertEqual(wb["category_audit"]["M2"].value, "price-job")
            self.assertEqual(wb["category_audit"]["O2"].value, "RM10–20")
            self.assertEqual(wb["category_audit"]["R2"].value, 15)
            self.assertEqual(wb["category_audit"]["S2"].value, "RM_RANGE_MIDPOINT")
            self.assertEqual(wb["feature_definitions"].max_row, 17)
            wb.close()

    def test_categories_grouped_without_using_business_names(self):
        expected = {
            "Cafe": "cafes_coffee", "Coffee bar": "cafes_coffee",
            "Kopitiam": "cafes_coffee", "Tea house": "cafes_coffee",
            "Chinese restaurant": "restaurants_casual_dining",
            "Hawker centre": "restaurants_casual_dining",
            "Fast food restaurant": "fast_food_takeaway",
            "Hamburger restaurant": "fast_food_takeaway",
            "Pizza takeaway": "fast_food_takeaway",
            "Bakery": "bakeries_desserts", "Bubble tea store": "bakeries_desserts",
            "Dessert restaurant": "bakeries_desserts", "Ice cream shop": "bakeries_desserts",
        }
        for label, group in expected.items():
            with self.subTest(label=label):
                self.assertEqual(pipeline["classify_fnb_category"](label)[0], group)
        for label in ("Supermarket", "Restaurant supply store", "Internet cafe",
                      "Coffee wholesaler", "Hotel", "Food manufacturer"):
            with self.subTest(label=label):
                self.assertIsNone(pipeline["classify_fnb_category"](label)[0])

    def test_averages_exclude_unrelated_outside_and_duplicate_places(self):
        records = [place("Cafe", "4", "10"), place("Cafe", "4", "10"),
                   place("Restaurant", "2", "30"),
                   place("Bakery", "", "0"),
                   place("Supermarket", "5", "10000", title="Cafe Restaurant Bakery"),
                   place("Coffee shop", "5", "999", latitude="3.2")]
        metrics, status = pipeline["compute_rating_features"](3.1, 101.6, records, 1000)
        self.assertEqual(status, "SCRAPED")
        self.assertEqual(metrics["avg_competitor_rating_1km"], 3)
        self.assertEqual(metrics["avg_competitor_review_count_1km"], 13.33)
        self.assertEqual(metrics["rated_competitor_count_1km"], 2)
        self.assertEqual(metrics["accepted_fnb_count_1km"], 3)
        self.assertEqual(metrics["excluded_category_count"], 1)
        self.assertEqual(len(metrics["_category_audit"]), 5)

    def test_missing_category_not_inferred_from_shop_name(self):
        metrics, status = pipeline["compute_rating_features"](
            3.1, 101.6, [place("", title="Coffee Restaurant")], 1000)
        self.assertEqual(status, "PARTIAL")
        self.assertIsNone(metrics["avg_competitor_rating_1km"])
        self.assertEqual(metrics["missing_category_count"], 1)

    def test_unrelated_missing_location_does_not_make_fnb_result_partial(self):
        metrics, status = pipeline["compute_rating_features"](
            3.1, 101.6, [place("Cafe"), place("Hotel", latitude="")], 1000)
        self.assertEqual(status, "SCRAPED")
        self.assertEqual(metrics["accepted_fnb_count_1km"], 1)
        _, status = pipeline["compute_rating_features"](
            3.1, 101.6, [place("Cafe", latitude="")], 1000)
        self.assertEqual(status, "PARTIAL")

    def test_empty_and_no_qualifying_results_are_distinct(self):
        for records, expected in [([], "NO_RESULTS"), ([place("Hotel")], "NO_FNB_RESULTS")]:
            metrics, status = pipeline["compute_rating_features"](3.1, 101.6, records, 1000)
            self.assertEqual(status, expected)
            self.assertIsNone(metrics["avg_competitor_rating_1km"])
            self.assertEqual(metrics["rated_competitor_count_1km"], 0)

    def test_migration_backup_and_resume_keep_methods_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "output.xlsx"
            source = [{"canonical_property_id": "P1", "latitude": 3.1,
                       "longitude": 101.6, "state": "Selangor"}]
            wb, ws = pipeline["create_or_resume_output"](path, source)
            ws.cell(2, 5).value = 5
            ws.cell(2, 8).value = "SCRAPED"
            wb.save(path)
            pipeline["prepare_output_method"](wb, ws, path, 1000)
            self.assertIsNone(ws.cell(2, 5).value)
            self.assertEqual(ws.cell(2, 8).value, "PENDING")
            self.assertEqual(len(list(Path(directory).glob("*.before-category-update-*.xlsx"))), 1)
            metrics, status = pipeline["compute_rating_features"](3.1, 101.6, [place("Cafe")], 1000)
            pipeline["save_category_audit"](wb, 3.1, 101.6, metrics, "job-1")
            pipeline["save_category_audit"](wb, 3.1, 101.6, metrics, "job-2")
            self.assertEqual(wb["category_audit"].max_row, 2)
            pipeline["apply_metrics_to_group"](ws, [2], metrics, status)
            wb.save(path)
            wb.close()
            wb, ws = pipeline["create_or_resume_output"](path, source)
            pipeline["prepare_output_method"](wb, ws, path, 1000)
            self.assertEqual(ws.cell(2, 5).value, 4)
            self.assertEqual(ws.cell(2, 8).value, "SCRAPED")
            pipeline["prepare_output_method"](wb, ws, path, 500)
            self.assertEqual(ws.cell(2, 8).value, "PENDING")
            wb.close()


if __name__ == "__main__":
    unittest.main()
