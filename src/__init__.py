"""Source package for the Olist customer analytics project."""

from .config import (
    DBEngine,
    PG_HOST,
    PG_PORT,
    PG_USER,
    PG_DATABASE,
    RAW_DATA_DIR,
    PROCESSED_DATA_DIR,
    PROJECT_ROOT,
)

__all__ = [
    "DBEngine",
    "PG_HOST",
    "PG_PORT",
    "PG_USER",
    "PG_DATABASE",
    "RAW_DATA_DIR",
    "PROCESSED_DATA_DIR",
    "PROJECT_ROOT",
]
