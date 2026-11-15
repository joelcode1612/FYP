-- SITEWISE PU — TRAINING COPY ONLY / NO LIVE DATA DELETION
-- Based on: SiteWise_PU_1849_Recovery_Verified.xlsx
-- Source workbook: 1,849 unique subjects = 894 P + 955 U
-- Exclude 53 incomplete subjects = 14 P + 39 U
-- Result: 1,796 subjects = 880 P + 916 U
-- IMPORTANT: uses a new research table; DOES NOT delete real properties or original analytics.
-- Run entire script in one PostgreSQL session/transaction. Do not run twice under same staging name.

BEGIN;
CREATE SCHEMA IF NOT EXISTS sitewise_ml;

-- Deliberately fails if a table with this name already exists: prevents silent overwrite.
CREATE TABLE sitewise_ml.pu_training_1796_20261115 AS
SELECT * FROM sitewise_analytics.subject_features;

DO $$ BEGIN
  IF (SELECT COUNT(*) FROM sitewise_ml.pu_training_1796_20261115) <> 1849
     OR (SELECT COUNT(DISTINCT subject_id) FROM sitewise_ml.pu_training_1796_20261115) <> 1849
     OR (SELECT COUNT(*) FROM sitewise_ml.pu_training_1796_20261115 WHERE BTRIM(sample_class)='P') <> 894
     OR (SELECT COUNT(*) FROM sitewise_ml.pu_training_1796_20261115 WHERE BTRIM(sample_class)='U') <> 955
  THEN
     RAISE EXCEPTION 'Source DB no longer matches the Excel snapshot; run ROLLBACK, inspect data, do not delete';
  END IF;
END $$;

CREATE TEMP TABLE pu_excel_incomplete_53 (subject_id TEXT PRIMARY KEY) ON COMMIT DROP;
INSERT INTO pu_excel_incomplete_53 (subject_id) VALUES
    ('0x31da6f48a519ebf9:0xb502c21dbe51482e'),
    ('0x31da0b6146367c3d:0x303931f6d7db94b1'),
    ('0x304ac50033eea995:0xc0aceb7c81c42608'),
    ('0x304ac52abdb971c3:0x1eb4dd57c4febde4'),
    ('0x304ac458b457a9af:0x17fe6a59eef2b25f'),
    ('0x31cc4db34e73b507:0xc9a977a79afba894'),
    ('0x31cc5300570ed0a3:0x4e1d7cdf5b386f6f'),
    ('0x31cc5307246bdc91:0x3f791449256b3ca2'),
    ('0x31cc4bd2752a16cd:0x3363c3adb71c7f95'),
    ('0x31cdacaa0130ab41:0x38c884fd9e5212c7'),
    ('0x31cc546315a8e1c9:0x99fc2bc8e85208e8'),
    ('0x31cc53fd7b5fb82b:0x311edfcad248f71d'),
    ('0x31cc53f2442f28d1:0x7ca3d8c1a405e23d'),
    ('0x31cc52ab70fb2d83:0xeba29736cfc14673'),
    ('MD-03209'),
    ('EP-03153'),
    ('MD-01446'),
    ('EP-02181'),
    ('EP-02013'),
    ('MD-03480'),
    ('MD-04053'),
    ('EP-01453'),
    ('EP-02180'),
    ('MD-00075'),
    ('MD-00130'),
    ('MD-00179'),
    ('MD-00253'),
    ('MD-00301'),
    ('MD-00670'),
    ('MD-00756'),
    ('MD-01097'),
    ('MD-01289'),
    ('MD-01454'),
    ('MD-01571'),
    ('MD-01600'),
    ('MD-01773'),
    ('MD-01793'),
    ('MD-01983'),
    ('MD-03514'),
    ('MD-03578'),
    ('MD-03997'),
    ('MD-04832'),
    ('MD-00172'),
    ('MD-00500'),
    ('MD-00664'),
    ('MD-00904'),
    ('MD-01385'),
    ('MD-01642'),
    ('MD-02012'),
    ('MD-03544'),
    ('MD-03877'),
    ('MD-04129'),
    ('MD-04205');

DO $$ BEGIN
  IF (SELECT COUNT(*) FROM pu_excel_incomplete_53) <> 53
     OR (SELECT COUNT(*) FROM pu_excel_incomplete_53 x
          LEFT JOIN sitewise_ml.pu_training_1796_20261115 s USING (subject_id)
          WHERE s.subject_id IS NULL) <> 0
  THEN RAISE EXCEPTION '53 subject IDs do not exactly match DB staging source; ROLLBACK';
  END IF;
END $$;

-- REVIEW the rows identified for removal from the STAGING COPY
SELECT s.subject_id, s.sample_class
FROM sitewise_ml.pu_training_1796_20261115 s
JOIN pu_excel_incomplete_53 m USING (subject_id)
ORDER BY s.sample_class, s.subject_id;

-- Actual deletion (ONLY FROM NEW, ISOLATED STAGING TABLE)
DELETE FROM sitewise_ml.pu_training_1796_20261115 s
USING pu_excel_incomplete_53 m
WHERE s.subject_id = m.subject_id;

DO $$ BEGIN
  IF (SELECT COUNT(*) FROM sitewise_ml.pu_training_1796_20261115) <> 1796
     OR (SELECT COUNT(DISTINCT subject_id) FROM sitewise_ml.pu_training_1796_20261115) <> 1796
     OR (SELECT COUNT(*) FROM sitewise_ml.pu_training_1796_20261115 WHERE BTRIM(sample_class)='P') <> 880
     OR (SELECT COUNT(*) FROM sitewise_ml.pu_training_1796_20261115 WHERE BTRIM(sample_class)='U') <> 916
  THEN RAISE EXCEPTION 'Clean training-table count mismatch: ROLLBACK';
  END IF;
END $$;

SELECT BTRIM(sample_class) AS sample_class, COUNT(*) AS rows_after_delete
FROM sitewise_ml.pu_training_1796_20261115 GROUP BY 1 ORDER BY 1;
COMMIT;

-- If any error occurs while inside BEGIN, run ROLLBACK before trying again.
-- Original shared analytics source and live fyp.rental_properties remain unchanged.
-- The 47-column model is trained from the Excel CSV, not this DB staging table.
