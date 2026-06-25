-- ============================================================================
-- 01_advanced_queries.sql
-- ----------------------------------------------------------------------------
-- 15 interview-grade analytical queries over the star schema defined in
-- 00_create_star_schema.sql (one fact_order_item at order-line grain + natural
-- key dimensions: dim_customer, dim_product, dim_seller, dim_date,
-- dim_geolocation).
--
-- Each query is self-contained: copy any block into psql / your BI tool.
-- Conventions used throughout:
--   * Table aliases : f = fact_order_item, dc/dp/ds/d = dimensions
--   * Revenue       : SUM(price)            (price is the order-line value)
--   * Spend / cash  : SUM(payment_value)    (what the customer actually paid)
--   * True customer : dim_customer.customer_unique_id
--                     (customer_id is per-order in Olist, so never aggregate
--                      buyers by customer_id alone)
--
-- ----------------------------------------------------------------------------
-- SQL TECHNIQUES DEMONSTRATED  (query -> technique)
-- ----------------------------------------------------------------------------
--  Q1  Aggregation + JOIN (fact -> dim_product)
--  Q2  Aggregation + JOIN (fact -> dim_customer)
--  Q3  Window functions: SUM() OVER running 3-month total + LAG() MoM % growth
--  Q4  Window functions: ROW_NUMBER() OVER (PARTITION BY ...)
--  Q5  Ranking: DENSE_RANK() OVER (ORDER BY ...)
--  Q6  Ranking: PERCENT_RANK() + NTILE(10) deciles
--  Q7  Cohort analysis: chained CTEs (first_order -> active_month -> index)
--  Q8  RFM scoring: NTILE(5) on Recency / Frequency / Monetary + string concat
--  Q9  SLA / delivery analytics: conditional aggregation (on-time rate)
--  Q10 Delivery analytics: AVG(delivered - purchase) by category
--  Q11 Payment analytics: window SUM() OVER () for % of total
--  Q12 Payment analytics: AVG(installments) by review_score
--  Q13 Seasonality: month-of-year rollup across all years
--  Q14 Seasonality + ranking: best category per year/quarter (CTE + ROW_NUMBER)
--  Q15 Advanced: CTE + self-aggregate + PERCENTILE_CONT WITHIN GROUP (median, p90)
-- ============================================================================


-- ============================================================================
-- AGGREGATION + JOIN
-- ============================================================================

/* Q1: Top 10 product categories by total revenue */
SELECT
    dp.product_category_name_english AS category,
    SUM(f.price)                     AS total_revenue,
    ROUND(AVG(f.price), 2)           AS avg_item_price,
    COUNT(*)                         AS items_sold
FROM fact_order_item f
JOIN dim_product     dp ON dp.product_id = f.product_id
GROUP BY
    dp.product_category_name_english
ORDER BY
    total_revenue DESC
LIMIT 10;


/* Q2: Revenue by customer_state */
SELECT
    dc.customer_state,
    SUM(f.price)                                AS total_revenue,
    COUNT(DISTINCT f.order_id)                  AS n_orders,
    COUNT(DISTINCT dc.customer_unique_id)       AS n_customers
FROM fact_order_item f
JOIN dim_customer     dc ON dc.customer_id = f.customer_id
GROUP BY
    dc.customer_state
ORDER BY
    total_revenue DESC;


-- ============================================================================
-- WINDOW FUNCTIONS: running total + MoM growth
-- ============================================================================

/* Q3: Monthly revenue with a running 3-month total and MoM % growth
   Techniques: SUM() OVER (... ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
               LAG() over the monthly series. */
WITH monthly AS (
    SELECT
        d.year,
        d.month,
        SUM(f.price) AS revenue
    FROM fact_order_item f
    JOIN dim_date         d  ON d.date_id = f.date_id
    GROUP BY
        d.year,
        d.month
)
SELECT
    year,
    month,
    ROUND(revenue, 2) AS revenue,
    ROUND(
        SUM(revenue) OVER (
            ORDER BY year, month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ), 2
    ) AS running_3mo_total,
    ROUND(
        LAG(revenue) OVER (ORDER BY year, month), 2
    ) AS prev_month_revenue,
    ROUND(
        (revenue - LAG(revenue) OVER (ORDER BY year, month))
        / NULLIF(LAG(revenue) OVER (ORDER BY year, month), 0) * 100,
        2
    ) AS mom_growth_pct
FROM monthly
ORDER BY
    year,
    month;


/* Q4: Top 3 products per category by revenue
   Technique: ROW_NUMBER() OVER (PARTITION BY category ORDER BY revenue DESC). */
WITH product_revenue AS (
    SELECT
        dp.product_category_name_english AS category,
        f.product_id,
        SUM(f.price) AS revenue
    FROM fact_order_item f
    JOIN dim_product     dp ON dp.product_id = f.product_id
    GROUP BY
        dp.product_category_name_english,
        f.product_id
),
ranked AS (
    SELECT
        category,
        product_id,
        revenue,
        ROW_NUMBER() OVER (
            PARTITION BY category
            ORDER BY revenue DESC
        ) AS product_rank
    FROM product_revenue
)
SELECT
    category,
    product_id,
    ROUND(revenue, 2) AS revenue,
    product_rank
FROM ranked
WHERE product_rank <= 3
ORDER BY
    category,
    product_rank;


-- ============================================================================
-- RANKING
-- ============================================================================

/* Q5: Top 5 customers by total spend
   Technique: DENSE_RANK() OVER (ORDER BY total_spend DESC).
   Spend = payment_value aggregated to the true customer (customer_unique_id). */
WITH customer_spend AS (
    SELECT
        dc.customer_unique_id,
        SUM(f.payment_value)            AS total_spend,
        COUNT(DISTINCT f.order_id)      AS n_orders
    FROM fact_order_item f
    JOIN dim_customer     dc ON dc.customer_id = f.customer_id
    GROUP BY
        dc.customer_unique_id
),
ranked AS (
    SELECT
        customer_unique_id,
        total_spend,
        n_orders,
        DENSE_RANK() OVER (ORDER BY total_spend DESC) AS spend_rank
    FROM customer_spend
)
SELECT
    customer_unique_id,
    ROUND(total_spend, 2) AS total_spend,
    n_orders,
    spend_rank
FROM ranked
WHERE spend_rank <= 5
ORDER BY
    spend_rank;


/* Q6: Products in the top 10% by revenue
   Techniques: PERCENT_RANK() and NTILE(10). Both are shown so you can cross-
   check: PERCENT_RANK() >= 0.90 should land in decile 10. */
WITH product_revenue AS (
    SELECT
        f.product_id,
        SUM(f.price) AS revenue
    FROM fact_order_item f
    GROUP BY
        f.product_id
),
bucketed AS (
    SELECT
        product_id,
        revenue,
        PERCENT_RANK() OVER (ORDER BY revenue ASC) AS pct_rank,
        NTILE(10)        OVER (ORDER BY revenue ASC) AS decile
    FROM product_revenue
)
SELECT
    product_id,
    ROUND(revenue, 2)        AS revenue,
    ROUND(pct_rank * 100, 2) AS percentile,
    decile
FROM bucketed
WHERE pct_rank >= 0.90           -- top decile (top 10%) by revenue
ORDER BY
    revenue DESC;


-- ============================================================================
-- COHORT ANALYSIS  (retention matrix)
-- ----------------------------------------------------------------------------
-- NOTE: must join dim_customer.customer_unique_id, because customer_id is a
-- per-order key in Olist. Counting distinct customer_id would treat every
-- order as a "new customer" and destroy the cohort.
-- ============================================================================

/* Q7: Cohort retention matrix
   CTE 1  first_order    -> first purchase month per true customer (cohort_month)
   CTE 2  active_month   -> each month a customer was active (placed any order)
   CTE 3  cohort_index   -> months elapsed between cohort_month and activity_month
   CTE 4  cohort_size    -> size of each cohort (denominator for retention)
   Final  -> cohort_month, cohort_index, active_customers, cohort_size, retention */
WITH first_order AS (
    SELECT
        dc.customer_unique_id,
        MIN(make_date(d.year, d.month, 1)) AS cohort_month
    FROM fact_order_item f
    JOIN dim_customer     dc ON dc.customer_id = f.customer_id
    JOIN dim_date         d  ON d.date_id      = f.date_id
    GROUP BY
        dc.customer_unique_id
),
active_month AS (
    SELECT DISTINCT
        dc.customer_unique_id,
        make_date(d.year, d.month, 1) AS activity_month
    FROM fact_order_item f
    JOIN dim_customer     dc ON dc.customer_id = f.customer_id
    JOIN dim_date         d  ON d.date_id      = f.date_id
),
cohort_index AS (
    SELECT
        fo.cohort_month,
        am.activity_month,
        ( (EXTRACT(YEAR  FROM am.activity_month) - EXTRACT(YEAR  FROM fo.cohort_month)) * 12
        + (EXTRACT(MONTH FROM am.activity_month) - EXTRACT(MONTH FROM fo.cohort_month))
        )::INT                                AS cohort_index,
        fo.customer_unique_id
    FROM first_order  fo
    JOIN active_month am ON am.customer_unique_id = fo.customer_unique_id
),
cohort_size AS (
    SELECT
        cohort_month,
        COUNT(*) AS cohort_size
    FROM first_order
    GROUP BY
        cohort_month
)
SELECT
    ci.cohort_month,
    ci.cohort_index,
    COUNT(DISTINCT ci.customer_unique_id)             AS active_customers,
    cs.cohort_size,
    ROUND(
        COUNT(DISTINCT ci.customer_unique_id) * 100.0 / NULLIF(cs.cohort_size, 0),
        2
    )                                                 AS retention_rate_pct
FROM cohort_index ci
JOIN cohort_size  cs ON cs.cohort_month = ci.cohort_month
GROUP BY
    ci.cohort_month,
    ci.cohort_index,
    cs.cohort_size
ORDER BY
    ci.cohort_month,
    ci.cohort_index;


-- ============================================================================
-- RFM IN SQL  (Recency / Frequency / Monetary)
-- ----------------------------------------------------------------------------
-- Snapshot date = latest purchase in the fact (so the model is re-runnable and
-- never depends on a hard-coded "today"). Each metric is bucketed into 5 with
-- NTILE(5), oriented so 5 is always best:
--   R_score: ORDER BY recency_days DESC (fewest days since last order -> 5)
--   F_score: ORDER BY frequency    ASC (most orders                  -> 5)
--   M_score: ORDER BY monetary     ASC (highest spend                -> 5)
-- RFM_cell concatenates them (e.g. '555' = champion).
-- ============================================================================

/* Q8: RFM scoring with NTILE(5) */
WITH snapshot AS (
    SELECT MAX(date_id) AS snapshot_date
    FROM fact_order_item
),
rfm_raw AS (
    SELECT
        dc.customer_unique_id,
        (s.snapshot_date - MAX(f.date_id))   AS recency_days,
        COUNT(DISTINCT f.order_id)           AS frequency,
        SUM(f.payment_value)                 AS monetary
    FROM fact_order_item f
    JOIN dim_customer     dc ON dc.customer_id = f.customer_id
    CROSS JOIN snapshot   s
    GROUP BY
        dc.customer_unique_id,
        s.snapshot_date
),
scored AS (
    SELECT
        customer_unique_id,
        recency_days,
        frequency,
        monetary,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(5) OVER (ORDER BY frequency    ASC)  AS f_score,
        NTILE(5) OVER (ORDER BY monetary     ASC)  AS m_score
    FROM rfm_raw
)
SELECT
    customer_unique_id,
    recency_days,
    frequency,
    ROUND(monetary, 2)            AS monetary,
    r_score,
    f_score,
    m_score,
    CONCAT(r_score, f_score, m_score) AS rfm_cell
FROM scored
ORDER BY
    monetary DESC;


-- ============================================================================
-- DELIVERY ANALYTICS
-- ============================================================================

/* Q9: On-time delivery rate by seller_state
   On-time = delivered_customer_date <= order_estimated_delivery_date. */
SELECT
    ds.seller_state,
    COUNT(*) AS n_deliveries,
    SUM(
        CASE WHEN f.delivered_customer_date <= f.order_estimated_delivery_date
             THEN 1 ELSE 0 END
    ) AS n_on_time,
    ROUND(
        SUM(
            CASE WHEN f.delivered_customer_date <= f.order_estimated_delivery_date
                 THEN 1 ELSE 0 END
        ) * 100.0 / NULLIF(COUNT(*), 0),
        2
    ) AS on_time_delivery_pct
FROM fact_order_item f
JOIN dim_seller         ds ON ds.seller_id = f.seller_id
WHERE f.order_status             = 'delivered'
  AND f.delivered_customer_date IS NOT NULL
GROUP BY
    ds.seller_state
ORDER BY
    on_time_delivery_pct DESC;


/* Q10: Average delivery time by product category
   Delivery time = delivered_customer_date - date_id (purchase date), in days. */
SELECT
    dp.product_category_name_english AS category,
    COUNT(*)                         AS n_items,
    ROUND(AVG(f.delivered_customer_date - f.date_id), 2) AS avg_delivery_days
FROM fact_order_item f
JOIN dim_product     dp ON dp.product_id = f.product_id
WHERE f.order_status             = 'delivered'
  AND f.delivered_customer_date IS NOT NULL
GROUP BY
    dp.product_category_name_english
ORDER BY
    avg_delivery_days DESC;


-- ============================================================================
-- PAYMENT ANALYTICS
-- ============================================================================

/* Q11: Revenue split by payment_type with % of total
   Technique: SUM() OVER () to get the grand total inside the same SELECT. */
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
    ROUND(revenue, 2)                                   AS revenue,
    ROUND(revenue * 100.0 / SUM(revenue) OVER (), 2)    AS pct_of_revenue
FROM pay
ORDER BY
    revenue DESC;


/* Q12: Average payment_installments by review_score
   Do customers who pay in more installments leave different reviews? */
SELECT
    review_score,
    COUNT(*)                              AS n_items,
    ROUND(AVG(payment_installments), 2)   AS avg_installments,
    ROUND(AVG(payment_value), 2)          AS avg_payment_value
FROM fact_order_item
WHERE review_score IS NOT NULL
GROUP BY
    review_score
ORDER BY
    review_score;


-- ============================================================================
-- SEASONALITY
-- ============================================================================

/* Q13: Revenue by month-of-year across all years (seasonality detector)
   Collapses every year into months 1-12; avg_revenue_per_year reveals whether
   a month is consistently high/low rather than just big once. */
WITH monthly AS (
    SELECT
        d.year,
        d.month,
        d.month_name,
        SUM(f.price) AS revenue
    FROM fact_order_item f
    JOIN dim_date         d  ON d.date_id = f.date_id
    GROUP BY
        d.year,
        d.month,
        d.month_name
)
SELECT
    month,
    month_name,
    COUNT(*)                       AS n_years_with_sales,
    ROUND(SUM(revenue), 2)         AS total_revenue,
    ROUND(AVG(revenue), 2)         AS avg_revenue_per_year
FROM monthly
GROUP BY
    month,
    month_name
ORDER BY
    month;


/* Q14: Best-selling category per season/quarter
   CTE ranks categories within each (year, quarter) and keeps the #1. */
WITH cat_quarter AS (
    SELECT
        d.year,
        d.quarter,
        dp.product_category_name_english AS category,
        SUM(f.price)                     AS revenue
    FROM fact_order_item f
    JOIN dim_date         d  ON d.date_id   = f.date_id
    JOIN dim_product      dp ON dp.product_id = f.product_id
    GROUP BY
        d.year,
        d.quarter,
        dp.product_category_name_english
),
ranked AS (
    SELECT
        year,
        quarter,
        category,
        revenue,
        ROW_NUMBER() OVER (
            PARTITION BY year, quarter
            ORDER BY revenue DESC
        ) AS rn
    FROM cat_quarter
)
SELECT
    year,
    quarter,
    category,
    ROUND(revenue, 2) AS revenue
FROM ranked
WHERE rn = 1
ORDER BY
    year,
    quarter;


-- ============================================================================
-- ADVANCED: CTE + SELF-AGGREGATE + PERCENTILE_CONT
-- ============================================================================

/* Q15: Median order value by state, plus the 90th percentile (p90)
   CTE 1  order_value  -> one row per order with its total value (order-line
                         prices summed up to order grain) + the customer's state
   Final  -> PERCENTILE_CONT(0.5) and (0.9) WITHIN GROUP (ORDER BY order_value)
   Mean (AVG) hides skew; median + p90 show the real distribution per state. */
WITH order_value AS (
    SELECT
        dc.customer_state,
        f.order_id,
        SUM(f.price) AS order_value
    FROM fact_order_item f
    JOIN dim_customer     dc ON dc.customer_id = f.customer_id
    GROUP BY
        dc.customer_state,
        f.order_id
)
SELECT
    customer_state,
    COUNT(*)                                                        AS n_orders,
    ROUND(AVG(order_value), 2)                                      AS mean_order_value,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY order_value), 2)
                                                                     AS median_order_value,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY order_value), 2)
                                                                     AS p90_order_value
FROM order_value
GROUP BY
    customer_state
ORDER BY
    median_order_value DESC;
