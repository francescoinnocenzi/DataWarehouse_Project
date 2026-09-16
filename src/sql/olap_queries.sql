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
-- Q1b. ROLL-UP ALONG THE CROSS-DIMENSIONAL ATTRIBUTE (EU Membership)
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
       ROUND(AVG(cy.pm25)::numeric, 2)            AS pm25,
       ROUND(AVG(e.gdp_per_capita)::numeric, 0)   AS avg_gdp
FROM        country_yearly     cy
JOIN        country_eu_status  s ON s.key_country = cy.key_country
                                AND s.key_time    = cy.key_time
JOIN        dim_time           t ON t.key_time    = cy.key_time
LEFT  JOIN  economy            e ON e.key_country = cy.key_country
                                AND e.key_time    = cy.key_time
GROUP  BY s.eu_membership, t.year
HAVING COUNT(DISTINCT cy.key_country) >= 3   -- drop years with a degenerate panel
ORDER  BY s.eu_membership, t.year;


-- ---------------------------------------------------------------------
-- Q2. ROLL-UP with the SQL ROLLUP operator
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
-- Q3. DRILL-DOWN
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
-- Q4. SLICE AND DICE
--     Slice: cause = respiratory, sex = MALE, region = Eastern Europe.
--     Dice:  years restricted to 2015-2020.
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
-- Q5. PIVOTING
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
-- Q6. DRILL-ACROSS  (the unified cross-source analysis)
--     Air quality is rolled up from city to country grain, then joined to
--     MORTALITY and ECONOMY on the conformed (country, time) keys.
--     One row combines all four original data sources.
--
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
       ROUND(AVG(a.pm25)::numeric, 2)           AS pm25,
       ROUND(AVG(re.sdr)::numeric, 2)           AS respiratory_sdr,
       ROUND(AVG(e.gdp_per_capita)::numeric, 0) AS gdp_per_capita
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
-- Q7. RANKING / comparative analysis
--     Ranks the most polluted countries in 2018 alongside their health and
--     economic context.
--
--     Analytical finding: at country level the correlation between PM2.5 and
--     respiratory SDR is essentially zero, both in 2018 alone (r = -0.037,
--     n = 30) and pooled over 2010-2019 (r = -0.049, n = 249). The null result
--     is not a data artefact but a modelling one, and the primary explanation
--     comes from the warehouse itself:
--       1. Grain mismatch / ecological fallacy: PM2.5 is measured at CITY
--          grain and averaged up to country to meet the national SDR. That
--          average discards exactly the information that matters - who lives
--          where - and attributes urban pollution to a largely rural population.
--     Secondary explanations, in decreasing order of confidence:
--       2. SDR is age-standardised, so it removes the very channel through
--          which chronic exposure raises mortality (an older population).
--       3. Chronic-exposure mortality lags exposure by 10-20 years; the
--          analysis window is 10.
--       4. Cause-of-death coding varies with health-system quality, which
--          correlates with GDP (cf. DNK: lowest PM2.5 and highest SDR of the
--          top 20).
--
--     NB: some top-ranked countries have gaps in the other sources (BIH has no
--     mortality data, UKR no Eurostat GDP). Rows are kept rather than dropped,
--     so the coverage of the integration stays visible instead of hidden.
--
--     key_time is carried out of the CTE so that ECONOMY and MORTALITY can be
--     joined on the surrogate key directly, with no second lookup into
--     dim_time by year.
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
)
SELECT cy.country_iso3,
       cy.sub_region,
       ROUND(cy.pm25::numeric, 1)              AS pm25_2018,
       ROUND(m.sdr, 1)                         AS respiratory_sdr,
       ROUND(e.gdp_per_capita, 0)              AS gdp_per_capita,
       RANK() OVER (ORDER BY cy.pm25 DESC)     AS pollution_rank
FROM       country_year cy
LEFT JOIN  economy     e  ON e.key_country = cy.key_country
                         AND e.key_time    = cy.key_time
LEFT JOIN  mortality   m  ON m.key_country = cy.key_country
                         AND m.key_time    = cy.key_time
                         AND m.key_cause   = (SELECT key_cause FROM dim_cause
                                              WHERE cause = 'Respiratory diseases')
                         AND m.key_sex     = (SELECT key_sex FROM dim_sex
                                              WHERE sex = 'ALL')
WHERE  cy.pm25 IS NOT NULL
ORDER  BY cy.pm25 DESC
LIMIT  20;

--  NOTA su sub_region e grano:
--  Aggiungere sub_region alla SELECT obbliga ad aggiungerla anche alla GROUP BY,
--  ma il grano NON cambia: un paese appartiene a una sola sub-regione, quindi il
--  raggruppamento non si scompone e la CTE produce comunque una riga per paese.
--  Serve solo ad arricchire il report (es. ITA -> Southern Europe).
--  Lo stesso vale per key_time: e' in corrispondenza uno-a-uno con year.

--  NOTA: Anche se aggreghiamo a livello di sub-region (invece di country)
--  Il livello di aggregazione (grano) NON cambia: La CTE produce comunque 1 sola riga per Paese.
--  Serve per arricchire il report: Estraiamo sub_region solo per mostrare nel report a quale area d'Europa appartiene ogni Paese in classifica (es. ITA ➔ Southern Europe).
--  Regola SQL: In SQL, per mostrare la colonna sub_region nella SELECT, dobbiamo per forza scriverla anche nel GROUP BY. Poiché 1 Paese sta in 1 sola Sub-Regione, il raggruppamento non si scompone.


-- ---------------------------------------------------------------------
-- Q8. TEMPORAL TREND
--     Change in pollution and respiratory mortality between the start and
--     the end of the analysis window, by sub-region.
-- ---------------------------------------------------------------------
WITH by_region_year AS (
    SELECT r.sub_region,
           t.year,
           AVG(aq.avg_pm25) AS pm25
    FROM   air_quality aq
    JOIN   dim_city    ci ON ci.key_city    = aq.key_city
    JOIN   dim_country co ON co.key_country = ci.key_country
    JOIN   dim_region  r  ON r.key_region   = co.key_region
    JOIN   dim_time    t  ON t.key_time     = aq.key_time
    WHERE  t.year IN (2013, 2019)
    GROUP  BY r.sub_region, t.year
)
SELECT sub_region,
       ROUND(MAX(pm25) FILTER (WHERE year = 2013)::numeric, 2) AS pm25_2013,
       ROUND(MAX(pm25) FILTER (WHERE year = 2019)::numeric, 2) AS pm25_2019,
       ROUND((MAX(pm25) FILTER (WHERE year = 2019)
            - MAX(pm25) FILTER (WHERE year = 2013))::numeric, 2) AS change
FROM   by_region_year
GROUP  BY sub_region
ORDER  BY change;