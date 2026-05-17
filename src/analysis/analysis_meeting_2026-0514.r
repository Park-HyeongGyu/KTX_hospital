library(DBI)
library(duckdb)
library(fixest)
library(did)
library(glue)
library(knitr)

source("config.r")

con <- dbConnect(duckdb(), "analysis_db.duckdb")

MEETING <- file.path(ROOT, "memo", "2026-0514_미팅")

clean_hospital_file <- file.path(CLEAN, "clean_hospital_by_type.parquet")
clean_doctor_file <- file.path(CLEAN, "clean_doctor_by_level.parquet")
clean_shock_file <- file.path(CLEAN, "clean_shock_30.parquet")
clean_population_file <- file.path(CLEAN, "clean_population.parquet")

excluded_sido <- "'서울', '경기', '인천', '제주'"

set.seed(20260514)
cs_bootstrap_iterations <- 99

dbExecute(con, glue("
    CREATE OR REPLACE TABLE meeting_base_hospital AS
    SELECT
        h.region_sido,
        h.region_sigungu,
        h.hospital_type,
        h.year,
        h.hospital_no,
        h.net_entry,
        h.exit_no,
        h.exit_rate,
        h.entry_no,
        h.entry_rate,
        s.shock_station,
        s.line,
        s.distance_to_station,
        s.ktx_date,
        s.shock_year,
        s.ktx_shock_did,
        LN(p.population) AS log_population
    FROM read_parquet('{clean_hospital_file}') AS h
    LEFT JOIN read_parquet('{clean_shock_file}') AS s
        USING (year, region_sido, region_sigungu)
    LEFT JOIN read_parquet('{clean_population_file}') AS p
        USING (year, region_sido, region_sigungu)
    WHERE
        h.year BETWEEN 2007 AND 2025 AND
        h.region_sido NOT IN ({excluded_sido})
"))

dbExecute(con, glue("
    CREATE OR REPLACE TABLE meeting_base_doctor AS
    SELECT
        d.region_sido,
        d.region_sigungu,
        d.doctor_level,
        d.year,
        d.doctor_no,
        s.shock_station,
        s.line,
        s.distance_to_station,
        s.ktx_date,
        s.shock_year,
        s.ktx_shock_did,
        LN(p.population) AS log_population
    FROM read_parquet('{clean_doctor_file}') AS d
    LEFT JOIN read_parquet('{clean_shock_file}') AS s
        USING (year, region_sido, region_sigungu)
    LEFT JOIN read_parquet('{clean_population_file}') AS p
        USING (year, region_sido, region_sigungu)
    WHERE
        d.year BETWEEN 2007 AND 2025 AND
        d.region_sido NOT IN ({excluded_sido}) AND
        d.doctor_level IN ('인턴', '레지던트', '전문의', '일반의')
"))

dbExecute(con, "
    CREATE OR REPLACE TABLE meeting_panel_hospital_full AS
    SELECT *
    FROM meeting_base_hospital
")

make_hospital_panel <- function(table_name, hospital_type_name) {
    dbExecute(con, glue("
        CREATE OR REPLACE TABLE {`table_name`} AS
        WITH eligible_regions AS (
            SELECT
                region_sido,
                region_sigungu
            FROM meeting_base_hospital
            WHERE hospital_type = '{hospital_type_name}'
            GROUP BY region_sido, region_sigungu
            HAVING SUM(hospital_no) > 0
        )
        SELECT b.*
        FROM meeting_base_hospital AS b
        INNER JOIN eligible_regions AS e
            USING (region_sido, region_sigungu)
    "))
}

make_hospital_panel("meeting_panel_hospital_clinic", "의원")
make_hospital_panel("meeting_panel_hospital_secondary", "병원")
make_hospital_panel("meeting_panel_hospital_general", "종합병원")
make_hospital_panel("meeting_panel_hospital_tertiary", "상급종합병원")

dbExecute(con, "
    CREATE OR REPLACE TABLE meeting_panel_doctor AS
    SELECT *
    FROM meeting_base_doctor
")

format_regions_latex <- function(x, max_regions = 15, regions_per_line = 4) {
    if (is.na(x) || nchar(x) == 0) {
        return("")
    }

    regions <- strsplit(x, ", ", fixed = TRUE)[[1]]

    if (length(regions) > max_regions) {
        regions <- c(regions[1:max_regions], "...")
    }

    line_id <- ceiling(seq_along(regions) / regions_per_line)
    lines <- split(regions, line_id)
    lines <- vapply(lines, paste, collapse = ", ", character(1))

    paste0("\\shortstack[l]{", paste(lines, collapse = " \\\\ "), "}")
}

write_summary_stats <- function(panel_name, file_name) {
    summary_stats <- dbGetQuery(con, glue("
        WITH region_base AS (
            SELECT DISTINCT
                region_sido,
                region_sigungu,
                shock_year
            FROM {`panel_name`}
        )
        SELECT
            CASE
                WHEN shock_year IS NULL THEN 'NA'
                ELSE CAST(shock_year AS VARCHAR)
            END AS shock_year,
            COUNT(*) AS number_of_regions,
            string_agg(
                region_sido || ' ' || region_sigungu,
                ', '
                ORDER BY region_sido, region_sigungu
            ) AS regions
        FROM region_base
        GROUP BY shock_year
        ORDER BY
            CASE WHEN shock_year IS NULL THEN 1 ELSE 0 END,
            shock_year
    "))

    summary_stats$regions <- vapply(
        summary_stats$regions,
        format_regions_latex,
        character(1)
    )

    summary_stats_tex <- kable(
        summary_stats,
        format = "latex",
        booktabs = TRUE,
        escape = FALSE,
        col.names = c("shock year", "number", "regions"),
        align = c("l", "r", "l"),
        linesep = rep("\\midrule", max(nrow(summary_stats) - 1, 0))
    )

    writeLines(summary_stats_tex, file.path(MEETING, file_name))
}

hospital_specs <- list(
    full = list(panel = "meeting_panel_hospital_full", hospital_type = NULL, label = "Full"),
    clinic = list(panel = "meeting_panel_hospital_clinic", hospital_type = "의원", label = "Clinic"),
    secondary = list(panel = "meeting_panel_hospital_secondary", hospital_type = "병원", label = "Hospital"),
    general = list(panel = "meeting_panel_hospital_general", hospital_type = "종합병원", label = "General hospital"),
    tertiary = list(panel = "meeting_panel_hospital_tertiary", hospital_type = "상급종합병원", label = "Tertiary hospital")
)

for (spec_name in names(hospital_specs)) {
    write_summary_stats(
        hospital_specs[[spec_name]]$panel,
        glue("meeting_summary_stats_{spec_name}.tex")
    )
}

write_summary_stats("meeting_panel_doctor", "meeting_summary_stats_doctor.tex")

hospital_outcomes <- c(
    "hospital_no",
    "net_entry",
    "exit_no",
    "exit_rate",
    "entry_no",
    "entry_rate"
)

outcome_dict <- c(
    hospital_no = "hospital\\_no",
    net_entry = "net\\_entry",
    exit_no = "exit\\_no",
    exit_rate = "exit\\_rate",
    entry_no = "entry\\_no",
    entry_rate = "entry\\_rate",
    intern = "intern",
    resident = "resident",
    specialist = "specialist",
    general_doctor = "general\\_doctor"
)

get_hospital_model_data <- function(panel_name, hospital_type = NULL) {
    if (is.null(hospital_type)) {
        query <- glue("
            SELECT
                region_sido || '_' || region_sigungu AS region,
                region_sido,
                region_sigungu,
                year,
                MAX(ktx_shock_did) AS ktx_shock_did,
                MIN(shock_year) AS shock_year,
                MAX(log_population) AS log_population,
                SUM(hospital_no) AS hospital_no,
                SUM(net_entry) AS net_entry,
                SUM(exit_no) AS exit_no,
                CASE
                    WHEN SUM(hospital_no) = 0 THEN NULL
                    ELSE CAST(SUM(exit_no) AS DOUBLE) / SUM(hospital_no)
                END AS exit_rate,
                SUM(entry_no) AS entry_no,
                CASE
                    WHEN SUM(hospital_no) = 0 THEN NULL
                    ELSE CAST(SUM(entry_no) AS DOUBLE) / SUM(hospital_no)
                END AS entry_rate
            FROM {`panel_name`}
            GROUP BY region_sido, region_sigungu, year
            ORDER BY region, year
        ")
    } else {
        query <- glue("
            SELECT
                region_sido || '_' || region_sigungu AS region,
                region_sido,
                region_sigungu,
                year,
                ktx_shock_did,
                shock_year,
                log_population,
                hospital_no,
                net_entry,
                exit_no,
                exit_rate,
                entry_no,
                entry_rate
            FROM {`panel_name`}
            WHERE hospital_type = '{hospital_type}'
            ORDER BY region, year
        ")
    }

    dbGetQuery(con, query)
}

get_doctor_model_data <- function() {
    dbGetQuery(con, "
        SELECT
            region_sido || '_' || region_sigungu AS region,
            region_sido,
            region_sigungu,
            year,
            MAX(ktx_shock_did) AS ktx_shock_did,
            MIN(shock_year) AS shock_year,
            MAX(log_population) AS log_population,
            SUM(CASE WHEN doctor_level = '인턴' THEN doctor_no ELSE 0 END) AS intern,
            SUM(CASE WHEN doctor_level = '레지던트' THEN doctor_no ELSE 0 END) AS resident,
            SUM(CASE WHEN doctor_level = '전문의' THEN doctor_no ELSE 0 END) AS specialist,
            SUM(CASE WHEN doctor_level = '일반의' THEN doctor_no ELSE 0 END) AS general_doctor
        FROM meeting_panel_doctor
        GROUP BY region_sido, region_sigungu, year
        ORDER BY region, year
    ")
}

run_twfe_models <- function(model_data, outcomes) {
    model_list <- list()
    skipped_outcomes <- character(0)

    model_data <- model_data[
        (is.na(model_data$shock_year) | model_data$shock_year > min(model_data$year, na.rm = TRUE)) &
            !is.na(model_data$log_population),
    ]

    for (outcome in outcomes) {
        outcome_data <- model_data[[outcome]]
        outcome_data <- outcome_data[!is.na(outcome_data)]

        if (length(outcome_data) == 0 || length(unique(outcome_data)) <= 1) {
            skipped_outcomes <- c(skipped_outcomes, outcome)
            next
        }

        twfe_formula <- as.formula(glue("{outcome} ~ ktx_shock_did + log_population | region + year"))

        model_list[[outcome]] <- feols(
            twfe_formula,
            data = model_data,
            cluster = ~region
        )

        model_list[[outcome]]$meeting_region_count <- length(unique(
            model_data$region[!is.na(model_data[[outcome]])]
        ))
    }

    attr(model_list, "skipped_outcomes") <- skipped_outcomes
    model_list
}

write_twfe_table <- function(model_list, file_name) {
    skipped_outcomes <- attr(model_list, "skipped_outcomes")

    if (length(model_list) == 0) {
        writeLines("% No estimable TWFE models.", file.path(MEETING, file_name))
        return(invisible(NULL))
    }

    twfe_tex <- etable(
        model_list,
        tex = TRUE,
        style.tex = style.tex("aer", tablefoot = FALSE),
        keep_raw = "^ktx_shock_did$",
        coefstat = "se",
        se.below = TRUE,
        fitstat = ~n + r2,
        dict = c("ktx_shock_did" = "$\\beta$"),
        signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
    )

    region_counts <- vapply(
        model_list,
        function(model) {
            format(model$meeting_region_count, big.mark = ",", scientific = FALSE)
        },
        character(1)
    )
    region_row <- paste0(
        "   Region count         & ",
        paste(region_counts, collapse = "           & "),
        "\\\\"
    )
    observation_line <- grep("^   Observations", twfe_tex)
    if (length(observation_line) == 1) {
        twfe_tex <- append(twfe_tex, region_row, after = observation_line - 1)
    }

    if (length(skipped_outcomes) > 0) {
        twfe_tex <- c(
            paste0("% Skipped outcomes: ", paste(skipped_outcomes, collapse = ", ")),
            twfe_tex
        )
    }

    writeLines(twfe_tex, file.path(MEETING, file_name))
}

estimate_cs_simple_att <- function(cs_data, outcome) {
    cs_data <- cs_data[, c("region", "year", "first_treat_year", outcome)]
    cs_data <- cs_data[!is.na(cs_data[[outcome]]), ]

    treated_years <- sort(unique(cs_data$first_treat_year[
        is.finite(cs_data$first_treat_year) &
            cs_data$first_treat_year > min(cs_data$year, na.rm = TRUE)
    ]))

    att_cells <- data.frame(
        group = numeric(),
        year = numeric(),
        att = numeric(),
        weight = numeric(),
        stringsAsFactors = FALSE
    )

    for (group_year in treated_years) {
        pre_year <- group_year - 1
        post_years <- sort(unique(cs_data$year[cs_data$year >= group_year]))
        group_regions <- unique(cs_data$region[cs_data$first_treat_year == group_year])

        for (post_year in post_years) {
            control_regions <- unique(cs_data$region[
                is.infinite(cs_data$first_treat_year) |
                    cs_data$first_treat_year > post_year
            ])

            pre_data <- cs_data[cs_data$year == pre_year, c("region", outcome)]
            post_data <- cs_data[cs_data$year == post_year, c("region", outcome)]
            names(pre_data)[2] <- "y_pre"
            names(post_data)[2] <- "y_post"
            delta_data <- merge(pre_data, post_data, by = "region")
            delta_data$delta_y <- delta_data$y_post - delta_data$y_pre

            treated_delta <- delta_data$delta_y[delta_data$region %in% group_regions]
            control_delta <- delta_data$delta_y[delta_data$region %in% control_regions]

            if (length(treated_delta) == 0 || length(control_delta) == 0) {
                next
            }

            att_cells <- rbind(
                att_cells,
                data.frame(
                    group = group_year,
                    year = post_year,
                    att = mean(treated_delta) - mean(control_delta),
                    weight = length(treated_delta),
                    stringsAsFactors = FALSE
                )
            )
        }
    }

    if (nrow(att_cells) == 0) {
        return(NA_real_)
    }

    weighted.mean(att_cells$att, att_cells$weight)
}

bootstrap_cs_simple_se <- function(cs_data, outcome, iterations = cs_bootstrap_iterations) {
    regions <- unique(cs_data$region)
    boot_att <- numeric(iterations)

    for (iteration in seq_len(iterations)) {
        sampled_regions <- sample(regions, length(regions), replace = TRUE)
        boot_data <- do.call(
            rbind,
            lapply(seq_along(sampled_regions), function(index) {
                region_data <- cs_data[cs_data$region == sampled_regions[index], ]
                region_data$region <- paste0(region_data$region, "__boot", index)
                region_data
            })
        )

        boot_att[iteration] <- estimate_cs_simple_att(boot_data, outcome)
    }

    stats::sd(boot_att, na.rm = TRUE)
}

run_cs_simple_models <- function(model_data, outcomes) {
    cs_results <- data.frame(
        outcome = character(),
        estimate = numeric(),
        se = numeric(),
        p_value = numeric(),
        nobs = integer(),
        region_count = integer(),
        stringsAsFactors = FALSE
    )
    skipped_outcomes <- character(0)

    cs_base <- model_data
    cs_base$first_treat_year <- ifelse(is.na(cs_base$shock_year), Inf, cs_base$shock_year)
    cs_base <- cs_base[
        is.infinite(cs_base$first_treat_year) |
            cs_base$first_treat_year > min(cs_base$year, na.rm = TRUE),
    ]

    for (outcome in outcomes) {
        cs_data <- cs_base[, c("region", "year", "first_treat_year", outcome)]
        cs_data <- cs_data[!is.na(cs_data[[outcome]]), ]

        if (
            nrow(cs_data) == 0 ||
            length(unique(cs_data$first_treat_year[is.finite(cs_data$first_treat_year)])) == 0
        ) {
            skipped_outcomes <- c(skipped_outcomes, outcome)
            next
        }

        cs_att <- tryCatch(
            estimate_cs_simple_att(cs_data, outcome),
            error = function(e) {
                message(glue("Skipped C&S {outcome}: {conditionMessage(e)}"))
                NA_real_
            }
        )

        if (is.na(cs_att)) {
            cs_att <- NA_real_
            cs_se <- NA_real_
        } else if (length(unique(cs_data[[outcome]])) <= 1) {
            cs_se <- 0
        } else {
            cs_se <- bootstrap_cs_simple_se(cs_data, outcome)
        }

        cs_results <- rbind(
            cs_results,
            data.frame(
                outcome = outcome,
                estimate = cs_att,
                se = cs_se,
                p_value = ifelse(cs_se > 0, 2 * pnorm(-abs(cs_att / cs_se)), NA_real_),
                nobs = nrow(cs_data),
                region_count = length(unique(cs_data$region)),
                stringsAsFactors = FALSE
            )
        )
    }

    attr(cs_results, "skipped_outcomes") <- skipped_outcomes
    cs_results
}

format_stars <- function(p_value) {
    ifelse(
        is.na(p_value), "",
        ifelse(p_value < 0.01, "***", ifelse(p_value < 0.05, "**", ifelse(p_value < 0.1, "*", "")))
    )
}

write_cs_table <- function(cs_results, file_name) {
    skipped_outcomes <- attr(cs_results, "skipped_outcomes")

    if (nrow(cs_results) == 0) {
        writeLines("% No estimable Callaway-Sant'Anna simple ATT models.", file.path(MEETING, file_name))
        return(invisible(NULL))
    }

    column_labels <- outcome_dict[cs_results$outcome]
    column_labels[is.na(column_labels)] <- cs_results$outcome[is.na(column_labels)]

    table_body <- data.frame(
        statistic = c("$ATT$", "", "Region count", "Observations"),
        stringsAsFactors = FALSE
    )

    for (i in seq_len(nrow(cs_results))) {
        value <- paste0(
            sprintf("%.3f", cs_results$estimate[i]),
            format_stars(cs_results$p_value[i])
        )
        se <- paste0("(", sprintf("%.3f", cs_results$se[i]), ")")
        region_count <- format(cs_results$region_count[i], big.mark = ",", scientific = FALSE)
        nobs <- format(cs_results$nobs[i], big.mark = ",", scientific = FALSE)

        table_body[[column_labels[i]]] <- c(value, se, region_count, nobs)
    }

    cs_tex <- kable(
        table_body,
        format = "latex",
        booktabs = TRUE,
        escape = FALSE,
        align = c("l", rep("c", ncol(table_body) - 1)),
        col.names = c("", column_labels),
        linesep = c("", "\\midrule", "")
    )

    if (length(skipped_outcomes) > 0) {
        cs_tex <- c(
            paste0("% Skipped outcomes: ", paste(skipped_outcomes, collapse = ", ")),
            cs_tex
        )
    }

    writeLines(cs_tex, file.path(MEETING, file_name))
}

for (spec_name in names(hospital_specs)) {
    spec <- hospital_specs[[spec_name]]
    model_data <- get_hospital_model_data(spec$panel, spec$hospital_type)

    twfe_models <- run_twfe_models(model_data, hospital_outcomes)
    write_twfe_table(twfe_models, glue("meeting_twfe_hospital_{spec_name}.tex"))

    cs_models <- run_cs_simple_models(model_data, hospital_outcomes)
    write_cs_table(cs_models, glue("meeting_cs_hospital_{spec_name}.tex"))
}

doctor_outcomes <- c("intern", "resident", "specialist", "general_doctor")
doctor_model_data <- get_doctor_model_data()

doctor_twfe_models <- run_twfe_models(doctor_model_data, doctor_outcomes)
write_twfe_table(doctor_twfe_models, "meeting_twfe_doctor.tex")

doctor_cs_models <- run_cs_simple_models(doctor_model_data, doctor_outcomes)
write_cs_table(doctor_cs_models, "meeting_cs_doctor.tex")

event_terms <- c(
    "event_m5",
    "event_m4",
    "event_m3",
    "event_m2",
    "event_p0",
    "event_p1",
    "event_p2",
    "event_p3",
    "event_p4",
    "event_p5"
)

event_dict <- c(
    event_m5 = "$t \\leq -5$",
    event_m4 = "$t = -4$",
    event_m3 = "$t = -3$",
    event_m2 = "$t = -2$",
    event_p0 = "$t = 0$",
    event_p1 = "$t = 1$",
    event_p2 = "$t = 2$",
    event_p3 = "$t = 3$",
    event_p4 = "$t = 4$",
    event_p5 = "$t \\geq 5$"
)

add_event_study_terms <- function(model_data) {
    event_data <- model_data[
        (is.na(model_data$shock_year) | model_data$shock_year > min(model_data$year, na.rm = TRUE)) &
            !is.na(model_data$log_population),
    ]

    event_data$treated_ever <- !is.na(event_data$shock_year)
    event_data$event_time <- ifelse(
        event_data$treated_ever,
        event_data$year - event_data$shock_year,
        NA_real_
    )

    for (event_term in event_terms) {
        event_data[[event_term]] <- 0L
    }

    event_data$event_m5 <- as.integer(event_data$treated_ever & event_data$event_time <= -5)
    event_data$event_m4 <- as.integer(event_data$treated_ever & event_data$event_time == -4)
    event_data$event_m3 <- as.integer(event_data$treated_ever & event_data$event_time == -3)
    event_data$event_m2 <- as.integer(event_data$treated_ever & event_data$event_time == -2)
    event_data$event_p0 <- as.integer(event_data$treated_ever & event_data$event_time == 0)
    event_data$event_p1 <- as.integer(event_data$treated_ever & event_data$event_time == 1)
    event_data$event_p2 <- as.integer(event_data$treated_ever & event_data$event_time == 2)
    event_data$event_p3 <- as.integer(event_data$treated_ever & event_data$event_time == 3)
    event_data$event_p4 <- as.integer(event_data$treated_ever & event_data$event_time == 4)
    event_data$event_p5 <- as.integer(event_data$treated_ever & event_data$event_time >= 5)

    event_data
}

run_event_study_models <- function(model_data, outcomes) {
    event_data <- add_event_study_terms(model_data)
    model_list <- list()
    skipped_outcomes <- character(0)

    for (outcome in outcomes) {
        outcome_data <- event_data[[outcome]]
        outcome_data <- outcome_data[!is.na(outcome_data)]

        if (length(outcome_data) == 0 || length(unique(outcome_data)) <= 1) {
            skipped_outcomes <- c(skipped_outcomes, outcome)
            next
        }

        event_formula <- as.formula(glue(
            "{outcome} ~ {paste(event_terms, collapse = ' + ')} + log_population | region + year"
        ))

        model_list[[outcome]] <- feols(
            event_formula,
            data = event_data,
            cluster = ~region
        )

        model_list[[outcome]]$meeting_region_count <- length(unique(
            event_data$region[!is.na(event_data[[outcome]])]
        ))
    }

    attr(model_list, "skipped_outcomes") <- skipped_outcomes
    model_list
}

write_event_study_table <- function(model_list, file_name) {
    skipped_outcomes <- attr(model_list, "skipped_outcomes")

    if (length(model_list) == 0) {
        writeLines("% No estimable event-study models.", file.path(MEETING, file_name))
        return(invisible(NULL))
    }

    region_counts <- vapply(
        model_list,
        function(model) {
            format(model$meeting_region_count, big.mark = ",", scientific = FALSE)
        },
        character(1)
    )

    event_tex <- etable(
        model_list,
        tex = TRUE,
        style.tex = style.tex("aer", tablefoot = FALSE),
        headers = outcome_dict[names(model_list)],
        depvar = FALSE,
        keep_raw = paste0("^(", paste(event_terms, collapse = "|"), ")$"),
        coefstat = "se",
        se.below = TRUE,
        fitstat = ~n + r2,
        extralines = list(
            "Log population control" = rep("Yes", length(model_list)),
            "Region FE" = rep("Yes", length(model_list)),
            "Year FE" = rep("Yes", length(model_list)),
            "Regions" = region_counts
        ),
        drop.section = "fixef",
        dict = c(event_dict, outcome_dict),
        signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
    )

    if (length(skipped_outcomes) > 0) {
        event_tex <- c(
            paste0("% Skipped outcomes: ", paste(skipped_outcomes, collapse = ", ")),
            event_tex
        )
    }

    writeLines(event_tex, file.path(MEETING, file_name))
}

for (spec_name in names(hospital_specs)[names(hospital_specs) != "full"]) {
    spec <- hospital_specs[[spec_name]]
    model_data <- get_hospital_model_data(spec$panel, spec$hospital_type)

    event_models <- run_event_study_models(model_data, hospital_outcomes)
    write_event_study_table(event_models, glue("meeting_event_hospital_{spec_name}.tex"))
}

doctor_event_models <- run_event_study_models(doctor_model_data, doctor_outcomes)
write_event_study_table(doctor_event_models, "meeting_event_doctor.tex")

dbDisconnect(con, shutdown = TRUE)
