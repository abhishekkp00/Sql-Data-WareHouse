# Exploratory Data Analysis (EDA)

This folder contains exploratory analysis of the CRM, ERP, and warehouse datasets.

## Conventions
- Read source data from the canonical `../datasets/` directory or query the warehouse.
- Do not store duplicate source files or Bronze exports here.
- Keep exploratory SQL in `sql/`, notebooks in `notebooks/`, and selected reproducible outputs in `outputs/`.
- Move stable, reusable transformations into `../scripts/`.

## Suggested workflow
1. Source and column profiling.
2. Null, duplicate, and distinct-value analysis.
3. Numeric distributions and outlier review.
4. Date coverage and anomaly analysis.
5. Customer, product, location, and sales relationship exploration.
6. Record findings and follow-up questions.
