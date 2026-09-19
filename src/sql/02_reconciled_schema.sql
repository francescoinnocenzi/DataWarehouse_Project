--  RECONCILED LAYER — DDL
--
--  Three-tier architecture:
--     sources  ->  staging      (source-faithful, all TEXT, no semantics)
--              ->  reconciled   (normalised 3NF, canonical keys, clean types)
--              ->  public       (constellation schema: the data warehouse)
--
--  Division of labour, deliberate and stated:
--    * Python does INGESTION ONLY. It opens the files, picks the right
--      worksheet, locates the header row buried under the source metadata,
--      and copies the columns verbatim into staging as TEXT.
--    * Every SEMANTIC transformation — key reconciliation, value cleaning,
--      geographic filtering, grain de-duplication, aggregation — happens in
--      SQL between staging and reconciled (see etl_reconciled.sql).
--    * The warehouse is loaded exclusively from reconciled (see load_dw.sql).
--      No object in the public schema ever reads from staging.
--
-- =====================================================================

DROP SCHEMA IF EXISTS staging    CASCADE;
DROP SCHEMA IF EXISTS reconciled CASCADE;

CREATE SCHEMA staging;
CREATE SCHEMA reconciled;

COMMENT ON SCHEMA staging    IS 'Source-faithful landing area. All columns TEXT, no constraints, no semantics.';
COMMENT ON SCHEMA reconciled IS 'Normalised integrated layer. Canonical ISO3 keys, typed values, one row per declared grain.';


-- =====================================================================
--  1. STAGING — SOURCE TABLES
--
--  Every column is TEXT on purpose. Staging must accept whatever the source
--  contains, including the values that a typed column would reject: Eurostat
--  observation flags ('31200 p'), the missing-value marker (':'), and
--  footer junk. Casting is a semantic decision and belongs in the
--  staging -> reconciled step, not in the landing area.
-- =====================================================================

-- ---------------------------------------------------------------------
-- WHO Ambient Air Quality Database 2022, worksheet 'AAP_2022_city_v9'.
-- Column names are normalised to snake_case at ingestion because the source
-- headers contain spaces, parentheses and the micro sign ('PM2.5 (ug/m3)'),
-- which would otherwise require quoted identifiers in every query.
-- Grain in the source: NOT unique on (iso3, city, year) — duplicates exist
-- and are resolved in the reconciled layer.
-- ---------------------------------------------------------------------
CREATE TABLE staging.stg_who_aap (
    who_region        TEXT,
    iso3              TEXT,
    who_country_name  TEXT,
    city_or_locality  TEXT,
    measurement_year  TEXT,
    pm25              TEXT,
    pm10              TEXT,
    no2               TEXT,
    cov_pm25          TEXT,
    cov_pm10          TEXT,
    cov_no2           TEXT,
    reference         TEXT,
    monitoring_stations TEXT,
    db_version        TEXT,
    status            TEXT
);

-- ---------------------------------------------------------------------
-- Eurostat nama_10_pc — GDP per capita.
--
-- The source TSV is WIDE: 51 year columns (1975 to 2025), and the first
-- column packs four dimensions into a single comma-separated string:
--     "freq,unit,na_item,geo\TIME_PERIOD"
-- Staging keeps the composite column verbatim and all year columns present
-- in the source TSV (1975 to 2025). Filtering for the 2010-2020 analysis
-- window is deferred to the staging -> reconciled step in SQL.
--
-- The wide-to-long unpivot is performed in SQL — see etl_reconciled.sql.
-- ---------------------------------------------------------------------
CREATE TABLE staging.stg_eurostat_gdp (
    dims    TEXT,            -- 'A,CLV10_EUR_HAB,B1GQ,IT'
    "1975" TEXT, "1976" TEXT, "1977" TEXT, "1978" TEXT, "1979" TEXT,
    "1980" TEXT, "1981" TEXT, "1982" TEXT, "1983" TEXT, "1984" TEXT,
    "1985" TEXT, "1986" TEXT, "1987" TEXT, "1988" TEXT, "1989" TEXT,
    "1990" TEXT, "1991" TEXT, "1992" TEXT, "1993" TEXT, "1994" TEXT,
    "1995" TEXT, "1996" TEXT, "1997" TEXT, "1998" TEXT, "1999" TEXT,
    "2000" TEXT, "2001" TEXT, "2002" TEXT, "2003" TEXT, "2004" TEXT,
    "2005" TEXT, "2006" TEXT, "2007" TEXT, "2008" TEXT, "2009" TEXT,
    "2010" TEXT, "2011" TEXT, "2012" TEXT, "2013" TEXT, "2014" TEXT,
    "2015" TEXT, "2016" TEXT, "2017" TEXT, "2018" TEXT, "2019" TEXT,
    "2020" TEXT, "2021" TEXT, "2022" TEXT, "2023" TEXT, "2024" TEXT,
    "2025" TEXT
);

-- ---------------------------------------------------------------------
-- Eurostat demo_pjan — population on 1 January.
-- Same wide layout; the composite column carries five dimensions:
--     "freq,unit,age,sex,geo\TIME_PERIOD"
-- All year columns present in the source TSV (1960 to 2025).
-- ---------------------------------------------------------------------
CREATE TABLE staging.stg_eurostat_pop (
    dims    TEXT,            -- 'A,NR,TOTAL,T,IT'
    "1960" TEXT, "1961" TEXT, "1962" TEXT, "1963" TEXT, "1964" TEXT,
    "1965" TEXT, "1966" TEXT, "1967" TEXT, "1968" TEXT, "1969" TEXT,
    "1970" TEXT, "1971" TEXT, "1972" TEXT, "1973" TEXT, "1974" TEXT,
    "1975" TEXT, "1976" TEXT, "1977" TEXT, "1978" TEXT, "1979" TEXT,
    "1980" TEXT, "1981" TEXT, "1982" TEXT, "1983" TEXT, "1984" TEXT,
    "1985" TEXT, "1986" TEXT, "1987" TEXT, "1988" TEXT, "1989" TEXT,
    "1990" TEXT, "1991" TEXT, "1992" TEXT, "1993" TEXT, "1994" TEXT,
    "1995" TEXT, "1996" TEXT, "1997" TEXT, "1998" TEXT, "1999" TEXT,
    "2000" TEXT, "2001" TEXT, "2002" TEXT, "2003" TEXT, "2004" TEXT,
    "2005" TEXT, "2006" TEXT, "2007" TEXT, "2008" TEXT, "2009" TEXT,
    "2010" TEXT, "2011" TEXT, "2012" TEXT, "2013" TEXT, "2014" TEXT,
    "2015" TEXT, "2016" TEXT, "2017" TEXT, "2018" TEXT, "2019" TEXT,
    "2020" TEXT, "2021" TEXT, "2022" TEXT, "2023" TEXT, "2024" TEXT,
    "2025" TEXT
);

-- ---------------------------------------------------------------------
-- WHO/Europe HFA-MDB mortality, four files unioned at ingestion.
-- Each source file carries roughly thirty lines of metadata before the
-- header row; locating it is file parsing and stays in Python.
-- cause_label is added by the loader, one constant per file, and is the
-- only column not present in the sources.
-- ---------------------------------------------------------------------
CREATE TABLE staging.stg_hfamdb_mortality (
    country          TEXT,
    country_grp      TEXT,
    age_grp_list     TEXT,
    sex              TEXT,
    subnational_mdb  TEXT,
    year             TEXT,
    value            TEXT,
    cause_label      TEXT,   -- 'All causes' | 'Circulatory diseases' | ...
    source_file      TEXT    -- provenance, for the reject log
);


-- =====================================================================
--  2. STAGING — RECONCILIATION MAPPING TABLES
--  Holding them as relations rather than code means the reconciliation rules are
--  queryable, auditable and joinable.
-- =====================================================================

-- Eurostat 2-letter geo code -> ISO 3166-1 alpha-3.
-- Note the two classic exceptions: EL = Greece, UK = United Kingdom.
CREATE TABLE staging.map_eurostat_iso3 (
    geo_code      CHAR(2)  PRIMARY KEY,
    country_iso3  CHAR(3)  NOT NULL
);

-- Eurostat geo codes that are aggregates, not countries (EU27_2020, EA20,
-- EEA31, EFTA, ...). Held as a table rather than a regex so the exclusion
-- list is explicit and reviewable.
CREATE TABLE staging.map_eurostat_aggregate (
    geo_code  VARCHAR(12)  PRIMARY KEY,
    label     VARCHAR(80)
);

-- ISO3 -> UN geoscheme sub-region for Europe.
-- Membership of this table defines the geographic scope of the warehouse:
-- a country absent from it is outside geographic Europe and is rejected.
CREATE TABLE staging.map_iso3_subregion (
    country_iso3  CHAR(3)      PRIMARY KEY,
    country_name  VARCHAR(80)  NOT NULL,
    sub_region    VARCHAR(30)  NOT NULL,
    CONSTRAINT ck_map_subregion CHECK (sub_region IN
        ('Northern Europe', 'Southern Europe', 'Eastern Europe', 'Western Europe'))
);

-- EU membership as a validity interval per country.
-- accession_year / exit_year depend on the country alone, so they are proper
-- descriptive attributes and live here. The warehouse materialises them over
-- (country, year) in country_eu_status, because eu_membership itself is a
-- CROSS-DIMENSIONAL attribute 
CREATE TABLE staging.map_eu_membership (
    country_iso3    CHAR(3)   PRIMARY KEY,
    accession_year  SMALLINT  NOT NULL,
    exit_year       SMALLINT,            -- NULL = still a member
    CONSTRAINT ck_eu_interval CHECK (exit_year IS NULL OR exit_year > accession_year)
);

-- Cause label as written by the loader -> canonical cause and its group.
-- 'All causes' maps to cause_group NULL: it is the total, not a member of
-- the cause dimension
CREATE TABLE staging.map_cause (
    cause_label  VARCHAR(60)  PRIMARY KEY,
    cause        VARCHAR(60)  NOT NULL,
    cause_group  VARCHAR(30)
);


-- =====================================================================
--  3. RECONCILED — INTEGRATED NORMALISED LAYER
--
--  Natural keys throughout (country_iso3, city_name, year).
--
--  Every table here satisfies its declared grain as a primary key. That is
--  the contract of this layer: whatever duplication the sources contain has
--  already been resolved upstream of it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Reconciled country register. Populated from map_iso3_subregion joined to
-- the set of ISO3 codes actually observed in the three sources, so a country
-- appears only if it carries data.
-- Grain: one row per country (country_iso3).
-- ---------------------------------------------------------------------
CREATE TABLE reconciled.rec_country (
    country_iso3   CHAR(3)      PRIMARY KEY,
    country_name   VARCHAR(80)  NOT NULL,
    sub_region     VARCHAR(30)  NOT NULL,
    who_region     VARCHAR(40)  NOT NULL DEFAULT 'European Region',
    eu_accession   SMALLINT,    -- NULL = never an EU member in any year
    eu_exit        SMALLINT     -- NULL = still a member
);

-- Grain: one row per (country, city) (country_iso3, city_name).
CREATE TABLE reconciled.rec_city (
    country_iso3  CHAR(3)       NOT NULL REFERENCES reconciled.rec_country (country_iso3),
    city_name     VARCHAR(120)  NOT NULL,
    CONSTRAINT pk_rec_city PRIMARY KEY (country_iso3, city_name)
);

-- Grain: one row per (country, city, year). The WHO source contains duplicate city-year rows
-- (20 292 raw rows collapse to 20 210); they are averaged in the reconciled
-- step, so the primary key below (country_iso3, city_name, year) is what enforces the contract.
CREATE TABLE reconciled.rec_air_quality (
    country_iso3  CHAR(3)       NOT NULL,
    city_name     VARCHAR(120)  NOT NULL,
    year          SMALLINT      NOT NULL,
    avg_pm25      NUMERIC(8,3),
    avg_pm10      NUMERIC(8,3),
    avg_no2       NUMERIC(8,3),
    cov_pm25      NUMERIC(5,2),
    cov_pm10      NUMERIC(5,2),
    cov_no2       NUMERIC(5,2),
    CONSTRAINT pk_rec_aq PRIMARY KEY (country_iso3, city_name, year),
    CONSTRAINT fk_rec_aq_city FOREIGN KEY (country_iso3, city_name)
        REFERENCES reconciled.rec_city (country_iso3, city_name),
    CONSTRAINT ck_rec_aq_nonneg CHECK (
        COALESCE(avg_pm25, 0) >= 0 AND
        COALESCE(avg_pm10, 0) >= 0 AND
        COALESCE(avg_no2,  0) >= 0
    ),
    CONSTRAINT ck_rec_aq_not_empty CHECK (
        avg_pm25 IS NOT NULL OR avg_pm10 IS NOT NULL OR avg_no2 IS NOT NULL
    )
);

-- Grain: one row per (country, year). GDP and population arrive from two different
-- Eurostat files and are merged here on (country, year): this is the first
-- point in the pipeline where the two sources become one relation.
CREATE TABLE reconciled.rec_economy (
    country_iso3    CHAR(3)   NOT NULL REFERENCES reconciled.rec_country (country_iso3),
    year            SMALLINT  NOT NULL,
    gdp_per_capita  NUMERIC(12,2),
    population      BIGINT,
    CONSTRAINT pk_rec_economy PRIMARY KEY (country_iso3, year),
    CONSTRAINT ck_rec_eco_nonneg CHECK (
        COALESCE(gdp_per_capita, 0) >= 0 AND COALESCE(population, 0) >= 0
    ),
    CONSTRAINT ck_rec_eco_not_empty CHECK (
        gdp_per_capita IS NOT NULL OR population IS NOT NULL
    )
);

-- Grain: one row per (country, year, sex, cause).
-- Unlike the warehouse fact table, cause is NOT NULL here: the reconciled
-- layer keeps 'All causes' as an ordinary label. Turning it into a NULL key
-- is the optional-dimension encoding of the DFM (Approach 2a) and therefore
-- a warehouse decision, applied in load_dw.sql.
-- sdr is an age-standardised RATE per 100 000: aggregate with AVG, never SUM.
CREATE TABLE reconciled.rec_mortality (
    country_iso3  CHAR(3)      NOT NULL REFERENCES reconciled.rec_country (country_iso3),
    year          SMALLINT     NOT NULL,
    sex           VARCHAR(10)  NOT NULL,
    cause         VARCHAR(60)  NOT NULL,
    sdr           NUMERIC(10,3),
    CONSTRAINT pk_rec_mortality PRIMARY KEY (country_iso3, year, sex, cause),
    CONSTRAINT ck_rec_sex CHECK (sex IN ('ALL', 'MALE', 'FEMALE')),
    CONSTRAINT ck_rec_sdr_nonneg CHECK (sdr IS NULL OR sdr >= 0)
);


-- =====================================================================
--  4. RECONCILED — DATA QUALITY
--
--  Every filter applied between staging and reconciled writes the rows it
--  discards here, with the reason. Without this the exclusions are invisible
--  and the integration cannot be audited: the difference between "no data"
--  and "data we chose to drop" is only recoverable if it is recorded.
-- =====================================================================

CREATE TABLE reconciled.rec_reject_log (
    reject_id      BIGSERIAL     PRIMARY KEY,
    source_table   VARCHAR(40)   NOT NULL,
    reject_reason  VARCHAR(80)   NOT NULL,
    natural_key    VARCHAR(200)  NOT NULL,   -- source identifier of the row
    rejected_at    TIMESTAMP     NOT NULL DEFAULT now()
);

-- Composite index supporting fast GROUP BY queries and enabling Index-Only Scans
-- for the v_reject_summary view even over large historical log volumes.
CREATE INDEX ix_reject_reason ON reconciled.rec_reject_log (source_table, reject_reason);

-- Summary view for the presentation: one line per exclusion rule, with counts.
-- Powered by Index-Only Scan on ix_reject_reason: since the GROUP BY aggregates
-- strictly over (source_table, reject_reason), PostgreSQL can satisfy the count
-- directly from the composite index without reading table heap pages.
CREATE VIEW reconciled.v_reject_summary AS
SELECT source_table,
       reject_reason,
       COUNT(*)                             AS n_rejected,
       MIN(natural_key)                     AS example_key
FROM   reconciled.rec_reject_log
GROUP  BY source_table, reject_reason
ORDER  BY n_rejected DESC;


-- =====================================================================
--  5. INDEXES ON THE RECONCILED LAYER
--     The leading primary-key column is already indexed; these support the
--     joins performed by load_dw.sql, which filters by year and by country.
-- =====================================================================

CREATE INDEX ix_rec_aq_year     ON reconciled.rec_air_quality (year);
CREATE INDEX ix_rec_aq_country  ON reconciled.rec_air_quality (country_iso3);
CREATE INDEX ix_rec_eco_year    ON reconciled.rec_economy     (year);
CREATE INDEX ix_rec_mort_year   ON reconciled.rec_mortality   (year);
CREATE INDEX ix_rec_mort_cause  ON reconciled.rec_mortality   (cause);


-- =====================================================================
--  6. SEED DATA FOR THE MAPPING TABLES
--     Static reference data, loaded here rather than by the ETL so that the
--     reconciliation rules live in one reviewable place.
-- =====================================================================

INSERT INTO staging.map_eurostat_iso3 (geo_code, country_iso3) VALUES
    ('AD','AND'), ('AL','ALB'), ('AM','ARM'), ('AT','AUT'), ('AZ','AZE'),
    ('BA','BIH'), ('BE','BEL'), ('BG','BGR'), ('BY','BLR'), ('CH','CHE'),
    ('CY','CYP'), ('CZ','CZE'), ('DE','DEU'), ('DK','DNK'), ('EE','EST'),
    ('EL','GRC'), ('ES','ESP'), ('FI','FIN'), ('FR','FRA'), ('GE','GEO'),
    ('HR','HRV'), ('HU','HUN'), ('IE','IRL'), ('IS','ISL'), ('IT','ITA'),
    ('LI','LIE'), ('LT','LTU'), ('LU','LUX'), ('LV','LVA'), ('MC','MCO'),
    ('MD','MDA'), ('ME','MNE'), ('MK','MKD'), ('MT','MLT'), ('NL','NLD'),
    ('NO','NOR'), ('PL','POL'), ('PT','PRT'), ('RO','ROU'), ('RS','SRB'),
    ('RU','RUS'), ('SE','SWE'), ('SI','SVN'), ('SK','SVK'), ('SM','SMR'),
    ('TR','TUR'), ('UA','UKR'), ('UK','GBR'), ('XK','XKX');

INSERT INTO staging.map_eurostat_aggregate (geo_code, label) VALUES
    ('EU27_2020','European Union - 27 countries (from 2020)'),
    ('EU28',     'European Union - 28 countries (2013-2020)'),
    ('EU27_2007','European Union - 27 countries (2007-2013)'),
    ('EU15',     'European Union - 15 countries (1995-2004)'),
    ('EA',       'Euro area'),
    ('EA12',     'Euro area - 12 countries'),
    ('EA19',     'Euro area - 19 countries'),
    ('EA20',     'Euro area - 20 countries'),
    ('EA21',     'Euro area - 21 countries'),
    ('EEA30_2007','European Economic Area (2007-2013)'),
    ('EEA31',    'European Economic Area - 31 countries'),
    ('EFTA',     'European Free Trade Association'),
    ('DE_TOT',   'Germany including former GDR'),
    ('FX',       'France - metropolitan');

INSERT INTO staging.map_iso3_subregion (country_iso3, country_name, sub_region) VALUES
    -- Northern Europe
    ('DNK','Denmark','Northern Europe'),        ('EST','Estonia','Northern Europe'),
    ('FIN','Finland','Northern Europe'),        ('ISL','Iceland','Northern Europe'),
    ('IRL','Ireland','Northern Europe'),        ('LVA','Latvia','Northern Europe'),
    ('LTU','Lithuania','Northern Europe'),      ('NOR','Norway','Northern Europe'),
    ('SWE','Sweden','Northern Europe'),         ('GBR','United Kingdom','Northern Europe'),
    -- Western Europe
    ('AUT','Austria','Western Europe'),         ('BEL','Belgium','Western Europe'),
    ('FRA','France','Western Europe'),          ('DEU','Germany','Western Europe'),
    ('LIE','Liechtenstein','Western Europe'),   ('LUX','Luxembourg','Western Europe'),
    ('MCO','Monaco','Western Europe'),          ('NLD','Netherlands','Western Europe'),
    ('CHE','Switzerland','Western Europe'),
    -- Southern Europe
    ('ALB','Albania','Southern Europe'),        ('AND','Andorra','Southern Europe'),
    ('BIH','Bosnia and Herzegovina','Southern Europe'),
    ('HRV','Croatia','Southern Europe'),        ('GRC','Greece','Southern Europe'),
    ('ITA','Italy','Southern Europe'),          ('MLT','Malta','Southern Europe'),
    ('MNE','Montenegro','Southern Europe'),     ('MKD','North Macedonia','Southern Europe'),
    ('PRT','Portugal','Southern Europe'),       ('SMR','San Marino','Southern Europe'),
    ('SRB','Serbia','Southern Europe'),         ('SVN','Slovenia','Southern Europe'),
    ('ESP','Spain','Southern Europe'),          ('XKX','Kosovo','Southern Europe'),
    ('CYP','Cyprus','Southern Europe'),
    -- Eastern Europe
    ('BLR','Belarus','Eastern Europe'),         ('BGR','Bulgaria','Eastern Europe'),
    ('CZE','Czechia','Eastern Europe'),         ('HUN','Hungary','Eastern Europe'),
    ('POL','Poland','Eastern Europe'),          ('MDA','Moldova','Eastern Europe'),
    ('ROU','Romania','Eastern Europe'),         ('RUS','Russia','Eastern Europe'),
    ('SVK','Slovakia','Eastern Europe'),        ('UKR','Ukraine','Eastern Europe');

-- Only two of these intervals fall inside the 2010-2020 analysis window:
-- Croatia's accession (2013) and the United Kingdom's exit (2020).
INSERT INTO staging.map_eu_membership (country_iso3, accession_year, exit_year) VALUES
    ('BEL',1958,NULL), ('DEU',1958,NULL), ('FRA',1958,NULL), ('ITA',1958,NULL),
    ('LUX',1958,NULL), ('NLD',1958,NULL),
    ('DNK',1973,NULL), ('IRL',1973,NULL), ('GBR',1973,2020),
    ('GRC',1981,NULL), ('ESP',1986,NULL), ('PRT',1986,NULL),
    ('AUT',1995,NULL), ('FIN',1995,NULL), ('SWE',1995,NULL),
    ('CYP',2004,NULL), ('CZE',2004,NULL), ('EST',2004,NULL), ('HUN',2004,NULL),
    ('LTU',2004,NULL), ('LVA',2004,NULL), ('MLT',2004,NULL), ('POL',2004,NULL),
    ('SVK',2004,NULL), ('SVN',2004,NULL),
    ('BGR',2007,NULL), ('ROU',2007,NULL),
    ('HRV',2013,NULL);

INSERT INTO staging.map_cause (cause_label, cause, cause_group) VALUES
    ('All causes',                     'All causes',                      NULL),
    ('Circulatory diseases',           'Circulatory diseases',            'cardiopulmonary'),
    ('Respiratory diseases',           'Respiratory diseases',            'cardiopulmonary'),
    ('Trachea/bronchus/lung neoplasm', 'Trachea/bronchus/lung neoplasm',  'cancer');
