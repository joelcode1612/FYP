"""Run separately from existing sitewise.ml.cli without changing its default PU model.

From FYP/backend with PYTHONPATH=src:
  python -m sitewise.ml.selected_pu_cli inspect
  python -m sitewise.ml.selected_pu_cli predict --features-json ml_reference/example_property_47.json
  python -m sitewise.ml.selected_pu_cli explain --features-json ml_reference/example_property_47.json
"""
from __future__ import annotations
import argparse
import csv
import json
from pathlib import Path
from sitewise.ml.selected_pu_integration import selected_metadata, predict_selected, explain_selected


def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('inspect','predict','explain'))
    parser.add_argument('--features-json',type=Path,default=Path('ml_reference/example_property_47.json'))
    parser.add_argument('--background-csv',type=Path,default=Path('ml_reference/shap_background_47.csv'))
    parser.add_argument('--out',type=Path)
    args=parser.parse_args()
    if args.action=='inspect':
        result=selected_metadata()
    else:
        payload=json.loads(args.features_json.read_text(encoding='utf-8'))
        data=payload['features']
        if not isinstance(data,dict): raise ValueError('features must be a dict')
        if args.action=='predict':
            result=predict_selected(str(payload['property_id']),data)
        else:
            with args.background_csv.open(newline='',encoding='utf-8-sig') as f:
                background=list(csv.DictReader(f))
            result=explain_selected(data,background)
            # Explain exactly the same score as produced by the selected PU model.
    output=json.dumps(result,indent=2,ensure_ascii=False,allow_nan=False)
    if args.out:
        args.out.parent.mkdir(parents=True,exist_ok=True)
        args.out.write_text(output+'\n',encoding='utf-8')
        print('Saved',args.out)
    else:
        print(output)

if __name__=='__main__':main()
