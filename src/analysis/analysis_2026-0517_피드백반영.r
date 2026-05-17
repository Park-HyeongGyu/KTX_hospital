library(DBI)
library(duckdb)
library(dplyr)
library(fixest)
library(glue)

source("config.r")

setFixest_notes(FALSE)

con <- dbConnect(duckdb(), file.path(ROOT, "analysis_db.duckdb"))

REPORT <- file.path(ROOT, "memo", "2026-0517_피드백반영")
TABLES <- file.path(REPORT, "tables")

dir.create(REPORT, recursive = TRUE, showWarnings = FALSE)
dir.create(TABLES, recursive = TRUE, showWarnings = FALSE)

path_travel_time <- file.path(CLEAN, "clean_travel_time.parquet")
path_population <- file.path(CLEAN, "clean_population.parquet")
path_hospital <- file.path(CLEAN, "clean_hospital_by_type.parquet")
path_doctor <- file.path(CLEAN, "clean_doctor_by_level.parquet")

dbExecute(con, glue("
    CREATE OR REPLACE TABLE feedback_travel AS
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
            END AS ktx_within2h,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 1.0
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within1h,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 1.5
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within1p5h,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 2.5
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within2p5h,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 3.0
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within3h,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 3.5
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within3p5h,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 4.0
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within4h
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
    CREATE OR REPLACE TABLE feedback_population AS
    SELECT
        region_sido,
        region_sigungu,
        year,
        population
    FROM read_parquet('{path_population}')
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE feedback_hospital AS
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
    CREATE OR REPLACE TABLE feedback_doctor AS
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
        p.population,
        t.travel_time_hour,
        t.saving,
        t.ktx_within2h,
        t.ktx_within1h,
        t.ktx_within1p5h,
        t.ktx_within2p5h,
        t.ktx_within3h,
        t.ktx_within3p5h,
        t.ktx_within4h
    FROM feedback_hospital AS h
    INNER JOIN feedback_travel AS t
        USING (region_sido, region_sigungu, year)
    INNER JOIN feedback_population AS p
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
        p.population,
        t.travel_time_hour,
        t.saving,
        t.ktx_within2h,
        t.ktx_within1h,
        t.ktx_within1p5h,
        t.ktx_within2p5h,
        t.ktx_within3h,
        t.ktx_within3p5h,
        t.ktx_within4h
    FROM feedback_doctor AS d
    INNER JOIN feedback_travel AS t
        USING (region_sido, region_sigungu, year)
    INNER JOIN feedback_population AS p
        USING (region_sido, region_sigungu, year)
    WHERE d.region_sido NOT IN ('서울', '경기', '인천', '제주')
    ORDER BY d.doctor_level, t.region, t.year
")

dbDisconnect(con, shutdown = TRUE)

hospital_types <- c("의원", "병원", "종합병원", "상급종합병원")
doctor_levels <- c("인턴", "레지던트", "전문의", "일반의")

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
    model_vars <- c(outcome, treatment, "region", "year")
    df_model <- data[complete.cases(data[, model_vars]), ]

    if (
        nrow(df_model) == 0 ||
        length(unique(df_model$region)) < 2 ||
        length(unique(df_model$year)) < 2 ||
        length(unique(df_model[[outcome]])) <= 1
    ) {
        return(NULL)
    }

    formula <- as.formula(glue("{outcome} ~ {treatment} | region + year"))
    model <- feols(formula, data = df_model, cluster = ~region)
    attr(model, "n_regions") <- length(unique(df_model$region))

    model
}

write_model_table <- function(models, file_name, treatment, dict) {
    file_path <- file.path(TABLES, file_name)

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
            "Log population control" = rep("No", length(models)),
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
        mutate(
            hospital_no_per10k = hospital_no / population * 10000,
            net_entry_per10k = net_entry / population * 10000,
            exit_no_per10k = exit_no / population * 10000,
            entry_no_per10k = entry_no / population * 10000
        )

    outcome_vars <- c(
        hospital_no = "hospital_no_per10k",
        net_entry = "net_entry_per10k",
        exit_no = "exit_no_per10k",
        exit_rate = "exit_rate",
        entry_no = "entry_no_per10k",
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
        glue("pc_{spec_name}_hospital_{file_stub}.tex"),
        spec$treatment,
        spec$dict
    )
}

make_doctor_table <- function(spec_name, spec) {
    models <- list()

    for (doctor_level in doctor_levels) {
        df <- doctor_panel %>%
            filter(doctor_level == !!doctor_level) %>%
            mutate(doctor_no_per10k = doctor_no / population * 10000)

        model <- fit_model(df, "doctor_no_per10k", spec$treatment)
        if (!is.null(model)) {
            models[[doctor_level]] <- model
        }
    }

    write_model_table(
        models,
        glue("pc_{spec_name}_doctor.tex"),
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

fit_difference_model <- function(data, outcome) {
    model_vars <- c(outcome, "saving", "log_population_diff_2007", "region", "year")
    df_model <- data[complete.cases(data[, model_vars]), ]

    if (
        nrow(df_model) == 0 ||
        length(unique(df_model$region)) < 2 ||
        length(unique(df_model$year)) < 2 ||
        length(unique(df_model[[outcome]])) <= 1
    ) {
        return(NULL)
    }

    model <- feols(
        as.formula(glue("{outcome} ~ saving + log_population_diff_2007 | region + year")),
        data = df_model,
        cluster = ~region
    )
    attr(model, "n_regions") <- length(unique(df_model$region))

    model
}

write_difference_table <- function(models, file_name) {
    file_path <- file.path(TABLES, file_name)

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
        keep_raw = "^saving$",
        coefstat = "se",
        se.below = TRUE,
        fitstat = ~n + ar2,
        drop.section = "fixef",
        extralines = list(
            "Log population difference control" = rep("Yes", length(models)),
            "Region FE" = rep("Yes", length(models)),
            "Year FE" = rep("Yes", length(models)),
            "Regions" = region_counts
        ),
        dict = c("saving" = "$Saving_{it}$"),
        signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
    )

    writeLines(tex, file_path)
    invisible(file_path)
}

make_difference_hospital_table <- function() {
    models <- list()

    for (hospital_type in hospital_types) {
        df <- hospital_panel %>%
            filter(hospital_type == !!hospital_type) %>%
            group_by(region) %>%
            filter(sum(hospital_no, na.rm = TRUE) > 0) %>%
            arrange(year, .by_group = TRUE) %>%
            mutate(
                hospital_no_2007 = hospital_no[year == 2007][1],
                log_population_2007 = log(population[year == 2007][1]),
                hospital_no_diff_2007 = hospital_no - hospital_no_2007,
                log_population_diff_2007 = log(population) - log_population_2007
            ) %>%
            ungroup()

        model <- fit_difference_model(df, "hospital_no_diff_2007")
        if (!is.null(model)) {
            models[[hospital_type]] <- model
        }
    }

    write_difference_table(models, "diff2007_saving_hospital.tex")
}

make_difference_doctor_table <- function() {
    models <- list()

    for (doctor_level in doctor_levels) {
        df <- doctor_panel %>%
            filter(doctor_level == !!doctor_level) %>%
            group_by(region) %>%
            arrange(year, .by_group = TRUE) %>%
            mutate(
                doctor_no_2007 = doctor_no[year == 2007][1],
                log_population_2007 = log(population[year == 2007][1]),
                doctor_no_diff_2007 = doctor_no - doctor_no_2007,
                log_population_diff_2007 = log(population) - log_population_2007
            ) %>%
            ungroup()

        model <- fit_difference_model(df, "doctor_no_diff_2007")
        if (!is.null(model)) {
            models[[doctor_level]] <- model
        }
    }

    write_difference_table(models, "diff2007_saving_doctor.tex")
}

make_difference_hospital_table()
make_difference_doctor_table()

population_panel <- hospital_panel %>%
    select(
        region,
        region_sido,
        region_sigungu,
        year,
        population,
        travel_time_hour,
        saving,
        ktx_within2h,
        ktx_within1h,
        ktx_within1p5h,
        ktx_within2p5h,
        ktx_within3h,
        ktx_within3p5h,
        ktx_within4h
    ) %>%
    distinct() %>%
    mutate(log_population = log(population))

fit_population_model <- function(data, treatment) {
    model_vars <- c("log_population", treatment, "region", "year")
    df_model <- data[complete.cases(data[, model_vars]), ]

    if (
        nrow(df_model) == 0 ||
        length(unique(df_model$region)) < 2 ||
        length(unique(df_model$year)) < 2 ||
        length(unique(df_model$log_population)) <= 1
    ) {
        return(NULL)
    }

    model <- tryCatch(
        feols(
            as.formula(glue("log_population ~ {treatment} | region + year")),
            data = df_model,
            cluster = ~region
        ),
        error = function(e) NULL
    )
    if (is.null(model)) {
        return(NULL)
    }

    attr(model, "n_regions") <- length(unique(df_model$region))

    model
}

population_models <- list()
for (spec_name in names(specs)) {
    spec <- specs[[spec_name]]
    model <- fit_population_model(population_panel, spec$treatment)
    if (!is.null(model)) {
        population_models[[spec$label]] <- model
    }
}

population_region_counts <- vapply(
    population_models,
    function(model) as.character(attr(model, "n_regions")),
    character(1)
)

population_tex <- etable(
    population_models,
    tex = TRUE,
    style.tex = style.tex("aer", tablefoot = FALSE),
    headers = names(population_models),
    depvar = FALSE,
    keep_raw = "^(travel_time_hour|saving|ktx_within2h)$",
    coefstat = "se",
    se.below = TRUE,
    fitstat = ~n + ar2,
    drop.section = "fixef",
    extralines = list(
        "Region FE" = rep("Yes", length(population_models)),
        "Year FE" = rep("Yes", length(population_models)),
        "Regions" = population_region_counts
    ),
    dict = c(
        "travel_time_hour" = "$TravelTime_{it}$",
        "saving" = "$Saving_{it}$",
        "ktx_within2h" = "$KTXWithin2h_{it}$"
    ),
    signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
)

writeLines(population_tex, file.path(TABLES, "population_as_outcome.tex"))

population_threshold_specs <- list(
    "1h" = "ktx_within1h",
    "1.5h" = "ktx_within1p5h",
    "2h" = "ktx_within2h",
    "2.5h" = "ktx_within2p5h",
    "3h" = "ktx_within3h",
    "3.5h" = "ktx_within3p5h",
    "4h" = "ktx_within4h"
)

population_threshold_models <- list()
for (threshold_label in names(population_threshold_specs)) {
    treatment <- population_threshold_specs[[threshold_label]]
    model <- fit_population_model(population_panel, treatment)
    if (!is.null(model)) {
        population_threshold_models[[threshold_label]] <- model
    }
}

population_threshold_region_counts <- vapply(
    population_threshold_models,
    function(model) as.character(attr(model, "n_regions")),
    character(1)
)

population_threshold_tex <- etable(
    population_threshold_models,
    tex = TRUE,
    style.tex = style.tex("aer", tablefoot = FALSE),
    headers = names(population_threshold_models),
    depvar = FALSE,
    keep_raw = paste0("^(", paste(unname(population_threshold_specs), collapse = "|"), ")$"),
    coefstat = "se",
    se.below = TRUE,
    fitstat = ~n + ar2,
    drop.section = "fixef",
    extralines = list(
        "Region FE" = rep("Yes", length(population_threshold_models)),
        "Year FE" = rep("Yes", length(population_threshold_models)),
        "Regions" = population_threshold_region_counts
    ),
    dict = c(
        "ktx_within1h" = "$KTXWithin1h_{it}$",
        "ktx_within1p5h" = "$KTXWithin1.5h_{it}$",
        "ktx_within2h" = "$KTXWithin2h_{it}$",
        "ktx_within2p5h" = "$KTXWithin2.5h_{it}$",
        "ktx_within3h" = "$KTXWithin3h_{it}$",
        "ktx_within3p5h" = "$KTXWithin3.5h_{it}$",
        "ktx_within4h" = "$KTXWithin4h_{it}$"
    ),
    signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
)

writeLines(population_threshold_tex, file.path(TABLES, "population_as_outcome_ktx_thresholds.tex"))

hospital_type_stubs <- c(
    "의원" = "clinic",
    "병원" = "secondary",
    "종합병원" = "general",
    "상급종합병원" = "tertiary"
)

hospital_outcome_dict <- c(
    "hospital_no_log" = "$\\log(HospitalNo_{it} + 1)$",
    "hospital_no_per10k" = "$HospitalNo_{it}$ per 10,000",
    "net_entry" = "$NetEntry_{it}$",
    "net_entry_per10k" = "$NetEntry_{it}$ per 10,000",
    "exit_no" = "$ExitNo_{it}$",
    "exit_no_per10k" = "$ExitNo_{it}$ per 10,000",
    "exit_rate" = "$ExitRate_{it}$",
    "entry_no" = "$EntryNo_{it}$",
    "entry_no_per10k" = "$EntryNo_{it}$ per 10,000",
    "entry_rate" = "$EntryRate_{it}$",
    "travel_time_hour" = "$TravelTime_{it}$",
    "saving" = "$Saving_{it}$",
    "ktx_within2h" = "$KTXWithin2h_{it}$",
    "log_population" = "$\\log(Population_{it})$"
)

fit_model_with_log_population <- function(data, outcome, treatment) {
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

write_model_table_with_log_population <- function(models, file_name, treatment) {
    file_path <- file.path(TABLES, file_name)

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
        keep_raw = paste0("^(", treatment, "|log_population)$"),
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
        dict = hospital_outcome_dict,
        signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
    )

    writeLines(tex, file_path)
    invisible(file_path)
}

make_appendix_meeting_hospital_table <- function(spec_name, spec, hospital_type) {
    df <- hospital_panel %>%
        filter(hospital_type == !!hospital_type) %>%
        mutate(
            hospital_no_log = log(hospital_no + 1),
            log_population = log(population)
        )

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
        model <- fit_model_with_log_population(df, outcome_vars[[outcome_name]], spec$treatment)
        if (!is.null(model)) {
            models[[outcome_name]] <- model
        }
    }

    write_model_table_with_log_population(
        models,
        glue("appendix_all_regions_{spec_name}_hospital_{hospital_type_stubs[[hospital_type]]}.tex"),
        spec$treatment
    )
}

make_appendix_per_capita_hospital_table <- function(spec_name, spec, hospital_type) {
    df <- hospital_panel %>%
        filter(hospital_type == !!hospital_type) %>%
        mutate(
            hospital_no_per10k = hospital_no / population * 10000,
            net_entry_per10k = net_entry / population * 10000,
            exit_no_per10k = exit_no / population * 10000,
            entry_no_per10k = entry_no / population * 10000
        )

    outcome_vars <- c(
        hospital_no = "hospital_no_per10k",
        net_entry = "net_entry_per10k",
        exit_no = "exit_no_per10k",
        exit_rate = "exit_rate",
        entry_no = "entry_no_per10k",
        entry_rate = "entry_rate"
    )

    models <- list()
    for (outcome_name in names(outcome_vars)) {
        model <- fit_model(df, outcome_vars[[outcome_name]], spec$treatment)
        if (!is.null(model)) {
            models[[outcome_name]] <- model
        }
    }

    write_model_table(
        models,
        glue("appendix_all_regions_pc_{spec_name}_hospital_{hospital_type_stubs[[hospital_type]]}.tex"),
        spec$treatment,
        c(spec$dict, hospital_outcome_dict)
    )
}

make_appendix_difference_hospital_table <- function() {
    models <- list()

    for (hospital_type in hospital_types) {
        df <- hospital_panel %>%
            filter(hospital_type == !!hospital_type) %>%
            group_by(region) %>%
            arrange(year, .by_group = TRUE) %>%
            mutate(
                hospital_no_2007 = hospital_no[year == 2007][1],
                log_population_2007 = log(population[year == 2007][1]),
                hospital_no_diff_2007 = hospital_no - hospital_no_2007,
                log_population_diff_2007 = log(population) - log_population_2007
            ) %>%
            ungroup()

        model <- fit_difference_model(df, "hospital_no_diff_2007")
        if (!is.null(model)) {
            models[[hospital_type]] <- model
        }
    }

    write_difference_table(models, "appendix_all_regions_diff2007_saving_hospital.tex")
}

for (spec_name in names(specs)) {
    spec <- specs[[spec_name]]

    for (hospital_type in hospital_types) {
        make_appendix_meeting_hospital_table(spec_name, spec, hospital_type)
        make_appendix_per_capita_hospital_table(spec_name, spec, hospital_type)
    }
}

make_appendix_difference_hospital_table()
