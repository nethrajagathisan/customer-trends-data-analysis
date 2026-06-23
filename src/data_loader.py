"""Loading and persisting raw/processed data.

Responsibilities:
  * Discover Olist CSVs under ``data/raw/``.
  * Read them into typed ``pandas`` DataFrames with sane dtypes.
  * Snapshot cleaned outputs to ``data/processed/`` as Parquet (cheap to read,
    keeps types intact) and reload them later without re-running cleaning.
"""

from __future__ import annotations

from pathlib import Path
from typing import Dict

import pandas as pd

from .config import PROCESSED_DATA_DIR, RAW_DATA_DIR

# Canonical file -> table mapping for the Olist dataset.
# Files that aren't present are skipped silently so partial datasets work.
OLIST_FILES: Dict[str, str] = {
    "olist_customers_dataset.csv": "customers",
    "olist_geolocation_dataset.csv": "geolocation",
    "olist_order_items_dataset.csv": "order_items",
    "olist_order_payments_dataset.csv": "order_payments",
    "olist_order_reviews_dataset.csv": "order_reviews",
    "olist_orders_dataset.csv": "orders",
    "olist_products_dataset.csv": "products",
    "olist_sellers_dataset.csv": "sellers",
    "product_category_name_translation.csv": "product_category_translation",
}


def list_raw_files() -> list[Path]:
    """Return every ``.csv`` currently present under ``RAW_DATA_DIR``."""
    if not RAW_DATA_DIR.exists():
        return []
    return sorted(RAW_DATA_DIR.glob("*.csv"))


def load_raw_table(name: str, **read_csv_kwargs) -> pd.DataFrame:
    """Load a single raw CSV by its table ``name`` (see ``OLIST_FILES``).

    Raises ``FileNotFoundError`` if the file isn't on disk yet.
    """
    filename = next((f for f, n in OLIST_FILES.items() if n == name), None)
    if filename is None:
        raise KeyError(f"Unknown raw table '{name}'. Known: {list(OLIST_FILES)}")
    path = RAW_DATA_DIR / filename
    if not path.exists():
        raise FileNotFoundError(
            f"Expected '{path}'. Drop the Olist CSVs into {RAW_DATA_DIR} first."
        )
    return pd.read_csv(path, **read_csv_kwargs)


def load_all_raw() -> Dict[str, pd.DataFrame]:
    """Load every available Olist CSV into a ``{table: DataFrame}`` dict.

    Missing files are simply omitted, so the result keys tell you which
    tables you actually have on disk.
    """
    tables: Dict[str, pd.DataFrame] = {}
    for filename, name in OLIST_FILES.items():
        path = RAW_DATA_DIR / filename
        if path.exists():
            tables[name] = pd.read_csv(path)
    return tables


def save_processed(df: pd.DataFrame, name: str) -> Path:
    """Persist a cleaned DataFrame to ``data/processed/<name>.parquet``."""
    out = PROCESSED_DATA_DIR / f"{name}.parquet"
    df.to_parquet(out, index=False)
    return out


def load_processed(name: str) -> pd.DataFrame:
    """Reload a previously saved processed snapshot by name."""
    path = PROCESSED_DATA_DIR / f"{name}.parquet"
    if not path.exists():
        raise FileNotFoundError(
            f"No processed snapshot '{name}'. Run the cleaning notebook first."
        )
    return pd.read_parquet(path)


__all__ = [
    "OLIST_FILES",
    "list_raw_files",
    "load_raw_table",
    "load_all_raw",
    "save_processed",
    "load_processed",
]
