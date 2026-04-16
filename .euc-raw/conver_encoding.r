ROOT <- "/home/yum_ki/Research/KTXHospital"
EUC <- file.path(ROOT, ".euc-raw")
CONVERTED <- file.path(ROOT, "raw_data")

euckr_to_utf8_lf <- function(input_file, output_file) {
  tryCatch({
    # 1. Read as euc-kr
    lines <- readLines(input_file, encoding = "EUC-KR", warn = FALSE)

    # 2. conver to UTF-8
    lines_utf8 <- iconv(lines, from = "EUC-KR", to = "UTF-8")

    # 3. Check NA  (conversion failure)
    if (any(is.na(lines_utf8))) {
      warning("⚠️ Encoding converting failures (NA found)")
    }

    # 4. Save as UTF-8 + LF
    con <- file(output_file, open = "w", encoding = "UTF-8")
    writeLines(lines_utf8, con = con, sep = "\n", useBytes = TRUE)
    close(con)

    message(sprintf("✅ converting complete: %s → %s", input_file, output_file))

  }, error = function(e) {
    stop(sprintf("❌ converting failed: %s", e$message))
  })
}


files <- c("HIRA_요양기관폐업현황.csv",
           "KOSIS_시군구별_전문과목별_전문의현황.csv",
           "KOSIS_시군구별_종별_요양기관.csv",
           "KOSIS_시군구별_표시과목별_의원.csv",
           "KOSIS_시군구별의료인력현황_의사.csv",
           "국가철도공단_철도역 정보_20250711.csv",
           "한국철도공사_KTX 정차역 최초 개통일_20240201.CSV"
           )

for (file_name in files) {
  input_path <- file.path(EUC, file_name)
  output_path <- file.path(CONVERTED, file_name)
  euckr_to_utf8_lf(input_path, output_path)
}

