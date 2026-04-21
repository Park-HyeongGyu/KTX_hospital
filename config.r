ROOT <- "/home/yum_ki/Research/KTXHospital"

RAW <- file.path(ROOT, "raw_data")
SRC <- file.path(ROOT, "src")
CSV <- file.path(ROOT, "clean_csv")
CLEAN <- file.path(ROOT, "clean_parquet")

DB_CLEAN <- file.path(ROOT, "clean_db.duckdb")

setwd(ROOT)
