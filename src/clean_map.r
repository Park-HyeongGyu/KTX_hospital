library(DBI)
library(duckdb)
library(sf)
library(dplyr)
library(readxl)
library(glue)
library(tibble)

source("config.r")

con <- dbConnect(duckdb(), DB_CLEAN)

############################################################
#### bnd_sigungu_00_2023_4Q.shp ############################
############################################################

sigungu_map_raw <- st_read(
    dsn = file.path(RAW, "bnd_sigungu_00_2023_4Q", "bnd_sigungu_00_2023_4Q.shp"),
    options = "ENCODING=CP949",
    quiet = TRUE
)

# EPSG:5179
sigungu_map_raw <- st_transform(sigungu_map_raw, 5179)

adm_code_2023_raw <- read_excel(
    path = file.path(RAW, "adm_code.xls"),
    sheet = "2023년 12월",
    skip = 1,
    col_names = c(
        "sido_code",
        "sido_name",
        "sigungu_code",
        "sigungu_name",
        "emd_code",
        "emd_name"
    )
) 

adm_code_2023 <- adm_code_2023_raw %>%
    filter(sido_code != "시도코드") %>%
    mutate(
        sido_name = case_when(
            sido_name == "서울특별시" ~ "서울",
            sido_name == "부산광역시" ~ "부산",
            sido_name == "대구광역시" ~ "대구",
            sido_name == "인천광역시" ~ "인천",
            sido_name == "광주광역시" ~ "광주",
            sido_name == "대전광역시" ~ "대전",
            sido_name == "울산광역시" ~ "울산",
            sido_name == "세종특별자치시" ~ "세종",
            sido_name == "경기도" ~ "경기",
            sido_name == "강원특별자치도" ~ "강원",
            sido_name == "충청북도" ~ "충북",
            sido_name == "충청남도" ~ "충남",
            sido_name == "전북특별자치도" ~ "전북",
            sido_name == "전라북도" ~ "전북",
            sido_name == "전라남도" ~ "전남",
            sido_name == "경상북도" ~ "경북",
            sido_name == "경상남도" ~ "경남",
            sido_name == "제주특별자치도" ~ "제주",
            TRUE ~ sido_name
        ),
        sido_code = as.character(sido_code),
        sigungu_code = sprintf("%03d", as.integer(sigungu_code)),
        adm_sigungu_cd = paste0(sido_code, sigungu_code)
    ) %>%
    distinct(adm_sigungu_cd, .keep_all = TRUE) %>%
    select(adm_sigungu_cd, sido_code, sido_name, sigungu_code, sigungu_name)

sigungu_map <- sigungu_map_raw %>%
    left_join(adm_code_2023, by = c("SIGUNGU_CD" = "adm_sigungu_cd"))

stopifnot(st_crs(sigungu_map)$epsg == 5179)
stopifnot(sum(is.na(sigungu_map$sido_name)) == 0)


#### manual region harmonization ####

region_rule <- tibble::tribble(
    ~sido_name, ~sigungu_name,        ~action,   ~target_sido, ~target_sigungu,
    "경북",     "군위군",             "keep",    "경북",       "군위군",
    "대구",     "군위군",             "rename",  "경북",       "군위군",
    "경기",     "부천시",             "keep",    "경기",       "부천시",
    "경기",     "부천시 소사구",      "merge",   "경기",       "부천시",
    "경기",     "부천시 오정구",      "merge",   "경기",       "부천시",
    "경기",     "부천시 원미구",      "merge",   "경기",       "부천시",
    "세종",     "세종시",             "drop",    NA,           NA,
    "충북",     "청원군",             "drop",    NA,           NA,
    "충북",     "청주시 청원구",      "drop",    NA,           NA,
    "충북",     "청주시 서원구",      "drop",    NA,           NA,
    "충북",     "청주시 상당구",      "drop",    NA,           NA,
    "충북",     "청주시 흥덕구",      "drop",    NA,           NA,
    "충남",     "연기군",             "drop",    NA,           NA,
    "충남",     "공주시",             "drop",    NA,           NA,
    "충남",     "천안시",             "keep",    "충남",       "천안시",
    "충남",     "천안시 서북구",      "merge",   "충남",       "천안시",
    "충남",     "천안시 동남구",      "merge",   "충남",       "천안시",
    "경남",     "마산시",             "merge",   "경남",       "창원시",
    "경남",     "진해시",             "merge",   "경남",       "창원시",
    "경남",     "창원시",             "merge",   "경남",       "창원시",
    "경남",     "창원시 마산합포구",  "merge",   "경남",       "창원시",
    "경남",     "창원시 마산회원구",  "merge",   "경남",       "창원시",
    "경남",     "창원시 진해구",      "merge",   "경남",       "창원시",
    "경남",     "창원시 의창구",      "merge",   "경남",       "창원시",
    "경남",     "창원시 성산구",      "merge",   "경남",       "창원시",
    "경기",     "고양시 일산동구",    "rename",  "경기",       "고양시 일산 동구",
    "경기",     "고양시 일산서구",    "rename",  "경기",       "고양시 일산 서구",
    "인천",     "남구",               "rename",  "인천",       "남구",
    "인천",     "미추홀구",           "rename",  "인천",       "남구",
    "부산",     "진구",               "rename",  "부산",       "부산진구"
)

sigungu_map_rule <- sigungu_map %>%
    left_join(region_rule, by = c("sido_name", "sigungu_name"))

sigungu_map_rule <- sigungu_map_rule %>%
    mutate(
        action = if_else(is.na(action), "keep", action),
        region_sido = if_else(is.na(target_sido), sido_name, target_sido),
        region_sigungu = if_else(is.na(target_sigungu), sigungu_name, target_sigungu)
    )

sigungu_map_filtered <- sigungu_map_rule %>%
    filter(action != "drop")

sigungu_map_ruled <- sigungu_map_filtered %>%
    group_by(region_sido, region_sigungu) %>%
    summarise(.groups = "drop")

stopifnot(st_crs(sigungu_map_ruled)$epsg == 5179)

sigungu_map_ruled_path <- file.path(CLEAN, "sigungu_map_ruled.parquet")

if (file.exists(sigungu_map_ruled_path)) {
    file.remove(sigungu_map_ruled_path)
}

# 이거 가지고 나중에 지도 색칠하는 함수 만들자.
st_write(
    obj = sigungu_map_ruled,
    dsn = sigungu_map_ruled_path,
    driver = "Parquet",
    quiet = TRUE
)


#### centroid coordinates ####

sigungu_map_centroid <- st_centroid(sigungu_map_ruled)

sigungu_coord <- sigungu_map_centroid %>%
    mutate(
        x_coord = st_coordinates(geometry)[, 1],
        y_coord = st_coordinates(geometry)[, 2]
    ) %>%
    st_drop_geometry() %>%
    select(region_sido, region_sigungu, x_coord, y_coord)

merge_key <- read.csv(
    file = file.path(CSV, "merge_key.csv"),
    fileEncoding = "UTF-8",
    check.names = FALSE
)

stopifnot(
    nrow(
        anti_join(
            merge_key,
            sigungu_coord,
            by = c("region_sido", "region_sigungu")
        )
    ) == 0
)

stopifnot(
    nrow(
        anti_join(
            sigungu_coord,
            merge_key,
            by = c("region_sido", "region_sigungu")
        )
    ) == 0
)

dbWriteTable(con, "sigungu_coord", sigungu_coord, overwrite = TRUE)

############################################################
#### 국가철도공단_철도역 정보_20250711 ##########################
#### manual/ktx_shock_date #################################
############################################################

temp_station_coord_raw <- read.csv(
    file = file.path(RAW, "국가철도공단_철도역 정보_20250711.csv"),
    fileEncoding = "UTF-8",
    check.names = FALSE
)

temp_station_coord <- temp_station_coord_raw %>%
    transmute(
        station_name = case_when(
            역이름 == "김천(구미)" ~ "김천(구미)역",
            TRUE ~ 역이름
        ),
        lon = 경도좌표,
        lat = 위도좌표
    )

# 수동 좌표 보정
# 서대구역: 35° 52′ 53.29″ N, 128° 32′ 25.45″ E
# 김천(구미)역 36° 6′ 48.68″ N, 128° 10′ 51.60″ E
# 김천(구미)역: 36.113522147, 128.180999088 위에거랑 동일함

temp_station_coord_manual <- data.frame(
    station_name = c(
        "서대구역",
        "김천(구미)역"
    ),
    lon = c(
        128 + 32 / 60 + 25.45 / 3600,
        128.180999088
    ),
    lat = c(
        35 + 52 / 60 + 53.29 / 3600,
        36.113522147
    )
)

temp_station_coord <- temp_station_coord %>%
    filter(!station_name %in% temp_station_coord_manual$station_name)

temp_station_coord <- bind_rows(temp_station_coord, temp_station_coord_manual)

temp_station_coord_sf <- st_as_sf(
    temp_station_coord,
    coords = c("lon", "lat"),
    crs = 4326,
    remove = FALSE
)

temp_station_coord_sf <- st_transform(temp_station_coord_sf, 5179)

temp_station_coord <- temp_station_coord_sf %>%
    mutate(
        x_coord = st_coordinates(geometry)[, 1],
        y_coord = st_coordinates(geometry)[, 2]
    ) %>%
    st_drop_geometry() %>%
    select(station_name, x_coord, y_coord)

dbWriteTable(con, "temp_station_coord", temp_station_coord, overwrite = TRUE)


#### ktx station coordinates ####

ktx_shock_date_raw <- read_excel(
    #path = file.path(RAW, "manual", "ktx_shock_date.xlsx")
    path = file.path(RAW, "manual", "ktx_shock_date_removed.xlsx")
)

ktx_shock_date <- ktx_shock_date_raw %>%
    mutate(
        station_name = case_when(
            grepl("역$", station) ~ station,
            TRUE ~ paste0(station, "역")
        )
    ) %>%
    select(line, station_name, ktx_date)

ktx_station_coord <- ktx_shock_date %>%
    left_join(temp_station_coord, by = "station_name")

stopifnot(sum(is.na(ktx_station_coord$x_coord)) == 0)
stopifnot(sum(is.na(ktx_station_coord$y_coord)) == 0)

dbWriteTable(con, "ktx_station_coord", ktx_station_coord, overwrite = TRUE)
dbExecute(con, "DROP TABLE IF EXISTS temp_station_coord")


############################################################
#### Merge and Finalize ####################################
############################################################

for (threshold_km in seq(10, 50, 10)) {
    threshold_meter <- threshold_km * 1000
    clean_shock_table <- glue("clean_shock_{threshold_km}")

    dbExecute(con, glue("
        CREATE OR REPLACE TABLE temp_1 AS
        WITH candidate_station AS (
            SELECT
                s.region_sido,
                s.region_sigungu,
                k.station_name AS shock_station,
                k.line,
                sqrt(
                    power(s.x_coord - k.x_coord, 2) +
                    power(s.y_coord - k.y_coord, 2)
                ) / 1000.0 AS distance_to_station,
                CAST(k.ktx_date AS DATE) AS ktx_date
            FROM sigungu_coord AS s
            INNER JOIN ktx_station_coord AS k
                ON abs(s.x_coord - k.x_coord) <= {threshold_meter}
               AND abs(s.y_coord - k.y_coord) <= {threshold_meter}
            WHERE sqrt(
                power(s.x_coord - k.x_coord, 2) +
                power(s.y_coord - k.y_coord, 2)
            ) <= {threshold_meter}
        ),
        ranked_station AS (
            SELECT
                region_sido,
                region_sigungu,
                shock_station,
                line,
                distance_to_station,
                ktx_date,
                row_number() OVER (
                    PARTITION BY region_sido, region_sigungu
                    ORDER BY
                        ktx_date,
                        distance_to_station,
                        shock_station
                ) AS rn
            FROM candidate_station
        )
        SELECT
            s.region_sido,
            s.region_sigungu,
            r.shock_station,
            r.line,
            r.distance_to_station,
            r.ktx_date,
            CASE
                WHEN r.ktx_date IS NULL THEN NULL
                WHEN EXTRACT(MONTH FROM r.ktx_date) < 5 THEN EXTRACT(YEAR FROM r.ktx_date)
                ELSE EXTRACT(YEAR FROM r.ktx_date) + 1
            END AS shock_year
        FROM sigungu_coord AS s
        LEFT JOIN ranked_station AS r
            ON s.region_sido = r.region_sido
           AND s.region_sigungu = r.region_sigungu
           AND r.rn = 1
        ORDER BY
            s.region_sido,
            s.region_sigungu
    "))
    # 계룡역(7월 15일 개통) 빼고 5월 이전 이후로 나누면 shock_year가
    # 깔끔하게 나누어 떨어짐. 그리고 어차피 계룡역은 2005년에 개통함

    dbExecute(con, "
        CREATE OR REPLACE TABLE temp_time AS
        SELECT
            year
        FROM range(2007, 2026) AS t(year)
    ")

    dbExecute(con, glue("
        CREATE OR REPLACE TABLE {clean_shock_table} AS
        SELECT
            t1.region_sido,
            t1.region_sigungu,
            tt.year,
            t1.shock_station,
            t1.line,
            t1.distance_to_station,
            t1.ktx_date,
            t1.shock_year,
            CASE
                WHEN t1.shock_year IS NULL THEN 0
                WHEN tt.year < t1.shock_year THEN 0
                ELSE 1
            END AS ktx_shock_did
        FROM temp_1 AS t1
        CROSS JOIN temp_time AS tt
        ORDER BY
            t1.region_sido,
            t1.region_sigungu,
            tt.year
    "))

    clean_shock_path <- file.path(CLEAN, glue("{clean_shock_table}.parquet"))
    clean_shock_csv <- file.path(CSV, glue("{clean_shock_table}.csv"))

    dbExecute(con, glue("
        COPY {clean_shock_table} TO '{clean_shock_path}' (FORMAT PARQUET)
    "))
    dbExecute(con, glue("
        COPY {clean_shock_table} TO '{clean_shock_csv}' (FORMAT csv)
    "))

    dbExecute(con, "DROP TABLE IF EXISTS temp_1")
    dbExecute(con, "DROP TABLE IF EXISTS temp_time")
}

dbDisconnect(con, shutdown = TRUE)

