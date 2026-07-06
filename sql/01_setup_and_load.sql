/* ============================================================
   Smart Meter Demo DWH – konsolidiertes SQL-Skript
   ============================================================
   Dieses Skript dokumentiert den Aufbau der Datenbank in vier
   Teilen:
     1. Datenbank & Schemata
     2. Tabellen (stg- und dwh-Schema)
     3. Ladeskripte der Kalender-/statischen Dimensionen
     4. Ladeskripte der datengetriebenen Dimensionen + Fact-Tabelle

   Hinweis Teil 2: Die exakten CREATE-TABLE-Skripte (inkl. aller
   Spaltenbreiten, die im Projektverlauf mehrfach angepasst wurden)
   bitte direkt aus SSMS exportieren, damit sie 1:1 mit der
   tatsächlich laufenden Datenbank übereinstimmen:
   SSMS → Datenbank → Aufgaben → Skripts generieren →
   stg- und dwh-Schema auswählen → "Nur Schema" → Datei speichern
   und den Inhalt hier unter Abschnitt 2 einfügen.
   ============================================================ */

-- ============================================================
-- 1. Datenbank & Schemata
-- ============================================================
CREATE DATABASE SmartMeterDemoDWH;
GO

USE SmartMeterDemoDWH;
GO

CREATE SCHEMA stg;
GO
CREATE SCHEMA dwh;
GO

-- ============================================================
-- 2. Tabellen (stg- und dwh-Schema)
-- ============================================================
-- >>> HIER: per SSMS "Skripts generieren" exportierte CREATE-TABLE-
-- >>> Anweisungen für alle stg.* und dwh.* Tabellen einfügen.
-- >>> (5 stg-Tabellen: HouseholdInfo, WeatherHourly, AcornDetails,
-- >>>  BankHolidays, HalfHourlyConsumption; 6 dwh-Tabellen:
-- >>>  Dim_Household, Dim_Date, Dim_Time, Dim_Weather, Dim_Tariff,
-- >>>  Fact_Consumption inkl. Foreign-Key-Constraints)

-- ============================================================
-- 3. Kalender-/statische Dimensionen laden (einmalig)
-- ============================================================

-- Dim_Tariff (2 Zeilen)
INSERT INTO dwh.Dim_Tariff (TariffKey, TariffType)
VALUES (1, 'Std'), (2, 'ToU');
GO

-- Dim_Time (48 Zeilen, ein Halbstunden-Slot pro Tag)
;WITH TimeSeq AS (
    SELECT 0 AS SlotNumber
    UNION ALL
    SELECT SlotNumber + 1 FROM TimeSeq WHERE SlotNumber < 47
)
INSERT INTO dwh.Dim_Time (TimeKey, HalfHourSlot, HourNum, MinuteNum, DaySegment)
SELECT
    SlotNumber AS TimeKey,
    FORMAT(DATEADD(MINUTE, SlotNumber * 30, CAST('00:00' AS TIME)), 'hh\:mm') AS HalfHourSlot,
    SlotNumber / 2 AS HourNum,
    (SlotNumber % 2) * 30 AS MinuteNum,
    CASE
        WHEN SlotNumber / 2 BETWEEN 6 AND 11  THEN 'Morgen'
        WHEN SlotNumber / 2 BETWEEN 12 AND 17 THEN 'Nachmittag'
        WHEN SlotNumber / 2 BETWEEN 18 AND 22 THEN 'Abend'
        ELSE 'Nacht'
    END AS DaySegment
FROM TimeSeq
OPTION (MAXRECURSION 0);
GO

-- Dim_Date (1.461 Zeilen, Kalendertage 2011-01-01 bis 2014-12-31)
-- Hinweis: JOIN auf stg.BankHolidays ggf. an tatsächliche Spaltennamen
-- anpassen (hier angenommen: HolidayDate, HolidayName).
;WITH DateSeq AS (
    SELECT CAST('2011-01-01' AS DATE) AS FullDate
    UNION ALL
    SELECT DATEADD(DAY, 1, FullDate)
    FROM DateSeq
    WHERE FullDate < '2014-12-31'
)
INSERT INTO dwh.Dim_Date (DateKey, FullDate, Year, Quarter, Month, MonthName, Day, Weekday, WeekdayName, IsWeekend, IsHoliday, HolidayName)
SELECT
    CONVERT(INT, FORMAT(d.FullDate, 'yyyyMMdd'))   AS DateKey,
    d.FullDate,
    YEAR(d.FullDate)                                AS Year,
    DATEPART(QUARTER, d.FullDate)                   AS Quarter,
    MONTH(d.FullDate)                                AS Month,
    DATENAME(MONTH, d.FullDate)                      AS MonthName,
    DAY(d.FullDate)                                  AS Day,
    DATEPART(WEEKDAY, d.FullDate)                    AS Weekday,
    DATENAME(WEEKDAY, d.FullDate)                    AS WeekdayName,
    CASE WHEN DATEPART(WEEKDAY, d.FullDate) IN (1,7) THEN 1 ELSE 0 END AS IsWeekend,
    CASE WHEN bh.HolidayDate IS NOT NULL THEN 1 ELSE 0 END AS IsHoliday,
    bh.HolidayName
FROM DateSeq d
LEFT JOIN stg.BankHolidays bh ON bh.HolidayDate = d.FullDate
OPTION (MAXRECURSION 0);
GO

-- ============================================================
-- 4. Datengetriebene Dimensionen + Fact-Tabelle laden
--    (entspricht 02_Transform_Load.dtsx – jeweils vorher DELETE
--    auf die Zieltabelle, siehe README/SSIS-Paket)
-- ============================================================

-- Dim_Household (5.566 Zeilen)
INSERT INTO dwh.Dim_Household (HouseholdId, TariffType, Acorn, AcornGrouped)
SELECT DISTINCT HouseholdId, TariffType, Acorn, AcornGrouped
FROM stg.HouseholdInfo;
GO

-- Dim_Weather (21.165 Zeilen)
INSERT INTO dwh.Dim_Weather (WeatherDateTime, Temperature, ApparentTemperature, Humidity, WindSpeed, PrecipType, Summary)
SELECT
    TRY_CAST(ReadingTime AS DATETIME2),
    TRY_CAST(Temperature AS DECIMAL(5,2)),
    TRY_CAST(ApparentTemperature AS DECIMAL(5,2)),
    TRY_CAST(Humidity AS DECIMAL(5,2)),
    TRY_CAST(WindSpeed AS DECIMAL(5,2)),
    PrecipType,
    Summary
FROM stg.WeatherHourly;
GO

-- Fact_Consumption (5.606.314 Zeilen)
INSERT INTO dwh.Fact_Consumption (HouseholdKey, DateKey, TimeKey, WeatherKey, TariffKey, EnergyKWH)
SELECT
    dh.HouseholdKey,
    CONVERT(INT, FORMAT(rt.ReadingDateTime, 'yyyyMMdd')),
    (DATEPART(HOUR, rt.ReadingDateTime) * 2) + (DATEPART(MINUTE, rt.ReadingDateTime) / 30),
    dw.WeatherKey,
    dt.TariffKey,
    CASE WHEN LTRIM(RTRIM(hc.EnergyKWH)) = 'Null' THEN NULL ELSE TRY_CAST(hc.EnergyKWH AS DECIMAL(10,4)) END
FROM stg.HalfHourlyConsumption hc
CROSS APPLY (SELECT TRY_CAST(hc.ReadingTime AS DATETIME2) AS ReadingDateTime) rt
INNER JOIN dwh.Dim_Household dh ON dh.HouseholdId = hc.HouseholdId
LEFT JOIN dwh.Dim_Weather dw ON dw.WeatherDateTime = DATEADD(SECOND, -DATEPART(SECOND, rt.ReadingDateTime), DATEADD(MINUTE, -DATEPART(MINUTE, rt.ReadingDateTime), rt.ReadingDateTime))
INNER JOIN dwh.Dim_Tariff dt ON dt.TariffType = dh.TariffType
WHERE rt.ReadingDateTime IS NOT NULL;
GO
