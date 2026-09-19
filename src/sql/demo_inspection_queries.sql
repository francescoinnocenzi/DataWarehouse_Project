--  DEMO INSPECTION QUERIES — DWH & ELT ARCHITECTURE

-- =====================================================================
--  1. STAGING LAYER (Raw "Source-Faithful" Data)
-- =====================================================================

-- 1.1 Inspection of raw composite strings from Eurostat (dims column)
-- Shows how the 'dims' column combines multiple dimensions separated by commas (freq, unit, na_item, geo).
-- This highlights the need for data cleaning and extraction in the next tier.
SELECT dims, "2010", "2015", "2020"
FROM   staging.stg_eurostat_gdp
LIMIT 5;

-- 1.2 Inspection of Eurostat data flags (symbols like ':', ': b', or dirty textual values)
-- Demonstrates the presence of non-numeric characters in numeric columns that must be cleaned.
SELECT dims, "2018"
FROM   staging.stg_eurostat_gdp
WHERE  "2018" LIKE '%:%' OR "2018" LIKE '%b%'
LIMIT 5;


-- =====================================================================
--  2. DATA QUALITY & REJECT LOG LAYER (Rejection Audit)
-- =====================================================================

-- 2.1 Rejection summary by reason and source table
-- Uses the 'v_reject_summary' view to aggregate data from the reject log, providing a high-level overview of data quality issues.
SELECT source_table,
       reject_reason,
       n_rejected,
       example_key
FROM   reconciled.v_reject_summary;

-- 2.2 Detail of the first 10 recorded rejections with their raw values
-- Inspects the actual rejected records and the raw values that caused the failure, allowing for troubleshooting.
SELECT reject_id,
       source_table,
       reject_reason,
       natural_key,
       raw_value,
       rejected_at
FROM   reconciled.rec_reject_log
ORDER  BY reject_id ASC
LIMIT 10;


-- =====================================================================
--  3. RECONCILED LAYER (Reconciled and 3NF Normalized Tables)
-- =====================================================================

-- 3.1 Result of Unpivoting and FULL JOIN of GDP + Population
-- Shows GDP and Population data aligned side-by-side by country and year. 
-- The wide format from Eurostat has been successfully unpivoted into a long format.
SELECT country_iso3,
       year,
       gdp_per_capita,
       population
FROM   reconciled.rec_economy
WHERE  country_iso3 = 'ITA'
ORDER  BY year ASC;

-- 3.2 Air Quality with aggregated averages by city and year
-- Shows the cleaned and consolidated air quality metrics grouped at the city-year grain.
SELECT country_iso3,
       city_name,
       year,
       avg_pm25,
       avg_pm10,
       avg_no2
FROM   reconciled.rec_air_quality
WHERE  country_iso3 = 'ITA' AND city_name = 'Roma'
ORDER  BY year ASC;


-- =====================================================================
--  4. DATA WAREHOUSE LAYER (Star Schema in the `public` schema)
-- =====================================================================

-- 4.1 Verification of natural key replacement with surrogate keys (dim_country and dim_time)
-- Shows how the fact table (economy) is linked to dimension tables using integer surrogate keys instead of natural keys.
SELECT e.key_country,
       dc.country_iso3,
       dc.country_name,
       e.key_time,
       dt.year,
       e.gdp_per_capita,
       e.population
FROM   economy e
JOIN   dim_country dc ON dc.key_country = e.key_country
JOIN   dim_time    dt ON dt.key_time    = e.key_time
WHERE  dc.country_iso3 = 'ITA'
ORDER  BY dt.year ASC;

-- 4.2 Resolution of city name homonyms across different countries
-- Demonstrates how surrogate keys successfully distinguish cities with the exact same name that belong to different countries (e.g., Victoria).
SELECT dci.key_city,
       dci.city_name,
       dc.country_iso3,
       dc.country_name
FROM   dim_city dci
JOIN   dim_country dc ON dc.key_country = dci.key_country
WHERE  dci.city_name IN ('Limburg', 'Bratislava', 'Victoria')
ORDER  BY dci.city_name, dc.country_name;

-- 4.3 Analytical OLAP Query (Drill-Across: PM2.5 Pollution vs Mortality)
-- A cross-fact analysis joining Air Quality and Mortality on the conformed dimensions (Geography and Time) to find correlations.
SELECT dc.country_name,
       dt.year,
       ROUND(AVG(aq.avg_pm25), 2) AS avg_pm25_country,
       ROUND(AVG(m.sdr), 2)       AS avg_mortality_sdr
FROM   air_quality aq
JOIN   dim_city dci    ON dci.key_city = aq.key_city
JOIN   dim_country dc  ON dc.key_country = dci.key_country
JOIN   dim_time dt     ON dt.key_time = aq.key_time
JOIN   mortality m     ON m.key_country = dc.key_country AND m.key_time = dt.key_time
WHERE  dt.year = 2018
GROUP  BY dc.country_name, dt.year
HAVING AVG(aq.avg_pm25) IS NOT NULL AND AVG(m.sdr) IS NOT NULL
ORDER  BY avg_pm25_country DESC
LIMIT 10;
