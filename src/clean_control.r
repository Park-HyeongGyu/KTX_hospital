library(DBI)
library(duckdb)
library(glue)

source("config.r")

con <- dbConnect(duckdb(), DB_CLEAN)

############################################################
#### 주민등록인구_시도_시_군_구 #################################
#### population.parquet ####################################
############################################################

raw_population <- file.path(RAW, "행정구역_시군구_별__성별_인구수_20260423193150.csv")

dbExecute(con, glue("
    CREATE OR REPLACE TABLE temp_population_1 AS
    WITH raw_population AS (
        SELECT
            \"A 행정구역(시군구)별\" AS raw_region,
            split_part(\"A 행정구역(시군구)별\", ' ', 1) AS region_code,
            substr(split_part(\"A 행정구역(시군구)별\", ' ', 1), 1, 2) AS sido_code,
            trim(regexp_replace(\"A 행정구역(시군구)별\", '^[0-9]+\\s+', '')) AS raw_name,
            \"Y2007 2007\",
            \"Y2008 2008\",
            \"Y2009 2009\",
            \"Y2010 2010\",
            \"Y2011 2011\",
            \"Y2012 2012\",
            \"Y2013 2013\",
            \"Y2014 2014\",
            \"Y2015 2015\",
            \"Y2016 2016\",
            \"Y2017 2017\",
            \"Y2018 2018\",
            \"Y2019 2019\",
            \"Y2020 2020\",
            \"Y2021 2021\",
            \"Y2022 2022\",
            \"Y2023 2023\",
            \"Y2024 2024\",
            \"Y2025 2025\"
        FROM read_csv_auto('{raw_population}', header = TRUE)
        WHERE \"A 행정구역(시군구)별\" <> 'A 행정구역(시군구)별'
    ),
    sido_lookup AS (
        SELECT
            region_code AS sido_code,
            CASE raw_name
                WHEN '서울특별시' THEN '서울'
                WHEN '부산광역시' THEN '부산'
                WHEN '대구광역시' THEN '대구'
                WHEN '인천광역시' THEN '인천'
                WHEN '광주광역시' THEN '광주'
                WHEN '대전광역시' THEN '대전'
                WHEN '울산광역시' THEN '울산'
                WHEN '세종특별자치시' THEN '세종'
                WHEN '경기도' THEN '경기'
                WHEN '충청북도' THEN '충북'
                WHEN '충청남도' THEN '충남'
                WHEN '전라남도' THEN '전남'
                WHEN '경상북도' THEN '경북'
                WHEN '경상남도' THEN '경남'
                WHEN '제주특별자치도' THEN '제주'
                WHEN '강원특별자치도' THEN '강원'
                WHEN '전북특별자치도' THEN '전북'
                ELSE raw_name
            END AS region_sido
        FROM raw_population
        WHERE length(region_code) = 2
    ),
    filtered_population AS (
        SELECT
            region_code,
            sido_code,
            raw_name,
            \"Y2007 2007\",
            \"Y2008 2008\",
            \"Y2009 2009\",
            \"Y2010 2010\",
            \"Y2011 2011\",
            \"Y2012 2012\",
            \"Y2013 2013\",
            \"Y2014 2014\",
            \"Y2015 2015\",
            \"Y2016 2016\",
            \"Y2017 2017\",
            \"Y2018 2018\",
            \"Y2019 2019\",
            \"Y2020 2020\",
            \"Y2021 2021\",
            \"Y2022 2022\",
            \"Y2023 2023\",
            \"Y2024 2024\",
            \"Y2025 2025\"
        FROM raw_population
        WHERE length(region_code) = 5
          AND raw_name NOT LIKE '%출장소%'
    )
    SELECT
        p.region_code,
        s.region_sido,
        p.raw_name AS region_sigungu,
        p.\"Y2007 2007\",
        p.\"Y2008 2008\",
        p.\"Y2009 2009\",
        p.\"Y2010 2010\",
        p.\"Y2011 2011\",
        p.\"Y2012 2012\",
        p.\"Y2013 2013\",
        p.\"Y2014 2014\",
        p.\"Y2015 2015\",
        p.\"Y2016 2016\",
        p.\"Y2017 2017\",
        p.\"Y2018 2018\",
        p.\"Y2019 2019\",
        p.\"Y2020 2020\",
        p.\"Y2021 2021\",
        p.\"Y2022 2022\",
        p.\"Y2023 2023\",
        p.\"Y2024 2024\",
        p.\"Y2025 2025\"
    FROM filtered_population AS p
    LEFT JOIN sido_lookup AS s
        USING (sido_code)
    ORDER BY p.region_code
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE temp_population_2 AS
    SELECT
        region_code,
        region_sido,
        region_sigungu,
        CAST(substr(year_label, 2, 4) AS INTEGER) AS year,
        TRY_CAST(NULLIF(value, '-') AS INTEGER) AS population
    FROM temp_population_1
    UNPIVOT (
        value FOR year_label IN (
            \"Y2007 2007\",
            \"Y2008 2008\",
            \"Y2009 2009\",
            \"Y2010 2010\",
            \"Y2011 2011\",
            \"Y2012 2012\",
            \"Y2013 2013\",
            \"Y2014 2014\",
            \"Y2015 2015\",
            \"Y2016 2016\",
            \"Y2017 2017\",
            \"Y2018 2018\",
            \"Y2019 2019\",
            \"Y2020 2020\",
            \"Y2021 2021\",
            \"Y2022 2022\",
            \"Y2023 2023\",
            \"Y2024 2024\",
            \"Y2025 2025\"
        )
    )
    ORDER BY region_code, year
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE clean_population AS
    WITH renamed_population AS (
        SELECT
            region_code,
            CASE
                WHEN region_sido = '대구' AND region_sigungu = '군위군' THEN '경북'
                ELSE region_sido
            END AS region_sido,
            CASE
                WHEN region_sido = '인천' AND region_sigungu IN ('남구', '미추홀구') THEN '남구'
                WHEN region_sido = '경기' AND region_sigungu IN ('부천시', '원미구', '소사구', '오정구') THEN '부천시'
                WHEN region_sido = '경기' AND region_sigungu IN ('여주군', '여주시') THEN '여주시'
                WHEN region_sido = '충남' AND region_sigungu IN ('당진군', '당진시') THEN '당진시'
                WHEN region_sido = '경기' AND region_code = '41281' THEN '고양시 덕양구'
                WHEN region_sido = '경기' AND region_code = '41285' THEN '고양시 일산 동구'
                WHEN region_sido = '경기' AND region_code = '41287' THEN '고양시 일산 서구'
                WHEN region_sido = '경기' AND region_code IN ('41111', '41113', '41115', '41117') THEN concat('수원시 ', region_sigungu)
                WHEN region_sido = '경기' AND region_code IN ('41131', '41133', '41135') THEN concat('성남시 ', region_sigungu)
                WHEN region_sido = '경기' AND region_code IN ('41271', '41273') THEN concat('안산시 ', region_sigungu)
                WHEN region_sido = '경기' AND region_code IN ('41171', '41173') THEN concat('안양시 ', region_sigungu)
                WHEN region_sido = '경기' AND region_code IN ('41461', '41463', '41465') THEN concat('용인시 ', region_sigungu)
                WHEN region_sido = '충남' AND region_sigungu IN ('천안시', '동남구', '서북구') THEN '천안시'
                WHEN region_sido = '경남' AND region_sigungu IN ('창원시', '마산시', '진해시', '의창구', '성산구', '마산합포구', '마산회원구', '진해구') THEN '창원시'
                WHEN region_sido = '경북' AND region_code IN ('47111', '47113') THEN concat('포항시 ', region_sigungu)
                WHEN region_sido = '전북' AND region_code IN ('52111', '52113') THEN concat('전주시 ', region_sigungu)
                ELSE region_sigungu
            END AS region_sigungu,
            year,
            population
        FROM temp_population_2
        WHERE NOT (
            region_sido = '세종' AND region_sigungu = '세종시'
        )
          AND NOT (
            region_sido = '충북' AND region_sigungu IN ('청원군', '청주시', '상당구', '서원구', '흥덕구', '청원구')
        )
          AND NOT (
            region_sido = '충남' AND region_sigungu IN ('연기군', '공주시')
        )
          AND NOT (
            region_sido = '경기' AND region_sigungu IN ('고양시', '수원시', '성남시', '안산시', '안양시', '용인시')
        )
          AND NOT (
            region_sido = '경북' AND region_sigungu = '포항시'
        )
          AND NOT (
            region_sido = '전북' AND region_sigungu = '전주시'
        )
    )
    SELECT
        region_sido,
        region_sigungu,
        year,
        SUM(population) AS population
    FROM renamed_population
    GROUP BY
        region_sido,
        region_sigungu,
        year
    ORDER BY region_sido, region_sigungu, year
"))

csv_clean_population <- file.path(CSV, "clean_population.csv")
parquet_clean_population <- file.path(CLEAN, "clean_population.parquet")

dbExecute(con, glue("
    COPY clean_population TO '{csv_clean_population}' (FORMAT CSV)
"))

dbExecute(con, glue("
    COPY clean_population TO '{parquet_clean_population}' (FORMAT PARQUET)
"))

dbExecute(con, "
    DROP TABLE IF EXISTS temp_population_1
")

dbExecute(con, "
    DROP TABLE IF EXISTS temp_population_2
")

dbDisconnect(con, shutdown = TRUE)
