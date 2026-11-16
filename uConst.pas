unit uConst;

interface

const
  APP_FOLDER = 'MSADataPump';

const
  STargetDBMSServerName = 'Target_DBMS_ServerName';
  STargetDBMSServerPort = 'Target_DBMS_ServerPort';
  STargetDBName = 'Target_DatabaseName';
  STargetDBUserName = 'Target_DatabaseUserName';
  STargetDBPass = 'Target_DatabasePassword';
  SSourceDBMSServerName = 'Source_DBMSServerName';
  SSourceDBMSServerPort = 'Source_DBMS_ServerPort';
  SSourceDBName = 'Source_DatabaseName';
  SSourceDBUserName = 'Source_DatabaseUserName';
  SSourceDBPass = 'Source_DatabasePassword';
  SDefaultTargetDBMSServerName = '10.88.58.11';
  SDefaultTargetDBMSServerPort = '1433';
  SDefaultTargetDBName = 'AIS_Data_UES';
  SDefaultTargetDBUserName = '1C_User';
  SDefaultTargetDBPass = 'W6JHxH~m4321';
  SDefaultSourceDBMSServerName = '10.78.6.16';
  SDefaultSourceDBMSServerPort = '1521';
  SDefaultSourceDBName = 'bfl_vostok';
  SDefaultSourceDBUserName = 'UES_VOSTOK_INTEGR';
  SDefaultSourceDBPass = 'dsfUUBd2#t';
  SLogFileName = 'msadatapump_log.db';
  SConfigFileName = 'msadatapump_config.db';
  SSourceOptions = 'SourceOptions';
  SIgnoreTables = 'IgnoreTables';
  STargetOptions = 'TargetOptions';
  SSchemaNames = 'SchemaNames';
  SDefaultSchemaNames = 'tiger;';
  STablesList = 'TablesList';
  STablesListMask = 'TablesListMask';
  SDefaultTablesListMask = '';
  SPumpOptions = 'PumpOptions';
  SPumpIntervalSec = 'PumpIntervalSec';
  SDefaultPumpIntervalSec = '60';
  SPumpWorkerCount = 'WorkerCount';
  SDefaultPumpWorkerCount = '5';
  SPumpGapFillEnabled = 'GapFillEnabled';
  SPumpGapFillMask = 'GapFillMask';
  SDefaultPumpGapFillEnabled = '0';
  SDefaultPumpGapFillMask = '';
  SPumpGapFillChunkSize = 'GapFillChunkSize';
  SDefaultPumpGapFillChunkSize = '100000';
  SPumpGapFillWorkerCount = 'GapFillWorkerCount';
  SDefaultPumpGapFillWorkerCount = '5';
  SPumpGapFillIntervalSec = 'GapFillIntervalSec';
  SDefaultPumpGapFillIntervalSec = '0';
  SSpecialDataSources = 'SpecialDataSources';
  SSpecialSelectSQL = 'SelectSQL';
  SSpecialIntervalSec = 'IntervalSec';
  SSpecialEnabled = 'Enabled';
  SDefaultSpecialIntervalSec = '0';
  SDefaultSpecialEnabled = '1';
  SSpecialCheckExists = 'CheckExists';
  SDefaultSpecialCheckExists = '1';
  SSpecialCommitEvery = 'CommitEvery';
  SDefaultSpecialCommitEvery = '10000';
  SSpecialIndexSeparator = ' #';
  SSpecialExampleSuffix = ' (пример)';
  SSpecialExampleTableName = 'TIGER.CARD_CALC';
  CReloadConfigTimer: Integer = 10 * 60 * 1000;
  DefaultPumpIntervalSec: integer = 60;
  DefaultPumpWorkerCount: integer = 5;
  DefaultTargetDBMSServerPort: integer = 1433;
  DefaultSourceDBMSServerPort: integer = 1521;
  DefaultPumpGapFillChunkSize: Integer = 100000;
  DefaultPumpGapFillWorkerCount: Integer = 5;
  DefaultPumpGapFillIntervalSec: Integer = 0;
  DefaultSpecialIntervalSec: Integer = 0;
  SUpdateTables = 'UpdateTables';
  SDefaultUpdateTables = '';
  SUpdateIntervalSec = 'UpdateIntervalSec';
  SDefaultUpdateIntervalSec = '0';
  SUpdateWorkerCount = 'UpdateWorkerCount';
  SDefaultUpdateWorkerCount = '5';
  DefaultUpdateWorkerCount: Integer = 5;
  DefaultUpdateIntervalSec: Integer = 0;
  CRLF = #13#10;
  ServiceDescr = 'MSA DataPump service';
  SPQSection = 'PQ';
  SPQSelectSQL = 'SelectSQL';
  SPQParamNames = 'ParamNames';
  SPQParamValues = 'ParamValues';
  SPQTableName = 'TableName';
  SPQChunkSize = 'ChunkSize';
  SPQCommitEvery = 'CommitEvery';
  SPQEnabled = 'Enabled';
  SPQIntervalSec = 'IntervalSec';
  SPQProgressEverySec = 'PQProgressEverySec';
  SPQMaxWorkers = 'PQMaxConcurrentWorkers';
  SPQTotalRows = 'TotalRows';
  SPQMinPK = 'MinPK';
  SPQMaxPK = 'MaxPK';
  SPQCountSQL = 'CountSQL';
  SPQMinPKSQL = 'MinPK_SQL';
  SPQMaxPKSQL = 'MaxPK_SQL';
  SPQRowIdSQL = 'RowIdSQL';
  SPQRidChunkWorkers = 'RidChunkWorkers';
  SDefaultRidChunkWorkers = '8';
  SDefaultPQChunkSize = '20000';
  SDefaultPQCommitEvery = '10000';
  SDefaultPQEnabled = '0';
  SDefaultPQIntervalSec = '0';
  SDefaultPQProgressEverySec = '10';
  SDefaultPQMaxWorkers = '20';

implementation

end.

