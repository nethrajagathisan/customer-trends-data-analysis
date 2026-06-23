# Executive Summary — Olist Customer Analytics

> Status: **scaffold**. Metrics will be filled in once the warehouse load
> (`notebooks/02_data_modeling_load.ipynb`) and RFM segmentation
> (`notebooks/03_rfm_segmentation.ipynb`) have been run end-to-end.

## Objective

Turn raw Olist e-commerce transactions into a maintainable analytics stack:
cleaned data → star schema in Postgres → KPI views → Power BI dashboard and
RFM customer segmentation.

## Pipeline overview

| Stage            | Artifact                                              |
| ---------------- | ----------------------------------------------------- |
| Raw data         | `data/raw/*.csv` (gitignored)                         |
| Cleaned data     | `data/processed/*.parquet`                            |
| Source code      | `src/` — config, db, data_loader, rfm                 |
| Data modeling    | `sql/00_create_star_schema.sql` → Postgres star schema |
| Analytics marts  | `sql/02_kpi_views.sql` → materialised views           |
| Segmentation     | `src/rfm.py` + `notebooks/03_rfm_segmentation.ipynb`  |
| Reporting        | `dashboards/customer_behavior_dashboard.pbix`         |

## Key metrics _(to be populated)_

| Metric                  | Value | Period |
| ----------------------- | ----- | ------ |
| Total revenue           | TBD   |        |
| Total orders            | TBD   |        |
| Average order value     | TBD   |        |
| Average review score    | TBD   |        |
| On-time delivery rate   | TBD   |        |
| % revenue from top tier | TBD   |        |

## Customer segmentation highlights _(to be populated)_

| Segment     | Customers | Revenue | Avg recency (days) |
| ----------- | --------- | ------- | ------------------ |
| Champions   | TBD       | TBD     | TBD                |
| Loyal       | TBD       | TBD     | TBD                |
| At Risk     | TBD       | TBD     | TBD                |
| Lost        | TBD       | TBD     | TBD                |

## Recommended actions _(to be populated)_

- **Champions / Loyal** — reward programme, early access to launches.
- **At Risk** — targeted win-back with time-limited offers.
- **Lost / Hibernating** — suppress from active marketing; low-cost reactivation only.

## Reproducing

```bash
python -m venv .venv && . .venv/Scripts/activate   # Windows
pip install -r requirements.txt
cp .env.example .env          # then edit credentials
# place Olist CSVs in data/raw/
jupyter lab notebooks/        # run 01 → 02 → 03
```
