/*
===============================================================================
Database Initialization: DataWarehouse
===============================================================================
Purpose:
    Creates the DataWarehouse database when it does not exist and ensures
    the Bronze, Silver, and Gold schemas are available.

Safety:
    This script is NON-DESTRUCTIVE. It does not drop or recreate an existing
    database. Back up the database before making manual destructive changes.
===============================================================================
*/

USE master;
GO

IF DB_ID(N'DataWarehouse') IS NULL
BEGIN
    CREATE DATABASE DataWarehouse;
END;
GO

USE DataWarehouse;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'bronze')
    EXEC(N'CREATE SCHEMA bronze');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'silver')
    EXEC(N'CREATE SCHEMA silver');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'gold')
    EXEC(N'CREATE SCHEMA gold');
GO
