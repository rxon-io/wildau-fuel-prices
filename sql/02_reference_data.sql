-- Reference data. Stations are loaded together with the price data.

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE wildau_fuel;
GO

INSERT INTO dbo.fuel (fuel_id, code, name)
VALUES (1, 'e5',     N'Super E5'),
       (2, 'e10',    N'Super E10'),
       (3, 'diesel', N'Diesel');

INSERT INTO dbo.payment_method (payment_method_id, name)
VALUES (1, N'Cash'),
       (2, N'Card'),
       (3, N'Fuel card');
GO
