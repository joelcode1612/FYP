SiteWise MD-00510 — store latest expanded64 score without replacing original baseline47 score

This script is intended for the local FYP/backend environment. It cannot reach your PostgreSQL database from ChatGPT.

1. Extract folder into C:\Users\Lenovo\AndroidStudioProjects\FYP\sitewise_pu64_update
2. Open PowerShell:
   cd C:\Users\Lenovo\AndroidStudioProjects\FYP\backend
3. Compute/read-only dry run:
   .\.venv\Scripts\python.exe ..\sitewise_pu64_update\update_md00510_pu64.py
4. Read the printed model version, computed score and feature coverage. It should be close to the checked-in 58.8861 reference.
5. Apply one-row write only after verifying:
   .\.venv\Scripts\python.exe ..\sitewise_pu64_update\update_md00510_pu64.py --apply

The script verifies:
- SITEWISE_PU_MODEL_VARIANT=expanded64
- model has exactly 64 input features
- actual property ID MD-00510 -> fyp.rental_properties id 316
- original 47-feature score remains 27.255328732372767
- model output is real and between 0 and 1
- live score within 2 points of checked-in MD-00510 example (otherwise refuses; investigate before overriding)
- it only writes catalogue_source_data.pu_expanded64 and keeps approval / publication unchanged.

Verification query:
SELECT id, listing_id, catalogue_suitability_score AS pu47_0_100,
       catalogue_source_data->'pu_expanded64'->>'score_0_100' AS pu64_0_100,
       catalogue_source_data->'pu_expanded64'->>'model_version' AS pu64_model_version,
       verification_status, is_published
FROM fyp.rental_properties WHERE id=316 AND listing_id='MD-00510';

NOTE: The current SiteWise web 'expanded64' score is calculated live and does not read the new pu_expanded64 JSON field. The update is stored provenance, not a frontend fix. A later catalogue reimport that replaces catalogue_source_data may erase this metadata; design a dedicated versioned score table if you need durable persisted scores for all properties.
