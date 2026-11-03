-- Analysis queries. Run the whole file (F5): each block returns its own result grid.
-- Blocks 1-3 use the simulated sales, blocks 4-5 only the prices.
-- To re-run block 4 or 5 alone, first run the block that fills #hourly_price in the same window.

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE wildau_fuel;
GO

-- 1. Revenue and litres per month and station
SELECT
    FORMAT(sold_at_local, 'yyyy-MM') AS month,
    station,
    COUNT(*)                         AS fills,
    CAST(SUM(liters) AS int)         AS liters,
    SUM(amount_eur)                  AS revenue_eur,
    CAST(AVG(amount_eur) AS decimal(6,2)) AS avg_fill_eur
FROM dbo.v_sale
GROUP BY FORMAT(sold_at_local, 'yyyy-MM'), station
ORDER BY month, station;

-- 2. Fuel and payment mix: share of fills and of revenue
SELECT
    fuel,
    payment_method,
    COUNT(*) AS fills,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(5,1))               AS pct_of_fills,
    CAST(100.0 * SUM(amount_eur) / SUM(SUM(amount_eur)) OVER () AS decimal(5,1)) AS pct_of_revenue
FROM dbo.v_sale
GROUP BY fuel, payment_method
ORDER BY fuel, fills DESC;

-- 3. Busiest hours: share of fills per local hour, before and after the 12:00 rule (1 April 2026)
WITH s AS (
    SELECT DATEPART(HOUR, sold_at_local) AS local_hour,
           CASE WHEN sold_at_local < '2026-04-01' THEN 'before' ELSE 'after' END AS period
    FROM dbo.v_sale
)
SELECT
    local_hour,
    CAST(100.0 * SUM(CASE WHEN period = 'before' THEN 1 ELSE 0 END)
         / SUM(SUM(CASE WHEN period = 'before' THEN 1 ELSE 0 END)) OVER () AS decimal(4,1)) AS pct_before,
    CAST(100.0 * SUM(CASE WHEN period = 'after' THEN 1 ELSE 0 END)
         / SUM(SUM(CASE WHEN period = 'after' THEN 1 ELSE 0 END)) OVER () AS decimal(4,1))  AS pct_after
FROM s
GROUP BY local_hour
ORDER BY local_hour;
GO

-- Prices sampled at every full hour of the analysis period (8,760 hours = 365 days),
-- for every station and fuel. Used by blocks 4 and 5.
-- GENERATE_SERIES needs SQL Server 2022 (compatibility level 160).
DROP TABLE IF EXISTS #hourly_price;

WITH hours AS (
    -- 2025-10-31 23:00 UTC = 2025-11-01 00:00 in Berlin
    SELECT DATEADD(HOUR, value, CAST('2025-10-31T23:00:00' AS datetime2(0))) AS hour_utc
    FROM GENERATE_SERIES(0, 8759)
)
SELECT
    h.hour_utc,
    CAST(h.hour_utc AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime2(0)) AS hour_local,
    st.brand AS station,
    f.name   AS fuel,
    p.price_eur
INTO #hourly_price
FROM hours AS h
CROSS JOIN dbo.station AS st
CROSS JOIN dbo.fuel    AS f
CROSS APPLY (SELECT TOP (1) pc.price_eur
             FROM dbo.price_change AS pc
             WHERE pc.station_id = st.station_id
               AND pc.fuel_id = f.fuel_id
               AND pc.valid_from_utc <= h.hour_utc
             ORDER BY pc.valid_from_utc DESC) AS p;

-- 4. Price pattern over the day, before and after the 12:00 rule.
-- Shown as the difference from that day's average in cents, so that changes in the
-- overall price level do not hide the daily pattern.
WITH d AS (
    SELECT *,
           price_eur - AVG(price_eur) OVER (PARTITION BY station, fuel, CAST(hour_local AS date)) AS diff_from_day_avg
    FROM #hourly_price
)
SELECT
    DATEPART(HOUR, hour_local) AS local_hour,
    CAST(100 * AVG(CASE WHEN hour_local <  '2026-04-01' THEN diff_from_day_avg END) AS decimal(4,1)) AS before_ct,
    CAST(100 * AVG(CASE WHEN hour_local >= '2026-04-01' THEN diff_from_day_avg END) AS decimal(4,1)) AS after_ct
FROM d
WHERE fuel = N'Super E10'
GROUP BY DATEPART(HOUR, hour_local)
ORDER BY local_hour;

-- 5. Shell vs Sprint at the same hour: average difference and how often Sprint is cheaper
SELECT
    sh.fuel,
    CASE WHEN sh.hour_local < '2026-04-01' THEN 'before 12:00 rule' ELSE 'after 12:00 rule' END AS period,
    CAST(100 * AVG(sh.price_eur - sp.price_eur) AS decimal(4,2))                         AS shell_minus_sprint_ct,
    CAST(100.0 * AVG(CASE WHEN sp.price_eur < sh.price_eur THEN 1.0 ELSE 0 END) AS decimal(4,1)) AS pct_hours_sprint_cheaper
FROM #hourly_price AS sh
JOIN #hourly_price AS sp
  ON sp.hour_utc = sh.hour_utc AND sp.fuel = sh.fuel AND sp.station = N'Sprint'
WHERE sh.station = N'Shell'
GROUP BY sh.fuel, CASE WHEN sh.hour_local < '2026-04-01' THEN 'before 12:00 rule' ELSE 'after 12:00 rule' END
ORDER BY sh.fuel, period DESC;
GO
