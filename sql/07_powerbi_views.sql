-- Views for Power BI.
-- Power BI imports these two views; all names, local times and periods are prepared here,
-- so the Power BI model stays small.

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE wildau_fuel;
GO

-- Sales with date and hour columns for the Power BI date table and charts
CREATE OR ALTER VIEW dbo.v_sale
AS
SELECT
    s.sale_id,
    st.brand  AS station,
    f.name    AS fuel,
    pm.name   AS payment_method,
    l.sold_at_local,
    CAST(l.sold_at_local AS date)         AS sale_date,
    DATEPART(HOUR, l.sold_at_local)       AS sale_hour,
    CASE WHEN l.sold_at_local < '2026-04-01' THEN N'Before 12:00 rule' ELSE N'After 12:00 rule' END AS period,
    s.liters,
    s.price_eur,
    s.amount_eur
FROM dbo.sale AS s
JOIN dbo.station        AS st ON st.station_id        = s.station_id
JOIN dbo.fuel           AS f  ON f.fuel_id            = s.fuel_id
JOIN dbo.payment_method AS pm ON pm.payment_method_id = s.payment_method_id
CROSS APPLY (SELECT CAST(s.sold_at_utc AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime2(0)) AS sold_at_local) AS l;
GO

-- Average price per station, fuel and hour, weighted by how many seconds each price was valid
-- in that hour. Example: 1.799 for 10 minutes and 1.759 for 50 minutes gives
-- (1.799 * 600 + 1.759 * 3000) / 3600 = 1.766.
-- The analysis period is 1 Nov 2025 - 31 Oct 2026 in Berlin time:
-- 2025-10-31 23:00 UTC up to (not including) 2026-10-31 23:00 UTC, 8,760 hours.
-- Each price period is split into the hours it touches (GENERATE_SERIES per period),
-- which is much cheaper than comparing every hour with every period.
CREATE OR ALTER VIEW dbo.v_hourly_price
AS
WITH periods AS (
    SELECT
        pp.station_id,
        pp.fuel_id,
        pp.price_eur,
        pp.valid_from_utc,
        ISNULL(pp.valid_to_utc, CAST('2026-10-31T23:00:00' AS datetime2(0))) AS valid_to_utc,
        -- start of the hour in which the price period begins
        DATEADD(HOUR, DATEDIFF(HOUR, '2000-01-01', pp.valid_from_utc), CAST('2000-01-01' AS datetime2(0))) AS first_hour_utc
    FROM dbo.v_price_period AS pp
),
pieces AS (
    -- one row per price period and hour, with the seconds of that hour the price was valid
    SELECT
        p.station_id,
        p.fuel_id,
        p.price_eur,
        h.hour_start_utc,
        DATEDIFF(SECOND,
                 CASE WHEN p.valid_from_utc > h.hour_start_utc THEN p.valid_from_utc ELSE h.hour_start_utc END,
                 CASE WHEN p.valid_to_utc < DATEADD(HOUR, 1, h.hour_start_utc) THEN p.valid_to_utc
                      ELSE DATEADD(HOUR, 1, h.hour_start_utc) END) AS seconds_valid
    FROM periods AS p
    CROSS APPLY (SELECT DATEADD(HOUR, s.value, p.first_hour_utc) AS hour_start_utc
                 FROM GENERATE_SERIES(0, DATEDIFF(HOUR, p.first_hour_utc, p.valid_to_utc)) AS s) AS h
    WHERE h.hour_start_utc < p.valid_to_utc
),
weighted AS (
    SELECT
        hour_start_utc,
        station_id,
        fuel_id,
        SUM(price_eur * seconds_valid) / 3600.0 AS avg_price_eur,
        SUM(seconds_valid)                      AS covered_seconds
    FROM pieces
    WHERE hour_start_utc >= '2025-10-31T23:00:00'
      AND hour_start_utc <  '2026-10-31T23:00:00'
    GROUP BY hour_start_utc, station_id, fuel_id
),
localised AS (
    SELECT
        w.*,
        CAST(w.hour_start_utc AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime2(0)) AS hour_start_local
    FROM weighted AS w
    WHERE w.covered_seconds = 3600   -- only hours fully covered by known prices
)
SELECT
    st.brand AS station,
    f.name   AS fuel,
    l.hour_start_local,
    CAST(l.hour_start_local AS date)   AS price_date,
    DATEPART(HOUR, l.hour_start_local) AS price_hour,
    CASE WHEN l.hour_start_local < '2026-04-01' THEN N'Before 12:00 rule' ELSE N'After 12:00 rule' END AS period,
    CAST(l.avg_price_eur AS decimal(6,4)) AS avg_price_eur,
    -- difference from the same day's average, in cents: shows the daily pattern without the price level
    CAST(100 * (l.avg_price_eur - AVG(l.avg_price_eur) OVER (PARTITION BY l.station_id, l.fuel_id,
                                                             CAST(l.hour_start_local AS date))) AS decimal(6,2)) AS diff_from_day_avg_ct
FROM localised AS l
JOIN dbo.station AS st ON st.station_id = l.station_id
JOIN dbo.fuel    AS f  ON f.fuel_id     = l.fuel_id;
GO

-- Quick check: one row per station, fuel and hour (2 * 3 * 8,760 = 52,560 with the test data)
SELECT COUNT(*) AS hourly_rows FROM dbo.v_hourly_price;

-- The 12:00 increase should now show up at hour 12 after the rule
SELECT price_hour, period, CAST(AVG(diff_from_day_avg_ct) AS decimal(4,1)) AS avg_diff_ct
FROM dbo.v_hourly_price
WHERE fuel = N'Super E10' AND price_hour IN (11, 12, 13, 19, 20)
GROUP BY price_hour, period
ORDER BY period DESC, price_hour;
GO
