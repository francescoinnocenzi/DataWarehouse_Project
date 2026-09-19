import os
import pandas as pd
import psycopg2
import matplotlib.pyplot as plt
import seaborn as sns

# Database configuration from run_reconciled.py
DB = dict(
    host=os.environ.get("PGHOST", "localhost"),
    port=int(os.environ.get("PGPORT", 5432)),
    dbname=os.environ.get("PGDATABASE", "DataWarehouse"),
    user=os.environ.get("PGUSER", "postgres"),
    password=os.environ.get("PGPASSWORD", "postgres"),
)

def get_connection():
    return psycopg2.connect(**DB)

def plot_q1_rollup(conn, output_dir):
    """Generates the chart for Query 1: Roll-up (PM2.5 Trend by Sub-Region)"""
    query = """
    SELECT r.sub_region, t.year, ROUND(AVG(aq.avg_pm25), 2) AS pm25
    FROM   air_quality aq
    JOIN   dim_city    ci ON ci.key_city    = aq.key_city
    JOIN   dim_country co ON co.key_country = ci.key_country
    JOIN   dim_region  r  ON r.key_region   = co.key_region
    JOIN   dim_time    t  ON t.key_time     = aq.key_time
    GROUP  BY r.sub_region, t.year
    ORDER  BY r.sub_region, t.year;
    """
    df = pd.read_sql_query(query, conn)
    if df.empty: 
        print("Q1: No data retrieved.")
        return
    
    plt.figure(figsize=(10, 6))
    sns.lineplot(data=df, x='year', y='pm25', hue='sub_region', marker='o')
    plt.title('Q1: PM2.5 Trend by Sub-Region (Roll-up)')
    plt.ylabel('PM2.5 (μg/m³)')
    plt.xlabel('Year')
    plt.grid(True, linestyle='--', alpha=0.7)
    plt.legend(title='Sub-Region', bbox_to_anchor=(1.05, 1), loc='upper left')
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'q1_rollup.png'))
    plt.close()

def plot_q6_drill_across(conn, output_dir):
    """Generates the chart for Query 6: Drill-Across (PM2.5 vs GDP per Capita)"""
    query = """
    WITH aq_country AS (
        SELECT ci.key_country, aq.key_time, AVG(aq.avg_pm25) AS pm25
        FROM air_quality aq JOIN dim_city ci ON ci.key_city = aq.key_city
        GROUP BY ci.key_country, aq.key_time
    ),
    resp AS (
        SELECT m.key_country, m.key_time, m.sdr
        FROM mortality m JOIN dim_cause ca ON ca.key_cause = m.key_cause
        JOIN dim_sex s ON s.key_sex = m.key_sex
        WHERE ca.cause = 'Respiratory diseases' AND s.sex = 'ALL'
    )
    SELECT r.sub_region, t.year,
           ROUND(AVG(a.pm25)::numeric, 2) AS pm25,
           ROUND(AVG(re.sdr)::numeric, 2) AS respiratory_sdr,
           ROUND(AVG(e.gdp_per_capita)::numeric, 0) AS gdp_per_capita
    FROM aq_country a
    JOIN dim_country co ON co.key_country = a.key_country
    JOIN dim_region r ON r.key_region = co.key_region
    JOIN dim_time t ON t.key_time = a.key_time
    LEFT JOIN resp re ON re.key_country = a.key_country AND re.key_time = a.key_time
    LEFT JOIN economy e ON e.key_country = a.key_country AND e.key_time = a.key_time
    GROUP BY r.sub_region, t.year
    HAVING COUNT(DISTINCT a.key_country) >= 3
    """
    df = pd.read_sql_query(query, conn)
    if df.empty: 
        print("Q6: No data retrieved.")
        return
        
    df_2019 = df[df['year'] == 2019]
    if df_2019.empty: 
        print("Q6: No data available for 2019.")
        return

    # Use a grouped bar chart with a secondary y-axis for GDP
    fig, ax1 = plt.subplots(figsize=(10, 6))
    
    # Position of bars
    import numpy as np
    x = np.arange(len(df_2019['sub_region']))
    width = 0.35
    
    ax1.bar(x - width/2, df_2019['pm25'], width, label='PM2.5', color='skyblue')
    ax1.set_ylabel('PM2.5 (μg/m³)', color='darkblue')
    ax1.set_xlabel('Sub-Region')
    ax1.tick_params(axis='y', labelcolor='darkblue')
    ax1.set_xticks(x)
    ax1.set_xticklabels(df_2019['sub_region'])
    
    # Second y-axis for GDP
    ax2 = ax1.twinx()
    ax2.bar(x + width/2, df_2019['gdp_per_capita'], width, label='GDP per Capita', color='salmon')
    ax2.set_ylabel('GDP per Capita (€)', color='darkred')
    ax2.tick_params(axis='y', labelcolor='darkred')
    
    plt.title('Q6: PM2.5 vs GDP per Capita by Sub-Region (2019)')
    
    # Combined legend inside the plot
    lines_1, labels_1 = ax1.get_legend_handles_labels()
    lines_2, labels_2 = ax2.get_legend_handles_labels()
    ax1.legend(lines_1 + lines_2, labels_1 + labels_2, loc='upper center', ncol=2)
    
    # Ensure there is enough space at the top for the legend
    ax1.set_ylim(0, df_2019['pm25'].max() * 1.25)
    ax2.set_ylim(0, df_2019['gdp_per_capita'].max() * 1.25)
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'q6_drill_across.png'))
    plt.close()

def plot_q8_trend(conn, output_dir):
    """Generates the chart for Query 8: Temporal Trend (PM2.5 Change)"""
    query = """
    WITH by_region_year AS (
        SELECT r.sub_region, t.year, AVG(aq.avg_pm25) AS pm25
        FROM air_quality aq JOIN dim_city ci ON ci.key_city = aq.key_city
        JOIN dim_country co ON co.key_country = ci.key_country
        JOIN dim_region r ON r.key_region = co.key_region
        JOIN dim_time t ON t.key_time = aq.key_time
        WHERE t.year IN (2013, 2019)
        GROUP BY r.sub_region, t.year
    )
    SELECT sub_region,
           ROUND((MAX(pm25) FILTER (WHERE year = 2019) - MAX(pm25) FILTER (WHERE year = 2013))::numeric, 2) AS change
    FROM by_region_year
    GROUP BY sub_region
    ORDER BY change;
    """
    df = pd.read_sql_query(query, conn)
    if df.empty: 
        print("Q8: No data retrieved.")
        return

    plt.figure(figsize=(10, 6))
    sns.barplot(data=df, x='change', y='sub_region', hue='sub_region', palette='coolwarm', legend=False)
    plt.title('Q8: PM2.5 Change (2013 - 2019)')
    plt.xlabel('PM2.5 Change (μg/m³)')
    plt.ylabel('Sub-Region')
    plt.axvline(x=0, color='black', linestyle='-')
    plt.grid(True, axis='x', linestyle='--', alpha=0.7)
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'q8_temporal_trend.png'))
    plt.close()

def main():
    # Creates the 'charts' directory inside src/
    output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'charts')
    os.makedirs(output_dir, exist_ok=True)
    
    print(f"Connecting to database {DB['dbname']} on {DB['host']}...")
    try:
        conn = get_connection()
        print("Connected. Generating charts...")
        
        plot_q1_rollup(conn, output_dir)
        print(" -> Q1 chart generated.")
        
        plot_q6_drill_across(conn, output_dir)
        print(" -> Q6 chart generated.")
        
        plot_q8_trend(conn, output_dir)
        print(" -> Q8 chart generated.")
        
        conn.close()
        print(f"\\nAll charts have been successfully saved to: {output_dir}")
    except Exception as e:
        print(f"Error during execution: {e}")

if __name__ == "__main__":
    main()
