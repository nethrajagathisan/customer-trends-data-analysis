# KPI Definitions — Olist Customer & Revenue Analytics

Authoritative definitions for every KPI shown in the Power BI dashboard and the
SQL materialized views in `sql/02_kpi_views.sql`. Each KPI lists: the formula,
its business meaning, the source table(s), the Power BI DAX measure, and a
ready-to-paste **resume framing** line.

> **Revenue basis note.** The KPI list below uses `payment_value` (the amount a
> customer actually paid) as the revenue measure, per the spec. Note the
> project's dimensional model (`sql/00_create_star_schema.sql`) does **not**
> include a payments fact; `fact_order_items` holds item-level `price` and
> `freight_value`. The existing materialized view `mv_kpi_summary` therefore
> computes revenue as `SUM(price)`. The two are reconcilable: item
> `price + freight_value` summed per order equals `payment_value` for most
> orders. For a payment-faithful figure, source these measures from the raw
> `olist_order_payments_dataset` (a `fact_payments` table is the clean fix).

---

## 1. Total Revenue

| Field | Value |
|---|---|
| **Formula** | `SUM(payment_value)` over all payment rows |
| **Business meaning** | Gross cash collected from customers (items + freight + installments). The top-line health number for the business. |
| **Source table(s)** | `olist_order_payments_dataset` (`payment_value`, `order_id`). Star-schema equivalent would be a `fact_payments` table; today `fact_order_items.price` (+ `freight_value`) is the proxy. |
| **SQL** | `SELECT SUM(payment_value) AS total_revenue FROM olist_order_payments_dataset;` |
| **DAX** | `Total Revenue = SUM ( olist_order_payments[payment_value] )` |
| **Resume framing** | *Defined and instrumented a Total Revenue KPI (SUM of payment_value) as the executive top-line metric, feeding the headline scorecard and monthly trend across the Olist analytics dashboard.* |

---

## 2. Total Orders

| Field | Value |
|---|---|
| **Formula** | `COUNT(DISTINCT order_id)` |
| **Business meaning** | Number of unique orders placed — measures transaction volume independent of basket size. |
| **Source table(s)** | `olist_orders_dataset` (`order_id`); also present in `fact_orders`. |
| **SQL** | `SELECT COUNT(DISTINCT order_id) AS total_orders FROM olist_orders_dataset;` |
| **DAX** | `Total Orders = DISTINCTCOUNT ( olist_orders[order_id] )` |
| **Resume framing** | *Built a Total Orders measure (DISTINCTCOUNT of order_id) to track transaction volume and underpin derived conversion and basket-size KPIs.* |

---

## 3. Average Order Value (AOV)

| Field | Value |
|---|---|
| **Formula** | `Total Revenue / Total Orders` |
| **Business meaning** | Mean revenue per order — shows whether growth is driven by more orders or larger baskets. |
| **Source table(s)** | `olist_order_payments_dataset` (numerator) ÷ `olist_orders_dataset` (denominator). |
| **SQL** | `SELECT SUM(payment_value) / NULLIF(COUNT(DISTINCT o.order_id), 0) AS aov FROM olist_order_payments_dataset p JOIN olist_orders_dataset o USING (order_id);` |
| **DAX** | `AOV = DIVIDE ( [Total Revenue], [Total Orders], 0 )` |
| **Resume framing** | *Engineered an Average Order Value KPI (revenue ÷ distinct orders) using DIVIDE for divide-by-zero safety, surfacing basket-size trends that informed category and pricing strategy.* |
| **Watch-out** | The current `mv_kpi_summary` computes `AVG(price)` — that is **average item price**, not AOV. Use `SUM(revenue)/COUNT(DISTINCT order_id)` instead. |

---

## 4. Active Customers

| Field | Value |
|---|---|
| **Formula** | `COUNT(DISTINCT customer_unique_id)` |
| **Business meaning** | Count of real (deduped) individuals who placed at least one order. `customer_id` is per-order in Olist; `customer_unique_id` is the true person. |
| **Source table(s)** | `olist_customers_dataset` (`customer_unique_id`); reachable via `fact_orders` → `dim_customer`. |
| **SQL** | `SELECT COUNT(DISTINCT customer_unique_id) AS active_customers FROM olist_customers_dataset;` |
| **DAX** | `Active Customers = DISTINCTCOUNT ( dim_customer[customer_unique_id] )` |
| **Resume framing** | *Defined the Active Customers KPI using `customer_unique_id` (deduped across Olist's per-order customer keys) to report a true person-level customer base.* |

---

## 5. Repeat Purchase Rate

| Field | Value |
|---|---|
| **Formula** | `customers with > 1 order / total customers` |
| **Business meaning** | Share of customers who returned to buy again — a core loyalty / retention signal and a leading indicator of CLV. |
| **Source table(s)** | `olist_customers_dataset` + `olist_orders_dataset` (grouped by `customer_unique_id`). Frequency is also produced in `mart_rfm` (`src/rfm.py`) as the `frequency` column. |
| **SQL** | `SELECT COUNT(*) FILTER (WHERE order_cnt > 1) * 100.0 / COUNT(*) AS repeat_rate_pct FROM (SELECT customer_unique_id, COUNT(DISTINCT order_id) AS order_cnt FROM olist_customers_dataset c JOIN olist_orders_dataset o USING (customer_id) GROUP BY 1) t;` |
| **DAX** | `Repeat Purchase Rate = VAR RepeatCust = CALCULATE ( DISTINCTCOUNT ( dim_customer[customer_unique_id] ), FILTER ( ADDCOLUMNS ( VALUES ( dim_customer[customer_unique_id] ), "Orders", CALCULATE ( DISTINCTCOUNT ( fact_orders[order_id] ) ) ), [Orders] > 1 ) ) RETURN DIVIDE ( RepeatCust, [Active Customers], 0 )` |
| **Resume framing** | *Quantified Repeat Purchase Rate (repeat customers ÷ total customers) by collapsing Olist's per-order keys to unique individuals, feeding the retention story alongside the RFM segmentation.* |

---

## 6. Average Review Score

| Field | Value |
|---|---|
| **Formula** | `AVG(review_score)` (scores 1–5) |
| **Business meaning** | Mean customer satisfaction across post-purchase reviews — the leading quality / experience indicator. |
| **Source table(s)** | `olist_order_reviews_dataset` (`review_score`, `order_id`); `dim_review` in the star schema. |
| **SQL** | `SELECT ROUND(AVG(review_score), 2) AS avg_review_score FROM olist_order_reviews_dataset;` |
| **DAX** | `Avg Review Score = AVERAGE ( olist_order_reviews[review_score] )` |
| **Resume framing** | *Tracked Average Review Score (AVG of 1–5 review_score) as the customer-experience KPI, joining review data to orders to correlate satisfaction with delivery performance.* |

---

## 7. On-Time Delivery Rate

| Field | Value |
|---|---|
| **Formula** | `orders delivered by the estimated date / total delivered orders` |
| **Business meaning** | Percentage of orders arriving on or before the promised delivery date — the core logistics/SLA metric. |
| **Source table(s)** | `olist_orders_dataset` (`order_delivered_customer_date`, `order_estimated_delivery_date`, `order_status`); `fact_orders` (`order_delivered_ts`, `order_estimated_delivery_ts`). |
| **SQL** | `SELECT COUNT(*) FILTER (WHERE order_delivered_customer_date <= order_estimated_delivery_date) * 100.0 / NULLIF(COUNT(*) FILTER (WHERE order_status = 'delivered'), 0) AS on_time_pct FROM olist_orders_dataset;` |
| **DAX** | `On-Time Delivery Rate = VAR Delivered = CALCULATE ( COUNTROWS ( fact_orders ), fact_orders[order_status] = "delivered" ) VAR OnTime = CALCULATE ( COUNTROWS ( fact_orders ), fact_orders[order_status] = "delivered", fact_orders[order_delivered_ts] <= fact_orders[order_estimated_delivery_ts] ) RETURN DIVIDE ( OnTime, Delivered, 0 )` |
| **Resume framing** | *Measured On-Time Delivery Rate (orders delivered ≤ estimated date ÷ delivered orders) to quantify SLA performance and expose logistics risk for operations.* |

---

## 8. Average Delivery Time (days)

| Field | Value |
|---|---|
| **Formula** | `AVG(order_delivered_customer_date − order_purchase_timestamp)` expressed in days |
| **Business meaning** | Mean lead time from purchase to doorstep — operational efficiency and a direct driver of review scores. |
| **Source table(s)** | `olist_orders_dataset` (`order_delivered_customer_date`, `order_purchase_timestamp`); `fact_orders` (`order_delivered_ts`, `order_purchase_ts`). |
| **SQL** | `SELECT ROUND(AVG(order_delivered_customer_date - order_purchase_timestamp), 2) AS avg_delivery_days FROM olist_orders_dataset WHERE order_status = 'delivered';` |
| **DAX** | `Avg Delivery Time (days) = AVERAGE ( DATEDIFF ( fact_orders[order_purchase_ts], fact_orders[order_delivered_ts], DAY ) )` |
| **Resume framing** | *Computed Average Delivery Time (delivery − purchase date) to benchmark fulfillment speed and isolate its correlation with review-score declines.* |

---

## 9. Category Revenue Mix

| Field | Value |
|---|---|
| **Formula** | `revenue per category / total revenue` |
| **Business meaning** | Each category's share of total revenue — reveals concentration risk and where to invest marketing/inventory. |
| **Source table(s)** | `olist_order_payments_dataset` (revenue) joined to `olist_order_items_dataset` → `olist_products_dataset` (`product_category_name`, English via `product_category_name_translation`); `mv_revenue_by_category` / `dim_product` in the star schema. |
| **SQL** | `WITH cat AS (SELECT dp.product_category_name_en AS category, SUM(foi.price) AS revenue FROM fact_order_items foi JOIN dim_product dp ON foi.product_sk = dp.product_sk GROUP BY 1) SELECT category, revenue, ROUND(revenue * 100.0 / SUM(revenue) OVER (), 2) AS mix_pct FROM cat ORDER BY mix_pct DESC;` |
| **DAX** | `Category Revenue Mix % = DIVIDE ( CALCULATE ( [Total Revenue], dim_product[product_category_name_en] ), [Total Revenue], 0 )` |
| **Resume framing** | *Built a Category Revenue Mix view (category revenue ÷ total revenue) that surfaced the top categories and concentration risk, guiding merchandising and inventory decisions.* |

---

## 10. Time-series / rolling KPIs

### 10a. Monthly Active Customers

| Field | Value |
|---|---|
| **Formula** | `COUNT(DISTINCT customer_unique_id)` for orders placed in the given calendar month |
| **Business meaning** | Distinct customers transacting each month — the heartbeat of product engagement. |
| **Source table(s)** | `olist_orders_dataset` + `olist_customers_dataset`, sliced by month of `order_purchase_timestamp`; `fact_orders` (purchase date) → `dim_customer`; month bucket from `dim_date`. |
| **SQL** | `SELECT DATE_TRUNC('month', o.order_purchase_timestamp) AS month, COUNT(DISTINCT c.customer_unique_id) AS mac FROM olist_orders_dataset o JOIN olist_customers_dataset c USING (customer_id) GROUP BY 1 ORDER BY 1;` |
| **DAX** | `Monthly Active Customers = CALCULATE ( DISTINCTCOUNT ( dim_customer[customer_unique_id] ), dim_date[year], dim_date[month] )` |
| **Resume framing** | *Created a Monthly Active Customers time series (distinct unique customers per month) to visualize engagement momentum alongside revenue trends.* |

### 10b. MoM Revenue Growth %

| Field | Value |
|---|---|
| **Formula** | `(current-month revenue − prior-month revenue) / prior-month revenue × 100` |
| **Business meaning** | Month-over-month momentum of revenue — the standard growth-rate headline. |
| **Source table(s)** | `olist_order_payments_dataset` joined to `olist_orders_dataset` (purchase month); also available via `mv_revenue_monthly` and the pattern in `sql/01_advanced_queries.sql` (uses `LAG … OVER`). |
| **SQL** | `WITH monthly AS (SELECT DATE_TRUNC('month', o.order_purchase_timestamp) AS month, SUM(p.payment_value) AS revenue FROM olist_orders_dataset o JOIN olist_order_payments_dataset p USING (order_id) GROUP BY 1) SELECT month, revenue, ROUND((revenue - LAG(revenue) OVER (ORDER BY month)) / NULLIF(LAG(revenue) OVER (ORDER BY month), 0) * 100, 2) AS mom_growth_pct FROM monthly;` |
| **DAX** | `MoM Revenue Growth % = VAR Curr = [Total Revenue] VAR Prev = CALCULATE ( [Total Revenue], DATEADD ( dim_date[date_key], -1, MONTH ) ) RETURN DIVIDE ( Curr - Prev, Prev, 0 )` |
| **Resume framing** | *Implemented MoM Revenue Growth % using window functions in SQL and `DATEADD`-based DAX, providing the headline growth indicator on the executive dashboard.* |

### 10c. 30-Day Rolling Revenue

| Field | Value |
|---|---|
| **Formula** | `SUM(payment_value)` over the trailing 30-day window ending on each date |
| **Business meaning** | Smoothed, lag-free revenue trend that dampens day-of-week noise and tracks momentum in real time. |
| **Source table(s)** | `olist_order_payments_dataset` + `olist_orders_dataset` (purchase date); `fact_orders` → `dim_date` in the star schema. |
| **SQL** | `SELECT d.date_key AS d, SUM(SUM(p.payment_value)) OVER (ORDER BY d.date_key RANGE BETWEEN INTERVAL '29 days' PRECEDING AND CURRENT ROW) AS rolling_30d_revenue FROM dim_date d LEFT JOIN fact_orders fo ON fo.order_purchase_date_key = d.date_key LEFT JOIN olist_order_payments_dataset p ON p.order_id = fo.order_id GROUP BY d.date_key ORDER BY d.date_key;` |
| **DAX** | `30-Day Rolling Revenue = CALCULATE ( [Total Revenue], DATESINPERIOD ( dim_date[date_key], MAX ( dim_date[date_key] ), -30, DAY ) )` |
| **Resume framing** | *Engineered a 30-day rolling revenue measure with a `RANGE` window in SQL and `DATESINPERIOD` in DAX to give leadership a smoothed, low-noise view of revenue momentum.* |

---

## Source-to-KPI matrix (quick reference)

| KPI | Primary source table(s) | Grain |
|---|---|---|
| Total Revenue | `olist_order_payments_dataset` | payment row |
| Total Orders | `olist_orders_dataset` | order |
| AOV | payments ÷ orders | order |
| Active Customers | `olist_customers_dataset` | unique customer |
| Repeat Purchase Rate | customers + orders | unique customer |
| Average Review Score | `olist_order_reviews_dataset` | review |
| On-Time Delivery Rate | `olist_orders_dataset` | delivered order |
| Average Delivery Time | `olist_orders_dataset` | delivered order |
| Category Revenue Mix | payments + items + products | category |
| MAC / MoM / Rolling | payments + orders + date | month / day |
