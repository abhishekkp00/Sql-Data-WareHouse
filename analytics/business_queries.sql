/*
===============================================================================
Business Analysis Queries for the Gold Layer
===============================================================================
Purpose:
    Answer eight practical business questions using the warehouse Gold layer.
    The queries are designed to be easy to explain in interviews and to reflect
    real business decision-making.

Important business rules used in this file:
    - Revenue is measured using gold.fact_sales.sales_amount.
    - AOV is computed using order-level revenue, not line-item revenue, because
      one order can include multiple products.
    - "Recently" is defined as inactivity for more than 90 days relative to the
      latest order date in the fact table.
    - Categories are considered underperforming only when they fall below a
      reasonable comparison threshold (80% of the category average revenue).

These queries assume the Gold views already exist in the DataWarehouse database.
===============================================================================
*/

SET NOCOUNT ON;
GO

/*
===============================================================================
1) Top 10 products by total revenue
Business question:
    Which products generate the most revenue?

Logic:
    Join the sales fact table to the product dimension and aggregate sales by
    product name. This shows which products contribute most to revenue.

SQL concepts used:
    JOIN, GROUP BY, SUM, TOP, ORDER BY
===============================================================================
*/
SELECT TOP (10)
    p.product_name,
    SUM(f.sales_amount) AS total_revenue
FROM gold.fact_sales AS f
JOIN gold.dim_products AS p
    ON p.product_key = f.product_key
GROUP BY p.product_name
ORDER BY total_revenue DESC;
GO

/*
===============================================================================
2) Top 10 customers by total revenue
Business question:
    Which customers generate the most revenue?

Logic:
    Aggregate sales by customer and rank them by total revenue. This helps focus
    on valuable customers for retention and upsell activity.

SQL concepts used:
    JOIN, GROUP BY, SUM, TOP, ORDER BY
===============================================================================
*/
SELECT TOP (10)
    c.customer_key,
    c.first_name,
    c.last_name,
    SUM(f.sales_amount) AS total_revenue
FROM gold.fact_sales AS f
JOIN gold.dim_customers AS c
    ON c.customer_key = f.customer_key
GROUP BY
    c.customer_key,
    c.first_name,
    c.last_name
ORDER BY total_revenue DESC;
GO

/*
===============================================================================
3) Monthly revenue trend and month-over-month growth
Business question:
    How is revenue changing over time month by month?

Logic:
    Aggregate sales by month and compare each month with the previous month using
    LAG(). The first month has no previous month value, so it is left NULL.

SQL concepts used:
    GROUP BY, DATEADD, DATEDIFF, SUM, LAG, CASE
===============================================================================
*/
WITH monthly_revenue AS (
    SELECT
        DATEADD(MONTH, DATEDIFF(MONTH, 0, f.order_date), 0) AS month_start,
        SUM(f.sales_amount) AS monthly_revenue
    FROM gold.fact_sales AS f
    WHERE f.order_date IS NOT NULL
    GROUP BY DATEADD(MONTH, DATEDIFF(MONTH, 0, f.order_date), 0)
)
SELECT
    month_start,
    monthly_revenue,
    LAG(monthly_revenue) OVER (ORDER BY month_start) AS previous_month_revenue,
    CASE
        WHEN LAG(monthly_revenue) OVER (ORDER BY month_start) IS NULL THEN NULL
        WHEN LAG(monthly_revenue) OVER (ORDER BY month_start) = 0 THEN NULL
        ELSE (
            (monthly_revenue - LAG(monthly_revenue) OVER (ORDER BY month_start))
            * 100.0 / LAG(monthly_revenue) OVER (ORDER BY month_start)
        )
    END AS month_over_month_growth_pct
FROM monthly_revenue
ORDER BY month_start;
GO

/*
===============================================================================
4) Product category performance and underperforming categories
Business question:
    Which categories are performing well and which are underperforming?

Logic:
    Calculate revenue by category and compare each category to the average
    category revenue. Categories below 80% of the average are flagged as
    underperforming. This is a simple, practical threshold for interview
    discussions and can be adjusted if a business team defines a different rule.

SQL concepts used:
    JOIN, GROUP BY, AVG, CASE, WINDOW FUNCTION
===============================================================================
*/
WITH category_revenue AS (
    SELECT
        p.category,
        SUM(f.sales_amount) AS total_revenue
    FROM gold.fact_sales AS f
    JOIN gold.dim_products AS p
        ON p.product_key = f.product_key
    GROUP BY p.category
),
category_summary AS (
    SELECT
        category,
        total_revenue,
        AVG(total_revenue) OVER () AS avg_category_revenue
    FROM category_revenue
)
SELECT
    category,
    total_revenue,
    avg_category_revenue,
    CASE
        WHEN total_revenue < (avg_category_revenue * 0.8) THEN 'Underperforming'
        ELSE 'Healthy'
    END AS category_status,
    (total_revenue * 100.0 / avg_category_revenue) AS pct_of_average_category_revenue
FROM category_summary
ORDER BY total_revenue DESC;
GO

/*
===============================================================================
5) Average order value (AOV)
Business question:
    What is the average value of each order?

Logic:
    Because one order can include multiple products, AOV is calculated using the
    total revenue per order number, then the average of those order totals.
    This avoids overstating AOV by dividing total sales by the number of rows.

SQL concepts used:
    GROUP BY, CTE, AVG, ORDER BY
===============================================================================
*/
WITH order_revenue AS (
    SELECT
        f.order_number,
        SUM(f.sales_amount) AS order_value
    FROM gold.fact_sales AS f
    GROUP BY f.order_number
)
SELECT
    AVG(order_value) AS average_order_value
FROM order_revenue;
GO

/*
===============================================================================
6) Sales and revenue by customer region
Business question:
    Which regions generate the most sales and revenue?

Logic:
    Join customer dimension to fact sales and summarize revenue, quantity, and
    order count by country.

SQL concepts used:
    JOIN, GROUP BY, SUM, COUNT(DISTINCT), ORDER BY
===============================================================================
*/
SELECT
    c.country,
    COUNT(DISTINCT f.order_number) AS total_orders,
    SUM(f.sales_amount) AS total_revenue,
    SUM(f.quantity) AS total_quantity_sold
FROM gold.fact_sales AS f
JOIN gold.dim_customers AS c
    ON c.customer_key = f.customer_key
GROUP BY c.country
ORDER BY total_revenue DESC;
GO

/*
===============================================================================
7) Percentage of total revenue contributed by the top 10 customers
Business question:
    How much of the total revenue comes from the top 10 customers?

Logic:
    Calculate revenue per customer, rank them, and then sum the revenue of the
    top 10 customers. Divide by total company revenue to show their share.

SQL concepts used:
    JOIN, GROUP BY, SUM, RANK, OVER, CTE
===============================================================================
*/
WITH customer_revenue AS (
    SELECT
        c.customer_key,
        c.first_name,
        c.last_name,
        SUM(f.sales_amount) AS total_revenue
    FROM gold.fact_sales AS f
    JOIN gold.dim_customers AS c
        ON c.customer_key = f.customer_key
    GROUP BY
        c.customer_key,
        c.first_name,
        c.last_name
),
ranked_customers AS (
    SELECT
        customer_key,
        first_name,
        last_name,
        total_revenue,
        RANK() OVER (ORDER BY total_revenue DESC) AS revenue_rank
    FROM customer_revenue
),
total_revenue AS (
    SELECT SUM(total_revenue) AS overall_revenue
    FROM customer_revenue
)
SELECT
    SUM(r.total_revenue) AS top_10_customer_revenue,
    (SUM(r.total_revenue) * 100.0 / t.overall_revenue) AS pct_of_total_revenue
FROM ranked_customers AS r
CROSS JOIN total_revenue AS t
WHERE r.revenue_rank <= 10;
GO

/*
===============================================================================
8) Customers who have not purchased recently
Business question:
    Which customers have been inactive for a long time?

Logic:
    Compute the latest order date per customer and compare it against the latest
    order date in the fact table. The rule used here is: if a customer has not
    purchased for more than 90 days, they are treated as inactive.

This is a practical business rule, not a universal definition. In a real
business environment, the threshold can be adjusted based on product cycle time
and customer behavior.

SQL concepts used:
    GROUP BY, MAX, DATEADD, DATEDIFF, JOIN, CTE
===============================================================================
*/
WITH customer_last_purchase AS (
    SELECT
        f.customer_key,
        MAX(f.order_date) AS last_order_date
    FROM gold.fact_sales AS f
    GROUP BY f.customer_key
),
latest_system_order AS (
    SELECT MAX(order_date) AS max_order_date
    FROM gold.fact_sales
)
SELECT
    c.customer_key,
    c.first_name,
    c.last_name,
    clp.last_order_date,
    lso.max_order_date,
    DATEDIFF(DAY, clp.last_order_date, lso.max_order_date) AS days_since_last_purchase
FROM customer_last_purchase AS clp
JOIN gold.dim_customers AS c
    ON c.customer_key = clp.customer_key
CROSS JOIN latest_system_order AS lso
WHERE clp.last_order_date < DATEADD(DAY, -90, lso.max_order_date)
ORDER BY days_since_last_purchase DESC;
GO
