"""Central configuration and paths.

Loads environment variables from a project-root ``.env`` file via
``python-dotenv`` and exposes:
  * Project-wide path constants (``PROJECT_ROOT``, ``RAW_DATA_DIR`` ...).
  * A lazily-constructed SQLAlchemy ``DBEngine`` singleton so every module
    shares a single connection pool instead of opening new engines.

Copy ``.env.example`` to ``.env`` and fill in real values before running
anything that touches the database or raw data.
"""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import Engine, create_engine

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# src/config.py -> project root is two levels up.
PROJECT_ROOT: Path = Path(__file__).resolve().parent.parent

# Load .env from the project root (no-op if the file is absent).
load_dotenv(PROJECT_ROOT / ".env")


def _resolve_dir(env_key: str, default: str) -> Path:
    """Resolve a directory from the environment, falling back to a default.

    The value may be absolute or relative to the project root. The directory
    is created on demand so callers can write into it without extra setup.
    """
    raw = os.getenv(env_key, default)
    path = Path(raw)
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    path.mkdir(parents=True, exist_ok=True)
    return path


RAW_DATA_DIR: Path = _resolve_dir("RAW_DATA_DIR", "data/raw")
PROCESSED_DATA_DIR: Path = _resolve_dir("PROCESSED_DATA_DIR", "data/processed")

# ---------------------------------------------------------------------------
# Postgres credentials
# ---------------------------------------------------------------------------
PG_HOST: str = os.getenv("PG_HOST", "localhost")
PG_PORT: str = os.getenv("PG_PORT", "5432")
PG_USER: str = os.getenv("PG_USER", "postgres")
PG_PASSWORD: str = os.getenv("PG_PASSWORD", "changeme")
PG_DATABASE: str = os.getenv("PG_DATABASE", "olist_analytics")


def database_url() -> str:
    """Build a SQLAlchemy PostgreSQL connection URL from the env vars."""
    return (
        f"postgresql+psycopg2://{PG_USER}:{PG_PASSWORD}"
        f"@{PG_HOST}:{PG_PORT}/{PG_DATABASE}"
    )


@lru_cache(maxsize=1)
def _build_engine() -> Engine:
    """Construct (once) the shared SQLAlchemy engine.

    ``pool_pre_ping`` issues a lightweight ``SELECT 1`` before reusing a
    connection so stale connections left idle in the pool don't blow up.
    """
    return create_engine(database_url(), pool_pre_ping=True, future=True)


class DBEngine:
    """Singleton accessor for the shared SQLAlchemy engine.

    Use ``DBEngine.engine`` anywhere you need an engine or connection::

        from src.config import DBEngine
        with DBEngine.engine.connect() as conn:
            ...
    """

    engine: Engine = _build_engine()


__all__ = [
    "PROJECT_ROOT",
    "RAW_DATA_DIR",
    "PROCESSED_DATA_DIR",
    "PG_HOST",
    "PG_PORT",
    "PG_USER",
    "PG_PASSWORD",
    "PG_DATABASE",
    "database_url",
    "DBEngine",
]
