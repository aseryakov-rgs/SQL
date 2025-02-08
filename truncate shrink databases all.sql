--by ASeryakov@rg-spc.ru

--truncation of service tables and truncation all databases

DECLARE @command VARCHAR(6000)
DECLARE @DBInfo TABLE (DatabaseName VARCHAR(100))

SELECT @command = 'Use [' + '?' + '] SELECT  c.name AS DatabaseName
from sys.databases c
where c.name = ' + '''' + '?' + '''' + ' and c.database_id > 4
and not name = ''tempdb'' and not name = ''master'' and not name = ''msdb''
and not name = ''model'''

INSERT INTO @DBInfo
EXEC sp_MSForEachDB @command
----
DECLARE @DatabaseDestination varchar(50);
--debug--DECLARE @ALLDB varchar(5000)
--debug--SET @ALLDB = ''
DECLARE @QUERYTEXT varchar(2048);
DECLARE curs CURSOR SCROLL FOR
-- Для ограничения количества обрабатываемых баз до 10: SELECT TOP 10 DatabaseName from @DBInfo
SELECT DatabaseName from @DBInfo
OPEN curs
FETCH NEXT FROM curs INTO @DatabaseDestination

WHILE @@FETCH_STATUS = 0
BEGIN
    --debug--SET @ALLDB = @ALLDB + '''' + @DatabaseDestination + '''' + ','
    FETCH NEXT FROM curs INTO @DatabaseDestination
-- ОСНОВНОЙ ИСПОЛНЯЮЩИЙ СКРИПТ --
SET @QUERYTEXT = 'USE ['+ @DatabaseDestination +'];

BEGIN TRY
	TRUNCATE TABLE dbo._InfoRg66844X1;
END TRY
BEGIN CATCH
    RAISERROR(''Ошибка TRUNCATE таблицы dbo._InfoRg66844X1'', 1, 1) WITH NOWAIT;
END CATCH	


DECLARE @FileName sysname = (select name from sys.database_files where type_desc = ''ROWS'');
DECLARE @TargetSize INT = (SELECT 1 + size*8./1024 FROM sys.database_files WHERE name = @FileName);
DECLARE @Factor FLOAT = .99;
DECLARE @ActualSize INT = 0;

WHILE @TargetSize > @ActualSize
BEGIN
    SET @TargetSize *= @Factor;
   DBCC SHRINKFILE(@FileName, @TargetSize);
    SET @ActualSize = (SELECT 1 + size*8./1024 FROM sys.database_files  Where name = @FileName) * 0.99; 
    DECLARE @msg VARCHAR(200) = CONCAT(''Shrink file completed. Target Size: '', 
         @TargetSize, '' MB. Actual size: '', @ActualSize, ''MB. Timestamp: '', CURRENT_TIMESTAMP);
    RAISERROR(@msg, 1, 1) WITH NOWAIT;
    WAITFOR DELAY ''00:00:01'';
END;';

--PRINT @QUERYTEXT;
EXEC sp_sqlexec @QUERYTEXT;
-- ОСНОВНОЙ ИСПОЛНЯЮЩИЙ СКРИПТ --

END
CLOSE curs;
DEALLOCATE curs;
--debug--PRINT @ALLDB
