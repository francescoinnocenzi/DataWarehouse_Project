-- =====================================================================
--  LOAD DW FROM RECONCILED LAYER
--
--  This script populates the public Data Warehouse star/constellation schema
--  exclusively from the normalised reconciled schema.
-- =====================================================================

BEGIN;

-- TRUNCATE existing tables and reset surrogate key sequences for idempotency
TRUNCATE air_quality, economy, mortality, country_eu_status;
TRUNCATE dim_city, dim_country, dim_time RESTART IDENTITY CASCADE;
-- Note: dim_region, dim_sex and dim_cause contain seed data initialized by dw_schema.sql.

-- 1. DIMENSION REGION
INSERT INTO dim_region (sub_region, who_region)
SELECT DISTINCT sub_region, who_region
FROM   reconciled.rec_country
ON CONFLICT (sub_region) DO NOTHING;

-- 2. DIMENSION COUNTRY
INSERT INTO dim_country (country_iso3, country_name, key_region)
SELECT rc.country_iso3,
       rc.country_name,
       dr.key_region
FROM   reconciled.rec_country rc
JOIN   dim_region dr ON dr.sub_region = rc.sub_region
ON CONFLICT (country_iso3) DO NOTHING;

-- 3. DIMENSION CITY
INSERT INTO dim_city (city_name, key_country)
SELECT rci.city_name,
       dc.key_country
FROM   reconciled.rec_city rci
JOIN   dim_country dc ON dc.country_iso3 = rci.country_iso3
ON CONFLICT (key_country, city_name) DO NOTHING;

-- 4. DIMENSION TIME
INSERT INTO dim_time (year, decade)
SELECT DISTINCT year,
       (year / 10 * 10)::text || 's' AS decade
FROM (
    SELECT year FROM reconciled.rec_air_quality
    UNION
    SELECT year FROM reconciled.rec_economy
    UNION
    SELECT year FROM reconciled.rec_mortality
) y
ON CONFLICT (year) DO NOTHING;

-- 5. COUNTRY EU STATUS (Cross-dimensional bridge)
INSERT INTO country_eu_status (key_country, key_time, eu_membership)
SELECT dc.key_country,
       dt.key_time,
       CASE
         WHEN rc.eu_accession IS NOT NULL
              AND dt.year >= rc.eu_accession
              AND (rc.eu_exit IS NULL OR dt.year < rc.eu_exit)
         THEN 'EU Member'
         ELSE 'Non-EU'
       END AS eu_membership
FROM   reconciled.rec_country rc
JOIN   dim_country dc ON dc.country_iso3 = rc.country_iso3
CROSS  JOIN dim_time dt
ON CONFLICT (key_country, key_time) DO NOTHING;

-- 6. FACT TABLE: AIR QUALITY
INSERT INTO air_quality (key_city, key_time, avg_pm25, avg_pm10, avg_no2, cov_pm25, cov_pm10, cov_no2)
SELECT dci.key_city,
       dt.key_time,
       raq.avg_pm25,
       raq.avg_pm10,
       raq.avg_no2,
       raq.cov_pm25,
       raq.cov_pm10,
       raq.cov_no2
FROM   reconciled.rec_air_quality raq
JOIN   dim_country dc ON dc.country_iso3 = raq.country_iso3
JOIN   dim_city dci ON dci.key_country = dc.key_country AND dci.city_name = raq.city_name
JOIN   dim_time dt ON dt.year = raq.year
ON CONFLICT DO NOTHING;

-- 7. FACT TABLE: ECONOMY
INSERT INTO economy (key_country, key_time, gdp_per_capita, population)
SELECT dc.key_country,
       dt.key_time,
       re.gdp_per_capita,
       re.population
FROM   reconciled.rec_economy re
JOIN   dim_country dc ON dc.country_iso3 = re.country_iso3
JOIN   dim_time dt ON dt.year = re.year
ON CONFLICT DO NOTHING;

-- 8. FACT TABLE: MORTALITY (Approach 2a: OPTIONAL cause dimension)
INSERT INTO mortality (key_country, key_time, key_sex, key_cause, sdr)
SELECT dc.key_country,
       dt.key_time,
       ds.key_sex,
       dcause.key_cause, -- NULL when cause is 'All causes'
       rm.sdr
FROM   reconciled.rec_mortality rm
JOIN   dim_country dc ON dc.country_iso3 = rm.country_iso3
JOIN   dim_time dt ON dt.year = rm.year
JOIN   dim_sex ds ON ds.sex = rm.sex
LEFT JOIN dim_cause dcause ON dcause.cause = rm.cause
ON CONFLICT DO NOTHING;

COMMIT;
