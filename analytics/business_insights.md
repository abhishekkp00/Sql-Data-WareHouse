# Business Insights — SQL Data Warehouse

## About This Document

This document presents findings from the eight business queries in
[business_queries.sql](business_queries.sql), which run on the Gold layer:

- `gold.fact_sales` — one row per product within an order (order-line grain)
- `gold.dim_customers` — one row per customer
- `gold.dim_products` — one row per currently active product

## How These Findings Were Verified

| Status label | Meaning |
|---|---|
| **Verified (CSV replication)** | The query logic was re-calculated with pandas on the exported Gold CSV files in `EDA/datasets/csv_files/` (`gold.fact_sales.csv`, `gold.dim_customers.csv`, `gold.dim_products.csv`). These exports are snapshots of the Gold views. |
| **Pending execution** | Needs the T-SQL to be executed on the SQL Server instance. |

> [!IMPORTANT]
> The T-SQL files themselves were **not executed** against SQL Server while preparing
> this document (no database credentials were available). The numbers below come from
> an independent pandas replication of each query's logic on the exported data. Run
> [business_queries.sql](business_queries.sql) locally and compare; small differences
> would mean the export is older than the live database.

---

## Data Limitations

| Limitation | Impact |
|---|---|
| `sales_amount`, `price`, and `cost` are stored as `INT` (whole currency units) | Revenue is in whole numbers; rounding differences are possible. |
| Grain is one row per product within an order | Use `COUNT(DISTINCT order_number)` for order counts; AOV needs an order-level CTE. |
| `gold.dim_products` keeps only current products (`prd_end_dt IS NULL`) | Historical product versions are excluded by design. |
| 19 fact rows (about 5k revenue units) have a NULL `order_date` | Included in revenue totals, excluded from monthly and recency analysis. |
| The data starts in December 2010 and ends on 28 January 2014 | The first and last months are partial, so their month-over-month growth is not meaningful. |
| Only 130 of 295 current products have sales | Product rankings cover sold products only. |
| 7 current products have no category (e.g. pedals); none have sales | Category analysis is not affected, but those products are unclassified. |
| Silver load is a full truncate-and-reload | No incremental history. |

---

## Finding 1 — Revenue is concentrated in a few product lines (Query 1)

**Status:** Verified (CSV replication)

Total revenue is 29,356,250. The top 10 products are all size variants of two models,
**Mountain-200** (Black/Silver) and **Road-150 Red**. Together they earn about **42.5%** of
total revenue. Top product: *Mountain-200 Black- 46* (1,373,454).

At product-line level, Road bikes earn about 49% and Mountain about 34% of revenue.

**Implication:** Revenue depends heavily on a few models.
**Recommendation:** Protect stock availability and pricing for these models, and
review whether the long tail of unsold or low-selling products is worth keeping.

*Note: each size variant is a separate `product_key`, which is why grouping by key (not name) matters.*

---

## Finding 2 — Customer revenue is NOT concentrated (Queries 2 and 7)

**Status:** Verified (CSV replication)

18,484 customers have purchases. The top 10 customers together contribute 132,023, which is
only about **0.45%** of total revenue. The highest customers (e.g. customer_key 1302 and
1133 at 13,294 each) are tied, which is why Query 2 uses `customer_key` as a tie-breaker.

**Implication:** There is no single-customer revenue risk. This is a broad customer base.
**Recommendation:** Growth should come from repeat purchases and acquisition rather than
key-account management. Most customers (11,619 of 18,484) placed only one order, so repeat-purchase
programs are a clear opportunity.

---

## Finding 3 — Revenue fell in 2012 and grew strongly in 2013 (Query 3)

**Status:** Verified (CSV replication)

| Year | Revenue |
|---|---|
| 2010 (Dec only) | 43,419 |
| 2011 | 7,075,088 |
| 2012 | 5,842,231 |
| 2013 | 16,344,878 |
| 2014 (Jan only, partial) | 45,642 |

Revenue dropped from 2011 to 2012, then rose to nearly three times the 2012 level in 2013.
Monthly revenue peaked in December 2013 (1,874,128). The −97.6% growth in January 2014 and the
+982% in January 2011 are artifacts of partial or very small months, not real events.

**Implication:** The business grew fast in 2013.
**Recommendation:** Investigate what changed in late 2012/2013 (new products, new markets,
pricing) with the business team; the data alone cannot explain the cause.

---

## Finding 4 — Bikes make up almost all category revenue (Query 4)

**Status:** Verified (CSV replication)

| Category | Share of revenue |
|---|---|
| Bikes | 96.46% |
| Accessories | 2.39% |
| Clothing | 1.16% |

With the rule "underperforming = below 50% of an equal share" (equal share = 33.3%, so the
cut-off is 16.7%), Accessories and Clothing are flagged as **Underperforming** and Bikes as **Healthy**.

> The 50% rule is a business assumption, documented and adjustable in the query.
> The old rule (80% of average category revenue) was replaced because a single dominant category
> inflates the average.

**Limitation:** Revenue only. Margin (`cost`) is not included, so low revenue does not prove a category is unprofitable.
**Recommendation:** Look at accessories and clothing as add-on sales to bike buyers rather than standalone categories.

---

## Finding 5 — Average order value is about 1,061 (Query 5)

**Status:** Verified (CSV replication)

There are 27,659 distinct orders. The AOV calculated per order is about **1,061**. The average
per fact row (line item) is only about 486. Using the line-item average would understate AOV by more than half.

**Recommendation:** Since accessories are low-priced add-ons, bundling them with bikes is a simple way to raise AOV.

---

## Finding 6 — Two countries produce about 62% of revenue (Query 6)

**Status:** Verified (CSV replication)

| Country | Revenue | Share |
|---|---|---|
| United States | 9,162,327 | 31.2% |
| Australia | 9,060,172 | 30.9% |
| United Kingdom | 3,391,376 | 11.6% |
| Germany | 2,894,066 | 9.9% |
| France | 2,643,751 | 9.0% |
| Canada | 1,977,738 | 6.7% |
| n/a (country not available) | 226,820 | 0.8% |

Canada has more orders (3,375) than France or Germany (2,484 each) but much lower revenue,
which suggests a lower average order value there.

**Limitation:** Customers without an ERP location record show `n/a` as country (337 orders, 0.8% of revenue). It is small, but it should not be read as a real market.

**Recommendation:** Check Canadian product mix and pricing, and fix the missing location mapping.

---

## Finding 7 — Most customers have not purchased in the final 90 days (Query 8)

**Status:** Verified (CSV replication)

Using 28 January 2014 (latest order date in the data) as the reference date, **13,550 of
18,484** customers (73%) last purchased more than 90 days earlier. 2 customers are excluded because all their orders have a
NULL date.

**Important:** This reflects a data set where most customers buy once or twice over three years.
The 90-day rule is an assumption; for bikes a longer window (e.g. 12 months) may be more realistic.
**Recommendation:** Test several thresholds before using the list for a campaign.

---

## Finding 8 — Row counts across layers (Quality Check 8)

**Status:** Verified (CSV replication of exported layer counts)

| Table | Bronze | Silver | Gold |
|---|---|---|---|
| Customers | 18,493 | 18,484 | 18,484 |
| Products | 397 | 397 | 295 (current only) |
| Sales | 60,398 | 60,398 | 60,398 |

The 9-row drop in customers is the Silver duplicate removal. The product drop at Gold is the
`prd_end_dt IS NULL` filter. Sales rows are preserved. In the exported data the Gold
checks for duplicate keys, orphaned keys, negative or inconsistent values, impossible dates, and
duplicate grain rows all return zero rows.

---

## Summary

| # | Finding | Query | Status |
|---|---|---|---|
| 1 | Revenue concentrated in a few Mountain-200 / Road-150 models (42.5% for the top 10) | Query 1 | Verified (CSV replication) |
| 2 | Customer revenue is not concentrated (top 10 = 0.45%) | Queries 2, 7 | Verified (CSV replication) |
| 3 | Revenue dipped in 2012, strong growth in 2013 | Query 3 | Verified (CSV replication) |
| 4 | Bikes are 96.5% of revenue | Query 4 | Verified (CSV replication) |
| 5 | AOV about 1,061 | Query 5 | Verified (CSV replication) |
| 6 | US and Australia about 62% of revenue | Query 6 | Verified (CSV replication) |
| 7 | 13,550 customers inactive for more than 90 days | Query 8 | Verified (CSV replication) |
| 8 | Layer counts consistent with documented cleaning rules | Quality Check 8 | Verified (CSV replication) |

All findings are **pending execution of the T-SQL on SQL Server** for final confirmation.

---

*Author: Abhishek Kr Prajapati — Trainee Data Analyst portfolio project*
