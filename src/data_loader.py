"""Loading and cleaning the Olist e-commerce dataset.

This module is the single entry point for getting raw Olist CSVs off disk
and into tidy ``pandas`` DataFrames:

  * :data:`OLIST_FILES` maps each of the 9 canonical CSV filenames to a short
    table name.
  * :func:`load_all_tables` reads every CSV in a directory, parsing the
    ``*_date`` / ``*_timestamp`` columns of the orders and reviews tables.
  * :func:`clean_table` trims whitespace, normalizes column names and (for
    orders) enforces datetime dtypes.
  * :func:`validate_ids` checks primary-key uniqueness.
  :func:`print_schema_summary` prints a quick shape/dtype/null audit.

Processed snapshots can be persisted to / reloaded from parquet via
:func:`save_processed` and :func:`load_processed`.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Dict, Iterable, List, Optional

import pandas as pd

from .config import PROCESSED_DATA_DIR, RAW_DATA_DIR

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Canonical Olist CSV filenames (one constant per table)
# ---------------------------------------------------------------------------
CUSTOMERS_CSV = "olist_customers_dataset.csv"
ORDERS_CSV = "olist_orders_dataset.csv"
ORDER_ITEMS_CSV = "olist_order_items_dataset.csv"
ORDER_PAYMENTS_CSV = "olist_order_payments_dataset.csv"
ORDER_REVIEWS_CSV = "olist_order_reviews_dataset.csv"
PRODUCTS_CSV = "olist_products_dataset.csv"
SELLERS_CSV = "olist_sellers_dataset.csv"
GEOLOCATION_CSV = "olist_geolocation_dataset.csv"
PRODUCT_CATEGORY_TRANSLATION_CSV = "product_category_name_translation.csv"

#: Map of CSV filename -> short table name. Iteration order is stable.
OLIST_FILES: Dict[str, str] = {
    CUSTOMERS_CSV: "customers",
    ORDERS_CSV: "orders",
    ORDER_ITEMS_CSV: "order_items",
    ORDER_PAYMENTS_CSV: "order_payments",
    ORDER_REVIEWS_CSV: "order_reviews",
    PRODUCTS_CSV: "products",
    SELLERS_CSV: "sellers",
    GEOLOCATION_CSV: "geolocation",
    PRODUCT_CATEGORY_TRANSLATION_CSV: "product_category_translation",
}

#: Tables whose ``*_date`` / ``*_timestamp`` columns should be parsed as dates.
DATE_PARSING_TABLES = {"orders", "order_reviews"}

#: Suffixes that mark a column as a datetime field.
_DATE_SUFFIXES = ("_date", "_timestamp")


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
def _datetime_columns(path: Path) -> List[str]:
    """Return columns ending in ``_date`` / ``_timestamp`` for the CSV at *path*.

    Reads only the header (``nrows=0``) so this stays cheap even for big files.
    """
    try:
        header = pd.read_csv(path, nrows=0).columns
    except pd.errors.EmptyDataError:
        return []
    return [c for c in header if isinstance(c, str) and c.endswith(_DATE_SUFFIXES)]


def _normalize_column(name: str) -> str:
    """Collapse a column name to canonical snake_case.

    The Olist columns ship already snake_case, so this is mostly a guard: it
    logs any column it actually changes.
    """
    cleaned = re.sub(r"[^0-9a-zA-Z_]+", "_", name).strip("_").lower()
    if cleaned != name:
        logger.warning("column renamed %r -> %r", name, cleaned)
    return cleaned


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
def load_all_tables(raw_dir: Path | str = RAW_DATA_DIR) -> Dict[str, pd.DataFrame]:
    """Read every available Olist CSV from *raw_dir* into a dict of frames.

    Parameters
    ----------
    raw_dir:
        Directory holding the raw CSVs. Defaults to :data:`RAW_DATA_DIR`.

    Returns
    -------
    dict[str, pandas.DataFrame]
        ``{table_name: DataFrame}`` for every CSV that was present. Missing
        files are skipped with a warning, so a partial dataset still loads.

    Notes
    -----
    The ``orders`` and ``order_reviews`` tables have their ``*_date`` and
    ``*_timestamp`` columns parsed directly by ``read_csv`` (via
    ``parse_dates``) so downstream code sees proper datetimes.
    """
    raw_path = Path(raw_dir)
    if not raw_path.exists():
        raise FileNotFoundError(f"Raw data directory not found: {raw_path}")

    tables: Dict[str, pd.DataFrame] = {}
    for filename, name in OLIST_FILES.items():
        path = raw_path / filename
        if not path.exists():
            logger.warning("missing CSV for '%s': %s", name, path)
            continue

        read_kwargs: Dict[str, object] = {}
        if name in DATE_PARSING_TABLES:
            date_cols = _datetime_columns(path)
            if date_cols:
                read_kwargs["parse_dates"] = date_cols

        tables[name] = pd.read_csv(path, **read_kwargs)
        logger.info("loaded '%s' (%s rows) from %s", name, len(tables[name]), path.name)

    logger.info("loaded %d/%d tables from %s", len(tables), len(OLIST_FILES), raw_path)
    return tables


def list_raw_files(raw_dir: Path | str = RAW_DATA_DIR) -> List[Path]:
    """Return every ``.csv`` present in *raw_dir*, sorted."""
    raw_path = Path(raw_dir)
    if not raw_path.exists():
        return []
    return sorted(raw_path.glob("*.csv"))


def load_raw_table(name: str, **read_csv_kwargs) -> pd.DataFrame:
    """Load a single raw CSV by its short table *name* (see :data:`OLIST_FILES`).

    Any extra keyword args are forwarded to ``pandas.read_csv``.
    """
    filename = next((f for f, n in OLIST_FILES.items() if n == name), None)
    if filename is None:
        raise KeyError(f"Unknown raw table '{name}'. Known: {list(OLIST_FILES.values())}")
    path = RAW_DATA_DIR / filename
    if not path.exists():
        raise FileNotFoundError(
            f"Expected '{path}'. Drop the Olist CSVs into {RAW_DATA_DIR} first."
        )
    return pd.read_csv(path, **read_csv_kwargs)


def load_all_raw() -> Dict[str, pd.DataFrame]:
    """Backward-compatible alias for :func:`load_all_tables` using the default dir."""
    return load_all_tables(RAW_DATA_DIR)


# ---------------------------------------------------------------------------
# Cleaning
# ---------------------------------------------------------------------------
def clean_table(name: str, df: pd.DataFrame) -> pd.DataFrame:
    """Apply standard cleaning to a single table.

    Steps applied to every table:

    * **Trim whitespace** on all string columns.
    * **Verify snake_case column names**; rename anything that is not already
      canonical snake_case (a no-op for the standard Olist schema).

    Extra steps applied to ``orders`` specifically:

    * **Coerce datetime dtypes** on every ``*_date`` / ``*_timestamp`` column
      (parse failures become ``NaT`` rather than raising).

    The input frame is not mutated; a cleaned copy is returned.
    """
    out = df.copy()

    # 1. Verify / normalize column names to snake_case.
    renamed = {col: _normalize_column(col) for col in out.columns}
    if any(k != v for k, v in renamed.items()):
        out = out.rename(columns=renamed)
        logger.warning("'%s' had non-snake_case columns; renamed", name)

    # 2. Trim whitespace on string columns.
    str_cols = out.select_dtypes(include=["object", "string"]).columns
    for col in str_cols:
        out[col] = out[col].str.strip()

    # 3. Orders: enforce datetime dtypes on timestamp/date columns.
    if name == "orders":
        for col in out.columns:
            if isinstance(col, str) and col.endswith(_DATE_SUFFIXES):
                out[col] = pd.to_datetime(out[col], errors="coerce")
        logger.debug("'%s' datetime columns coerced", name)

    return out


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
def validate_ids(df: pd.DataFrame, id_col: str) -> bool:
    """Check that *id_col* has no duplicate primary keys.

    Returns ``True`` when all values are unique. When duplicates are found the
    check **warns** (it does not raise) and returns ``False`` — useful during
    EDA where you want to see problems without halting the pipeline.
    """
    if id_col not in df.columns:
        raise KeyError(f"id column '{id_col}' not in dataframe columns: {list(df.columns)}")

    dup_count = int(df[id_col].duplicated().sum())
    if dup_count:
        sample = df.loc[df[id_col].duplicated(), id_col].head(5).tolist()
        logger.warning(
            "'%s' has %d duplicate primary keys in column '%s' (sample: %s)",
            getattr(df, "__name__", "table"),
            dup_count,
            id_col,
            sample,
        )
        return False
    logger.debug("'%s' OK: %d unique ids", id_col, len(df))
    return True


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def print_schema_summary(tables: Dict[str, pd.DataFrame]) -> None:
    """Print a quick audit (shape, dtypes, null counts) for each table."""
    for name, df in tables.items():
        print(f"\n=== {name} ===")
        print(f"shape: {df.shape[0]:,} rows x {df.shape[1]} cols")
        print("\ndtypes:")
        print(df.dtypes.to_string())
        nulls = df.isna().sum()
        nulls = nulls[nulls > 0].sort_values(ascending=False)
        if not nulls.empty:
            print("\nnull counts (non-zero only):")
            print(nulls.to_string())
        else:
            print("\nnull counts: none")


# ---------------------------------------------------------------------------
# Processed-snapshot persistence (parquet)
# ---------------------------------------------------------------------------
def save_processed(df: pd.DataFrame, name: str) -> Path:
    """Persist a cleaned DataFrame to ``data/processed/<name>.parquet``."""
    out = PROCESSED_DATA_DIR / f"{name}.parquet"
    df.to_parquet(out, index=False)
    logger.info("wrote %s (%s rows)", out, len(df))
    return out


def load_processed(name: str) -> pd.DataFrame:
    """Reload a previously saved processed snapshot by *name*."""
    path = PROCESSED_DATA_DIR / f"{name}.parquet"
    if not path.exists():
        raise FileNotFoundError(
            f"No processed snapshot '{name}'. Run the cleaning notebook first."
        )
    return pd.read_parquet(path)


__all__ = [
    # constants
    "CUSTOMERS_CSV",
    "ORDERS_CSV",
    "ORDER_ITEMS_CSV",
    "ORDER_PAYMENTS_CSV",
    "ORDER_REVIEWS_CSV",
    "PRODUCTS_CSV",
    "SELLERS_CSV",
    "GEOLOCATION_CSV",
    "PRODUCT_CATEGORY_TRANSLATION_CSV",
    "OLIST_FILES",
    "DATE_PARSING_TABLES",
    # loading
    "load_all_tables",
    "load_all_raw",
    "load_raw_table",
    "list_raw_files",
    # cleaning / validation / reporting
    "clean_table",
    "validate_ids",
    "print_schema_summary",
    # persistence
    "save_processed",
    "load_processed",
]
