-- Checks for the schema rules. Run after 01-03.
-- Everything happens inside one transaction that is rolled back at the end,
-- so the database stays unchanged and the script can be re-run.

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
USE wildau_fuel;
GO

BEGIN TRANSACTION;

DECLARE @station_id int, @sale_id int, @price decimal(4,3), @amount decimal(9,2), @valid_to datetime2(0);

-- Test station with two E5 prices: 1.799 from 06:00 UTC, 1.749 from 18:00 UTC
INSERT INTO dbo.station (tk_uuid, brand, name, street, post_code, city)
VALUES (NEWID(), N'TEST', N'Test station', N'Teststr.', '15745', N'Wildau');
SET @station_id = SCOPE_IDENTITY();

INSERT INTO dbo.price_change (station_id, fuel_id, valid_from_utc, price_eur)
VALUES (@station_id, 1, '2026-01-10T06:00:00', 1.799),
       (@station_id, 1, '2026-01-10T18:00:00', 1.749);

-- 1. A price of zero is rejected
BEGIN TRY
    INSERT INTO dbo.price_change (station_id, fuel_id, valid_from_utc, price_eur)
    VALUES (@station_id, 1, '2026-01-11T06:00:00', 0);
    PRINT 'FAIL 1: a price of 0 was accepted';
END TRY
BEGIN CATCH
    PRINT 'PASS 1: price 0 rejected (error ' + CAST(ERROR_NUMBER() AS varchar(10)) + ')';
END CATCH;

-- 2. The same price change cannot be loaded twice
BEGIN TRY
    INSERT INTO dbo.price_change (station_id, fuel_id, valid_from_utc, price_eur)
    VALUES (@station_id, 1, '2026-01-10T06:00:00', 1.799);
    PRINT 'FAIL 2: a duplicate price change was accepted';
END TRY
BEGIN CATCH
    PRINT 'PASS 2: duplicate price change rejected (error ' + CAST(ERROR_NUMBER() AS varchar(10)) + ')';
END CATCH;

-- 3. A sale at 12:00 gets the morning price, not the later evening price
EXEC dbo.pr_record_sale @station_id, 1, 2, 33.33, '2026-01-10T12:00:00', @sale_id OUTPUT;
SELECT @price = price_eur, @amount = amount_eur FROM dbo.sale WHERE sale_id = @sale_id;
IF @price = 1.799
    PRINT 'PASS 3: sale at 12:00 recorded with the price valid at that time (1.799)';
ELSE
    PRINT 'FAIL 3: sale recorded with price ' + ISNULL(CAST(@price AS varchar(10)), 'NULL');

-- 4. The amount is rounded to cents: 33.33 l * 1.799 EUR = 59.96067 -> 59.96
IF @amount = 59.96
    PRINT 'PASS 4: amount rounded to cents (59.96)';
ELSE
    PRINT 'FAIL 4: amount is ' + ISNULL(CAST(@amount AS varchar(20)), 'NULL');

-- 5. A sale before the first known price is rejected with error 50001
BEGIN TRY
    EXEC dbo.pr_record_sale @station_id, 1, 2, 20, '2026-01-09T12:00:00', @sale_id OUTPUT;
    PRINT 'FAIL 5: a sale without a known price was recorded';
END TRY
BEGIN CATCH
    PRINT 'PASS 5: sale without a known price rejected (error ' + CAST(ERROR_NUMBER() AS varchar(10)) + ')';
END CATCH;

-- 6. The view turns price changes into periods: the morning price is valid until 18:00
SELECT @valid_to = valid_to_utc
FROM dbo.v_price_period
WHERE station_id = @station_id AND fuel_id = 1 AND valid_from_utc = '2026-01-10T06:00:00';
IF @valid_to = '2026-01-10T18:00:00'
    PRINT 'PASS 6: price period 06:00-18:00 built with LEAD()';
ELSE
    PRINT 'FAIL 6: valid_to is ' + ISNULL(CONVERT(varchar(20), @valid_to, 120), 'NULL');

-- 7. Local time: 06:00 UTC in January is 07:00 in Berlin (CET, UTC+1)
IF EXISTS (SELECT 1 FROM dbo.v_price_period
           WHERE station_id = @station_id AND valid_from_utc = '2026-01-10T06:00:00'
             AND valid_from_local = '2026-01-10T07:00:00')
    PRINT 'PASS 7: UTC converted to Berlin time (07:00)';
ELSE
    PRINT 'FAIL 7: local time conversion is wrong';

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
PRINT 'All changes rolled back.';
GO
