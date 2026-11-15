# SiteWise — Research-only F&B category prediction package

**This is a real trained and reloaded model, but NOT a validated commercial-suitability model.**

## Main files

- `SiteWise_Two_Stage_PU_FNB_Category_ResearchOnly.joblib` — full two-stage artifact (64-feature original PU + new 54-feature conditional business-category model).
- `SiteWise_FNB_Category_Conditional_ResearchOnly.joblib` — category-only artifact.
- `SiteWise_916_U_Category_Research_Predictions.xlsx` — browsable Excel with predictions for 916 U locations, source semantics, validations and model feature contract.
- `SiteWise_916_U_Category_Exploratory_Predictions.csv` — same U category rankings and separate general PU associations.
- `train_category_pu.py` — training, spatial/model selection, validation and export. Re-runs from the source Excel/CSV/model supplied with the ZIP.
- `predict_category_pu.py` — standalone model inference by ID or 64-feature JSON.
- `explain_category_shap.py` — verified conditional-category permutation SHAP using real P background; does NOT explain general PU association.
- `SHAP_Observed_Category_Background_54.csv` — 32 complete, observed category-stratified P examples.
- `SiteWise_Category_Model_Comparison.csv` — benchmark and geographic metrics.
- `SiteWise_Category_Model_Validation_Folds.csv` — per-fold metrics.
- `SiteWise_Category_Heldout_Predictions.csv` — detailed out-of-fold predictions.
- `SiteWise_Category_Training_Audit.json` — exact feature list, counts and model selection.
- `Example_MD-00510_Prediction.json` and `Example_MD-00510_Category_SHAP.json` — test of saved artifact and explanation additivity.
- `MODEL_CARD_AND_FYP_REPORT.md` — methodology, results and limitations suitable to adapt for your FYP report.

## Model provenance

- Original Excel: 1,796 records, 880 known P category labels, 916 U unknown categories.
- General P/U model: 64-feature research logistic ensemble from the prior experiment.
- Category model: 54 features (including 20 new age/residential variables) from the *P* records; all 10 F&B competitor counts deliberately excluded due potential self-count target leakage.
- Geographic held-out macro F1 approximately **0.274** and balanced accuracy **0.279**; near chance, *not suitable as an automated commercial-opening decision*.
- The model scores are association/confidence values about known-category patterns, not predicted profitability or business success.

### Example

```bash
python predict_category_pu.py --model SiteWise_Two_Stage_PU_FNB_Category_ResearchOnly.joblib --csv SiteWise_PU_1796_Expanded_Observed.csv --subject-id MD-00510
```

### Integration caution

**Do not** rename the artifact to `PU_model.joblib` or drop it over the current deployed model. It uses a different two-stage dictionary schema; integrate through an explicit versioned adapter. Ensure the current database can return all 64 required feature names with correct semantics and that both stages explain the model that generated their displayed score.
