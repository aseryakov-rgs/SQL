/**********************************************************************

    sp_MyProc � Saves the live execution plan (Live Query Plan) to a file.
    Source:   https://github.com/aseryakov-rgs/SQL/tree/main/LiveQueryPlanMSSQL
    Version:  1.2.0  (2026-10-22)
    Author:   Aleksandr Seryakov aleksandr.rgspc@gmail.com

    SPDX-License-Identifier: MIT
    Copyright (c) 2026 Aleksandr Seryakov

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction ... (full text MIT)

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND ...
    Full license text: https://github.com/aseryakov-rgs/SQL/tree/main/LiveQueryPlanMSSQL/LICENSE.txt

  Saves the live execution plan (Live Query Plan) to a file.
  If there is no data in sys.dm_exec_query_profiles, the script automatically
 creates a temporary XE session with query_post_execution_showplan,
 collects the plan, and deletes the session.

 Requires:
 - VIEW SERVER STATE, ALTER ANY EVENT SESSION permissions
 - xp_cmdshell enabled (sp_configure 'xp_cmdshell', 1)
 - the directory for saving exists and is accessible to the SQL Server service
  ��������� ����� ���� ���������� (Live Query Plan) � ����.
  ���� � sys.dm_exec_query_profiles ��� ������, ������ �������������
  ������ ��������� XE-����� � query_post_execution_showplan,
  �������� ���� � ������� �����.

  �������:
    - ����� VIEW SERVER STATE, ALTER ANY EVENT SESSION
    - ���������� xp_cmdshell (sp_configure 'xp_cmdshell', 1)
    - ������� ��� ���������� ���������� � �������� ������ SQL Server
**********************************************************************/

SET NOCOUNT ON;

------------------------------------------------------------------
-- 1. ��������� (��� ������������� ��������)
------------------------------------------------------------------
DECLARE @SessionId      INT           = 0;                    -- 0 = ��� ������, ����� ���������� session_id
DECLARE @DatabaseName   SYSNAME       = N'DBName';        -- <-- ��� ����� ����
DECLARE @OutputDir      NVARCHAR(400) = N'F:\MSSQL\Plans\';    -- ������� ������ ������������
DECLARE @Timestamp      NVARCHAR(20)  = REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(19), GETDATE(), 120), '-', ''), ':', ''), ' ', '_');
DECLARE @PlanFile       NVARCHAR(500);
DECLARE @MetricsFile    NVARCHAR(500);
DECLARE @SqlFile        NVARCHAR(500);
DECLARE @Cmd            NVARCHAR(4000);
DECLARE @DirCheckCmd    NVARCHAR(4000);
DECLARE @PlanXml        XML;
DECLARE @SqlText        NVARCHAR(MAX);
DECLARE @CurSessionId   INT;
DECLARE @ErrMsg         NVARCHAR(2048);

-- ��� ���������� XE-�������
DECLARE @XeSessionName  SYSNAME       = N'LivePlanCapture_' + @Timestamp;
DECLARE @XeCreated      BIT           = 0;
DECLARE @XeCmd          NVARCHAR(MAX);

------------------------------------------------------------------
-- 2. �������� �������� (����� xp_cmdshell + if exist)
------------------------------------------------------------------
IF RIGHT(@OutputDir, 1) <> N'\' SET @OutputDir = @OutputDir + N'\';

DECLARE @DirCheck TABLE (output NVARCHAR(4000));

SET @DirCheckCmd = N'if exist "' + @OutputDir + N'." (echo EXISTS) else (echo MISSING)';
INSERT INTO @DirCheck
EXEC master.dbo.xp_cmdshell @DirCheckCmd;

IF NOT EXISTS (SELECT 1 FROM @DirCheck WHERE output = N'EXISTS')
BEGIN
    SET @ErrMsg = N'������� ' + @OutputDir + N' �� ���������� ��� ���������� ������� ������ ������ SQL Server. �������� ��� ������� � ��������� �����.';
    RAISERROR(@ErrMsg, 16, 1);
    RETURN;
END;

------------------------------------------------------------------
-- 3. ������� ����� ������ �� DMV (�������� ������������)
------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Profiles') IS NOT NULL DROP TABLE #Profiles;

CREATE TABLE #Profiles
(
    session_id              INT,
    request_id              INT,
    node_id                 INT,
    physical_operator_name  NVARCHAR(256),
    thread_id               INT,
    row_count               BIGINT,
    estimate_row_count      BIGINT,
    elapsed_time_ms         BIGINT,
    cpu_time_ms             BIGINT,
    plan_handle             VARBINARY(64),
    sql_handle              VARBINARY(64)
);

------------------------------------------------------------------
-- 4. ������ �������: ������� ������ ���� �����
------------------------------------------------------------------
INSERT INTO #Profiles
SELECT
    qp.session_id,
    qp.request_id,
    qp.node_id,
    qp.physical_operator_name,
    qp.thread_id,
    qp.row_count,
    qp.estimate_row_count,
    qp.elapsed_time_ms,
    qp.cpu_time_ms,
    qp.plan_handle,
    qp.sql_handle
FROM sys.dm_exec_query_profiles AS qp
JOIN sys.dm_exec_sessions      AS s  ON s.session_id = qp.session_id
JOIN sys.databases             AS d  ON d.database_id = s.database_id
WHERE (@SessionId = 0 OR qp.session_id = @SessionId)
  AND d.name = @DatabaseName;

------------------------------------------------------------------
-- 5. ���� ������ ��� � ������ ��������� XE-�����
------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM #Profiles)
BEGIN
    PRINT N'������ � sys.dm_exec_query_profiles ���. ������ ��������� XE-�����...';

    SET @XeCmd = N'
    CREATE EVENT SESSION [' + @XeSessionName + N'] ON SERVER
    ADD EVENT sqlserver.query_post_execution_showplan
    (
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.session_id)
        WHERE (sqlserver.database_name = N''' + @DatabaseName + N''')
    )
    ADD TARGET package0.ring_buffer
    WITH (MAX_DISPATCH_LATENCY = 1 SECONDS, STARTUP_STATE = OFF);
    ';

    BEGIN TRY
        EXEC sp_executesql @XeCmd;

        SET @XeCmd = N'ALTER EVENT SESSION [' + @XeSessionName + N'] ON SERVER STATE = START;';
        EXEC sp_executesql @XeCmd;

        SET @XeCreated = 1;
        PRINT N'XE-����� ' + @XeSessionName + N' ������ � �������.';
    END TRY
    BEGIN CATCH
        SET @ErrMsg = N'�� ������� ������� XE-�����: ' + ERROR_MESSAGE();
        RAISERROR(@ErrMsg, 16, 1);
        RETURN;
    END CATCH;

    -- ��� ������ ����� �������� ������ (����� ��������� ��� �������������)
    WAITFOR DELAY '00:00:05';

    ------------------------------------------------------------------
    -- ��������� ������� ����� ������ ����� ��������� XE
    ------------------------------------------------------------------
    INSERT INTO #Profiles
    SELECT
        qp.session_id,
        qp.request_id,
        qp.node_id,
        qp.physical_operator_name,
        qp.thread_id,
        qp.row_count,
        qp.estimate_row_count,
        qp.elapsed_time_ms,
        qp.cpu_time_ms,
        qp.plan_handle,
        qp.sql_handle
    FROM sys.dm_exec_query_profiles AS qp
    JOIN sys.dm_exec_sessions      AS s  ON s.session_id = qp.session_id
    JOIN sys.databases             AS d  ON d.database_id = s.database_id
    WHERE (@SessionId = 0 OR qp.session_id = @SessionId)
      AND d.name = @DatabaseName;
END;

------------------------------------------------------------------
-- 6. ���� ������ �� ����� ��� � �������� � �������
------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM #Profiles)
BEGIN
    -- ������� ��������� XE-�����, ���� ���������
    IF @XeCreated = 1
    BEGIN
        BEGIN TRY
            SET @XeCmd = N'ALTER EVENT SESSION [' + @XeSessionName + N'] ON SERVER STATE = STOP;';
            EXEC sp_executesql @XeCmd;
            SET @XeCmd = N'DROP EVENT SESSION [' + @XeSessionName + N'] ON SERVER;';
            EXEC sp_executesql @XeCmd;
        END TRY
        BEGIN CATCH
            PRINT N'�� ������� ������� XE-�����: ' + ERROR_MESSAGE();
        END CATCH;
    END;

    SET @ErrMsg = N'��� ������ � sys.dm_exec_query_profiles ��� �� ' + @DatabaseName 
                + N' ���� ����� ��������� XE-������. ���������, ��� ������������� ������ �����������, � ��������� �������.';
    RAISERROR(@ErrMsg, 16, 1);
    RETURN;
END;

------------------------------------------------------------------
-- 7. ���������� ������ � ������ �� ������ ������
------------------------------------------------------------------
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT session_id FROM #Profiles ORDER BY session_id;

OPEN cur;
FETCH NEXT FROM cur INTO @CurSessionId;

WHILE @@FETCH_STATUS = 0
BEGIN
    ------------------------------------------------------------------
    -- 7.1. XML-����
    ------------------------------------------------------------------
    SET @PlanXml = NULL;

    SELECT TOP (1) @PlanXml = (SELECT query_plan FROM sys.dm_exec_query_plan(plan_handle))
    FROM #Profiles
    WHERE session_id = @CurSessionId
      AND plan_handle IS NOT NULL;

    IF @PlanXml IS NOT NULL
    BEGIN
        SET @PlanFile = @OutputDir + N'LivePlan_' + @Timestamp + N'_sid' + CAST(@CurSessionId AS NVARCHAR(10)) + N'.sqlplan';

        SET @Cmd = N'bcp "SELECT (SELECT query_plan FROM sys.dm_exec_query_plan(0x' 
                 + CONVERT(NVARCHAR(MAX), (SELECT TOP 1 plan_handle FROM #Profiles WHERE session_id = @CurSessionId AND plan_handle IS NOT NULL), 2)
                 + N')) AS XML" queryout "' + @PlanFile + N'" -w -T -S ' + @@SERVERNAME + N' -d master';
        EXEC master.dbo.xp_cmdshell @Cmd, no_output;
    END

    ------------------------------------------------------------------
    -- 7.2. ������� ���������� (CSV)
    ------------------------------------------------------------------
    SET @MetricsFile = @OutputDir + N'LiveMetrics_' + @Timestamp + N'_sid' + CAST(@CurSessionId AS NVARCHAR(10)) + N'.csv';

    DECLARE @Csv NVARCHAR(MAX) = N'';
    SELECT @Csv = @Csv + 
        CAST(session_id AS NVARCHAR(20)) + N',' +
        CAST(request_id AS NVARCHAR(20)) + N',' +
        CAST(node_id AS NVARCHAR(20)) + N',' +
        ISNULL(physical_operator_name, N'') + N',' +
        CAST(thread_id AS NVARCHAR(20)) + N',' +
        CAST(row_count AS NVARCHAR(20)) + N',' +
        CAST(estimate_row_count AS NVARCHAR(20)) + N',' +
        CAST(elapsed_time_ms AS NVARCHAR(20)) + N',' +
        CAST(cpu_time_ms AS NVARCHAR(20)) + CHAR(13) + CHAR(10)
    FROM #Profiles
    WHERE session_id = @CurSessionId
    ORDER BY node_id, thread_id;

    SET @Csv = N'session_id,request_id,node_id,physical_operator_name,thread_id,row_count,estimate_row_count,elapsed_time_ms,cpu_time_ms'
             + CHAR(13) + CHAR(10) + @Csv;

    ------------------------------------------------------------------
    -- 7.3. SQL-����� �������
    ------------------------------------------------------------------
    SET @SqlText = NULL;

    SELECT TOP (1) @SqlText = (SELECT text FROM sys.dm_exec_sql_text(sql_handle))
    FROM #Profiles
    WHERE session_id = @CurSessionId
      AND sql_handle IS NOT NULL;

    IF @SqlText IS NOT NULL
    BEGIN
        SET @SqlFile = @OutputDir + N'LiveSQL_' + @Timestamp + N'_sid' + CAST(@CurSessionId AS NVARCHAR(10)) + N'.sql';
        SET @Cmd = N'bcp "SELECT N'''' + REPLACE(''' 
                 + REPLACE(REPLACE(@SqlText, '''', ''''''), CHAR(13), '''''+CHAR(13)+''''')
                 + N''', '''''', '''''''')" queryout "' + @SqlFile + N'" -w -T -S ' + @@SERVERNAME + N' -d master';
        EXEC master.dbo.xp_cmdshell @Cmd, no_output;
    END

    FETCH NEXT FROM cur INTO @CurSessionId;
END

CLOSE cur;
DEALLOCATE cur;

------------------------------------------------------------------
-- 8. �������� ���������� XE-������ (���� ���������)
------------------------------------------------------------------
IF @XeCreated = 1
BEGIN
    BEGIN TRY
        SET @XeCmd = N'ALTER EVENT SESSION [' + @XeSessionName + N'] ON SERVER STATE = STOP;';
        EXEC sp_executesql @XeCmd;
        SET @XeCmd = N'DROP EVENT SESSION [' + @XeSessionName + N'] ON SERVER;';
        EXEC sp_executesql @XeCmd;
        PRINT N'��������� XE-����� ' + @XeSessionName + N' �����.';
    END TRY
    BEGIN CATCH
        PRINT N'�� ������� ������� XE-�����: ' + ERROR_MESSAGE();
    END CATCH;
END;

PRINT N'������. ����� ��������� � ' + @OutputDir;