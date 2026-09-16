-- =====================================================================
--  ETL: STAGING -> RECONCILED (All Branches)
--
--  This file contains the semantic transformations from raw staging tables
--  into the normalised 3NF reconciled layer.
--
--  Requires: reconciled_schema.sql, and staging populated by etl.py.
-- =====================================================================

BEGIN;

TRUNCATE reconciled.rec_air_quality;
TRUNCATE reconciled.rec_city CASCADE;
TRUNCATE reconciled.rec_economy;
TRUNCATE reconciled.rec_mortality;
TRUNCATE reconciled.rec_country CASCADE;
TRUNCATE reconciled.rec_reject_log;


-- =====================================================================
--  0. HELPERS
-- =====================================================================

CREATE OR REPLACE FUNCTION staging.clean_eurostat(raw TEXT)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN raw IS NULL THEN NULL
             ELSE NULLIF(NULLIF(REGEXP_REPLACE(raw, '[^0-9.\-]', '', 'g'), ''), '-')::numeric
           END;
$$;

-- =====================================================================
--  1. RECONCILED COUNTRY REGISTER
-- =====================================================================

CREATE TEMP TABLE tmp_observed_iso3 AS
    SELECT DISTINCT TRIM(iso3) AS country_iso3, 'stg_who_aap' AS src
    FROM   staging.stg_who_aap
    WHERE  TRIM(iso3) ~ '^[A-Z]{3}$'
UNION
    SELECT DISTINCT m.country_iso3, 'stg_eurostat_gdp'
    FROM   staging.stg_eurostat_gdp s
    JOIN   staging.map_eurostat_iso3 m ON m.geo_code = TRIM(SPLIT_PART(s.dims, ',', 4))
UNION
    SELECT DISTINCT m.country_iso3, 'stg_eurostat_pop'
    FROM   staging.stg_eurostat_pop s
    JOIN   staging.map_eurostat_iso3 m ON m.geo_code = TRIM(SPLIT_PART(s.dims, ',', 5))
UNION
    SELECT DISTINCT TRIM(country), 'stg_hfamdb_mortality'
    FROM   staging.stg_hfamdb_mortality
    WHERE  TRIM(country) ~ '^[A-Z]{3}$';

INSERT INTO reconciled.rec_country
       (country_iso3, country_name, sub_region, who_region, eu_accession, eu_exit)
SELECT sr.country_iso3,
       sr.country_name,
       sr.sub_region,
       'European Region',
       eu.accession_year,
       eu.exit_year
FROM        (SELECT DISTINCT country_iso3 FROM tmp_observed_iso3) o
JOIN        staging.map_iso3_subregion  sr ON sr.country_iso3 = o.country_iso3
LEFT  JOIN  staging.map_eu_membership   eu ON eu.country_iso3 = o.country_iso3;

-- Reject Log: ISO3 outside geographic Europe
INSERT INTO reconciled.rec_reject_log (source_table, reject_reason, natural_key)
SELECT o.src,
       'ISO3 outside geographic Europe (absent from map_iso3_subregion)',
       o.country_iso3
FROM   tmp_observed_iso3 o
WHERE  NOT EXISTS (SELECT * FROM staging.map_iso3_subregion sr
                   WHERE sr.country_iso3 = o.country_iso3);


-- =====================================================================
--  2. REJECT LOG FOR EUROSTAT GEO CODES
-- =====================================================================

WITH geo AS (
    SELECT 'stg_eurostat_gdp' AS src, TRIM(SPLIT_PART(dims, ',', 4)) AS geo_code
    FROM   staging.stg_eurostat_gdp
    UNION
    SELECT 'stg_eurostat_pop', TRIM(SPLIT_PART(dims, ',', 5))
    FROM   staging.stg_eurostat_pop
)
INSERT INTO reconciled.rec_reject_log (source_table, reject_reason, natural_key)
SELECT g.src,
       CASE WHEN a.geo_code IS NOT NULL
            THEN 'Eurostat aggregate, not a country'
            ELSE 'Eurostat geo code with no ISO3 mapping' END,
       g.geo_code
FROM        geo g
LEFT  JOIN  staging.map_eurostat_iso3      m ON m.geo_code = g.geo_code
LEFT  JOIN  staging.map_eurostat_aggregate a ON a.geo_code = g.geo_code
WHERE  m.geo_code IS NULL;


-- =====================================================================
--  3. RECONCILED ECONOMY
-- =====================================================================

CREATE TEMP TABLE tmp_gdp AS
SELECT m.country_iso3,
       y.year,
       staging.clean_eurostat(y.raw) AS gdp_per_capita
FROM   staging.stg_eurostat_gdp s
CROSS  JOIN LATERAL (VALUES
           (1975::smallint, s."1975"), (1976, s."1976"), (1977, s."1977"), (1978, s."1978"), (1979, s."1979"),
           (1980, s."1980"), (1981, s."1981"), (1982, s."1982"), (1983, s."1983"), (1984, s."1984"),
           (1985, s."1985"), (1986, s."1986"), (1987, s."1987"), (1988, s."1988"), (1989, s."1989"),
           (1990, s."1990"), (1991, s."1991"), (1992, s."1992"), (1993, s."1993"), (1994, s."1994"),
           (1995, s."1995"), (1996, s."1996"), (1997, s."1997"), (1998, s."1998"), (1999, s."1999"),
           (2000, s."2000"), (2001, s."2001"), (2002, s."2002"), (2003, s."2003"), (2004, s."2004"),
           (2005, s."2005"), (2006, s."2006"), (2007, s."2007"), (2008, s."2008"), (2009, s."2009"),
           (2010, s."2010"), (2011, s."2011"), (2012, s."2012"), (2013, s."2013"), (2014, s."2014"),
           (2015, s."2015"), (2016, s."2016"), (2017, s."2017"), (2018, s."2018"), (2019, s."2019"),
           (2020, s."2020"), (2021, s."2021"), (2022, s."2022"), (2023, s."2023"), (2024, s."2024"),
           (2025, s."2025")
       ) AS y(year, raw)
JOIN   staging.map_eurostat_iso3 m
       ON m.geo_code = TRIM(SPLIT_PART(s.dims, ',', 4))
WHERE  TRIM(SPLIT_PART(s.dims, ',', 2)) = 'CLV10_EUR_HAB' -- Chain linked volume series in 2010 prices in EUR
  AND  TRIM(SPLIT_PART(s.dims, ',', 3)) = 'B1GQ'; -- Gross domestic product

CREATE TEMP TABLE tmp_pop AS
SELECT m.country_iso3,
       y.year,
       staging.clean_eurostat(y.raw) AS population
FROM   staging.stg_eurostat_pop s
CROSS  JOIN LATERAL (VALUES
           (1960::smallint, s."1960"), (1961, s."1961"), (1962, s."1962"), (1963, s."1963"), (1964, s."1964"),
           (1965, s."1965"), (1966, s."1966"), (1967, s."1967"), (1968, s."1968"), (1969, s."1969"),
           (1970, s."1970"), (1971, s."1971"), (1972, s."1972"), (1973, s."1973"), (1974, s."1974"),
           (1975, s."1975"), (1976, s."1976"), (1977, s."1977"), (1978, s."1978"), (1979, s."1979"),
           (1980, s."1980"), (1981, s."1981"), (1982, s."1982"), (1983, s."1983"), (1984, s."1984"),
           (1985, s."1985"), (1986, s."1986"), (1987, s."1987"), (1988, s."1988"), (1989, s."1989"),
           (1990, s."1990"), (1991, s."1991"), (1992, s."1992"), (1993, s."1993"), (1994, s."1994"),
           (1995, s."1995"), (1996, s."1996"), (1997, s."1997"), (1998, s."1998"), (1999, s."1999"),
           (2000, s."2000"), (2001, s."2001"), (2002, s."2002"), (2003, s."2003"), (2004, s."2004"),
           (2005, s."2005"), (2006, s."2006"), (2007, s."2007"), (2008, s."2008"), (2009, s."2009"),
           (2010, s."2010"), (2011, s."2011"), (2012, s."2012"), (2013, s."2013"), (2014, s."2014"),
           (2015, s."2015"), (2016, s."2016"), (2017, s."2017"), (2018, s."2018"), (2019, s."2019"),
           (2020, s."2020"), (2021, s."2021"), (2022, s."2022"), (2023, s."2023"), (2024, s."2024"),
           (2025, s."2025")
       ) AS y(year, raw)
JOIN   staging.map_eurostat_iso3 m
       ON m.geo_code = TRIM(SPLIT_PART(s.dims, ',', 5))
WHERE  TRIM(SPLIT_PART(s.dims, ',', 3)) = 'TOTAL' -- Total age	
  AND  TRIM(SPLIT_PART(s.dims, ',', 4)) = 'T'; -- All genders

INSERT INTO reconciled.rec_economy (country_iso3, year, gdp_per_capita, population)
-- Deduplicate using average in case of multiple entries
SELECT COALESCE(g.country_iso3, p.country_iso3)  AS country_iso3,
       COALESCE(g.year,         p.year)          AS year,
       AVG(g.gdp_per_capita)                     AS gdp_per_capita,
       ROUND(AVG(p.population))::bigint          AS population
FROM        tmp_gdp g
FULL  JOIN  tmp_pop p ON p.country_iso3 = g.country_iso3
                      AND p.year         = g.year
WHERE  COALESCE(g.country_iso3, p.country_iso3) IN
            (SELECT country_iso3 FROM reconciled.rec_country)
  AND  COALESCE(g.year, p.year) BETWEEN 2010 AND 2020
GROUP BY COALESCE(g.country_iso3, p.country_iso3),
          COALESCE(g.year, p.year)
HAVING AVG(g.gdp_per_capita) IS NOT NULL
    OR AVG(p.population)     IS NOT NULL;


-- =====================================================================
--  4. RECONCILED CITY AND AIR QUALITY
-- =====================================================================

CREATE TEMP TABLE tmp_raw_aq AS
WITH clean_aq AS (
    SELECT TRIM(iso3)                            AS country_iso3,
           TRIM(city_or_locality)                AS city_name,
           TRIM(measurement_year)                AS year_txt,
           TRIM(pm25)                            AS pm25_txt,
           TRIM(pm10)                            AS pm10_txt,
           TRIM(no2)                             AS no2_txt,
           TRIM(cov_pm25)                        AS cov_pm25_txt,
           TRIM(cov_pm10)                        AS cov_pm10_txt,
           TRIM(cov_no2)                         AS cov_no2_txt
    FROM   staging.stg_who_aap
    WHERE  who_region = 'European Region'
      AND  TRIM(iso3) ~ '^[A-Z]{3}$'
      AND  TRIM(measurement_year) ~ '^[0-9]+$'
)
SELECT country_iso3,
       city_name,
       year_txt::smallint                        AS year,
       NULLIF(pm25_txt, '')::numeric            AS avg_pm25,
       NULLIF(pm10_txt, '')::numeric            AS avg_pm10,
       NULLIF(no2_txt, '')::numeric             AS avg_no2,
       NULLIF(cov_pm25_txt, '')::numeric        AS cov_pm25,
       NULLIF(cov_pm10_txt, '')::numeric        AS cov_pm10,
       NULLIF(cov_no2_txt, '')::numeric         AS cov_no2
FROM   clean_aq;

-- Populate rec_city
INSERT INTO reconciled.rec_city (country_iso3, city_name)
SELECT DISTINCT country_iso3, city_name
FROM   tmp_raw_aq
WHERE  country_iso3 IN (SELECT country_iso3 FROM reconciled.rec_country)
  AND  city_name IS NOT NULL AND city_name != ''
ON CONFLICT (country_iso3, city_name) DO NOTHING;

-- Populate rec_air_quality (aggregating duplicate city-year entries)
INSERT INTO reconciled.rec_air_quality
    (country_iso3, city_name, year, avg_pm25, avg_pm10, avg_no2,
     cov_pm25, cov_pm10, cov_no2)
SELECT country_iso3,
       city_name,
       year,
       AVG(avg_pm25) AS avg_pm25,
       AVG(avg_pm10) AS avg_pm10,
       AVG(avg_no2)  AS avg_no2,
       AVG(cov_pm25) AS cov_pm25,
       AVG(cov_pm10) AS cov_pm10,
       AVG(cov_no2)  AS cov_no2
FROM   tmp_raw_aq
WHERE  country_iso3 IN (SELECT country_iso3 FROM reconciled.rec_country)
  AND  city_name IS NOT NULL AND city_name != ''
  AND  year BETWEEN 2010 AND 2020
GROUP  BY country_iso3, city_name, year
HAVING AVG(avg_pm25) IS NOT NULL
    OR AVG(avg_pm10) IS NOT NULL
    OR AVG(avg_no2)  IS NOT NULL;


-- =====================================================================
--  5. RECONCILED MORTALITY
-- =====================================================================

WITH clean_mort AS (
    SELECT TRIM(m.country) AS country_iso3,
           TRIM(m.year)    AS year_txt,
           TRIM(m.sex)     AS sex,
           m.cause_label,
           TRIM(m.value)   AS value_txt
    FROM   staging.stg_hfamdb_mortality m
    WHERE  TRIM(m.country) ~ '^[A-Z]{3}$'
      AND  TRIM(m.year)    ~ '^[0-9]+$'
      AND  TRIM(m.value)   ~ '^[0-9]+(\.[0-9]+)?$'
)
INSERT INTO reconciled.rec_mortality (country_iso3, year, sex, cause, sdr)
SELECT c.country_iso3,
       c.year_txt::smallint,
       c.sex,
       mc.cause,
       AVG(c.value_txt::numeric)
FROM   clean_mort c
JOIN   staging.map_cause mc ON mc.cause_label = c.cause_label
WHERE  c.country_iso3 IN (SELECT country_iso3 FROM reconciled.rec_country)
  AND  c.year_txt::smallint BETWEEN 2010 AND 2020
GROUP  BY c.country_iso3,
          c.year_txt::smallint,
          c.sex,
          mc.cause;

COMMIT;
