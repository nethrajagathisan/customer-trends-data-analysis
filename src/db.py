"""Database helpers for loading Olist data into a PostgreSQL star schema.

Built on SQLAlchemy. Three layers:

  * :func:`get_engine` — builds a single shared ``postgresql+psycopg2`` engine
    from environment variables (via :mod:`src.config`).
  * :func:`load_df_to_sql` — writes one DataFrame to a table.
  * :func:`load_all_to_star_schema` — loops a ``{table: DataFrame}`` dict and
    writes each, continuing on error and logging progress.

Ad-hoc helpers :func:`test_connection`, :func:`run_script` and :func:`query`
are kept for notebook use.
"""

from __future__ import annotations

import logging
from typing import Dict, Iterator

import pandas as pd
from sqlalchemy import Engine, create_engine, text
from sqlalchemy.exc import SQLAlchemyError

from .config import DBEngine, PG_DATABASE, PG_HOST, PG_PASSWORD, PG_PORT, PG_USER, database_url

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------
def get_engine() -> Engine:
    """Return the shared SQLAlchemy engine.

    The engine is created once via :class:`src.config.DBEngine` so the whole
    process reuses one connection pool.
    """
    return DBEngine.engine


def _build_engine() -> Engine:
    """Construct a postgres ``postgresql+psycopg2://`` engine from env vars.

    Used internally by :class:`src.config.DBEngine`. Exposed here so callers
    who want a fresh, non-shared engine (e.g. a second database) can build one
    with the same credentials.
    """
    return create_engine(
        database_url(),
        pool_pre_ping=True,
        future=True,
    )


# ---------------------------------------------------------------------------
# DataFrame loading
# ---------------------------------------------------------------------------
def load_df_to_sql(
    df: pd.DataFrame,
    table_name: str,
    if_exists: str = "replace",
) -> int:
    """Write *df* to a database table via ``DataFrame.to_sql``.

    Parameters
    ----------
    df:
        DataFrame to persist.
    table_name:
        Target table name in the default schema.
    if_exists:
        What to do if the table already exists: ``'replace'``, ``'append'``
        or ``'fail'`` (pandas default semantics).

    Returns
    -------
    int
        Number of rows written (``len(df)``).
    """
    if if_exists not in {"fail", "replace", "append"}:
        raise ValueError(
            f"if_exists must be one of fail/replace/append, got {if_exists!r}"
        )

    rows = len(df)
    df.to_sql(
        table_name,
        con=get_engine(),
        if_exists=if_exists,
        index=False,
    )
    logger.info("loaded %s -> table '%s' (%s rows)", type(df).__name__, table_name, rows)
    return rows


def load_all_to_star_schema(
    star_tables: Dict[str, pd.DataFrame],
    if_exists: str = "replace",
) -> Dict[str, int]:
    """Load every table in *star_tables* into the database.

    Each ``{table_name: DataFrame}`` pair is written with
    :func:`load_df_to_sql`. A failure on one table does not abort the rest;
    the failing table is logged and skipped, and its result value is ``-1``.

    Parameters
    ----------
    star_tables:
        Mapping of table name -> DataFrame to load.
    if_exists:
        Forwarded to :func:`load_df_to_sql` for every table.

    Returns
    -------
    dict[str, int]
        ``{table_name: rows_written}`` for each table attempted. Tables that
        failed to load have a value of ``-1``.
    """
    results: Dict[str, int] = {}
    total = len(star_tables)
    for i, (table_name, df) in enumerate(star_tables.items(), start=1):
        try:
            rows = load_df_to_sql(df, table_name, if_exists=if_exists)
            results[table_name] = rows
            logger.info("[%d/%d] loaded '%s' (%s rows)", i, total, table_name, rows)
        except SQLAlchemyError as exc:
            results[table_name] = -1
            logger.exception("[%d/%d] failed to load '%s': %s", i, total, table_name, exc)
        except Exception as exc:  # pragma: no cover - defensive catch-all
            results[table_name] = -1
            logger.exception("[%d/%d] unexpected error loading '%s': %s", i, total, table_name, exc)

    succeeded = sum(1 for v in results.values() if v >= 0)
    logger.info("loaded %d/%d tables into star schema", succeeded, total)
    return results


# ---------------------------------------------------------------------------
# Ad-hoc helpers (notebook convenience)
# ---------------------------------------------------------------------------
def test_connection() -> bool:
    """Open and close a connection, returning ``True`` on success.

    Handy sanity check during notebook setup::

        from src.db import test_connection
        assert test_connection()
    """
    try:
        with get_engine().connect() as conn:
            conn.execute(text("SELECT 1"))
        logger.info("database connection OK: %s@%s/%s", PG_USER, PG_HOST, PG_DATABASE)
        return True
    except SQLAlchemyError as exc:  # pragma: no cover - diagnostic only
        logger.error("database connection check failed: %s", exc)
        return False


def run_script(sql_path: str) -> None:
    """Execute a ``.sql`` file (DDL/DML) against the database.

    Splits on ``;`` so multiple statements in one file (e.g. the star-schema
    DDL in ``sql/00_create_star_schema.sql``) all execute inside one
    transaction.
    """
    path = sql_path
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()

    statements = [s.strip() for s in raw.split(";") if s.strip()]
    with get_engine().begin() as conn:
        for stmt in statements:
            conn.execute(text(stmt))
    logger.info("executed %d statements from %s", len(statements), sql_path)


def query(sql: str, params: dict | None = None) -> Iterator[dict]:
    """Yield each row of *sql* as a dict — convenience for ad-hoc queries."""
    with get_engine().connect() as conn:
        result = conn.execute(text(sql), params or {})
        for row in result.mappings():
            yield dict(row)


__all__ = [
    "get_engine",
    "load_df_to_sql",
    "load_all_to_star_schema",
    # ad-hoc helpers
    "test_connection",
    "run_script",
    "query",
]
