-- 00_create_star_schema.sql
-- ----------------------------------------------------------------------------
-- Build the dimensional (star) schema on top of the raw Olist tables.
-- Re-runnable: wraps everything in a transaction and uses DROP ... IF EXISTS.
--
-- Design notes
--   * Natural business keys (TEXT) are used as dimension PRIMARY KEYs instead
--     of BIGSERIAL surrogates. This keeps the model readable, lets ETL load
--     dimensions and facts directly from source IDs, and makes point-lookups
--     by customer_id / product_id / seller_id trivial.
--   * One fact table, fact_order_item, at the grain of a single order line
--     (order_id + order_item_id). Order-level attributes (payments, review
--     score, delivery dates, status) are denormalised onto each line so a
--     single join set powers revenue, satisfaction, and SLA analytics.
--   * DROP order is reverse dependency (fact first, then dims) so the
--     REFERENCES constraints never block a reload; CREATE order is forward
--     dependency (dims first, fact last) so the FK targets already exist.
--
-- Tables
--   Dimensions : dim_customer, dim_product, dim_seller, dim_date,
--                dim_geolocation
--   Fact       : fact_order_item
-- ----------------------------------------------------------------------------
BEGIN;

-- ============================================================================
-- DROP (reverse dependency: fact first, then dimensions)
-- ============================================================================
DROP TABLE IF EXISTS fact_order_item;
DROP TABLE IF EXISTS dim_geolocation;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_seller;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_customer;

-- ============================================================================
-- DIMENSIONS (created in forward dependency order)
-- ============================================================================

-- dim_customer ----------------------------------------------------------------
-- Grain: one row per customer_id. In Olist, customer_id is a per-order
-- identifier; customer_unique_id is the true (deduped) customer and lets us
-- count distinct buyers and compute repeat-purchase / RFM metrics.
CREATE TABLE dim_customer (
    customer_id              TEXT PRIMARY KEY,   -- per-order identifier from Olist
    customer_unique_id       TEXT,               -- true customer (one unique_id can span many order_ids)
    customer_zip_code_prefix TEXT,
    customer_city            TEXT,
    customer_state           TEXT
);

-- dim_product -----------------------------------------------------------------
-- Grain: one row per product_id. Category is already joined to the English
-- translation during ETL so analysts never need to look up the mapping.
-- product_volume_cm3 is derived (length * height * width) via a STORED
-- generated column, so it can never drift out of sync with its inputs and
-- is available for shipping-cost / density analysis without recomputation.
CREATE TABLE dim_product (
    product_id                     TEXT PRIMARY KEY,
    product_category_name_english  TEXT,          -- already joined with translation
    product_name_length            INT,
    product_description_length     INT,
    product_photos_qty             INT,
    product_weight_g               DOUBLE PRECISION,
    product_length_cm              NUMERIC,
    product_height_cm              NUMERIC,
    product_width_cm               NUMERIC,
    product_volume_cm3             NUMERIC         -- computed: L*H*W
        GENERATED ALWAYS AS (product_length_cm * product_height_cm * product_width_cm) STORED
);

-- dim_seller ------------------------------------------------------------------
-- Grain: one row per seller_id. Mirrors dim_customer so customer-vs-seller
-- geography (freight distance, regional concentration) is symmetric.
CREATE TABLE dim_seller (
    seller_id                TEXT PRIMARY KEY,
    seller_zip_code_prefix   TEXT,
    seller_city              TEXT,
    seller_state             TEXT
);

-- dim_date --------------------------------------------------------------------
-- Grain: one row per calendar day (date_id = the order's purchase date).
-- Pre-exploded calendar columns let every dashboard group/slice by day,
-- week, month, quarter, or year without date functions in the query.
CREATE TABLE dim_date (
    date_id        DATE PRIMARY KEY,              -- = order date
    day            INT,
    month          INT,
    quarter        INT,
    year           INT,
    day_of_week    TEXT,
    is_weekend     BOOLEAN,
    month_name     TEXT
);

-- dim_geolocation -------------------------------------------------------------
-- Grain: one row per (zip prefix, lat, lng) tuple. Olist ships multiple
-- coordinate points per zip prefix; this composite key preserves them all.
-- The ETL step aggregates/dedupes raw geolocation rows in Python before load.
CREATE TABLE dim_geolocation (
    geolocation_zip_code_prefix TEXT,
    geolocation_lat             DOUBLE PRECISION,
    geolocation_lng             DOUBLE PRECISION,
    geolocation_city            TEXT,
    geolocation_state           TEXT,
    PRIMARY KEY (geolocation_zip_code_prefix, geolocation_lat, geolocation_lng)  -- aggregated later in Python
);

-- ============================================================================
-- FACT (created last, after all FK targets exist)
-- ============================================================================

-- fact_order_item -------------------------------------------------------------
-- Grain: one row per order line (order_id, order_item_id).
-- Every order-level measure is denormalised onto the line:
--   * payment_*     -> aggregated up from order_payments (one payment type /
--                      installments value per order, chosen during ETL)
--   * review_score  -> the order's review score, enabling satisfaction-per-revenue
--   * *_delivery_*  -> actual vs estimated delivery dates for SLA / on-time analysis
-- FKs use the dimensions' natural TEXT keys for direct, index-backed joins.
CREATE TABLE fact_order_item (
    order_item_pk                  BIGSERIAL PRIMARY KEY,
    order_id                       TEXT NOT NULL,
    order_item_id                  INT,
    customer_id                    TEXT REFERENCES dim_customer(customer_id),
    product_id                     TEXT REFERENCES dim_product(product_id),
    seller_id                      TEXT REFERENCES dim_seller(seller_id),
    date_id                        DATE REFERENCES dim_date(date_id),    -- purchase date
    price                          NUMERIC,
    freight_value                  NUMERIC,
    payment_value                  NUMERIC,                              -- aggregated from order_payments
    payment_type                   TEXT,
    payment_installments           INT,
    review_score                   INT,
    order_status                   TEXT,
    delivered_customer_date        DATE,
    order_estimated_delivery_date  DATE
);

-- ============================================================================
-- INDEXES
-- One index per foreign key so dimension joins are index-backed, plus an
-- index on order_id for order-level rollups (e.g. order count, AOV) that
-- GROUP BY order_id without joining a dimension.
-- ============================================================================
CREATE INDEX idx_fact_order_item_customer_id ON fact_order_item(customer_id);
CREATE INDEX idx_fact_order_item_product_id  ON fact_order_item(product_id);
CREATE INDEX idx_fact_order_item_seller_id   ON fact_order_item(seller_id);
CREATE INDEX idx_fact_order_item_date_id     ON fact_order_item(date_id);
CREATE INDEX idx_fact_order_item_order_id    ON fact_order_item(order_id);

COMMIT;
