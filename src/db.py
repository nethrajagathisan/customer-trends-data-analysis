"""Database helpers built on top of the shared engine.

Thin wrappers around the ``DBEngine`` singleton so notebooks and scripts
don't repeat connection boilerplate.
"""

from __future__ import annotations

from typing import Iterator

from sqlalchemy import Engine, text
from sqlalchemy.exc import SQLAlchemyError

from .config import DBEngine


def get_engine() -> Engine:
    """Return the shared SQLAlchemy engine."""
    return DBEngine.engine


def test_connection() -> bool:
    """Open and close a connection, returning True on success.

    Handy sanity check during notebook setup::

        from src.db import test_connection
        assert test_connection()
    """
    try:
        with DBEngine.engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except SQLAlchemyError as exc:  # pragma: no cover - diagnostic only
        print(f"[db] connection check failed: {exc}")
        return False


def run_script(sql_path: str) -> None:
    """Execute a ``.sql`` file (DDL/DML) against the database.

    Splits on ``;`` so multiple statements in one file (e.g. the star-schema
    DDL in ``sql/00_create_star_schema.sql``) all execute.
    """
    path = sql_path
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()

    statements = [s.strip() for s in raw.split(";") if s.strip()]
    with DBEngine.engine.begin() as conn:
        for stmt in statements:
            conn.execute(text(stmt))


def query(sql: str, params: dict | None = None) -> Iterator[dict]:
    """Yield each row of ``sql`` as a dict — convenience for ad-hoc queries."""
    with DBEngine.engine.connect() as conn:
        result = conn.execute(text(sql), params or {})
        for row in result.mappings():
            yield dict(row)


__all__ = ["get_engine", "test_connection", "run_script", "query"]
