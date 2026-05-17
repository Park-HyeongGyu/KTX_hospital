library(DBI)
library(duckdb)
library(dplyr)
library(fixest)
library(glue)

source("../../../config.r")

setFixest_notes(FALSE)

APPENDIX <- file.path(ROOT, "memo", "2026-0514_미팅", "어펜딕스")
TABLES <- file.path(APPENDIX, "tables")

dir.create(APPENDIX, recursive = TRUE, showWarnings = FALSE)
dir.create(TABLES, recursive = TRUE, showWarnings = FALSE)

con <- dbConnect(duckdb(), file.path(ROOT, "analysis_db.duckdb"))

path_travel_time <- file.path(CLEAN, "clean_travel_time.parquet")
path_population <- file.path(CLEAN, "clean_population.parquet")
path_hospital <- file.path(CLEAN, "clean_hospital_by_type.parquet")
path_doctor <- file.path(CLEAN, "clean_doctor_by_level.parquet")

dbExecute(con, glue("
    CREATE OR REPLACE TABLE appendix_travel_time AS
    WITH travel AS (
        SELECT
            region_sido,
            region_sigungu,
            region_sido || '_' || region_sigungu AS region,
            year,
            car_travel_time / 60.0 AS car_travel_time_hour,
            ktx_travel_time_median / 60.0 AS ktx_travel_time_median_hour,
            travel_time / 60.0 AS travel_time_hour,
            CASE WHEN travel_time / 60.0 <= 1.5 THEN 1 ELSE 0 END AS within1p5h,
            CASE WHEN travel_time / 60.0 <= 2.0 THEN 1 ELSE 0 END AS within2h,
            CASE WHEN travel_time / 60.0 <= 2.5 THEN 1 ELSE 0 END AS within2p5h,
            CASE WHEN travel_time / 60.0 <= 3.0 THEN 1 ELSE 0 END AS within3h,
            CASE WHEN ktx_travel_time_median < car_travel_time THEN 1 ELSE 0 END AS ktx_chosen,
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
            WHEN l.travel_time_lag_hour > 1.5 AND l.travel_time_hour <= 1.5 THEN 1 ELSE 0
        END AS cross1p5h,
        CASE
            WHEN l.travel_time_lag_hour IS NULL THEN NULL
            WHEN l.travel_time_lag_hour > 2.0 AND l.travel_time_hour <= 2.0 THEN 1 ELSE 0
        END AS cross2h,
        CASE
            WHEN l.travel_time_lag_hour IS NULL THEN NULL
            WHEN l.travel_time_lag_hour > 2.5 AND l.travel_time_hour <= 2.5 THEN 1 ELSE 0
        END AS cross2p5h,
        CASE
            WHEN l.travel_time_lag_hour IS NULL THEN NULL
            WHEN l.travel_time_lag_hour > 3.0 AND l.travel_time_hour <= 3.0 THEN 1 ELSE 0
        END AS cross3h,
        CASE
            WHEN b.within2h_2007 = 1 OR b.ktx_chosen_2007 = 1 THEN 1 ELSE 0
        END AS already_treated_2007
    FROM lagged AS l
    LEFT JOIN baseline AS b
        USING (region_sido, region_sigungu)
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE appendix_population AS
    SELECT
        region_sido,
        region_sigungu,
        year,
        population,
        LOG(population) AS log_population
    FROM read_parquet('{path_population}')
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE appendix_hospital AS
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
    CREATE OR REPLACE TABLE appendix_doctor AS
    SELECT
        region_sido,
        region_sigungu,
        year,
        MAX(CASE WHEN doctor_level = '인턴' THEN doctor_no END) AS intern_no,
        MAX(CASE WHEN doctor_level = '레지던트' THEN doctor_no END) AS resident_no,
        MAX(CASE WHEN doctor_level = '전문의' THEN doctor_no END) AS specialist_no,
        MAX(CASE WHEN doctor_level = '일반의' THEN doctor_no END) AS gp_no
    FROM read_parquet('{path_doctor}')
    GROUP BY region_sido, region_sigungu, year
"))

dbExecute(con, "
    CREATE OR REPLACE TABLE appendix_panel AS
    SELECT
        t.*,
        p.population,
        p.log_population,
        h.* EXCLUDE (region_sido, region_sigungu, year),
        d.* EXCLUDE (region_sido, region_sigungu, year)
    FROM appendix_travel_time AS t
    LEFT JOIN appendix_population AS p
        USING (region_sido, region_sigungu, year)
    LEFT JOIN appendix_hospital AS h
        USING (region_sido, region_sigungu, year)
    LEFT JOIN appendix_doctor AS d
        USING (region_sido, region_sigungu, year)
    WHERE t.region_sido NOT IN ('서울', '경기', '인천', '제주')
")

panel <- dbGetQuery(con, "
    SELECT *
    FROM appendix_panel
    ORDER BY region, year
")

hospital_types <- list(
    clinic = list(label = "의원", prefix = "clinic", sample = "clinic_no"),
    secondary = list(label = "병원", prefix = "secondary", sample = "secondary_hospital_no"),
    general = list(label = "종합병원", prefix = "general", sample = "general_hospital_no"),
    tertiary = list(label = "상급종합병원", prefix = "tertiary", sample = "tertiary_hospital_no")
)

hospital_outcome_suffixes <- c(
    hospital_no = "hospital_no",
    net_entry = "net_entry",
    exit_no = "exit_no",
    exit_rate = "exit_rate",
    entry_no = "entry_no",
    entry_rate = "entry_rate"
)

doctor_outcomes <- c(
    "인턴" = "intern_no",
    "레지던트" = "resident_no",
    "전문의" = "specialist_no",
    "일반의" = "gp_no"
)

coef_dict <- c(
    travel_time_hour = "$TravelTime_{it}$",
    saving = "$Saving_{it}$",
    within1p5h = "$Within1.5h_{it}$",
    within2h = "$Within2h_{it}$",
    within2p5h = "$Within2.5h_{it}$",
    within3h = "$Within3h_{it}$",
    ktx_within1p5h = "$KTXWithin1.5h_{it}$",
    ktx_within2h = "$KTXWithin2h_{it}$",
    ktx_within2p5h = "$KTXWithin2.5h_{it}$",
    ktx_within3h = "$KTXWithin3h_{it}$",
    saving_to_2h = "$SavingTo2h_{it}$",
    shock_saving = "$ShockSaving_{it}$",
    cross2h = "$Cross2h_{it}$",
    ktx_chosen = "$KTXChosen_{it}$"
)

clean_sample <- function(data, filter_fun) {
    if (is.null(filter_fun)) {
        return(data)
    }

    keep <- filter_fun(data)
    keep[is.na(keep)] <- FALSE
    data[keep, ]
}

make_outcome <- function(data, outcome_var, log_outcome, horizon) {
    if (is.null(horizon)) {
        if (log_outcome) {
            return(log(data[[outcome_var]] + 1))
        }

        return(data[[outcome_var]])
    }

    data <- data %>%
        arrange(region, year) %>%
        group_by(region)

    if (log_outcome) {
        data <- data %>%
            mutate(y_level = log(.data[[outcome_var]] + 1))
    } else {
        data <- data %>%
            mutate(y_level = .data[[outcome_var]])
    }

    data <- data %>%
        mutate(y = dplyr::lead(y_level, n = horizon) - dplyr::lag(y_level, n = 1)) %>%
        ungroup()

    data$y
}

fit_models <- function(data, outcome_vars, treatment_vars, filter_fun = NULL, horizon = NULL, hospital_sample_var = NULL) {
    models <- list()

    for (outcome_name in names(outcome_vars)) {
        outcome_var <- outcome_vars[[outcome_name]]
        df_reg <- clean_sample(data, filter_fun)

        if (!outcome_var %in% names(df_reg)) {
            stop(paste("Missing outcome variable:", outcome_var))
        }

        if (!is.null(hospital_sample_var)) {
            region_sum <- tapply(
                df_reg[[hospital_sample_var]],
                df_reg$region,
                function(x) sum(x, na.rm = TRUE)
            )
            df_reg <- df_reg[df_reg$region %in% names(region_sum)[region_sum > 0], ]
        }

        log_outcome <- outcome_name %in% c("hospital_no", names(doctor_outcomes))
        df_reg$y <- make_outcome(df_reg, outcome_var, log_outcome, horizon)

        rhs_vars <- c(treatment_vars, "log_population")
        model_vars <- c("y", rhs_vars, "region", "year")
        missing_vars <- setdiff(model_vars, names(df_reg))
        if (length(missing_vars) > 0) {
            stop(paste("Missing variables:", paste(missing_vars, collapse = ", ")))
        }
        df_model <- df_reg[complete.cases(df_reg[, model_vars]), ]

        if (
            nrow(df_model) == 0 ||
            length(unique(df_model$region)) < 2 ||
            length(unique(df_model$year)) < 2 ||
            length(unique(df_model$y)) <= 1
        ) {
            next
        }

        model <- tryCatch(
            feols(
                as.formula(glue("y ~ {paste(rhs_vars, collapse = ' + ')} | region + year")),
                data = df_model,
                cluster = ~region
            ),
            error = function(e) NULL
        )

        if (!is.null(model)) {
            attr(model, "n_regions") <- length(unique(df_model$region))
            models[[outcome_name]] <- model
        }
    }

    models
}

write_model_table <- function(models, file_path, treatment_vars) {
    if (length(models) == 0) {
        writeLines("% No model was estimated.", file_path)
        return(invisible(file_path))
    }

    region_counts <- vapply(
        models,
        function(model) as.character(attr(model, "n_regions")),
        character(1)
    )
    coefficient_names <- unique(unlist(lapply(models, function(model) names(coef(model)))))
    selected_terms <- intersect(treatment_vars, coefficient_names)

    if (length(selected_terms) == 0) {
        writeLines(c(
            "\\begingroup",
            "\\centering",
            "\\begin{tabular}{lc}",
            "\\toprule",
            "Treatment coefficient & Not estimated\\\\",
            "\\midrule",
            paste0("Regions & ", paste(region_counts, collapse = ", "), "\\\\"),
            "\\bottomrule",
            "\\end{tabular}",
            "\\par\\endgroup"
        ), file_path)
        return(invisible(file_path))
    }

    tex <- etable(
        models,
        tex = TRUE,
        style.tex = style.tex("aer", tablefoot = FALSE),
        headers = names(models),
        depvar = FALSE,
        keep_raw = paste0("^(", paste(selected_terms, collapse = "|"), ")$"),
        coefstat = "se",
        se.below = TRUE,
        fitstat = ~n + ar2,
        extralines = list(
            "Log population control" = rep("Yes", length(models)),
            "Region FE" = rep("Yes", length(models)),
            "Year FE" = rep("Yes", length(models)),
            "Regions" = region_counts
        ),
        drop.section = "fixef",
        dict = coef_dict,
        signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
    )

    writeLines(tex, file_path)
    invisible(file_path)
}

thresholds <- data.frame(
    cutoff = c(1.5, 2.0, 2.5, 3.0),
    suffix = c("1p5h", "2h", "2p5h", "3h"),
    label = c("1.5", "2", "2.5", "3"),
    stringsAsFactors = FALSE
)

specs <- list()

add_spec <- function(id, title, equation, treatment_vars, filter_fun = NULL, horizon = NULL, sample_note = NULL) {
    specs[[length(specs) + 1]] <<- list(
        id = id,
        title = title,
        equation = equation,
        treatment_vars = treatment_vars,
        filter_fun = filter_fun,
        horizon = horizon,
        sample_note = sample_note
    )
}

add_spec(
    "reg01_continuous_saving",
    "Regression 1. Continuous Saving Model",
    "Y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving")
)
add_spec(
    "reg02_within2h",
    "Regression 2. Two-Hour Access Model",
    "Y_{it}=\\alpha_i+\\tau_t+\\delta Within2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("within2h")
)
add_spec(
    "reg03_hybrid_saving_within2h",
    "Regression 3. Hybrid Saving + Two-Hour Access Model",
    "Y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\delta Within2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving", "within2h")
)
add_spec(
    "reg04_ktx_within2h",
    "Regression 4. KTX Two-Hour Access Model",
    "Y_{it}=\\alpha_i+\\tau_t+\\delta KTXWithin2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("ktx_within2h")
)
add_spec(
    "reg05_hybrid_saving_ktx_within2h",
    "Regression 5. Hybrid Saving + KTX Two-Hour Access Model",
    "Y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\delta KTXWithin2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving", "ktx_within2h")
)
add_spec(
    "reg06_saving_to_2h",
    "Regression 6. Saving Toward Two-Hour Threshold Model",
    "Y_{it}=\\alpha_i+\\tau_t+\\beta SavingTo2h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving_to_2h")
)

for (i in seq_len(nrow(thresholds))) {
    suffix <- thresholds$suffix[i]
    label <- thresholds$label[i]
    add_spec(
        paste0("reg07_threshold_", suffix),
        paste0("Regression 7. Threshold Access Model, ", label, " Hours"),
        paste0(
            "Y_{it}=\\alpha_i+\\tau_t+\\delta Within",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c(paste0("within", suffix))
    )
}

for (h in 0:5) {
    add_spec(
        paste0("reg08_lp_shocksaving_h", h),
        paste0("Regression 8. Local Projection with Continuous Shock, h = ", h),
        "Y_{i,t+h}-Y_{i,t-1}=\\alpha_i^h+\\tau_t^h+\\beta_h ShockSaving_{it}+\\gamma_h\\log(Population_{it})+\\epsilon_{i,t+h}",
        c("shock_saving"),
        horizon = h
    )
}

for (h in 0:5) {
    add_spec(
        paste0("reg09_lp_cross2h_h", h),
        paste0("Regression 9. Local Projection with Two-Hour Crossing Shock, h = ", h),
        "Y_{i,t+h}-Y_{i,t-1}=\\alpha_i^h+\\tau_t^h+\\delta_h Cross2h_{it}+\\gamma_h\\log(Population_{it})+\\epsilon_{i,t+h}",
        c("cross2h"),
        horizon = h
    )
}

add_spec(
    "reg10_ktx_chosen",
    "Regression 10. KTX Chosen Model",
    "Y_{it}=\\alpha_i+\\tau_t+\\delta KTXChosen_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("ktx_chosen")
)

add_spec(
    "rob01_saving_excluding_already_treated",
    "Robustness 1. Continuous Saving, Excluding Already-Treated Regions",
    "Y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("saving"),
    filter_fun = function(x) x$already_treated_2007 == 0,
    sample_note = "Regions with $Within2h_{i,2007}=1$ or $KTXChosen_{i,2007}=1$ are excluded."
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

    add_spec(
        paste0("rob02_threshold_", suffix),
        paste0("Robustness 2. Threshold Access, ", label, " Hours"),
        paste0(
            "Y_{it}=\\alpha_i+\\tau_t+\\delta Within",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c(within_var),
        filter_fun = base_filter,
        sample_note = paste0("Regions already within ", label, " hours in 2007 are excluded.")
    )

    add_spec(
        paste0("rob03_hybrid_threshold_", suffix),
        paste0("Robustness 3. Hybrid Saving + Threshold Access, ", label, " Hours"),
        paste0(
            "Y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\delta Within",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c("saving", within_var),
        filter_fun = base_filter,
        sample_note = paste0("Regions already within ", label, " hours in 2007 are excluded.")
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

    add_spec(
        paste0("rob04_ktx_threshold_", suffix),
        paste0("Robustness 4. KTX Threshold Access, ", label, " Hours"),
        paste0(
            "Y_{it}=\\alpha_i+\\tau_t+\\delta KTXWithin",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c(ktx_within_var),
        filter_fun = base_filter,
        sample_note = paste0("Regions already KTX-within ", label, " hours in 2007 are excluded.")
    )

    add_spec(
        paste0("rob05_hybrid_ktx_threshold_", suffix),
        paste0("Robustness 5. Hybrid Saving + KTX Threshold Access, ", label, " Hours"),
        paste0(
            "Y_{it}=\\alpha_i+\\tau_t+\\beta Saving_{it}+\\delta KTXWithin",
            label,
            "h_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}"
        ),
        c("saving", ktx_within_var),
        filter_fun = base_filter,
        sample_note = paste0("Regions already KTX-within ", label, " hours in 2007 are excluded.")
    )
}

add_spec(
    "rob06_ktx_chosen",
    "Robustness 6. KTX Chosen, Excluding Baseline KTX-Chosen Regions",
    "Y_{it}=\\alpha_i+\\tau_t+\\delta KTXChosen_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("ktx_chosen"),
    filter_fun = function(x) x$ktx_chosen_2007 == 0,
    sample_note = "Regions where KTX was already the fastest route in 2007 are excluded."
)

add_spec(
    "direct_travel_time_level",
    "Direct Travel-Time Level Model",
    "Y_{it}=\\alpha_i+\\tau_t+\\beta TravelTime_{it}+\\gamma\\log(Population_{it})+\\epsilon_{it}",
    c("travel_time_hour")
)

tex_escape <- function(x) {
    x <- gsub("&", "\\\\&", x, fixed = TRUE)
    x
}

appendix_lines <- c(
    "\\documentclass[a4paper, 10pt]{article}",
    "\\usepackage{amsmath}",
    "\\usepackage{amssymb}",
    "\\usepackage{booktabs}",
    "\\usepackage{geometry}",
    "\\usepackage{kotex}",
    "\\usepackage{float}",
    "\\begin{document}",
    "\\section{2026-05-12 Regression Appendix}",
    "이 appendix는 2026-05-12 분석에서 사용한 회귀식들을 미팅자료 형식으로 재정리한 것이다.",
    "병원 표는 병원 type별로 분리하였고, 각 표의 열은 hospital\\_no, net\\_entry, exit\\_no, exit\\_rate, entry\\_no, entry\\_rate이다.",
    "의사 표는 인턴, 레지던트, 전문의, 일반의를 하나의 표에 정리하였다.",
    "모든 회귀식은 서울, 경기, 인천, 제주를 제외하고 region fixed effects, year fixed effects, log population control을 포함한다.",
    ""
)

for (spec in specs) {
    appendix_lines <- c(
        appendix_lines,
        paste0("\\subsection{", tex_escape(spec$title), "}"),
        "\\begin{align*}",
        paste0("    ", spec$equation),
        "\\end{align*}"
    )

    if (!is.null(spec$sample_note)) {
        appendix_lines <- c(appendix_lines, spec$sample_note)
    }

    for (type_name in names(hospital_types)) {
        type <- hospital_types[[type_name]]
        outcome_vars <- vapply(
            hospital_outcome_suffixes,
            function(suffix) {
                if (suffix == "hospital_no") {
                    return(type$sample)
                }

                paste0(type$prefix, "_", suffix)
            },
            character(1)
        )
        names(outcome_vars) <- names(hospital_outcome_suffixes)

        models <- fit_models(
            panel,
            outcome_vars,
            spec$treatment_vars,
            filter_fun = spec$filter_fun,
            horizon = spec$horizon,
            hospital_sample_var = type$sample
        )

        table_name <- paste0(spec$id, "_hospital_", type_name, ".tex")
        write_model_table(
            models,
            file.path(TABLES, table_name),
            spec$treatment_vars
        )

        appendix_lines <- c(
            appendix_lines,
            "\\begin{table}[H]",
            "\\centering",
            paste0("\\caption{", tex_escape(spec$title), ": ", type$label, "}"),
            paste0("\\input{tables/", table_name, "}"),
            "\\end{table}",
            ""
        )
    }

    doctor_models <- fit_models(
        panel,
        doctor_outcomes,
        spec$treatment_vars,
        filter_fun = spec$filter_fun,
        horizon = spec$horizon
    )

    doctor_table_name <- paste0(spec$id, "_doctor.tex")
    write_model_table(
        doctor_models,
        file.path(TABLES, doctor_table_name),
        spec$treatment_vars
    )

    appendix_lines <- c(
        appendix_lines,
        "\\begin{table}[H]",
        "\\centering",
        paste0("\\caption{", tex_escape(spec$title), ": 의사}"),
        paste0("\\input{tables/", doctor_table_name, "}"),
        "\\end{table}",
        ""
    )
}

appendix_lines <- c(appendix_lines, "\\end{document}")

writeLines(appendix_lines, file.path(APPENDIX, "2026-0512_regression_appendix.tex"))

dbDisconnect(con, shutdown = TRUE)
