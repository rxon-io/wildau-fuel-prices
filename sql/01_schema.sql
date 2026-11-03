-- Wildau fuel stations: real prices (Tankerkönig / MTS-K) and simulated sales
-- Microsoft SQL Server 2022 / T-SQL
-- All timestamps are stored in UTC; the views in 03_views.sql convert them to German local time.

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF DB_ID(N'wildau_fuel') IS NULL
    CREATE DATABASE wildau_fuel;
GO
USE wildau_fuel;
GO

-- Fuel stations, taken from the Tankerkönig station list
CREATE TABLE dbo.station
(
    station_id   int IDENTITY(1,1) NOT NULL CONSTRAINT pk_station PRIMARY KEY,
    tk_uuid      uniqueidentifier  NOT NULL CONSTRAINT uq_station_tk_uuid UNIQUE, -- station id in the Tankerkönig data
    brand        nvarchar(50)      NOT NULL,
    name         nvarchar(100)     NOT NULL,
    street       nvarchar(100)     NOT NULL,
    house_number nvarchar(10)      NULL,
    post_code    char(5)           NOT NULL,
    city         nvarchar(50)      NOT NULL,
    latitude     decimal(9,6)      NULL,
    longitude    decimal(9,6)      NULL
);

-- Fuel types reported to the MTS-K. A short fixed list, so tinyint is enough here.
CREATE TABLE dbo.fuel
(
    fuel_id tinyint      NOT NULL CONSTRAINT pk_fuel PRIMARY KEY,
    code    varchar(10)  NOT NULL CONSTRAINT uq_fuel_code UNIQUE,   -- column name in the Tankerkönig CSV files
    name    nvarchar(30) NOT NULL
);

CREATE TABLE dbo.payment_method
(
    payment_method_id tinyint      NOT NULL CONSTRAINT pk_payment_method PRIMARY KEY,
    name              nvarchar(30) NOT NULL CONSTRAINT uq_payment_method_name UNIQUE
);

-- Real price history: one row per price change of one fuel at one station.
-- A price is valid from valid_from_utc until the next change (see dbo.v_price_period).
-- The natural key is the primary key: a station cannot change the same fuel twice in the same second.
CREATE TABLE dbo.price_change
(
    station_id     int          NOT NULL CONSTRAINT fk_price_change_station REFERENCES dbo.station (station_id),
    fuel_id        tinyint      NOT NULL CONSTRAINT fk_price_change_fuel REFERENCES dbo.fuel (fuel_id),
    valid_from_utc datetime2(0) NOT NULL,
    price_eur      decimal(4,3) NOT NULL CONSTRAINT ck_price_change_price CHECK (price_eur > 0),
    CONSTRAINT pk_price_change PRIMARY KEY (station_id, fuel_id, valid_from_utc)
);

-- Simulated sales (generated, not real transactions; see README).
-- Each sale stores the price that was valid at the moment of sale.
CREATE TABLE dbo.sale
(
    sale_id           int IDENTITY(1,1) NOT NULL CONSTRAINT pk_sale PRIMARY KEY,
    station_id        int          NOT NULL CONSTRAINT fk_sale_station REFERENCES dbo.station (station_id),
    fuel_id           tinyint      NOT NULL CONSTRAINT fk_sale_fuel REFERENCES dbo.fuel (fuel_id),
    payment_method_id tinyint      NOT NULL CONSTRAINT fk_sale_payment_method REFERENCES dbo.payment_method (payment_method_id),
    sold_at_utc       datetime2(0) NOT NULL,
    liters            decimal(6,2) NOT NULL CONSTRAINT ck_sale_liters CHECK (liters > 0 AND liters <= 150),
    price_eur         decimal(4,3) NOT NULL CONSTRAINT ck_sale_price CHECK (price_eur > 0),
    amount_eur AS CAST(ROUND(liters * price_eur, 2) AS decimal(9,2)) PERSISTED  -- rounded to cents, like at the pump
);

CREATE INDEX ix_sale_sold_at ON dbo.sale (sold_at_utc) INCLUDE (station_id, fuel_id, liters, price_eur);
GO
