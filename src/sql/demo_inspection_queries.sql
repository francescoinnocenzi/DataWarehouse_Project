--  DEMO INSPECTION QUERIES — ELT PIPELINE
--  Trimmed selection for a 5-minute demo (3 queries, one per ELT stage)

-- =====================================================================
--  1. STAGING LAYER — raw "dirty" data
-- =====================================================================

-- 1.1 Non-numeric flags/symbols in Eurostat data (':' , 'b', etc.)
-- Shows why cleaning/extraction is needed in the next layers.
SELECT dims, "2018"
FROM   staging.stg_eurostat_gdp
WHERE  "2018" LIKE '%:%' OR "2018" LIKE '%b%'
LIMIT 5;


-- =====================================================================
--  2. DATA QUALITY & REJECT LOG — rejection audit
-- =====================================================================

-- 2.1 Rejection summary by reason and source table
SELECT source_table,
       reject_reason,
       n_rejected,
       example_key
FROM   reconciled.v_reject_summary;


-- =====================================================================
--  3. DATA WAREHOUSE LAYER — Star Schema (public)
-- =====================================================================

-- 3.1 Resolving city name homonyms across different countries
-- Demonstrates the value of surrogate keys (e.g. 'Montana' exists in both Bulgaria and Switzerland).
SELECT dci.key_city,
       dci.city_name,
       dc.country_iso3,
       dc.country_name
FROM   dim_city dci
JOIN   dim_country dc ON dc.key_country = dci.key_country
WHERE  dci.city_name IN ('Limburg', 'Bratislava', 'Montana')
ORDER  BY dci.city_name, dc.country_name;
