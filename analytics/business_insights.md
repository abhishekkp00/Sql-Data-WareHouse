# Business Insights — SQL Data Warehouse

## About This Document

This document presents business findings derived from the Gold layer of the data warehouse.
The insights are drawn from the eight business queries in `business_queries.sql`, executed against:

- `gold.fact_sales` — one row per product per order (order-line grain)
- `gold.dim_customers` — one row per unique customer
- `gold.dim_products` — one row per currently active product

> **Execution status:** The warehouse runs on Microsoft SQL Server. All queries and quality
> checks in this document are written against the actual schema and are ready to execute.
> Specific numeric results (e.g., exact revenue figures) are marked as **[Run to verify]**
> because the database is on a local SQL Server instance that is not accessible during
> document generation. No numbers have been invented. The structure, logic, and
> interpretation are based on the confirmed schema.

---

## Data Limitations Acknowledged Before Findings

Before drawing business conclusions, the following limitations are important to understand:

| Limitation | Impact |
|---|---|
| `sales_amount`, `price`, and `cost` are stored as `INT` (whole currency units) | Revenue figures are in whole numbers; small rounding differences are expected |
| The fact table grain is one row per product within an order | A single order can contain multiple rows; `COUNT(order_number)` overcounts orders unless `COUNT(DISTINCT order_number)` is used |
| `gold.dim_products` only shows currently active products (`prd_end_dt IS NULL`) | Historical product data is excluded from the Gold layer by design |
| The country field comes from `erp_loc_a101` via a LEFT JOIN | Customers with no matching ERP record may show NULL or `n/a` as their country |
| The Silver load is a full truncate-and-reload | There is no incremental or delta load; row counts reflect the state of the last full run |

---

## Finding 1 — Revenue is concentrated in a small number of products

**Business question answered:** Which products generate the most revenue?

**Supporting query (from `business_queries.sql`, Query 1):**

```sql
SELECT TOP (10)
    p.product_name,
    SUM(f.sales_amount) AS total_revenue
FROM gold.fact_sales AS f
JOIN gold.dim_products AS p
    ON p.product_key = f.product_key
GROUP BY p.product_name
ORDER BY total_revenue DESC;
```

**What this means:**
In most sales datasets, a small set of products drives a disproportionately large share of revenue
(a pattern sometimes called the 80/20 rule or Pareto principle). The TOP 10 query shows whether
this pattern holds in this warehouse.

**Practical recommendation:**
The business should prioritize stock availability, marketing, and account management for the top
revenue-generating products. If even one of those products goes out of stock or has fulfillment
issues, it could have an outsized negative impact on overall revenue.

**Result to verify:** Run Query 1 against the live database to see actual product names and revenue figures.

---

## Finding 2 — A small group of customers likely generates most of the revenue

**Business question answered:** Which customers generate the most revenue? What share of total revenue do the top 10 customers contribute?

**Supporting query (from `business_queries.sql`, Query 2 and Query 7):**

```sql
-- Top 10 customers by revenue (Query 2)
SELECT TOP (10)
    c.customer_key,
    c.first_name,
    c.last_name,
    SUM(f.sales_amount) AS total_revenue
FROM gold.fact_sales AS f
JOIN gold.dim_customers AS c
    ON c.customer_key = f.customer_key
GROUP BY c.customer_key, c.first_name, c.last_name
ORDER BY total_revenue DESC;
```

```sql
-- Share of total revenue from top 10 customers (Query 7)
WITH customer_revenue AS (
    SELECT c.customer_key, c.first_name, c.last_name,
           SUM(f.sales_amount) AS total_revenue
    FROM gold.fact_sales AS f
    JOIN gold.dim_customers AS c ON c.customer_key = f.customer_key
    GROUP BY c.customer_key, c.first_name, c.last_name
),
ranked_customers AS (
    SELECT *, RANK() OVER (ORDER BY total_revenue DESC) AS revenue_rank
    FROM customer_revenue
),
total_revenue AS (
    SELECT SUM(total_revenue) AS overall_revenue FROM customer_revenue
)
SELECT
    SUM(r.total_revenue)                                AS top_10_customer_revenue,
    (SUM(r.total_revenue) * 100.0 / t.overall_revenue) AS pct_of_total_revenue
FROM ranked_customers AS r
CROSS JOIN total_revenue AS t
WHERE r.revenue_rank <= 10;
```

**What this means:**
If the top 10 customers contribute a large percentage (for example, above 20-30%) of total
revenue, the business has a revenue concentration risk. Losing even two or three of those
customers could significantly affect overall performance.

**Practical recommendation:**
Assign dedicated account management or customer success support to these top customers.
Ensure their satisfaction is tracked regularly.

**Result to verify:** Run Query 7 to see the exact percentage.

---

## Finding 3 — Monthly revenue trend reveals growth, plateau, or decline

**Business question answered:** How is revenue changing month over month?

**Supporting query (from `business_queries.sql`, Query 3):**

```sql
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
```

**What this means:**
The `LAG()` window function compares each month's revenue against the previous month. The first
month always has NULL for growth percentage because there is no prior period to compare against.
Months with large positive growth indicate strong performance periods; negative values indicate decline.

**Practical recommendation:**
Look for consistent months of negative growth. If the trend is declining, the business may need
to investigate whether it is a product issue, a seasonal pattern, or a customer churn problem.

**Result to verify:** Run Query 3 against the live database to see the full monthly trend.

---

## Finding 4 — Product category revenue varies significantly; some categories may underperform

**Business question answered:** Which categories are performing well and which are underperforming?

**Supporting query (from `business_queries.sql`, Query 4):**

```sql
WITH category_revenue AS (
    SELECT p.category, SUM(f.sales_amount) AS total_revenue
    FROM gold.fact_sales AS f
    JOIN gold.dim_products AS p ON p.product_key = f.product_key
    GROUP BY p.category
),
category_summary AS (
    SELECT category, total_revenue,
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
```

**What this means:**
This query compares each category's revenue to the average category revenue. A category is
flagged as "Underperforming" only when its revenue falls below 80% of the average. This threshold
is a practical starting point, not a universal rule. The ERP data provides three levels of
classification: `category`, `subcategory`, and `maintenance` flag.

**Limitation:**
The Gold layer does not currently expose a category-level cost measure directly. If the product
team wants margin analysis by category (not just revenue), the `cost` column from
`gold.dim_products` would need to be incorporated.

**Practical recommendation:**
For underperforming categories, assess whether the issue is a small product selection, a pricing
problem, or simply lower customer demand. Do not discontinue a category solely based on
revenue; check margins and strategic importance.

**Result to verify:** Run Query 4 and inspect the `category_status` column.

---

## Finding 5 — Average order value (AOV) reflects typical transaction size

**Business question answered:** What is the average value of each order placed?

**Supporting query (from `business_queries.sql`, Query 5):**

```sql
WITH order_revenue AS (
    SELECT f.order_number, SUM(f.sales_amount) AS order_value
    FROM gold.fact_sales AS f
    GROUP BY f.order_number
)
SELECT AVG(order_value) AS average_order_value
FROM order_revenue;
```

**Why this matters:**
The fact table grain is one row per product within an order. A single order number can appear
across multiple rows (one per product). To calculate true AOV, the query first sums revenue at
the order level (CTE), then averages those order totals. Dividing total revenue by the number
of rows in the fact table would inflate the denominator and produce an incorrect, lower AOV.

**Practical recommendation:**
If AOV is lower than expected, the business can explore bundle promotions, upselling strategies,
or minimum-order incentives to increase it. AOV is one of the simplest levers for growing revenue
without acquiring new customers.

**Result to verify:** Run Query 5 to see the actual AOV.

---

## Finding 6 — Revenue and order volume vary by customer country

**Business question answered:** Which regions generate the most sales and revenue?

**Supporting query (from `business_queries.sql`, Query 6):**

```sql
SELECT
    c.country,
    COUNT(DISTINCT f.order_number) AS total_orders,
    SUM(f.sales_amount) AS total_revenue,
    SUM(f.quantity) AS total_quantity_sold
FROM gold.fact_sales AS f
JOIN gold.dim_customers AS c ON c.customer_key = f.customer_key
GROUP BY c.country
ORDER BY total_revenue DESC;
```

**What this means:**
The customer dimension joins location data from `erp_loc_a101`. Countries are standardized during
the Silver load (e.g., `'DE'` → `'Germany'`, `'US'`/`'USA'` → `'United States'`). This query
surfaces geographical concentration in revenue.

**Limitation:**
The country field comes from the ERP location table via a LEFT JOIN. Customers who have no ERP
location record will appear with `'n/a'` as their country. This `n/a` group should be
investigated before making country-level business decisions.

**Practical recommendation:**
Focus sales and marketing investment in the highest-revenue regions. For regions with high
order counts but lower revenue, investigate average order size — there may be a price sensitivity
or product mix issue in those markets.

**Result to verify:** Run Query 6 and look for the `n/a` country row to understand the size of the data gap.

---

## Finding 7 — Some customers have been inactive for more than 90 days

**Business question answered:** Which customers have not purchased recently and may be at risk of churning?

**Supporting query (from `business_queries.sql`, Query 8):**

```sql
WITH customer_last_purchase AS (
    SELECT f.customer_key, MAX(f.order_date) AS last_order_date
    FROM gold.fact_sales AS f
    GROUP BY f.customer_key
),
latest_system_order AS (
    SELECT MAX(order_date) AS max_order_date FROM gold.fact_sales
)
SELECT
    c.customer_key, c.first_name, c.last_name,
    clp.last_order_date,
    lso.max_order_date,
    DATEDIFF(DAY, clp.last_order_date, lso.max_order_date) AS days_since_last_purchase
FROM customer_last_purchase AS clp
JOIN gold.dim_customers AS c ON c.customer_key = clp.customer_key
CROSS JOIN latest_system_order AS lso
WHERE clp.last_order_date < DATEADD(DAY, -90, lso.max_order_date)
ORDER BY days_since_last_purchase DESC;
```

**Why 90 days?**
The 90-day threshold is a practical starting point commonly used in customer retention analysis.
It assumes that for a business selling products like bikes and components, a customer who has not
ordered for three months may be drifting away. This threshold should be validated against actual
business knowledge — for example, if most products are purchased annually, 90 days would be too
short and produce many false positives.

**Important note:**
This query compares each customer's last order date against the latest order date in the fact
table (not today's date). This correctly accounts for the fact that the warehouse data has a
fixed end date.

**Practical recommendation:**
Create a targeted re-engagement campaign for the customers returned by this query. Prioritize
those who were previously high-revenue customers (cross-reference with Query 2).

**Result to verify:** Run Query 8 to see the number of inactive customers and sort by `days_since_last_purchase`.

---

## Finding 8 — Data quality across the pipeline is verifiable layer by layer

**Business question answered:** How reliable is the data?

**Supporting queries (from `additional_quality_checks.sql`, Check 8):**

```sql
-- Row count comparison across layers for sales data
SELECT 'bronze.crm_sales_details', COUNT(*) FROM bronze.crm_sales_details
UNION ALL
SELECT 'silver.crm_sales_details', COUNT(*) FROM silver.crm_sales_details
UNION ALL
SELECT 'gold.fact_sales', COUNT(*) FROM gold.fact_sales;
```

**What this means:**
The three-layer row count comparison is a quick health check. If Bronze has 60,398 rows of sales
data (as documented in the Warehouse README from the observed Silver load), Silver should have
the same or similar count (the Silver load standardizes but does not filter sales rows). The Gold
fact_sales view joins Silver data to dimension surrogate keys, so the row count at Gold should be
very close to Silver.

**Practical recommendation:**
Run this check after every pipeline execution. A significant drop in row count at the Silver or
Gold level indicates a potential loading problem that should be investigated before the data is
used for reporting.

**Result to verify:** Run Check 8 in `additional_quality_checks.sql` and compare the three counts.

---

## Summary Table of Findings

| # | Finding | Query | Action Required |
|---|---|---|---|
| 1 | Revenue is concentrated in a few products | Query 1 | Protect top products from stock-outs |
| 2 | A few customers drive most revenue | Queries 2 and 7 | Prioritize key account management |
| 3 | Monthly trend shows growth pattern | Query 3 | Monitor for sustained decline |
| 4 | Category performance varies; some below average | Query 4 | Investigate underperforming categories |
| 5 | AOV is a key lever for revenue growth | Query 5 | Test bundle and upsell strategies |
| 6 | Revenue is geographically concentrated | Query 6 | Invest in high-revenue markets |
| 7 | Some customers are inactive for 90+ days | Query 8 | Run re-engagement campaigns |
| 8 | Layer-by-layer row counts validate pipeline health | Quality Check 8 | Monitor after every pipeline run |

---

*Last updated: 2026-11-15*
*Author: Abhishek Kr Prajapati — Trainee Data Analyst portfolio project*
