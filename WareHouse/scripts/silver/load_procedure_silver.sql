
USE DataWarehouse;
GO

/*
===============================================================================
STORED PROCEDURE: silver.load_silver
===============================================================================
Purpose:
    Load and transform data from Bronze Layer into Silver Layer.

Transformations:
    1. Remove duplicate customer records.
    2. Trim whitespace from customer names.
    3. Standardize marital status and gender.
    4. Extract product category and product keys.
    5. Calculate product end dates.
    6. Validate and convert sales dates.
    7. Recalculate invalid sales and prices.
    8. Remove NAS prefix from ERP customer IDs.
    9. Handle future birthdates.
   10. Standardize country codes.
   11. Load ERP product category data.

Usage:
    EXEC silver.load_silver;
===============================================================================
*/

CREATE OR ALTER PROCEDURE silver.load_silver
AS
BEGIN

    SET NOCOUNT ON;

    DECLARE
        @start_time DATETIME,
        @end_time DATETIME,
        @batch_start_time DATETIME,
        @batch_end_time DATETIME;

    BEGIN TRY

        SET @batch_start_time = GETDATE();

        PRINT '================================================';
        PRINT 'STARTING SILVER LAYER LOAD';
        PRINT '================================================';

        --------------------------------------------------
        -- CRM TABLES
        --------------------------------------------------

        PRINT 'Loading CRM Tables';

        --------------------------------------------------
        -- 1. CRM CUSTOMER INFO
        --------------------------------------------------

        SET @start_time = GETDATE();

        PRINT 'Truncating silver.crm_cust_info';

        TRUNCATE TABLE silver.crm_cust_info;

        INSERT INTO silver.crm_cust_info
        (
            cst_id,
            cst_key,
            cst_firstname,
            cst_lastname,
            cst_marital_status,
            cst_gndr,
            cst_create_date
        )
        SELECT
            cst_id,
            cst_key,
            TRIM(cst_firstname),
            TRIM(cst_lastname),

            CASE
                WHEN UPPER(TRIM(cst_marital_status)) = 'S'
                    THEN 'Single'
                WHEN UPPER(TRIM(cst_marital_status)) = 'M'
                    THEN 'Married'
                ELSE 'n/a'
            END,

            CASE
                WHEN UPPER(TRIM(cst_gndr)) = 'F'
                    THEN 'Female'
                WHEN UPPER(TRIM(cst_gndr)) = 'M'
                    THEN 'Male'
                ELSE 'n/a'
            END,

            cst_create_date

        FROM
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY cst_id
                    ORDER BY cst_create_date DESC
                ) AS flag_last

            FROM bronze.crm_cust_info
            WHERE cst_id IS NOT NULL

        ) AS customer_data

        WHERE flag_last = 1;

        SET @end_time = GETDATE();

        PRINT 'CRM Customer Load Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR(20))
            + ' seconds';

        --------------------------------------------------
        -- 2. CRM PRODUCT INFO
        --------------------------------------------------

        SET @start_time = GETDATE();

        PRINT 'Truncating silver.crm_prd_info';

        TRUNCATE TABLE silver.crm_prd_info;

        ;WITH ProductData AS
        (
            SELECT
                prd_id,
                prd_key,
                prd_nm,
                prd_cost,
                prd_line,

                TRY_CONVERT(DATE, prd_start_dt) AS prd_start_dt,

                LEAD(TRY_CONVERT(DATE, prd_start_dt)) OVER
                (
                    PARTITION BY prd_key
                    ORDER BY TRY_CONVERT(DATE, prd_start_dt)
                ) AS next_start_dt

            FROM bronze.crm_prd_info
        )

        INSERT INTO silver.crm_prd_info
        (
            prd_id,
            cat_id,
            prd_key,
            prd_nm,
            prd_cost,
            prd_line,
            prd_start_dt,
            prd_end_dt
        )
        SELECT
            prd_id,

            REPLACE(SUBSTRING(prd_key, 1, 5), '-', '_'),

            SUBSTRING(prd_key, 7, LEN(prd_key)),

            prd_nm,

            ISNULL(prd_cost, 0),

            CASE
                WHEN UPPER(TRIM(prd_line)) = 'M'
                    THEN 'Mountain'
                WHEN UPPER(TRIM(prd_line)) = 'R'
                    THEN 'Road'
                WHEN UPPER(TRIM(prd_line)) = 'S'
                    THEN 'Other Sales'
                WHEN UPPER(TRIM(prd_line)) = 'T'
                    THEN 'Touring'
                ELSE 'n/a'
            END,

            prd_start_dt,

            DATEADD(DAY, -1, next_start_dt)

        FROM ProductData;

        SET @end_time = GETDATE();

        PRINT 'CRM Product Load Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR(20))
            + ' seconds';

        --------------------------------------------------
        -- 3. CRM SALES DETAILS
        --------------------------------------------------

        SET @start_time = GETDATE();

        PRINT 'Truncating silver.crm_sales_details';

        TRUNCATE TABLE silver.crm_sales_details;

        INSERT INTO silver.crm_sales_details
        (
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            sls_order_dt,
            sls_ship_dt,
            sls_due_dt,
            sls_sales,
            sls_quantity,
            sls_price
        )
        SELECT
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,

            TRY_CONVERT(
                DATE,
                CASE
                    WHEN LEN(LTRIM(RTRIM(
                        CONVERT(VARCHAR(20), sls_order_dt)
                    ))) = 8
                    THEN CONVERT(VARCHAR(8), sls_order_dt)
                END,
                112
            ),

            TRY_CONVERT(
                DATE,
                CASE
                    WHEN LEN(LTRIM(RTRIM(
                        CONVERT(VARCHAR(20), sls_ship_dt)
                    ))) = 8
                    THEN CONVERT(VARCHAR(8), sls_ship_dt)
                END,
                112
            ),

            TRY_CONVERT(
                DATE,
                CASE
                    WHEN LEN(LTRIM(RTRIM(
                        CONVERT(VARCHAR(20), sls_due_dt)
                    ))) = 8
                    THEN CONVERT(VARCHAR(8), sls_due_dt)
                END,
                112
            ),

            CASE
                WHEN sls_sales IS NULL
                    OR sls_sales <= 0
                    OR sls_sales <> sls_quantity * ABS(sls_price)
                THEN sls_quantity * ABS(sls_price)
                ELSE sls_sales
            END,

            sls_quantity,

            CASE
                WHEN sls_price IS NULL OR sls_price <= 0
                THEN sls_sales / NULLIF(sls_quantity, 0)
                ELSE sls_price
            END

        FROM bronze.crm_sales_details;

        SET @end_time = GETDATE();

        PRINT 'CRM Sales Load Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR(20))
            + ' seconds';

        --------------------------------------------------
        -- ERP TABLES
        --------------------------------------------------

        PRINT 'Loading ERP Tables';

        --------------------------------------------------
        -- 4. ERP CUSTOMER AZ12
        --------------------------------------------------

        SET @start_time = GETDATE();

        PRINT 'Truncating silver.erp_cust_az12';

        TRUNCATE TABLE silver.erp_cust_az12;

        INSERT INTO silver.erp_cust_az12
        (
            cid,
            bdate,
            gen
        )
        SELECT
            CASE
                WHEN cid LIKE 'NAS%'
                    THEN SUBSTRING(cid, 4, LEN(cid))
                ELSE cid
            END,

            CASE
                WHEN TRY_CONVERT(DATE, bdate) > CAST(GETDATE() AS DATE)
                    THEN NULL
                ELSE TRY_CONVERT(DATE, bdate)
            END,

            CASE
                WHEN UPPER(TRIM(gen)) IN ('F', 'FEMALE')
                    THEN 'Female'
                WHEN UPPER(TRIM(gen)) IN ('M', 'MALE')
                    THEN 'Male'
                ELSE 'n/a'
            END

        FROM bronze.erp_cust_az12;

        SET @end_time = GETDATE();

        PRINT 'ERP Customer Load Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR(20))
            + ' seconds';

        --------------------------------------------------
        -- 5. ERP LOCATION A101
        --------------------------------------------------

        SET @start_time = GETDATE();

        PRINT 'Truncating silver.erp_loc_a101';

        TRUNCATE TABLE silver.erp_loc_a101;

        INSERT INTO silver.erp_loc_a101
        (
            cid,
            cntry
        )
        SELECT
            REPLACE(cid, '-', ''),

            CASE
                WHEN TRIM(cntry) = 'DE'
                    THEN 'Germany'
                WHEN TRIM(cntry) IN ('US', 'USA')
                    THEN 'United States'
                WHEN TRIM(cntry) = '' OR cntry IS NULL
                    THEN 'n/a'
                ELSE TRIM(cntry)
            END

        FROM bronze.erp_loc_a101;

        SET @end_time = GETDATE();

        PRINT 'ERP Location Load Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR(20))
            + ' seconds';

        --------------------------------------------------
        -- 6. ERP PRODUCT CATEGORY
        --------------------------------------------------

        SET @start_time = GETDATE();

        PRINT 'Truncating silver.erp_px_cat_g1v2';

        TRUNCATE TABLE silver.erp_px_cat_g1v2;

        INSERT INTO silver.erp_px_cat_g1v2
        (
            id,
            cat,
            subcat,
            maintenance
        )
        SELECT
            id,
            cat,
            subcat,
            maintenance

        FROM bronze.erp_px_cat_g1v2;

        SET @end_time = GETDATE();

        PRINT 'ERP Product Category Load Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR(20))
            + ' seconds';

        --------------------------------------------------
        -- COMPLETION
        --------------------------------------------------

        SET @batch_end_time = GETDATE();

        PRINT '================================================';
        PRINT 'SILVER LAYER LOAD COMPLETED SUCCESSFULLY';

        PRINT 'Total Load Duration: '
            + CAST(
                DATEDIFF(
                    SECOND,
                    @batch_start_time,
                    @batch_end_time
                ) AS NVARCHAR(20)
            )
            + ' seconds';

        PRINT '================================================';

    END TRY

    BEGIN CATCH

        PRINT '================================================';
        PRINT 'ERROR OCCURRED DURING SILVER LAYER LOAD';

        PRINT 'Error Message: ' + ERROR_MESSAGE();

        PRINT 'Error Number: '
            + CAST(ERROR_NUMBER() AS NVARCHAR(20));

        PRINT 'Error Line: '
            + CAST(ERROR_LINE() AS NVARCHAR(20));

        PRINT 'Error Procedure: '
            + ISNULL(ERROR_PROCEDURE(), 'N/A');

        PRINT '================================================';

        THROW;

    END CATCH

END;
GO
