-- 01_advanced_queries.sql
-- ----------------------------------------------------------------------------
-- Advanced analytical queries over the star schema. Each block is
-- self-contained; copy/paste into your BI tool or run via src.db.run_script.
-- ----------------------------------------------------------------------------

-- 1. Monthly revenue trend with WoW growth -----------------------------------
WITH monthly AS (
    SELECT
        d.year,
        d.month,
        SUM(foi.price) AS revenue
    FROM fact_order_items foi
    JOIN fact_orders  fo ON foi.order_id = fo.order_id
    JOIN dim_date     d  ON fo.order_purchase_date_key = d.date_key
    GROUP BY d.year, d.month
)
SELECT
    year,
    month,
    revenue,
    LAG(revenue) OVER (ORDER BY year, month) AS prev_month_revenue,
    ROUND(
        (revenue - LAG(revenue) OVER (ORDER BY year, month))
        / NULLIF(LAG(revenue) OVER (ORDER BY year, month), 0) * 100,
        2
    ) AS mom_growth_pct
FROM monthly
ORDER BY year, month;

-- 2. Top-10 product categories by revenue ------------------------------------
SELECT
    dp.product_category_name_en AS category,
    SUM(foi.price)               AS revenue,
    COUNT(*)                     AS items_sold,
    ROUND(AVG(foi.price), 2)     AS avg_price
FROM fact_order_items foi
JOIN dim_product dp ON foi.product_sk = dp.product_sk
GROUP BY dp.product_category_name_en
ORDER BY revenue DESC
LIMIT 10;

-- 3. Delivery performance vs promise (on-time / late) ------------------------
SELECT
    CASE
        WHEN order_delivered_ts <= order_estimated_delivery_ts THEN 'on_time'
        ELSE 'late'
    END AS delivery_status,
    COUNT(*) AS n_orders,
    ROUND(AVG(order_delivered_ts - order_purchase_ts), 2) AS avg_lead_time_days
FROM fact_orders
WHERE order_status = 'delivered'
GROUP BY 1;

-- 4. Review-score distribution ------------------------------------------------
SELECT
    review_score,
    COUNT(*) AS n_reviews,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM dim_review
GROUP BY review_score
ORDER BY review_score DESC;
