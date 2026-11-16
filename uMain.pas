unit uMain;

{$I MyService.inc}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.StrUtils, System.Classes, Registry, Vcl.Graphics,
  Vcl.Controls, Vcl.SvcMgr, Vcl.Dialogs, System.DateUtils, System.Variants, SQLiteUserDatabase, MSA.Logger, uCommon,
  uConst, Winapi.ShlObj, FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Def, FireDAC.Stan.Async, FireDAC.Phys.Intf,
  FireDAC.Phys.Oracle, FireDAC.Phys.MSSQL, uConfigWatcher, FireDAC.Comp.Client, System.SyncObjs,
  System.Generics.Collections, uPumpTypes, uPumpManager, uPumpStatDB
{$IFDEF GUI_APP}
    , uTmp
{$ENDIF }
;

type
  Tmsadpsvc = class(TService)
    procedure ServiceCreate(Sender: TObject);
    procedure ServiceAfterInstall(Sender: TService);
    procedure ServiceStart(Sender: TService; var Started: Boolean);
    procedure ServiceStop(Sender: TService; var Stopped: Boolean);
  private
    FSourceConn: TFDConnection;
    FTargetConn: TFDConnection;
    FConfigWatcher: TConfigWatcherThread;
    FPumpManager: TPumpManager;
    FStatDB: TPumpStatDB;

    procedure EnsurePQExampleSections(ADB: TmsaSQLiteUserDatabase; AParentID: Integer);
    procedure LoadPQSources;
    procedure LogPQSources;
    function HasAnyWork: Boolean;
  public
    FStartUpTime: TDateTime;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    function GetServiceController: TServiceController; override;

    procedure DatapumpServiceStart;
    procedure DatapumpServiceStop;
    procedure StopWatcher;

    procedure WriteLog(const Msg: string; Level: TLogLevel = llInfo);

    procedure InitConfig;
    procedure LoadSettings;
    procedure LogConfig;
    procedure OpenConnections;
    procedure CloseConnections;
    procedure CheckConnections;
    procedure InitOracleSession;
    procedure ReloadConfig;
    procedure RebuildTables;

    function GetConnection(ADB: TDBKind): TFDConnection;
    function GetFieldMinMax(ADB: TDBKind; const TableName, FieldName: string): TIDs;
    function GetVPDTablesAsString: string;
    function GetIgnoreTables: string;
    function GetSchemaNames: string;
    function GetTablesListMask: string;
    function GetSchemaTables(const SchemaName: string): string;
    function GetSchemaTablesByMask(const SchemaName, Mask: string): string;
    function GetSchemaTablesByMasks(const SchemaName: string; const Masks: TArray<string>): string;
    function GetTargetTables: string;
    function GetTablesToLoadAsString: string;
    function GetGapFillTablesAsString: string;
    function GetTableFields(const TableName: string): string;
    function GetTableKeyFields(const TableName: string): string;
    function BuildSQLs(const TableName, WhereClause: string): TQueries;
    procedure BuildQueries;
    procedure LogQueries;
    procedure LogTargetTables;
    function IsTableIgnored(const ATableName: string): Boolean;
    procedure LoadSpecialSources;
    function BuildSpecialInsertSQL(const ATableName: string; ACheckExists: Boolean = True): string;
    procedure LogSpecialSources;
    function ParseSpecialSectionName(const AName: string; out ATableName: string; out AQueryIndex: Integer; out
      AIsExample: Boolean): Boolean;
    procedure EnsureSpecialExampleSection(ADB: TmsaSQLiteUserDatabase; AParentID: Integer);
    function GetUpdateTablesAsString: string;
    procedure BuildUpdateQueries;
  end;

var
  msadpsvc: Tmsadpsvc;

function GetLogFolder: string;

procedure GlobalLog(const Msg: string; Level: TLogLevel);

implementation

uses
  uFunctions;

{$R *.dfm}

function GetLogFolder: string;
begin
  Result := GetSpecialPath(CSIDL_COMMON_APPDATA);
  Result := IncludeTrailingPathDelimiter(Result) + APP_FOLDER;
  ForceDirectories(Result);
  Result := IncludeTrailingPathDelimiter(Result);
end;

procedure InitGlobalParams;
begin
  GConfigParams.Values['DriverID'] := 'SQLite';
  GConfigParams.Values['OpenMode'] := 'CreateUTF8';
  GConfigParams.Values['Database'] := GetLogFolder + SConfigFileName;
end;

constructor Tmsadpsvc.Create(AOwner: TComponent);
begin
  inherited;
end;

destructor Tmsadpsvc.Destroy;
begin
  StopWatcher;
  if Assigned(FPumpManager) then
  begin
    FPumpManager.Stop;
    FreeAndNil(FPumpManager);
  end;
  CloseConnections;
  inherited;
end;

procedure Tmsadpsvc.StopWatcher;
begin
  if Assigned(FConfigWatcher) then
  begin
    FConfigWatcher.Stop;
    FConfigWatcher.WaitFor;
    FreeAndNil(FConfigWatcher);
  end;
end;

procedure Tmsadpsvc.WriteLog(const Msg: string; Level: TLogLevel);
begin
  TSqliteLogger.GetInstance.Log(Msg, Level);
{$IFDEF GUI_APP}
  if Assigned(fTmp) then
    fTmp.AddLogLine(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' [' + TEnumUtils.AsString<TLogLevel>(Level) + '] ' + Msg);
{$ENDIF}
end;

procedure Tmsadpsvc.InitConfig;
var
  DB: TmsaSQLiteUserDatabase;
  ConnSection, SourceSection, TargetSection, TablesSection, PumpSection: Integer;
begin
  DB := TmsaSQLiteUserDatabase.Create(GConfigParams, '', '');
  try

    ConnSection := DB.SectionExists(-1, 'Connections');
    if ConnSection < 1 then
    begin
      WriteLog('Раздел "Connections" не найден, создаём');
      ConnSection := DB.ForceSections('Connections');
      if ConnSection < 1 then
        raise Exception.Create('Не удалось создать раздел "Connections"');
      DB.WriteValue(ConnSection, SSourceDBMSServerName, SDefaultSourceDBMSServerName);
      DB.WriteValue(ConnSection, SSourceDBMSServerPort, SDefaultSourceDBMSServerPort);
      DB.WriteValue(ConnSection, SSourceDBName, SDefaultSourceDBName);
      DB.WriteValue(ConnSection, SSourceDBUserName, SDefaultSourceDBUserName);
      DB.WriteValue(ConnSection, SSourceDBPass, SDefaultSourceDBPass);
      DB.WriteValue(ConnSection, STargetDBMSServerName, SDefaultTargetDBMSServerName);
      DB.WriteValue(ConnSection, STargetDBMSServerPort, SDefaultTargetDBMSServerPort);
      DB.WriteValue(ConnSection, STargetDBName, SDefaultTargetDBName);
      DB.WriteValue(ConnSection, STargetDBUserName, SDefaultTargetDBUserName);
      DB.WriteValue(ConnSection, STargetDBPass, SDefaultTargetDBPass);
      WriteLog('Раздел "Connections" создан и заполнен значениями по умолчанию');
    end
    else
      WriteLog('Раздел "Connections" найден, id = ' + IntToStr(ConnSection));

    SourceSection := DB.SectionExists(-1, SSourceOptions);
    if SourceSection < 1 then
    begin
      SourceSection := DB.ForceSections(SSourceOptions);
      if SourceSection < 1 then
        raise Exception.Create('Не удалось создать раздел "' + SSourceOptions + '"');
      WriteLog('Раздел "' + SSourceOptions + '" создан');
    end
    else
      WriteLog('Раздел "' + SSourceOptions + '" найден, id = ' + IntToStr(SourceSection));

    if not DB.ValueExists(SourceSection, SIgnoreTables) then
    begin
      DB.WriteValue(SourceSection, SIgnoreTables, '');
      WriteLog('Ключ "' + SIgnoreTables + '" создан (пустой список)');
    end
    else
      WriteLog('Ключ "' + SIgnoreTables + '" найден');

    TargetSection := DB.SectionExists(-1, STargetOptions);
    if TargetSection < 1 then
    begin
      TargetSection := DB.ForceSections(STargetOptions);
      if TargetSection < 1 then
        raise Exception.Create('Не удалось создать раздел "' + STargetOptions + '"');
      WriteLog('Раздел "' + STargetOptions + '" создан');
    end
    else
      WriteLog('Раздел "' + STargetOptions + '" найден, id = ' + IntToStr(TargetSection));

    TablesSection := DB.SectionExists(-1, STablesList);
    if TablesSection < 1 then
    begin
      TablesSection := DB.ForceSections(STablesList);
      if TablesSection < 1 then
        raise Exception.Create('Не удалось создать раздел "' + STablesList + '"');
      WriteLog('Раздел "' + STablesList + '" создан');
    end
    else
      WriteLog('Раздел "' + STablesList + '" найден, id = ' + IntToStr(TablesSection));

    if not DB.ValueExists(TablesSection, STablesListMask) then
    begin
      DB.WriteValue(TablesSection, STablesListMask, SDefaultTablesListMask);
      WriteLog('Ключ "' + STablesListMask + '" создан, значение по умолчанию: "' + SDefaultTablesListMask + '"');
    end
    else
      WriteLog('Ключ "' + STablesListMask + '" найден');

    if not DB.ValueExists(TablesSection, SSchemaNames) then
    begin
      DB.WriteValue(TablesSection, SSchemaNames, SDefaultSchemaNames);
      WriteLog('Ключ "' + SSchemaNames + '" создан в TablesList, значение по умолчанию: ' + SDefaultSchemaNames);
    end
    else
      WriteLog('Ключ "' + SSchemaNames + '" найден в TablesList');

    if not DB.ValueExists(TablesSection, SPumpGapFillMask) then
    begin
      DB.WriteValue(TablesSection, SPumpGapFillMask, SDefaultPumpGapFillMask);
      WriteLog('Ключ "' + SPumpGapFillMask + '" создан в TablesList, значение по умолчанию: "' + SDefaultPumpGapFillMask + '"');
    end
    else
      WriteLog('Ключ "' + SPumpGapFillMask + '" найден в TablesList');

    PumpSection := DB.SectionExists(-1, SPumpOptions);
    if PumpSection < 1 then
    begin
      PumpSection := DB.ForceSections(SPumpOptions);
      if PumpSection < 1 then
        raise Exception.Create('Не удалось создать раздел "' + SPumpOptions + '"');
      WriteLog('Раздел "' + SPumpOptions + '" создан');
    end
    else
      WriteLog('Раздел "' + SPumpOptions + '" найден, id = ' + IntToStr(PumpSection));

    if not DB.ValueExists(PumpSection, SPumpIntervalSec) then
    begin
      DB.WriteValue(PumpSection, SPumpIntervalSec, SDefaultPumpIntervalSec);
      WriteLog('Ключ "' + SPumpIntervalSec + '" создан, значение по умолчанию: ' + SDefaultPumpIntervalSec);
    end
    else
      WriteLog('Ключ "' + SPumpIntervalSec + '" найден');

    if not DB.ValueExists(PumpSection, SPumpWorkerCount) then
    begin
      DB.WriteValue(PumpSection, SPumpWorkerCount, SDefaultPumpWorkerCount);
      WriteLog('Ключ "' + SPumpWorkerCount + '" создан, значение по умолчанию: ' + SDefaultPumpWorkerCount);
    end
    else
      WriteLog('Ключ "' + SPumpWorkerCount + '" найден');

    if not DB.ValueExists(PumpSection, SPumpGapFillEnabled) then
    begin
      DB.WriteValue(PumpSection, SPumpGapFillEnabled, SDefaultPumpGapFillEnabled);
      WriteLog('Ключ "' + SPumpGapFillEnabled + '" создан, значение по умолчанию: ' + SDefaultPumpGapFillEnabled);
    end
    else
      WriteLog('Ключ "' + SPumpGapFillEnabled + '" найден');

    if not DB.ValueExists(PumpSection, SPumpGapFillIntervalSec) then
    begin
      DB.WriteValue(PumpSection, SPumpGapFillIntervalSec, SDefaultPumpGapFillIntervalSec);
      WriteLog('Ключ "' + SPumpGapFillIntervalSec + '" создан, значение по умолчанию: ' + SDefaultPumpGapFillIntervalSec);
    end
    else
      WriteLog('Ключ "' + SPumpGapFillIntervalSec + '" найден');

    if not DB.ValueExists(PumpSection, SPumpGapFillChunkSize) then
    begin
      DB.WriteValue(PumpSection, SPumpGapFillChunkSize, SDefaultPumpGapFillChunkSize);
      WriteLog('Ключ "' + SPumpGapFillChunkSize + '" создан, значение по умолчанию: ' + SDefaultPumpGapFillChunkSize);
    end
    else
      WriteLog('Ключ "' + SPumpGapFillChunkSize + '" найден');

    if not DB.ValueExists(PumpSection, SPumpGapFillWorkerCount) then
    begin
      DB.WriteValue(PumpSection, SPumpGapFillWorkerCount, SDefaultPumpGapFillWorkerCount);
      WriteLog('Ключ "' + SPumpGapFillWorkerCount + '" создан, значение по умолчанию: ' + SDefaultPumpGapFillWorkerCount);
    end
    else
      WriteLog('Ключ "' + SPumpGapFillWorkerCount + '" найден');

    if not DB.ValueExists(PumpSection, SUpdateTables) then
    begin
      DB.WriteValue(PumpSection, SUpdateTables, SDefaultUpdateTables);
      WriteLog('Ключ "' + SUpdateTables + '" создан (пустой список)');
    end
    else
      WriteLog('Ключ "' + SUpdateTables + '" найден');

    if not DB.ValueExists(PumpSection, SUpdateIntervalSec) then
    begin
      DB.WriteValue(PumpSection, SUpdateIntervalSec, SDefaultUpdateIntervalSec);
      WriteLog('Ключ "' + SUpdateIntervalSec + '" создан, значение по умолчанию: ' + SDefaultUpdateIntervalSec);
    end
    else
      WriteLog('Ключ "' + SUpdateIntervalSec + '" найден');

    if not DB.ValueExists(PumpSection, SUpdateWorkerCount) then
    begin
      DB.WriteValue(PumpSection, SUpdateWorkerCount, SDefaultUpdateWorkerCount);
      WriteLog('Ключ "' + SUpdateWorkerCount + '" создан, значение по умолчанию: ' + SDefaultUpdateWorkerCount);
    end
    else
      WriteLog('Ключ "' + SUpdateWorkerCount + '" найден');

    if not DB.ValueExists(PumpSection, SPQProgressEverySec) then
    begin
      DB.WriteValue(PumpSection, SPQProgressEverySec, SDefaultPQProgressEverySec);
      WriteLog('Ключ "' + SPQProgressEverySec + '" создан, значение по умолчанию: ' + SDefaultPQProgressEverySec);
    end
    else
      WriteLog('Ключ "' + SPQProgressEverySec + '" найден');

    if not DB.ValueExists(PumpSection, SPQMaxWorkers) then
    begin
      DB.WriteValue(PumpSection, SPQMaxWorkers, SDefaultPQMaxWorkers);
      WriteLog('Ключ "' + SPQMaxWorkers + '" создан, значение по умолчанию: ' + SDefaultPQMaxWorkers);
    end
    else
      WriteLog('Ключ "' + SPQMaxWorkers + '" найден');

    var SpecSection := DB.SectionExists(-1, SSpecialDataSources);
    if SpecSection < 1 then
    begin
      SpecSection := DB.ForceSections(SSpecialDataSources);
      if SpecSection < 1 then
        raise Exception.Create('Не удалось создать раздел "' + SSpecialDataSources + '"');
      WriteLog('Раздел "' + SSpecialDataSources + '" создан');
    end
    else
      WriteLog('Раздел "' + SSpecialDataSources + '" найден, id = ' + IntToStr(SpecSection));

    EnsureSpecialExampleSection(DB, SpecSection);

    var PQSection := DB.SectionExists(-1, SPQSection);
    if PQSection < 1 then
    begin
      PQSection := DB.ForceSections(SPQSection);
      if PQSection < 1 then
        raise Exception.Create('Не удалось создать раздел "' + SPQSection + '"');
      WriteLog('Раздел "' + SPQSection + '" создан');
    end
    else
      WriteLog('Раздел "' + SPQSection + '" найден, id = ' + IntToStr(PQSection));

    EnsurePQExampleSections(DB, PQSection);
  finally
    DB.Free;
  end;
end;

procedure Tmsadpsvc.LoadSettings;
var
  DB: TmsaSQLiteUserDatabase;
  ConnID, SrcID, TgtID, TblID, PumpID: Integer;
begin
  DB := TmsaSQLiteUserDatabase.Create(GConfigParams, '', '');
  try

    ConnID := DB.SectionExists(-1, 'Connections');
    if ConnID < 1 then
      raise Exception.Create('Раздел "Connections" не найден');

    GSettings.Source.Host := DB.ReadValue(ConnID, SSourceDBMSServerName);
    GSettings.Source.Port := StrToIntDef(DB.ReadValue(ConnID, SSourceDBMSServerPort), DefaultSourceDBMSServerPort);
    GSettings.Source.Database := DB.ReadValue(ConnID, SSourceDBName);
    GSettings.Source.User := DB.ReadValue(ConnID, SSourceDBUserName);
    GSettings.Source.Pass := DB.ReadValue(ConnID, SSourceDBPass);

    GSettings.Target.Host := DB.ReadValue(ConnID, STargetDBMSServerName);
    GSettings.Target.Port := StrToIntDef(DB.ReadValue(ConnID, STargetDBMSServerPort), DefaultTargetDBMSServerPort);
    GSettings.Target.Database := DB.ReadValue(ConnID, STargetDBName);
    GSettings.Target.User := DB.ReadValue(ConnID, STargetDBUserName);
    GSettings.Target.Pass := DB.ReadValue(ConnID, STargetDBPass);

    SrcID := DB.SectionExists(-1, SSourceOptions);
    if SrcID > 0 then
      GSettings.IgnoreTables := Trim(DB.ReadValue(SrcID, SIgnoreTables))
    else
      GSettings.IgnoreTables := '';

    TblID := DB.SectionExists(-1, STablesList);
    if TblID > 0 then
    begin
      GSettings.SchemaNames := Trim(DB.ReadValue(TblID, SSchemaNames));
      GSettings.TablesListMask := Trim(DB.ReadValue(TblID, STablesListMask));
      GSettings.GapFillMask := Trim(DB.ReadValue(TblID, SPumpGapFillMask));
    end
    else
    begin
      GSettings.SchemaNames := '';
      GSettings.TablesListMask := '';
      GSettings.GapFillMask := '';
    end;

    PumpID := DB.SectionExists(-1, SPumpOptions);
    if PumpID > 0 then
      GSettings.PumpIntervalSec := StrToIntDef(Trim(DB.ReadValue(PumpID, SPumpIntervalSec)), StrToIntDef(SDefaultPumpIntervalSec,
          DefaultPumpIntervalSec))
    else
      GSettings.PumpIntervalSec := StrToIntDef(SDefaultPumpIntervalSec, DefaultPumpIntervalSec);

    if PumpID > 0 then
      GSettings.PumpWorkerCount := StrToIntDef(Trim(DB.ReadValue(PumpID, SPumpWorkerCount)), StrToIntDef(SDefaultPumpWorkerCount,
          DefaultPumpWorkerCount))
    else
      GSettings.PumpWorkerCount := StrToIntDef(SDefaultPumpWorkerCount, DefaultPumpWorkerCount);

    if PumpID > 0 then
      GSettings.GapFillEnabled := StrToIntDef(Trim(DB.ReadValue(PumpID, SPumpGapFillEnabled)), StrToIntDef(SDefaultPumpGapFillEnabled,
          0)) <> 0
    else
      GSettings.GapFillEnabled := StrToIntDef(SDefaultPumpGapFillEnabled, 0) <> 0;

    if PumpID > 0 then
      GSettings.GapFillIntervalSec := StrToIntDef(Trim(DB.ReadValue(PumpID, SPumpGapFillIntervalSec)),
        DefaultPumpGapFillIntervalSec)
    else
      GSettings.GapFillIntervalSec := DefaultPumpGapFillIntervalSec;

    if PumpID > 0 then
      GSettings.GapFillChunkSize := StrToIntDef(Trim(DB.ReadValue(PumpID, SPumpGapFillChunkSize)), DefaultPumpGapFillChunkSize)
    else
      GSettings.GapFillChunkSize := DefaultPumpGapFillChunkSize;

    if PumpID > 0 then
      GSettings.GapFillWorkerCount := StrToIntDef(Trim(DB.ReadValue(PumpID, SPumpGapFillWorkerCount)),
        DefaultPumpGapFillWorkerCount)
    else
      GSettings.GapFillWorkerCount := DefaultPumpGapFillWorkerCount;

    if PumpID > 0 then
    begin
      GSettings.UpdateTables := Trim(DB.ReadValue(PumpID, SUpdateTables));
      GSettings.UpdateIntervalSec := StrToIntDef(Trim(DB.ReadValue(PumpID, SUpdateIntervalSec)),
        DefaultUpdateIntervalSec);
      GSettings.UpdateWorkerCount := StrToIntDef(Trim(DB.ReadValue(PumpID, SUpdateWorkerCount)),
        DefaultUpdateWorkerCount);
      if GSettings.UpdateWorkerCount < 1 then
        GSettings.UpdateWorkerCount := 1;
      if GSettings.UpdateIntervalSec < 0 then
        GSettings.UpdateIntervalSec := 0;
    end
    else
    begin
      GSettings.UpdateTables := '';
      GSettings.UpdateIntervalSec := DefaultUpdateIntervalSec;
      GSettings.UpdateWorkerCount := DefaultUpdateWorkerCount;
    end;

    if PumpID > 0 then
    begin
      GSettings.PQProgressEverySec := StrToIntDef(Trim(DB.ReadValue(PumpID, SPQProgressEverySec)),
        StrToIntDef(SDefaultPQProgressEverySec, 10));
      GSettings.PQMaxConcurrentWorkers := StrToIntDef(Trim(DB.ReadValue(PumpID, SPQMaxWorkers)),
        StrToIntDef(SDefaultPQMaxWorkers, 20));
    end
    else
    begin
      GSettings.PQProgressEverySec := StrToIntDef(SDefaultPQProgressEverySec, 10);
      GSettings.PQMaxConcurrentWorkers := StrToIntDef(SDefaultPQMaxWorkers, 20);
    end;
    if GSettings.PQProgressEverySec < 1 then
      GSettings.PQProgressEverySec := 10;
    if GSettings.PQMaxConcurrentWorkers < 1 then
      GSettings.PQMaxConcurrentWorkers := 1;
    if GSettings.PQMaxConcurrentWorkers > 256 then
      GSettings.PQMaxConcurrentWorkers := 256;
  finally
    DB.Free;
  end;
end;

procedure Tmsadpsvc.LogConfig;
begin
  WriteLog('--- Конфигурация ---');
  WriteLog('SessionID = ' + GUIDToString(GSessionID));
  WriteLog(Format('Source: %s:%d/%s, user=%s, pass=%s', [GSettings.Source.Host, GSettings.Source.Port, GSettings.Source.Database,
        GSettings.Source.User, StringOfChar('*', Length(GSettings.Source.Pass))]));
  WriteLog(Format('Target: %s:%d/%s, user=%s, pass=%s', [GSettings.Target.Host, GSettings.Target.Port, GSettings.Target.Database,
        GSettings.Target.User, StringOfChar('*', Length(GSettings.Target.Pass))]));
  WriteLog('IgnoreTables = "' + GSettings.IgnoreTables + '"');
  WriteLog('SchemaNames = "' + GSettings.SchemaNames + '"');
  WriteLog('TablesListMask = "' + GSettings.TablesListMask + '"');
  WriteLog('GapFillMask = "' + GSettings.GapFillMask + '"');
  WriteLog('PumpIntervalSec = ' + IntToStr(GSettings.PumpIntervalSec));
  WriteLog('PumpWorkerCount = ' + IntToStr(GSettings.PumpWorkerCount));
  WriteLog('GapFillEnabled = ' + BoolToStr(GSettings.GapFillEnabled, True));
  WriteLog('GapFillIntervalSec = ' + IntToStr(GSettings.GapFillIntervalSec));
  WriteLog('GapFillChunkSize = ' + IntToStr(GSettings.GapFillChunkSize));
  WriteLog('GapFillWorkerCount = ' + IntToStr(GSettings.GapFillWorkerCount));
  WriteLog('UpdateTables = "' + GSettings.UpdateTables + '"');
  WriteLog('UpdateIntervalSec = ' + IntToStr(GSettings.UpdateIntervalSec));
  WriteLog('UpdateWorkerCount = ' + IntToStr(GSettings.UpdateWorkerCount));

  WriteLog('PQProgressEverySec = ' + IntToStr(GSettings.PQProgressEverySec));
  WriteLog('PQMaxConcurrentWorkers = ' + IntToStr(GSettings.PQMaxConcurrentWorkers));
  WriteLog('--- Конец конфигурации ---');
end;

procedure Tmsadpsvc.ReloadConfig;
begin
  GConfigLock.Enter;
  try
    LoadSettings;
    LogConfig;
    RebuildTables;
    LoadSpecialSources;
    LoadPQSources;
    LogPQSources;
  finally
    GConfigLock.Leave;
  end;
end;

procedure Tmsadpsvc.OpenConnections;
begin
  FSourceConn := TFDConnection.Create(nil);
  FSourceConn.LoginPrompt := False;
  FSourceConn.Params.Clear;
  FSourceConn.Params.Add('DriverID=Ora');
  FSourceConn.Params.Add('Database=' + GSettings.Source.Host + ':' + IntToStr(GSettings.Source.Port) + '/' + GSettings.Source.Database);
  FSourceConn.Params.Add('User_Name=' + GSettings.Source.User);
  FSourceConn.Params.Add('Password=' + GSettings.Source.Pass);

  FTargetConn := TFDConnection.Create(nil);
  FTargetConn.LoginPrompt := False;
  FTargetConn.Params.Clear;
  FTargetConn.Params.Add('DriverID=MSSQL');
  FTargetConn.Params.Add('Server=' + GSettings.Target.Host + ',' + IntToStr(GSettings.Target.Port));
  FTargetConn.Params.Add('Database=' + GSettings.Target.Database);
  FTargetConn.Params.Add('User_Name=' + GSettings.Target.User);
  FTargetConn.Params.Add('Password=' + GSettings.Target.Pass);
  FTargetConn.Params.Add('OSAuthent=No');
  FTargetConn.Params.Add('ODBCAdvanced=TrustServerCertificate=yes');
  FTargetConn.Params.Add('ApplicationName=' + ServiceDescr);
end;

procedure Tmsadpsvc.CloseConnections;
begin
  if Assigned(FSourceConn) then
  begin
    if FSourceConn.Connected then
      FSourceConn.Connected := False;
    FreeAndNil(FSourceConn);
  end;
  if Assigned(FTargetConn) then
  begin
    if FTargetConn.Connected then
      FTargetConn.Connected := False;
    FreeAndNil(FTargetConn);
  end;
end;

procedure Tmsadpsvc.CheckConnections;
var
  MM: TIDs;
begin
  WriteLog('Проверка Oracle...');
  try
    FSourceConn.Connected := True;
    WriteLog('Oracle: подключение OK');
  except
    on E: Exception do
    begin
      WriteLog('Oracle: ошибка подключения: ' + E.Message, llError);
      Exit;
    end;
  end;

  InitOracleSession;

  WriteLog('Проверка MS SQL...');
  try
    FTargetConn.Connected := True;
    WriteLog('MS SQL: подключение OK');
  except
    on E: Exception do
    begin
      WriteLog('MS SQL: ошибка подключения: ' + E.Message, llError);
      Exit;
    end;
  end;

  MM := GetFieldMinMax(dbSource, 'tiger.A_ACODE', 'ACODE_ID');
  WriteLog(Format('Oracle tiger.A_ACODE.ACODE_ID: min=%d, max=%d', [MM.MinID, MM.MaxID]));
  MM := GetFieldMinMax(dbTarget, 'tiger.A_ACODE', 'ACODE_ID');
  WriteLog(Format('MS SQL tiger.A_ACODE.ACODE_ID: min=%d, max=%d', [MM.MinID, MM.MaxID]));
end;

procedure Tmsadpsvc.InitOracleSession;
begin
  if not Assigned(FSourceConn) or not FSourceConn.Connected then
    Exit;
  try
    FSourceConn.ExecSQL('begin tiger.admission_for_ues_users.init_user_context; end;');
    WriteLog('Oracle: контекст пользователя инициализирован (init_user_context)');
  except
    on E: Exception do
      WriteLog('Oracle: ошибка init_user_context: ' + E.Message, llError);
  end;
end;

function Tmsadpsvc.GetConnection(ADB: TDBKind): TFDConnection;
begin
  case ADB of
    dbSource:
      Result := FSourceConn;
    dbTarget:
      Result := FTargetConn;
  else
    Result := nil;
  end;
end;

function Tmsadpsvc.GetFieldMinMax(ADB: TDBKind; const TableName, FieldName: string): TIDs;
var
  Conn: TFDConnection;
  Q: TFDQuery;
begin
  Result.MinID := 0;
  Result.MaxID := 0;

  Conn := GetConnection(ADB);
  if Conn = nil then
  begin
    WriteLog('GetFieldMinMax: соединение не задано', llError);
    Exit;
  end;

  Q := TFDQuery.Create(nil);
  try
    try
      Q.Connection := Conn;
      Q.SQL.Text := 'SELECT MIN(' + FieldName + ') AS min_val, MAX(' + FieldName + ') AS max_val FROM ' + TableName;
      Q.Open;
      if not Q.IsEmpty then
      begin
        Result.MinID := Q.FieldByName('min_val').AsLargeInt;
        Result.MaxID := Q.FieldByName('max_val').AsLargeInt;
      end;
    except
      on E: Exception do
        WriteLog(Format('GetFieldMinMax(%s.%s): %s', [TableName, FieldName, E.Message]), llError);
    end;
  finally
    Q.Free;
  end;
end;

function Tmsadpsvc.GetVPDTablesAsString: string;
var
  Q: TFDQuery;
  List: TStringList;
begin
  Result := '';
  List := TStringList.Create;
  try
    List.Sorted := True;
    List.Delimiter := ';';
    List.Duplicates := dupIgnore;
    List.StrictDelimiter := True;

    Q := TFDQuery.Create(nil);
    try
      try
        Q.Connection := FSourceConn;
        Q.SQL.Text := 'SELECT DISTINCT OBJECT_NAME FROM ALL_POLICIES WHERE OBJECT_OWNER = :owner AND ENABLE = ''YES''';
        Q.ParamByName('owner').AsString := 'TIGER';
        Q.Open;
        while not Q.EOF do
        begin
          List.Add(Trim(Q.Fields[0].AsString));
          Q.Next;
        end;
        Result := List.DelimitedText;
      except
        on E: Exception do
        begin
          Result := '';
          WriteLog('GetVPDTablesAsString: ошибка: ' + E.Message, llError);
        end;
      end;
    finally
      Q.Free;
    end;
  finally
    List.Free;
  end;
end;

function Tmsadpsvc.GetSchemaTables(const SchemaName: string): string;
var
  Q: TFDQuery;
  List: TStringList;
begin
  Result := '';
  List := TStringList.Create;
  try
    List.Sorted := True;
    List.Delimiter := ';';
    List.Duplicates := dupIgnore;
    List.StrictDelimiter := True;

    Q := TFDQuery.Create(nil);
    try
      try
        Q.Connection := FTargetConn;
        Q.SQL.Text :=
          'SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = :schema AND TABLE_TYPE = ''BASE TABLE''';
        Q.ParamByName('schema').AsString := SchemaName;
        Q.Open;
        while not Q.EOF do
        begin
          List.Add(Trim(Q.Fields[0].AsString));
          Q.Next;
        end;
        Result := List.DelimitedText;
      except
        on E: Exception do
        begin
          Result := '';
          WriteLog('GetSchemaTables(' + SchemaName + '): ошибка: ' + E.Message, llError);
        end;
      end;
    finally
      Q.Free;
    end;
  finally
    List.Free;
  end;
end;

function Tmsadpsvc.GetSchemaTablesByMasks(const SchemaName: string; const Masks: TArray<string>): string;
var
  Q: TFDQuery;
  List: TStringList;
  Mask, M: string;
begin
  Result := '';
  List := TStringList.Create;
  try
    List.Sorted := True;
    List.Delimiter := ';';
    List.Duplicates := dupIgnore;
    List.StrictDelimiter := True;

    Q := TFDQuery.Create(nil);
    try
      try
        Q.Connection := FTargetConn;
        Q.SQL.Text :=
          'SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = :schema AND TABLE_TYPE = ''BASE TABLE'' AND TABLE_NAME LIKE :mask';

        for Mask in Masks do
        begin
          M := Trim(Mask);
          if M = '' then
            Continue;

          Q.ParamByName('schema').AsString := SchemaName;
          Q.ParamByName('mask').AsString := M;
          Q.Open;

          while not Q.EOF do
          begin
            List.Add(Trim(Q.Fields[0].AsString));
            Q.Next;
          end;
          Q.Close;
        end;

        Result := List.DelimitedText;
      except
        on E: Exception do
        begin
          Result := '';
          WriteLog('GetSchemaTablesByMasks(' + SchemaName + '): ошибка: ' + E.Message, llError);
        end;
      end;
    finally
      Q.Free;
    end;
  finally
    List.Free;
  end;
end;

function Tmsadpsvc.GetSchemaTablesByMask(const SchemaName, Mask: string): string;
var
  Q: TFDQuery;
  List: TStringList;
begin
  Result := '';
  List := TStringList.Create;
  try
    List.Sorted := True;
    List.Delimiter := ';';
    List.Duplicates := dupIgnore;
    List.StrictDelimiter := True;

    Q := TFDQuery.Create(nil);
    try
      try
        Q.Connection := FTargetConn;
        Q.SQL.Text :=
          'SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = :schema AND TABLE_TYPE = ''BASE TABLE'' AND TABLE_NAME LIKE :mask';
        Q.ParamByName('schema').AsString := SchemaName;
        Q.ParamByName('mask').AsString := Mask;
        Q.Open;
        while not Q.EOF do
        begin
          List.Add(Trim(Q.Fields[0].AsString));
          Q.Next;
        end;
        Result := List.DelimitedText;
      except
        on E: Exception do
        begin
          Result := '';
          WriteLog('GetSchemaTablesByMask(' + SchemaName + ', mask=' + Mask + '): ошибка: ' + E.Message, llError);
        end;
      end;
    finally
      Q.Free;
    end;
  finally
    List.Free;
  end;
end;

function Tmsadpsvc.GetTargetTables: string;
var
  MaskStr, SchemaNames, Schema, Tables, Prefixed: string;
  SchemaParts, MaskParts: TArray<string>;
  I: Integer;
  ResultList: TStringList;
begin
  Result := '';
  ResultList := TStringList.Create;
  try
    ResultList.Sorted := True;
    ResultList.Delimiter := ';';
    ResultList.Duplicates := dupIgnore;
    ResultList.StrictDelimiter := True;

    MaskStr := GetTablesListMask;
    if Trim(MaskStr) = '' then
      Exit;

    MaskParts := MaskStr.Split([';']);
    SchemaNames := GetSchemaNames;
    SchemaParts := SchemaNames.Split([';']);
    for I := 0 to High(SchemaParts) do
    begin
      Schema := Trim(SchemaParts[I]);
      if Schema = '' then
        Continue;

      Tables := GetSchemaTablesByMasks(Schema, MaskParts);
      if Tables = '' then
        Continue;

      Prefixed := Schema + '.' + StringReplace(Tables, ';', ';' + Schema + '.', [rfReplaceAll]);
      ResultList.AddStrings(Prefixed.Split([';']));
    end;

    Result := ResultList.DelimitedText;
  finally
    ResultList.Free;
  end;
end;

function Tmsadpsvc.GetTablesToLoadAsString: string;
var
  VPDList, IgnoreList, SchemaNames: string;
  VPDArr, IgnoreArr, MaskArr: TArray<string>;
  SchemaParts, TableParts: TArray<string>;
  I, J: Integer;
  Schema, TableName, FullName: string;

  function IsInArray(const Arr: TArray<string>; const Name: string): Boolean;
  var
    S: string;
  begin
    for S in Arr do
      if SameText(Trim(S), Name) then
        Exit(True);
    Result := False;
  end;

begin
  GTablesToLoad.Clear;
  VPDList := GetVPDTablesAsString;
  IgnoreList := GetIgnoreTables;
  MaskArr := GetTargetTables.Split([';']);
  VPDArr := VPDList.Split([';']);
  IgnoreArr := IgnoreList.Split([';']);

  SchemaNames := GetSchemaNames;
  SchemaParts := SchemaNames.Split([';']);
  for I := 0 to High(SchemaParts) do
  begin
    Schema := Trim(SchemaParts[I]);
    if Schema = '' then
      Continue;

    TableParts := GetSchemaTables(Schema).Split([';']);
    for J := 0 to High(TableParts) do
    begin
      TableName := Trim(TableParts[J]);
      if TableName = '' then
        Continue;

      FullName := Schema + '.' + TableName;
      if IsInArray(IgnoreArr, TableName) then
        Continue;

      if IsInArray(VPDArr, TableName) or IsInArray(MaskArr, FullName) then
        if GTablesToLoad.IndexOf(FullName) < 0 then
          GTablesToLoad.Add(FullName);
    end;
  end;

  Result := GTablesToLoad.DelimitedText;
end;

function Tmsadpsvc.GetTableFields(const TableName: string): string;
var
  Q: TFDQuery;
  Schema, Table: string;
  P: Integer;
  List: TStringList;
begin
  Result := '';
  List := TStringList.Create;
  try
    List.Delimiter := ';';
    List.StrictDelimiter := True;

    P := Pos('.', TableName);
    if P > 0 then
    begin
      Schema := Copy(TableName, 1, P - 1);
      Table := Copy(TableName, P + 1, MaxInt);
    end
    else
    begin
      Schema := '';
      Table := TableName;
    end;

    Q := TFDQuery.Create(nil);
    try
      try
        Q.Connection := FTargetConn;
        Q.SQL.Text :=
          'SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = :schema AND TABLE_NAME = :table ORDER BY ORDINAL_POSITION';
        Q.ParamByName('schema').AsString := Schema;
        Q.ParamByName('table').AsString := Table;
        Q.Open;
        while not Q.EOF do
        begin
          List.Add(Trim(Q.FieldByName('COLUMN_NAME').AsString));
          Q.Next;
        end;
        Result := List.DelimitedText;
      except
        on E: Exception do
        begin
          Result := '';
          WriteLog('GetTableFields(' + TableName + '): ошибка: ' + E.Message, llError);
        end;
      end;
    finally
      Q.Free;
    end;
  finally
    List.Free;
  end;
end;

function Tmsadpsvc.GetTableKeyFields(const TableName: string): string;
var
  Q: TFDQuery;
  Schema, Table: string;
  P: Integer;
  List: TStringList;
begin
  Result := '';
  List := TStringList.Create;
  try
    List.Delimiter := ';';
    List.StrictDelimiter := True;

    P := Pos('.', TableName);
    if P > 0 then
    begin
      Schema := Copy(TableName, 1, P - 1);
      Table := Copy(TableName, P + 1, MaxInt);
    end
    else
    begin
      Schema := '';
      Table := TableName;
    end;

    Q := TFDQuery.Create(nil);
    try
      try
        Q.Connection := FTargetConn;
        Q.SQL.Text := 'SELECT kcu.COLUMN_NAME ' + '  FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc ' +
          '  JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu ' + '    ON kcu.CONSTRAINT_NAME   = tc.CONSTRAINT_NAME ' +
          '   AND kcu.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA ' + ' WHERE tc.CONSTRAINT_TYPE = ''PRIMARY KEY'' ' +
          '   AND tc.TABLE_SCHEMA    = :schema ' + '   AND tc.TABLE_NAME      = :table ' + ' ORDER BY kcu.ORDINAL_POSITION';
        Q.ParamByName('schema').AsString := Schema;
        Q.ParamByName('table').AsString := Table;
        Q.Open;
        while not Q.EOF do
        begin
          List.Add(Trim(Q.FieldByName('COLUMN_NAME').AsString));
          Q.Next;
        end;
        Result := List.DelimitedText;
      except
        on E: Exception do
        begin
          Result := '';
          WriteLog('GetTableKeyFields(' + TableName + '): ошибка: ' + E.Message, llError);
        end;
      end;
    finally
      Q.Free;
    end;
  finally
    List.Free;
  end;
end;

function Tmsadpsvc.BuildSQLs(const TableName, WhereClause: string): TQueries;
var
  Fields, Cols, Params: string;
  FieldArr: TArray<string>;
  I: Integer;
begin
  Result.TableName := TableName;
  Result.SelectSQL := '';
  Result.InsertSQL := '';
  Result.KeyFields := '';

  Fields := GetTableFields(TableName);
  if Fields = '' then
  begin
    WriteLog('BuildSQLs(' + TableName + '): список полей пуст', llWarning);
    Exit;
  end;

  Result.KeyFields := GetTableKeyFields(TableName);
  if Result.KeyFields = '' then
  begin
    WriteLog('BuildSQLs(' + TableName + '): не найдены ключевые поля', llWarning);
    Exit;
  end;

  FieldArr := Fields.Split([';']);
  Cols := '';
  Params := '';
  for I := 0 to High(FieldArr) do
  begin
    if Cols <> '' then
    begin
      Cols := Cols + ', ';
      Params := Params + ', ';
    end;
    Cols := Cols + FieldArr[I];
    Params := Params + ':' + FieldArr[I];
  end;

  Result.SelectSQL := 'SELECT ' + Cols + ' FROM ' + TableName;
  if Trim(WhereClause) <> '' then
    Result.SelectSQL := Result.SelectSQL + ' WHERE ' + WhereClause;

  Result.InsertSQL := 'INSERT INTO ' + TableName + ' (' + Cols + ') VALUES (' + Params + ')';
end;

procedure Tmsadpsvc.BuildQueries;
var
  TableName: string;
  Q: TQueries;
  AllTables: TStringList;
begin
  GQueries.Clear;

  AllTables := TStringList.Create;
  try
    AllTables.Sorted := True;
    AllTables.Duplicates := dupIgnore;
    AllTables.AddStrings(GTablesToLoad);
    AllTables.AddStrings(GTablesToLoadGapFill);

    for TableName in AllTables do
    begin
      Q := BuildSQLs(TableName, '');
      if Q.InsertSQL = '' then
      begin
        WriteLog('BuildQueries: не удалось построить SQL для ' + TableName + ' - пропускаем', llWarning);
        Continue;
      end;
      GQueries.Add(TableName, Q);
    end;
  finally
    AllTables.Free;
  end;

  WriteLog('BuildQueries: подготовлено запросов: ' + IntToStr(GQueries.Count));
end;

procedure Tmsadpsvc.LogQueries;
var
  Pair: TPair<string, TQueries>;
begin
  if GQueries.Count = 0 then
  begin
    WriteLog('Запросы: список пуст');
    Exit;
  end;

  WriteLog('--- Запросы (' + IntToStr(GQueries.Count) + ') ---');
  for Pair in GQueries do
  begin
    WriteLog('Таблица: ' + Pair.Key);
    WriteLog('  KeyFields: ' + Pair.Value.KeyFields);
    WriteLog('  SELECT: ' + Pair.Value.SelectSQL);
    WriteLog('  INSERT: ' + Pair.Value.InsertSQL);
  end;
  WriteLog('--- Конец запросов ---');
end;

procedure Tmsadpsvc.LogTargetTables;
var
  SchemaNames: string;
  SchemaParts: TArray<string>;
  I: Integer;
  Schema, Tables, Prefixed: string;
begin
  SchemaNames := GetSchemaNames;
  if SchemaNames = '' then
  begin
    WriteLog('Схемы MS SQL: список пуст');
    Exit;
  end;

  WriteLog('Схемы MS SQL (' + IntToStr(Length(SchemaNames.Split([';']))) + '): ' + SchemaNames);
  SchemaParts := SchemaNames.Split([';']);
  for I := 0 to High(SchemaParts) do
  begin
    Schema := Trim(SchemaParts[I]);
    if Schema = '' then
      Continue;

    Tables := GetSchemaTables(Schema);
    if Tables = '' then
    begin
      WriteLog('Таблицы MS SQL [' + Schema + ']: список пуст');
      Continue;
    end;

    Prefixed := Schema + '.' + StringReplace(Tables, ';', ';' + Schema + '.', [rfReplaceAll]);
    WriteLog('Таблицы MS SQL [' + Schema + '] (' + IntToStr(Length(Tables.Split([';']))) + '): ' + Prefixed);
  end;
end;

procedure Tmsadpsvc.RebuildTables;
begin
  GetTablesToLoadAsString;
  if GTablesToLoad.Count = 0 then
    WriteLog('Таблицы к загрузке: список пуст')
  else
    WriteLog('Таблицы к загрузке (' + IntToStr(GTablesToLoad.Count) + '): ' + GTablesToLoad.DelimitedText);

  GetGapFillTablesAsString;
  if GTablesToLoadGapFill.Count = 0 then
    WriteLog('GapFill-таблицы: список пуст')
  else
    WriteLog('GapFill-таблицы (' + IntToStr(GTablesToLoadGapFill.Count) + '): ' + GTablesToLoadGapFill.DelimitedText);

  BuildQueries;
  LogQueries;

  GetUpdateTablesAsString;
  if GTablesToUpdate.Count = 0 then
    WriteLog('Update-таблицы: список пуст')
  else
    WriteLog('Update-таблицы (' + IntToStr(GTablesToUpdate.Count) + '): ' +
      GTablesToUpdate.DelimitedText);

  BuildUpdateQueries;
end;

function Tmsadpsvc.GetIgnoreTables: string;
begin
  Result := GSettings.IgnoreTables;
end;

function Tmsadpsvc.GetSchemaNames: string;
begin
  Result := GSettings.SchemaNames;
end;

function Tmsadpsvc.GetTablesListMask: string;
begin
  Result := GSettings.TablesListMask;
end;

function Tmsadpsvc.IsTableIgnored(const ATableName: string): Boolean;
var
  IgnoreList: string;
  Parts: TArray<string>;
  Part: string;
begin
  Result := False;
  IgnoreList := GetIgnoreTables;
  if IgnoreList = '' then
    Exit;

  Parts := IgnoreList.Split([';']);
  for Part in Parts do
    if SameText(Trim(Part), Trim(ATableName)) then
      Exit(True);
end;

procedure Tmsadpsvc.DatapumpServiceStart;
var
  LogPath: string;
begin
  if Assigned(FSourceConn) or Assigned(FTargetConn) then
  begin
    WriteLog('Сервис уже запущен', llWarning);
    Exit;
  end;

  try
    LogPath := GetLogFolder + SLogFileName;
    TSqliteLogger.GetInstance.Start(LogPath);
    CreateGUID(GSessionID);
    WriteLog('=== Сервис запущен ===', llInfo);
    WriteLog('SessionID = ' + GUIDToString(GSessionID));

    InitConfig;
    LoadSettings;
    LogConfig;

    OpenConnections;
    CheckConnections;

    RebuildTables;
    LoadSpecialSources;
    LogSpecialSources;
    LoadPQSources;
    LogPQSources;

    FStatDB := TPumpStatDB.Create(GSettings);
    FStatDB.Start;
    GStatWriteProc := FStatDB.WriteStat;

    if HasAnyWork then
    begin
      FPumpManager := TPumpManager.Create;
      FPumpManager.Start;
    end
    else
      WriteLog('Памп не запущен: нет работы (ни Tables, ни Special, ни PQ)', llWarning);

    FConfigWatcher := TConfigWatcherThread.Create(CReloadConfigTimer, ReloadConfig);
    FConfigWatcher.Start;
    WriteLog(Format('ConfigWatcher запущен, интервал %d сек.', [CReloadConfigTimer div 1000]));
  except
    on E: Exception do
    begin
      LogMessage('Ошибка запуска сервиса:'#13#10 + E.Message, EVENTLOG_ERROR_TYPE);
      raise;
    end;
  end;

  FStartUpTime := Now;
end;

procedure Tmsadpsvc.DatapumpServiceStop;
begin
  if (FSourceConn = nil) and (FTargetConn = nil) then
  begin
    WriteLog('Сервис не запущен', llWarning);
    Exit;
  end;

  WriteLog('=== Остановка сервиса ===', llInfo);
  StopWatcher;

  if Assigned(FPumpManager) then
  begin
    FPumpManager.Stop;
    FreeAndNil(FPumpManager);
    WriteLog('PumpManager: остановлен');
  end;

  GStatWriteProc := nil;
  if Assigned(FStatDB) then
  begin
    FStatDB.Stop;
    FreeAndNil(FStatDB);
  end;

  CloseConnections;
  WriteLog('=== Сервис остановлен ===', llInfo);
  TSqliteLogger.GetInstance.Stop;
end;

procedure ServiceController(CtrlCode: DWord); stdcall;
begin
  msadpsvc.Controller(CtrlCode);
end;

function Tmsadpsvc.GetServiceController: TServiceController;
begin
  Result := ServiceController;
end;

procedure Tmsadpsvc.ServiceAfterInstall(Sender: TService);
begin
  with TRegistry.Create(KEY_READ or KEY_WRITE) do
  try
    RootKey := HKEY_LOCAL_MACHINE;
    if OpenKey('\SYSTEM\CurrentControlSet\Services\' + Name, False) then
    begin
      WriteString('Description', ServiceDescr +
        '. Синхронизирует выбранные таблицы между БД Oracle БФЛ УЭС и транспортной БД MS SQL Server');
      CloseKey;
    end;
  finally
    Free;
  end;
end;

procedure Tmsadpsvc.ServiceCreate(Sender: TObject);
begin
  DisplayName := 'MSA DataPump service';
end;

procedure Tmsadpsvc.ServiceStart(Sender: TService; var Started: Boolean);
begin
  msadpsvc.DatapumpServiceStart;
end;

procedure Tmsadpsvc.ServiceStop(Sender: TService; var Stopped: Boolean);
begin
  msadpsvc.DatapumpServiceStop;
end;

procedure GlobalLog(const Msg: string; Level: TLogLevel);
begin
  if Assigned(msadpsvc) then
    msadpsvc.WriteLog(Msg, Level)
  else
    TSqliteLogger.GetInstance.Log(Msg, Level);
end;

function Tmsadpsvc.GetGapFillTablesAsString: string;
var
  MaskStr, SchemaNames, Schema, Tables, Prefixed: string;
  SchemaParts, MaskParts: TArray<string>;
  I: Integer;
  ResultList: TStringList;
begin
  Result := '';
  GTablesToLoadGapFill.Clear;

  if not GSettings.GapFillEnabled then
    Exit;
  MaskStr := Trim(GSettings.GapFillMask);
  if MaskStr = '' then
    Exit;

  ResultList := TStringList.Create;
  try
    ResultList.Sorted := True;
    ResultList.Delimiter := ';';
    ResultList.Duplicates := dupIgnore;
    ResultList.StrictDelimiter := True;

    MaskParts := MaskStr.Split([';']);
    SchemaNames := GetSchemaNames;
    SchemaParts := SchemaNames.Split([';']);
    for I := 0 to High(SchemaParts) do
    begin
      Schema := Trim(SchemaParts[I]);
      if Schema = '' then
        Continue;

      Tables := GetSchemaTablesByMasks(Schema, MaskParts);
      if Tables = '' then
        Continue;

      Prefixed := Schema + '.' + StringReplace(Tables, ';', ';' + Schema + '.', [rfReplaceAll]);
      ResultList.AddStrings(Prefixed.Split([';']));
    end;

    GTablesToLoadGapFill.AddStrings(ResultList);
  finally
    ResultList.Free;
  end;

  Result := GTablesToLoadGapFill.DelimitedText;
end;

procedure Tmsadpsvc.LoadSpecialSources;
var
  DB: TmsaSQLiteUserDatabase;
  SpecID, ParentID: Integer;
  Sections: TList<TSections>;
  S: TSections;
  Source: TSpecialDataSource;
  IntervalStr, EnabledStr, CheckStr, CommitStr: string;
  ParsedTableName: string;
  ParsedQueryIndex: Integer;
  IsExample: Boolean;
begin
  GSpecialSources.Clear;

  DB := TmsaSQLiteUserDatabase.Create(GConfigParams, '', '');
  try
    SpecID := DB.SectionExists(-1, SSpecialDataSources);
    if SpecID < 1 then
    begin
      WriteLog('Раздел "SpecialDataSources" не найден — Special-источников нет');
      Exit;
    end;

    Sections := TList<TSections>.Create;
    try
      DB.ReadSections(SpecID, Sections);

      for S in Sections do
      begin
        if VarIsNull(S.parent_id) then
          Continue;
        ParentID := Integer(S.parent_id);
        if ParentID <> SpecID then
          Continue;

        if not ParseSpecialSectionName(S.section_name, ParsedTableName,
          ParsedQueryIndex, IsExample) then
        begin
          if IsExample then
            WriteLog('Special: пропуск раздела-примера "' + S.section_name + '"')
          else
            WriteLog('Special: некорректное имя раздела "' + S.section_name +
              '" — пропуск', llWarning);
          Continue;
        end;

        Source.SectionName := S.section_name;
        Source.TableName := ParsedTableName;
        Source.QueryIndex := ParsedQueryIndex;

        Source.SelectSQL := Trim(DB.ReadValue(S.id, SSpecialSelectSQL));
        if Source.SelectSQL = '' then
        begin
          WriteLog('Special: источник "' + Source.SectionName +
            '" — пустой SelectSQL, пропускаем', llWarning);
          Continue;
        end;

        IntervalStr := Trim(DB.ReadValue(S.id, SSpecialIntervalSec));
        Source.IntervalSec := StrToIntDef(IntervalStr, DefaultSpecialIntervalSec);

        EnabledStr := Trim(DB.ReadValue(S.id, SSpecialEnabled));
        Source.Enabled := (EnabledStr = '') or (EnabledStr = '1');

        CheckStr := Trim(DB.ReadValue(S.id, SSpecialCheckExists));
        Source.CheckExists := (CheckStr = '') or (CheckStr = '1');

        CommitStr := Trim(DB.ReadValue(S.id, SSpecialCommitEvery));
        Source.CommitEvery := StrToIntDef(CommitStr,
          StrToIntDef(SDefaultSpecialCommitEvery, 10000));
        if Source.CommitEvery < 0 then
          Source.CommitEvery := 0;

        Source.InsertSQL := BuildSpecialInsertSQL(Source.TableName, Source.CheckExists);
        if Source.InsertSQL = '' then
        begin
          WriteLog('Special: источник "' + Source.SectionName +
            '" — не удалось построить INSERT, пропускаем', llWarning);
          Continue;
        end;

        GSpecialSources.Add(Source);

        WriteLog(Format(
            'Special: загружен "%s" (таблица=%s, #%d), Enabled=%s, IntervalSec=%d, CheckExists=%s, CommitEvery=%d',
            [Source.SectionName, Source.TableName, Source.QueryIndex,
              BoolToStr(Source.Enabled, True),
              Source.IntervalSec,
              BoolToStr(Source.CheckExists, True),
              Source.CommitEvery]));
        WriteLog('  SelectSQL: ' + Source.SelectSQL);
        WriteLog('  InsertSQL: ' + Source.InsertSQL);
      end;
    finally
      Sections.Free;
    end;
  finally
    DB.Free;
  end;

  WriteLog(Format('Special: всего источников: %d', [GSpecialSources.Count]));
end;

function Tmsadpsvc.BuildSpecialInsertSQL(const ATableName: string; ACheckExists: Boolean = True): string;
var
  Fields, KeyFields: string;
  FieldArr, KeyArr: TArray<string>;
  Cols, Params, NotExists: string;
  I: Integer;
begin
  Result := '';

  Fields := GetTableFields(ATableName);
  if Fields = '' then
  begin
    WriteLog('BuildSpecialInsertSQL(' + ATableName + '): нет полей', llWarning);
    Exit;
  end;

  FieldArr := Fields.Split([';']);

  Cols := '';
  Params := '';
  for I := 0 to High(FieldArr) do
  begin
    if Cols <> '' then
    begin
      Cols := Cols + ', ';
      Params := Params + ', ';
    end;
    Cols := Cols + FieldArr[I];
    Params := Params + ':' + FieldArr[I];
  end;

  Result :=
    'INSERT INTO ' + ATableName + ' (' + Cols + ') ' +
    'SELECT ' + Cols +
    ' FROM (VALUES (' + Params + ')) AS v(' + Cols + ')';

  if ACheckExists then
  begin
    KeyFields := GetTableKeyFields(ATableName);
    if KeyFields = '' then
    begin
      WriteLog('BuildSpecialInsertSQL(' + ATableName +
        '): CheckExists=True, но PK не найден — INSERT без WHERE NOT EXISTS',
        llWarning);
      Exit;
    end;

    KeyArr := KeyFields.Split([';']);
    NotExists := '';
    for I := 0 to High(KeyArr) do
    begin
      if NotExists <> '' then
        NotExists := NotExists + ' AND ';
      NotExists := NotExists + KeyArr[I] + ' = v.' + KeyArr[I];
    end;

    Result := Result +
      ' WHERE NOT EXISTS (SELECT 1 FROM ' + ATableName +
      ' WHERE ' + NotExists + ')';
  end;
end;

procedure Tmsadpsvc.LogSpecialSources;
var
  I: Integer;
  S: TSpecialDataSource;
begin
  if GSpecialSources.Count = 0 then
  begin
    WriteLog('Special-источники: список пуст');
    Exit;
  end;

  WriteLog('Special-источники (' + IntToStr(GSpecialSources.Count) + '):');
  for I := 0 to GSpecialSources.Count - 1 do
  begin
    S := GSpecialSources[I];
    WriteLog(Format('  [%d] %s (таблица=%s, #%d) — Enabled=%s, IntervalSec=%d, CheckExists=%s, CommitEvery=%d',
        [I + 1, S.SectionName, S.TableName, S.QueryIndex,
          BoolToStr(S.Enabled, True),
          S.IntervalSec,
          BoolToStr(S.CheckExists, True),
          S.CommitEvery]));
  end;
end;

function Tmsadpsvc.ParseSpecialSectionName(const AName: string; out ATableName: string; out AQueryIndex: Integer; out
  AIsExample: Boolean): Boolean;
var
  S, Suffix, NumStr: string;
  P, Idx: Integer;
begin
  Result := False;
  ATableName := '';
  AQueryIndex := 0;
  AIsExample := False;

  S := Trim(AName);
  if S = '' then
    Exit;

  if S.EndsWith(SSpecialExampleSuffix, True) then
  begin
    AIsExample := True;
    ATableName := Trim(Copy(S, 1, Length(S) - Length(SSpecialExampleSuffix)));
    Exit;
  end;

  ATableName := S;
  AQueryIndex := 1;
  Result := True;

  P := LastDelimiter(' ', S);
  if P > 0 then
  begin
    Suffix := Copy(S, P + 1, MaxInt);
    if (Length(Suffix) >= 2) and (Suffix[1] = '#') then
    begin
      NumStr := Copy(Suffix, 2, MaxInt);
      if TryStrToInt(NumStr, Idx) and (Idx >= 1) then
      begin
        ATableName := Trim(Copy(S, 1, P - 1));
        AQueryIndex := Idx;
      end
      else
        Result := False;
    end;
  end;

  if ATableName = '' then
    Result := False;
end;

procedure Tmsadpsvc.EnsureSpecialExampleSection(ADB: TmsaSQLiteUserDatabase; AParentID: Integer);
var
  ExName: string;
  SId: Integer;
begin
  if (ADB = nil) or (AParentID < 1) then
    Exit;

  ExName := SSpecialExampleTableName + SSpecialExampleSuffix;

  if ADB.SectionExists(AParentID, ExName) <> -1 then
  begin
    WriteLog('Раздел-пример "' + ExName + '" уже есть');
    Exit;
  end;

  try
    SId := ADB.CreateSection(AParentID, ExName,
      'Пример. Скопируйте раздел, переименуйте в "' + SSpecialExampleTableName +
      ' #1" (без суффикса "' + Trim(SSpecialExampleSuffix) + '") и настройте.');
    if SId = -1 then
      Exit;

    ADB.WriteValue(SId, SSpecialSelectSQL,
      'SELECT CARD_CALC_ID, POINT_ID, CARD_CALC_DATE_B, CARD_CALC_DATE_E, CARD_CALC_CONSUM' + sLineBreak +
      '  FROM TIGER.CARD_CALC' + sLineBreak +
      ' WHERE CARD_CALC_DATE_B >= TRUNC(SYSDATE) - 1');

    ADB.WriteValue(SId, SSpecialIntervalSec, '0');
    ADB.WriteValue(SId, SSpecialEnabled, '0');
    ADB.WriteValue(SId, SSpecialCheckExists, '1');
    ADB.WriteValue(SId, SSpecialCommitEvery, SDefaultSpecialCommitEvery);

    WriteLog('Создан раздел-пример "' + ExName + '" (Enabled=0, не запускается)');
  except
    on E: Exception do
      WriteLog('Ошибка создания раздела-примера "' + ExName + '": ' +
        E.ClassName + ': ' + E.Message, llError);
  end;
end;

function Tmsadpsvc.GetUpdateTablesAsString: string;
var
  Raw, Item, Name: string;
  Parts: TArray<string>;
begin
  GTablesToUpdate.Clear;
  Raw := Trim(GSettings.UpdateTables);
  if Raw = '' then
  begin
    Result := '';
    Exit;
  end;

  Parts := Raw.Split([';']);
  for Item in Parts do
  begin
    Name := Trim(Item);
    if Name = '' then
      Continue;
    if GTablesToUpdate.IndexOf(Name) < 0 then
      GTablesToUpdate.Add(Name);
  end;

  Result := GTablesToUpdate.DelimitedText;
end;

procedure Tmsadpsvc.BuildUpdateQueries;
var
  TableName: string;
  Q: TQueries;
begin
  GUpdateQueries.Clear;

  for TableName in GTablesToUpdate do
  begin
    Q := BuildSQLs(TableName, '');
    if (Q.SelectSQL = '') or (Q.KeyFields = '') then
    begin
      WriteLog('BuildUpdateQueries: не удалось построить SQL для ' + TableName +
        ' — пропуск', llWarning);
      Continue;
    end;
    if Pos(';', Q.KeyFields) > 0 then
    begin
      WriteLog('BuildUpdateQueries: ' + TableName + ' — составной PK, пропуск', llWarning);
      Continue;
    end;
    GUpdateQueries.Add(TableName, Q);
  end;

  WriteLog('BuildUpdateQueries: подготовлено запросов: ' + IntToStr(GUpdateQueries.Count));
end;

function Tmsadpsvc.HasAnyWork: Boolean;
var
  I: Integer;
begin
  Result := (GTablesToLoad.Count > 0)
    or (GTablesToLoadGapFill.Count > 0)
    or (GTablesToUpdate.Count > 0)
    or (GSpecialSources.Count > 0);

  if not Result then
    for I := 0 to GPQSources.Count - 1 do
      if GPQSources[I].Enabled then
        Exit(True);
end;

procedure Tmsadpsvc.EnsurePQExampleSections(ADB: TmsaSQLiteUserDatabase; AParentID: Integer);

  function MakeParamValues: string;
  begin
    Result :=
      '100500;5757' + sLineBreak +
      '40507300;5758' + sLineBreak +
      '257300;5759';
  end;

  procedure EnsureKey(const ASectionName, AKeyName, ADefault: string);
  var
    SId: Integer;
  begin
    SId := ADB.SectionExists(AParentID, ASectionName);
    if SId = -1 then
      Exit;
    if not ADB.ValueExists(SId, AKeyName) then
    begin
      ADB.WriteValue(SId, AKeyName, ADefault);
      WriteLog('PQ: "' + ASectionName + '" — добавлен ключ "' + AKeyName +
        '" = "' + ADefault + '" (миграция)');
    end;
  end;

  procedure CreateOrMigrateOne(const ASectionName, ATableName: string);
  var
    SId: Integer;
    IsNew: Boolean;
  begin
    IsNew := ADB.SectionExists(AParentID, ASectionName) = -1;

    if IsNew then
    begin
      try
        SId := ADB.CreateSection(AParentID, ASectionName,
          'Пример PQ-запроса (шаблон, Enabled=0). ' +
          'Скопируйте/переименуйте под свою задачу и включите Enabled=1.');
        if SId = -1 then
        begin
          WriteLog('PQ: не удалось создать раздел-пример "' + ASectionName + '"', llWarning);
          Exit;
        end;

        ADB.WriteValue(SId, SPQSelectSQL,
          'select id, name, period_id from ' + ATableName +
          ' where id > :pmin_id and period = :pperiod_id');
        ADB.WriteValue(SId, SPQParamNames, 'pmin_id;pperiod_id');
        ADB.WriteValue(SId, SPQParamValues, MakeParamValues);
        ADB.WriteValue(SId, SPQTableName, ATableName);
        ADB.WriteValue(SId, SPQChunkSize, SDefaultPQChunkSize);
        ADB.WriteValue(SId, SPQCommitEvery, SDefaultPQCommitEvery);
        ADB.WriteValue(SId, SPQEnabled, SDefaultPQEnabled);
        ADB.WriteValue(SId, SPQIntervalSec, SDefaultPQIntervalSec);
        ADB.WriteValue(SId, SPQTotalRows, '');
        ADB.WriteValue(SId, SPQMinPK, '');
        ADB.WriteValue(SId, SPQMaxPK, '');
        ADB.WriteValue(SId, SPQCountSQL, '');
        ADB.WriteValue(SId, SPQMinPKSQL, '');
        ADB.WriteValue(SId, SPQMaxPKSQL, '');
        ADB.WriteValue(SId, SPQRowIdSQL, '');
        ADB.WriteValue(SId, SPQRidChunkWorkers, SDefaultRidChunkWorkers);

        WriteLog('PQ: создан раздел-пример "' + ASectionName + '"');
      except
        on E: Exception do
          WriteLog('PQ: ошибка создания раздела-примера "' + ASectionName + '": ' +
            E.ClassName + ': ' + E.Message, llError);
      end;
      Exit;
    end;

    WriteLog('PQ: раздел-пример "' + ASectionName + '" уже есть — проверка ключей');
    EnsureKey(ASectionName, SPQTotalRows, '');
    EnsureKey(ASectionName, SPQMinPK, '');
    EnsureKey(ASectionName, SPQMaxPK, '');
    EnsureKey(ASectionName, SPQCountSQL, '');
    EnsureKey(ASectionName, SPQMinPKSQL, '');
    EnsureKey(ASectionName, SPQMaxPKSQL, '');
  end;

begin
  if (ADB = nil) or (AParentID < 1) then
    Exit;

  CreateOrMigrateOne('TIGER.TABLE1 - Query1', 'TIGER.TABLE1');
  CreateOrMigrateOne('TIGER.TABLE2 - Query1', 'TIGER.TABLE2');
  CreateOrMigrateOne('TIGER.TABLE3 - Query1', 'TIGER.TABLE3');
end;

procedure Tmsadpsvc.LoadPQSources;
var
  DB: TmsaSQLiteUserDatabase;
  PQID, ParentID: Integer;
  Sections: TList<TSections>;
  S: TSections;
  Source: TPQDataSource;
  RawNames, RawValues, EnabledStr: string;
  NameArr, TempNames: TArray<string>;
  Lines, ValueParts: TArray<string>;
  Line: string;
  SetArr: TArray<TPQParamSet>;
  I, J, SetIdx, BadSets: Integer;
begin
  GPQSources.Clear;

  DB := TmsaSQLiteUserDatabase.Create(GConfigParams, '', '');
  try
    PQID := DB.SectionExists(-1, SPQSection);
    if PQID < 1 then
    begin
      WriteLog('PQ: раздел "' + SPQSection + '" не найден — источников нет');
      Exit;
    end;

    Sections := TList<TSections>.Create;
    try
      DB.ReadSections(PQID, Sections);

      for S in Sections do
      begin
        if VarIsNull(S.parent_id) then
          Continue;
        ParentID := Integer(S.parent_id);
        if ParentID <> PQID then
          Continue;

        Source.SectionName := S.section_name;
        Source.TableName := Trim(DB.ReadValue(S.id, SPQTableName));
        Source.SelectSQL := Trim(DB.ReadValue(S.id, SPQSelectSQL));
        RawNames := Trim(DB.ReadValue(S.id, SPQParamNames));
        RawValues := DB.ReadValue(S.id, SPQParamValues);
        EnabledStr := Trim(DB.ReadValue(S.id, SPQEnabled));

        Source.Enabled := StrToIntDef(EnabledStr, 0) <> 0;
        Source.ChunkSize := StrToIntDef(Trim(DB.ReadValue(S.id, SPQChunkSize)),
          StrToIntDef(SDefaultPQChunkSize, 20000));
        Source.CommitEvery := StrToIntDef(Trim(DB.ReadValue(S.id, SPQCommitEvery)),
          StrToIntDef(SDefaultPQCommitEvery, 10000));
        Source.IntervalSec := StrToIntDef(Trim(DB.ReadValue(S.id, SPQIntervalSec)), 0);

        Source.RowIdSQL := Trim(DB.ReadValue(S.id, SPQRowIdSQL));
        Source.RidChunkWorkers := StrToIntDef(Trim(DB.ReadValue(S.id, SPQRidChunkWorkers)),
          StrToIntDef(SDefaultRidChunkWorkers, 8));
        if Source.RidChunkWorkers < 1 then
          Source.RidChunkWorkers := 1;
        if Source.RidChunkWorkers > 32 then
          Source.RidChunkWorkers := 32;

        Source.TotalRows := StrToInt64Def(Trim(DB.ReadValue(S.id, SPQTotalRows)), 0);
        Source.MinPK := StrToInt64Def(Trim(DB.ReadValue(S.id, SPQMinPK)), -1);
        Source.MaxPK := StrToInt64Def(Trim(DB.ReadValue(S.id, SPQMaxPK)), -1);
        Source.CountSQL := Trim(DB.ReadValue(S.id, SPQCountSQL));
        Source.MinPKSQL := Trim(DB.ReadValue(S.id, SPQMinPKSQL));
        Source.MaxPKSQL := Trim(DB.ReadValue(S.id, SPQMaxPKSQL));
        if Source.TotalRows < 0 then
          Source.TotalRows := 0;

        if Source.ChunkSize < 100 then
          Source.ChunkSize := StrToIntDef(SDefaultPQChunkSize, 20000);
        if Source.CommitEvery < 0 then
          Source.CommitEvery := 0;
        if Source.IntervalSec < 0 then
          Source.IntervalSec := 0;

        if Source.SelectSQL = '' then
        begin
          WriteLog('PQ: "' + Source.SectionName + '" — пустой SelectSQL, пропуск', llWarning);
          Continue;
        end;
        if Source.TableName = '' then
        begin
          WriteLog('PQ: "' + Source.SectionName + '" — пустой TableName, пропуск', llWarning);
          Continue;
        end;

        Source.ParamNames := nil;
        if RawNames <> '' then
        begin
          NameArr := RawNames.Split([';']);
          TempNames := nil;
          for I := 0 to High(NameArr) do
          begin
            NameArr[I] := Trim(NameArr[I]);
            if NameArr[I] = '' then
              Continue;
            SetLength(TempNames, Length(TempNames) + 1);
            TempNames[High(TempNames)] := NameArr[I];
          end;
          Source.ParamNames := TempNames;
        end;

        Source.ParamValues := nil;
        SetArr := nil;
        BadSets := 0;
        if RawValues <> '' then
        begin
          Lines := RawValues.Replace(#13, #10).Split([#10]);
          SetIdx := 0;

          for Line in Lines do
          begin
            if Trim(Line) = '' then
              Continue;
            Inc(SetIdx);

            ValueParts := Line.Split([';']);
            for J := 0 to High(ValueParts) do
              ValueParts[J] := Trim(ValueParts[J]);

            if Length(Source.ParamNames) > 0 then
            begin
              if Length(ValueParts) <> Length(Source.ParamNames) then
              begin
                Inc(BadSets);
                WriteLog(Format(
                    'PQ: "%s" — набор #%d: %d значений при %d именах [%s], пропуск',
                    [Source.SectionName, SetIdx, Length(ValueParts),
                      Length(Source.ParamNames),
                      JoinStrArray(Source.ParamNames)]), llWarning);
                Continue;
              end;
            end;

            SetLength(SetArr, Length(SetArr) + 1);
            SetArr[High(SetArr)] := ValueParts;
          end;

          Source.ParamValues := SetArr;

          if BadSets > 0 then
            WriteLog(Format('PQ: "%s" — пропущено %d некорректных наборов параметров',
                [Source.SectionName, BadSets]), llWarning);
        end;

        if Length(Source.ParamValues) = 0 then
        begin
          WriteLog('PQ: "' + Source.SectionName +
            '" — нет наборов параметров, источник не добавлен', llWarning);
          Continue;
        end;

        GPQSources.Add(Source);

        WriteLog(Format(
            'PQ: загружен "%s" (table=%s, Enabled=%s, IntervalSec=%d, ' +
            'ChunkSize=%d, CommitEvery=%d, paramSets=%d, paramNames=[%s])',
            [Source.SectionName, Source.TableName,
              BoolToStr(Source.Enabled, True),
              Source.IntervalSec, Source.ChunkSize, Source.CommitEvery,
              Length(Source.ParamValues),
              JoinStrArray(Source.ParamNames)]));

        WriteLog(Format(
            'PQ:   prep: TotalRows=%d, MinPK=%d, MaxPK=%d, CountSQL=%s, ' +
            'MinPK_SQL=%s, MaxPK_SQL=%s, RowIdSQL=%s, RidWorkers=%d',
            [Source.TotalRows, Source.MinPK, Source.MaxPK,
              IfThen(Source.CountSQL <> '', 'задан', 'нет'),
              IfThen(Source.MinPKSQL <> '', 'задан', 'нет'),
              IfThen(Source.MaxPKSQL <> '', 'задан', 'нет'),
              IfThen(Source.RowIdSQL <> '', 'задан', 'нет'),
              Source.RidChunkWorkers]));
      end;
    finally
      Sections.Free;
    end;
  finally
    DB.Free;
  end;

  WriteLog(Format('PQ: всего источников: %d', [GPQSources.Count]));
end;

procedure Tmsadpsvc.LogPQSources;
var
  I, J: Integer;
  S: TPQDataSource;
begin
  if GPQSources.Count = 0 then
  begin
    WriteLog('PQ-источники: список пуст');
    Exit;
  end;

  WriteLog('PQ-источники (' + IntToStr(GPQSources.Count) + '):');
  for I := 0 to GPQSources.Count - 1 do
  begin
    S := GPQSources[I];
    WriteLog(Format(
        '  [%d] %s — TableName=%s, Enabled=%s, IntervalSec=%d, ' +
        'ChunkSize=%d, CommitEvery=%d, paramSets=%d',
        [I + 1, S.SectionName, S.TableName,
          BoolToStr(S.Enabled, True),
          S.IntervalSec, S.ChunkSize, S.CommitEvery, Length(S.ParamValues)]));
    for J := 0 to High(S.ParamValues) do
      WriteLog(Format('      set #%d: [%s]',
          [J + 1, JoinStrArray(S.ParamValues[J])]));
  end;
end;

initialization
  InitGlobalParams;
  GLogProc := GlobalLog;

finalization
  GLogProc := nil;
  if Assigned(msadpsvc) then
    msadpsvc.StopWatcher;

end.

