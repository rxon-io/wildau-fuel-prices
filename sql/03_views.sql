-- Views and procedures used by the analysis and by Power BI.
-- 'W. Europe Standard Time' is the SQL Server name of the Berlin time zone (CET/CEST, with daylight saving).

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE wildau_fuel;
GO

-- Price periods: each price change becomes an interval [valid_from, valid_to).
-- valid_to is the time of the next change of the same fuel at the same station (NULL for the current price).
CREATE VIEW dbo.v_price_period
AS
SELECT
    pc.station_id,
    pc.fuel_id,
    pc.price_eur,
    pc.valid_from_utc,
    LEAD(pc.valid_from_utc) OVER (PARTITION BY pc.station_id, pc.fuel_id
                                  ORDER BY pc.valid_from_utc) AS valid_to_utc,
    CAST(pc.valid_from_utc AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime2(0)) AS valid_from_local
FROM dbo.price_change AS pc;
GO

-- Sales with names instead of ids and the time in German local time
CREATE VIEW dbo.v_sale
AS
SELECT
    s.sale_id,
    st.brand  AS station,
    f.name    AS fuel,
    pm.name   AS payment_method,
    CAST(s.sold_at_utc AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime2(0)) AS sold_at_local,
    s.liters,
    s.price_eur,
    s.amount_eur
FROM dbo.sale AS s
JOIN dbo.station        AS st ON st.station_id        = s.station_id
JOIN dbo.fuel           AS f  ON f.fuel_id            = s.fuel_id
JOIN dbo.payment_method AS pm ON pm.payment_method_id = s.payment_method_id;
GO

-- Record one sale with the price that was valid at the moment of sale.
-- Raises error 50001 if no price is known yet for this station and fuel.
CREATE PROCEDURE dbo.pr_record_sale
    @station_id        int,
    @fuel_id           tinyint,
    @payment_method_id tinyint,
    @liters            decimal(6,2),
    @sold_at_utc       datetime2(0) = NULL,   -- NULL = now
    @sale_id           int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @sold_at_utc = ISNULL(@sold_at_utc, CAST(SYSUTCDATETIME() AS datetime2(0)));

    DECLARE @price_eur decimal(4,3);

    SELECT TOP (1) @price_eur = pc.price_eur
    FROM dbo.price_change AS pc
    WHERE pc.station_id = @station_id
      AND pc.fuel_id = @fuel_id
      AND pc.valid_from_utc <= @sold_at_utc
    ORDER BY pc.valid_from_utc DESC;

    IF @price_eur IS NULL
        THROW 50001, N'No price is known for this station and fuel at the given time.', 1;

    INSERT INTO dbo.sale (station_id, fuel_id, payment_method_id, sold_at_utc, liters, price_eur)
    VALUES (@station_id, @fuel_id, @payment_method_id, @sold_at_utc, @liters, @price_eur);

    SET @sale_id = SCOPE_IDENTITY();
END;
GO
