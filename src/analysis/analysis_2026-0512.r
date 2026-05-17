library(DBI)
library(duckdb)
library(dplyr)
library(fixest)
library(glue)
library(ggplot2)

source("config.r")

setFixest_notes(FALSE)

con <- dbConnect(duckdb(), file.path(ROOT, "analysis_db.duckdb"))

REPORT <- file.path(ROOT, "temp", "2026-0512")
TABLES <- file.path(REPORT, "tables")
FIGURES <- file.path(REPORT, "figures")

dir.create(REPORT, recursive = TRUE, showWarnings = FALSE)
dir.create(TABLES, recursive = TRUE, showWarnings = FALSE)
dir.create(FIGURES, recursive = TRUE, showWarnings = FALSE)

path_travel_time <- file.path(CLEAN, "clean_travel_time.parquet")
path_population <- file.path(CLEAN, "clean_population.parquet")
path_hospital <- file.path(CLEAN, "clean_hospital_by_type.parquet")
path_doctor <- file.path(CLEAN, "clean_doctor_by_level.parquet")

############################################################
#### Build Analysis Panel ##################################
############################################################

dbExecute(con, glue("
    CREATE OR REPLACE TABLE analysis_travel_time AS
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
                WHEN travel_time / 60.0 <= 1.5 THEN 1 ELSE 0
            END AS within1p5h,
            CASE
                WHEN travel_time / 60.0 <= 2.0 THEN 1 ELSE 0
            END AS within2h,
            CASE
                WHEN travel_time / 60.0 <= 2.5 THEN 1 ELSE 0
            END AS within2p5h,
            CASE
                WHEN travel_time / 60.0 <= 3.0 THEN 1 ELSE 0
            END AS within3h,
            CASE
                WHEN ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_chosen,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 1.5
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within1p5h,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 2.0
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within2h,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 2.5
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within2p5h,
            CASE
                WHEN ktx_travel_time_median / 60.0 <= 3.0
                 AND ktx_travel_time_median < car_travel_time THEN 1 ELSE 0
            END AS ktx_within3h
        FROM read_parquet('{path_travel_time}')
    ),
    baseline AS (
        SELECT
            region_sido,
            region_sigungu,
            travel_time_hour AS travel_time_2007_hour,
            within1p5h AS within1p5h_2007,
            within2h AS within2h_2007,
            within2p5h AS within2p5h_2007,
            within3h AS within3h_2007,
            ktx_chosen AS ktx_chosen_2007,
            ktx_within1p5h AS ktx_within1p5h_2007,
            ktx_within2h AS ktx_within2h_2007,
            ktx_within2p5h AS ktx_within2p5h_2007,
            ktx_within3h AS ktx_within3h_2007
        FROM travel
        WHERE year = 2007
    ),
    lagged AS (
        SELECT
            *,
            LAG(travel_time_hour) OVER (
                PARTITION BY region
                ORDER BY year
            ) AS travel_time_lag_hour
        FROM travel
    )
    SELECT
        l.*,
        b.travel_time_2007_hour,
        b.within1p5h_2007,
        b.within2h_2007,
        b.within2p5h_2007,
        b.within3h_2007,
        b.ktx_chosen_2007,
        b.ktx_within1p5h_2007,
        b.ktx_within2h_2007,
        b.ktx_within2p5h_2007,
        b.ktx_within3h_2007,
        b.travel_time_2007_hour - l.travel_time_hour AS saving,
        GREATEST(0, b.travel_time_2007_hour - 1.5)
            - GREATEST(0, l.travel_time_hour - 1.5) AS saving_to_1p5h,
        GREATEST(0, b.travel_time_2007_hour - 2.0)
            - GREATEST(0, l.travel_time_hour - 2.0) AS saving_to_2h,
        GREATEST(0, b.travel_time_2007_hour - 2.5)
            - GREATEST(0, l.travel_time_hour - 2.5) AS saving_to_2p5h,
        GREATEST(0, b.travel_time_2007_hour - 3.0)
            - GREATEST(0, l.travel_time_hour - 3.0) AS saving_to_3h,
        CASE
            WHEN l.travel_time_lag_hour IS NULL THEN NULL
            ELSE l.travel_time_lag_hour - l.travel_time_hour
        END AS shock_saving,
        CASE
            WHEN l.travel_time_lag_hour IS NULL THEN NULL
            WHEN l.travel_time_lag_hour > 1.5
             AND l.travel_time_hour <= 1.5 THEN 1 ELSE 0
        END AS cross1p5h,
        CASE
            WHEN l.travel_time_lag_hour IS NULL THEN NULL
            WHEN l.travel_time_lag_hour > 2.0
             AND l.travel_time_hour <= 2.0 THEN 1 ELSE 0
        END AS cross2h,
        CASE
            WHEN l.travel_time_lag_hour IS NULL THEN NULL
            WHEN l.travel_time_lag_hour > 2.5
             AND l.travel_time_hour <= 2.5 THEN 1 ELSE 0
        END AS cross2p5h,
        CASE
            WHEN l.travel_time_lag_hour IS NULL THEN NULL
            WHEN l.travel_time_lag_hour > 3.0
             AND l.travel_time_hour <= 3.0 THEN 1 ELSE 0
        END AS cross3h,
        CASE
            WHEN b.within2h_2007 = 1 OR b.ktx_chosen_2007 = 1 THEN 1 ELSE 0
        END AS already_treated_2007
    FROM lagged AS l
    LEFT JOIN baseline AS b
        USING (region_sido, region_sigungu)
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE analysis_population AS
    SELECT
        region_sido,
        region_sigungu,
        year,
        population,
        LOG(population) AS log_population
    FROM read_parquet('{path_population}')
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE analysis_hospital AS
    SELECT
        region_sido,
        region_sigungu,
        year,
        MAX(CASE WHEN hospital_type = '상급종합병원' THEN hospital_no END)
            AS tertiary_hospital_no,
        MAX(CASE WHEN hospital_type = '종합병원' THEN hospital_no END)
            AS general_hospital_no,
        MAX(CASE WHEN hospital_type = '의원' THEN hospital_no END)
            AS clinic_no,
        MAX(CASE WHEN hospital_type = '병원' THEN hospital_no END)
            AS secondary_hospital_no,
        MAX(CASE WHEN hospital_type = '상급종합병원' THEN net_entry END)
            AS tertiary_net_entry,
        MAX(CASE WHEN hospital_type = '종합병원' THEN net_entry END)
            AS general_net_entry,
        MAX(CASE WHEN hospital_type = '의원' THEN net_entry END)
            AS clinic_net_entry,
        MAX(CASE WHEN hospital_type = '병원' THEN net_entry END)
            AS secondary_net_entry,
        MAX(CASE WHEN hospital_type = '상급종합병원' THEN exit_no END)
            AS tertiary_exit_no,
        MAX(CASE WHEN hospital_type = '종합병원' THEN exit_no END)
            AS general_exit_no,
        MAX(CASE WHEN hospital_type = '의원' THEN exit_no END)
            AS clinic_exit_no,
        MAX(CASE WHEN hospital_type = '병원' THEN exit_no END)
            AS secondary_exit_no,
        MAX(CASE WHEN hospital_type = '상급종합병원' THEN exit_rate END)
            AS tertiary_exit_rate,
        MAX(CASE WHEN hospital_type = '종합병원' THEN exit_rate END)
            AS general_exit_rate,
        MAX(CASE WHEN hospital_type = '의원' THEN exit_rate END)
            AS clinic_exit_rate,
        MAX(CASE WHEN hospital_type = '병원' THEN exit_rate END)
            AS secondary_exit_rate,
        MAX(CASE WHEN hospital_type = '상급종합병원' THEN entry_no END)
            AS tertiary_entry_no,
        MAX(CASE WHEN hospital_type = '종합병원' THEN entry_no END)
            AS general_entry_no,
        MAX(CASE WHEN hospital_type = '의원' THEN entry_no END)
            AS clinic_entry_no,
        MAX(CASE WHEN hospital_type = '병원' THEN entry_no END)
            AS secondary_entry_no,
        MAX(CASE WHEN hospital_type = '상급종합병원' THEN entry_rate END)
            AS tertiary_entry_rate,
        MAX(CASE WHEN hospital_type = '종합병원' THEN entry_rate END)
            AS general_entry_rate,
        MAX(CASE WHEN hospital_type = '의원' THEN entry_rate END)
            AS clinic_entry_rate,
        MAX(CASE WHEN hospital_type = '병원' THEN entry_rate END)
            AS secondary_entry_rate
    FROM read_parquet('{path_hospital}')
    GROUP BY region_sido, region_sigungu, year
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE analysis_doctor AS
    SELECT
        region_sido,
        region_sigungu,
        year,
        MAX(CASE WHEN doctor_level = '인턴' THEN doctor_no END)
            AS intern_no,
        MAX(CASE WHEN doctor_level = '레지던트' THEN doctor_no END)
            AS resident_no,
        MAX(CASE WHEN doctor_level = '전문의' THEN doctor_no END)
            AS specialist_no,
        MAX(CASE WHEN doctor_level = '일반의' THEN doctor_no END)
            AS gp_no
    FROM read_parquet('{path_doctor}')
    GROUP BY region_sido, region_sigungu, year
"))

dbExecute(con, "
    CREATE OR REPLACE TABLE analysis_panel AS
    SELECT
        t.*,
        p.population,
        p.log_population,
        h.tertiary_hospital_no,
        h.general_hospital_no,
        h.clinic_no,
        h.secondary_hospital_no,
        h.tertiary_net_entry,
        h.general_net_entry,
        h.clinic_net_entry,
        h.secondary_net_entry,
        h.tertiary_exit_no,
        h.general_exit_no,
        h.clinic_exit_no,
        h.secondary_exit_no,
        h.tertiary_exit_rate,
        h.general_exit_rate,
        h.clinic_exit_rate,
        h.secondary_exit_rate,
        h.tertiary_entry_no,
        h.general_entry_no,
        h.clinic_entry_no,
        h.secondary_entry_no,
        h.tertiary_entry_rate,
        h.general_entry_rate,
        h.clinic_entry_rate,
        h.secondary_entry_rate,
        d.intern_no,
        d.resident_no,
        d.specialist_no,
        d.gp_no
    FROM analysis_travel_time AS t
    LEFT JOIN analysis_population AS p
        USING (region_sido, region_sigungu, year)
    LEFT JOIN analysis_hospital AS h
        USING (region_sido, region_sigungu, year)
    LEFT JOIN analysis_doctor AS d
        USING (region_sido, region_sigungu, year)
    WHERE t.region_sido NOT IN ('서울', '경기', '인천', '제주')
")

panel <- dbGetQuery(con, "
    SELECT *
    FROM analysis_panel
    ORDER BY region, year
")

stopifnot(nrow(panel) > 0)
stopifnot(sum(is.na(panel$travel_time_hour)) == 0)
stopifnot(sum(is.na(panel$log_population)) == 0)

############################################################
#### Regression Helpers ####################################
############################################################

hospital_outcomes <- list(
    "상급종합병원" = "tertiary_hospital_no",
    "종합병원" = "general_hospital_no",
    "의원" = "clinic_no",
    "병원" = "secondary_hospital_no"
)

hospital_sample_outcomes <- hospital_outcomes

additional_hospital_outcome_sets <- list(
    net_entry = list(
        label = "Net Entry",
        equation_label = "NetEntry",
        outcomes = list(
            "상급종합병원" = "tertiary_net_entry",
            "종합병원" = "general_net_entry",
            "의원" = "clinic_net_entry",
            "병원" = "secondary_net_entry"
        )
    ),
    exit_no = list(
        label = "Exit Count",
        equation_label = "Exit",
        outcomes = list(
            "상급종합병원" = "tertiary_exit_no",
            "종합병원" = "general_exit_no",
            "의원" = "clinic_exit_no",
            "병원" = "secondary_exit_no"
        )
    ),
    exit_rate = list(
        label = "Exit Rate",
        equation_label = "ExitRate",
        outcomes = list(
            "상급종합병원" = "tertiary_exit_rate",
            "종합병원" = "general_exit_rate",
            "의원" = "clinic_exit_rate",
            "병원" = "secondary_exit_rate"
        )
    ),
    entry_no = list(
        label = "Entry Count",
        equation_label = "Entry",
        outcomes = list(
            "상급종합병원" = "tertiary_entry_no",
            "종합병원" = "general_entry_no",
            "의원" = "clinic_entry_no",
            "병원" = "secondary_entry_no"
        )
    ),
    entry_rate = list(
        label = "Entry Rate",
        equation_label = "EntryRate",
        outcomes = list(
            "상급종합병원" = "tertiary_entry_rate",
            "종합병원" = "general_entry_rate",
            "의원" = "clinic_entry_rate",
            "병원" = "secondary_entry_rate"
        )
    )
)

doctor_outcomes <- list(
    "인턴" = "intern_no",
    "레지던트" = "resident_no",
    "전문의" = "specialist_no",
    "일반의" = "gp_no"
)

coef_dict <- c(
    "travel_time_hour" = "$TravelTime_{it}$",
    "saving" = "$Saving_{it}$",
    "within1p5h" = "$Within1.5h_{it}$",
    "within2h" = "$Within2h_{it}$",
    "within2p5h" = "$Within2.5h_{it}$",
    "within3h" = "$Within3h_{it}$",
    "ktx_within1p5h" = "$KTXWithin1.5h_{it}$",
    "ktx_within2h" = "$KTXWithin2h_{it}$",
    "ktx_within2p5h" = "$KTXWithin2.5h_{it}$",
    "ktx_within3h" = "$KTXWithin3h_{it}$",
    "saving_to_2h" = "$SavingTo2h_{it}$",
    "shock_saving" = "$ShockSaving_{it}$",
    "cross2h" = "$Cross2h_{it}$",
    "ktx_chosen" = "$KTXChosen_{it}$"
)

regression_log <- list()
lp_coefficients <- list()

add_log <- function(entry) {
    regression_log[[length(regression_log) + 1]] <<- entry
}

clean_sample <- function(data, filter_fun) {
    if (is.null(filter_fun)) {
        return(data)
    }

    keep <- filter_fun(data)
    keep[is.na(keep)] <- FALSE
    data[keep, ]
}

make_lp_outcome <- function(data, outcome_var, horizon) {
    data %>%
        arrange(region, year) %>%
        group_by(region) %>%
        mutate(
            y_level = log(.data[[outcome_var]] + 1),
            y = dplyr::lead(y_level, n = horizon) - dplyr::lag(y_level, n = 1)
        ) %>%
        ungroup()
}

make_lp_outcome_level <- function(data, outcome_var, horizon) {
    data %>%
        arrange(region, year) %>%
        group_by(region) %>%
        mutate(
            y = dplyr::lead(.data[[outcome_var]], n = horizon) -
                dplyr::lag(.data[[outcome_var]], n = 1)
        ) %>%
        ungroup()
}

run_outcome_models <- function(
    data,
    outcomes,
    outcome_group,
    spec_id,
    sample_label,
    treatment_vars,
    filter_fun = NULL,
    horizon = NULL
) {
    models <- list()

    for (outcome_label in names(outcomes)) {
        outcome_var <- outcomes[[outcome_label]]
        df_reg <- clean_sample(data, filter_fun)

        dropped_regions <- character(0)
        always_zero_regions <- character(0)

        region_sum <- tapply(
            df_reg[[outcome_var]],
            df_reg$region,
            function(x) sum(x, na.rm = TRUE)
        )

        if (outcome_group == "hospital") {
            dropped_regions <- names(region_sum)[region_sum <= 0]
            df_reg <- df_reg[df_reg$region %in% names(region_sum)[region_sum > 0], ]
        } else {
            always_zero_regions <- names(region_sum)[region_sum <= 0]
        }

        if (is.null(horizon)) {
            df_reg$y <- log(df_reg[[outcome_var]] + 1)
        } else {
            df_reg <- make_lp_outcome(df_reg, outcome_var, horizon)
        }

        rhs_vars <- c(treatment_vars, "log_population")
        model_vars <- c("y", rhs_vars, "region", "year")
        df_model <- df_reg[complete.cases(df_reg[, model_vars]), ]

        status <- "estimated"
        note <- ""
        model <- NULL

        if (
            nrow(df_model) == 0 ||
            length(unique(df_model$region)) < 2 ||
            length(unique(df_model$year)) < 2 ||
            length(unique(df_model$y)) <= 1
        ) {
            status <- "skipped"
            note <- "insufficient identifying variation"
        } else {
            formula_text <- paste(
                "y ~",
                paste(rhs_vars, collapse = " + "),
                "| region + year"
            )

            model <- tryCatch(
                feols(
                    as.formula(formula_text),
                    data = df_model,
                    cluster = ~region
                ),
                error = function(e) {
                    status <<- "failed"
                    note <<- conditionMessage(e)
                    NULL
                }
            )
        }

        if (!is.null(model)) {
            attr(model, "n_regions") <- length(unique(df_model$region))
            attr(model, "outcome_label") <- outcome_label
            attr(model, "outcome_var") <- outcome_var
            attr(model, "spec_id") <- spec_id
            attr(model, "sample_label") <- sample_label
            attr(model, "horizon") <- horizon
            models[[outcome_label]] <- model

            if (!is.null(model$collin.var)) {
                note <- paste(
                    "collinear variables dropped:",
                    paste(model$collin.var, collapse = ", ")
                )
            }
        }

        add_log(data.frame(
            spec_id = spec_id,
            sample = sample_label,
            outcome_group = outcome_group,
            outcome = outcome_label,
            n_obs = nrow(df_model),
            n_regions = length(unique(df_model$region)),
            dropped_region_count = length(dropped_regions),
            always_zero_region_count = length(always_zero_regions),
            dropped_regions = paste(dropped_regions, collapse = "; "),
            always_zero_regions = paste(always_zero_regions, collapse = "; "),
            status = status,
            note = note,
            stringsAsFactors = FALSE
        ))
    }

    models
}

run_additional_hospital_models <- function(
    data,
    outcomes,
    spec_id,
    sample_label,
    treatment_vars,
    filter_fun = NULL,
    horizon = NULL,
    outcome_family = NULL
) {
    models <- list()

    for (outcome_label in names(outcomes)) {
        outcome_var <- outcomes[[outcome_label]]
        sample_var <- hospital_sample_outcomes[[outcome_label]]
        df_reg <- clean_sample(data, filter_fun)

        dropped_regions <- character(0)

        region_sum <- tapply(
            df_reg[[sample_var]],
            df_reg$region,
            function(x) sum(x, na.rm = TRUE)
        )

        dropped_regions <- names(region_sum)[region_sum <= 0]
        df_reg <- df_reg[df_reg$region %in% names(region_sum)[region_sum > 0], ]

        if (is.null(horizon)) {
            df_reg$y <- df_reg[[outcome_var]]
        } else {
            df_reg <- make_lp_outcome_level(df_reg, outcome_var, horizon)
        }

        rhs_vars <- c(treatment_vars, "log_population")
        model_vars <- c("y", rhs_vars, "region", "year")
        df_model <- df_reg[complete.cases(df_reg[, model_vars]), ]

        status <- "estimated"
        note <- ""
        model <- NULL

        if (
            nrow(df_model) == 0 ||
            length(unique(df_model$region)) < 2 ||
            length(unique(df_model$year)) < 2 ||
            length(unique(df_model$y)) <= 1
        ) {
            status <- "skipped"
            note <- "insufficient identifying variation"
        } else {
            formula_text <- paste(
                "y ~",
                paste(rhs_vars, collapse = " + "),
                "| region + year"
            )

            model <- tryCatch(
                feols(
                    as.formula(formula_text),
                    data = df_model,
                    cluster = ~region
                ),
                error = function(e) {
                    status <<- "failed"
                    note <<- conditionMessage(e)
                    NULL
                }
            )
        }

        if (!is.null(model)) {
            attr(model, "n_regions") <- length(unique(df_model$region))
            attr(model, "outcome_label") <- outcome_label
            attr(model, "outcome_var") <- outcome_var
            attr(model, "spec_id") <- spec_id
            attr(model, "sample_label") <- sample_label
            attr(model, "horizon") <- horizon
            models[[outcome_label]] <- model

            if (!is.null(model$collin.var)) {
                note <- paste(
                    "collinear variables dropped:",
                    paste(model$collin.var, collapse = ", ")
                )
            }
        }

        add_log(data.frame(
            spec_id = spec_id,
            sample = sample_label,
            outcome_group = paste0("hospital_", outcome_family),
            outcome = outcome_label,
            n_obs = nrow(df_model),
            n_regions = length(unique(df_model$region)),
            dropped_region_count = length(dropped_regions),
            always_zero_region_count = 0,
            dropped_regions = paste(dropped_regions, collapse = "; "),
            always_zero_regions = "",
            status = status,
            note = note,
            stringsAsFactors = FALSE
        ))
    }

    models
}

extract_model_coefficients <- function(models, term, outcome_group, spec_id, horizon) {
    rows <- list()

    for (outcome_label in names(models)) {
        model <- models[[outcome_label]]
        coef_table <- coeftable(model)

        if (!term %in% rownames(coef_table)) {
            next
        }

        estimate <- coef_table[term, "Estimate"]
        se <- coef_table[term, "Std. Error"]

        rows[[length(rows) + 1]] <- data.frame(
            spec_id = spec_id,
            outcome_group = outcome_group,
            outcome = outcome_label,
            horizon = horizon,
            term = term,
            estimate = estimate,
            se = se,
            ci_low = estimate - 1.96 * se,
            ci_high = estimate + 1.96 * se,
            stringsAsFactors = FALSE
        )
    }

    if (length(rows) == 0) {
        return(NULL)
    }

    do.call(rbind, rows)
}

write_empty_table <- function(file_path, table_title) {
    writeLines(c(
        "\\begin{table}[!htbp]",
        "\\centering",
        paste0("\\caption{", table_title, "}"),
        "\\begin{tabular}{l}",
        "\\toprule",
        "No model was estimated.\\\\",
        "\\bottomrule",
        "\\end{tabular}",
        "\\end{table}"
    ), file_path)
}

write_regression_table <- function(
    models,
    table_file,
    table_title,
    treatment_vars
) {
    file_path <- file.path(TABLES, table_file)

    if (length(models) == 0) {
        write_empty_table(file_path, table_title)
        return(invisible(file_path))
    }

    region_counts <- vapply(
        models,
        function(x) as.character(attr(x, "n_regions")),
        character(1)
    )

    extra_lines <- list(
        "Controls" = rep("Yes", length(models)),
        "Region FE" = rep("Yes", length(models)),
        "Year FE" = rep("Yes", length(models)),
        "Regions" = region_counts
    )

    keep_regex <- paste0("^(", paste(treatment_vars, collapse = "|"), ")$")

    tex <- etable(
        models,
        tex = TRUE,
        title = table_title,
        headers = names(models),
        style.tex = style.tex("aer", tablefoot = FALSE),
        keep_raw = keep_regex,
        coefstat = "se",
        se.below = TRUE,
        fitstat = ~n + ar2,
        extralines = extra_lines,
        dict = coef_dict,
        signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
    )

    writeLines(tex, file_path)
    invisible(file_path)
}

run_static_spec <- function(
    spec_id,
    title,
    equation,
    treatment_vars,
    hospital_table,
    doctor_table,
    filter_fun = NULL,
    sample_label = "main",
    note = NULL
) {
    hospital_models <- run_outcome_models(
        panel,
        hospital_outcomes,
        "hospital",
        spec_id,
        sample_label,
        treatment_vars,
        filter_fun = filter_fun
    )

    doctor_models <- run_outcome_models(
        panel,
        doctor_outcomes,
        "doctor",
        spec_id,
        sample_label,
        treatment_vars,
        filter_fun = filter_fun
    )

    write_regression_table(
        hospital_models,
        hospital_table,
        paste0(title, ": Hospital-Type Outcomes"),
        treatment_vars
    )

    write_regression_table(
        doctor_models,
        doctor_table,
        paste0(title, ": Doctor-Type Outcomes"),
        treatment_vars
    )

    invisible(list(
        hospital = hospital_models,
        doctor = doctor_models
    ))
}

run_lp_spec <- function(
    spec_id,
    title,
    equation,
    treatment_var,
    horizon,
    hospital_table,
    doctor_table,
    filter_fun = NULL,
    sample_label = "main"
) {
    hospital_models <- run_outcome_models(
        panel,
        hospital_outcomes,
        "hospital",
        spec_id,
        sample_label,
        treatment_var,
        filter_fun = filter_fun,
        horizon = horizon
    )

    doctor_models <- run_outcome_models(
        panel,
        doctor_outcomes,
        "doctor",
        spec_id,
        sample_label,
        treatment_var,
        filter_fun = filter_fun,
        horizon = horizon
    )

    write_regression_table(
        hospital_models,
        hospital_table,
        paste0(title, ": Hospital-Type Outcomes"),
        treatment_var
    )

    write_regression_table(
        doctor_models,
        doctor_table,
        paste0(title, ": Doctor-Type Outcomes"),
        treatment_var
    )

    lp_hospital <- extract_model_coefficients(
        hospital_models,
        treatment_var,
        "hospital",
        spec_id,
        horizon
    )
    lp_doctor <- extract_model_coefficients(
        doctor_models,
        treatment_var,
        "doctor",
        spec_id,
        horizon
    )

    lp_coefficients[[length(lp_coefficients) + 1]] <<- lp_hospital
    lp_coefficients[[length(lp_coefficients) + 1]] <<- lp_doctor

    invisible(list(
        hospital = hospital_models,
        doctor = doctor_models
    ))
}

additional_hospital_lp_coefficients <- list()

run_additional_hospital_static_spec <- function(
    outcome_family,
    outcome_set,
    spec_id,
    title,
    treatment_vars,
    table_file,
    filter_fun = NULL,
    sample_label = "main"
) {
    hospital_models <- run_additional_hospital_models(
        panel,
        outcome_set$outcomes,
        spec_id,
        sample_label,
        treatment_vars,
        filter_fun = filter_fun,
        outcome_family = outcome_family
    )

    write_regression_table(
        hospital_models,
        table_file,
        paste0(title, ": ", outcome_set$label, " by Hospital Type"),
        treatment_vars
    )

    invisible(hospital_models)
}

run_additional_hospital_lp_spec <- function(
    outcome_family,
    outcome_set,
    spec_id,
    title,
    treatment_var,
    horizon,
    table_file,
    filter_fun = NULL,
    sample_label = "main"
) {
    hospital_models <- run_additional_hospital_models(
        panel,
        outcome_set$outcomes,
        spec_id,
        sample_label,
        treatment_var,
        filter_fun = filter_fun,
        horizon = horizon,
        outcome_family = outcome_family
    )

    write_regression_table(
        hospital_models,
        table_file,
        paste0(title, ": ", outcome_set$label, " by Hospital Type"),
        treatment_var
    )

    lp_hospital <- extract_model_coefficients(
        hospital_models,
        treatment_var,
        paste0("hospital_", outcome_family),
        spec_id,
        horizon
    )

    additional_hospital_lp_coefficients[[length(additional_hospital_lp_coefficients) + 1]] <<- lp_hospital

    invisible(hospital_models)
}

thresholds <- data.frame(
    cutoff = c(1.5, 2.0, 2.5, 3.0),
    suffix = c("1p5h", "2h", "2p5h", "3h"),
    label = c("1.5", "2", "2.5", "3"),
    stringsAsFactors = FALSE
)

############################################################
#### Main Handoff Regressions ##############################
############################################################

run_static_spec(
    "reg01_continuous_saving",
    "Regression 1. Continuous Saving Model",
    "y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving"),
    "reg01_continuous_saving_hospital.tex",
    "reg01_continuous_saving_doctor.tex"
)

run_static_spec(
    "reg02_within2h",
    "Regression 2. Two-Hour Access Model",
    "y_{it}=\\alpha_i+\\tau_t+\\delta Within2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("within2h"),
    "reg02_within2h_hospital.tex",
    "reg02_within2h_doctor.tex"
)

run_static_spec(
    "reg03_hybrid_saving_within2h",
    "Regression 3. Hybrid Saving + Two-Hour Access Model",
    "y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\delta Within2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving", "within2h"),
    "reg03_hybrid_saving_within2h_hospital.tex",
    "reg03_hybrid_saving_within2h_doctor.tex"
)

run_static_spec(
    "reg04_ktx_within2h",
    "Regression 4. KTX Two-Hour Access Model",
    "y_{it}=\\alpha_i+\\tau_t+\\delta KTXWithin2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("ktx_within2h"),
    "reg04_ktx_within2h_hospital.tex",
    "reg04_ktx_within2h_doctor.tex"
)

run_static_spec(
    "reg05_hybrid_saving_ktx_within2h",
    "Regression 5. Hybrid Saving + KTX Two-Hour Access Model",
    "y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\delta KTXWithin2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving", "ktx_within2h"),
    "reg05_hybrid_saving_ktx_within2h_hospital.tex",
    "reg05_hybrid_saving_ktx_within2h_doctor.tex"
)

run_static_spec(
    "reg06_saving_to_2h",
    "Regression 6. Saving Toward Two-Hour Threshold Model",
    "y_{it}=\\alpha_i+\\tau_t+\\beta SavingTo2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving_to_2h"),
    "reg06_saving_to_2h_hospital.tex",
    "reg06_saving_to_2h_doctor.tex"
)

for (i in seq_len(nrow(thresholds))) {
    suffix <- thresholds$suffix[i]
    label <- thresholds$label[i]
    within_var <- paste0("within", suffix)

    run_static_spec(
        paste0("reg07_threshold_", suffix),
        paste0("Regression 7. Threshold Access Model, ", label, " Hours"),
        paste0(
            "y_{it}=\\alpha_i+\\tau_t+\\delta Within",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c(within_var),
        paste0("reg07_threshold_", suffix, "_hospital.tex"),
        paste0("reg07_threshold_", suffix, "_doctor.tex")
    )
}

for (h in 0:5) {
    run_lp_spec(
        paste0("reg08_lp_shocksaving_h", h),
        "Regression 8. Local Projection with Continuous Shock",
        "y_{i,t+h}-y_{i,t-1}=\\alpha_i^h+\\tau_t^h+\\beta_h ShockSaving_{it}+\\gamma_h\\log(Population_{it})+\\epsilon_{i,t+h}",
        "shock_saving",
        h,
        paste0("reg08_lp_shocksaving_h", h, "_hospital.tex"),
        paste0("reg08_lp_shocksaving_h", h, "_doctor.tex")
    )
}

for (h in 0:5) {
    run_lp_spec(
        paste0("reg09_lp_cross2h_h", h),
        "Regression 9. Local Projection with Two-Hour Crossing Shock",
        "y_{i,t+h}-y_{i,t-1}=\\alpha_i^h+\\tau_t^h+\\delta_h Cross2h_{it}+\\gamma_h\\log(Population_{it})+\\epsilon_{i,t+h}",
        "cross2h",
        h,
        paste0("reg09_lp_cross2h_h", h, "_hospital.tex"),
        paste0("reg09_lp_cross2h_h", h, "_doctor.tex")
    )
}

run_static_spec(
    "reg10_ktx_chosen",
    "Regression 10. KTX Chosen Model",
    "y_{it}=\\alpha_i+\\tau_t+\\delta KTXChosen_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("ktx_chosen"),
    "reg10_ktx_chosen_hospital.tex",
    "reg10_ktx_chosen_doctor.tex"
)

############################################################
#### Additional Robustness #################################
############################################################

run_static_spec(
    "rob01_saving_excluding_already_treated",
    "Robustness 1. Continuous Saving, Excluding Already-Treated Regions",
    "y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving"),
    "rob01_saving_excluding_already_treated_hospital.tex",
    "rob01_saving_excluding_already_treated_doctor.tex",
    filter_fun = function(x) x$already_treated_2007 == 0,
    sample_label = "exclude within2h_2007 or ktx_chosen_2007",
    note = "Regions with $Within2h_{i,2007}=1$ or $KTXChosen_{i,2007}=1$ are excluded."
)

for (i in seq_len(nrow(thresholds))) {
    suffix <- thresholds$suffix[i]
    label <- thresholds$label[i]
    within_var <- paste0("within", suffix)
    base_var <- paste0("within", suffix, "_2007")
    base_filter <- local({
        baseline_var <- base_var
        function(x) x[[baseline_var]] == 0
    })

    run_static_spec(
        paste0("rob02_threshold_", suffix, "_not_already_within"),
        paste0(
            "Robustness 2. Threshold Access, ",
            label,
            " Hours, Excluding Baseline Within-Threshold Regions"
        ),
        paste0(
            "y_{it}=\\alpha_i+\\tau_t+\\delta Within",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c(within_var),
        paste0("rob02_threshold_", suffix, "_hospital.tex"),
        paste0("rob02_threshold_", suffix, "_doctor.tex"),
        filter_fun = base_filter,
        sample_label = paste0("exclude ", base_var, " = 1"),
        note = paste0("Regions already within ", label, " hours in 2007 are excluded.")
    )

    run_static_spec(
        paste0("rob03_hybrid_threshold_", suffix, "_not_already_within"),
        paste0(
            "Robustness 3. Hybrid Saving + Threshold Access, ",
            label,
            " Hours, Excluding Baseline Within-Threshold Regions"
        ),
        paste0(
            "y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\delta Within",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c("saving", within_var),
        paste0("rob03_hybrid_threshold_", suffix, "_hospital.tex"),
        paste0("rob03_hybrid_threshold_", suffix, "_doctor.tex"),
        filter_fun = base_filter,
        sample_label = paste0("exclude ", base_var, " = 1"),
        note = paste0("Regions already within ", label, " hours in 2007 are excluded.")
    )
}

for (i in seq_len(nrow(thresholds))) {
    suffix <- thresholds$suffix[i]
    label <- thresholds$label[i]
    ktx_within_var <- paste0("ktx_within", suffix)
    base_var <- paste0("ktx_within", suffix, "_2007")
    base_filter <- local({
        baseline_var <- base_var
        function(x) x[[baseline_var]] == 0
    })

    run_static_spec(
        paste0("rob04_ktx_threshold_", suffix, "_not_already_ktx_within"),
        paste0(
            "Robustness 4. KTX Threshold Access, ",
            label,
            " Hours, Excluding Baseline KTX Within-Threshold Regions"
        ),
        paste0(
            "y_{it}=\\alpha_i+\\tau_t+\\delta KTXWithin",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c(ktx_within_var),
        paste0("rob04_ktx_threshold_", suffix, "_hospital.tex"),
        paste0("rob04_ktx_threshold_", suffix, "_doctor.tex"),
        filter_fun = base_filter,
        sample_label = paste0("exclude ", base_var, " = 1"),
        note = paste0("Regions already KTX-within ", label, " hours in 2007 are excluded.")
    )

    run_static_spec(
        paste0("rob05_hybrid_ktx_threshold_", suffix, "_not_already_ktx_within"),
        paste0(
            "Robustness 5. Hybrid Saving + KTX Threshold Access, ",
            label,
            " Hours, Excluding Baseline KTX Within-Threshold Regions"
        ),
        paste0(
            "y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\delta KTXWithin",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c("saving", ktx_within_var),
        paste0("rob05_hybrid_ktx_threshold_", suffix, "_hospital.tex"),
        paste0("rob05_hybrid_ktx_threshold_", suffix, "_doctor.tex"),
        filter_fun = base_filter,
        sample_label = paste0("exclude ", base_var, " = 1"),
        note = paste0("Regions already KTX-within ", label, " hours in 2007 are excluded.")
    )
}

run_static_spec(
    "rob06_ktx_chosen_not_already_chosen",
    "Robustness 6. KTX Chosen, Excluding Baseline KTX-Chosen Regions",
    "y_{it}=\\alpha_i+\\tau_t+\\delta KTXChosen_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("ktx_chosen"),
    "rob06_ktx_chosen_hospital.tex",
    "rob06_ktx_chosen_doctor.tex",
    filter_fun = function(x) x$ktx_chosen_2007 == 0,
    sample_label = "exclude ktx_chosen_2007 = 1",
    note = "Regions where KTX was already the fastest route in 2007 are excluded."
)

############################################################
#### Additional Hospital Flow and Rate Outcomes ############
############################################################

for (outcome_family in names(additional_hospital_outcome_sets)) {
    outcome_set <- additional_hospital_outcome_sets[[outcome_family]]
    file_prefix <- paste0("add_", outcome_family)

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0(file_prefix, "_reg01_continuous_saving"),
        paste0("Additional ", outcome_set$label, ". Continuous Saving Model"),
        c("saving"),
        paste0(file_prefix, "_reg01_continuous_saving_hospital.tex")
    )

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0(file_prefix, "_reg02_within2h"),
        paste0("Additional ", outcome_set$label, ". Two-Hour Access Model"),
        c("within2h"),
        paste0(file_prefix, "_reg02_within2h_hospital.tex")
    )

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0(file_prefix, "_reg03_hybrid_saving_within2h"),
        paste0("Additional ", outcome_set$label, ". Hybrid Saving + Two-Hour Access Model"),
        c("saving", "within2h"),
        paste0(file_prefix, "_reg03_hybrid_saving_within2h_hospital.tex")
    )

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0(file_prefix, "_reg04_ktx_within2h"),
        paste0("Additional ", outcome_set$label, ". KTX Two-Hour Access Model"),
        c("ktx_within2h"),
        paste0(file_prefix, "_reg04_ktx_within2h_hospital.tex")
    )

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0(file_prefix, "_reg05_hybrid_saving_ktx_within2h"),
        paste0("Additional ", outcome_set$label, ". Hybrid Saving + KTX Two-Hour Access Model"),
        c("saving", "ktx_within2h"),
        paste0(file_prefix, "_reg05_hybrid_saving_ktx_within2h_hospital.tex")
    )

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0(file_prefix, "_reg06_saving_to_2h"),
        paste0("Additional ", outcome_set$label, ". Saving Toward Two-Hour Threshold Model"),
        c("saving_to_2h"),
        paste0(file_prefix, "_reg06_saving_to_2h_hospital.tex")
    )

    for (i in seq_len(nrow(thresholds))) {
        suffix <- thresholds$suffix[i]
        label <- thresholds$label[i]
        within_var <- paste0("within", suffix)

        run_additional_hospital_static_spec(
            outcome_family,
            outcome_set,
            paste0(file_prefix, "_reg07_threshold_", suffix),
            paste0("Additional ", outcome_set$label, ". Threshold Access Model, ", label, " Hours"),
            c(within_var),
            paste0(file_prefix, "_reg07_threshold_", suffix, "_hospital.tex")
        )
    }

    for (h in 0:5) {
        run_additional_hospital_lp_spec(
            outcome_family,
            outcome_set,
            paste0(file_prefix, "_reg08_lp_shocksaving_h", h),
            paste0("Additional ", outcome_set$label, ". Local Projection with Continuous Shock"),
            "shock_saving",
            h,
            paste0(file_prefix, "_reg08_lp_shocksaving_h", h, "_hospital.tex")
        )
    }

    for (h in 0:5) {
        run_additional_hospital_lp_spec(
            outcome_family,
            outcome_set,
            paste0(file_prefix, "_reg09_lp_cross2h_h", h),
            paste0("Additional ", outcome_set$label, ". Local Projection with Two-Hour Crossing Shock"),
            "cross2h",
            h,
            paste0(file_prefix, "_reg09_lp_cross2h_h", h, "_hospital.tex")
        )
    }

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0(file_prefix, "_reg10_ktx_chosen"),
        paste0("Additional ", outcome_set$label, ". KTX Chosen Model"),
        c("ktx_chosen"),
        paste0(file_prefix, "_reg10_ktx_chosen_hospital.tex")
    )

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0(file_prefix, "_rob01_saving_excluding_already_treated"),
        paste0("Additional ", outcome_set$label, ". Continuous Saving, Excluding Already-Treated Regions"),
        c("saving"),
        paste0(file_prefix, "_rob01_saving_excluding_already_treated_hospital.tex"),
        filter_fun = function(x) x$already_treated_2007 == 0,
        sample_label = "exclude within2h_2007 or ktx_chosen_2007"
    )

    for (i in seq_len(nrow(thresholds))) {
        suffix <- thresholds$suffix[i]
        label <- thresholds$label[i]
        within_var <- paste0("within", suffix)
        base_var <- paste0("within", suffix, "_2007")
        base_filter <- local({
            baseline_var <- base_var
            function(x) x[[baseline_var]] == 0
        })

        run_additional_hospital_static_spec(
            outcome_family,
            outcome_set,
            paste0(file_prefix, "_rob02_threshold_", suffix, "_not_already_within"),
            paste0("Additional ", outcome_set$label, ". Threshold Access, ", label, " Hours, Excluding Baseline Within-Threshold Regions"),
            c(within_var),
            paste0(file_prefix, "_rob02_threshold_", suffix, "_hospital.tex"),
            filter_fun = base_filter,
            sample_label = paste0("exclude ", base_var, " = 1")
        )

        run_additional_hospital_static_spec(
            outcome_family,
            outcome_set,
            paste0(file_prefix, "_rob03_hybrid_threshold_", suffix, "_not_already_within"),
            paste0("Additional ", outcome_set$label, ". Hybrid Saving + Threshold Access, ", label, " Hours, Excluding Baseline Within-Threshold Regions"),
            c("saving", within_var),
            paste0(file_prefix, "_rob03_hybrid_threshold_", suffix, "_hospital.tex"),
            filter_fun = base_filter,
            sample_label = paste0("exclude ", base_var, " = 1")
        )
    }

    for (i in seq_len(nrow(thresholds))) {
        suffix <- thresholds$suffix[i]
        label <- thresholds$label[i]
        ktx_within_var <- paste0("ktx_within", suffix)
        base_var <- paste0("ktx_within", suffix, "_2007")
        base_filter <- local({
            baseline_var <- base_var
            function(x) x[[baseline_var]] == 0
        })

        run_additional_hospital_static_spec(
            outcome_family,
            outcome_set,
            paste0(file_prefix, "_rob04_ktx_threshold_", suffix, "_not_already_ktx_within"),
            paste0("Additional ", outcome_set$label, ". KTX Threshold Access, ", label, " Hours, Excluding Baseline KTX Within-Threshold Regions"),
            c(ktx_within_var),
            paste0(file_prefix, "_rob04_ktx_threshold_", suffix, "_hospital.tex"),
            filter_fun = base_filter,
            sample_label = paste0("exclude ", base_var, " = 1")
        )

        run_additional_hospital_static_spec(
            outcome_family,
            outcome_set,
            paste0(file_prefix, "_rob05_hybrid_ktx_threshold_", suffix, "_not_already_ktx_within"),
            paste0("Additional ", outcome_set$label, ". Hybrid Saving + KTX Threshold Access, ", label, " Hours, Excluding Baseline KTX Within-Threshold Regions"),
            c("saving", ktx_within_var),
            paste0(file_prefix, "_rob05_hybrid_ktx_threshold_", suffix, "_hospital.tex"),
            filter_fun = base_filter,
            sample_label = paste0("exclude ", base_var, " = 1")
        )
    }

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0(file_prefix, "_rob06_ktx_chosen_not_already_chosen"),
        paste0("Additional ", outcome_set$label, ". KTX Chosen, Excluding Baseline KTX-Chosen Regions"),
        c("ktx_chosen"),
        paste0(file_prefix, "_rob06_ktx_chosen_hospital.tex"),
        filter_fun = function(x) x$ktx_chosen_2007 == 0,
        sample_label = "exclude ktx_chosen_2007 = 1"
    )
}

############################################################
#### Direct Travel-Time Level Regressions ##################
############################################################

run_static_spec(
    "direct_travel_time_level",
    "Direct Travel-Time Level Model",
    "y_{it}=\\alpha_i+\\tau_t+\\beta TravelTime_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("travel_time_hour"),
    "direct_travel_time_level_hospital.tex",
    "direct_travel_time_level_doctor.tex"
)

for (outcome_family in names(additional_hospital_outcome_sets)) {
    outcome_set <- additional_hospital_outcome_sets[[outcome_family]]

    run_additional_hospital_static_spec(
        outcome_family,
        outcome_set,
        paste0("direct_travel_time_level_", outcome_family),
        paste0("Direct Travel-Time Level Model, ", outcome_set$label),
        c("travel_time_hour"),
        paste0("direct_travel_time_level_", outcome_family, "_hospital.tex")
    )
}

############################################################
#### Local Projection Plots ################################
############################################################

lp_coef <- do.call(rbind, lp_coefficients[!vapply(lp_coefficients, is.null, logical(1))])

plot_lp_by_outcome <- function(data, spec_prefix, outcome_group, term, file_prefix, title_prefix) {
    plot_data <- data %>%
        filter(
            grepl(spec_prefix, spec_id, fixed = TRUE),
            outcome_group == !!outcome_group,
            term == !!term
        )

    if (nrow(plot_data) == 0) {
        return(invisible(NULL))
    }

    outcome_plot_labels <- c(
        "상급종합병원" = "Tertiary hospitals",
        "종합병원" = "General hospitals",
        "의원" = "Clinics",
        "병원" = "Hospitals",
        "인턴" = "Interns",
        "레지던트" = "Residents",
        "전문의" = "Specialists",
        "일반의" = "General practitioners"
    )

    outcome_file_names <- c(
        "상급종합병원" = "tertiary",
        "종합병원" = "general_hospital",
        "의원" = "clinic",
        "병원" = "secondary_hospital",
        "인턴" = "intern",
        "레지던트" = "resident",
        "전문의" = "specialist",
        "일반의" = "general_practitioner"
    )

    plot_data$outcome_plot <- unname(outcome_plot_labels[plot_data$outcome])
    plot_data$outcome_plot[is.na(plot_data$outcome_plot)] <- plot_data$outcome[is.na(plot_data$outcome_plot)]

    expected_outcomes <- if (outcome_group == "hospital") {
        names(hospital_outcomes)
    } else {
        names(doctor_outcomes)
    }

    output_files <- character(0)

    for (outcome_name in expected_outcomes) {
        outcome_data <- plot_data %>%
            filter(outcome == outcome_name)

        outcome_label <- unname(outcome_plot_labels[outcome_name])
        if (is.na(outcome_label)) {
            outcome_label <- outcome_name
        }

        file_stub <- unname(outcome_file_names[outcome_name])
        if (is.na(file_stub)) {
            file_stub <- gsub("[^A-Za-z0-9]+", "_", outcome_name)
        }

        if (nrow(outcome_data) == 0) {
            p <- ggplot() +
                annotate(
                    "text",
                    x = 0,
                    y = 0,
                    label = "Coefficient not estimated\n(collinear with fixed effects)",
                    size = 4
                ) +
                xlim(-1, 1) +
                ylim(-1, 1) +
                labs(
                    title = paste(title_prefix, outcome_label),
                    x = NULL,
                    y = NULL
                ) +
                theme_void(base_size = 10) +
                theme(plot.title = element_text(face = "bold"))
        } else {
            p <- ggplot(
                outcome_data,
                aes(x = horizon, y = estimate)
            ) +
                geom_hline(yintercept = 0, linewidth = 0.3, color = "gray45") +
                geom_ribbon(aes(ymin = ci_low, ymax = ci_high), fill = "#dbe9f6", alpha = 0.75) +
                geom_line(linewidth = 0.65, color = "#1f5f99") +
                geom_point(size = 2, color = "#1f5f99") +
                scale_x_continuous(breaks = 0:5) +
                labs(
                    title = paste(title_prefix, outcome_label),
                    x = "Horizon",
                    y = "Coefficient"
                ) +
                theme_minimal(base_size = 10) +
                theme(
                    panel.grid.minor = element_blank(),
                    plot.title = element_text(face = "bold")
                )
        }

        file_name <- paste0(file_prefix, "_", file_stub, ".pdf")

        ggsave(
            filename = file.path(FIGURES, file_name),
            plot = p,
            width = 5.8,
            height = 4.1
        )

        output_files <- c(output_files, file.path(FIGURES, file_name))
    }

    invisible(output_files)
}

if (!is.null(lp_coef) && nrow(lp_coef) > 0) {
    plot_lp_by_outcome(
        lp_coef,
        "reg08_lp_shocksaving",
        "hospital",
        "shock_saving",
        "reg08_lp_shocksaving_hospital",
        "Travel-Time Shock:"
    )
    plot_lp_by_outcome(
        lp_coef,
        "reg08_lp_shocksaving",
        "doctor",
        "shock_saving",
        "reg08_lp_shocksaving_doctor",
        "Travel-Time Shock:"
    )
    plot_lp_by_outcome(
        lp_coef,
        "reg09_lp_cross2h",
        "hospital",
        "cross2h",
        "reg09_lp_cross2h_hospital",
        "Crossing Two-Hour Zone:"
    )
    plot_lp_by_outcome(
        lp_coef,
        "reg09_lp_cross2h",
        "doctor",
        "cross2h",
        "reg09_lp_cross2h_doctor",
        "Crossing Two-Hour Zone:"
    )
}

############################################################
#### Regression Log and Report #############################
############################################################

log_df <- do.call(rbind, regression_log)

dbWriteTable(con, "analysis_regression_log", log_df, overwrite = TRUE)

write_log_tex <- function(log_df) {
    tex_escape <- function(x) {
        x <- ifelse(is.na(x), "", x)
        x <- gsub("\\", "\\textbackslash{}", x, fixed = TRUE)
        x <- gsub("&", "\\&", x, fixed = TRUE)
        x <- gsub("%", "\\%", x, fixed = TRUE)
        x <- gsub("$", "\\$", x, fixed = TRUE)
        x <- gsub("#", "\\#", x, fixed = TRUE)
        x <- gsub("_", "\\_", x, fixed = TRUE)
        x
    }

    summary_df <- log_df %>%
        group_by(spec_id, sample, outcome_group, status) %>%
        summarise(
            regressions = n(),
            min_obs = min(n_obs),
            max_obs = max(n_obs),
            min_regions = min(n_regions),
            max_regions = max(n_regions),
            .groups = "drop"
        ) %>%
        arrange(spec_id, outcome_group, status)

    lines <- c(
        "\\section{Regression Sample Log}",
        "\\begin{longtable}{lllrrrrr}",
        "\\toprule",
        "Specification & Sample & Group & Status & Regressions & Min Obs. & Max Obs. & Regions\\\\",
        "\\midrule",
        "\\endhead"
    )

    for (i in seq_len(nrow(summary_df))) {
        row <- summary_df[i, ]
        lines <- c(lines, paste0(
            tex_escape(row$spec_id),
            " & ",
            tex_escape(row$sample),
            " & ",
            tex_escape(row$outcome_group),
            " & ",
            tex_escape(row$status),
            " & ",
            row$regressions,
            " & ",
            row$min_obs,
            " & ",
            row$max_obs,
            " & ",
            row$min_regions,
            "--",
            row$max_regions,
            "\\\\"
        ))
    }

    lines <- c(lines, "\\bottomrule", "\\end{longtable}")

    dropped <- log_df %>%
        filter(dropped_region_count > 0) %>%
        select(spec_id, sample, outcome, dropped_region_count, dropped_regions)

    lines <- c(
        lines,
        "\\subsection{Hospital-type always-zero region exclusions}"
    )

    if (nrow(dropped) == 0) {
        lines <- c(lines, "No hospital-type always-zero exclusions were applied.")
    } else {
        for (i in seq_len(nrow(dropped))) {
            row <- dropped[i, ]
            lines <- c(lines, paste0(
                "\\paragraph{",
                tex_escape(row$spec_id),
                ", ",
                tex_escape(row$outcome),
                ".} Dropped ",
                row$dropped_region_count,
                " regions: ",
                tex_escape(row$dropped_regions)
            ))
        }
    }

    writeLines(lines, file.path(REPORT, "regression_sample_log.tex"))
}

write_log_tex(log_df)

dbDisconnect(con, shutdown = TRUE)
