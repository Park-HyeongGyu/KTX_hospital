library(DBI)
library(duckdb)
library(glue)

source("config.r")

con <- dbConnect(duckdb(), DB_CLEAN)



############################################################
#### KOSIS_시군구별_종별_요양기관 ###############################
#### hospital_no_by_type.parquet ###########################
############################################################

raw_kosis_hospital <- file.path(RAW, "KOSIS_시군구별_종별_요양기관.csv")
csv_hospital_no_by_type <- file.path(CSV, "hospital_no_by_type.csv")
parquet_hospital_no_by_type <- file.path(CLEAN, "hospital_no_by_type.parquet")

dbExecute(con, glue("
    CREATE OR REPLACE TABLE temp_1 AS
    WITH raw_kosis AS (
        SELECT
            split_part(\"[1535413101140064HC3]시군구별\", '.', 2) AS region_code,
            CASE substr(split_part(\"[1535413101140064HC3]시군구별\", '.', 2), 1, 2)
                WHEN '11' THEN '서울'
                WHEN '21' THEN '부산'
                WHEN '22' THEN '대구'
                WHEN '23' THEN '인천'
                WHEN '24' THEN '광주'
                WHEN '25' THEN '대전'
                WHEN '26' THEN '울산'
                WHEN '31' THEN '경기'
                WHEN '32' THEN '강원'
                WHEN '33' THEN '충북'
                WHEN '34' THEN '충남'
                WHEN '35' THEN '전북'
                WHEN '36' THEN '전남'
                WHEN '37' THEN '경북'
                WHEN '38' THEN '경남'
                WHEN '39' THEN '제주'
                WHEN '41' THEN '세종'
            END AS region_sido,
            \"시군구별\" AS region_sigungu,
            \"요양기관종별\" AS hospital_type,
            \"2007.01 월\",
            \"2008.01 월\",
            \"2009.1/4\",
            \"2010.1/4\",
            \"2011.1/4\",
            \"2012.1/4\",
            \"2013.1/4\",
            \"2014.1/4\",
            \"2015.1/4\",
            \"2016.1/4\",
            \"2017.1/4\",
            \"2018.1/4\",
            \"2019.1/4\",
            \"2020.1/4\",
            \"2021.1/4\",
            \"2022.1/4\",
            \"2023.1/4\",
            \"2024.1/4\",
            \"2025.1/4\"
        FROM read_csv_auto('{raw_kosis_hospital}', header = TRUE)
    )
    SELECT
        region_sido,
        region_sigungu,
        hospital_type,
        CAST(substr(year_label, 1, 4) AS INTEGER) AS year,
        TRY_CAST(value AS INTEGER) AS value
    FROM (
        SELECT *
        FROM raw_kosis
        WHERE length(region_code) = 6
    )
    UNPIVOT (
        value FOR year_label IN (
            \"2007.01 월\",
            \"2008.01 월\",
            \"2009.1/4\",
            \"2010.1/4\",
            \"2011.1/4\",
            \"2012.1/4\",
            \"2013.1/4\",
            \"2014.1/4\",
            \"2015.1/4\",
            \"2016.1/4\",
            \"2017.1/4\",
            \"2018.1/4\",
            \"2019.1/4\",
            \"2020.1/4\",
            \"2021.1/4\",
            \"2022.1/4\",
            \"2023.1/4\",
            \"2024.1/4\",
            \"2025.1/4\"
        )
    )
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE temp_2 AS
    WITH renamed_regions AS (
        SELECT
            CASE
                WHEN region_sido = '대구' AND region_sigungu = '군위군' THEN '경북'
                ELSE region_sido
            END AS region_sido,
            CASE
                WHEN region_sido = '부산' AND region_sigungu = '진구' THEN '부산진구'
                WHEN region_sido = '경북' AND region_sigungu = '군위군' THEN '군위군'
                WHEN region_sido = '대구' AND region_sigungu = '군위군' THEN '군위군'
                WHEN region_sido = '인천' AND region_sigungu IN ('남구', '미추홀구') THEN '남구'
                WHEN region_sido = '경기' AND region_sigungu IN ('부천시', '부천시 소사구', '부천시 오정구', '부천시 원미구') THEN '부천시'
                WHEN region_sido = '충남' AND region_sigungu IN ('천안시', '천안시 서북구', '천안시 동남구') THEN '천안시'
                WHEN region_sido = '경남' AND region_sigungu IN (
                    '마산시',
                    '진해시',
                    '창원시',
                    '창원시 마산합포구',
                    '창원시 마산회원구',
                    '창원시 진해구',
                    '창원시 의창구',
                    '창원시 성산구'
                ) THEN '창원시'
                ELSE region_sigungu
            END AS region_sigungu,
            hospital_type,
            year,
            value
        FROM temp_1
        WHERE NOT (
            region_sido = '세종' AND region_sigungu = '세종시'
        )
          AND NOT (
            region_sido = '충북' AND region_sigungu = '청원군'
        )
          AND NOT (
            region_sido = '충북' AND region_sigungu IN ('청주시 청원구', '청주시 서원구')
        )
          AND NOT (
            region_sido = '충북' AND region_sigungu IN ('청주시 상당구', '청주시 흥덕구')
        )
          AND NOT (
            region_sido = '충남' AND region_sigungu = '연기군'
          )
          AND NOT (
            region_sido = '충남' AND region_sigungu = '공주시'
        )
          AND NOT (
            region_sido = '충남' AND region_sigungu = '세종시'
        )
    )
    SELECT
        region_sido,
        region_sigungu,
        hospital_type,
        year,
        SUM(value) AS value
    FROM renamed_regions
    GROUP BY
        region_sido,
        region_sigungu,
        hospital_type,
        year
    ORDER BY region_sido, region_sigungu, hospital_type, year
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE hospital_no_by_type AS
    SELECT
        region_sido,
        region_sigungu,
        hospital_type,
        year,
        value
    FROM temp_2 AS t
    WHERE hospital_type IN ('상급종합병원', '종합병원', '병원', '의원')
    ORDER BY region_sido, region_sigungu, hospital_type, year
"))

dbExecute(con, glue("
    COPY hospital_no_by_type TO '{csv_hospital_no_by_type}' (FORMAT CSV)
"))

dbExecute(con, glue("
    COPY hospital_no_by_type TO '{parquet_hospital_no_by_type}' (FORMAT PARQUET)
"))

dbExecute(con, "
    DROP TABLE IF EXISTS hospital_no_by_typejg
")

dbExecute(con, "
    DROP TABLE IF EXISTS temp_1
")

dbExecute(con, "
    DROP TABLE IF EXISTS temp_2
")





############################################################
#### HIRA_요양기관폐업현황 #####################################
#### exit_no_by_type.parquet ###############################
############################################################

raw_hira_exit <- file.path(RAW, "HIRA_요양기관폐업현황.csv")
csv_exit_no_by_type <- file.path(CSV, "exit_no_by_type.csv")
parquet_exit_no_by_type <- file.path(CLEAN, "exit_no_by_type.parquet")

dbExecute(con, glue("
    CREATE OR REPLACE TABLE temp_11 AS
    WITH raw_hira AS (
        SELECT
            \"시도명\" AS region_sido,
            \"시군구명\" AS region_sigungu,
            EXTRACT(YEAR FROM \"폐업일자\") AS year
        FROM read_csv_auto('{raw_hira_exit}', header = TRUE)
    ),
    hira_2007 AS (
        SELECT
            region_sido,
            region_sigungu,
            year
        FROM raw_hira
        WHERE year >= 2007
    )
    SELECT
        h.region_sido,
        h.region_sigungu,
        COUNT(*) AS n
    FROM hira_2007 AS h
    LEFT JOIN (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM hospital_no_by_type
    ) AS k
        USING (region_sido, region_sigungu)
    WHERE k.region_sido IS NULL
    GROUP BY
        h.region_sido,
        h.region_sigungu
    ORDER BY h.region_sido, h.region_sigungu
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE temp_12 AS
    WITH raw_hira AS (
        SELECT
            \"요양종별\" AS hospital_type,
            \"시도명\" AS region_sido,
            \"시군구명\" AS region_sigungu,
            EXTRACT(YEAR FROM \"폐업일자\") AS year
        FROM read_csv_auto('{raw_hira_exit}', header = TRUE)
    ),
    hira_2007 AS (
        SELECT
            hospital_type,
            region_sido,
            region_sigungu,
            year
        FROM raw_hira
        WHERE year >= 2007
    ),
    renamed_regions AS (
        SELECT
            hospital_type,
            CASE
                WHEN region_sido = '대구' AND region_sigungu = '군위군' THEN '경북'
                ELSE region_sido
            END AS region_sido,
            CASE
                WHEN region_sido = '부산' AND region_sigungu = '진구' THEN '부산진구'
                WHEN region_sido = '경북' AND region_sigungu = '군위군' THEN '군위군'
                WHEN region_sido = '대구' AND region_sigungu = '군위군' THEN '군위군'
                WHEN region_sido = '인천' AND region_sigungu IN ('남구', '미추홀구') THEN '남구'
                WHEN region_sido = '경기' AND region_sigungu = '고양시 일산동구' THEN '고양시 일산 동구'
                WHEN region_sido = '경기' AND region_sigungu = '고양시 일산서구' THEN '고양시 일산 서구'
                WHEN region_sido = '경기' AND region_sigungu IN ('부천시', '부천시 소사구', '부천시 오정구', '부천시 원미구') THEN '부천시'
                WHEN region_sido = '충남' AND region_sigungu IN ('천안시', '천안시 동남구', '천안시 서북구', '천안시(천안서북구,동남구)') THEN '천안시'
                WHEN region_sido = '경남' AND region_sigungu IN (
                    '마산시',
                    '진해시',
                    '창원시',
                    '창원시 마산합포구',
                    '창원시 마산회원구',
                    '창원시 진해구',
                    '창원시 의창구',
                    '창원시 성산구'
                ) THEN '창원시'
                ELSE region_sigungu
            END AS region_sigungu,
            year
        FROM hira_2007
        WHERE NOT (
            region_sido = '세종' AND region_sigungu = '세종시'
        )
          AND NOT (
            region_sido = '충북' AND region_sigungu = '청원군'
        )
          AND NOT (
            region_sido = '충북' AND region_sigungu IN ('청주시 청원구', '청주시 서원구')
        )
          AND NOT (
            region_sido = '충북' AND region_sigungu IN ('청주시 상당구', '청주시 흥덕구')
        )
          AND NOT (
            region_sido = '충남' AND region_sigungu = '연기군'
        )
          AND NOT (
            region_sido = '충남' AND region_sigungu = '공주시'
        )
          AND NOT (
            region_sido = '충남' AND region_sigungu = '세종시'
        )
    )
    SELECT
        hospital_type,
        region_sido,
        region_sigungu,
        year
    FROM renamed_regions
    ORDER BY region_sido, region_sigungu, hospital_type, year
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE temp_13 AS
    SELECT
        region_sido,
        region_sigungu,
        hospital_type,
        year,
        COUNT(*) AS exit_no
    FROM temp_12
    GROUP BY
        region_sido,
        region_sigungu,
        hospital_type,
        year
    ORDER BY region_sido, region_sigungu, hospital_type, year
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE exit_no_by_type AS
    WITH region_keys AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM hospital_no_by_type
    ),
    hospital_types AS (
        SELECT '상급종합병원' AS hospital_type
        UNION ALL
        SELECT '종합병원' AS hospital_type
        UNION ALL
        SELECT '병원' AS hospital_type
        UNION ALL
        SELECT '의원' AS hospital_type
    ),
    years AS (
        SELECT DISTINCT
            year
        FROM hospital_no_by_type
    ),
    full_grid AS (
        SELECT
            r.region_sido,
            r.region_sigungu,
            h.hospital_type,
            y.year
        FROM region_keys AS r
        CROSS JOIN hospital_types AS h
        CROSS JOIN years AS y
    )
    SELECT
        g.region_sido,
        g.region_sigungu,
        g.hospital_type,
        g.year,
        COALESCE(t.exit_no, 0) AS exit_no
    FROM full_grid AS g
    LEFT JOIN (
        SELECT
            region_sido,
            region_sigungu,
            hospital_type,
            year,
            exit_no
        FROM temp_13
        WHERE hospital_type IN ('상급종합병원', '종합병원', '병원', '의원')
    ) AS t
        USING (region_sido, region_sigungu, hospital_type, year)
    ORDER BY g.region_sido, g.region_sigungu, g.hospital_type, g.year
"))

dbExecute(con, glue("
    COPY exit_no_by_type TO '{csv_exit_no_by_type}' (FORMAT CSV)
"))

dbExecute(con, glue("
    COPY exit_no_by_type TO '{parquet_exit_no_by_type}' (FORMAT PARQUET)
"))

dbExecute(con, "
    DROP TABLE IF EXISTS temp_11
")

dbExecute(con, "
    DROP TABLE IF EXISTS temp_12
")

dbExecute(con, "
    DROP TABLE IF EXISTS temp_13
")

############################################################
#### hospital_full.parquet #################################
############################################################

parquet_hospital_no_by_type <- file.path(CLEAN, "hospital_no_by_type.parquet")
parquet_exit_no_by_type <- file.path(CLEAN, "exit_no_by_type.parquet")
csv_hospital_full <- file.path(CSV, "hospital_full.csv")
parquet_hospital_full <- file.path(CLEAN, "hospital_full.parquet")

dbExecute(con, glue("
    CREATE OR REPLACE TABLE hospital_full AS
    WITH hospital_no_base AS (
        SELECT
            region_sido,
            region_sigungu,
            hospital_type,
            year,
            value AS hospital_no
        FROM read_parquet('{parquet_hospital_no_by_type}')
    ),
    exit_no_base AS (
        SELECT
            region_sido,
            region_sigungu,
            hospital_type,
            year,
            exit_no
        FROM read_parquet('{parquet_exit_no_by_type}')
    ),
    joined_base AS (
        SELECT
            h.region_sido,
            h.region_sigungu,
            h.hospital_type,
            h.year,
            h.hospital_no,
            COALESCE(e.exit_no, 0) AS exit_no
        FROM hospital_no_base AS h
        LEFT JOIN exit_no_base AS e
            USING (region_sido, region_sigungu, hospital_type, year)
    ),
    entry_base AS (
        SELECT
            region_sido,
            region_sigungu,
            hospital_type,
            year,
            hospital_no,
            hospital_no - LAG(hospital_no) OVER (
                PARTITION BY region_sido, region_sigungu, hospital_type
                ORDER BY year
            ) AS net_entry,
            exit_no
        FROM joined_base
    )
    SELECT
        region_sido,
        region_sigungu,
        hospital_type,
        year,
        hospital_no,
        net_entry,
        exit_no,
        CASE
            WHEN hospital_no = 0 THEN NULL
            ELSE CAST(exit_no AS DOUBLE) / hospital_no
        END AS exit_rate,
        net_entry + exit_no AS entry_no,
        CASE
            WHEN hospital_no = 0 THEN NULL
            ELSE CAST(net_entry + exit_no AS DOUBLE) / hospital_no
        END AS entry_rate
    FROM entry_base
    ORDER BY region_sido, region_sigungu, hospital_type, year
"))

dbExecute(con, glue("
    COPY hospital_full TO '{csv_hospital_full}' (FORMAT CSV)
"))

dbExecute(con, glue("
    COPY hospital_full TO '{parquet_hospital_full}' (FORMAT PARQUET)
"))

dbDisconnect(con, shutdown = TRUE)

