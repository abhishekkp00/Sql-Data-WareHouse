/*
===============================================================================
Additional Data Quality Checks
===============================================================================
Purpose:
    Validate that the Gold layer is logically consistent and that the fact and
    dimension tables match expected business rules.

Important notes:
    - These checks do not modify data.
    - A failing result points to a likely data quality, loading, or modeling issue.
    - The checks are based on the actual schema and business grain of this project.
===============================================================================
*/

SET NOCOUNT ON;
GO

/*
===============================================================================
1) Duplicate customer keys
What it checks:
    Finds duplicate customer_key values in gold.dim_customers.

What a failing result means:
    This suggests the dimension has duplicate surrogate keys or a broken load.
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
2) Duplicate product keys
What it checks:
    Finds duplicate product_key values in gold.dim_products.

What a failing result means:
    Product dimension records may have been loaded twice or the table was rebuilt
    without a stable key strategy.
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
3) Null values in mandatory customer and product columns
What it checks:
    Finds nulls in keys and critical business attributes.

What a failing result means:
    The dimension may be missing critical customer or product attributes.
===============================================================================
*/
SELECT 'dim_customers' AS table_name, customer_key AS missing_value
FROM gold.dim_customers
WHERE customer_key IS NULL
UNION ALL
SELECT 'dim_customers', customer_number
FROM gold.dim_customers
WHERE customer_number IS NULL
UNION ALL
SELECT 'dim_products', product_key
FROM gold.dim_products
WHERE product_key IS NULL
UNION ALL
SELECT 'dim_products', product_name
FROM gold.dim_products
WHERE product_name IS NULL;
GO

/*
===============================================================================
4) Invalid or future order dates
What it checks:
    Finds order dates that are NULL or in the future compared with the latest
    record in the fact table.

What a failing result means:
    Dates may be malformed or loaded incorrectly. This would affect time-based
    analysis and trend reporting.
===============================================================================
*/
SELECT
    f.order_number,
    f.product_key,
    f.customer_key,
    f.order_date
FROM gold.fact_sales AS f
WHERE f.order_date IS NULL
   OR f.order_date > CAST(GETDATE() AS DATE);
GO

/*
===============================================================================
5) Negative or inconsistent sales amounts
What it checks:
    Identifies negative sales amounts or rows where sales value is zero or
    inconsistent with product and order patterns.

What a failing result means:
    The fact table may contain invalid data or a load issue could have affected
    transaction values.
===============================================================================
*/
SELECT
    f.order_number,
    f.product_key,
    f.customer_key,
    f.sales_amount,
    f.quantity,
    f.price
FROM gold.fact_sales AS f
WHERE f.sales_amount < 0
   OR f.quantity < 0
   OR f.price < 0
   OR (f.sales_amount = 0 AND f.quantity > 0)
   OR (f.price = 0 AND f.quantity > 0);
GO

/*
===============================================================================
6) Orphaned customer and product references in the fact table
What it checks:
    Detects fact rows whose customer_key or product_key does not exist in the
    matching dimension table.

What a failing result means:
    The fact table contains values that do not match the dimension model, which
    breaks the star schema and can create misleading analysis.
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
7) Duplicate fact-table records based on the actual grain
What it checks:
    Detects duplicate order-product-customer combinations in the fact table.

Business rule:
    The grain of gold.fact_sales is one row per product within an order.
    So the natural duplicate check is the combination of order_number +
    product_key + customer_key.

What a failing result means:
    The fact table may have repeated records for the same business transaction.
===============================================================================
*/
SELECT
    order_number,
    product_key,
    customer_key,
    COUNT(*) AS duplicate_count
FROM gold.fact_sales
GROUP BY order_number, product_key, customer_key
HAVING COUNT(*) > 1;
GO

/*
===============================================================================
8) Row counts across Bronze, Silver, and Gold where meaningful
What it checks:
    Provides a simple comparison of counts across layers for each logical source.

What a failing result means:
    The load process may be dropping rows or not matching the expected grain.
    This is a monitoring check, not a strict pass/fail rule.
===============================================================================
*/
SELECT
    'bronze.crm_cust_info' AS layer_table,
    COUNT(*) AS row_count
FROM bronze.crm_cust_info
UNION ALL
SELECT 'silver.crm_cust_info', COUNT(*)
FROM silver.crm_cust_info
UNION ALL
SELECT 'gold.dim_customers', COUNT(*)
FROM gold.dim_customers;
GO

SELECT
    'bronze.crm_prd_info' AS layer_table,
    COUNT(*) AS row_count
FROM bronze.crm_prd_info
UNION ALL
SELECT 'silver.crm_prd_info', COUNT(*)
FROM silver.crm_prd_info
UNION ALL
SELECT 'gold.dim_products', COUNT(*)
FROM gold.dim_products;
GO

SELECT
    'bronze.crm_sales_details' AS layer_table,
    COUNT(*) AS row_count
FROM bronze.crm_sales_details
UNION ALL
SELECT 'silver.crm_sales_details', COUNT(*)
FROM silver.crm_sales_details
UNION ALL
SELECT 'gold.fact_sales', COUNT(*)
FROM gold.fact_sales;
GO
