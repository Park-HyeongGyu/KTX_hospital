library(DBI)
library(duckdb)
library(ggplot2)
library(fixest)
library(did)
library(glue)

source("config.r")

con <- dbConnect(duckdb(), dbdir = ":memory:")
OUTPUT <- file.path(ROOT, "output", "2026-0425_fig")

# 그림을 좀 그려서 이게 진짜 좀 괜찮은 것들인지 확인해보기 위함.
# 약간 motivating figure 그린다는 느낌
# 일단 30km를 기준으로 잡아볼까?


############################################################
#### hospital number #######################################
############################################################
hospital_path <- file.path(CLEAN, "clean_hospital_by_type.parquet")
shock_30_path <- file.path(CLEAN, "clean_shock_30.parquet")
population_path <- file.path(CLEAN, "clean_population.parquet")


dbExecute(con, glue("
    CREATE OR REPLACE TEMP TABLE base_hospital AS
    WITH shock_2007 AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{shock_30_path}')
        WHERE shock_year <= 2007
    ) -- 2007년 이전 already treated 제거
    SELECT
        h.*,
        s.shock_station,
        s.line,
        s.distance_to_station,
        s.ktx_date,
        s.shock_year,
        s.ktx_shock_did,
        p.population
    FROM read_parquet('{hospital_path}') AS h
    LEFT JOIN read_parquet('{shock_30_path}') AS s
        USING (region_sido, region_sigungu, year)
    LEFT JOIN shock_2007 AS x
        USING (region_sido, region_sigungu)
    LEFT JOIN read_parquet('{population_path}') AS p
        USING (region_sido, region_sigungu, year)
    WHERE
        h.region_sido NOT IN ('서울', '경기', '인천', '제주') AND
        x.region_sido IS NULL AND
        h.year >= 2008
"))
# Exactly matched. Perfect match! Good!!


plot_data <- dbGetQuery(con, "
    WITH eligible_groups AS (
        SELECT
            region_sido,
            region_sigungu,
            hospital_type
        FROM base_hospital
        GROUP BY region_sido, region_sigungu, hospital_type
        HAVING MAX(COALESCE(hospital_no, 0)) > 0
    )
    SELECT
        b.region_sido,
        b.region_sigungu,
        b.hospital_type,
        b.year,
        b.hospital_no,
        b.shock_year,
        b.population
    FROM base_hospital AS b
    INNER JOIN eligible_groups AS e
        USING (region_sido, region_sigungu, hospital_type)
    ORDER BY b.region_sido, b.region_sigungu, b.hospital_type, b.year
")

get_slope_label <- function(model, label = "beta") {
    slope <- unname(coef(model)["year"])

    if (length(slope) == 0 || is.na(slope) || !is.finite(slope)) {
        return(NULL)
    }

    glue("{label} = {format(round(slope, 3), nsmall = 3)}")
}

get_population_scale <- function(outcome, population) {
    outcome_min <- min(outcome, na.rm = TRUE)
    outcome_max <- max(outcome, na.rm = TRUE)
    population_min <- min(population, na.rm = TRUE)
    population_max <- max(population, na.rm = TRUE)

    if (!is.finite(outcome_min)) {
        outcome_min <- 0
    }

    if (!is.finite(outcome_max)) {
        outcome_max <- 1
    }

    if (!is.finite(population_min)) {
        population_min <- 0
    }

    if (!is.finite(population_max)) {
        population_max <- 1
    }

    if (outcome_max == outcome_min) {
        outcome_max <- outcome_min + 1
    }

    if (population_max == population_min) {
        scale_factor <- 1
        scale_offset <- mean(c(outcome_min, outcome_max)) - population_min
    } else {
        scale_factor <- (outcome_max - outcome_min) / (population_max - population_min)
        scale_offset <- outcome_min - population_min * scale_factor
    }

    list(
        population_scaled = population * scale_factor + scale_offset,
        scale_factor = scale_factor,
        scale_offset = scale_offset
    )
}

plot_group <- function(group_data) {
    region_sido <- group_data$region_sido[1]
    region_sigungu <- group_data$region_sigungu[1]
    hospital_type <- group_data$hospital_type[1]
    shock_year_values <- unique(na.omit(group_data$shock_year))
    shock_year <- if (length(shock_year_values) == 0) NA_real_ else shock_year_values[1]
    population_median <- median(group_data$population, na.rm = TRUE)

    x_center <- mean(range(group_data$year, na.rm = TRUE))
    y_center <- mean(range(group_data$hospital_no, na.rm = TRUE))
    y_min <- min(group_data$hospital_no, na.rm = TRUE)
    y_max <- max(group_data$hospital_no, na.rm = TRUE)
    y_span <- y_max - y_min
    population_scale <- get_population_scale(group_data$hospital_no, group_data$population)
    group_data$population_scaled <- population_scale$population_scaled

    if (!is.finite(y_span) || y_span == 0) {
        y_span <- 1
    }

    p <- ggplot(group_data, aes(x = year, y = hospital_no)) +
        geom_point(size = 2, alpha = 0.8, color = "gray20") +
        geom_point(aes(y = population_scaled), size = 2, alpha = 0.7, color = "#33a02c", na.rm = TRUE) +
        labs(
            title = glue("{region_sido} {region_sigungu} - {hospital_type}"),
            x = "Year",
            y = "Hospital count"
        ) +
        scale_y_continuous(
            name = "Hospital count",
            sec.axis = sec_axis(
                ~ (. - population_scale$scale_offset) / population_scale$scale_factor,
                name = "Population"
            )
        ) +
        theme_minimal(base_size = 12) +
        theme(
            axis.title.y.right = element_text(color = "#33a02c"),
            axis.text.y.right = element_text(color = "#33a02c")
        ) +
        annotate(
            "text",
            x = x_center,
            y = y_center,
            label = glue("인구 중앙값: {format(round(population_median), big.mark = ',')}"),
            size = 4,
            color = "gray30"
        )

    if (!is.na(shock_year)) {
        pre_data <- subset(group_data, year < shock_year)
        post_data <- subset(group_data, year >= shock_year)

        p <- p + geom_vline(xintercept = shock_year, linetype = "dashed", color = "firebrick")

        if (nrow(pre_data) >= 2 && length(unique(pre_data$year)) >= 2) {
            pre_fit <- lm(hospital_no ~ year, data = pre_data)
            pre_line <- data.frame(year = seq(2007, shock_year, by = 1))
            pre_line$hospital_no <- predict(pre_fit, newdata = pre_line)
            pre_label <- get_slope_label(pre_fit)
            p <- p +
                geom_line(
                    data = pre_line,
                    aes(x = year, y = hospital_no),
                    color = "#1f78b4",
                    linewidth = 0.8,
                    inherit.aes = FALSE
                ) +
                annotate(
                    "text",
                    x = min(group_data$year, na.rm = TRUE),
                    y = y_max,
                    label = pre_label,
                    hjust = 0,
                    vjust = 1.2,
                    color = "#1f78b4",
                    size = 4
                )

            pre_ctrl_data <- subset(
                pre_data,
                !is.na(hospital_no) & !is.na(year) & !is.na(population) & population > 0
            )

            if (nrow(pre_ctrl_data) >= 3 && length(unique(pre_ctrl_data$year)) >= 2) {
                pre_ctrl_data$log_population <- log(pre_ctrl_data$population)
                pre_fit_ctrl <- lm(hospital_no ~ year + log_population, data = pre_ctrl_data)
                pre_ctrl_label <- get_slope_label(pre_fit_ctrl, "beta (log pop ctrl)")

                if (!is.null(pre_ctrl_label)) {
                    p <- p + annotate(
                        "text",
                        x = min(group_data$year, na.rm = TRUE),
                        y = y_max - 0.12 * y_span,
                        label = pre_ctrl_label,
                        hjust = 0,
                        vjust = 1.2,
                        color = "#33a02c",
                        size = 4
                    )
                }
            }
        }

        if (nrow(post_data) >= 2 && length(unique(post_data$year)) >= 2) {
            post_fit <- lm(hospital_no ~ year, data = post_data)
            post_line <- data.frame(year = seq(shock_year, 2025, by = 1))
            post_line$hospital_no <- predict(post_fit, newdata = post_line)
            post_label <- get_slope_label(post_fit)
            p <- p +
                geom_line(
                    data = post_line,
                    aes(x = year, y = hospital_no),
                    color = "#e31a1c",
                    linewidth = 0.8,
                    inherit.aes = FALSE
                ) +
                annotate(
                    "text",
                    x = max(group_data$year, na.rm = TRUE),
                    y = y_max - 0.12 * y_span,
                    label = post_label,
                    hjust = 1,
                    vjust = 1.2,
                    color = "#e31a1c",
                    size = 4
                )

            post_ctrl_data <- subset(
                post_data,
                !is.na(hospital_no) & !is.na(year) & !is.na(population) & population > 0
            )

            if (nrow(post_ctrl_data) >= 3 && length(unique(post_ctrl_data$year)) >= 2) {
                post_ctrl_data$log_population <- log(post_ctrl_data$population)
                post_fit_ctrl <- lm(hospital_no ~ year + log_population, data = post_ctrl_data)
                post_ctrl_label <- get_slope_label(post_fit_ctrl, "beta (log pop ctrl)")

                if (!is.null(post_ctrl_label)) {
                    p <- p + annotate(
                        "text",
                        x = max(group_data$year, na.rm = TRUE),
                        y = y_max - 0.24 * y_span,
                        label = post_ctrl_label,
                        hjust = 1,
                        vjust = 1.2,
                        color = "#33a02c",
                        size = 4
                    )
                }
            }
        }

        output_file <- file.path(
            OUTPUT,
            hospital_type,
            glue("처치_{region_sido}_{region_sigungu}.png")
        )
    } else {
        output_file <- file.path(
            OUTPUT,
            hospital_type,
            glue("대조군_{region_sido}_{region_sigungu}.png")
        )
    }

    dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
    ggsave(output_file, plot = p, width = 8, height = 6, dpi = 300)
}

group_keys <- unique(plot_data[c("region_sido", "region_sigungu", "hospital_type")])

for (i in seq_len(nrow(group_keys))) {
    key <- group_keys[i, ]
    message(glue("[hospital] {i}/{nrow(group_keys)}: {key$region_sido} {key$region_sigungu} - {key$hospital_type}"))
    group_data <- subset(
        plot_data,
        region_sido == key$region_sido &
            region_sigungu == key$region_sigungu &
            hospital_type == key$hospital_type
    )
    plot_group(group_data)
}


############################################################
#### doctor number #########################################
############################################################
doctor_path <- file.path(CLEAN, "clean_doctor_by_level.parquet")
shock_30_path <- file.path(CLEAN, "clean_shock_30.parquet")
population_path <- file.path(CLEAN, "clean_population.parquet")

dbExecute(con, glue("
    CREATE OR REPLACE TEMP TABLE base_doctor AS
    WITH shock_2007 AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{shock_30_path}')
        WHERE shock_year <= 2007
    ) -- 2007년 이전 already treated 제거
    SELECT
        d.*,
        s.shock_station,
        s.line,
        s.distance_to_station,
        s.ktx_date,
        s.shock_year,
        s.ktx_shock_did,
        p.population
    FROM read_parquet('{doctor_path}') AS d
    LEFT JOIN read_parquet('{shock_30_path}') AS s
        USING (region_sido, region_sigungu, year)
    LEFT JOIN shock_2007 AS x
        USING (region_sido, region_sigungu)
    LEFT JOIN read_parquet('{population_path}') AS p
        USING (region_sido, region_sigungu, year)
    WHERE
        d.region_sido NOT IN ('서울', '경기', '인천', '제주') AND
        x.region_sido IS NULL AND
        d.year >= 2008
"))

plot_doctor_data <- dbGetQuery(con, "
    WITH eligible_groups AS (
        SELECT
            region_sido,
            region_sigungu,
            doctor_level
        FROM base_doctor
        GROUP BY region_sido, region_sigungu, doctor_level
        HAVING MAX(COALESCE(doctor_no, 0)) > 0
    )
    SELECT
        b.region_sido,
        b.region_sigungu,
        b.doctor_level,
        b.year,
        b.doctor_no,
        b.shock_year,
        b.population
    FROM base_doctor AS b
    INNER JOIN eligible_groups AS e
        USING (region_sido, region_sigungu, doctor_level)
    ORDER BY b.region_sido, b.region_sigungu, b.doctor_level, b.year
")

plot_doctor_group <- function(group_data) {
    region_sido <- group_data$region_sido[1]
    region_sigungu <- group_data$region_sigungu[1]
    doctor_level <- group_data$doctor_level[1]
    shock_year_values <- unique(na.omit(group_data$shock_year))
    shock_year <- if (length(shock_year_values) == 0) NA_real_ else shock_year_values[1]
    population_median <- median(group_data$population, na.rm = TRUE)

    x_center <- mean(range(group_data$year, na.rm = TRUE))
    y_center <- mean(range(group_data$doctor_no, na.rm = TRUE))
    y_min <- min(group_data$doctor_no, na.rm = TRUE)
    y_max <- max(group_data$doctor_no, na.rm = TRUE)
    y_span <- y_max - y_min
    population_scale <- get_population_scale(group_data$doctor_no, group_data$population)
    group_data$population_scaled <- population_scale$population_scaled

    if (!is.finite(y_span) || y_span == 0) {
        y_span <- 1
    }

    p <- ggplot(group_data, aes(x = year, y = doctor_no)) +
        geom_point(size = 2, alpha = 0.8, color = "gray20") +
        geom_point(aes(y = population_scaled), size = 2, alpha = 0.7, color = "#33a02c", na.rm = TRUE) +
        labs(
            title = glue("{region_sido} {region_sigungu} - {doctor_level}"),
            x = "Year",
            y = "Doctor count"
        ) +
        scale_y_continuous(
            name = "Doctor count",
            sec.axis = sec_axis(
                ~ (. - population_scale$scale_offset) / population_scale$scale_factor,
                name = "Population"
            )
        ) +
        theme_minimal(base_size = 12) +
        theme(
            axis.title.y.right = element_text(color = "#33a02c"),
            axis.text.y.right = element_text(color = "#33a02c")
        ) +
        annotate(
            "text",
            x = x_center,
            y = y_center,
            label = glue("인구 중앙값: {format(round(population_median), big.mark = ',')}"),
            size = 4,
            color = "gray30"
        )

    if (!is.na(shock_year)) {
        pre_data <- subset(group_data, year < shock_year)
        post_data <- subset(group_data, year >= shock_year)

        p <- p + geom_vline(xintercept = shock_year, linetype = "dashed", color = "firebrick")

        if (nrow(pre_data) >= 2 && length(unique(pre_data$year)) >= 2) {
            pre_fit <- lm(doctor_no ~ year, data = pre_data)
            pre_line <- data.frame(year = seq(2007, shock_year, by = 1))
            pre_line$doctor_no <- predict(pre_fit, newdata = pre_line)
            pre_label <- get_slope_label(pre_fit)
            p <- p +
                geom_line(
                    data = pre_line,
                    aes(x = year, y = doctor_no),
                    color = "#1f78b4",
                    linewidth = 0.8,
                    inherit.aes = FALSE
                ) +
                annotate(
                    "text",
                    x = min(group_data$year, na.rm = TRUE),
                    y = y_max,
                    label = pre_label,
                    hjust = 0,
                    vjust = 1.2,
                    color = "#1f78b4",
                    size = 4
                )

            pre_ctrl_data <- subset(
                pre_data,
                !is.na(doctor_no) & !is.na(year) & !is.na(population) & population > 0
            )

            if (nrow(pre_ctrl_data) >= 3 && length(unique(pre_ctrl_data$year)) >= 2) {
                pre_ctrl_data$log_population <- log(pre_ctrl_data$population)
                pre_fit_ctrl <- lm(doctor_no ~ year + log_population, data = pre_ctrl_data)
                pre_ctrl_label <- get_slope_label(pre_fit_ctrl, "beta (log pop ctrl)")

                if (!is.null(pre_ctrl_label)) {
                    p <- p + annotate(
                        "text",
                        x = min(group_data$year, na.rm = TRUE),
                        y = y_max - 0.12 * y_span,
                        label = pre_ctrl_label,
                        hjust = 0,
                        vjust = 1.2,
                        color = "#33a02c",
                        size = 4
                    )
                }
            }
        }

        if (nrow(post_data) >= 2 && length(unique(post_data$year)) >= 2) {
            post_fit <- lm(doctor_no ~ year, data = post_data)
            post_line <- data.frame(year = seq(shock_year, 2025, by = 1))
            post_line$doctor_no <- predict(post_fit, newdata = post_line)
            post_label <- get_slope_label(post_fit)
            p <- p +
                geom_line(
                    data = post_line,
                    aes(x = year, y = doctor_no),
                    color = "#e31a1c",
                    linewidth = 0.8,
                    inherit.aes = FALSE
                ) +
                annotate(
                    "text",
                    x = max(group_data$year, na.rm = TRUE),
                    y = y_max - 0.12 * y_span,
                    label = post_label,
                    hjust = 1,
                    vjust = 1.2,
                    color = "#e31a1c",
                    size = 4
                )

            post_ctrl_data <- subset(
                post_data,
                !is.na(doctor_no) & !is.na(year) & !is.na(population) & population > 0
            )

            if (nrow(post_ctrl_data) >= 3 && length(unique(post_ctrl_data$year)) >= 2) {
                post_ctrl_data$log_population <- log(post_ctrl_data$population)
                post_fit_ctrl <- lm(doctor_no ~ year + log_population, data = post_ctrl_data)
                post_ctrl_label <- get_slope_label(post_fit_ctrl, "beta (log pop ctrl)")

                if (!is.null(post_ctrl_label)) {
                    p <- p + annotate(
                        "text",
                        x = max(group_data$year, na.rm = TRUE),
                        y = y_max - 0.24 * y_span,
                        label = post_ctrl_label,
                        hjust = 1,
                        vjust = 1.2,
                        color = "#33a02c",
                        size = 4
                    )
                }
            }
        }

        output_file <- file.path(
            OUTPUT,
            doctor_level,
            glue("처치_{region_sido}_{region_sigungu}.png")
        )
    } else {
        output_file <- file.path(
            OUTPUT,
            doctor_level,
            glue("대조군_{region_sido}_{region_sigungu}.png")
        )
    }

    dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
    ggsave(output_file, plot = p, width = 8, height = 6, dpi = 300)
}

doctor_group_keys <- unique(plot_doctor_data[c("region_sido", "region_sigungu", "doctor_level")])

for (i in seq_len(nrow(doctor_group_keys))) {
    key <- doctor_group_keys[i, ]
    message(glue("[doctor] {i}/{nrow(doctor_group_keys)}: {key$region_sido} {key$region_sigungu} - {key$doctor_level}"))
    group_data <- subset(
        plot_doctor_data,
        region_sido == key$region_sido &
            region_sigungu == key$region_sigungu &
            doctor_level == key$doctor_level
    )
    plot_doctor_group(group_data)
}

############################################################################################
############################################################################################
############################################################################################
############################################################################################
############################################################################################
############################################################################################
############################################################################################
############################################################################################
############################################################################################
############################################################################################
############################################################################################
############################################################################################

##################
#### Summary by AI
##################

summary_dir <- file.path(OUTPUT, "_summary")
dir.create(summary_dir, recursive = TRUE, showWarnings = FALSE)

fit_year_model <- function(data, outcome_var, with_population = FALSE) {
    rhs <- "year"
    required_vars <- c(outcome_var, "year")
    min_obs <- 2

    if (with_population) {
        rhs <- c(rhs, "log_population")
        required_vars <- c(required_vars, "population")
        min_obs <- 3
    }

    model_data <- data[complete.cases(data[required_vars]), required_vars]

    if (with_population) {
        model_data <- subset(model_data, population > 0)
        model_data$log_population <- log(model_data$population)
    }

    if (nrow(model_data) < min_obs || length(unique(model_data$year)) < 2) {
        return(NULL)
    }

    tryCatch(
        lm(reformulate(rhs, response = outcome_var), data = model_data),
        error = function(e) NULL
    )
}

extract_year_coef <- function(model) {
    if (is.null(model)) {
        return(NA_real_)
    }

    coef_value <- unname(coef(model)["year"])

    if (length(coef_value) == 0 || is.na(coef_value) || !is.finite(coef_value)) {
        return(NA_real_)
    }

    coef_value
}

summarize_group <- function(group_data, group_var, outcome_var) {
    group_value <- group_data[[group_var]][1]
    shock_year_values <- unique(na.omit(group_data$shock_year))
    shock_year <- if (length(shock_year_values) == 0) NA_real_ else shock_year_values[1]
    treated <- !is.na(shock_year)

    row <- data.frame(
        region_sido = group_data$region_sido[1],
        region_sigungu = group_data$region_sigungu[1],
        group_value = group_value,
        treated = treated,
        shock_year = shock_year,
        n_obs = nrow(group_data),
        population_median = median(group_data$population, na.rm = TRUE),
        outcome_mean = mean(group_data[[outcome_var]], na.rm = TRUE),
        pre_mean = NA_real_,
        post_mean = NA_real_,
        pre_beta = NA_real_,
        post_beta = NA_real_,
        delta_beta = NA_real_,
        pre_beta_pop_ctrl = NA_real_,
        post_beta_pop_ctrl = NA_real_,
        delta_beta_pop_ctrl = NA_real_,
        control_beta = NA_real_,
        control_beta_pop_ctrl = NA_real_,
        stringsAsFactors = FALSE
    )

    if (treated) {
        pre_data <- subset(group_data, year < shock_year)
        post_data <- subset(group_data, year >= shock_year)

        pre_fit <- fit_year_model(pre_data, outcome_var, with_population = FALSE)
        post_fit <- fit_year_model(post_data, outcome_var, with_population = FALSE)
        pre_fit_ctrl <- fit_year_model(pre_data, outcome_var, with_population = TRUE)
        post_fit_ctrl <- fit_year_model(post_data, outcome_var, with_population = TRUE)

        row$pre_mean <- mean(pre_data[[outcome_var]], na.rm = TRUE)
        row$post_mean <- mean(post_data[[outcome_var]], na.rm = TRUE)
        row$pre_beta <- extract_year_coef(pre_fit)
        row$post_beta <- extract_year_coef(post_fit)
        row$delta_beta <- row$post_beta - row$pre_beta
        row$pre_beta_pop_ctrl <- extract_year_coef(pre_fit_ctrl)
        row$post_beta_pop_ctrl <- extract_year_coef(post_fit_ctrl)
        row$delta_beta_pop_ctrl <- row$post_beta_pop_ctrl - row$pre_beta_pop_ctrl
    } else {
        control_fit <- fit_year_model(group_data, outcome_var, with_population = FALSE)
        control_fit_ctrl <- fit_year_model(group_data, outcome_var, with_population = TRUE)

        row$control_beta <- extract_year_coef(control_fit)
        row$control_beta_pop_ctrl <- extract_year_coef(control_fit_ctrl)
    }

    row
}

build_region_summary <- function(data, group_var, outcome_var, output_name) {
    group_keys <- unique(data[c("region_sido", "region_sigungu", group_var)])
    rows <- vector("list", nrow(group_keys))

    for (i in seq_len(nrow(group_keys))) {
        key <- group_keys[i, ]
        group_data <- subset(
            data,
            region_sido == key$region_sido &
                region_sigungu == key$region_sigungu &
                data[[group_var]] == key[[group_var]]
        )
        rows[[i]] <- summarize_group(group_data, group_var, outcome_var)
    }

    summary_data <- do.call(rbind, rows)
    names(summary_data)[names(summary_data) == "group_value"] <- group_var

    write.csv(summary_data, file.path(summary_dir, output_name), row.names = FALSE, fileEncoding = "UTF-8")
    summary_data
}

build_type_summary <- function(region_summary, group_var, output_name) {
    split_data <- split(region_summary, region_summary[[group_var]])

    summary_rows <- lapply(split_data, function(df) {
        treated_df <- subset(df, treated)
        control_df <- subset(df, !treated)

        data.frame(
            group_value = df[[group_var]][1],
            treated_regions = nrow(treated_df),
            control_regions = nrow(control_df),
            mean_shock_year = mean(treated_df$shock_year, na.rm = TRUE),
            mean_pre_beta = mean(treated_df$pre_beta, na.rm = TRUE),
            mean_post_beta = mean(treated_df$post_beta, na.rm = TRUE),
            mean_delta_beta = mean(treated_df$delta_beta, na.rm = TRUE),
            median_delta_beta = median(treated_df$delta_beta, na.rm = TRUE),
            mean_pre_beta_pop_ctrl = mean(treated_df$pre_beta_pop_ctrl, na.rm = TRUE),
            mean_post_beta_pop_ctrl = mean(treated_df$post_beta_pop_ctrl, na.rm = TRUE),
            mean_delta_beta_pop_ctrl = mean(treated_df$delta_beta_pop_ctrl, na.rm = TRUE),
            median_delta_beta_pop_ctrl = median(treated_df$delta_beta_pop_ctrl, na.rm = TRUE),
            share_delta_beta_positive = mean(treated_df$delta_beta > 0, na.rm = TRUE),
            share_delta_beta_pop_ctrl_positive = mean(treated_df$delta_beta_pop_ctrl > 0, na.rm = TRUE),
            mean_control_beta = mean(control_df$control_beta, na.rm = TRUE),
            mean_control_beta_pop_ctrl = mean(control_df$control_beta_pop_ctrl, na.rm = TRUE),
            stringsAsFactors = FALSE
        )
    })

    summary_data <- do.call(rbind, summary_rows)
    names(summary_data)[names(summary_data) == "group_value"] <- group_var

    write.csv(summary_data, file.path(summary_dir, output_name), row.names = FALSE, fileEncoding = "UTF-8")
    summary_data
}

hospital_region_summary <- build_region_summary(
    plot_data,
    "hospital_type",
    "hospital_no",
    "hospital_region_summary.csv"
)

hospital_type_summary <- build_type_summary(
    hospital_region_summary,
    "hospital_type",
    "hospital_type_summary.csv"
)

doctor_region_summary <- build_region_summary(
    plot_doctor_data,
    "doctor_level",
    "doctor_no",
    "doctor_region_summary.csv"
)

doctor_level_summary <- build_type_summary(
    doctor_region_summary,
    "doctor_level",
    "doctor_level_summary.csv"
)

message(glue("Summary tables written to {summary_dir}"))


############################################################
#### only big city #########################################
############################################################
hospital_path <- file.path(CLEAN, "clean_hospital_by_type.parquet")
doctor_path <- file.path(CLEAN, "clean_doctor_by_level.parquet")
shock_30_path <- file.path(CLEAN, "clean_shock_30.parquet")
population_path <- file.path(CLEAN, "clean_population.parquet")

dbExecute(con, glue("
    CREATE OR REPLACE TEMP TABLE panel_big_city_hospital AS
    WITH shock_2007 AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{shock_30_path}')
        WHERE shock_year <= 2007
    ),
    base AS (
        SELECT
            h.*,
            s.shock_station,
            s.line,
            s.distance_to_station,
            s.ktx_date,
            s.shock_year,
            s.ktx_shock_did,
            p.population
        FROM read_parquet('{hospital_path}') AS h
        LEFT JOIN read_parquet('{shock_30_path}') AS s
            USING (region_sido, region_sigungu, year)
        LEFT JOIN shock_2007 AS x
            USING (region_sido, region_sigungu)
        LEFT JOIN read_parquet('{population_path}') AS p
            USING (region_sido, region_sigungu, year)
        WHERE
            h.region_sido NOT IN ('서울', '경기', '인천', '제주') AND
            x.region_sido IS NULL AND
            h.year >= 2008
    ),
    eligible_groups AS (
        SELECT
            region_sido,
            region_sigungu,
            hospital_type
        FROM base
        GROUP BY region_sido, region_sigungu, hospital_type
        HAVING
            MEDIAN(population) >= 100000 AND
            MIN(COALESCE(hospital_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base AS b
    INNER JOIN eligible_groups AS e
        USING (region_sido, region_sigungu, hospital_type)
"))

dbExecute(con, glue("
    CREATE OR REPLACE TEMP TABLE panel_big_city_doctor AS
    WITH shock_2007 AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{shock_30_path}')
        WHERE shock_year <= 2007
    ),
    base AS (
        SELECT
            d.*,
            s.shock_station,
            s.line,
            s.distance_to_station,
            s.ktx_date,
            s.shock_year,
            s.ktx_shock_did,
            p.population
        FROM read_parquet('{doctor_path}') AS d
        LEFT JOIN read_parquet('{shock_30_path}') AS s
            USING (region_sido, region_sigungu, year)
        LEFT JOIN shock_2007 AS x
            USING (region_sido, region_sigungu)
        LEFT JOIN read_parquet('{population_path}') AS p
            USING (region_sido, region_sigungu, year)
        WHERE
            d.region_sido NOT IN ('서울', '경기', '인천', '제주') AND
            x.region_sido IS NULL AND
            d.year >= 2008
    ),
    eligible_groups AS (
        SELECT
            region_sido,
            region_sigungu,
            doctor_level
        FROM base
        GROUP BY region_sido, region_sigungu, doctor_level
        HAVING
            MEDIAN(population) >= 100000 AND
            MAX(COALESCE(doctor_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base AS b
    INNER JOIN eligible_groups AS e
        USING (region_sido, region_sigungu, doctor_level)
"))

print_shock_year_region_counts <- function(panel_name, group_var = NULL, label = panel_name) {
    if (is.null(group_var)) {
        count_query <- glue("
            WITH region_base AS (
                SELECT DISTINCT
                    region_sido,
                    region_sigungu,
                    shock_year
                FROM {panel_name}
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
        ")
    } else {
        count_query <- glue("
            WITH region_base AS (
                SELECT DISTINCT
                    {group_var},
                    region_sido,
                    region_sigungu,
                    shock_year
                FROM {panel_name}
            )
            SELECT
                {group_var},
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
            GROUP BY {group_var}, shock_year
            ORDER BY
                {group_var},
                CASE WHEN shock_year IS NULL THEN 1 ELSE 0 END,
                shock_year
        ")
    }

    message(glue("\n[{label}] shock year별 region count"))
    print(dbGetQuery(con, count_query), row.names = FALSE)
}

print_shock_year_region_counts(
    "panel_big_city_hospital",
    "hospital_type",
    "big city hospital_type panel"
)
print_shock_year_region_counts(
    "panel_big_city_doctor",
    "doctor_level",
    "big city doctor_level panel"
)

# ktx_shock_did \times year term 대신에 post_ktx_years로 (ktx_shock 이후에 몇년 지났냐)
get_regression_data <- function(panel_name, group_var, group_value, outcome_var) {
    model_data <- dbGetQuery(con, glue("
        SELECT
            *,
            region_sido || ' ' || region_sigungu AS region_id,
            year - 2006 AS year_2007,
            COALESCE(ktx_shock_did, 0) AS ktx_shock_did_for_reg,
            CASE
                WHEN shock_year IS NOT NULL AND year >= shock_year THEN year - shock_year + 1
                ELSE 0
            END AS post_ktx_years
        FROM {panel_name}
        WHERE population > 0
    "))

    model_data <- model_data[model_data[[group_var]] == group_value, ]
    model_data[complete.cases(model_data[c(outcome_var, "year_2007", "population", "region_id")]), ]
}

run_trend_model_no_year_fe <- function(panel_name, group_var, group_value, outcome_var, label = group_value) {
    model_data <- get_regression_data(panel_name, group_var, group_value, outcome_var)

    message(glue("\n[{label}] FE trend regression: no year FE, ktx_shock_did x year"))

    if (nrow(model_data) == 0) {
        message("No observations available.")
        return(NULL)
    }

    model_formula <- as.formula(glue(
        "{outcome_var} ~ year_2007 + ktx_shock_did_for_reg:year_2007 + log(population) | region_id"
    ))

    model <- feols(
        model_formula,
        data = model_data,
        cluster = ~region_id
    )

    print(etable(
        model,
        dict = c(
            year_2007 = "year (2007 = 1)",
            "ktx_shock_did_for_reg:year_2007" = "ktx_shock_did x year (2007 = 1)",
            "year_2007:ktx_shock_did_for_reg" = "ktx_shock_did x year (2007 = 1)",
            "log(population)" = "log(population)"
        ),
        fitstat = ~n + r2 + wr2
    ))

    invisible(model)
}

run_post_ktx_years_model <- function(panel_name, group_var, group_value, outcome_var, label = group_value) {
    model_data <- get_regression_data(panel_name, group_var, group_value, outcome_var)

    message(glue("\n[{label}] FE trend regression: post_ktx_years"))

    if (nrow(model_data) == 0) {
        message("No observations available.")
        return(NULL)
    }

    model_formula <- as.formula(glue(
        "{outcome_var} ~ year_2007 + post_ktx_years + log(population) | region_id"
    ))

    model <- feols(
        model_formula,
        data = model_data,
        cluster = ~region_id
    )

    print(etable(
        model,
        dict = c(
            year_2007 = "year (2007 = 1)",
            post_ktx_years = "post KTX years",
            "log(population)" = "log(population)"
        ),
        fitstat = ~n + r2 + wr2
    ))

    invisible(model)
}

#### 의원
model_big_city_clinic_no_year_fe <- run_trend_model_no_year_fe(
    "panel_big_city_hospital",
    "hospital_type",
    "의원",
    "hospital_no",
    "의원"
)
model_big_city_clinic_post_years <- run_post_ktx_years_model(
    "panel_big_city_hospital",
    "hospital_type",
    "의원",
    "hospital_no",
    "의원"
)

#### 병원
model_big_city_secondary_no_year_fe <- run_trend_model_no_year_fe(
    "panel_big_city_hospital",
    "hospital_type",
    "병원",
    "hospital_no",
    "병원"
)
model_big_city_secondary_post_years <- run_post_ktx_years_model(
    "panel_big_city_hospital",
    "hospital_type",
    "병원",
    "hospital_no",
    "병원"
)

#### 종합병원
model_big_city_general_no_year_fe <- run_trend_model_no_year_fe(
    "panel_big_city_hospital",
    "hospital_type",
    "종합병원",
    "hospital_no",
    "종합병원"
)
model_big_city_general_post_years <- run_post_ktx_years_model(
    "panel_big_city_hospital",
    "hospital_type",
    "종합병원",
    "hospital_no",
    "종합병원"
)

#### 상급종합병원
model_big_city_tertiary_no_year_fe <- run_trend_model_no_year_fe(
    "panel_big_city_hospital",
    "hospital_type",
    "상급종합병원",
    "hospital_no",
    "상급종합병원"
)
model_big_city_tertiary_post_years <- run_post_ktx_years_model(
    "panel_big_city_hospital",
    "hospital_type",
    "상급종합병원",
    "hospital_no",
    "상급종합병원"
)

#### 인턴
model_big_city_intern_no_year_fe <- run_trend_model_no_year_fe(
    "panel_big_city_doctor",
    "doctor_level",
    "인턴",
    "doctor_no",
    "인턴"
)
model_big_city_intern_post_years <- run_post_ktx_years_model(
    "panel_big_city_doctor",
    "doctor_level",
    "인턴",
    "doctor_no",
    "인턴"
)

#### 레지던트
model_big_city_resident_no_year_fe <- run_trend_model_no_year_fe(
    "panel_big_city_doctor",
    "doctor_level",
    "레지던트",
    "doctor_no",
    "레지던트"
)
model_big_city_resident_post_years <- run_post_ktx_years_model(
    "panel_big_city_doctor",
    "doctor_level",
    "레지던트",
    "doctor_no",
    "레지던트"
)

#### 전문의
model_big_city_specialist_no_year_fe <- run_trend_model_no_year_fe(
    "panel_big_city_doctor",
    "doctor_level",
    "전문의",
    "doctor_no",
    "전문의"
)
model_big_city_specialist_post_years <- run_post_ktx_years_model(
    "panel_big_city_doctor",
    "doctor_level",
    "전문의",
    "doctor_no",
    "전문의"
)

#### 일반의
model_big_city_general_doctor_no_year_fe <- run_trend_model_no_year_fe(
    "panel_big_city_doctor",
    "doctor_level",
    "일반의",
    "doctor_no",
    "일반의"
)
model_big_city_general_doctor_post_years <- run_post_ktx_years_model(
    "panel_big_city_doctor",
    "doctor_level",
    "일반의",
    "doctor_no",
    "일반의"
)

############################################################
#### all city #########################################
############################################################

dbExecute(con, glue("
    CREATE OR REPLACE TEMP TABLE panel_all_city_hospital AS
    WITH shock_2007 AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{shock_30_path}')
        WHERE shock_year <= 2007
    ),
    base AS (
        SELECT
            h.*,
            s.shock_station,
            s.line,
            s.distance_to_station,
            s.ktx_date,
            s.shock_year,
            s.ktx_shock_did,
            p.population
        FROM read_parquet('{hospital_path}') AS h
        LEFT JOIN read_parquet('{shock_30_path}') AS s
            USING (region_sido, region_sigungu, year)
        LEFT JOIN shock_2007 AS x
            USING (region_sido, region_sigungu)
        LEFT JOIN read_parquet('{population_path}') AS p
            USING (region_sido, region_sigungu, year)
        WHERE
            h.region_sido NOT IN ('서울', '경기', '인천', '제주') AND
            x.region_sido IS NULL AND
            h.year >= 2008
    ),
    eligible_groups AS (
        SELECT
            region_sido,
            region_sigungu,
            hospital_type
        FROM base
        GROUP BY region_sido, region_sigungu, hospital_type
        HAVING MIN(COALESCE(hospital_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base AS b
    INNER JOIN eligible_groups AS e
        USING (region_sido, region_sigungu, hospital_type)
"))

dbExecute(con, glue("
    CREATE OR REPLACE TEMP TABLE panel_all_city_doctor AS
    WITH shock_2007 AS (
        SELECT DISTINCT
            region_sido,
            region_sigungu
        FROM read_parquet('{shock_30_path}')
        WHERE shock_year <= 2007
    ),
    base AS (
        SELECT
            d.*,
            s.shock_station,
            s.line,
            s.distance_to_station,
            s.ktx_date,
            s.shock_year,
            s.ktx_shock_did,
            p.population
        FROM read_parquet('{doctor_path}') AS d
        LEFT JOIN read_parquet('{shock_30_path}') AS s
            USING (region_sido, region_sigungu, year)
        LEFT JOIN shock_2007 AS x
            USING (region_sido, region_sigungu)
        LEFT JOIN read_parquet('{population_path}') AS p
            USING (region_sido, region_sigungu, year)
        WHERE
            d.region_sido NOT IN ('서울', '경기', '인천', '제주') AND
            x.region_sido IS NULL AND
            d.year >= 2008
    ),
    eligible_groups AS (
        SELECT
            region_sido,
            region_sigungu,
            doctor_level
        FROM base
        GROUP BY region_sido, region_sigungu, doctor_level
        HAVING MAX(COALESCE(doctor_no, 0)) > 0
    )
    SELECT
        b.*
    FROM base AS b
    INNER JOIN eligible_groups AS e
        USING (region_sido, region_sigungu, doctor_level)
"))

print_shock_year_region_counts(
    "panel_all_city_hospital",
    "hospital_type",
    "all city hospital_type panel"
)
print_shock_year_region_counts(
    "panel_all_city_doctor",
    "doctor_level",
    "all city doctor_level panel"
)

#### 의원
model_all_city_clinic_no_year_fe <- run_trend_model_no_year_fe(
    "panel_all_city_hospital",
    "hospital_type",
    "의원",
    "hospital_no",
    "all city - 의원"
)
model_all_city_clinic_post_years <- run_post_ktx_years_model(
    "panel_all_city_hospital",
    "hospital_type",
    "의원",
    "hospital_no",
    "all city - 의원"
)

#### 병원
model_all_city_secondary_no_year_fe <- run_trend_model_no_year_fe(
    "panel_all_city_hospital",
    "hospital_type",
    "병원",
    "hospital_no",
    "all city - 병원"
)
model_all_city_secondary_post_years <- run_post_ktx_years_model(
    "panel_all_city_hospital",
    "hospital_type",
    "병원",
    "hospital_no",
    "all city - 병원"
)

#### 종합병원
model_all_city_general_no_year_fe <- run_trend_model_no_year_fe(
    "panel_all_city_hospital",
    "hospital_type",
    "종합병원",
    "hospital_no",
    "all city - 종합병원"
)
model_all_city_general_post_years <- run_post_ktx_years_model(
    "panel_all_city_hospital",
    "hospital_type",
    "종합병원",
    "hospital_no",
    "all city - 종합병원"
)

#### 상급종합병원
model_all_city_tertiary_no_year_fe <- run_trend_model_no_year_fe(
    "panel_all_city_hospital",
    "hospital_type",
    "상급종합병원",
    "hospital_no",
    "all city - 상급종합병원"
)
model_all_city_tertiary_post_years <- run_post_ktx_years_model(
    "panel_all_city_hospital",
    "hospital_type",
    "상급종합병원",
    "hospital_no",
    "all city - 상급종합병원"
)

#### 인턴
model_all_city_intern_no_year_fe <- run_trend_model_no_year_fe(
    "panel_all_city_doctor",
    "doctor_level",
    "인턴",
    "doctor_no",
    "all city - 인턴"
)
model_all_city_intern_post_years <- run_post_ktx_years_model(
    "panel_all_city_doctor",
    "doctor_level",
    "인턴",
    "doctor_no",
    "all city - 인턴"
)

#### 레지던트
model_all_city_resident_no_year_fe <- run_trend_model_no_year_fe(
    "panel_all_city_doctor",
    "doctor_level",
    "레지던트",
    "doctor_no",
    "all city - 레지던트"
)
model_all_city_resident_post_years <- run_post_ktx_years_model(
    "panel_all_city_doctor",
    "doctor_level",
    "레지던트",
    "doctor_no",
    "all city - 레지던트"
)

#### 전문의
model_all_city_specialist_no_year_fe <- run_trend_model_no_year_fe(
    "panel_all_city_doctor",
    "doctor_level",
    "전문의",
    "doctor_no",
    "all city - 전문의"
)
model_all_city_specialist_post_years <- run_post_ktx_years_model(
    "panel_all_city_doctor",
    "doctor_level",
    "전문의",
    "doctor_no",
    "all city - 전문의"
)

#### 일반의
model_all_city_general_doctor_no_year_fe <- run_trend_model_no_year_fe(
    "panel_all_city_doctor",
    "doctor_level",
    "일반의",
    "doctor_no",
    "all city - 일반의"
)
model_all_city_general_doctor_post_years <- run_post_ktx_years_model(
    "panel_all_city_doctor",
    "doctor_level",
    "일반의",
    "doctor_no",
    "all city - 일반의"
)

############################################################
#### event study ###########################################
############################################################

get_event_study_data <- function(panel_name, group_var, group_value, outcome_var) {
    model_data <- dbGetQuery(con, glue("
        SELECT
            *,
            region_sido || ' ' || region_sigungu AS region_id,
            year - 2006 AS year_2007,
            log(population) AS log_population
        FROM {panel_name}
        WHERE population > 0
    "))

    model_data <- model_data[model_data[[group_var]] == group_value, ]
    model_data <- model_data[complete.cases(
        model_data[c(outcome_var, "year", "population", "log_population", "region_id")]
    ), ]

    first_treat <- ave(
        model_data$shock_year,
        model_data$region_id,
        FUN = function(x) {
            x <- x[!is.na(x)]
            if (length(x) == 0) {
                return(NA_real_)
            }
            min(x)
        }
    )

    model_data$first_treat_year <- as.integer(first_treat)
    model_data$first_treat_year_did <- ifelse(
        is.na(model_data$first_treat_year),
        0L,
        model_data$first_treat_year
    )
    model_data$region_num <- as.integer(factor(model_data$region_id))

    model_data
}

run_sunab_event_study <- function(panel_name, group_var, group_value, outcome_var, label = group_value) {
    model_data <- get_event_study_data(panel_name, group_var, group_value, outcome_var)

    message(glue("\n[{label}] Sun-Abraham event study"))

    if (nrow(model_data) == 0) {
        message("No observations available.")
        return(NULL)
    }

    never_treated_cohort <- max(model_data$year, na.rm = TRUE) + 1000L
    model_data$first_treat_year_sunab <- ifelse(
        is.na(model_data$first_treat_year),
        never_treated_cohort,
        model_data$first_treat_year
    )

    model_formula <- as.formula(glue(
        "{outcome_var} ~ sunab(first_treat_year_sunab, year) + log_population | region_id + year"
    ))

    model <- feols(
        model_formula,
        data = model_data,
        cluster = ~region_id
    )

    print(etable(
        model,
        dict = c(log_population = "log(population)"),
        fitstat = ~n + r2 + wr2
    ))

    invisible(model)
}

run_cs_dynamic_simple <- function(
    panel_name,
    group_var,
    group_value,
    outcome_var,
    label = group_value,
    control_group = "notyettreated",
    base_period = "universal"
) {
    model_data <- get_event_study_data(panel_name, group_var, group_value, outcome_var)

    message(glue("\n[{label}] Callaway-Sant'Anna dynamic and simple ATT"))

    if (nrow(model_data) == 0) {
        message("No observations available.")
        return(NULL)
    }

    cs_att <- att_gt(
        yname = outcome_var,
        tname = "year",
        idname = "region_num",
        gname = "first_treat_year_did",
        xformla = ~log_population,
        data = model_data,
        panel = TRUE,
        control_group = control_group,
        base_period = base_period,
        clustervars = "region_num",
        allow_unbalanced_panel = TRUE
    )

    cs_dynamic <- aggte(cs_att, type = "dynamic")
    cs_simple <- aggte(cs_att, type = "simple")

    message(glue("\n[{label}] Callaway-Sant'Anna dynamic ATT"))
    print(summary(cs_dynamic))

    message(glue("\n[{label}] Callaway-Sant'Anna simple ATT"))
    print(summary(cs_simple))

    invisible(list(
        att_gt = cs_att,
        dynamic = cs_dynamic,
        simple = cs_simple
    ))
}

#### 의원
sunab_all_city_clinic <- run_sunab_event_study(
    "panel_all_city_hospital",
    "hospital_type",
    "의원",
    "hospital_no",
    "all city - 의원"
)
cs_all_city_clinic <- run_cs_dynamic_simple(
    "panel_all_city_hospital",
    "hospital_type",
    "의원",
    "hospital_no",
    "all city - 의원"
)

#### 병원
sunab_all_city_secondary <- run_sunab_event_study(
    "panel_all_city_hospital",
    "hospital_type",
    "병원",
    "hospital_no",
    "all city - 병원"
)
cs_all_city_secondary <- run_cs_dynamic_simple(
    "panel_all_city_hospital",
    "hospital_type",
    "병원",
    "hospital_no",
    "all city - 병원"
)

#### 종합병원
sunab_all_city_general <- run_sunab_event_study(
    "panel_all_city_hospital",
    "hospital_type",
    "종합병원",
    "hospital_no",
    "all city - 종합병원"
)
cs_all_city_general <- run_cs_dynamic_simple(
    "panel_all_city_hospital",
    "hospital_type",
    "종합병원",
    "hospital_no",
    "all city - 종합병원"
)

#### 상급종합병원
sunab_all_city_tertiary <- run_sunab_event_study(
    "panel_all_city_hospital",
    "hospital_type",
    "상급종합병원",
    "hospital_no",
    "all city - 상급종합병원"
)
cs_all_city_tertiary <- run_cs_dynamic_simple(
    "panel_all_city_hospital",
    "hospital_type",
    "상급종합병원",
    "hospital_no",
    "all city - 상급종합병원"
)

#### 인턴
sunab_all_city_intern <- run_sunab_event_study(
    "panel_all_city_doctor",
    "doctor_level",
    "인턴",
    "doctor_no",
    "all city - 인턴"
)
cs_all_city_intern <- run_cs_dynamic_simple(
    "panel_all_city_doctor",
    "doctor_level",
    "인턴",
    "doctor_no",
    "all city - 인턴"
)

#### 레지던트
sunab_all_city_resident <- run_sunab_event_study(
    "panel_all_city_doctor",
    "doctor_level",
    "레지던트",
    "doctor_no",
    "all city - 레지던트"
)
cs_all_city_resident <- run_cs_dynamic_simple(
    "panel_all_city_doctor",
    "doctor_level",
    "레지던트",
    "doctor_no",
    "all city - 레지던트"
)

#### 전문의
sunab_all_city_specialist <- run_sunab_event_study(
    "panel_all_city_doctor",
    "doctor_level",
    "전문의",
    "doctor_no",
    "all city - 전문의"
)
cs_all_city_specialist <- run_cs_dynamic_simple(
    "panel_all_city_doctor",
    "doctor_level",
    "전문의",
    "doctor_no",
    "all city - 전문의"
)

#### 일반의
sunab_all_city_general_doctor <- run_sunab_event_study(
    "panel_all_city_doctor",
    "doctor_level",
    "일반의",
    "doctor_no",
    "all city - 일반의"
)
cs_all_city_general_doctor <- run_cs_dynamic_simple(
    "panel_all_city_doctor",
    "doctor_level",
    "일반의",
    "doctor_no",
    "all city - 일반의"
)

############################################################
#### growth outcome TWFE DiD ###############################
############################################################

run_hospital_net_entry_twfe <- function(panel_name, hospital_type, label = hospital_type) {
    model_data <- dbGetQuery(con, glue("
        SELECT
            region_sido || ' ' || region_sigungu AS region_id,
            hospital_type,
            year,
            net_entry,
            COALESCE(ktx_shock_did, 0) AS ktx_shock_did_for_reg
        FROM {panel_name}
        WHERE hospital_type = '{hospital_type}'
    "))

    model_data <- model_data[complete.cases(
        model_data[c("net_entry", "year", "ktx_shock_did_for_reg", "region_id")]
    ), ]

    message(glue("\n[{label}] TWFE DiD: net_entry"))

    if (nrow(model_data) == 0) {
        message("No observations available.")
        return(NULL)
    }

    if (length(unique(model_data$net_entry)) < 2) {
        message("No outcome variation available.")
        return(NULL)
    }

    model <- tryCatch(
        feols(
            net_entry ~ ktx_shock_did_for_reg | region_id + year,
            data = model_data,
            cluster = ~region_id
        ),
        error = function(e) {
            message(e$message)
            NULL
        }
    )

    if (is.null(model)) {
        return(NULL)
    }

    print(etable(
        model,
        dict = c(ktx_shock_did_for_reg = "KTX shock"),
        fitstat = ~n + r2 + wr2
    ))

    invisible(model)
}

run_doctor_delta_twfe <- function(panel_name, doctor_level, label = doctor_level) {
    model_data <- dbGetQuery(con, glue("
        SELECT
            region_sido || ' ' || region_sigungu AS region_id,
            doctor_level,
            year,
            doctor_no,
            COALESCE(ktx_shock_did, 0) AS ktx_shock_did_for_reg
        FROM {panel_name}
        WHERE doctor_level = '{doctor_level}'
    "))

    model_data <- model_data[complete.cases(
        model_data[c("doctor_no", "year", "ktx_shock_did_for_reg", "region_id")]
    ), ]
    model_data <- model_data[order(model_data$region_id, model_data$year), ]
    model_data$delta_doctor_no <- ave(
        model_data$doctor_no,
        model_data$region_id,
        FUN = function(x) c(NA_real_, diff(x))
    )
    model_data <- model_data[complete.cases(model_data[c("delta_doctor_no")]), ]

    message(glue("\n[{label}] TWFE DiD: delta_doctor_no"))

    if (nrow(model_data) == 0) {
        message("No observations available.")
        return(NULL)
    }

    if (length(unique(model_data$delta_doctor_no)) < 2) {
        message("No outcome variation available.")
        return(NULL)
    }

    model <- tryCatch(
        feols(
            delta_doctor_no ~ ktx_shock_did_for_reg | region_id + year,
            data = model_data,
            cluster = ~region_id
        ),
        error = function(e) {
            message(e$message)
            NULL
        }
    )

    if (is.null(model)) {
        return(NULL)
    }

    print(etable(
        model,
        dict = c(ktx_shock_did_for_reg = "KTX shock"),
        fitstat = ~n + r2 + wr2
    ))

    invisible(model)
}

#### 의원
twfe_net_entry_all_city_clinic <- run_hospital_net_entry_twfe(
    "panel_all_city_hospital",
    "의원",
    "all city - 의원"
)

#### 병원
twfe_net_entry_all_city_secondary <- run_hospital_net_entry_twfe(
    "panel_all_city_hospital",
    "병원",
    "all city - 병원"
)

#### 종합병원
twfe_net_entry_all_city_general <- run_hospital_net_entry_twfe(
    "panel_all_city_hospital",
    "종합병원",
    "all city - 종합병원"
)

#### 상급종합병원
twfe_net_entry_all_city_tertiary <- run_hospital_net_entry_twfe(
    "panel_all_city_hospital",
    "상급종합병원",
    "all city - 상급종합병원"
)

#### total
twfe_delta_doctor_all_city_total <- run_doctor_delta_twfe(
    "panel_all_city_doctor",
    "total",
    "all city - total"
)

#### 인턴
twfe_delta_doctor_all_city_intern <- run_doctor_delta_twfe(
    "panel_all_city_doctor",
    "인턴",
    "all city - 인턴"
)

#### 레지던트
twfe_delta_doctor_all_city_resident <- run_doctor_delta_twfe(
    "panel_all_city_doctor",
    "레지던트",
    "all city - 레지던트"
)

#### 전문의
twfe_delta_doctor_all_city_specialist <- run_doctor_delta_twfe(
    "panel_all_city_doctor",
    "전문의",
    "all city - 전문의"
)

#### 일반의
twfe_delta_doctor_all_city_general_doctor <- run_doctor_delta_twfe(
    "panel_all_city_doctor",
    "일반의",
    "all city - 일반의"
)

############################################################
#### delta doctor event study ##############################
############################################################

get_delta_doctor_event_study_data <- function(panel_name, doctor_level) {
    model_data <- dbGetQuery(con, glue("
        SELECT
            *,
            region_sido || ' ' || region_sigungu AS region_id,
            log(population) AS log_population
        FROM {panel_name}
        WHERE
            doctor_level = '{doctor_level}' AND
            population > 0
    "))

    model_data <- model_data[complete.cases(
        model_data[c("doctor_no", "year", "population", "log_population", "region_id")]
    ), ]
    model_data <- model_data[order(model_data$region_id, model_data$year), ]
    model_data$delta_doctor_no <- ave(
        model_data$doctor_no,
        model_data$region_id,
        FUN = function(x) c(NA_real_, diff(x))
    )
    model_data <- model_data[complete.cases(model_data[c("delta_doctor_no")]), ]

    first_treat <- ave(
        model_data$shock_year,
        model_data$region_id,
        FUN = function(x) {
            x <- x[!is.na(x)]
            if (length(x) == 0) {
                return(NA_real_)
            }
            min(x)
        }
    )

    model_data$first_treat_year <- as.integer(first_treat)
    model_data$first_treat_year_did <- ifelse(
        is.na(model_data$first_treat_year),
        0L,
        model_data$first_treat_year
    )
    model_data$region_num <- as.integer(factor(model_data$region_id))

    model_data
}

run_delta_doctor_sunab_event_study <- function(panel_name, doctor_level, label = doctor_level) {
    model_data <- get_delta_doctor_event_study_data(panel_name, doctor_level)

    message(glue("\n[{label}] Sun-Abraham event study: delta_doctor_no"))

    if (nrow(model_data) == 0) {
        message("No observations available.")
        return(NULL)
    }

    if (length(unique(model_data$delta_doctor_no)) < 2) {
        message("No outcome variation available.")
        return(NULL)
    }

    never_treated_cohort <- max(model_data$year, na.rm = TRUE) + 1000L
    model_data$first_treat_year_sunab <- ifelse(
        is.na(model_data$first_treat_year),
        never_treated_cohort,
        model_data$first_treat_year
    )

    model <- feols(
        delta_doctor_no ~ sunab(first_treat_year_sunab, year) + log_population | region_id + year,
        data = model_data,
        cluster = ~region_id
    )

    print(etable(
        model,
        dict = c(log_population = "log(population)"),
        fitstat = ~n + r2 + wr2
    ))

    invisible(model)
}

run_delta_doctor_cs_dynamic_simple <- function(
    panel_name,
    doctor_level,
    label = doctor_level,
    control_group = "notyettreated",
    base_period = "universal"
) {
    model_data <- get_delta_doctor_event_study_data(panel_name, doctor_level)

    message(glue("\n[{label}] Callaway-Sant'Anna dynamic and simple ATT: delta_doctor_no"))

    if (nrow(model_data) == 0) {
        message("No observations available.")
        return(NULL)
    }

    if (length(unique(model_data$delta_doctor_no)) < 2) {
        message("No outcome variation available.")
        return(NULL)
    }

    cs_att <- att_gt(
        yname = "delta_doctor_no",
        tname = "year",
        idname = "region_num",
        gname = "first_treat_year_did",
        xformla = ~log_population,
        data = model_data,
        panel = TRUE,
        control_group = control_group,
        base_period = base_period,
        clustervars = "region_num",
        allow_unbalanced_panel = TRUE
    )

    cs_dynamic <- aggte(cs_att, type = "dynamic")
    cs_simple <- aggte(cs_att, type = "simple")

    message(glue("\n[{label}] Callaway-Sant'Anna dynamic ATT: delta_doctor_no"))
    print(summary(cs_dynamic))

    message(glue("\n[{label}] Callaway-Sant'Anna simple ATT: delta_doctor_no"))
    print(summary(cs_simple))

    invisible(list(
        att_gt = cs_att,
        dynamic = cs_dynamic,
        simple = cs_simple
    ))
}

#### total
sunab_delta_doctor_all_city_total <- run_delta_doctor_sunab_event_study(
    "panel_all_city_doctor",
    "total",
    "all city - total"
)
cs_delta_doctor_all_city_total <- run_delta_doctor_cs_dynamic_simple(
    "panel_all_city_doctor",
    "total",
    "all city - total"
)

#### 인턴
sunab_delta_doctor_all_city_intern <- run_delta_doctor_sunab_event_study(
    "panel_all_city_doctor",
    "인턴",
    "all city - 인턴"
)
cs_delta_doctor_all_city_intern <- run_delta_doctor_cs_dynamic_simple(
    "panel_all_city_doctor",
    "인턴",
    "all city - 인턴"
)

#### 레지던트
sunab_delta_doctor_all_city_resident <- run_delta_doctor_sunab_event_study(
    "panel_all_city_doctor",
    "레지던트",
    "all city - 레지던트"
)
cs_delta_doctor_all_city_resident <- run_delta_doctor_cs_dynamic_simple(
    "panel_all_city_doctor",
    "레지던트",
    "all city - 레지던트"
)

#### 전문의
sunab_delta_doctor_all_city_specialist <- run_delta_doctor_sunab_event_study(
    "panel_all_city_doctor",
    "전문의",
    "all city - 전문의"
)
cs_delta_doctor_all_city_specialist <- run_delta_doctor_cs_dynamic_simple(
    "panel_all_city_doctor",
    "전문의",
    "all city - 전문의"
)

#### 일반의
sunab_delta_doctor_all_city_general_doctor <- run_delta_doctor_sunab_event_study(
    "panel_all_city_doctor",
    "일반의",
    "all city - 일반의"
)
cs_delta_doctor_all_city_general_doctor <- run_delta_doctor_cs_dynamic_simple(
    "panel_all_city_doctor",
    "일반의",
    "all city - 일반의"
)

############################################################
#### drawing pictures again ################################
############################################################

dbDisconnect(con, shutdown = TRUE)
