-- ============================================================================
-- 02_kpi_views.sql
-- ----------------------------------------------------------------------------
-- Pre-aggregated PostgreSQL views that back the Power BI dashboard. Power BI
-- consumes these directly so its DAX stays trivial (SUM/AVG over a few rows)
-- and all business logic lives in one auditable place: this file.
--
-- Target schema : the star schema from 00_create_star_schema.sql
--                 (fact_order_item + dim_customer / dim_product / dim_seller /
--                  dim_date / dim_geolocation).
-- Revenue basis : SUM(payment_value) throughout -- what the customer actually
--                 paid (price + freight). This is consistent with
--                 v_kpi_overview.total_revenue below.
--
-- All views are CREATE OR REPLACE VIEW so the script is re-runnable; drop the
-- old placeholder materialized views first (they targeted a dead schema and
-- can no longer be refreshed).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Cleanup: remove the obsolete materialized views from the prior schema
-- (fact_orders / fact_order_items / dim_review / mart_rfm). Plain views below
-- replace them.
-- ----------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_kpi_summary;
DROP MATERIALIZED VIEW IF EXISTS mv_revenue_by_category;
DROP MATERIALIZED VIEW IF EXISTS mv_revenue_by_state;
DROP MATERIALIZED VIEW IF EXISTS mv_revenue_monthly;
DROP MATERIALIZED VIEW IF EXISTS mv_rfm_segments;


-- ============================================================================
-- v_kpi_overview  -- single-row KPI cards (Total orders, Revenue, AOV,
--                   Active customers, Avg review).
-- ============================================================================
CREATE OR REPLACE VIEW v_kpi_overview AS
SELECT
    COUNT(DISTINCT order_id)                                   AS total_orders,
    SUM(payment_value)                                         AS total_revenue,
    SUM(payment_value) / NULLIF(COUNT(DISTINCT order_id), 0)   AS aov,
    -- NOTE: customer_id is per-order in Olist. For a true distinct-buyer count
    -- swap this for COUNT(DISTINCT customer_unique_id) after joining dim_customer.
    COUNT(DISTINCT customer_id)                               AS active_customers,
    AVG(review_score)                                         AS avg_review_score
FROM fact_order_item;


-- ============================================================================
-- v_revenue_by_month  -- monthly trend line with month-over-month growth.
--   month_start = first of month (DATE) so Power BI has a proper date axis;
--   MoM_growth_pct uses LAG() over the year/month series.
-- ============================================================================
CREATE OR REPLACE VIEW v_revenue_by_month AS
WITH monthly AS (
    SELECT
        d.year,
        d.month,
        make_date(d.year, d.month, 1)   AS month_start,
        SUM(f.payment_value)            AS revenue,
        COUNT(DISTINCT f.order_id)      AS order_count
    FROM fact_order_item f
    JOIN dim_date         d  ON d.date_id = f.date_id
    GROUP BY
        d.year,
        d.month
)
SELECT
    year,
    month,
    month_start,
    revenue,
    order_count,
    ROUND(
        (revenue - LAG(revenue) OVER (ORDER BY year, month))
        / NULLIF(LAG(revenue) OVER (ORDER BY year, month), 0) * 100,
        2
    ) AS mom_growth_pct
FROM monthly;


-- ============================================================================
-- v_revenue_by_category  -- category bar chart with share-of-total and review.
--   pct_of_total via SUM() OVER () (window grand total inside the same SELECT).
--   avg_review is item-weighted (review_score is denormalised onto each line);
--   good enough for ranking -- see note in v_kpi_overview for the per-order
--   alternative.
-- ============================================================================
CREATE OR REPLACE VIEW v_revenue_by_category AS
SELECT
    dp.product_category_name_english                     AS category,
    SUM(f.payment_value)                                 AS revenue,
    ROUND(
        SUM(f.payment_value) * 100.0
        / NULLIF(SUM(SUM(f.payment_value)) OVER (), 0),
        2
    )                                                    AS pct_of_total,
    COUNT(DISTINCT f.order_id)                           AS order_count,
    ROUND(AVG(f.review_score), 2)                        AS avg_review
FROM fact_order_item f
JOIN dim_product      dp ON dp.product_id = f.product_id
GROUP BY
    dp.product_category_name_english;


-- ============================================================================
-- v_revenue_by_state  -- revenue by customer_state with a lat/lng centroid for
--   the map visual.
--   Two CTEs are used deliberately: revenue is aggregated fact->dim_customer,
--   and the centroid is aggregated from dim_geolocation by state, then joined.
--   Joining geolocation straight into the fact would fan out payment_value
--   (one zip prefix maps to many coordinate rows) and inflate revenue.
-- ============================================================================
CREATE OR REPLACE VIEW v_revenue_by_state AS
WITH state_revenue AS (
    SELECT
        dc.customer_state,
        SUM(f.payment_value)                      AS revenue,
        COUNT(DISTINCT f.order_id)                AS orders,
        COUNT(DISTINCT dc.customer_unique_id)     AS customers
    FROM fact_order_item f
    JOIN dim_customer     dc ON dc.customer_id = f.customer_id
    GROUP BY
        dc.customer_state
),
state_geo AS (
    SELECT
        g.geolocation_state                AS customer_state,
        AVG(g.geolocation_lat)             AS lat,
        AVG(g.geolocation_lng)             AS lng
    FROM dim_geolocation g
    WHERE g.geolocation_state IS NOT NULL
    GROUP BY
        g.geolocation_state
)
SELECT
    sr.customer_state,
    sr.revenue,
    sr.orders,
    sr.customers,
    sg.lat,
    sg.lng
FROM state_revenue sr
LEFT JOIN state_geo sg ON sg.customer_state = sr.customer_state;


-- ============================================================================
-- v_delivery_metrics  -- single-row SLA card.
--   Deduped to one row per order (DISTINCT ON order_id) first, because the
--   delivery dates are denormalised onto every line and counting lines would
--   weight multi-item orders multiple times.
-- ============================================================================
CREATE OR REPLACE VIEW v_delivery_metrics AS
WITH delivered AS (
    SELECT DISTINCT ON (order_id)
        order_id,
        date_id,
        delivered_customer_date,
        order_estimated_delivery_date
    FROM fact_order_item
    WHERE order_status             = 'delivered'
      AND delivered_customer_date IS NOT NULL
    ORDER BY
        order_id
)
SELECT
    COUNT(*) AS delivered_orders,
    ROUND(
        SUM(
            CASE WHEN delivered_customer_date <= order_estimated_delivery_date
                 THEN 1 ELSE 0 END
        ) * 100.0 / NULLIF(COUNT(*), 0),
        2
    ) AS on_time_rate,
    ROUND(AVG(delivered_customer_date - date_id), 2) AS avg_delivery_days,
    SUM(
        CASE WHEN delivered_customer_date > order_estimated_delivery_date
             THEN 1 ELSE 0 END
    ) AS late_orders_count
FROM delivered;


-- ============================================================================
-- v_payment_type_split  -- payment-method donut with share of revenue.
-- ============================================================================
CREATE OR REPLACE VIEW v_payment_type_split AS
WITH pay AS (
    SELECT
        payment_type,
        SUM(payment_value) AS revenue
    FROM fact_order_item
    WHERE payment_type IS NOT NULL
    GROUP BY
        payment_type
)
SELECT
    payment_type,
    revenue,
    ROUND(
        revenue * 100.0 / NULLIF(SUM(revenue) OVER (), 0),
        2
    ) AS pct_of_total
FROM pay;


-- ============================================================================
-- WHY VIEWS (and not raw tables / not materialised views here)?
-- ----------------------------------------------------------------------------
-- * Pre-aggregation = faster Power BI rendering. Each visual binds to a few
--   hundred rows (months, states, categories) instead of millions of order
--   lines, so the report paints near-instantly and the DirectQuery cost per
--   click is tiny.
-- * Consistent logic. Every measure (revenue basis, on-time rule, MoM growth,
--   share-of-total) is defined once in SQL. There is no second copy of the
--   business rules living as DAX that can drift from the SQL truth.
-- * Single source of truth. Analysts, ad-hoc SQL, and the dashboard all read
--   the same views, so a number on the screen always reconciles with a number
--   in a query. Fix a rule here once and every consumer sees the correction.
-- * Always current. Plain (non-materialised) views reflect the latest load
--   with no REFRESH step -- ideal while the data is still settling. If a view
--   later proves hot enough to need materialisation, swap CREATE VIEW for
--   CREATE MATERIALIZED VIEW and add a REFRESH to the load job.
-- ============================================================================
