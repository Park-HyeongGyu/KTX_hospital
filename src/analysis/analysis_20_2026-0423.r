library(DBI)
library(duckdb)
library(fixest)
library(did)
library(glue)
library(knitr)

source("config.r")

con <- dbConnect(duckdb(), "analysis_db.duckdb")
OUTPUT <- file.path(ROOT, "output", "20km")

clean_hospital_file <- file.path(CLEAN, "clean_hospital_by_type.parquet")
clean_shock_file <- file.path(CLEAN, "clean_shock_20.parquet")

dbExecute(con, glue("
    CREATE OR REPLACE TABLE base AS
    WITH shock_2007 AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{clean_shock_file}')
        WHERE shock_year <= 2007 -- Exclude already-treated
    )
    SELECT
        h.*,
        s.* EXCLUDE (year, region_sido, region_sigungu)
    FROM read_parquet('{clean_hospital_file}') AS h
    LEFT JOIN read_parquet('{clean_shock_file}') AS s
        USING (year, region_sido, region_sigungu)
    LEFT JOIN shock_2007 AS x
        USING (region_sido, region_sigungu)
    WHERE
        region_sido NOT IN ('서울', '경기', '인천', '제주') AND
        x.region_sido IS NULL AND
        year >= 2008
"))

dbExecute(con, "
    CREATE OR REPLACE TABLE panel_full AS
    SELECT *
    FROM base
")

dbExecute(con, "
    CREATE OR REPLACE TABLE panel_clinic AS
    WITH eligible_regions AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM base
        WHERE hospital_type = '의원'
          AND hospital_no >= 1
    )
    SELECT
        b.*
    FROM base AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
")

dbExecute(con, "
    CREATE OR REPLACE TABLE panel_secondary AS
    WITH eligible_regions AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM base
        WHERE hospital_type = '병원'
          AND hospital_no >= 1
    )
    SELECT
        b.*
    FROM base AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
")

dbExecute(con, "
    CREATE OR REPLACE TABLE panel_general AS
    WITH eligible_regions AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM base
        WHERE hospital_type = '종합병원'
          AND hospital_no >= 1
    )
    SELECT
        b.*
    FROM base AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
")

dbExecute(con, "
    CREATE OR REPLACE TABLE panel_tertiary AS
    WITH eligible_regions AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM base
        WHERE hospital_type = '상급종합병원'
          AND hospital_no >= 1
    )
    SELECT
        b.*
    FROM base AS b
    INNER JOIN eligible_regions AS e
        USING (region_sido, region_sigungu)
")


############################################################
#### Summary Statistics ####################################
############################################################

# 지역 최대 15개, 한 줄에 4개씩 끊기
format_regions_latex <- function(x, max_regions = 15, regions_per_line = 4) {
    regions <- strsplit(x, ", ", fixed = TRUE)[[1]]

    if (length(regions) > max_regions) {
        regions <- c(regions[1:max_regions], "...")
    }

    line_id <- ceiling(seq_along(regions) / regions_per_line)
    lines <- split(regions, line_id)
    lines <- vapply(lines, paste, collapse = ", ", character(1))

    paste0("\\shortstack[l]{", paste(lines, collapse = " \\\\ "), "}")
}

create_summary_stats_table <- function(panel_name, summary_name) {
    dbExecute(con, glue("
        CREATE OR REPLACE TABLE {`summary_name`} AS
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
}

write_summary_stats <- function(summary_name, file_name) {
    summary_stats_file <- file.path(OUTPUT, file_name)
    summary_stats <- dbReadTable(con, summary_name)

    print(summary_stats, row.names = FALSE)

    summary_stats_latex <- summary_stats
    summary_stats_latex$regions <- vapply(
        summary_stats_latex$regions,
        format_regions_latex,
        character(1)
    )

    summary_stats_tex <- kable(
        summary_stats_latex,
        format = "latex",
        booktabs = TRUE,
        escape = FALSE,
        col.names = c("shock year", "number", "regions"),
        align = c("l", "r", "l"),
        linesep = rep("\\midrule", max(nrow(summary_stats_latex) - 1, 0))
    )

    writeLines(summary_stats_tex, summary_stats_file)
}

create_summary_stats_table("panel_full", "summary_stats_full")
create_summary_stats_table("panel_clinic", "summary_stats_clinic")
create_summary_stats_table("panel_secondary", "summary_stats_secondary")
create_summary_stats_table("panel_general", "summary_stats_general")
create_summary_stats_table("panel_tertiary", "summary_stats_tertiary")

write_summary_stats("summary_stats_full", "summary_stats_full.tex")
write_summary_stats("summary_stats_clinic", "summary_stats_clinic.tex")
write_summary_stats("summary_stats_secondary", "summary_stats_secondary.tex")
write_summary_stats("summary_stats_general", "summary_stats_general.tex")
write_summary_stats("summary_stats_tertiary", "summary_stats_tertiary.tex")

dbExecute(con, "DROP TABLE IF EXISTS summary_stats_full")
dbExecute(con, "DROP TABLE IF EXISTS summary_stats_clinic")
dbExecute(con, "DROP TABLE IF EXISTS summary_stats_secondary")
dbExecute(con, "DROP TABLE IF EXISTS summary_stats_general")
dbExecute(con, "DROP TABLE IF EXISTS summary_stats_tertiary")

# Garbage Collection: Remove functions and temporary variables to free up memory
rm(format_regions_latex, create_summary_stats_table, write_summary_stats)
gc()

############################################################
#### TWFE DiD ##############################################
############################################################

twfe_outcomes <- c(
    "hospital_no",
    "net_entry",
    "exit_no",
    "exit_rate",
    "entry_no",
    "entry_rate"
)

get_twfe_data <- function(panel_name, hospital_type = NULL) {
    if (is.null(hospital_type)) {
        query <- glue("
            SELECT
                region_sido || '_' || region_sigungu AS region,
                year,
                MAX(ktx_shock_did) AS ktx_shock_did,
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
                year,
                ktx_shock_did,
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

run_twfe_models <- function(panel_name, hospital_type = NULL) {
    panel_data <- get_twfe_data(panel_name, hospital_type)
    model_list <- list()
    skipped_outcomes <- character(0)

    for (outcome in twfe_outcomes) {
        outcome_data <- panel_data[[outcome]]
        outcome_data <- outcome_data[!is.na(outcome_data)]

        if (length(outcome_data) == 0 || length(unique(outcome_data)) <= 1) {
            skipped_outcomes <- c(skipped_outcomes, outcome)
            next
        }

        twfe_formula <- as.formula(
            glue("{outcome} ~ ktx_shock_did | region + year")
        )

        model_list[[outcome]] <- feols(
            twfe_formula,
            data = panel_data,
            cluster = ~region
        )
    }

    rm(panel_data, twfe_formula)
    gc()

    attr(model_list, "skipped_outcomes") <- skipped_outcomes
    model_list
}

write_twfe_table <- function(model_list, file_name) {
    twfe_file <- file.path(OUTPUT, file_name)
    skipped_outcomes <- attr(model_list, "skipped_outcomes")

    if (length(skipped_outcomes) > 0) {
        cat(
            "Skipped outcomes in",
            file_name,
            ":",
            paste(skipped_outcomes, collapse = ", "),
            "\n"
        )
    }

    print(
        etable(
            model_list,
            keep_raw = "^ktx_shock_did$",
            coefstat = "se",
            se.below = TRUE,
            fitstat = ~n + r2,
            dict = c("ktx_shock_did" = "$\\beta$"),
            signif.code = c("***" = 0.01, "**" = 0.05, "*" = 0.1)
        )
    )

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

    if (length(skipped_outcomes) > 0) {
        twfe_tex <- c(
            paste0(
                "% Skipped outcomes (constant or all NA): ",
                paste(skipped_outcomes, collapse = ", ")
            ),
            twfe_tex
        )
    }

    writeLines(twfe_tex, twfe_file)
}

twfe_full <- run_twfe_models("panel_full")
twfe_clinic <- run_twfe_models("panel_clinic", "의원")
twfe_secondary <- run_twfe_models("panel_secondary", "병원")
twfe_general <- run_twfe_models("panel_general", "종합병원")
twfe_tertiary <- run_twfe_models("panel_tertiary", "상급종합병원")

write_twfe_table(twfe_full, "twfe_did_full.tex")
write_twfe_table(twfe_clinic, "twfe_did_clinic.tex")
write_twfe_table(twfe_secondary, "twfe_did_secondary.tex")
write_twfe_table(twfe_general, "twfe_did_general.tex")
write_twfe_table(twfe_tertiary, "twfe_did_tertiary.tex")

rm(
    twfe_outcomes, get_twfe_data, run_twfe_models, write_twfe_table,
    twfe_full, twfe_clinic, twfe_secondary, twfe_general, twfe_tertiary
)

gc()

dbDisconnect(con, shutdown=TRUE)

