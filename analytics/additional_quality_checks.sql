/*
===============================================================================
Additional Data Quality Checks (Gold layer + cross-layer row counts)
===============================================================================
Purpose:
    Validate that the Gold layer is logically consistent and that the fact and
    dimension tables match the project's business rules.

How to read the results:
    - These checks are read-only. Nothing is inserted, updated, or deleted.
    - FAIL-type checks (1, 2, 3, 4b, 5, 6, 7): the query should return ZERO rows.
      Any returned row points to a data quality, loading, or modeling issue.
    - INFO-type checks (4a, 8): the result is for review only. A non-zero
      count is not automatically an error; the comment explains how to interpret it.

Fact table grain (confirmed from Warehouse/scripts/gold/ddl_gold.sql):
    gold.fact_sales = one row per product within an order
    (order_number + product_key). One order can have several rows.

Note:
    Existing checks in Warehouse/tests/ cover Bronze/Silver cleaning rules.
    This file adds Gold-level business-rule and cross-layer checks.
===============================================================================
*/

SET NOCOUNT ON;
GO

/*
===============================================================================
1) [FAIL-type] Duplicate customer keys in gold.dim_customers
Expected: 0 rows.
Meaning of a failure: the surrogate key is not unique, so joins from the fact
table would duplicate sales rows.
===============================================================================
*/
SELECT
    customer_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_customers
GROUP BY customer_key
HAVING COUNT(*) > 1;
GO

/*
===============================================================================
2) [FAIL-type] Duplicate product keys in gold.dim_products
Expected: 0 rows.
Meaning of a failure: the surrogate key is not unique, so joins from the fact
table would duplicate sales rows.
===============================================================================
*/
SELECT
    product_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_products
GROUP BY product_key
HAVING COUNT(*) > 1;
GO

/*
===============================================================================
3) [FAIL-type] NULLs in mandatory dimension columns
Expected: 0 rows.
Mandatory columns: customer_key, customer_number, product_key, product_name.
All values are cast to NVARCHAR so the UNION ALL has one consistent data type
(mixing INT and text columns in a UNION would cause a conversion error).
Note: category and country are NOT treated as mandatory because the source
mapping can legitimately be missing; the business queries handle them.
===============================================================================
*/
SELECT 'dim_customers' AS table_name, 'customer_key' AS column_name,
       CAST(customer_number AS NVARCHAR(50)) AS reference_value
FROM gold.dim_customers
WHERE customer_key IS NULL
UNION ALL
SELECT 'dim_customers', 'customer_number', CAST(customer_key AS NVARCHAR(50))
FROM gold.dim_customers
WHERE customer_number IS NULL
UNION ALL
SELECT 'dim_products', 'product_key', CAST(product_number AS NVARCHAR(50))
FROM gold.dim_products
WHERE product_key IS NULL
UNION ALL
SELECT 'dim_products', 'product_name', CAST(product_key AS NVARCHAR(50))
FROM gold.dim_products
WHERE product_name IS NULL;
GO

/*
===============================================================================
4a) [INFO-type] Fact rows with a NULL order_date
Silver converts invalid source dates to NULL instead of dropping the row.
These rows still count towards revenue totals but cannot be placed in a month.
Review the count; decide with the business whether they need source correction.
===============================================================================
*/
SELECT
    COUNT(*)            AS rows_with_null_order_date,
    SUM(sales_amount)   AS revenue_without_order_date
FROM gold.fact_sales
WHERE order_date IS NULL;
GO

/*
===============================================================================
4b) [FAIL-type] Impossible dates
Expected: 0 rows.
Rows where the order date is in the future, or where shipping/due dates come
before the order date.
===============================================================================
*/
SELECT
    order_number,
    product_key,
    customer_key,
    order_date,
    shipping_date,
    due_date
FROM gold.fact_sales
WHERE order_date > CAST(GETDATE() AS DATE)
   OR shipping_date < order_date
   OR due_date < order_date;
GO

/*
===============================================================================
5) [FAIL-type] Negative, zero, or inconsistent sales values
Expected: 0 rows.
Business rule (enforced in the Silver load): sales_amount = quantity * price,
and all three must be positive.
===============================================================================
*/
SELECT
    order_number,
    product_key,
    customer_key,
    sales_amount,
    quantity,
    price
FROM gold.fact_sales
WHERE sales_amount <= 0
   OR quantity     <= 0
   OR price        <= 0
   OR sales_amount <> quantity * price;
GO

/*
===============================================================================
6) [FAIL-type] Orphaned or missing dimension references in the fact table
Expected: 0 rows.
gold.fact_sales uses LEFT JOINs to the dimensions, so a sale whose product or
customer was not found keeps its row but gets a NULL key. NULL keys and keys
that do not exist in the dimension both break the star schema.
===============================================================================
*/
SELECT
    f.order_number,
    f.customer_key,
    f.product_key
FROM gold.fact_sales AS f
LEFT JOIN gold.dim_customers AS c
    ON c.customer_key = f.customer_key
LEFT JOIN gold.dim_products AS p
    ON p.product_key = f.product_key
WHERE c.customer_key IS NULL
   OR p.product_key IS NULL;
GO

/*
===============================================================================
7) [FAIL-type] Duplicate fact rows at the actual grain
Expected: 0 rows.
Grain = one row per product within an order (order_number + product_key).
The same product appearing twice in one order, or one order belonging to two
customers, would indicate a duplicated or inconsistent load.
Note: the same customer or product appearing in many orders is normal and is
NOT checked here.
===============================================================================
*/
SELECT
    order_number,
    product_key,
    COUNT(*)                     AS row_count,
    COUNT(DISTINCT customer_key) AS distinct_customers
FROM gold.fact_sales
GROUP BY order_number, product_key
HAVING COUNT(*) > 1
    OR COUNT(DISTINCT customer_key) > 1;
GO

/*
===============================================================================
8) [INFO-type] Row counts across Bronze, Silver, and Gold
This is a monitoring check, not strict pass/fail, because row counts are
EXPECTED to change between layers:
    - crm_cust_info : Silver removes duplicate customer records (keeps latest).
    - crm_prd_info  : Silver keeps product history; Gold keeps only current
                      products (prd_end_dt IS NULL), so Gold < Silver.
    - crm_sales_details: Silver normally keeps all rows; Gold fact_sales is a
                      view with LEFT JOINs, so Gold should equal Silver.
Investigate only when a change cannot be explained by these rules.
===============================================================================
*/
SELECT 'bronze.crm_cust_info' AS layer_table, COUNT(*) AS row_count FROM bronze.crm_cust_info
UNION ALL
SELECT 'silver.crm_cust_info', COUNT(*) FROM silver.crm_cust_info
UNION ALL
SELECT 'gold.dim_customers', COUNT(*) FROM gold.dim_customers;
GO

SELECT 'bronze.crm_prd_info' AS layer_table, COUNT(*) AS row_count FROM bronze.crm_prd_info
UNION ALL
SELECT 'silver.crm_prd_info', COUNT(*) FROM silver.crm_prd_info
UNION ALL
SELECT 'gold.dim_products', COUNT(*) FROM gold.dim_products;
GO

SELECT 'bronze.crm_sales_details' AS layer_table, COUNT(*) AS row_count FROM bronze.crm_sales_details
UNION ALL
SELECT 'silver.crm_sales_details', COUNT(*) FROM silver.crm_sales_details
UNION ALL
SELECT 'gold.fact_sales', COUNT(*) FROM gold.fact_sales;
GO
