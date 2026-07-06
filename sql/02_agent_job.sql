/* ============================================================
   SmartMeterDWH_Nightly_ETL – SQL Server Agent Job
   ============================================================
   Legt den Job an, der die komplette nächtliche Pipeline
   orchestriert:
     Schritt 1: SSIS-Paket 01_Load_Staging.dtsx  (CSV -> stg)
     Schritt 2: SSIS-Paket 02_Transform_Load.dtsx (stg -> dwh)
     Schritt 3: SSAS-Tabular-Modell per TMSL vollständig refreshen

   Hinweis: Dies ist eine von Hand geschriebene, funktional
   äquivalente Rekonstruktion des Jobs, der in diesem Projekt über
   die SSMS-GUI angelegt wurde. Für eine 1:1-Kopie des tatsächlich
   laufenden Jobs (inkl. exakter GUIDs) in SSMS:
   Agent Job -> Rechtsklick -> "Auftrag skripten als" -> CREATE
   und den Inhalt hier ersetzen.

   Vor Ausführung anpassen:
   - Pfad zu DTExec.exe (Versionsnummer je nach SQL-Server-Version,
     z.B. 130 = 2016, 140 = 2017, 150 = 2019, 160 = 2022)
   - Paketpfade, falls nicht unter C:\SSIS_Packages\...
   - SSAS-Servername/-instanz (hier: localhost\TAB)
   ============================================================ */

USE msdb;
GO

DECLARE @jobId BINARY(16);
DECLARE @ReturnCode INT = 0;

-- ------------------------------------------------------------
-- Job anlegen
-- ------------------------------------------------------------
EXEC @ReturnCode = dbo.sp_add_job
    @job_name = N'SmartMeterDWH_Nightly_ETL',
    @enabled = 1,
    @description = N'Nächtliche ETL-Pipeline: Staging laden, Star Schema transformieren, SSAS-Tabular-Modell refreshen.',
    @category_name = N'[Uncategorized (Local)]',
    @owner_login_name = N'sa',
    @job_id = @jobId OUTPUT;

-- ------------------------------------------------------------
-- Schritt 1: Staging laden
-- ------------------------------------------------------------
EXEC dbo.sp_add_jobstep
    @job_id = @jobId,
    @step_id = 1,
    @step_name = N'01 - Load Staging',
    @subsystem = N'CmdExec',
    @command = N'"C:\Program Files\Microsoft SQL Server\130\DTS\Binn\DTExec.exe" /F "C:\SSIS_Packages\SmartMeterDemoDWH_ETL\01_Load_Staging.dtsx"',
    @on_success_action = 3,   -- weiter zu Schritt 2
    @on_fail_action = 2,      -- Job abbrechen, Fehler melden
    @retry_attempts = 0;

-- ------------------------------------------------------------
-- Schritt 2: Transform & Load ins Star Schema
-- ------------------------------------------------------------
EXEC dbo.sp_add_jobstep
    @job_id = @jobId,
    @step_id = 2,
    @step_name = N'02 - Transform Load DWH',
    @subsystem = N'CmdExec',
    @command = N'"C:\Program Files\Microsoft SQL Server\130\DTS\Binn\DTExec.exe" /F "C:\SSIS_Packages\SmartMeterDemoDWH_ETL\02_Transform_Load.dtsx"',
    @on_success_action = 3,   -- weiter zu Schritt 3
    @on_fail_action = 2,
    @retry_attempts = 0;

-- ------------------------------------------------------------
-- Schritt 3: SSAS Tabular Modell vollständig refreshen (TMSL)
-- ------------------------------------------------------------
EXEC dbo.sp_add_jobstep
    @job_id = @jobId,
    @step_id = 3,
    @step_name = N'03 - SSAS Full Refresh',
    @subsystem = N'ANALYSISCOMMAND',
    @command = N'{
  "refresh": {
    "type": "full",
    "objects": [
      { "database": "SmartMeterDemoDWH_SSAS" }
    ]
  }
}',
    @server = N'localhost\TAB',
    @on_success_action = 1,   -- Job erfolgreich beenden
    @on_fail_action = 2,
    @retry_attempts = 0;

EXEC dbo.sp_update_job
    @job_id = @jobId,
    @start_step_id = 1;

-- ------------------------------------------------------------
-- Zeitplan: täglich 02:00 Uhr
-- ------------------------------------------------------------
EXEC dbo.sp_add_jobschedule
    @job_id = @jobId,
    @name = N'Taeglich_0200',
    @enabled = 1,
    @freq_type = 4,             -- täglich
    @freq_interval = 1,         -- jeden Tag
    @active_start_time = 020000;

-- ------------------------------------------------------------
-- Job dem lokalen Server zuweisen
-- ------------------------------------------------------------
EXEC dbo.sp_add_jobserver
    @job_id = @jobId,
    @server_name = N'(local)';
GO
