-- Load prices and simulated sales from CSV files into the database.
--
-- Before running: copy the CSV files into the SQL Server container:
--   docker exec -u root wildau-sql mkdir -p /tmp/wildau
--   docker cp data/stations.csv wildau-sql:/tmp/wildau/stations.csv
--   docker cp data/prices.csv   wildau-sql:/tmp/wildau/prices.csv
--   docker cp data/sales.csv    wildau-sql:/tmp/wildau/sales.csv
--
-- stations.csv and prices.csv come from src/tk_clean.py (real Tankerkönig data),
-- sales.csv from src/generate_sales.py (simulated).
-- The script replaces all stations, prices and sales, so it can be re-run.

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;   -- any error rolls back the whole load
GO
USE wildau_fuel;
GO

IF SCHEMA_ID(N'stage') IS NULL
    EXEC (N'CREATE SCHEMA stage');
GO

-- Staging tables: the CSV files as they are, before they are checked and mapped to ids
DROP TABLE IF EXISTS stage.station;
CREATE TABLE stage.station
(
    station      varchar(20)      NOT NULL,   -- key used in the other CSV files ('shell', 'sprint')
    uuid         uniqueidentifier NOT NULL,
    brand        nvarchar(50)     NOT NULL,
    name         nvarchar(100)    NOT NULL,
    street       nvarchar(100)    NOT NULL,
    house_number nvarchar(10)     NULL,
    post_code    char(5)          NOT NULL,
    city         nvarchar(50)     NOT NULL,
    latitude     decimal(9,6)     NULL,
    longitude    decimal(9,6)     NULL
);

DROP TABLE IF EXISTS stage.price;
CREATE TABLE stage.price
(
    station        varchar(20)  NOT NULL,
    fuel           varchar(10)  NOT NULL,
    valid_from_utc datetime2(0) NOT NULL,
    price_eur      decimal(4,3) NOT NULL
);

DROP TABLE IF EXISTS stage.sale;
CREATE TABLE stage.sale
(
    station        varchar(20)  NOT NULL,
    fuel           varchar(10)  NOT NULL,
    payment_method varchar(20)  NOT NULL,
    sold_at_utc    datetime2(0) NOT NULL,
    liters         decimal(6,2) NOT NULL,
    price_eur      decimal(4,3) NOT NULL
);
GO

BULK INSERT stage.station FROM '/tmp/wildau/stations.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

BULK INSERT stage.price FROM '/tmp/wildau/prices.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

BULK INSERT stage.sale FROM '/tmp/wildau/sales.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);
GO

-- Safety check: never delete the current data if the CSV files did not load.
-- (SSMS continues with the next batch after an error, so an empty stage must stop the script here.)
IF NOT EXISTS (SELECT 1 FROM stage.station)
   OR NOT EXISTS (SELECT 1 FROM stage.price)
   OR NOT EXISTS (SELECT 1 FROM stage.sale)
    THROW 50010, N'Staging tables are empty: the CSV files were not loaded. Existing data was not changed.', 1;

BEGIN TRANSACTION;

DELETE FROM dbo.sale;
DELETE FROM dbo.price_change;
DELETE FROM dbo.station;

INSERT INTO dbo.station (tk_uuid, brand, name, street, house_number, post_code, city, latitude, longitude)
SELECT uuid, brand, name, street, house_number, post_code, city, latitude, longitude
FROM stage.station;

-- The station key in the CSV files is mapped to the database id through the Tankerkönig uuid
INSERT INTO dbo.price_change (station_id, fuel_id, valid_from_utc, price_eur)
SELECT st.station_id, f.fuel_id, p.valid_from_utc, p.price_eur
FROM stage.price AS p
JOIN stage.station AS ss ON ss.station = p.station
JOIN dbo.station   AS st ON st.tk_uuid = ss.uuid
JOIN dbo.fuel      AS f  ON f.code = p.fuel;

INSERT INTO dbo.sale (station_id, fuel_id, payment_method_id, sold_at_utc, liters, price_eur)
SELECT st.station_id, f.fuel_id, pm.payment_method_id, s.sold_at_utc, s.liters, s.price_eur
FROM stage.sale AS s
JOIN stage.station      AS ss ON ss.station = s.station
JOIN dbo.station        AS st ON st.tk_uuid = ss.uuid
JOIN dbo.fuel           AS f  ON f.code = s.fuel
JOIN dbo.payment_method AS pm ON pm.name = s.payment_method;

COMMIT TRANSACTION;
GO

-- Every staged row must have arrived: a lost row means a station, fuel or payment
-- method in the CSV that the reference tables do not know.
SELECT 'station' AS target,
       (SELECT COUNT(*) FROM stage.station)    AS rows_in_csv,
       (SELECT COUNT(*) FROM dbo.station)      AS rows_loaded
UNION ALL
SELECT 'price_change',
       (SELECT COUNT(*) FROM stage.price)      AS rows_in_csv,
       (SELECT COUNT(*) FROM dbo.price_change) AS rows_loaded
UNION ALL
SELECT 'sale',
       (SELECT COUNT(*) FROM stage.sale),
       (SELECT COUNT(*) FROM dbo.sale);

-- Every sale must carry the price that was valid at its moment of sale
SELECT COUNT(*) AS sales_with_wrong_price
FROM dbo.sale AS s
CROSS APPLY (SELECT TOP (1) pc.price_eur
             FROM dbo.price_change AS pc
             WHERE pc.station_id = s.station_id
               AND pc.fuel_id = s.fuel_id
               AND pc.valid_from_utc <= s.sold_at_utc
             ORDER BY pc.valid_from_utc DESC) AS valid
WHERE valid.price_eur <> s.price_eur;
GO
