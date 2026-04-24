#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

clean_dir() {
    local target_dir="$1"

    find "$target_dir" -mindepth 1 ! -name '.gitkeep' -delete
}

clean_dir "$ROOT/output"
clean_dir "$ROOT/clean_csv"
clean_dir "$ROOT/clean_parquet"
