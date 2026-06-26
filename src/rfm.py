"""RFM (Recency / Frequency / Monetary) customer segmentation.

Computes per-customer RFM metrics from a merged fact+dimension DataFrame
(fact_order_item ⋈ dim_customer), scores each metric 1-5, assigns a
business segment label, and produces a rollup summary for reporting and
Power BI.

Typical usage::

    from src.rfm import compute_rfm, score_rfm, assign_segment, segment_summary

    # fact_df: JOIN of fact_order_item and dim_customer from PostgreSQL
    rfm = compute_rfm(fact_df)
    rfm = score_rfm(rfm)
    rfm["segment"] = rfm.apply(assign_segment, axis=1)
    summary = segment_summary(rfm)
"""

from __future__ import annotations

import logging
from typing import Optional

import pandas as pd

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Segment definitions (R_score × F_score → label, 1-5 scale)
# ---------------------------------------------------------------------------
# Standard business rules; overlapping ranges resolved by priority:
#   Champions        R=5,   F=5
#   Loyal            R=4-5, F=4-5
#   At Risk          R=2-3, F=4-5   (takes (3,4) over Potential Loyalist)
#   Can't Lose Them  R=1-2, F=5     ((2,5) goes here, not At Risk)
#   Potential Loyalist R=3-4, F=1-4
#   Hibernating      R=1-2, F=1-3
#   Lost             R=1,   F=1     (overrides Hibernating for (1,1))
#
# Cells not covered by these rules ((5,1-3) and (1,4)) return "Others".
SEGMENT_MAP: dict[tuple[int, int], str] = {
    (5, 5): "Champions",
    # Loyal (R=4-5, F=4-5)
    (5, 4): "Loyal",
    (4, 5): "Loyal",
    (4, 4): "Loyal",
    # At Risk (R=2-3, F=4-5)
    (3, 5): "At Risk",
    (3, 4): "At Risk",
    (2, 4): "At Risk",
    # Can't Lose Them (R=1-2, F=5) — (2,5) here rather than At Risk
    (2, 5): "Can't Lose Them",
    (1, 5): "Can't Lose Them",
    # Potential Loyalist (R=3-4, F=1-4)
    (4, 3): "Potential Loyalist",
    (4, 2): "Potential Loyalist",
    (4, 1): "Potential Loyalist",
    (3, 3): "Potential Loyalist",
    (3, 2): "Potential Loyalist",
    (3, 1): "Potential Loyalist",
    # Hibernating (R=1-2, F=1-3)
    (2, 3): "Hibernating",
    (2, 2): "Hibernating",
    (2, 1): "Hibernating",
    (1, 3): "Hibernating",
    (1, 2): "Hibernating",
    # Lost (R=1, F=1) — explicit override of Hibernating
    (1, 1): "Lost",
}


def assign_segment(row: pd.Series) -> str:
    """Return the business segment name for a scored customer row.

    Looks up ``(R_score, F_score)`` in :data:`SEGMENT_MAP`. Cells not covered
    by the standard rules (e.g. very-recent one-time buyers with R=5, F=1-3)
    return ``"Others"``.

    Parameters
    ----------
    row
        A row from the scored RFM DataFrame containing at minimum ``R_score``
        and ``F_score`` (integer 1-5).
    """
    return SEGMENT_MAP.get((int(row["R_score"]), int(row["F_score"])), "Others")


# ---------------------------------------------------------------------------
# Core pipeline
# ---------------------------------------------------------------------------

def compute_rfm(
    fact_df: pd.DataFrame,
    snapshot_date: Optional[pd.Timestamp] = None,
    *,
    customer_col: str = "customer_unique_id",
    order_col: str = "order_id",
    date_col: str = "date_id",
    monetary_col: str = "payment_value",
) -> pd.DataFrame:
    """Compute raw RFM metrics per unique customer.

    Parameters
    ----------
    fact_df
        Merged DataFrame containing at minimum *customer_col*, *order_col*,
        *date_col* (purchase date or timestamp), and *monetary_col* (payment
        value per order). Typically the result of::

            SELECT f.order_id, f.date_id, f.payment_value,
                   dc.customer_unique_id
            FROM fact_order_item f
            JOIN dim_customer dc ON f.customer_id = dc.customer_id

        If *fact_df* is at item grain (multiple rows per order),
        ``compute_rfm`` collapses to order level automatically: ``date_col``
        is taken as the max per order and ``monetary_col`` as the first value
        (``payment_value`` is an order-level total replicated on every item row).
    snapshot_date
        Reference date for recency. Defaults to ``max(date_col)`` in the data
        so the module produces consistent results regardless of when it runs.

    Returns
    -------
    DataFrame with columns: ``customer_unique_id``, ``recency`` (integer days
    since last order), ``frequency`` (distinct order count), ``monetary``
    (sum of *monetary_col* across all orders).
    """
    required = {customer_col, order_col, date_col, monetary_col}
    missing = required - set(fact_df.columns)
    if missing:
        raise KeyError(f"fact_df is missing columns: {sorted(missing)}")

    df = fact_df[[customer_col, order_col, date_col, monetary_col]].copy()
    df[date_col] = pd.to_datetime(df[date_col])

    # Collapse item-grain rows to order level so payment_value isn't double-counted.
    n_before = len(df)
    df = (
        df.groupby([customer_col, order_col], sort=False)
        .agg({date_col: "max", monetary_col: "first"})
        .reset_index()
    )
    if len(df) < n_before:
        logger.info(
            "Collapsed %d item-level rows → %d order-level rows",
            n_before, len(df),
        )

    snap = pd.Timestamp(snapshot_date) if snapshot_date is not None else df[date_col].max()
    logger.info("Snapshot date for recency: %s", snap.date())

    rfm = (
        df.groupby(customer_col, sort=False)
        .agg(
            recency=(date_col, lambda s: (snap - s.max()).days),
            frequency=(order_col, "nunique"),
            monetary=(monetary_col, "sum"),
        )
        .reset_index()
    )

    logger.info(
        "RFM computed: %d customers | recency %d–%d days | "
        "frequency %d–%d orders | monetary $%.0f–$%.0f",
        len(rfm),
        rfm["recency"].min(), rfm["recency"].max(),
        rfm["frequency"].min(), rfm["frequency"].max(),
        rfm["monetary"].min(), rfm["monetary"].max(),
    )
    return rfm


def score_rfm(rfm_df: pd.DataFrame, q: int = 5) -> pd.DataFrame:
    """Add ``R_score``, ``F_score``, ``M_score`` (integers 1–*q*) to the RFM table.

    Scoring conventions:
    * **Recency** — fewer days since last order is better → higher score.
    * **Frequency** — more distinct orders is better → higher score.
      Uses rank-based bucketing (``method='first'``) so the heavy tie at
      ``frequency == 1`` (the majority of Olist customers) is spread evenly
      across bins rather than collapsing into one bucket.
    * **Monetary** — higher total spend is better → higher score.

    Parameters
    ----------
    rfm_df
        Output of :func:`compute_rfm`.
    q
        Number of score levels (default 5, yielding scores 1-5).

    Returns
    -------
    Copy of *rfm_df* with integer columns ``R_score``, ``F_score``,
    ``M_score`` appended.
    """
    df = rfm_df.copy()
    labels = list(range(1, q + 1))
    mid = labels[len(labels) // 2]

    def _rank_score(series: pd.Series, ascending: bool) -> pd.Series:
        """Rank then qcut, returning integer scores 1-q."""
        ranks = series.rank(method="first", ascending=ascending)
        codes = pd.qcut(ranks, q=q, labels=labels, duplicates="drop")
        return pd.to_numeric(codes, errors="coerce").fillna(mid).astype(int)

    # Fewer recency days = better → ascending=False gives small days a high rank.
    df["R_score"] = _rank_score(df["recency"], ascending=False)
    df["F_score"] = _rank_score(df["frequency"], ascending=True)
    df["M_score"] = _rank_score(df["monetary"], ascending=True)

    logger.info(
        "Score distributions — R: %s | F: %s | M: %s",
        df["R_score"].value_counts().sort_index().to_dict(),
        df["F_score"].value_counts().sort_index().to_dict(),
        df["M_score"].value_counts().sort_index().to_dict(),
    )
    return df


def segment_summary(rfm_df: pd.DataFrame) -> pd.DataFrame:
    """Roll up the scored + segmented RFM table to one row per segment.

    Parameters
    ----------
    rfm_df
        Output of :func:`score_rfm` with a ``segment`` column added via
        ``rfm_df["segment"] = rfm_df.apply(assign_segment, axis=1)``.

    Returns
    -------
    DataFrame with columns ``segment``, ``count``, ``pct_customers``,
    ``total_monetary``, ``pct_revenue``, ``avg_recency``, ``avg_frequency``,
    sorted by ``total_monetary`` descending.
    """
    total_customers = len(rfm_df)
    total_monetary = rfm_df["monetary"].sum()

    agg = (
        rfm_df.groupby("segment", as_index=False)
        .agg(
            count=("customer_unique_id", "count"),
            total_monetary=("monetary", "sum"),
            avg_recency=("recency", "mean"),
            avg_frequency=("frequency", "mean"),
        )
    )

    agg["pct_customers"] = (agg["count"] / total_customers * 100).round(1)
    agg["pct_revenue"] = (agg["total_monetary"] / total_monetary * 100).round(1)
    agg["avg_recency"] = agg["avg_recency"].round(1)
    agg["avg_frequency"] = agg["avg_frequency"].round(2)
    agg["total_monetary"] = agg["total_monetary"].round(2)

    cols = [
        "segment", "count", "pct_customers",
        "total_monetary", "pct_revenue",
        "avg_recency", "avg_frequency",
    ]
    return (
        agg[cols]
        .sort_values("total_monetary", ascending=False)
        .reset_index(drop=True)
    )


__all__ = [
    "SEGMENT_MAP",
    "assign_segment",
    "compute_rfm",
    "score_rfm",
    "segment_summary",
]
