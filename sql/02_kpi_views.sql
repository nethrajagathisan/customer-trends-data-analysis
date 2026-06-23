-- 02_kpi_views.sql
-- ----------------------------------------------------------------------------
-- Materialised views backing the Power BI dashboard's KPI cards and trends.
-- Refresh after each load with:  REFRESH MATERIALIZED VIEW <name>;
-- ----------------------------------------------------------------------------

-- Overall KPIs (one row) -----------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_kpi_summary;
CREATE MATERIALIZED VIEW mv_kpi_summary AS
SELECT
    COUNT(DISTINCT fo.order_id)            AS total_orders,
    COUNT(DISTINCT fo.customer_sk)         AS total_customers,
    SUM(foi.price)                         AS total_revenue,
    ROUND(AVG(foi.price), 2)               AS avg_order_value,
    ROUND(AVG(dr.review_score), 2)         AS avg_review_score
FROM fact_orders fo
JOIN fact_order_items foi ON foi.order_id = fo.order_id
LEFT JOIN dim_review dr   ON dr.review_id = fo.order_id;

-- Revenue by category (bar chart) -------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_revenue_by_category;
CREATE MATERIALIZED VIEW mv_revenue_by_category AS
SELECT
    dp.product_category_name_en AS category,
    SUM(foi.price)              AS revenue,
    COUNT(*)                    AS items_sold
FROM fact_order_items foi
JOIN dim_product dp ON foi.product_sk = dp.product_sk
GROUP BY dp.product_category_name_en;

-- Revenue by state (map) -----------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_revenue_by_state;
CREATE MATERIALIZED VIEW mv_revenue_by_state AS
SELECT
    dc.customer_state,
    SUM(foi.price) AS revenue,
    COUNT(DISTINCT fo.order_id) AS n_orders
FROM fact_orders fo
JOIN fact_order_items foi ON foi.order_id = fo.order_id
JOIN dim_customer dc      ON dc.customer_sk = fo.customer_sk
GROUP BY dc.customer_state;

-- Monthly trend (line chart) -------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_revenue_monthly;
CREATE MATERIALIZED VIEW mv_revenue_monthly AS
SELECT
    d.year,
    d.month,
    SUM(foi.price) AS revenue,
    COUNT(DISTINCT fo.order_id) AS n_orders
FROM fact_order_items foi
JOIN fact_orders fo ON foi.order_id = fo.order_id
JOIN dim_date     d ON fo.order_purchase_date_key = d.date_key
GROUP BY d.year, d.month;

-- RFM segment counts (donut) -------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_rfm_segments;
CREATE MATERIALIZED VIEW mv_rfm_segments AS
SELECT
    segment,
    COUNT(*)              AS customers,
    SUM(monetary)         AS revenue,
    ROUND(AVG(recency_days), 1) AS avg_recency_days
FROM mart_rfm
GROUP BY segment;
