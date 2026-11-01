"""Prepare only Filtered_Data from the supplied workbook for PostgreSQL import."""
import argparse
import json
import math
from datetime import date, datetime
from pathlib import Path
from urllib.parse import urlsplit
from openpyxl import load_workbook


def number(value, name):
    result = float(str(value).replace(',', '').strip())
    if not math.isfinite(result):
        raise ValueError(f'Invalid {name}')
    return result


def url(value):
    text = str(value or '').strip()
    parsed = urlsplit(text)
    return text if parsed.scheme in ('http', 'https') and parsed.hostname else None


def prepare(path):
    wb = load_workbook(path, read_only=True, data_only=True)
    try:
        ws = wb['Filtered_Data']
        it = ws.iter_rows(values_only=True)
        headers = next(it)
        result, ids = [], set()
        for row_number, values in enumerate(it, 2):
            if not any(v is not None for v in values):
                continue
            raw = dict(zip(headers, values))
            property_id = str(raw.get('canonical_property_id') or '').strip()
            if not property_id or property_id in ids:
                raise ValueError(f'Missing/duplicate property ID at row {row_number}')
            ids.add(property_id)
            rent = number(raw.get('validated_monthly_rent_myr'), 'rent')
            size = number(raw.get('Built-up Area (sq ft)'), 'size')
            lat, lon = number(raw.get('latitude'), 'latitude'), number(raw.get('longitude'), 'longitude')
            score = number(raw.get('fnb_suitability_index'), 'suitability index')
            if not (rent >= 0 and size > 0 and .8 <= lat <= 7.5 and 99.5 <= lon <= 119.5 and 0 <= score <= 100):
                raise ValueError(f'Out-of-range data at row {row_number}; import stopped')
            result.append(dict(
                id=property_id, title=str(raw.get('original_title') or raw.get('title') or property_id),
                address=str(raw.get('normalized_address') or raw.get('address') or ''),
                city='', state=str(raw.get('state') or ''), postcode='',
                rental_rm=rent, size_sqft=size, latitude=lat, longitude=lon,
                property_type=str(raw.get('Property Type (Normalized)') or raw.get('property_type') or 'Commercial'),
                image_url=url(raw.get('image_url')), source_url=url(raw.get('source_url')),
                suitability_score=score,
                dataset_validation=str(raw.get('validation_status') or ''),
                source_workbook=path.name, source_sheet='Filtered_Data', source_row=row_number,
                source_data=raw,
            ))
        if not result:
            raise ValueError('No accepted property rows found')
        return result
    finally:
        wb.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workbook', type=Path)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / '.data/properties.json')
    args = parser.parse_args()
    rows = prepare(args.workbook)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def encode(value):
        if isinstance(value, (date, datetime)):
            return value.isoformat()
        raise TypeError(type(value).__name__)
    args.output.write_text(json.dumps(rows, ensure_ascii=False, default=encode, allow_nan=False), encoding='utf-8')
    print(f'Prepared {len(rows)} accepted rows; {sum(bool(r["image_url"]) for r in rows)} image URLs.')
