unit uPumpTypes;

interface

 uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs, MSA.Logger,
  FireDAC.Comp.Client, FireDAC.Stan.Option;

type
  TDBKind = (dbSource, dbTarget);

  TConnSettings = record
    Host: string;
    Port: Integer;
    Database: string;
    User: string;
    Pass: string;
  end;

  TPumpSettings = record
    Source: TConnSettings;
    Target: TConnSettings;
    IgnoreTables: string;
    SchemaNames: string;
    TablesListMask: string;
    PumpIntervalSec: Integer;
    PumpWorkerCount: Integer;
    GapFillEnabled: Boolean;
    GapFillMask: string;
    GapFillChunkSize: Integer;
    GapFillWorkerCount: Integer;
    GapFillIntervalSec: Integer;

    UpdateTables: string;         // 'tiger.T1;tiger.T2'
    UpdateIntervalSec: Integer;   // 0 = один раз при старте
    UpdateWorkerCount: Integer;


    // --- PQ (параметризованные запросы) ---
    // Общие для всех PQ-воркеров настройки, читаются из PumpOptions.
    PQProgressEverySec: Integer;      // как часто логировать прогресс (сек)
    PQMaxConcurrentWorkers: Integer;  // макс. число одновременно работающих PQ-воркеров
  end;

  TQueries = record
    TableName: string;
    SelectSQL: string;
    InsertSQL: string;
    KeyFields: string;
  end;

  TIDs = record
    MinID: Int64;
    MaxID: Int64;
  end;

  TPumpOperation = (poAppend, poGapFill, poSpecial, poUpdate, poPQ);

  TPumpTask = record
    TableName: string;
    Operation: TPumpOperation;
  end;

  TPumpStats = record
    SessionID: TGUID;
    TableName: string;
    Operation: TPumpOperation;
    RowsRead: Int64;
    RowsWritten: Int64;
    GapFilled: Int64;
    ElapsedMs: Int64;
    ErrorMsg: string;
  end;

  TTableStat = record
    TableName: string;
    Runs: Integer;
    RowsRead: Int64;
    RowsWritten: Int64;
    TotalMs: Int64;
    LastRunMs: Int64;
    LastRunAt: TDateTime;
    LastError: string;
    GapFilled: Int64;
  end;

  TSpecialDataSource = record
    TableName: string;    // = имя секции (schema.table)
    SectionName: string;     // имя раздела как в конфиге: "TIGER.CARD_CALC #2"
    QueryIndex: Integer;     // 1, 2, 3… (для #N)
    SelectSQL: string;    // SELECT из Oracle (из конфига)
    InsertSQL: string;    // INSERT ... WHERE NOT EXISTS (генерируется)
    IntervalSec: Integer; // 0 = один раз
    Enabled: Boolean;
    CheckExists: Boolean;
    CommitEvery: Integer;  //10000
  end;

  // PQ: один набор значений параметров = один экземпляр воркера (поток)
  // Хранится как TArray<string> — конвертация в нужный тип выполняется при биндинге
  TPQParamSet = TArray<string>;

  TPQDataSource = record
    SectionName: string;  // имя раздела как в конфиге
    TableName: string;  //Таблица, которую будем обновлять (MS SQL)
    SelectSQL: string;  //Запрос к Oracle для получения данных, которыми будем обновлять
    ParamNames: TArray<string>;  //Имена параметров через;
    ParamValues: TArray<TPQParamSet>;  //Значения параметров
    ChunkSize: Integer;   //Размер порции данных
    CommitEvery: Integer; //   10000
    Enabled: Boolean;   //Доступен/не доступен
    IntervalSec: Integer;  // 0 = один раз
    RidChunkWorkers: Integer;   // число параллельных воркеров
  end;

type
  TStatWriteProc = procedure(const AStat: TPumpStats) of object;

  TLogProc = procedure(const Msg: string; Level: TLogLevel);

const
 PUMP_OPS_NAMES: array[TPumpOperation] of string =
    ('Append', 'GapFill', 'Special', 'Update', 'PQ');

  PUMP_INSERT_BATCH = 500;
  PUMP_COMMIT_EVERY = 10;
  PUMP_PROGRESS_MS = 10000;
  PUMP_GAPFILL_INSERT_BATCH = 500;

var
  GConfigParams: TStringList;
  GTablesToLoad: TStringList;
  GTablesToLoadGapFill: TStringList;
  GSettings: TPumpSettings;
  GQueries: TDictionary<string, TQueries>;
  GConfigLock: TCriticalSection;
  GLogProc: TLogProc;
  GTableStats: TDictionary<string, TTableStat>;
  GGapFillDone: TDictionary<string, Boolean>;
  GStatWriteProc: TStatWriteProc;
  GSessionID: TGUID;
  GSpecialSources: TList<TSpecialDataSource>;
  GPQSources: TList<TPQDataSource>;
  GTablesToUpdate: TStringList;
  GUpdateQueries: TDictionary<string, TQueries>;

procedure GLog(const Msg: string; Level: TLogLevel = llInfo);
function JoinStrArray(const A: TArray<string>; const Sep: string = ';'): string;

function CurrentSettings: TPumpSettings;
procedure MakeQueryStreaming(Q: TFDQuery; ARowsetSize: Integer = 2000);

procedure UpdateTableStat(const ATableName: string; ARowsRead, ARowsWritten, AElapsedMs: Int64; AGapFilled: Int64 = 0;
  const AError: string = '');

implementation

procedure MakeQueryStreaming(Q: TFDQuery; ARowsetSize: Integer);
begin
  if Q = nil then
    Exit;
  Q.FetchOptions.Mode := fmOnDemand;
  Q.FetchOptions.Unidirectional := True;
  Q.FetchOptions.AutoFetchAll := afDisable;
  if ARowsetSize < 100 then
    ARowsetSize := 100;
  Q.FetchOptions.RowsetSize := ARowsetSize;
end;

function JoinStrArray(const A: TArray<string>; const Sep: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then Result := Result + Sep;
    Result := Result + A[I];
  end;
end;

function CurrentSettings: TPumpSettings;
begin
  GConfigLock.Enter;
  try
    Result := GSettings;
  finally
    GConfigLock.Leave;
  end;
end;

procedure GLog(const Msg: string; Level: TLogLevel);
begin
  if Assigned(GLogProc) then
    GLogProc(Msg, Level)
  else
    TSqliteLogger.GetInstance.Log(Msg, Level);
end;

procedure UpdateTableStat(const ATableName: string; ARowsRead, ARowsWritten, AElapsedMs: Int64; AGapFilled: Int64; const
  AError: string);
var
  Stat: TTableStat;
begin
  if ATableName = '' then
    Exit;
  GConfigLock.Enter;
  try
    if not GTableStats.TryGetValue(ATableName, Stat) then
    begin
      Stat.TableName := ATableName;
      Stat.Runs := 0;
      Stat.RowsRead := 0;
      Stat.RowsWritten := 0;
      Stat.TotalMs := 0;
      Stat.GapFilled := 0;
    end;

    Inc(Stat.Runs);
    Inc(Stat.RowsRead, ARowsRead);
    Inc(Stat.RowsWritten, ARowsWritten);
    Inc(Stat.TotalMs, AElapsedMs);
    Inc(Stat.GapFilled, AGapFilled);
    Stat.LastRunMs := AElapsedMs;
    Stat.LastRunAt := Now;
    Stat.LastError := AError;

    GTableStats.AddOrSetValue(ATableName, Stat);
  finally
    GConfigLock.Leave;
  end;
end;

initialization
  GConfigParams := TStringList.Create;
  GTablesToLoad := TStringList.Create;
  GTablesToLoadGapFill := TStringList.Create;
  GQueries := TDictionary<string, TQueries>.Create;
  GConfigLock := TCriticalSection.Create;
  GTableStats := TDictionary<string, TTableStat>.Create;
  GGapFillDone := TDictionary<string, Boolean>.Create;
  GSpecialSources := TList<TSpecialDataSource>.Create;
  GStatWriteProc := nil;
  GTablesToUpdate := TStringList.Create;
  GUpdateQueries := TDictionary<string, TQueries>.Create;
  GPQSources := TList<TPQDataSource>.Create;

finalization
  GSpecialSources.Free;
  GGapFillDone.Free;
  GTableStats.Free;
  GConfigLock.Free;
  GQueries.Free;
  GTablesToLoadGapFill.Free;
  GTablesToLoad.Free;
  GConfigParams.Free;
  GUpdateQueries.Free;
  GTablesToUpdate.Free;
  GPQSources.Free;

end.

