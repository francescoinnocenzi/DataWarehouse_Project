-- =====================================================================
--  OLAP QUERIES over the constellation schema
--  (ROLAP: every OLAP operator is expressed as SQL aggregation)
--
--  Two rules apply throughout and follow from the DFM integrity constraints:
--   1. sdr and gdp_per_capita are RATES -> aggregate with AVG, never SUM.
--   2. dim_cause contains only specific causes (Approach 2a). 'All causes'
--      is represented by key_cause IS NULL in the mortality table.
--      Likewise dim_sex contains 'ALL' alongside 'MALE'/'FEMALE'.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Q1. ROLL-UP
--     Air quality is stored at city grain. We climb the geographic
--     hierarchy city -> country -> sub_region and aggregate to the
--     region level, by year.
-- ---------------------------------------------------------------------
SELECT r.sub_region,
       t.year,
       COUNT(DISTINCT ci.key_city)      AS n_cities,
       ROUND(AVG(aq.avg_pm25), 2)       AS pm25,
       ROUND(AVG(aq.avg_pm10), 2)       AS pm10,
       ROUND(AVG(aq.avg_no2), 2)        AS no2
FROM   air_quality aq
JOIN   dim_city    ci ON ci.key_city    = aq.key_city
JOIN   dim_country co ON co.key_country = ci.key_country
JOIN   dim_region  r  ON r.key_region   = co.key_region
JOIN   dim_time    t  ON t.key_time     = aq.key_time
GROUP  BY r.sub_region, t.year
ORDER  BY r.sub_region, t.year;


-- ---------------------------------------------------------------------
-- Q2. ROLL-UP ALONG THE CROSS-DIMENSIONAL ATTRIBUTE (EU Membership)
--      air_quality is at CITY grain and economy at COUNTRY grain: the two are
--      aggregated to a common country-year grain in the CTE before the roll-up,
--      otherwise the GDP would be replicated once per city (fan trap).
--      eu_membership is a cross-dimensional attribute materialised in
--      country_eu_status depending on (country, year).
-- ---------------------------------------------------------------------
WITH country_yearly AS (
    SELECT ci.key_country,
           aq.key_time,
           AVG(aq.avg_pm25) AS pm25
    FROM   air_quality aq
    JOIN   dim_city    ci ON ci.key_city = aq.key_city
    GROUP  BY ci.key_country, aq.key_time
)
SELECT s.eu_membership,
       t.year,
       COUNT(DISTINCT cy.key_country)             AS n_countries,
       ROUND(AVG(cy.pm25), 2)            AS pm25,
       ROUND(AVG(e.gdp_per_capita), 0)   AS avg_gdp
FROM        country_yearly     cy
JOIN        country_eu_status  s ON s.key_country = cy.key_country
                                AND s.key_time    = cy.key_time
JOIN        dim_time           t ON t.key_time    = cy.key_time
LEFT  JOIN  economy            e ON e.key_country = cy.key_country
                                AND e.key_time    = cy.key_time
GROUP  BY s.eu_membership, t.year
HAVING COUNT(DISTINCT cy.key_country) >= 3 
ORDER  BY s.eu_membership, t.year;


-- ---------------------------------------------------------------------
-- Q3. ROLL-UP with the SQL ROLLUP operator
--     Produces region-year detail, region subtotals and the grand total
--     in a single result set (the classic OLAP cube margins).
-- ---------------------------------------------------------------------
SELECT COALESCE(r.sub_region, 'ALL REGIONS')       AS sub_region,
       COALESCE(t.year::text, 'ALL YEARS')         AS year,
       ROUND(AVG(aq.avg_pm25), 2)                  AS pm25
FROM   air_quality aq
JOIN   dim_city    ci ON ci.key_city    = aq.key_city
JOIN   dim_country co ON co.key_country = ci.key_country
JOIN   dim_region  r  ON r.key_region   = co.key_region
JOIN   dim_time    t  ON t.key_time     = aq.key_time
GROUP  BY ROLLUP (r.sub_region, t.year)
ORDER  BY sub_region, year;


-- ---------------------------------------------------------------------
-- Q4. DRILL-DOWN
--     From the aggregate cause group down to the individual cause,
--     for a single region. Excludes the 'All causes' total.
-- ---------------------------------------------------------------------
SELECT ca.cause_group,
       ca.cause,
       t.year,
       ROUND(AVG(m.sdr), 2) AS sdr
FROM   mortality  m
JOIN   dim_country co ON co.key_country = m.key_country
JOIN   dim_region  r  ON r.key_region   = co.key_region
JOIN   dim_cause   ca ON ca.key_cause   = m.key_cause
JOIN   dim_sex     s  ON s.key_sex      = m.key_sex
JOIN   dim_time    t  ON t.key_time     = m.key_time
WHERE  r.sub_region = 'Eastern Europe'
  AND  s.sex        = 'ALL'
GROUP  BY ca.cause_group, ca.cause, t.year
ORDER  BY ca.cause_group, ca.cause, t.year;


-- ---------------------------------------------------------------------
-- Q5. DICE
--     Extracts a sub-cube (Dice) by constraining multiple dimensions:
--     cause = 'Respiratory diseases', sex = 'MALE',
--     sub_region = 'Eastern Europe', and year range 2015-2020.
-- ---------------------------------------------------------------------
SELECT co.country_iso3,
       t.year,
       ROUND(m.sdr, 2) AS respiratory_sdr_male
FROM   mortality  m
JOIN   dim_country co ON co.key_country = m.key_country
JOIN   dim_region  r  ON r.key_region   = co.key_region
JOIN   dim_cause   ca ON ca.key_cause   = m.key_cause
JOIN   dim_sex     s  ON s.key_sex      = m.key_sex
JOIN   dim_time    t  ON t.key_time     = m.key_time
WHERE  ca.cause     = 'Respiratory diseases'
  AND  s.sex        = 'MALE'
  AND  r.sub_region = 'Eastern Europe'
  AND  t.year BETWEEN 2015 AND 2020
ORDER  BY co.country_iso3, t.year;


-- ---------------------------------------------------------------------
-- Q6. PIVOTING
--     The cause dimension is rotated into columns, and the sex dimension
--     is used to compare male and female rates side by side.
-- ---------------------------------------------------------------------
SELECT co.country_iso3,
       t.year,
       ROUND(AVG(m.sdr) FILTER (WHERE ca.cause = 'Circulatory diseases'), 2) AS circulatory,
       ROUND(AVG(m.sdr) FILTER (WHERE ca.cause = 'Respiratory diseases'), 2) AS respiratory,
       ROUND(AVG(m.sdr) FILTER (WHERE ca.cause_group = 'cancer'), 2)         AS lung_cancer,
       ROUND(AVG(m.sdr) FILTER (WHERE m.key_cause IS NULL), 2)                AS all_causes
FROM   mortality  m
JOIN   dim_country co ON co.key_country = m.key_country
LEFT JOIN dim_cause ca ON ca.key_cause  = m.key_cause
JOIN   dim_sex     s  ON s.key_sex      = m.key_sex
JOIN   dim_time    t  ON t.key_time     = m.key_time
WHERE  s.sex  = 'ALL'
  AND  t.year = 2015
GROUP  BY co.country_iso3, t.year
ORDER  BY all_causes DESC NULLS LAST;


-- ---------------------------------------------------------------------
-- Q7. DRILL-ACROSS  (the unified cross-source analysis)
--     Air quality is rolled up from city to country grain, then joined to
--     MORTALITY and ECONOMY on the conformed (country, time) keys.
--     One row combines all four original data sources.
--     population is NOT reported: it is additive over geography, but the
--     ECONOMY source has gaps (RUS reports population only for 2010-2012 and
--     2014), so a regional SUM is not comparable across years - one missing
--     country silently shifts the total by its whole size. n_countries and
--     n_cities are shown instead, so the reader can see the actual coverage.
-- ---------------------------------------------------------------------
WITH aq_country AS (
    SELECT ci.key_country,
           aq.key_time,
           AVG(aq.avg_pm25) AS pm25,
           AVG(aq.avg_no2)  AS no2,
           COUNT(*)         AS n_cities
    FROM   air_quality aq
    JOIN   dim_city    ci ON ci.key_city = aq.key_city
    GROUP  BY ci.key_country, aq.key_time
),
resp AS (
    SELECT m.key_country, m.key_time, m.sdr
    FROM   mortality m
    JOIN   dim_cause ca ON ca.key_cause = m.key_cause
    JOIN   dim_sex   s  ON s.key_sex    = m.key_sex
    WHERE  ca.cause = 'Respiratory diseases' AND s.sex = 'ALL'
)
SELECT r.sub_region,
       t.year,
       COUNT(DISTINCT a.key_country)            AS n_countries,
       SUM(a.n_cities)                          AS n_cities,
       ROUND(AVG(a.pm25), 2)           AS pm25,
       ROUND(AVG(re.sdr), 2)           AS respiratory_sdr,
       ROUND(AVG(e.gdp_per_capita), 0) AS gdp_per_capita
FROM        aq_country a
JOIN        dim_country co ON co.key_country = a.key_country
JOIN        dim_region  r  ON r.key_region   = co.key_region
JOIN        dim_time    t  ON t.key_time     = a.key_time
LEFT  JOIN  resp        re ON re.key_country = a.key_country
                          AND re.key_time    = a.key_time
LEFT  JOIN  economy     e  ON e.key_country  = a.key_country
                          AND e.key_time     = a.key_time
GROUP  BY r.sub_region, t.year
HAVING COUNT(DISTINCT a.key_country) >= 3
ORDER  BY r.sub_region, t.year;




-- ---------------------------------------------------------------------
-- Q8. RANKING / comparative analysis
--     Ranks the most polluted countries in 2018 alongside SDR and GDP.
--     Finding: correlation between PM2.5 and respiratory SDR is ~0,
--     mainly due to grain mismatch (ecological fallacy: city PM2.5 vs
--     national SDR) and age-standardisation removing demographic effects.
--     LEFT JOINs keep rows with data gaps (e.g. BIH, UKR) visible.
-- ---------------------------------------------------------------------

WITH country_year AS (
    SELECT co.key_country,
           co.country_iso3,
           r.sub_region,
           t.key_time,
           t.year,
           AVG(aq.avg_pm25) AS pm25
    FROM   air_quality aq
    JOIN   dim_city    ci ON ci.key_city    = aq.key_city
    JOIN   dim_country co ON co.key_country = ci.key_country
    JOIN   dim_region  r  ON r.key_region   = co.key_region
    JOIN   dim_time    t  ON t.key_time     = aq.key_time
    WHERE  t.year = 2018
    GROUP  BY co.key_country, co.country_iso3, r.sub_region, t.key_time, t.year
),
resp AS (
    SELECT m.key_country, m.key_time, m.sdr
    FROM   mortality m
    JOIN   dim_cause ca ON ca.key_cause = m.key_cause
    JOIN   dim_sex   s  ON s.key_sex    = m.key_sex
    WHERE  ca.cause = 'Respiratory diseases' AND s.sex = 'ALL'
)
SELECT cy.country_iso3,
       cy.sub_region,
       ROUND(cy.pm25, 1)                        AS pm25_2018,
       ROUND(re.sdr, 1)                         AS respiratory_sdr,
       ROUND(e.gdp_per_capita, 0)              AS gdp_per_capita,
       RANK() OVER (ORDER BY cy.pm25 DESC)     AS pollution_rank
FROM       country_year cy
LEFT JOIN  economy     e  ON e.key_country = cy.key_country
                         AND e.key_time    = cy.key_time
LEFT JOIN  resp        re ON re.key_country = cy.key_country
                         AND re.key_time    = cy.key_time
WHERE  cy.pm25 IS NOT NULL
ORDER  BY cy.pm25 DESC
LIMIT  20;