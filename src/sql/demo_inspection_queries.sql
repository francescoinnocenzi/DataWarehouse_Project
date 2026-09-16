-- =====================================================================
--  DEMO INSPECTION QUERIES — DWH & ELT ARCHITECTURE
--
--  Questo file contiene una selezione di query significative ordinate per
--  livello architetturale. Utile per mostrare il funzionamento interno
--  dell'ELT, il log degli scarti (Data Quality) e il Data Warehouse.
-- =====================================================================


-- =====================================================================
--  1. LIVELLO STAGING (Dati Grezzi "Source-Faithful")
-- =====================================================================

-- 1.1 Ispezione delle stringhe composite non elaborate Eurostat (dims)
-- Mostra come la colonna dims unisca più dimensioni separate da virgole (freq, unit, na_item, geo).
SELECT dims, "2010", "2015", "2020"
FROM   staging.stg_eurostat_gdp
LIMIT 5;

-- 1.2 Ispezione dei flag Eurostat (simboli come ':', ': b', o valori testuali sporchi)
SELECT dims, "2018"
FROM   staging.stg_eurostat_gdp
WHERE  "2018" LIKE '%:%' OR "2018" LIKE '%b%'
LIMIT 5;


-- =====================================================================
--  2. LIVELLO DATA QUALITY & REJECT LOG (Audit degli Scarti)
-- =====================================================================

-- 2.1 Summary degli scarti per motivo e tabella sorgente
-- Utilizza la vista v_reject_summary alimentata dal log degli scarti.
SELECT source_table,
       reject_reason,
       n_rejected,
       example_key
FROM   reconciled.v_reject_summary;

-- 2.2 Dettaglio dei primi 10 scarti registrati con valore grezzo
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
--  3. LIVELLO RECONCILED (Tabelle Riconciliate e Normalizzate 3NF)
-- =====================================================================

-- 3.1 Risultato dell'Unpivoting e del FULL JOIN PIL + Popolazione
-- Mostra i dati di PIL e Popolazione affiancati per paese e anno.
SELECT country_iso3,
       year,
       gdp_per_capita,
       population
FROM   reconciled.rec_economy
WHERE  country_iso3 = 'ITA'
ORDER  BY year ASC;

-- 3.2 Qualità dell'aria con medie aggregate per città e anno
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
--  4. LIVELLO DATA WAREHOUSE (Schema a Stella in `public`)
-- =====================================================================

-- 4.1 Verifica della sostituzione delle chiavi naturali con le chiavi surrogate (dim_country e dim_time)
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

-- 4.2 Risoluzione delle omonimie tra città appartenenti a paesi diversi
SELECT dci.key_city,
       dci.city_name,
       dc.country_iso3,
       dc.country_name
FROM   dim_city dci
JOIN   dim_country dc ON dc.key_country = dci.key_country
WHERE  dci.city_name IN ('Limburg', 'Bratislava', 'Victoria')
ORDER  BY dci.city_name, dc.country_name;

-- 4.3 Query Analitica OLAP (Drill-Across: Inquinamento PM2.5 vs Mortalità)
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

