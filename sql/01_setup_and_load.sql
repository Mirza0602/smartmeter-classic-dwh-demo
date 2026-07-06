/* ============================================================
   Smart Meter Demo DWH – konsolidiertes SQL-Skript
   ============================================================
   Dieses Skript dokumentiert den Aufbau der Datenbank in vier
   Teilen:
     1. Datenbank & Schemata
     2. Tabellen (stg- und dwh-Schema)
     3. Ladeskripte der Kalender-/statischen Dimensionen
     4. Ladeskripte der datengetriebenen Dimensionen + Fact-Tabelle

   Hinweis Teil 2: Die CREATE-TABLE-Skripte sind eine Rekonstruktion
   auf Basis der tatsächlich verwendeten Spalten in den Ladeskripten
   (Abschnitt 3/4) sowie der Kaggle-Rohdatenstruktur. Vor
   produktivem Einsatz bitte gegen die echte SSMS-Ausgabe prüfen:
   SSMS → Datenbank → Aufgaben → Skripts generieren →
   stg- und dwh-Schema auswählen → "Nur Schema" → Datei speichern,
   und bei Abweichungen (insb. Spaltenbreiten, die im Projektverlauf
   mehrfach angepasst wurden) den Inhalt hier ersetzen.
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

-- ---------- stg-Schema: Staging-Tabellen (Rohimport, bewusst locker typisiert) ----------

CREATE TABLE stg.HouseholdInfo (
    HouseholdId     VARCHAR(20)     NULL,
    TariffType      VARCHAR(10)     NULL,
    Acorn           VARCHAR(20)     NULL,
    AcornGrouped    VARCHAR(20)     NULL
);
GO

CREATE TABLE stg.WeatherHourly (
    ReadingTime             VARCHAR(50)     NULL,
    Temperature             VARCHAR(20)     NULL,
    ApparentTemperature     VARCHAR(20)     NULL,
    Humidity                VARCHAR(20)     NULL,
    WindSpeed               VARCHAR(20)     NULL,
    PrecipType              VARCHAR(20)     NULL,
    Summary                 VARCHAR(200)    NULL
);
GO

-- Hinweis: Original-Kaggle-Datei "acorn_details.csv" enthält zusätzlich
-- prozentuale Kennzahlen je Acorn-Gruppe, die im aktuellen Ladeskript
-- (Abschnitt 3/4) nicht referenziert werden. Spaltenliste hier daher
-- bewusst minimal gehalten und bei Bedarf aus SSMS-Export ergänzen.
CREATE TABLE stg.AcornDetails (
    AcornCategory       VARCHAR(20)     NULL,
    AcornGroup          VARCHAR(20)     NULL,
    ReferenceCategories VARCHAR(200)    NULL
);
GO

CREATE TABLE stg.BankHolidays (
    HolidayDate     DATE            NULL,
    HolidayName     VARCHAR(100)    NULL
);
GO

CREATE TABLE stg.HalfHourlyConsumption (
    HouseholdId     VARCHAR(20)     NULL,
    ReadingTime     VARCHAR(50)     NULL,
    EnergyKWH       VARCHAR(20)     NULL
);
GO

-- ---------- dwh-Schema: Star Schema ----------

CREATE TABLE dwh.Dim_Tariff (
    TariffKey       INT             NOT NULL PRIMARY KEY,
    TariffType      VARCHAR(10)     NOT NULL
);
GO

CREATE TABLE dwh.Dim_Time (
    TimeKey         INT             NOT NULL PRIMARY KEY,
    HalfHourSlot    VARCHAR(5)      NOT NULL,
    HourNum         TINYINT         NOT NULL,
    MinuteNum       TINYINT         NOT NULL,
    DaySegment      VARCHAR(20)     NOT NULL
);
GO

CREATE TABLE dwh.Dim_Date (
    DateKey         INT             NOT NULL PRIMARY KEY,
    FullDate        DATE            NOT NULL,
    Year            SMALLINT        NOT NULL,
    Quarter         TINYINT         NOT NULL,
    Month           TINYINT         NOT NULL,
    MonthName       VARCHAR(20)     NOT NULL,
    Day             TINYINT         NOT NULL,
    Weekday         TINYINT         NOT NULL,
    WeekdayName     VARCHAR(20)     NOT NULL,
    IsWeekend       BIT             NOT NULL,
    IsHoliday       BIT             NOT NULL,
    HolidayName     VARCHAR(100)    NULL
);
GO

CREATE TABLE dwh.Dim_Household (
    HouseholdKey    INT IDENTITY(1,1)  NOT NULL PRIMARY KEY,
    HouseholdId     VARCHAR(20)        NOT NULL,
    TariffType      VARCHAR(10)        NULL,
    Acorn           VARCHAR(20)        NULL,
    AcornGrouped    VARCHAR(20)        NULL
);
GO

CREATE TABLE dwh.Dim_Weather (
    WeatherKey              INT IDENTITY(1,1)  NOT NULL PRIMARY KEY,
    WeatherDateTime         DATETIME2(0)       NOT NULL,
    Temperature             DECIMAL(5,2)       NULL,
    ApparentTemperature     DECIMAL(5,2)       NULL,
    Humidity                DECIMAL(5,2)       NULL,
    WindSpeed               DECIMAL(5,2)       NULL,
    PrecipType              VARCHAR(20)        NULL,
    Summary                 VARCHAR(200)       NULL
);
GO

CREATE TABLE dwh.Fact_Consumption (
    FactKey         BIGINT IDENTITY(1,1)   NOT NULL PRIMARY KEY,
    HouseholdKey    INT                    NOT NULL,
    DateKey         INT                    NOT NULL,
    TimeKey         INT                    NOT NULL,
    WeatherKey      INT                    NULL,
    TariffKey       INT                    NOT NULL,
    EnergyKWH       DECIMAL(10,4)          NULL,
    CONSTRAINT FK_Fact_Household FOREIGN KEY (HouseholdKey) REFERENCES dwh.Dim_Household (HouseholdKey),
    CONSTRAINT FK_Fact_Date      FOREIGN KEY (DateKey)      REFERENCES dwh.Dim_Date (DateKey),
    CONSTRAINT FK_Fact_Time      FOREIGN KEY (TimeKey)      REFERENCES dwh.Dim_Time (TimeKey),
    CONSTRAINT FK_Fact_Weather   FOREIGN KEY (WeatherKey)   REFERENCES dwh.Dim_Weather (WeatherKey),
    CONSTRAINT FK_Fact_Tariff    FOREIGN KEY (TariffKey)    REFERENCES dwh.Dim_Tariff (TariffKey)
);
GO

-- Unterstützende Indizes auf den FK-Spalten der Fact-Tabelle
-- (Fremdschlüssel werden in SQL Server nicht automatisch indiziert)
CREATE NONCLUSTERED INDEX IX_Fact_Household ON dwh.Fact_Consumption (HouseholdKey);
CREATE NONCLUSTERED INDEX IX_Fact_Date      ON dwh.Fact_Consumption (DateKey);
CREATE NONCLUSTERED INDEX IX_Fact_Weather   ON dwh.Fact_Consumption (WeatherKey);
GO

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
