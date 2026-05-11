"""
Parse raw KTX timetable Excel files into train-stop level data.

The KTX timetable files are presentation-oriented Excel workbooks, not
machine-oriented tables.  The parsing below intentionally keeps the
year-specific work explicit: each parse_ktx_YYYY() function lists the sheets
and block starting positions for that year, while shared helpers only convert
those fixed blocks into a common long format.

By default this script writes parsed CSV and Parquet outputs.  Use --dry-run
when the parser should only report results without writing files.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, time
from pathlib import Path
from time import perf_counter
from typing import Iterable

import pandas as pd


ROOT = Path("/home/yum_ki/Research/KTXHospital")
RAW_KTX = ROOT / "raw_data" / "KTX시간표"
CLEAN_CSV = ROOT / "clean_csv"
CLEAN_PARQUET = ROOT / "clean_parquet"

TERMINAL_STATIONS = ("서울역", "용산역")


@dataclass(frozen=True)
class BlockSpec:
    sheet: str
    line: str
    direction: str
    title_row: int
    title_col: int


def normalize_station_name(value: object) -> str | None:
    if pd.isna(value):
        return None

    station = str(value).strip()
    station = re.sub(r"\s+", "", station)
    station = station.replace("·", "")

    if not station or station in {"nan", "NaT"}:
        return None
    if station in {"비고", "비고(정차역)", "Remark", "備考", "備考(停車駅)"}:
        return None
    if station in {"열차번호", "열번", "편성", "TrainNO.", "Trainname"}:
        return None

    station_map = {
        "김천구미": "김천(구미)",
        "김천(구미)": "김천(구미)",
        "인천공항": "인천공항",
        "인천국제공항": "인천국제공항",
        "광주송정": "광주송정",
        "여수EXPO": "여수엑스포",
        "여수-Expo": "여수엑스포",
        "여수-EXPO": "여수엑스포",
        "Yeosu-Expo": "여수엑스포",
    }
    station = station_map.get(station, station)

    if station.endswith("역"):
        return station
    return f"{station}역"


def parse_train_no(value: object) -> str | None:
    if pd.isna(value):
        return None
    if isinstance(value, (int, float)) and not pd.isna(value):
        if float(value).is_integer():
            return str(int(value))
        return str(value)

    text = str(value).strip()
    if not text:
        return None
    if not re.fullmatch(r"\d+(\.0)?", text):
        return None
    return str(int(float(text)))


def parse_time_cell(value: object) -> int | None:
    if pd.isna(value):
        return None

    if isinstance(value, pd.Timestamp):
        if value.hour == 0 and value.minute == 0 and value.second == 0:
            return None
        day_offset = 1440 if value.date() > datetime(1900, 1, 1).date() else 0
        return day_offset + value.hour * 60 + value.minute + round(value.second / 60)

    if isinstance(value, datetime):
        if value.hour == 0 and value.minute == 0 and value.second == 0:
            return None
        day_offset = 1440 if value.date() > datetime(1900, 1, 1).date() else 0
        return day_offset + value.hour * 60 + value.minute + round(value.second / 60)

    if isinstance(value, time):
        if value.hour == 0 and value.minute == 0 and value.second == 0:
            return None
        return value.hour * 60 + value.minute + round(value.second / 60)

    if isinstance(value, (int, float)) and not pd.isna(value):
        if value == 0:
            return None
        if 0 < float(value) < 2:
            return round(float(value) * 24 * 60)
        return None

    text = str(value).strip()
    if not text or text in {"0", "00:00", "00:00:00", "-", "ㅡ"}:
        return None

    match = re.search(r"(\d{1,2}):(\d{2})(?::(\d{2}))?", text)
    if not match:
        return None

    hour = int(match.group(1))
    minute = int(match.group(2))
    second = int(match.group(3) or 0)
    if hour == 0 and minute == 0 and second == 0:
        return None
    return hour * 60 + minute + round(second / 60)


def find_note_col(df: pd.DataFrame, header_row: int, train_col: int) -> int | None:
    for col in range(train_col + 1, df.shape[1]):
        value = df.iat[header_row, col]
        if pd.isna(value):
            continue
        if "비고" in str(value):
            return col
    return None


def next_title_row(spec: BlockSpec, specs: Iterable[BlockSpec], n_rows: int) -> int:
    later_rows = [
        other.title_row
        for other in specs
        if other.sheet == spec.sheet and other.title_row > spec.title_row
    ]
    return min(later_rows) if later_rows else n_rows


def parse_fixed_block(
    df: pd.DataFrame,
    path: Path,
    year: int,
    spec: BlockSpec,
    specs: list[BlockSpec],
) -> pd.DataFrame:
    header_row = spec.title_row + 1
    train_col = spec.title_col

    note_col = find_note_col(df, header_row, train_col)
    if note_col is None:
        note_col = next_title_col(df, header_row, train_col)

    train_type_col = None
    if train_col + 1 < df.shape[1] and str(df.iat[header_row, train_col + 1]).strip() == "편성":
        train_type_col = train_col + 1

    station_start_col = train_col + 1 if train_type_col is None else train_col + 2
    station_end_col = note_col - 1 if note_col is not None else df.shape[1] - 1
    row_end = next_title_row(spec, specs, df.shape[0])

    station_cols = []
    for col in range(station_start_col, station_end_col + 1):
        station = normalize_station_name(df.iat[header_row, col])
        if station is not None:
            station_cols.append((col, station))

    records = []
    for row in range(header_row + 1, row_end):
        train_no = parse_train_no(df.iat[row, train_col])
        if train_no is None:
            continue

        train_type = None
        if train_type_col is not None and pd.notna(df.iat[row, train_type_col]):
            train_type = str(df.iat[row, train_type_col]).strip()

        service_note = None
        if note_col is not None and pd.notna(df.iat[row, note_col]):
            service_note = str(df.iat[row, note_col]).strip()

        for order, (col, station) in enumerate(station_cols, start=1):
            minutes = parse_time_cell(df.iat[row, col])
            if minutes is None:
                continue
            records.append(
                {
                    "year": year,
                    "source_file": path.name,
                    "sheet_name": spec.sheet,
                    "line": spec.line,
                    "direction": spec.direction,
                    "train_no": train_no,
                    "train_type": train_type,
                    "station_name": station,
                    "station_order": order,
                    "time_minutes": minutes,
                    "service_note": service_note,
                }
            )

    out = pd.DataFrame.from_records(records)
    if out.empty:
        return out
    return adjust_train_times(out)


def next_title_col(df: pd.DataFrame, header_row: int, train_col: int) -> int | None:
    for col in range(train_col + 1, df.shape[1]):
        value = df.iat[header_row, col]
        if pd.isna(value):
            continue
        if str(value).strip() in {"열차번호", "열번"}:
            return col - 1
    return None


def adjust_train_times(df: pd.DataFrame) -> pd.DataFrame:
    adjusted_parts = []
    keys = ["year", "source_file", "sheet_name", "direction", "train_no"]
    for _, group in df.sort_values(keys + ["station_order"]).groupby(keys, sort=False):
        group = group.copy()
        adjusted = []
        offset = 0
        previous = None
        for value in group["time_minutes"]:
            current = int(value) + offset
            if previous is not None and current < previous:
                offset += 1440
                current = int(value) + offset
            adjusted.append(current)
            previous = current
        group["time_minutes"] = adjusted
        adjusted_parts.append(group)
    return pd.concat(adjusted_parts, ignore_index=True)


def parse_specs(path: Path, year: int, specs: list[BlockSpec]) -> pd.DataFrame:
    dfs = {}
    parsed = []
    for spec in specs:
        if spec.sheet not in dfs:
            dfs[spec.sheet] = pd.read_excel(path, sheet_name=spec.sheet, header=None, dtype=object)
        parsed.append(parse_fixed_block(dfs[spec.sheet], path, year, spec, specs))
    parsed = [x for x in parsed if not x.empty]
    if not parsed:
        return empty_timetable()
    return pd.concat(parsed, ignore_index=True)


def empty_timetable() -> pd.DataFrame:
    return pd.DataFrame(
        columns=[
            "year",
            "source_file",
            "sheet_name",
            "line",
            "direction",
            "train_no",
            "train_type",
            "station_name",
            "station_order",
            "time_minutes",
            "service_note",
        ]
    )


def pair_specs(sheet: str, line: str, row: int, down_col: int, up_col: int) -> list[BlockSpec]:
    return [
        BlockSpec(sheet=sheet, line=line, direction="하행", title_row=row, title_col=down_col),
        BlockSpec(sheet=sheet, line=line, direction="상행", title_row=row, title_col=up_col),
    ]


def vertical_specs(sheet: str, line: str, down_row: int, up_row: int, col: int = 1) -> list[BlockSpec]:
    return [
        BlockSpec(sheet=sheet, line=line, direction="하행", title_row=down_row, title_col=col),
        BlockSpec(sheet=sheet, line=line, direction="상행", title_row=up_row, title_col=col),
    ]


def require_command(command: str) -> str:
    path = shutil.which(command)
    if path is None:
        raise RuntimeError(f"Required command is not available: {command}")
    return path


def run_checked(command: list[str], env: dict[str, str] | None = None) -> None:
    try:
        subprocess.run(command, check=True, capture_output=True, text=True, env=env)
    except subprocess.CalledProcessError as exc:
        details = "\n".join(
            part
            for part in [
                f"Command failed: {' '.join(command)}",
                exc.stdout.strip(),
                exc.stderr.strip(),
            ]
            if part
        )
        raise RuntimeError(details) from exc


def xls_to_pdf(path: Path, temp_dir: Path) -> Path:
    libreoffice = require_command("libreoffice")
    xdg_runtime_dir = temp_dir / "xdg"
    user_profile = temp_dir / "lo-profile"
    xdg_runtime_dir.mkdir()
    user_profile.mkdir()
    xdg_runtime_dir.chmod(0o700)
    user_profile.chmod(0o700)

    env = os.environ.copy()
    env["HOME"] = str(temp_dir)
    env["XDG_RUNTIME_DIR"] = str(xdg_runtime_dir)

    run_checked(
        [
            libreoffice,
            "--headless",
            f"-env:UserInstallation={user_profile.as_uri()}",
            "--convert-to",
            "pdf",
            "--outdir",
            str(temp_dir),
            str(path),
        ],
        env=env,
    )

    pdf_path = temp_dir / f"{path.stem}.pdf"
    if not pdf_path.exists():
        raise RuntimeError(f"LibreOffice did not create expected PDF: {pdf_path}")
    return pdf_path


def pdf_bbox_words(pdf_path: Path, temp_dir: Path) -> list[dict[str, object]]:
    pdftotext = require_command("pdftotext")
    bbox_path = temp_dir / "bbox.html"
    run_checked([pdftotext, "-f", "1", "-l", "2", "-bbox", str(pdf_path), str(bbox_path)])

    ns = {"xhtml": "http://www.w3.org/1999/xhtml"}
    root = ET.parse(bbox_path).getroot()
    pages = root.findall(".//xhtml:page", ns)

    words = []
    for page_no, page in enumerate(pages, start=1):
        for word in page.findall("xhtml:word", ns):
            text = "".join(word.itertext()).strip()
            if not text:
                continue
            x = float(word.attrib["xMin"])
            y = float(word.attrib["yMin"])
            if (page_no == 1 and y >= 738) or (page_no == 2 and -5 <= y <= 95):
                words.append({"page": page_no, "x": x, "y": y, "text": text})
    return words


def group_pdf_rows(words: list[dict[str, object]]) -> list[list[dict[str, object]]]:
    rows = []
    for word in sorted(words, key=lambda x: (x["page"], x["y"], x["x"])):
        if (
            not rows
            or word["page"] != rows[-1][0]["page"]
            or abs(float(word["y"]) - float(rows[-1][0]["y"])) > 2.5
        ):
            rows.append([])
        rows[-1].append(word)
    return rows


def clean_pdf_cell(parts: list[tuple[float, str]]) -> str | None:
    text = "".join(value for _, value in sorted(parts))
    text = re.sub(r"\s+", "", text).replace("：", ":")
    return text or None


def assign_pdf_cells(
    row: list[dict[str, object]],
    columns: list[tuple[str, float]],
    max_distance: float = 8.8,
) -> dict[str, str]:
    cells = {key: [] for key, _ in columns}
    for word in row:
        x = float(word["x"])
        key, center = min(columns, key=lambda column: abs(x - column[1]))
        if abs(x - center) <= max_distance:
            cells[key].append((x, str(word["text"])))
    return {key: text for key, parts in cells.items() if (text := clean_pdf_cell(parts))}


def parse_2007_honam_image_side(
    row: list[dict[str, object]],
    path: Path,
    direction: str,
    columns: list[tuple[str, float]],
    stations: list[str],
) -> list[dict[str, object]]:
    cells = assign_pdf_cells(row, columns)
    train_no = parse_train_no(cells.get("train_no"))
    if train_no is None:
        return []

    service_note = cells.get("service_note")
    records = []
    for station_order, station in enumerate(stations, start=1):
        minutes = parse_time_cell(cells.get(station))
        if minutes is None:
            continue
        records.append(
            {
                "year": 2007,
                "source_file": path.name,
                "sheet_name": "KTX-07년6월1일부터",
                "line": "호남선",
                "direction": direction,
                "train_no": train_no,
                "train_type": None,
                "station_name": station,
                "station_order": station_order,
                "time_minutes": minutes,
                "service_note": service_note,
            }
        )
    return records


def parse_ktx_2007_honam_image(path: Path) -> pd.DataFrame:
    down_stations = [
        "행신역",
        "용산역",
        "광명역",
        "천안아산역",
        "서대전역",
        "계룡역",
        "논산역",
        "익산역",
        "김제역",
        "정읍역",
        "장성역",
        "광주송정역",
        "나주역",
        "목포역",
    ]
    up_stations = [
        "목포역",
        "나주역",
        "광주송정역",
        "장성역",
        "정읍역",
        "김제역",
        "익산역",
        "논산역",
        "계룡역",
        "서대전역",
        "천안아산역",
        "광명역",
        "용산역",
        "행신역",
    ]
    down_columns = [
        ("train_no", 14.2),
        *zip(
            down_stations,
            [30.6, 48.3, 66.0, 83.8, 101.5, 119.3, 136.7, 154.7, 172.5, 190.2, 208.0, 225.7, 242.4, 260.2],
        ),
        ("service_note", 281.9),
    ]
    up_columns = [
        ("train_no", 304.6),
        *zip(
            up_stations,
            [320.8, 338.4, 356.0, 373.5, 391.1, 408.6, 426.2, 443.7, 461.3, 478.8, 496.4, 514.0, 531.5, 548.1],
        ),
        ("service_note", 570.3),
    ]

    with tempfile.TemporaryDirectory(prefix="ktx_2007_honam_") as temp_name:
        temp_dir = Path(temp_name)
        pdf_path = xls_to_pdf(path, temp_dir)
        rows = group_pdf_rows(pdf_bbox_words(pdf_path, temp_dir))

    records = []
    for row in rows:
        records.extend(parse_2007_honam_image_side(row, path, "하행", down_columns, down_stations))
        records.extend(parse_2007_honam_image_side(row, path, "상행", up_columns, up_stations))

    out = pd.DataFrame.from_records(records)
    if out.empty:
        return out
    out = out.drop_duplicates(
        ["year", "source_file", "sheet_name", "line", "direction", "train_no", "station_name", "time_minutes"]
    )
    return adjust_train_times(out)


def parse_ktx_2007(path: Path) -> pd.DataFrame:
    specs = pair_specs("KTX-07년6월1일부터", "경부선", 2, 0, 12)
    parsed = [parse_specs(path, 2007, specs), parse_ktx_2007_honam_image(path)]
    parsed = [x for x in parsed if not x.empty]
    return pd.concat(parsed, ignore_index=True)


def parse_ktx_2008(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선(KTX)", "경부선", 2, 0, 12)
    specs += pair_specs("호남선(KTX)", "호남선", 2, 0, 18)
    return parse_specs(path, 2008, specs)


def parse_ktx_2009(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선(KTX)", "경부선", 2, 0, 12)
    specs += pair_specs("호남선(KTX)", "호남선", 2, 0, 18)
    return parse_specs(path, 2009, specs)


def parse_ktx_2010(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 9, 1, 15)
    specs += vertical_specs("호남선", "호남선", 7, 35, 1)
    return parse_specs(path, 2010, specs)


def parse_ktx_2011(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선 KTX", "경부선", 6, 1, 16)
    specs += vertical_specs("경전선 KTX", "경전선", 5, 22, 1)
    specs += vertical_specs("호남선 KTX", "호남선", 5, 31, 1)
    specs += vertical_specs("전라선 KTX", "전라선", 5, 15, 1)
    return parse_specs(path, 2011, specs)


def parse_ktx_2012(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선KTX", "경부선", 6, 1, 16)
    specs += vertical_specs("경전선KTX", "경전선", 5, 22, 1)
    specs += vertical_specs("호남선KTX", "호남선", 5, 32, 1)
    specs += vertical_specs("전라선KTX", "전라선", 5, 16, 1)
    return parse_specs(path, 2012, specs)


def parse_ktx_2013(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 6, 1, 16)
    specs += vertical_specs("경전선", "경전선", 5, 22, 1)
    specs += vertical_specs("호남선", "호남선", 5, 33, 1)
    specs += vertical_specs("전라선", "전라선", 5, 17, 1)
    return parse_specs(path, 2013, specs)


def parse_ktx_2014(path: Path) -> pd.DataFrame:
    specs = []
    specs += vertical_specs("경부선", "경부선", 6, 87, 1)
    specs += vertical_specs("경전선", "경전선", 5, 22, 1)
    specs += vertical_specs("호남선", "호남선", 5, 32, 1)
    specs += vertical_specs("전라선", "전라선", 5, 19, 1)
    return parse_specs(path, 2014, specs)


def parse_ktx_2015(path: Path) -> pd.DataFrame:
    specs = []
    specs += vertical_specs("경부선", "경부선", 6, 88, 0)
    specs += vertical_specs("경전선", "경전선", 5, 22, 0)
    specs += vertical_specs("동해선", "동해선", 5, 20, 0)
    specs += vertical_specs("호남선", "호남선", 5, 43, 0)
    specs += vertical_specs("전라선", "전라선", 5, 20, 0)
    return parse_specs(path, 2015, specs)


def parse_ktx_2016(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 6, 1, 24)
    specs += vertical_specs("경전선", "경전선", 5, 22, 0)
    specs += vertical_specs("동해선", "동해선", 5, 21, 1)
    specs += pair_specs("호남선", "호남선", 5, 1, 22)
    specs += vertical_specs("전라선", "전라선", 5, 22, 1)
    return parse_specs(path, 2016, specs)


def parse_ktx_2017(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 6, 1, 24)
    specs += vertical_specs("경전선", "경전선", 5, 24, 0)
    specs += vertical_specs("동해선", "동해선", 5, 24, 1)
    specs += pair_specs("호남선", "호남선", 5, 1, 22)
    specs += vertical_specs("전라선", "전라선", 5, 25, 1)
    return parse_specs(path, 2017, specs)


def parse_ktx_2018(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 6, 1, 22)
    specs += vertical_specs("경전선", "경전선", 5, 24, 0)
    specs += vertical_specs("동해선", "동해선", 5, 24, 1)
    specs += pair_specs("호남선", "호남선", 5, 1, 20)
    specs += vertical_specs("전라선", "전라선", 5, 25, 1)
    specs += pair_specs("강릉선", "강릉선", 3, 0, 14)
    return parse_specs(path, 2018, specs)


def parse_ktx_2019(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 1, 1, 22)
    specs += vertical_specs("경전선", "경전선", 1, 22, 1)
    specs += vertical_specs("동해선", "동해선", 1, 21, 1)
    specs += pair_specs("호남선", "호남선", 1, 1, 22)
    specs += vertical_specs("전라선", "전라선", 1, 22, 1)
    specs += pair_specs("강릉선", "강릉선", 1, 1, 15)
    return parse_specs(path, 2019, specs)


def parse_ktx_2020(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 1, 1, 21)
    specs += vertical_specs("경전선", "경전선", 1, 22, 1)
    specs += vertical_specs("동해선", "동해선", 1, 20, 1)
    specs += pair_specs("호남선", "호남선", 1, 1, 22)
    specs += vertical_specs("전라선", "전라선", 1, 22, 1)
    specs += pair_specs("강릉선", "강릉선", 1, 1, 18)
    return parse_specs(path, 2020, specs)


def parse_ktx_2021(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 1, 1, 22)
    specs += vertical_specs("경전선", "경전선", 1, 21, 1)
    specs += vertical_specs("동해선", "동해선", 1, 22, 1)
    specs += pair_specs("호남선", "호남선", 1, 1, 22)
    specs += vertical_specs("전라선", "전라선", 1, 22, 1)
    specs += pair_specs("강릉선", "강릉선", 1, 1, 19)
    specs += pair_specs("중앙선", "중앙선", 1, 1, 14)
    specs += pair_specs("중부내륙선", "중부내륙선", 1, 1, 10)
    return parse_specs(path, 2021, specs)


def parse_ktx_2022(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 1, 1, 22)
    specs += vertical_specs("경전선", "경전선", 1, 21, 1)
    specs += vertical_specs("동해선", "동해선", 1, 22, 1)
    specs += pair_specs("호남선", "호남선", 1, 1, 22)
    specs += vertical_specs("전라선", "전라선", 1, 22, 1)
    specs += pair_specs("강릉선", "강릉선", 1, 1, 19)
    specs += pair_specs("중앙선", "중앙선", 1, 1, 14)
    specs += pair_specs("중부내륙선(21년 12월 31일부터)", "중부내륙선", 1, 1, 10)
    return parse_specs(path, 2022, specs)


def parse_ktx_2023(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 6, 1, 23)
    specs += pair_specs("경전선", "경전선", 5, 0, 21)
    specs += pair_specs("동해선", "동해선", 5, 1, 15)
    specs += pair_specs("호남선", "호남선", 5, 1, 22)
    specs += pair_specs("전라선", "전라선", 5, 1, 23)
    specs += pair_specs("강릉선", "강릉선", 6, 1, 21)
    specs += pair_specs("중앙선", "중앙선", 6, 1, 16)
    specs += pair_specs("중부내륙선", "중부내륙선", 6, 1, 11)
    return parse_specs(path, 2023, specs)


def parse_ktx_2024(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 6, 1, 23)
    specs += pair_specs("경전선", "경전선", 5, 0, 21)
    specs += pair_specs("동해선", "동해선", 5, 1, 15)
    specs += pair_specs("호남선", "호남선", 5, 1, 22)
    specs += pair_specs("전라선", "전라선", 5, 1, 23)
    specs += pair_specs("강릉선", "강릉선", 6, 1, 21)
    specs += pair_specs("중앙선", "중앙선", 6, 1, 16)
    specs += pair_specs("중부내륙선", "중부내륙선", 6, 1, 11)
    return parse_specs(path, 2024, specs)


def parse_ktx_2025(path: Path) -> pd.DataFrame:
    specs = []
    specs += pair_specs("경부선", "경부선", 6, 1, 23)
    specs += pair_specs("경전선", "경전선", 5, 0, 21)
    specs += pair_specs("동해선(서울~포항)", "동해선(서울~포항)", 5, 1, 15)
    specs += pair_specs("동해선(부전-강릉)", "동해선(부전-강릉)", 5, 1, 17)
    specs += pair_specs("호남선", "호남선", 5, 1, 22)
    specs += pair_specs("전라선", "전라선", 5, 1, 23)
    specs += pair_specs("강릉선", "강릉선", 6, 1, 21)
    specs += pair_specs("중앙선", "중앙선", 6, 1, 27)
    specs += pair_specs("중부내륙선", "중부내륙선", 6, 1, 15)
    return parse_specs(path, 2025, specs)


PARSERS = {
    2007: parse_ktx_2007,
    2008: parse_ktx_2008,
    2009: parse_ktx_2009,
    2010: parse_ktx_2010,
    2011: parse_ktx_2011,
    2012: parse_ktx_2012,
    2013: parse_ktx_2013,
    2014: parse_ktx_2014,
    2015: parse_ktx_2015,
    2016: parse_ktx_2016,
    2017: parse_ktx_2017,
    2018: parse_ktx_2018,
    2019: parse_ktx_2019,
    2020: parse_ktx_2020,
    2021: parse_ktx_2021,
    2022: parse_ktx_2022,
    2023: parse_ktx_2023,
    2024: parse_ktx_2024,
    2025: parse_ktx_2025,
}


def timetable_path(year: int) -> Path:
    matches = sorted(RAW_KTX.glob(f"{year}년 KTX*"))
    if not matches:
        raise FileNotFoundError(f"No KTX timetable file for {year}")
    return matches[0]


def parse_all_years(years: Iterable[int]) -> pd.DataFrame:
    parsed = []
    start_time = perf_counter()
    for year in years:
        year_start = perf_counter()
        print(f"[{perf_counter() - start_time:8.1f}s] parsing {year}", flush=True)
        path = timetable_path(year)
        parsed_year = PARSERS[year](path)
        parsed.append(parsed_year)
        print(
            f"[{perf_counter() - start_time:8.1f}s] parsed {year}: "
            f"{len(parsed_year):,} rows ({perf_counter() - year_start:.1f}s)",
            flush=True,
        )
    if not parsed:
        return empty_timetable()
    return pd.concat(parsed, ignore_index=True)


def make_terminal_summary(timetable: pd.DataFrame) -> pd.DataFrame:
    if timetable.empty:
        return pd.DataFrame()

    rows = []
    keys = ["year", "source_file", "sheet_name", "line", "direction", "train_no"]
    up = timetable[timetable["direction"] == "상행"].copy()

    for _, train in up.groupby(keys, sort=False):
        terminal_rows = train[train["station_name"].isin(TERMINAL_STATIONS)]
        for _, terminal in terminal_rows.iterrows():
            terminal_time = terminal["time_minutes"]
            terminal_station = terminal["station_name"]
            origins = train[train["time_minutes"] < terminal_time].copy()
            origins = origins[origins["station_name"] != terminal_station]
            for _, origin in origins.iterrows():
                rows.append(
                    {
                        "year": origin["year"],
                        "station_name": origin["station_name"],
                        "terminal_station": terminal_station,
                        "train_no": origin["train_no"],
                        "departure_minutes": origin["time_minutes"] % 1440,
                        "ktx_travel_time": terminal_time - origin["time_minutes"],
                    }
                )

    detail = pd.DataFrame.from_records(rows)
    if detail.empty:
        return pd.DataFrame(
            columns=[
                "year",
                "station_name",
                "terminal_station",
                "ktx_travel_time_min",
                "ktx_travel_time_median",
                "ktx_travel_time_mean",
                "interval_minutes",
                "n_trains",
            ]
        )

    def interval(values: pd.Series) -> float | None:
        values = sorted(values.dropna().astype(int).tolist())
        if len(values) <= 1:
            return None
        gaps = [b - a for a, b in zip(values[:-1], values[1:])]
        return sum(gaps) / len(gaps)

    summary = (
        detail.groupby(["year", "station_name", "terminal_station"], as_index=False)
        .agg(
            ktx_travel_time_min=("ktx_travel_time", "min"),
            ktx_travel_time_median=("ktx_travel_time", "median"),
            ktx_travel_time_mean=("ktx_travel_time", "mean"),
            interval_minutes=("departure_minutes", interval),
            n_trains=("train_no", "nunique"),
        )
        .sort_values(["year", "station_name", "terminal_station"])
        .reset_index(drop=True)
    )
    return summary


def write_outputs(timetable: pd.DataFrame, summary: pd.DataFrame) -> None:
    CLEAN_CSV.mkdir(parents=True, exist_ok=True)
    CLEAN_PARQUET.mkdir(parents=True, exist_ok=True)

    timetable.to_csv(CLEAN_CSV / "ktx_timetable_long.csv", index=False)
    summary.to_csv(CLEAN_CSV / "ktx_station_to_terminal_time.csv", index=False)
    timetable.to_parquet(CLEAN_PARQUET / "ktx_timetable_long.parquet", index=False)
    summary.to_parquet(CLEAN_PARQUET / "ktx_station_to_terminal_time.parquet", index=False)


def report(timetable: pd.DataFrame, summary: pd.DataFrame) -> None:
    print("ktx_timetable_long")
    print(f"  rows: {len(timetable):,}")
    print("  rows by year:")
    print(timetable.groupby("year").size().to_string())
    print()
    print("ktx_station_to_terminal_time")
    print(f"  rows: {len(summary):,}")
    print("  rows by year:")
    print(summary.groupby("year").size().to_string())
    print()
    print("  sample terminal summary:")
    print(summary.head(20).to_string(index=False))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="report results without writing files")
    parser.add_argument("--write", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--start-year", type=int, default=2007)
    parser.add_argument("--end-year", type=int, default=2025)
    args = parser.parse_args()

    years = range(args.start_year, args.end_year + 1)
    missing = sorted(set(years) - set(PARSERS))
    if missing:
        raise ValueError(f"No parser implemented for years: {missing}")

    timetable = parse_all_years(years)
    summary = make_terminal_summary(timetable)
    report(timetable, summary)

    if args.dry_run:
        print("dry-run: no files written")
    else:
        write_outputs(timetable, summary)
        print("wrote outputs to clean_csv/ and clean_parquet/")


if __name__ == "__main__":
    main()
