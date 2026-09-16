#!/usr/bin/env python3
"""
Orchestrator for the Reconciled Layer 3-Tier ETL Pipeline.

This script:
1. Executes `sql/dw_schema.sql` to ensure Data Warehouse tables exist.
2. Executes `reconciled_layer/reconciled_schema.sql` (DDL & Mapping seed data).
3. Loads raw source files (Excel, TSV, CSV) into PostgreSQL `staging` as TEXT / NULL.
4. Executes `reconciled_layer/etl_reconciled.sql` (Semantic transformations -> `reconciled`).
5. Executes `reconciled_layer/load_dw.sql` (Populates Star Schema -> `public`).

Usage:
    python reconciled_layer/run_reconciled.py
"""

import os
import re
import sys
import pandas as pd
import psycopg2
import psycopg2.extras as extras

DATA_DIR = os.environ.get("DW_DATA_DIR", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "datasets"))

DB = dict(
    host=os.environ.get("PGHOST", "localhost"),
    port=int(os.environ.get("PGPORT", 5432)),
    dbname=os.environ.get("PGDATABASE", "DataWarehouse"),
    user=os.environ.get("PGUSER", "postgres"),
    password=os.environ.get("PGPASSWORD", "postgres"),
)

F_AIR  = "who_aap_2021_v9_11august2022.xlsx"
F_GDP  = "estat_nama_10_pc.tsv"
F_POP  = "estat_demo_pjan.tsv"
F_MORT = {
    "HFAMDB_113_EN_all_causes.csv":  "All causes",
    "HFAMDB_275_EN_circ.csv":        "Circulatory diseases",
    "HFAMDB_307_EN_resp.csv":        "Respiratory diseases",
    "HFAMDB_618_EN_neoplasma.csv":   "Trachea/bronchus/lung neoplasm",
}

WHO_COLS = {
    "WHO Region":                             "who_region",
    "ISO3":                                   "iso3",
    "WHO Country Name":                       "who_country_name",
    "City or Locality":                        "city_or_locality",
    "Measurement Year":                        "measurement_year",
    "PM2.5 (\u03bcg/m3)":                      "pm25",
    "PM10 (\u03bcg/m3)":                       "pm10",
    "NO2 (\u03bcg/m3)":                        "no2",
    "PM25 temporal coverage (%)":              "cov_pm25",
    "PM10 temporal coverage (%)":              "cov_pm10",
    "NO2 temporal coverage (%)":               "cov_no2",
    "Reference":                               "reference",
    "Number and type of monitoring stations":  "monitoring_stations",
    "Version of the database":                 "db_version",
    "Status":                                  "status",
}


def cell(row, name):
    """Safely extract cell value without converting NaN/NA to string 'nan'."""
    v = getattr(row, name, None)
    if v is None or pd.isna(v):
        return None
    return str(v).strip()


def run_sql_file(conn, file_path):
    print(f"Executing {file_path}...")
    with open(file_path, "r", encoding="utf-8") as f:
        sql = f.read()
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()


def load_staging(conn):
    print("Ingesting raw datasets into staging schema...")
    cur = conn.cursor()

    # 1. WHO Air Quality
    path_air = os.path.join(DATA_DIR, F_AIR)
    if os.path.exists(path_air):
        df_air = pd.read_excel(path_air, sheet_name="AAP_2022_city_v9", dtype=str)
        missing = [c for c in WHO_COLS if c not in df_air.columns]
        if missing:
            raise RuntimeError(f"WHO sheet is missing expected columns: {missing}")
        df_air = df_air[list(WHO_COLS)].rename(columns=WHO_COLS)
        df_air = df_air.astype(object).where(pd.notna(df_air), None)
        
        cur.execute("TRUNCATE staging.stg_who_aap;")
        tuples = [tuple(x) for x in df_air.to_numpy()]
        extras.execute_values(cur, """
            INSERT INTO staging.stg_who_aap
            (who_region, iso3, who_country_name, city_or_locality, measurement_year,
             pm25, pm10, no2, cov_pm25, cov_pm10, cov_no2, reference, monitoring_stations, db_version, status)
            VALUES %s
        """, tuples)
        print(f"  stg_who_aap: {len(tuples)} rows ingested.")

    # 2. Eurostat GDP TSV
    path_gdp = os.path.join(DATA_DIR, F_GDP)
    if os.path.exists(path_gdp):
        df_gdp = pd.read_csv(path_gdp, sep="\t", dtype=str)
        first_col = df_gdp.columns[0]
        year_cols = [c.strip() for c in df_gdp.columns[1:] if c.strip().isdigit()]
        raw_year_cols = [c for c in df_gdp.columns[1:] if c.strip().isdigit()]
        df_gdp = df_gdp[[first_col] + raw_year_cols]
        df_gdp.columns = ["dims"] + year_cols
        df_gdp = df_gdp.astype(object).where(pd.notna(df_gdp), None)

        cur.execute("TRUNCATE staging.stg_eurostat_gdp;")
        tuples = [tuple(x) for x in df_gdp.to_numpy()]
        cols_sql = ", ".join(['dims'] + [f'"{y}"' for y in year_cols])
        extras.execute_values(cur, f"""
            INSERT INTO staging.stg_eurostat_gdp ({cols_sql})
            VALUES %s
        """, tuples)
        print(f"  stg_eurostat_gdp: {len(tuples)} rows ingested across {len(year_cols)} year columns ({year_cols[0]}-{year_cols[-1]}).")

    # 3. Eurostat POP TSV
    path_pop = os.path.join(DATA_DIR, F_POP)
    if os.path.exists(path_pop):
        df_pop = pd.read_csv(path_pop, sep="\t", dtype=str)
        first_col = df_pop.columns[0]
        year_cols = [c.strip() for c in df_pop.columns[1:] if c.strip().isdigit()]
        raw_year_cols = [c for c in df_pop.columns[1:] if c.strip().isdigit()]
        df_pop = df_pop[[first_col] + raw_year_cols]
        df_pop.columns = ["dims"] + year_cols
        df_pop = df_pop.astype(object).where(pd.notna(df_pop), None)

        cur.execute("TRUNCATE staging.stg_eurostat_pop;")
        tuples = [tuple(x) for x in df_pop.to_numpy()]
        cols_sql = ", ".join(['dims'] + [f'"{y}"' for y in year_cols])
        extras.execute_values(cur, f"""
            INSERT INTO staging.stg_eurostat_pop ({cols_sql})
            VALUES %s
        """, tuples)
        print(f"  stg_eurostat_pop: {len(tuples)} rows ingested across {len(year_cols)} year columns ({year_cols[0]}-{year_cols[-1]}).")

    # 4. HFAMDB Mortality CSVs
    mort_rows = []
    for fname, cause_label in F_MORT.items():
        mpath = os.path.join(DATA_DIR, fname)
        if not os.path.exists(mpath):
            continue
        with open(mpath, encoding="utf-8-sig") as fh:
            header_idx = 0
            for i, line in enumerate(fh):
                if line.startswith('"COUNTRY"'):
                    header_idx = i
                    break
            else:
                raise RuntimeError(f"header row not found in {fname}")

        mdf = pd.read_csv(mpath, skiprows=header_idx, dtype=str)
        for row in mdf.itertuples(index=False):
            mort_rows.append((
                cell(row, 'COUNTRY'),
                cell(row, 'COUNTRY_GRP'),
                cell(row, 'AGE_GRP_LIST'),
                cell(row, 'SEX'),
                cell(row, 'SUBNATIONAL_MDB'),
                cell(row, 'YEAR'),
                cell(row, 'VALUE'),
                cause_label,
                fname
            ))

    cur.execute("TRUNCATE staging.stg_hfamdb_mortality;")
    extras.execute_values(cur, """
        INSERT INTO staging.stg_hfamdb_mortality
        (country, country_grp, age_grp_list, sex, subnational_mdb, year, value, cause_label, source_file)
        VALUES %s
    """, mort_rows)
    print(f"  stg_hfamdb_mortality: {len(mort_rows)} rows ingested.")

    conn.commit()
    cur.close()


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    
    dw_sql       = os.path.join(base_dir, "sql", "01_dw_schema.sql")
    schema_sql   = os.path.join(base_dir, "sql", "02_reconciled_schema.sql")
    etl_sql      = os.path.join(base_dir, "sql", "03_etl_reconciled.sql")
    load_sql     = os.path.join(base_dir, "sql", "04_load_dw.sql")

    with psycopg2.connect(**DB) as conn:
        run_sql_file(conn, dw_sql)
        run_sql_file(conn, schema_sql)
        load_staging(conn)
        run_sql_file(conn, etl_sql)
        run_sql_file(conn, load_sql)

    print("\n[SUCCESS] Reconciled Layer 3-Tier ETL execution complete!")


if __name__ == "__main__":
    main()
