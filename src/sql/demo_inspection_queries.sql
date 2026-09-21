-- =====================================================================
--  DEMO INSPECTION QUERIES: 3-TIER ARCHITECTURE
--  Inspects the 2 schemas of the Data Warehouse ELT pipeline:
--    1. staging    -> Raw ingest (TEXT columns, composite strings, dirty flags)
--    2. reconciled -> Cleaned, reconciled 3NF relations + data quality reject log
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. ARCHITECTURE OVERVIEW: table count per schema tier
-- ---------------------------------------------------------------------
SELECT table_schema,
       COUNT(*) AS num_tables
FROM   information_schema.tables
WHERE  table_schema IN ('staging', 'reconciled', 'public')
  AND  table_type = 'BASE TABLE'
GROUP  BY table_schema
ORDER  BY CASE table_schema
            WHEN 'staging'    THEN 1
            WHEN 'reconciled' THEN 2
            WHEN 'public'     THEN 3
          END;


-- ---------------------------------------------------------------------
-- 1. STAGING TIER: raw unparsed text
--    Shows composite dimensions ('dims') and Eurostat non-numeric flags:
--    'b' (break in series, e.g. '13370 b') and ':' (missing value, e.g. UK 2020).
-- ---------------------------------------------------------------------
SELECT dims, "2015", "2018", "2020"
FROM   staging.stg_eurostat_gdp
WHERE  "2020" LIKE '%b%' OR "2020" LIKE '%:%'
LIMIT  6;


-- ---------------------------------------------------------------------
-- 2. RECONCILED TIER (3NF): cleaned, unpivoted and typed relations
--    Same GDP data reconciled to ISO3, unpivoted into rows, and typed NUMERIC.
-- ---------------------------------------------------------------------
SELECT country_iso3,
       year,
       gdp_per_capita,
       population
FROM   reconciled.rec_economy
WHERE  country_iso3 = 'ITA'
  AND  year BETWEEN 2015 AND 2020
ORDER  BY year;


-- ---------------------------------------------------------------------
-- 2b. DATA QUALITY: audit reject log
--     Summarizes discarded source rows with their rejection reasons.
-- ---------------------------------------------------------------------
SELECT source_table,
       reject_reason,
       n_rejected,
       example_key
FROM   reconciled.v_reject_summary;
