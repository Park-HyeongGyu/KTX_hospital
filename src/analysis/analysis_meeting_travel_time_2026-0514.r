library(DBI)
library(duckdb)
library(dplyr)
library(fixest)
library(glue)

source("config.r")

setFixest_notes(FALSE)

con <- dbConnect(duckdb(), file.path(ROOT, "analysis_db.duckdb"))

MEETING <- file.path(ROOT, "memo", "2026-0514_미팅")

path_travel_time <- file.path(CLEAN, "clean_travel_time.parquet")
path_population <- file.path(CLEAN, "clean_population.parquet")
path_hospital <- file.path(CLEAN, "clean_hospital_by_type.parquet")
path_doctor <- file.path(CLEAN, "clean_doctor_by_level.parquet")

dbExecute(con, glue("
    CREATE OR REPLACE TABLE meeting_tt_travel AS
    WITH travel AS (
        SELECT
            region_sido,
            region_sigungu,
            region_sido || '_' || region_sigungu AS region,
            year,
            car_travel_time / 60.0 AS car_travel_time_hour,
            ktx_travel_time_median / 60.0 AS ktx_travel_time_median_hour,
            travel_time / 60.0 AS travel_time_hour,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 2.0
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within2h
        FROM read_parquet('{path_travel_time}')
    ),
    baseline AS (
        SELECT
            region_sido,
            region_sigungu,
            travel_time_hour AS travel_time_2007_hour
        FROM travel
        WHERE year = 2007
    )
    SELECT
        t.*,
        b.travel_time_2007_hour - t.travel_time_hour AS saving
    FROM travel AS t
    LEFT JOIN baseline AS b
        USING (region_sido, region_sigungu)
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE meeting_tt_population AS
    SELECT
        region_sido,
        region_sigungu,
        year,
        LN(population) AS log_population
    FROM read_parquet('{path_population}')
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE meeting_tt_hospital AS
    SELECT
        region_sido,
        region_sigungu,
        hospital_type,
        year,
        hospital_no,
        net_entry,
        exit_no,
        exit_rate,
        entry_no,
        entry_rate
    FROM read_parquet('{path_hospital}')
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE meeting_tt_doctor AS
    SELECT
        region_sido,
        region_sigungu,
        doctor_level,
        year,
        doctor_no
    FROM read_parquet('{path_doctor}')
    WHERE doctor_level IN ('인턴', '레지던트', '전문의', '일반의')
"))

hospital_panel <- dbGetQuery(con, "
    SELECT
        t.region,
        t.region_sido,
        t.region_sigungu,
        t.year,
        h.hospital_type,
        h.hospital_no,
        h.net_entry,
        h.exit_no,
        h.exit_rate,
        h.entry_no,
        h.entry_rate,
        t.travel_time_hour,
        t.saving,
        t.ktx_within2h,
        p.log_population
    FROM meeting_tt_hospital AS h
    INNER JOIN meeting_tt_travel AS t
        USING (region_sido, region_sigungu, year)
    INNER JOIN meeting_tt_population AS p
        USING (region_sido, region_sigungu, year)
    WHERE h.region_sido NOT IN ('서울', '경기', '인천', '제주')
    ORDER BY h.hospital_type, t.region, t.year
")

doctor_panel <- dbGetQuery(con, "
    SELECT
        t.region,
        t.region_sido,
        t.region_sigungu,
        t.year,
        d.doctor_level,
        d.doctor_no,
        t.travel_time_hour,
        t.saving,
        t.ktx_within2h,
        p.log_population
    FROM meeting_tt_doctor AS d
    INNER JOIN meeting_tt_travel AS t
        USING (region_sido, region_sigungu, year)
    INNER JOIN meeting_tt_population AS p
        USING (region_sido, region_sigungu, year)
    WHERE d.region_sido NOT IN ('서울', '경기', '인천', '제주')
    ORDER BY d.doctor_level, t.region, t.year
")

dbDisconnect(con, shutdown = TRUE)

hospital_types <- c("의원", "병원", "종합병원", "상급종합병원")
doctor_levels <- c("인턴", "레지던트", "전문의", "일반의")

hospital_outcomes <- c(
    hospital_no = "hospital_no",
    net_entry = "net_entry",
    exit_no = "exit_no",
    exit_rate = "exit_rate",
    entry_no = "entry_no",
    entry_rate = "entry_rate"
)

specs <- list(
    travel_time = list(
        label = "Travel Time",
        treatment = "travel_time_hour",
        dict = c("travel_time_hour" = "$TravelTime_{it}$")
    ),
    saving = list(
        label = "Saving",
        treatment = "saving",
        dict = c("saving" = "$Saving_{it}$")
    ),
    ktx_within2h = list(
        label = "KTX Within 2h",
        treatment = "ktx_within2h",
        dict = c("ktx_within2h" = "$KTXWithin2h_{it}$")
    )
)

fit_model <- function(data, outcome, treatment) {
    model_vars <- c(outcome, treatment, "log_population", "region", "year")
    df_model <- data[complete.cases(data[, model_vars]), ]

    if (
        nrow(df_model) == 0 ||
        length(unique(df_model$region)) < 2 ||
        length(unique(df_model$year)) < 2 ||
        length(unique(df_model[[outcome]])) <= 1
    ) {
        return(NULL)
    }

    formula <- as.formula(glue("{outcome} ~ {treatment} + log_population | region + year"))
    model <- feols(formula, data = df_model, cluster = ~region)
    attr(model, "n_regions") <- length(unique(df_model$region))

    model
}

write_model_table <- function(models, file_name, treatment, dict) {
    file_path <- file.path(MEETING, file_name)

    if (length(models) == 0) {
        writeLines("% No model was estimated.", file_path)
        return(invisible(file_path))
    }

    region_counts <- vapply(
        models,
        function(model) as.character(attr(model, "n_regions")),
        character(1)
    )

    tex <- etable(
        models,
        tex = TRUE,
        style.tex = style.tex("aer", tablefoot = FALSE),
        headers = names(models),
        depvar = FALSE,
        keep_raw = paste0("^", treatment, "$"),
        coefstat = "se",
        se.below = TRUE,
        fitstat = ~n + ar2,
        drop.section = "fixef",
        extralines = list(
            "Log population control" = rep("Yes", length(models)),
            "Region FE" = rep("Yes", length(models)),
            "Year FE" = rep("Yes", length(models)),
            "Regions" = region_counts
        ),
        dict = dict,
        signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
    )

    writeLines(tex, file_path)
    invisible(file_path)
}

make_hospital_table <- function(spec_name, spec, hospital_type) {
    df <- hospital_panel %>%
        filter(hospital_type == !!hospital_type) %>%
        group_by(region) %>%
        filter(sum(hospital_no, na.rm = TRUE) > 0) %>%
        ungroup() %>%
        mutate(hospital_no_log = log(hospital_no + 1))

    outcome_vars <- c(
        hospital_no = "hospital_no_log",
        net_entry = "net_entry",
        exit_no = "exit_no",
        exit_rate = "exit_rate",
        entry_no = "entry_no",
        entry_rate = "entry_rate"
    )

    models <- list()
    for (outcome_name in names(outcome_vars)) {
        model <- fit_model(df, outcome_vars[[outcome_name]], spec$treatment)
        if (!is.null(model)) {
            models[[outcome_name]] <- model
        }
    }

    file_stub <- c(
        "의원" = "clinic",
        "병원" = "secondary",
        "종합병원" = "general",
        "상급종합병원" = "tertiary"
    )[[hospital_type]]

    write_model_table(
        models,
        glue("meeting_tt_{spec_name}_hospital_{file_stub}.tex"),
        spec$treatment,
        spec$dict
    )
}

make_doctor_table <- function(spec_name, spec) {
    models <- list()

    for (doctor_level in doctor_levels) {
        df <- doctor_panel %>%
            filter(doctor_level == !!doctor_level) %>%
            mutate(doctor_no_log = log(doctor_no + 1))

        model <- fit_model(df, "doctor_no_log", spec$treatment)
        if (!is.null(model)) {
            models[[doctor_level]] <- model
        }
    }

    write_model_table(
        models,
        glue("meeting_tt_{spec_name}_doctor.tex"),
        spec$treatment,
        spec$dict
    )
}

for (spec_name in names(specs)) {
    spec <- specs[[spec_name]]

    for (hospital_type in hospital_types) {
        make_hospital_table(spec_name, spec, hospital_type)
    }

    make_doctor_table(spec_name, spec)
}
