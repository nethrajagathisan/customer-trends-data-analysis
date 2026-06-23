-- 00_create_star_schema.sql
-- ----------------------------------------------------------------------------
-- Build the dimensional (star) schema on top of the raw Olist tables.
-- Run order: 00 -> 01 -> 02. Re-runnable: uses DROP ... IF EXISTS.
--
-- Fact tables:  fact_orders, fact_order_items
-- Dim tables :  dim_customer, dim_product, dim_seller, dim_geolocation,
--               dim_date, dim_review
-- ----------------------------------------------------------------------------

BEGIN;

-- Dimension: dates ------------------------------------------------------------
DROP TABLE IF EXISTS dim_date CASCADE;
CREATE TABLE dim_date (
    date_key       DATE PRIMARY KEY,
    day            SMALLINT,
    month          SMALLINT,
    quarter        SMALLINT,
    year           SMALLINT,
    day_of_week    SMALLINT,
    is_weekend     BOOLEAN
);

-- Dimension: customers --------------------------------------------------------
DROP TABLE IF EXISTS dim_customer CASCADE;
CREATE TABLE dim_customer (
    customer_sk          BIGSERIAL PRIMARY KEY,
    customer_id          TEXT UNIQUE,       -- per-order id (olist)
    customer_unique_id   TEXT,              -- true customer (deduped)
    customer_zip_code    TEXT,
    customer_city        TEXT,
    customer_state       TEXT
);

-- Dimension: products ---------------------------------------------------------
DROP TABLE IF EXISTS dim_product CASCADE;
CREATE TABLE dim_product (
    product_sk               BIGSERIAL PRIMARY KEY,
    product_id               TEXT UNIQUE,
    product_category_name    TEXT,
    product_category_name_en TEXT,
    product_weight_g         NUMERIC(12,2),
    product_length_cm        NUMERIC(6,2),
    product_height_cm        NUMERIC(6,2),
    product_width_cm         NUMERIC(6,2)
);

-- Dimension: sellers ----------------------------------------------------------
DROP TABLE IF EXISTS dim_seller CASCADE;
CREATE TABLE dim_seller (
    seller_sk           BIGSERIAL PRIMARY KEY,
    seller_id           TEXT UNIQUE,
    seller_zip_code     TEXT,
    seller_city         TEXT,
    seller_state        TEXT
);

-- Dimension: geolocation ------------------------------------------------------
DROP TABLE IF EXISTS dim_geolocation CASCADE;
CREATE TABLE dim_geolocation (
    geolocation_sk     BIGSERIAL PRIMARY KEY,
    geolocation_zip    TEXT,
    geolocation_lat    NUMERIC(10,6),
    geolocation_lng    NUMERIC(10,6),
    geolocation_city   TEXT,
    geolocation_state  TEXT,
    UNIQUE (geolocation_zip, geolocation_lat, geolocation_lng)
);

-- Dimension: reviews ----------------------------------------------------------
DROP TABLE IF EXISTS dim_review CASCADE;
CREATE TABLE dim_review (
    review_sk         BIGSERIAL PRIMARY KEY,
    review_id         TEXT UNIQUE,
    review_score      SMALLINT,
    review_comment    BOOLEAN  -- TRUE if a written comment was left
);

-- Fact: orders (grain = one row per order) ------------------------------------
DROP TABLE IF EXISTS fact_orders CASCADE;
CREATE TABLE fact_orders (
    order_sk                BIGSERIAL PRIMARY KEY,
    order_id                TEXT UNIQUE,
    customer_sk             BIGINT REFERENCES dim_customer(customer_sk),
    order_purchase_date_key DATE REFERENCES dim_date(date_key),
    order_status            TEXT,
    order_purchase_ts       TIMESTAMP,
    order_delivered_ts      TIMESTAMP,
    order_estimated_delivery_ts TIMESTAMP
);

-- Fact: order items (grain = one row per order item) -------------------------
DROP TABLE IF EXISTS fact_order_items CASCADE;
CREATE TABLE fact_order_items (
    order_item_sk      BIGSERIAL PRIMARY KEY,
    order_id           TEXT,
    order_item_id      INTEGER,
    product_sk         BIGINT REFERENCES dim_product(product_sk),
    seller_sk          BIGINT REFERENCES dim_seller(product_sk),
    price              NUMERIC(12,2),
    freight_value      NUMERIC(12,2),
    review_sk          BIGINT REFERENCES dim_review(review_sk)
);

-- Indexes that every dashboard query will lean on -----------------------------
CREATE INDEX idx_fact_orders_customer ON fact_orders(customer_sk);
CREATE INDEX idx_fact_orders_date     ON fact_orders(order_purchase_date_key);
CREATE INDEX idx_fact_items_product   ON fact_order_items(product_sk);
CREATE INDEX idx_fact_items_seller    ON fact_order_items(seller_sk);

COMMIT;
