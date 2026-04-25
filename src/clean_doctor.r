library(DBI)
library(duckdb)
library(glue)

source("config.r")

con <- dbConnect(duckdb(), DB_CLEAN)

############################################################
#### 시군구별의료인력현황_의사 ###################################
#### clean_doctor_by_level.parquet #########################
############################################################

raw_kosis_doctor <- file.path(RAW, "KOSIS_시군구별의료인력현황_의사.csv")

dbExecute(con, glue("
    CREATE OR REPLACE TABLE temp_doctor_1 AS
    WITH raw_kosis AS (
        SELECT
            \"[1535413101140072HC3]시군구별\" AS region_code_raw,
            CASE
                WHEN contains(\"[1535413101140072HC3]시군구별\", '.') THEN split_part(\"[1535413101140072HC3]시군구별\", '.', 2)
                ELSE \"[1535413101140072HC3]시군구별\"
            END AS region_code,
            CASE
                WHEN (
                    CASE
                        WHEN contains(\"[1535413101140072HC3]시군구별\", '.') THEN split_part(\"[1535413101140072HC3]시군구별\", '.', 2)
                        ELSE \"[1535413101140072HC3]시군구별\"
                    END
                ) = '1A' THEN '대구' -- 대구 군위구 지역코드 이상함 이슈
                ELSE CASE substr(
                    CASE
                        WHEN contains(\"[1535413101140072HC3]시군구별\", '.') THEN split_part(\"[1535413101140072HC3]시군구별\", '.', 2)
                        ELSE \"[1535413101140072HC3]시군구별\"
                    END,
                    1,
                    2
                )
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
                END
            END AS region_sido,
            \"시군구별\" AS region_sigungu,
            \"의료인력별\" AS doctor_level,
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
        FROM read_csv_auto('{raw_kosis_doctor}', header = TRUE)
    )
    SELECT
        region_sido,
        region_sigungu,
        CASE
            WHEN doctor_level = '의사' THEN 'total'
            ELSE doctor_level
        END AS doctor_level,
        CAST(substr(year_label, 1, 4) AS INTEGER) AS year,
        TRY_CAST(value AS INTEGER) AS doctor_no
    FROM (
        SELECT *
        FROM raw_kosis
        WHERE length(region_code) = 6
           OR (
               region_code_raw = '1A'
               AND region_sigungu = '군위군'
           )
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
    CREATE OR REPLACE TABLE clean_doctor_by_level AS
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
            doctor_level,
            year,
            doctor_no
        FROM temp_doctor_1
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
    ),
    manual_overrides AS (
        -- Manual override: use the December 2008 Cheonan values from raw_data/의사_천안시.png
        -- as the 2009 Cheonan values because the original 2009 KOSIS cells are missing.
        -- 수기 보정: 원본 2009년 KOSIS 값이 결측이라 raw_data/의사_천안시.png의
        -- 2008년 12월 천안시 값을 2009년 천안시 값으로 사용한다.
        SELECT '충남' AS region_sido, '천안시' AS region_sigungu, 'total' AS doctor_level, 2009 AS year, 1064 AS doctor_no
        UNION ALL
        SELECT '충남', '천안시', '일반의', 2009, 70
        UNION ALL
        SELECT '충남', '천안시', '인턴', 2009, 76
        UNION ALL
        SELECT '충남', '천안시', '레지던트', 2009, 236
        UNION ALL
        SELECT '충남', '천안시', '전문의', 2009, 682
    )
    SELECT
        region_sido,
        region_sigungu,
        doctor_level,
        year,
        SUM(doctor_no) AS doctor_no
    FROM (
        SELECT *
        FROM renamed_regions
        UNION ALL
        SELECT *
        FROM manual_overrides
    )
    GROUP BY
        region_sido,
        region_sigungu,
        doctor_level,
        year
    ORDER BY region_sido, region_sigungu, doctor_level, year
"))

clean_doctor_by_level_parquet <- file.path(CLEAN, "clean_doctor_by_level.parquet")
clean_doctor_by_level_csv <- file.path(CSV, "clean_doctor_by_level.csv")
dbExecute(con, glue("
    COPY clean_doctor_by_level TO '{clean_doctor_by_level_parquet}' (FORMAT PARQUET)
"))

dbExecute(con, glue("
    COPY clean_doctor_by_level TO '{clean_doctor_by_level_csv}' (FORMAT CSV)
"))

dbExecute(con, "DROP TABLE IF EXISTS temp_doctor_1")

dbDisconnect(con, shutdown = TRUE)
