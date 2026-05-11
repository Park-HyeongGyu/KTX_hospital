library(DBI)
library(duckdb)
library(glue)
library(knitr)

source("config.r")

con <- dbConnect(duckdb(), "analysis_db.duckdb")

############################################################
#### Path Configuration ####################################
############################################################
path_clean_hospital <- file.path(CLEAN, "clean_hospital_by_type.parquet")
path_clean_doctor <- file.path(CLEAN, "clean_doctor_by_level.parquet")
path_clean_shock_10 <- file.path(CLEAN, "clean_shock_10.parquet")
path_clean_shock_20 <- file.path(CLEAN, "clean_shock_20.parquet")
path_clean_shock_30 <- file.path(CLEAN, "clean_shock_30.parquet")
path_clean_shock_40 <- file.path(CLEAN, "clean_shock_40.parquet")
path_clean_shock_50 <- file.path(CLEAN, "clean_shock_50.parquet")
OUTPUT_FOLDER <- file.path(ROOT, "output", "2026-0425_report")
dir.create(OUTPUT_FOLDER, recursive = TRUE, showWarnings = FALSE)

############################################################
#### Section 1 #############################################
#### Summary Statistics ####################################
############################################################

#### 기본 clean_shock
path_clean_shock <- path_clean_shock_30

#### 병원 base
dbExecute(con, glue("
    CREATE OR REPLACE TABLE base_hospital AS
    WITH shock_2007 AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{path_clean_shock}')
        WHERE shock_year <= 2007
    )
    SELECT
        h.*,
        s.* EXCLUDE (year, region_sido, region_sigungu)
    FROM read_parquet('{path_clean_hospital}') AS h
    LEFT JOIN read_parquet('{path_clean_shock}') AS s
        USING (year, region_sido, region_sigungu)
    LEFT JOIN shock_2007 AS x
        USING (region_sido, region_sigungu)
    WHERE
        h.region_sido NOT IN ('서울', '경기', '인천', '제주') AND
        x.region_sido IS NULL AND
        h.year >= 2008
"))

#### 의사 base
dbExecute(con, glue("
    CREATE OR REPLACE TABLE base_doctor AS
    WITH shock_2007 AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{path_clean_shock}')
        WHERE shock_year <= 2007
    )
    SELECT
        d.*,
        s.* EXCLUDE (year, region_sido, region_sigungu)
    FROM read_parquet('{path_clean_doctor}') AS d
    LEFT JOIN read_parquet('{path_clean_shock}') AS s
        USING (year, region_sido, region_sigungu)
    LEFT JOIN shock_2007 AS x
        USING (region_sido, region_sigungu)
    WHERE
        d.region_sido NOT IN ('서울', '경기', '인천', '제주') AND
        x.region_sido IS NULL AND
        d.year >= 2008
"))

#### 상급종합병원
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_hospital_tertiary AS
    WITH eligible_regions AS (
        SELECT
            region_sido,
            region_sigungu
        FROM base_hospital
        WHERE hospital_type = '상급종합병원'
        GROUP BY region_sido, region_sigungu
        HAVING MAX(COALESCE(hospital_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base_hospital AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
    WHERE b.hospital_type = '상급종합병원'
"))

#### 종합병원
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_hospital_general AS
    WITH eligible_regions AS (
        SELECT
            region_sido,
            region_sigungu
        FROM base_hospital
        WHERE hospital_type = '종합병원'
        GROUP BY region_sido, region_sigungu
        HAVING MAX(COALESCE(hospital_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base_hospital AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
    WHERE b.hospital_type = '종합병원'
"))

#### 병원
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_hospital_secondary AS
    WITH eligible_regions AS (
        SELECT
            region_sido,
            region_sigungu
        FROM base_hospital
        WHERE hospital_type = '병원'
        GROUP BY region_sido, region_sigungu
        HAVING MAX(COALESCE(hospital_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base_hospital AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
    WHERE b.hospital_type = '병원'
"))

#### 의원
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_hospital_clinic AS
    WITH eligible_regions AS (
        SELECT
            region_sido,
            region_sigungu
        FROM base_hospital
        WHERE hospital_type = '의원'
        GROUP BY region_sido, region_sigungu
        HAVING MAX(COALESCE(hospital_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base_hospital AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
    WHERE b.hospital_type = '의원'
"))

#### total
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_doctor_total AS
    WITH eligible_regions AS (
        SELECT
            region_sido,
            region_sigungu
        FROM base_doctor
        WHERE doctor_level = 'total'
        GROUP BY region_sido, region_sigungu
        HAVING MAX(COALESCE(doctor_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base_doctor AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
    WHERE b.doctor_level = 'total'
"))

#### 전문의
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_doctor_specialist AS
    WITH eligible_regions AS (
        SELECT
            region_sido,
            region_sigungu
        FROM base_doctor
        WHERE doctor_level = '전문의'
        GROUP BY region_sido, region_sigungu
        HAVING MAX(COALESCE(doctor_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base_doctor AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
    WHERE b.doctor_level = '전문의'
"))

#### 일반의
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_doctor_general AS
    WITH eligible_regions AS (
        SELECT
            region_sido,
            region_sigungu
        FROM base_doctor
        WHERE doctor_level = '일반의'
        GROUP BY region_sido, region_sigungu
        HAVING MAX(COALESCE(doctor_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base_doctor AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
    WHERE b.doctor_level = '일반의'
"))

#### 인턴
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_doctor_intern AS
    WITH eligible_regions AS (
        SELECT
            region_sido,
            region_sigungu
        FROM base_doctor
        WHERE doctor_level = '인턴'
        GROUP BY region_sido, region_sigungu
        HAVING MAX(COALESCE(doctor_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base_doctor AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
    WHERE b.doctor_level = '인턴'
"))

#### 레지던트
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_doctor_resident AS
    WITH eligible_regions AS (
        SELECT
            region_sido,
            region_sigungu
        FROM base_doctor
        WHERE doctor_level = '레지던트'
        GROUP BY region_sido, region_sigungu
        HAVING MAX(COALESCE(doctor_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base_doctor AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
    WHERE b.doctor_level = '레지던트'
"))

#### summary statistics
dbExecute(con, glue("
    CREATE OR REPLACE TABLE summary_statistics AS
    SELECT
        '상급종합병원' AS variable,
        COUNT(DISTINCT region_sido || ' ' || region_sigungu) AS regions,
        COUNT(*) AS observations,
        CAST(MIN(year) AS VARCHAR) || '-' || CAST(MAX(year) AS VARCHAR) AS period
    FROM summary_hospital_tertiary
    UNION ALL
    SELECT
        '종합병원' AS variable,
        COUNT(DISTINCT region_sido || ' ' || region_sigungu) AS regions,
        COUNT(*) AS observations,
        CAST(MIN(year) AS VARCHAR) || '-' || CAST(MAX(year) AS VARCHAR) AS period
    FROM summary_hospital_general
    UNION ALL
    SELECT
        '병원' AS variable,
        COUNT(DISTINCT region_sido || ' ' || region_sigungu) AS regions,
        COUNT(*) AS observations,
        CAST(MIN(year) AS VARCHAR) || '-' || CAST(MAX(year) AS VARCHAR) AS period
    FROM summary_hospital_secondary
    UNION ALL
    SELECT
        '의원' AS variable,
        COUNT(DISTINCT region_sido || ' ' || region_sigungu) AS regions,
        COUNT(*) AS observations,
        CAST(MIN(year) AS VARCHAR) || '-' || CAST(MAX(year) AS VARCHAR) AS period
    FROM summary_hospital_clinic
    UNION ALL
    SELECT
        'total_doctors' AS variable,
        COUNT(DISTINCT region_sido || ' ' || region_sigungu) AS regions,
        COUNT(*) AS observations,
        CAST(MIN(year) AS VARCHAR) || '-' || CAST(MAX(year) AS VARCHAR) AS period
    FROM summary_doctor_total
    UNION ALL
    SELECT
        '전문의' AS variable,
        COUNT(DISTINCT region_sido || ' ' || region_sigungu) AS regions,
        COUNT(*) AS observations,
        CAST(MIN(year) AS VARCHAR) || '-' || CAST(MAX(year) AS VARCHAR) AS period
    FROM summary_doctor_specialist
    UNION ALL
    SELECT
        '일반의' AS variable,
        COUNT(DISTINCT region_sido || ' ' || region_sigungu) AS regions,
        COUNT(*) AS observations,
        CAST(MIN(year) AS VARCHAR) || '-' || CAST(MAX(year) AS VARCHAR) AS period
    FROM summary_doctor_general
    UNION ALL
    SELECT
        '인턴' AS variable,
        COUNT(DISTINCT region_sido || ' ' || region_sigungu) AS regions,
        COUNT(*) AS observations,
        CAST(MIN(year) AS VARCHAR) || '-' || CAST(MAX(year) AS VARCHAR) AS period
    FROM summary_doctor_intern
    UNION ALL
    SELECT
        '레지던트' AS variable,
        COUNT(DISTINCT region_sido || ' ' || region_sigungu) AS regions,
        COUNT(*) AS observations,
        CAST(MIN(year) AS VARCHAR) || '-' || CAST(MAX(year) AS VARCHAR) AS period
    FROM summary_doctor_resident
"))

#### print
summary_statistics <- dbReadTable(con, "summary_statistics")
print(summary_statistics, row.names = FALSE)

#### latex
summary_statistics_tex <- kable(
    summary_statistics,
    format = "latex",
    booktabs = TRUE,
    col.names = c("Variable", "Regions", "Observations", "Period"),
    align = c("l", "r", "r", "l"),
    linesep = ""
)
summary_statistics_tex <- paste(summary_statistics_tex, collapse = "\n")
summary_statistics_tex <- sub("^\\s+", "", summary_statistics_tex)

writeLines(
    summary_statistics_tex,
    file.path(OUTPUT_FOLDER, "summary_statistics.tex")
)


############################################################
#### Section 2 #############################################
#### distance cutoff cannot be sufficient statistics #######
############################################################

#### cutoff region status
dbExecute(con, glue("
    CREATE OR REPLACE TABLE cutoff_region_status AS
    WITH sample_regions AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{path_clean_hospital}')
        WHERE
            region_sido NOT IN ('서울', '경기', '인천', '제주') AND
            year >= 2008
    ),
    shock_regions AS (
        SELECT DISTINCT
            10 AS cutoff_km,
            region_sido,
            region_sigungu,
            shock_station,
            line,
            distance_to_station,
            ktx_date,
            shock_year
        FROM read_parquet('{path_clean_shock_10}')
        WHERE shock_year IS NOT NULL
        UNION ALL
        SELECT DISTINCT
            20 AS cutoff_km,
            region_sido,
            region_sigungu,
            shock_station,
            line,
            distance_to_station,
            ktx_date,
            shock_year
        FROM read_parquet('{path_clean_shock_20}')
        WHERE shock_year IS NOT NULL
        UNION ALL
        SELECT DISTINCT
            30 AS cutoff_km,
            region_sido,
            region_sigungu,
            shock_station,
            line,
            distance_to_station,
            ktx_date,
            shock_year
        FROM read_parquet('{path_clean_shock_30}')
        WHERE shock_year IS NOT NULL
        UNION ALL
        SELECT DISTINCT
            40 AS cutoff_km,
            region_sido,
            region_sigungu,
            shock_station,
            line,
            distance_to_station,
            ktx_date,
            shock_year
        FROM read_parquet('{path_clean_shock_40}')
        WHERE shock_year IS NOT NULL
        UNION ALL
        SELECT DISTINCT
            50 AS cutoff_km,
            region_sido,
            region_sigungu,
            shock_station,
            line,
            distance_to_station,
            ktx_date,
            shock_year
        FROM read_parquet('{path_clean_shock_50}')
        WHERE shock_year IS NOT NULL
    ),
    cutoffs AS (
        SELECT 10 AS cutoff_km
        UNION ALL SELECT 20
        UNION ALL SELECT 30
        UNION ALL SELECT 40
        UNION ALL SELECT 50
    )
    SELECT
        c.cutoff_km,
        r.region_sido,
        r.region_sigungu,
        s.shock_station,
        s.line,
        s.distance_to_station,
        s.ktx_date,
        s.shock_year,
        CASE
            WHEN s.shock_year <= 2007 THEN 1
            ELSE 0
        END AS already_treated,
        CASE
            WHEN s.shock_year > 2007 THEN 1
            ELSE 0
        END AS treated
    FROM cutoffs AS c
    CROSS JOIN sample_regions AS r
    LEFT JOIN shock_regions AS s
        ON c.cutoff_km = s.cutoff_km
       AND r.region_sido = s.region_sido
       AND r.region_sigungu = s.region_sigungu
"))

#### cutoff sensitivity
dbExecute(con, glue("
    CREATE OR REPLACE TABLE cutoff_sensitivity AS
    WITH status_with_previous AS (
        SELECT
            c.*,
            COALESCE(p.treated, 0) AS previously_treated
        FROM cutoff_region_status AS c
        LEFT JOIN cutoff_region_status AS p
            ON p.cutoff_km = c.cutoff_km - 10
           AND p.region_sido = c.region_sido
           AND p.region_sigungu = c.region_sigungu
    ),
    aggregate_stats AS (
        SELECT
            cutoff_km,
            COUNT(*) FILTER (WHERE already_treated = 0) AS analysis_regions,
            COUNT(*) FILTER (WHERE treated = 1) AS treated_regions,
            COUNT(*) FILTER (WHERE already_treated = 0 AND treated = 0) AS control_regions,
            COUNT(*) FILTER (WHERE already_treated = 1) AS already_treated_regions,
            COUNT(*) FILTER (WHERE treated = 1 AND previously_treated = 0) AS newly_included_regions
        FROM status_with_previous
        GROUP BY cutoff_km
    ),
    shock_year_counts AS (
        SELECT
            cutoff_km,
            shock_year,
            COUNT(*) AS regions
        FROM cutoff_region_status
        WHERE treated = 1
        GROUP BY cutoff_km, shock_year
    ),
    shock_year_strings AS (
        SELECT
            cutoff_km,
            string_agg(
                CAST(shock_year AS VARCHAR) || ': ' || CAST(regions AS VARCHAR),
                '; '
                ORDER BY shock_year
            ) AS treated_by_shock_year
        FROM shock_year_counts
        GROUP BY cutoff_km
    )
    SELECT
        a.cutoff_km,
        a.analysis_regions,
        a.treated_regions,
        a.control_regions,
        a.already_treated_regions,
        a.newly_included_regions
        --y.treated_by_shock_year
    FROM aggregate_stats AS a
    LEFT JOIN shock_year_strings AS y
        USING (cutoff_km)
    ORDER BY a.cutoff_km
"))

#### newly included regions
dbExecute(con, glue("
    CREATE OR REPLACE TABLE newly_included_regions AS
    WITH status_with_previous AS (
        SELECT
            c.*,
            COALESCE(p.treated, 0) AS previously_treated
        FROM cutoff_region_status AS c
        LEFT JOIN cutoff_region_status AS p
            ON p.cutoff_km = c.cutoff_km - 10
           AND p.region_sido = c.region_sido
           AND p.region_sigungu = c.region_sigungu
    ),
    baseline_hospital AS (
        SELECT
            region_sido,
            region_sigungu,
            SUM(hospital_no) AS baseline_hospital_no
        FROM read_parquet('{path_clean_hospital}')
        WHERE year = 2008
        GROUP BY region_sido, region_sigungu
    ),
    baseline_doctor AS (
        SELECT
            region_sido,
            region_sigungu,
            doctor_no AS baseline_doctor_no
        FROM read_parquet('{path_clean_doctor}')
        WHERE
            year = 2008 AND
            doctor_level = 'total'
    )
    SELECT
        CASE
            WHEN s.cutoff_km = 10 THEN '0-10km'
            ELSE CAST(s.cutoff_km - 10 AS VARCHAR) || '-' || CAST(s.cutoff_km AS VARCHAR) || 'km'
        END AS cutoff_band,
        s.region_sido || ' ' || s.region_sigungu AS region,
        ROUND(s.distance_to_station, 1) AS distance_km,
        s.shock_station,
        s.line,
        s.shock_year,
        h.baseline_hospital_no,
        d.baseline_doctor_no
    FROM status_with_previous AS s
    LEFT JOIN baseline_hospital AS h
        USING (region_sido, region_sigungu)
    LEFT JOIN baseline_doctor AS d
        USING (region_sido, region_sigungu)
    WHERE
        s.treated = 1 AND
        s.previously_treated = 0
    ORDER BY s.cutoff_km, s.region_sido, s.region_sigungu
"))

#### cutoff sensitivity output
cutoff_sensitivity <- dbReadTable(con, "cutoff_sensitivity")
print(cutoff_sensitivity, row.names = FALSE)
write.csv(
    cutoff_sensitivity,
    file.path(OUTPUT_FOLDER, "cutoff_sensitivity.csv"),
    row.names = FALSE
)

cutoff_sensitivity_tex <- kable(
    cutoff_sensitivity,
    format = "latex",
    booktabs = TRUE,
    col.names = c(
        "Cutoff",
        "Analysis regions",
        "Treated",
        "Control",
        "Already treated",
        "Newly included"
    ),
    align = c("r", "r", "r", "r", "r", "r", "l"),
    linesep = ""
)
cutoff_sensitivity_tex <- paste(cutoff_sensitivity_tex, collapse = "\n")
cutoff_sensitivity_tex <- sub("^\\s+", "", cutoff_sensitivity_tex)

writeLines(
    cutoff_sensitivity_tex,
    file.path(OUTPUT_FOLDER, "cutoff_sensitivity.tex")
)

#### newly included regions output
newly_included_regions <- dbReadTable(con, "newly_included_regions")
print(newly_included_regions, row.names = FALSE)
write.csv(
    newly_included_regions,
    file.path(OUTPUT_FOLDER, "newly_included_regions.csv"),
    row.names = FALSE
)

newly_included_regions_tex <- kable(
    newly_included_regions,
    format = "latex",
    booktabs = TRUE,
    col.names = c(
        "Cutoff band",
        "Region",
        "Distance",
        "Station",
        "Line",
        "Shock year",
        "Hospitals in 2008",
        "Doctors in 2008"
    ),
    align = c("l", "l", "r", "l", "l", "r", "r", "r"),
    linesep = ""
)
newly_included_regions_tex <- paste(newly_included_regions_tex, collapse = "\n")
newly_included_regions_tex <- sub("^\\s+", "", newly_included_regions_tex)

writeLines(
    newly_included_regions_tex,
    file.path(OUTPUT_FOLDER, "newly_included_regions.tex")
)
