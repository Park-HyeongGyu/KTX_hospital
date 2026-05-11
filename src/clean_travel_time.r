library(DBI)
library(duckdb)
library(dplyr)
library(sf)
library(osrm)
library(readxl)
library(glue)
library(tibble)

source("config.r")

options(osrm.server = "http://localhost:5000/")
options(osrm.profile = "car")

con <- dbConnect(duckdb(), DB_CLEAN)

############################################################
#### Region Coordinate #####################################
############################################################

sigungu_map_raw <- st_read(
    dsn = file.path(RAW, "bnd_sigungu_00_2023_4Q", "bnd_sigungu_00_2023_4Q.shp"),
    options = "ENCODING=CP949",
    quiet = TRUE
)

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

sigungu_map_ruled <- sigungu_map %>%
    left_join(region_rule, by = c("sido_name", "sigungu_name")) %>%
    mutate(
        action = if_else(is.na(action), "keep", action),
        region_sido = if_else(is.na(target_sido), sido_name, target_sido),
        region_sigungu = if_else(is.na(target_sigungu), sigungu_name, target_sigungu)
    ) %>%
    filter(action != "drop") %>%
    group_by(region_sido, region_sigungu) %>%
    summarise(.groups = "drop")

stopifnot(st_crs(sigungu_map_ruled)$epsg == 5179)

region_coord <- sigungu_map_ruled %>%
    st_centroid() %>%
    st_transform(4326) %>%
    mutate(
        lon_epsg_4326 = st_coordinates(geometry)[, 1],
        lat_epsg_4326 = st_coordinates(geometry)[, 2]
    ) %>%
    st_drop_geometry() %>%
    select(region_sido, region_sigungu, lon_epsg_4326, lat_epsg_4326)

merge_key <- read.csv(
    file = file.path(CSV, "merge_key.csv"),
    fileEncoding = "UTF-8",
    check.names = FALSE
)

stopifnot(nrow(anti_join(merge_key, region_coord, by = c("region_sido", "region_sigungu"))) == 0)
stopifnot(nrow(anti_join(region_coord, merge_key, by = c("region_sido", "region_sigungu"))) == 0)

dbWriteTable(con, "region_coord", region_coord, overwrite = TRUE)

region_coord_parquet <- file.path(CLEAN, "region_coord.parquet")
region_coord_csv <- file.path(CSV, "region_coord.csv")

dbExecute(con, glue("COPY region_coord TO '{region_coord_parquet}' (FORMAT PARQUET)"))
dbExecute(con, glue("COPY region_coord TO '{region_coord_csv}' (FORMAT CSV)"))

############################################################
#### Car Travel Time #######################################
############################################################

## Car travel time from the centroid of a region
## to Yongsan station (temporary destination).

destination_lon <- 126.9639
destination_lat <- 37.52957
# Temporarily, the destination is Yongsan station.
# The destination coordinate is hard-coded in EPSG:4326.

region_coord_parquet <- file.path(CLEAN, "region_coord.parquet")
region_coord <- dbGetQuery(con, glue("
    SELECT *
    FROM read_parquet('{region_coord_parquet}')
"))

osrm_src <- region_coord %>%
    select(lon = lon_epsg_4326, lat = lat_epsg_4326) %>%
    as.data.frame()

rownames(osrm_src) <- paste(
    region_coord$region_sido,
    region_coord$region_sigungu,
    sep = "_"
)

osrm_dst <- data.frame(
    lon = destination_lon,
    lat = destination_lat
)

rownames(osrm_dst) <- "용산역"

car_time_matrix <- osrmTable(
    src = osrm_src,
    dst = osrm_dst,
    measure = "duration"
)

travel_time_car <- region_coord %>%
    mutate(car_travel_time = as.numeric(car_time_matrix$durations[, 1])) %>%
    select(region_sido, region_sigungu, car_travel_time)

stopifnot(sum(is.na(travel_time_car$car_travel_time)) == 0)

#stopifnot(nrow(anti_join(merge_key, travel_time_car, by = c("region_sido", "region_sigungu"))) == 0)
#stopifnot(nrow(anti_join(travel_time_car, merge_key, by = c("region_sido", "region_sigungu"))) == 0)

dbWriteTable(con, "travel_time_car", travel_time_car, overwrite = TRUE)

travel_time_car_parquet <- file.path(CLEAN, "travel_time_car.parquet")
travel_time_car_csv <- file.path(CSV, "travel_time_car.csv")

dbExecute(con, glue("COPY travel_time_car TO '{travel_time_car_parquet}' (FORMAT PARQUET)"))
dbExecute(con, glue("COPY travel_time_car TO '{travel_time_car_csv}' (FORMAT CSV)"))

############################################################
#### KTX Timetable Parsing #################################
############################################################

## It should be done in python file.

############################################################
#### KTX Travel Time #######################################
############################################################

wait_penalty_minutes <- 30
station_candidate_distance_km <- 30
osrm_chunk_size <- 20

ktx_station_to_terminal_time <- read.csv(
    file = file.path(CSV, "ktx_station_to_terminal_time.csv"),
    fileEncoding = "UTF-8",
    check.names = FALSE
)

station_coord_raw <- read.csv(
    file = file.path(RAW, "국가철도공단_철도역 정보_20250711.csv"),
    fileEncoding = "UTF-8",
    check.names = FALSE
)

station_coord_manual <- tibble::tribble(
    ~station_name,        ~lon_epsg_4326,                ~lat_epsg_4326,
    "서대구역",           128 + 32 / 60 + 25.45 / 3600,  35 + 52 / 60 + 53.29 / 3600,
    "김천(구미)역",       128.180999088,                 36.113522147,
    "둔내역",             128 + 13 / 60 + 16 / 3600,     37 + 30 / 60 + 36 / 3600,
    "서원주역",           127 + 50 / 60 + 13.2 / 3600,   37 + 20 / 60 + 59.28 / 3600,
    "신해운대역",         129 + 10 / 60 + 32 / 3600,     35 + 10 / 60 + 54 / 3600,
    "진부역",             128 + 34 / 60 + 29 / 3600,     37 + 38 / 60 + 33 / 3600,
    "진부(오대산)역",     128 + 34 / 60 + 29 / 3600,     37 + 38 / 60 + 33 / 3600,
    "평창역",             128 + 25 / 60 + 48 / 3600,     37 + 33 / 60 + 44 / 3600,
    "횡성역",             128 + 0 / 60 + 37 / 3600,      37 + 28 / 60 + 58 / 3600,
    "북울산역",           129 + 22 / 60 + 20 / 3600,     35 + 36 / 60 + 53 / 3600
)

station_coord <- station_coord_raw %>%
    transmute(
        station_name = case_when(
            역이름 == "김천(구미)" ~ "김천(구미)역",
            TRUE ~ 역이름
        ),
        lon_epsg_4326 = as.numeric(경도좌표),
        lat_epsg_4326 = as.numeric(위도좌표)
    ) %>%
    filter(!station_name %in% station_coord_manual$station_name) %>%
    bind_rows(station_coord_manual) %>%
    semi_join(
        ktx_station_to_terminal_time %>%
            distinct(station_name),
        by = "station_name"
    ) %>%
    distinct(station_name, .keep_all = TRUE)

stopifnot(nrow(anti_join(
    ktx_station_to_terminal_time %>% distinct(station_name),
    station_coord,
    by = "station_name"
)) == 0)
stopifnot(sum(is.na(station_coord$lon_epsg_4326)) == 0)
stopifnot(sum(is.na(station_coord$lat_epsg_4326)) == 0)
stopifnot(sum(station_coord$lon_epsg_4326 == 0 | station_coord$lat_epsg_4326 == 0) == 0)
stopifnot(nrow(station_coord) == n_distinct(station_coord$station_name))

region_coord_sf <- region_coord %>%
    st_as_sf(
        coords = c("lon_epsg_4326", "lat_epsg_4326"),
        crs = 4326,
        remove = FALSE
    ) %>%
    st_transform(5179)

station_coord_sf <- station_coord %>%
    st_as_sf(
        coords = c("lon_epsg_4326", "lat_epsg_4326"),
        crs = 4326,
        remove = FALSE
    ) %>%
    st_transform(5179)

station_candidate_idx <- st_is_within_distance(
    region_coord_sf,
    station_coord_sf,
    dist = station_candidate_distance_km * 1000
)

region_station_candidate <- bind_rows(lapply(seq_along(station_candidate_idx), function(i) {
    idx <- station_candidate_idx[[i]]
    if (length(idx) == 0) {
        return(tibble())
    }

    tibble(
        region_sido = region_coord$region_sido[i],
        region_sigungu = region_coord$region_sigungu[i],
        station_name = station_coord$station_name[idx],
        distance_to_station_km = as.numeric(st_distance(
            region_coord_sf[i, ],
            station_coord_sf[idx, ]
        )) / 1000
    )
}))

region_station_car_time_parts <- list()
region_chunks <- split(
    seq_len(nrow(region_coord)),
    ceiling(seq_along(seq_len(nrow(region_coord))) / osrm_chunk_size)
)

for (i in seq_along(region_chunks)) {
    region_chunk <- region_coord[region_chunks[[i]], ]

    chunk_candidate <- region_station_candidate %>%
        semi_join(
            region_chunk %>%
                select(region_sido, region_sigungu),
            by = c("region_sido", "region_sigungu")
        )

    if (nrow(chunk_candidate) == 0) {
        next
    }

    station_chunk <- station_coord %>%
        semi_join(
            chunk_candidate %>%
                distinct(station_name),
            by = "station_name"
        )

    osrm_src <- region_chunk %>%
        select(lon = lon_epsg_4326, lat = lat_epsg_4326) %>%
        as.data.frame()

    osrm_dst <- station_chunk %>%
        select(lon = lon_epsg_4326, lat = lat_epsg_4326) %>%
        as.data.frame()

    region_key <- sprintf("region_%03d", seq_len(nrow(region_chunk)))
    station_key <- sprintf("station_%03d", seq_len(nrow(station_chunk)))

    rownames(osrm_src) <- region_key
    rownames(osrm_dst) <- station_key

    region_lookup <- region_chunk %>%
        mutate(region_key = region_key) %>%
        select(region_key, region_sido, region_sigungu)

    station_lookup <- station_chunk %>%
        mutate(station_key = station_key) %>%
        select(station_key, station_name)

    car_time_matrix <- osrmTable(
        src = osrm_src,
        dst = osrm_dst,
        measure = "duration"
    )

    region_station_car_time_parts[[length(region_station_car_time_parts) + 1]] <-
        as.data.frame(as.table(car_time_matrix$durations), stringsAsFactors = FALSE) %>%
        as_tibble() %>%
        rename(
            region_key = Var1,
            station_key = Var2,
            car_to_station_time = Freq
        ) %>%
        left_join(region_lookup, by = "region_key") %>%
        left_join(station_lookup, by = "station_key") %>%
        inner_join(
            chunk_candidate,
            by = c("region_sido", "region_sigungu", "station_name")
        ) %>%
        select(
            region_sido,
            region_sigungu,
            station_name,
            distance_to_station_km,
            car_to_station_time
        )
}

region_station_car_time <- bind_rows(region_station_car_time_parts)

stopifnot(sum(is.na(region_station_car_time$car_to_station_time)) == 0)

ktx_candidate_time <- region_station_car_time %>%
    inner_join(
        ktx_station_to_terminal_time,
        by = "station_name",
        relationship = "many-to-many"
    ) %>%
    mutate(
        selected_station = station_name,
        selected_terminal = terminal_station,
        wait_penalty = wait_penalty_minutes,
        train_travel_time_min = ktx_travel_time_min,
        train_travel_time_median = ktx_travel_time_median,
        train_travel_time_mean = ktx_travel_time_mean,
        ktx_travel_time_min = car_to_station_time + wait_penalty_minutes + train_travel_time_min,
        ktx_travel_time_median = car_to_station_time + wait_penalty_minutes + train_travel_time_median,
        ktx_travel_time_mean = car_to_station_time + wait_penalty_minutes + train_travel_time_mean
    )

travel_time_ktx_best <- ktx_candidate_time %>%
    group_by(region_sido, region_sigungu, year) %>%
    arrange(
        ktx_travel_time_min,
        interval_minutes,
        selected_station,
        selected_terminal,
        .by_group = TRUE
    ) %>%
    slice(1) %>%
    ungroup() %>%
    select(
        region_sido,
        region_sigungu,
        year,
        selected_station,
        selected_terminal,
        ktx_travel_time_min,
        ktx_travel_time_median,
        ktx_travel_time_mean,
        car_to_station_time,
        wait_penalty,
        train_travel_time_min,
        train_travel_time_median,
        train_travel_time_mean,
        interval_minutes,
        n_trains,
        distance_to_station_km
    )

region_year <- merge(
    region_coord %>%
        select(region_sido, region_sigungu),
    data.frame(year = sort(unique(ktx_station_to_terminal_time$year))),
    by = NULL
)

travel_time_ktx <- region_year %>%
    left_join(
        travel_time_ktx_best,
        by = c("region_sido", "region_sigungu", "year")
    ) %>%
    arrange(region_sido, region_sigungu, year)

stopifnot(nrow(travel_time_ktx) == nrow(region_coord) * n_distinct(ktx_station_to_terminal_time$year))
stopifnot(nrow(anti_join(
    merge_key,
    travel_time_ktx %>%
        distinct(region_sido, region_sigungu),
    by = c("region_sido", "region_sigungu")
)) == 0)
stopifnot(nrow(anti_join(
    travel_time_ktx %>%
        distinct(region_sido, region_sigungu),
    merge_key,
    by = c("region_sido", "region_sigungu")
)) == 0)

dbWriteTable(con, "travel_time_ktx", travel_time_ktx, overwrite = TRUE)

travel_time_ktx_parquet <- file.path(CLEAN, "travel_time_ktx.parquet")
travel_time_ktx_csv <- file.path(CSV, "travel_time_ktx.csv")

dbExecute(con, glue("COPY travel_time_ktx TO '{travel_time_ktx_parquet}' (FORMAT PARQUET)"))
dbExecute(con, glue("COPY travel_time_ktx TO '{travel_time_ktx_csv}' (FORMAT CSV)"))

############################################################
#### Final Merge ###########################################
############################################################

clean_travel_time <- travel_time_ktx %>%
    left_join(
        travel_time_car,
        by = c("region_sido", "region_sigungu")
    ) %>%
    mutate(
        travel_time = pmin(
            car_travel_time,
            ktx_travel_time_median,
            na.rm = TRUE
        )
    ) %>%
    arrange(region_sido, region_sigungu, year)

stopifnot(nrow(clean_travel_time) == nrow(region_coord) * n_distinct(ktx_station_to_terminal_time$year))
stopifnot(sum(is.na(clean_travel_time$car_travel_time)) == 0)
stopifnot(sum(is.na(clean_travel_time$travel_time)) == 0)
stopifnot(nrow(anti_join(
    merge_key,
    clean_travel_time %>%
        distinct(region_sido, region_sigungu),
    by = c("region_sido", "region_sigungu")
)) == 0)
stopifnot(nrow(anti_join(
    clean_travel_time %>%
        distinct(region_sido, region_sigungu),
    merge_key,
    by = c("region_sido", "region_sigungu")
)) == 0)

dbWriteTable(con, "clean_travel_time", clean_travel_time, overwrite = TRUE)

clean_travel_time_parquet <- file.path(CLEAN, "clean_travel_time.parquet")
clean_travel_time_csv <- file.path(CSV, "clean_travel_time.csv")

dbExecute(con, glue("COPY clean_travel_time TO '{clean_travel_time_parquet}' (FORMAT PARQUET)"))
dbExecute(con, glue("COPY clean_travel_time TO '{clean_travel_time_csv}' (FORMAT CSV)"))

dbDisconnect(con, shutdown = TRUE)
