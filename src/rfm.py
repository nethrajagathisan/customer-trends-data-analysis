"""RFM (Recency / Frequency / Monetary) customer segmentation.

Produces per-customer RFM metrics and an assignment to a human-readable
segment label, e.g. ``Champions`` or ``At Risk``. Numbers are computed
relative to the latest purchase in the dataset so the module has no
dependency on "today".
"""

from __future__ import annotations

from typing import Tuple

import numpy as np
import pandas as pd

# Classic, business-readable segment table based on R/F quartile codes.
# Tweak the thresholds here to fit a specific client's definition.
SEGMENT_MAP = {
    (4, 4): "Champions",
    (3, 4): "Loyal",
    (4, 3): "Potential Loyalists",
    (3, 3): "Promising",
    (4, 2): "Recent Customers",
    (2, 4): "Need Attention",
    (3, 2): "About to Sleep",
    (2, 3): "About to Sleep",
    (4, 1): "Hibernating",
    (3, 1): "Hibernating",
    (2, 2): "At Risk",
    (2, 1): "Lost",
    (1, 4): "Lost",
    (1, 3): "Lost",
    (1, 2): "Lost",
    (1, 1): "Lost",
}

# Monetary rarely drives segmentation on its own, so we keep quartile codes
# but use them for an auxiliary "monetary_tier" flag instead of the label.
MONETARY_LABELS = ["low", "medium", "high", "top"]


def compute_rfm(
    orders: pd.DataFrame,
    order_items: pd.DataFrame,
    *,
    customer_col: str = "customer_unique_id",
    order_col: str = "order_id",
    purchase_ts_col: str = "order_purchase_timestamp",
    price_col: str = "price",
) -> pd.DataFrame:
    """Compute RFM metrics per customer.

    Parameters
    ----------
    orders
        Orders table; must contain ``customer_col``, ``order_col`` and a
        purchase timestamp column.
    order_items
        Order-items table; must contain ``order_col`` and a ``price`` column.
        Freight is excluded from the monetary value.

    Returns
    -------
    DataFrame indexed by ``customer_unique_id`` with columns
    ``recency_days``, ``frequency``, ``monetary`` plus quartile codes
    ``R``, ``F``, ``M`` and a ``segment`` label.
    """
    needed_order = {customer_col, order_col, purchase_ts_col}
    missing = needed_order - set(orders.columns)
    if missing:
        raise KeyError(f"orders is missing columns: {missing}")
    if order_col not in order_items.columns or price_col not in order_items.columns:
        raise KeyError(
            f"order_items is missing '{order_col}' or '{price_col}'"
        )

    df = orders[[customer_col, order_col, purchase_ts_col]].copy()
    df[purchase_ts_col] = pd.to_datetime(df[purchase_ts_col])

    # Monetary value per order, then collapse to one row per order per customer.
    order_value = (
        order_items.groupby(order_col)[price_col].sum().rename("order_value")
    )
    df = df.merge(order_value, on=order_col, how="left")
    df["order_value"] = df["order_value"].fillna(0.0)

    snapshot_ts = df[purchase_ts_col].max()

    rfm = (
        df.groupby(customer_col)
        .agg(
            recency_days=(
                purchase_ts_col,
                lambda s: (snapshot_ts - s.max()).days,
            ),
            frequency=(order_col, "nunique"),
            monetary=("order_value", "sum"),
        )
        .reset_index()
    )

    r, f, m = _assign_quartiles(rfm)
    rfm[["R", "F", "M"]] = pd.DataFrame(
        {"R": r, "F": f, "M": m}
    )
    rfm["segment"] = [
        SEGMENT_MAP.get((int(rec), int(freq)), "Others")
        for rec, freq in zip(rfm["R"], rfm["F"])
    ]
    rfm["monetary_tier"] = [
        MONETARY_LABELS[int(c) - 1] if pd.notna(c) else "low"
        for c in rfm["M"]
    ]
    return rfm


def _assign_quartiles(rfm: pd.DataFrame) -> Tuple[pd.Series, pd.Series, pd.Series]:
    """Convert raw metrics into 1-4 quartile codes.

    Higher R/F/M is always "better", so:
      * recency  -> inverted (fewer days = higher score)
      * frequency/monetary -> ascending
    Frequency is heavily right-skewed (most customers order once), so we
    rank rather than ``qcut`` to avoid duplicate-edge errors.
    """
    n = len(rfm)
    if n == 0:
        empty = pd.Series([], dtype=int)
        return empty, empty, empty

    # Recency: smaller days = better -> reverse the labels.
    rec_bins = pd.qcut(-rfm["recency_days"], q=4, labels=[1, 2, 3, 4], duplicates="drop")
    rec = pd.Series(rec_bins.tolist() if hasattr(rec_bins, "tolist") else rec_bins)
    rec = rec.fillna(2).astype(int)

    freq = _safe_rank_codes(rfm["frequency"])
    mon = _safe_rank_codes(rfm["monetary"])
    return rec, freq, mon


def _safe_rank_codes(values: pd.Series) -> pd.Series:
    """Map values to 1-4 via rank so heavy ties (e.g. all freq=1) survive."""
    ranks = values.rank(method="first")
    # Scale ranks into [1, 4] buckets regardless of population size.
    codes = pd.cut(
        ranks,
        bins=[0, n / 4, n / 2, 3 * n / 4, np.inf],
        labels=[1, 2, 3, 4],
        include_lowest=True,
    ) if (n := len(values)) else pd.Series([], dtype=int)
    return pd.Series(codes).fillna(2).astype(int)


def segment_summary(rfm: pd.DataFrame) -> pd.DataFrame:
    """Roll up to one row per segment: count, avg R/F/M, total revenue."""
    return (
        rfm.groupby("segment")
        .agg(
            customers=(rfm.columns[0], "count"),
            avg_recency_days=("recency_days", "mean"),
            avg_frequency=("frequency", "mean"),
            avg_monetary=("monetary", "mean"),
            total_monetary=("monetary", "sum"),
        )
        .round(2)
        .sort_values("total_monetary", ascending=False)
        .reset_index()
    )


__all__ = ["SEGMENT_MAP", "compute_rfm", "segment_summary"]
