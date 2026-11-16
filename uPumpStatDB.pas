unit uPumpStatDB;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections, Data.DB, FireDAC.Comp.Client, FireDAC.Stan.Def,
  FireDAC.Stan.Param, FireDAC.Stan.Option, FireDAC.Phys.MSSQL, uPumpTypes,
  MSA.Logger;

type
  TPumpStatDB = class
  private
    FConn: TFDConnection;
    FQueue: TThreadedQueue<TPumpStats>;
    FThread: TThread;
    FSettings: TPumpSettings;
    FInserted: Integer;
    procedure EnsureTableExists;
    procedure WriterThreadExecute;
  public
    constructor Create(const ASettings: TPumpSettings);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure WriteStat(const AStat: TPumpStats);
  end;

implementation

uses uConst;

const
  TABLE_NAME = 'tiger.DataPumpServeiceStat';

{ TPumpStatDB }

constructor TPumpStatDB.Create(const ASettings: TPumpSettings);
begin
  inherited Create;
  FSettings := ASettings;
  FInserted := 0;
  FQueue := TThreadedQueue<TPumpStats>.Create(1024, INFINITE, INFINITE);
  GLog('StatDB: конструктор отработал');
end;

destructor TPumpStatDB.Destroy;
begin
  Stop;
  FQueue.Free;
  GLog(Format('StatDB: деструктор, всего вставлено=%d', [FInserted]));
  inherited;
end;

procedure TPumpStatDB.EnsureTableExists;
var
  SQL: string;
begin
  SQL :=
    'IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N''' + TABLE_NAME + ''') AND type in (N''U'')) ' +
    'BEGIN ' +
    'CREATE TABLE ' + TABLE_NAME + ' (' +
    '  ID INT IDENTITY(1,1) PRIMARY KEY, ' +
    '  SessionID UNIQUEIDENTIFIER NULL, ' +
    '  TableName NVARCHAR(255) NOT NULL, ' +
    '  Operation NVARCHAR(50)  NOT NULL, ' +
    '  RowsRead BIGINT         NOT NULL DEFAULT 0, ' +
    '  RowsWritten BIGINT      NOT NULL DEFAULT 0, ' +
    '  GapFilled BIGINT        NOT NULL DEFAULT 0, ' +
    '  ElapsedMs BIGINT        NOT NULL DEFAULT 0, ' +
    '  ErrorMsg NVARCHAR(MAX)  NULL, ' +
    '  CreatedAt DATETIME      NOT NULL DEFAULT GETDATE() ' +
    '); ' +
    'END';
  GLog('StatDB: EnsureTableExists - проверяю таблицу ' + TABLE_NAME);
  FConn.ExecSQL(SQL);
  GLog('StatDB: EnsureTableExists - таблица OK');
end;

procedure TPumpStatDB.Start;
begin
  GLog(Format('StatDB: Start - %s:%d/%s, user=%s', [FSettings.Target.Host, FSettings.Target.Port, FSettings.Target.Database, FSettings.Target.User]));

  FConn := TFDConnection.Create(nil);
  FConn.LoginPrompt := False;
  FConn.Params.Clear;
  FConn.Params.Add('DriverID=MSSQL');
  FConn.Params.Add('Server=' + FSettings.Target.Host + ',' + IntToStr(FSettings.Target.Port));
  FConn.Params.Add('Database=' + FSettings.Target.Database);
  FConn.Params.Add('User_Name=' + FSettings.Target.User);
  FConn.Params.Add('Password=' + FSettings.Target.Pass);
  FConn.Params.Add('OSAuthent=No');
  FConn.Params.Add('ODBCAdvanced=TrustServerCertificate=yes');
  FConn.Params.Add('ApplicationName=' + ServiceDescr);

  try
    FConn.Connected := True;
    GLog('StatDB: соединение установлено');
  except
    on E: Exception do
    begin
      GLog('StatDB: ОШИБКА подключения: ' + E.ClassName + ': ' + E.Message, llError);
      raise;
    end;
  end;

  try
    EnsureTableExists;
  except
    on E: Exception do
    begin
      GLog('StatDB: ОШИБКА EnsureTableExists: ' + E.ClassName + ': ' + E.Message, llError);
      raise;
    end;
  end;

  FThread := TThread.CreateAnonymousThread(WriterThreadExecute);
  FThread.FreeOnTerminate := False;
  FThread.Start;
  GLog('StatDB: поток-писатель запущен');
end;

procedure TPumpStatDB.Stop;
var
  EmptyStat: TPumpStats;
begin
  GLog('StatDB: Stop - начат');
  if Assigned(FThread) then
  begin
    EmptyStat.TableName := '';
    FQueue.PushItem(EmptyStat);
    GLog('StatDB: Stop - ждём поток-писатель');
    FThread.WaitFor;
    FreeAndNil(FThread);
    GLog('StatDB: Stop - поток-писатель остановлен');
  end;
  if Assigned(FConn) then
  begin
    if FConn.Connected then
      FConn.Connected := False;
    FreeAndNil(FConn);
    GLog('StatDB: Stop - соединение закрыто');
  end;
end;

procedure TPumpStatDB.WriteStat(const AStat: TPumpStats);
begin
  if (AStat.RowsRead = 0) and (AStat.RowsWritten = 0) and (AStat.GapFilled = 0)
     and (AStat.ErrorMsg = '') then
  begin
    GLog(Format('StatDB: WriteStat - пропуск пустой записи %s / %s',
      [AStat.TableName, PUMP_OPS_NAMES[AStat.Operation]]));
    Exit;
  end;

  GLog(Format('StatDB: WriteStat CALLED - %s / %s / w=%d / ms=%d, очередь=%d',
    [AStat.TableName, PUMP_OPS_NAMES[AStat.Operation],
     AStat.RowsWritten, AStat.ElapsedMs, FQueue.Count]));
  FQueue.PushItem(AStat);
end;

procedure TPumpStatDB.WriterThreadExecute;
var
  Stat: TPumpStats;
  Q: TFDQuery;
begin
  GLog('StatDB: WriterThreadExecute - стартовал');
  try
    Q := TFDQuery.Create(nil);
      try
        Q.Connection := FConn;
        Q.SQL.Text :=
          'INSERT INTO ' + TABLE_NAME +
          ' (SessionID, TableName, Operation, RowsRead, RowsWritten, GapFilled, ElapsedMs, ErrorMsg) ' +
          'VALUES (:SessionID, :TableName, :Operation, :RowsRead, :RowsWritten, :GapFilled, :ElapsedMs, :ErrorMsg)';
        Q.ParamByName('SessionID').DataType := ftGuid;
        Q.ParamByName('TableName').DataType := ftString;
        Q.ParamByName('Operation').DataType := ftString;
        Q.ParamByName('RowsRead').DataType := ftLargeint;
        Q.ParamByName('RowsWritten').DataType := ftLargeint;
        Q.ParamByName('GapFilled').DataType := ftLargeint;
        Q.ParamByName('ElapsedMs').DataType := ftLargeint;
        Q.ParamByName('ErrorMsg').DataType := ftString;
        Q.Prepare;
      GLog('StatDB: WriterThreadExecute - INSERT подготовлен');

      while True do
      begin
        if FQueue.PopItem(Stat) <> wrSignaled then
        begin
          GLog('StatDB: PopItem вернул не wrSignaled', llWarning);
          Break;
        end;
        if Stat.TableName = '' then
        begin
          GLog('StatDB: получен стоп-сигнал');
          Break;
        end;

      try
          Q.ParamByName('SessionID').AsGuid := Stat.SessionID;
          Q.ParamByName('TableName').AsString := Stat.TableName;
          Q.ParamByName('Operation').AsString := PUMP_OPS_NAMES[Stat.Operation];
          Q.ParamByName('RowsRead').AsLargeInt := Stat.RowsRead;
          Q.ParamByName('RowsWritten').AsLargeInt := Stat.RowsWritten;
          Q.ParamByName('GapFilled').AsLargeInt := Stat.GapFilled;
          Q.ParamByName('ElapsedMs').AsLargeInt := Stat.ElapsedMs;
          Q.ParamByName('ErrorMsg').AsString := Stat.ErrorMsg;
          Q.ExecSQL;
          Inc(FInserted);
          GLog(Format('StatDB: INSERT #%d OK - %s / %s, w=%d', [FInserted, Stat.TableName, PUMP_OPS_NAMES[Stat.Operation], Stat.RowsWritten]));
        except
          on E: Exception do
            GLog('StatDB: ОШИБКА INSERT: ' + E.ClassName + ': ' + E.Message, llError);
        end;
      end;
    finally
      Q.Free;
    end;
  except
    on E: Exception do
      GLog('StatDB: КРИТИЧЕСКАЯ ОШИБКА WriterThreadExecute: ' + E.ClassName + ': ' + E.Message, llError);
  end;
  GLog('StatDB: WriterThreadExecute - завершён');
end;

end.

