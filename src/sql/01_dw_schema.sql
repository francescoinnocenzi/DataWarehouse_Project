-- =====================================================================
--  Data Warehouse: Air Quality, Mortality and Economy in Europe
--  Logical schema: constellation (3 fact tables) with conformed dimensions.
--  GEOGRAPHY is snowflaked (DIM_CITY -> DIM_COUNTRY -> DIM_REGION);
--  TIME, CAUSE and SEX are kept as flat (star) dimensions.
--  Target DBMS: PostgreSQL
-- =====================================================================

DROP TABLE IF EXISTS air_quality, mortality, economy CASCADE;
DROP TABLE IF EXISTS country_eu_status CASCADE;
DROP TABLE IF EXISTS dim_city, dim_country, dim_region CASCADE;
DROP TABLE IF EXISTS dim_time, dim_cause, dim_sex CASCADE;

-- ---------------------------------------------------------------------
-- 1. DIMENSION TABLES
-- ---------------------------------------------------------------------

-- Secondary dimension table of the snowflaked geographic hierarchy.
-- sub_region is the roll-up level actually used for analysis;
-- who_region is retained for provenance (constant within Europe).
CREATE TABLE dim_region (
    key_region   SERIAL       PRIMARY KEY,
    sub_region   VARCHAR(30)  NOT NULL UNIQUE,
    who_region   VARCHAR(40)  NOT NULL
);

-- Primary dimension table: referenced directly by the country-grain facts.
-- country_iso3 is the canonical key produced by the ELT reconciliation of
-- WHO ISO3 codes and Eurostat 2-letter geo codes (EL->GRC, UK->GBR, ...).
CREATE TABLE dim_country (
    key_country   SERIAL       PRIMARY KEY,
    country_iso3  CHAR(3)      NOT NULL UNIQUE,
    country_name  VARCHAR(80)  NOT NULL,
    key_region    INTEGER      NOT NULL
        REFERENCES dim_region (key_region)
);

-- Primary dimension table: referenced by the city-grain fact.
CREATE TABLE dim_city (
    key_city     SERIAL        PRIMARY KEY,
    city_name    VARCHAR(120)  NOT NULL,
    key_country  INTEGER       NOT NULL
        REFERENCES dim_country (key_country),
    CONSTRAINT uq_city UNIQUE (key_country, city_name)
);

-- Conformed temporal dimension (star: year and decade in one table).
CREATE TABLE dim_time (
    key_time  SERIAL       PRIMARY KEY,
    year      SMALLINT     NOT NULL UNIQUE,
    decade    VARCHAR(6)   NOT NULL,
    CONSTRAINT ck_year CHECK (year BETWEEN 1900 AND 2100)
);

-- Cause of death (star). OPTIONAL dimension.
-- Only the three SPECIFIC, mutually-exclusive causes live here; the
-- 'All causes' total is NOT a member of this dimension. In the fact table
-- an all-causes event has key_cause = NULL (see mortality).
CREATE TABLE dim_cause (
    key_cause    SERIAL       PRIMARY KEY,
    cause        VARCHAR(60)  NOT NULL UNIQUE,
    cause_group  VARCHAR(30)  NOT NULL
);

CREATE TABLE dim_sex (
    key_sex  SERIAL       PRIMARY KEY,
    sex      VARCHAR(10)  NOT NULL UNIQUE
);

-- Cross-dimensional attribute bridge table
-- eu_membership is determined by the COMBINATION of country and year.
-- Keyed by (key_country, key_time); placed after dim_country and dim_time.
CREATE TABLE country_eu_status (
    key_country    INTEGER      NOT NULL REFERENCES dim_country (key_country),
    key_time       INTEGER      NOT NULL REFERENCES dim_time (key_time),
    eu_membership  VARCHAR(20)  NOT NULL,
    CONSTRAINT pk_country_eu_status PRIMARY KEY (key_country, key_time),
    CONSTRAINT ck_eu_membership CHECK (eu_membership IN ('EU Member', 'Non-EU'))
);

-- ---------------------------------------------------------------------
-- 2. FACT TABLES
-- ---------------------------------------------------------------------

-- Grain: one city per year.
-- Pollutant measures are nullable: many city-years report only a subset
-- of the three pollutants (see '*' annotation in the DFM).
CREATE TABLE air_quality (
    key_city      INTEGER       NOT NULL REFERENCES dim_city (key_city),
    key_time      INTEGER       NOT NULL REFERENCES dim_time (key_time),
    avg_pm25      NUMERIC(8,3),
    avg_pm10      NUMERIC(8,3),
    avg_no2       NUMERIC(8,3),
    cov_pm25      NUMERIC(5,2),   -- temporal coverage % of the PM2.5 measure
    cov_pm10      NUMERIC(5,2),   -- temporal coverage % of the PM10 measure
    cov_no2       NUMERIC(5,2),   -- temporal coverage % of the NO2 measure
    CONSTRAINT pk_air_quality PRIMARY KEY (key_city, key_time),
    CONSTRAINT ck_aq_nonneg CHECK (
        (avg_pm25 IS NULL OR avg_pm25 >= 0) AND
        (avg_pm10 IS NULL OR avg_pm10 >= 0) AND
        (avg_no2  IS NULL OR avg_no2  >= 0)
    ),
    CONSTRAINT ck_aq_not_empty CHECK (
        avg_pm25 IS NOT NULL OR avg_pm10 IS NOT NULL OR avg_no2 IS NOT NULL
    )
);

-- Grain: one country per year.
CREATE TABLE economy (
    key_country     INTEGER      NOT NULL REFERENCES dim_country (key_country),
    key_time        INTEGER      NOT NULL REFERENCES dim_time (key_time),
    gdp_per_capita  NUMERIC(12,2),
    population      BIGINT,
    CONSTRAINT pk_economy PRIMARY KEY (key_country, key_time),
    CONSTRAINT ck_eco_nonneg CHECK (
        (gdp_per_capita IS NULL OR gdp_per_capita >= 0) AND
        (population     IS NULL OR population     >= 0)
    ),
    CONSTRAINT ck_eco_not_empty CHECK (
        gdp_per_capita IS NOT NULL OR population IS NOT NULL
    )
);

-- Grain: one country, year, sex and cause of death.
--   key_cause valued  -> event for one of the three specific causes
--   key_cause NULL     -> the 'All causes' total (identified by the other
--                         three dimensions only).
-- Because key_cause is nullable it cannot sit in a natural primary key, and
-- NULLs are all distinct under a plain UNIQUE. We therefore use a surrogate
-- key and enforce the grain with two PARTIAL unique indexes (below).
-- sdr is an age-standardised RATE per 100 000: aggregate with AVG, never SUM.
CREATE TABLE mortality (
    fact_id      BIGSERIAL     PRIMARY KEY,
    key_country  INTEGER       NOT NULL REFERENCES dim_country (key_country),
    key_time     INTEGER       NOT NULL REFERENCES dim_time (key_time),
    key_sex      INTEGER       NOT NULL REFERENCES dim_sex (key_sex),
    key_cause    INTEGER                REFERENCES dim_cause (key_cause),
    sdr          NUMERIC(10,3),
    CONSTRAINT ck_sdr_nonneg CHECK (sdr IS NULL OR sdr >= 0)
);

-- Grain enforcement for the OPTIONAL cause dimension:
--   one row per (country, year, sex, cause) when a specific cause is given ...
CREATE UNIQUE INDEX uq_mortality_cause
    ON mortality (key_country, key_time, key_sex, key_cause)
    WHERE key_cause IS NOT NULL;
--   ... and exactly one all-causes row per (country, year, sex).
CREATE UNIQUE INDEX uq_mortality_total
    ON mortality (key_country, key_time, key_sex)
    WHERE key_cause IS NULL;

-- ---------------------------------------------------------------------
-- 3. INDEXES
--    The leading PK column is already indexed by the primary key, so we
--    add indexes on the remaining foreign keys used as join / filter paths.
-- ---------------------------------------------------------------------

CREATE INDEX ix_city_country      ON dim_city    (key_country);
CREATE INDEX ix_country_region    ON dim_country (key_region);
CREATE INDEX ix_ceus_membership   ON country_eu_status (eu_membership);

CREATE INDEX ix_aq_time           ON air_quality (key_time);
CREATE INDEX ix_eco_time          ON economy     (key_time);
CREATE INDEX ix_mort_time         ON mortality   (key_time);
CREATE INDEX ix_mort_cause        ON mortality   (key_cause);
CREATE INDEX ix_mort_sex          ON mortality   (key_sex);

-- ---------------------------------------------------------------------
-- 4. SEED DATA FOR THE SMALL STATIC DIMENSIONS
--    (the remaining dimensions are populated by the ELT)
-- ---------------------------------------------------------------------

INSERT INTO dim_sex (sex) VALUES
    ('ALL'), ('FEMALE'), ('MALE');

-- Only the three SPECIFIC causes are dimension members.
-- 'All causes' is loaded by the ELT as fact rows with key_cause = NULL.
INSERT INTO dim_cause (cause, cause_group) VALUES
    ('Circulatory diseases',  'cardiopulmonary'),
    ('Respiratory diseases',  'cardiopulmonary'),
    ('Trachea/bronchus/lung neoplasm', 'cancer');

INSERT INTO dim_region (sub_region, who_region) VALUES
    ('Northern Europe', 'European Region'),
    ('Southern Europe', 'European Region'),
    ('Eastern Europe',  'European Region'),
    ('Western Europe',  'European Region');
