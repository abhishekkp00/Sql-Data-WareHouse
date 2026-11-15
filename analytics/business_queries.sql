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
    - Grain of gold.fact_sales: one row per product within an order.
    - Products are grouped by product_key (not product_name) so two different
      products that share a name are never merged.
    - AOV is computed using order-level revenue, not line-item revenue, because
      one order can include multiple products.
    - "Recently" is defined as inactivity for more than 90 days relative to the
      latest order date in the fact table (not today's date).
    - A category is "Underperforming" when its share of total revenue is below
      50% of an equal share (equal share = 100% / number of categories).
      Comparing with the average category revenue is avoided because one very
      large category inflates the average and makes almost everything look weak.
      The 50% rule is a business assumption and can be changed below.
    - Customers with no purchases do not appear in revenue queries (they are
      excluded by the INNER JOIN from the fact table). Query 8 only covers
      customers who have at least one dated order.
    - Some fact rows can have a NULL order_date (invalid source dates are
      cleaned to NULL in Silver). They are included in revenue totals but are
      excluded from time-based queries (3 and 8).

These queries assume the Gold views already exist in the DataWarehouse database.
They only read data; nothing is modified.
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
    product_key. This shows which products contribute most to revenue.

SQL concepts used:
    JOIN, GROUP BY, SUM, TOP, ORDER BY
===============================================================================
*/
SELECT TOP (10)
    p.product_key,
    p.product_name,
    SUM(f.sales_amount) AS total_revenue
FROM gold.fact_sales AS f
JOIN gold.dim_products AS p
    ON p.product_key = f.product_key
GROUP BY p.product_key, p.product_name
ORDER BY total_revenue DESC, p.product_key;
GO

/*
===============================================================================
2) Top 10 customers by total revenue
Business question:
    Which customers generate the most revenue?

Logic:
    Aggregate sales by customer and rank them by total revenue. This helps focus
    on valuable customers for retention and upsell activity.
    customer_key is used as a tie-breaker so the result is always exactly 10
    rows and is the same every time the query runs (two customers can have
    identical revenue).

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
ORDER BY total_revenue DESC, c.customer_key;
GO

/*
===============================================================================
3) Monthly revenue trend and month-over-month growth
Business question:
    How is revenue changing over time month by month?

Logic:
    Aggregate sales by month and compare each month with the previous month using
    LAG(). The first month has no previous month value, so it is left NULL.
    NULLIF avoids division by zero. Rows with a NULL order_date are excluded.
    Note: the first and last months of the data are usually partial months, so
    their growth percentages should be read with care.

SQL concepts used:
    GROUP BY, DATEADD, DATEDIFF, SUM, LAG, NULLIF, CTE
===============================================================================
*/
WITH monthly_revenue AS (
    SELECT
        DATEADD(MONTH, DATEDIFF(MONTH, 0, f.order_date), 0) AS month_start,
        SUM(f.sales_amount) AS monthly_revenue
    FROM gold.fact_sales AS f
    WHERE f.order_date IS NOT NULL
    GROUP BY DATEADD(MONTH, DATEDIFF(MONTH, 0, f.order_date), 0)
),
monthly_with_previous AS (
    SELECT
        month_start,
        monthly_revenue,
        LAG(monthly_revenue) OVER (ORDER BY month_start) AS previous_month_revenue
    FROM monthly_revenue
)
SELECT
    month_start,
    monthly_revenue,
    previous_month_revenue,
    (monthly_revenue - previous_month_revenue) * 100.0
        / NULLIF(previous_month_revenue, 0) AS month_over_month_growth_pct
FROM monthly_with_previous
ORDER BY month_start;
GO

/*
===============================================================================
4) Product category performance and underperforming categories
Business question:
    Which categories are performing well and which are underperforming?

Logic:
    Calculate revenue by category and each category's share of total revenue.
    The share is compared with an equal share (100% / number of categories).
    A category is flagged when its share is below 50% of the equal share.
    Business assumption: 50% is a simple starting rule that a business team can
    change by editing @underperformance_factor. Products without a category
    are grouped as 'Unknown' so no revenue is lost.

SQL concepts used:
    JOIN, GROUP BY, COALESCE, CASE, WINDOW FUNCTION (SUM OVER, COUNT OVER)
===============================================================================
*/
DECLARE @underperformance_factor DECIMAL(4, 2) = 0.50;

WITH category_revenue AS (
    SELECT
        COALESCE(p.category, 'Unknown') AS category,
        SUM(f.sales_amount) AS total_revenue
    FROM gold.fact_sales AS f
    JOIN gold.dim_products AS p
        ON p.product_key = f.product_key
    GROUP BY COALESCE(p.category, 'Unknown')
),
category_summary AS (
    SELECT
        category,
        total_revenue,
        total_revenue * 100.0 / SUM(total_revenue) OVER () AS pct_of_total_revenue,
        100.0 / COUNT(*) OVER ()                           AS equal_share_pct
    FROM category_revenue
)
SELECT
    category,
    total_revenue,
    pct_of_total_revenue,
    equal_share_pct,
    CASE
        WHEN pct_of_total_revenue < equal_share_pct * @underperformance_factor
            THEN 'Underperforming'
        ELSE 'Healthy'
    END AS category_status
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
    order count by country. COUNT(DISTINCT order_number) is used because one
    order has several fact rows. Customers with no country are shown as
    'Unknown' instead of being dropped.

SQL concepts used:
    JOIN, GROUP BY, SUM, COUNT(DISTINCT), COALESCE, ORDER BY
===============================================================================
*/
SELECT
    COALESCE(c.country, 'Unknown') AS country,
    COUNT(DISTINCT f.order_number) AS total_orders,
    SUM(f.sales_amount) AS total_revenue,
    SUM(f.quantity) AS total_quantity_sold
FROM gold.fact_sales AS f
JOIN gold.dim_customers AS c
    ON c.customer_key = f.customer_key
GROUP BY COALESCE(c.country, 'Unknown')
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
    ROW_NUMBER (with customer_key as tie-breaker) is used instead of RANK so
    that exactly 10 customers are selected even if revenues tie at the cut-off.
    This is the same set of customers returned by Query 2.

SQL concepts used:
    JOIN, GROUP BY, SUM, ROW_NUMBER, OVER, CTE
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
        ROW_NUMBER() OVER (ORDER BY total_revenue DESC, customer_key) AS revenue_rank
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

Scope: only customers with at least one order that has an order_date are
evaluated. Customers who never purchased (no fact rows) or whose orders all
have a NULL order_date cannot be assigned a last purchase date and are excluded.

SQL concepts used:
    GROUP BY, MAX, DATEADD, DATEDIFF, JOIN, CTE
===============================================================================
*/
WITH customer_last_purchase AS (
    SELECT
        f.customer_key,
        MAX(f.order_date) AS last_order_date
    FROM gold.fact_sales AS f
    WHERE f.order_date IS NOT NULL
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
