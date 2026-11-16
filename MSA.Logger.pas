unit MSA.Logger;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections, System.TypInfo, Data.DB,
  FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Param, FireDAC.Stan.Def, FireDAC.Stan.Async, FireDAC.Phys.Intf,
  FireDAC.Phys.SQLite, FireDAC.Comp.Client, FireDAC.Comp.UI, FireDAC.DApt, FireDAC.Phys.SQLiteWrapper.Stat;

type
  TLogLevel = (llDebug, llInfo, llWarning, llError);

  TLogItem = class
  public
    Level: TLogLevel;
    Text: string;
    constructor Create(const AText: string; ALevel: TLogLevel);
  end;

  TSqliteWriterThread = class(TThread)
  private
    FQueue: TThreadedQueue<TLogItem>;
    FDatabase: string;
    FConnection: TFDConnection;
    procedure LogThreadError(const S: string);
    function LogLevelToStr(ALogLevel: TLogLevel): string;
    procedure PrepareConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(AQueue: TThreadedQueue<TLogItem>; const ADatabase: string);

  end;

  ILogger = interface
    ['{5B6A70C2-6E7B-4D38-9D18-0D42D6F65B5A}']
    procedure Start(const ADatabase: string);
    procedure Stop;
    procedure Log(const Msg: string; Level: TLogLevel = llInfo);
    function GetDatabaseName: string;
    function GetQueueCount: Integer;
  end;

  TSqliteLogger = class(TInterfacedObject, ILogger)
  private
    class var
      FInstance: TSqliteLogger;
    class var
      FLock: TCriticalSection;
      FQueue: TThreadedQueue<TLogItem>;
      FThread: TSqliteWriterThread;
      FRunning: Boolean;
      FDatabase: string;
      FDatabaseLock: TCriticalSection;
      FQueueLock: TCriticalSection;
      FMinLogLevel: TLogLevel;
  public
    class function GetInstance: TSqliteLogger;

    constructor Create;
    destructor Destroy; override;

    procedure Start(const ADatabase: string);
    procedure Stop;
    procedure Log(const Msg: string; Level: TLogLevel = llInfo);
    function GetDatabaseName: string;
    procedure SetMinLogLevel(Level: TLogLevel);
    function GetQueueCount: Integer;
  end;

implementation

{ TLogItem }

constructor TLogItem.Create(const AText: string; ALevel: TLogLevel);
begin
  inherited Create;
  Text := AText;
  Level := ALevel;
end;

{ TSqliteWriterThread }

constructor TSqliteWriterThread.Create(AQueue: TThreadedQueue<TLogItem>; const ADatabase: string);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FQueue := AQueue;
  FDatabase := ADatabase;
end;

function TSqliteWriterThread.LogLevelToStr(ALogLevel: TLogLevel): string;
begin
  case ALogLevel of
    llDebug:
      Result := 'Debug';
    llInfo:
      Result := 'Info';
    llWarning:
      Result := 'Warning';
    llError:
      Result := 'Error';
  end;
end;

procedure TSqliteWriterThread.LogThreadError(const S: string);
var
  F: TextFile;
  FileName: string;
begin
  FileName := ChangeFileExt(FDatabase, '.log');
  AssignFile(F, FileName);
  if FileExists(FileName) then
    Append(F)
  else
    Rewrite(F);
  try
    Writeln(F, FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ' + S);
  finally
    CloseFile(F);
  end;
end;

procedure TSqliteWriterThread.PrepareConnection;
begin
  FConnection := TFDConnection.Create(nil);
  try
    with FConnection do
    begin
      LoginPrompt := False;
      Params.Clear;
      DriverName := 'SQLite';
      Params.Database := FDatabase;
      Params.Add('OpenMode=CreateUTF8');
      Params.Add('JournalMode=WAL');
      Params.Add('PersistentWAL=True');  
      Params.Add('Synchronous=Normal');
      Params.Add('BusyTimeout=5000');
      ResourceOptions.SilentMode := True;
      Connected := True;

      FConnection.ExecSQL('''
                   CREATE TABLE IF NOT EXISTS log
                   (id INTEGER PRIMARY KEY AUTOINCREMENT,
                    level TEXT, msg TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
                   ''');
    end;
  except
    on E: Exception do
      LogThreadError(E.ClassName + ': ' + E.Message);
  end;
end;

procedure TSqliteWriterThread.Execute;
const
  BATCH_SIZE = 5;
var
  Q: TFDQuery;
  Item: TLogItem;
  Batch: Integer;
begin
  PrepareConnection;
  try
    try

      Q := TFDQuery.Create(nil);

      try
        Q.Connection := FConnection;
        Q.SQL.Text := 'INSERT INTO log(level, msg) VALUES (:L, :M)';

        Q.ParamByName('L').DataType := ftString;
        Q.ParamByName('L').Size := 16;
        Q.ParamByName('M').DataType := ftString;
        Q.ParamByName('M').Size := 8192;

        Q.Prepare;

        Batch := 0;
        FConnection.StartTransaction;
        try
          while True do
          begin
            if FQueue.PopItem(Item) <> wrSignaled then
              Continue;

            if Item = nil then
              Break;

            try
              Q.ParamByName('L').AsString := LogLevelToStr(Item.Level);
              Q.ParamByName('M').AsString := Item.Text;
              Q.ExecSQL;
            finally
              Item.Free;
            end;

            Inc(Batch);
            if Batch >= BATCH_SIZE then
            begin
              FConnection.Commit;
              FConnection.StartTransaction;
              Batch := 0;
            end;
          end;

          FConnection.Commit;
        except
          FConnection.Rollback;
          raise;
        end;
      finally
        Q.Free;
      end;

    finally
      FConnection.Free;
    end;

  except
    on E: Exception do
      LogThreadError(E.ClassName + ': ' + E.Message);
  end;
end;

{ TSqliteLogger }

class function TSqliteLogger.GetInstance: TSqliteLogger;
begin
  FLock.Enter;
  try
    if FInstance = nil then
      FInstance := TSqliteLogger.Create;
    Result := FInstance;
  finally
    FLock.Leave;
  end;
end;

constructor TSqliteLogger.Create;
begin
  inherited;
  FQueue := TThreadedQueue<TLogItem>.Create(20000, 0, 0);
  FDatabaseLock := TCriticalSection.Create;
  FQueueLock := TCriticalSection.Create;
end;

destructor TSqliteLogger.Destroy;
begin
  Stop;
  FQueue.Free;
  FDatabaseLock.Free;
  FQueueLock.Free;
  inherited;
end;

procedure TSqliteLogger.Start(const ADatabase: string);
begin
  if FRunning then
    Exit;

  FDatabaseLock.Enter;
  try
    FDatabase := ADatabase;
  finally
    FDatabaseLock.Leave;
  end;

  FThread := TSqliteWriterThread.Create(FQueue, FDatabase);
  FRunning := True;
  Log('Log started', llInfo);
end;

procedure TSqliteLogger.Stop;
var
  Item: TLogItem;
begin
  if not FRunning then
    Exit;
  Log('Log stopped', llInfo);
  FRunning := False;

  FQueue.PushItem(nil);
  FThread.WaitFor;
  FreeAndNil(FThread);

  while FQueue.PopItem(Item) = wrSignaled do
    if Item <> nil then
      Item.Free;
end;

procedure TSqliteLogger.Log(const Msg: string; Level: TLogLevel);
begin
  if not FRunning then
    Exit;
  if Level < FMinLogLevel then
    Exit;
  FQueue.PushItem(TLogItem.Create(Msg, Level));
end;

function TSqliteLogger.GetDatabaseName: string;
begin
  FDatabaseLock.Enter;
  try
    Result := FDatabase;
  finally
    FDatabaseLock.Leave;
  end;
end;

function TSqliteLogger.GetQueueCount: Integer;
begin
  FQueueLock.Enter;
  try
    Result := FQueue.Count;
  finally
    FQueueLock.Leave;
  end;
end;

procedure TSqliteLogger.SetMinLogLevel(Level: TLogLevel);
begin
  FMinLogLevel := Level;
end;

initialization
  TSqliteLogger.FLock := TCriticalSection.Create;


finalization
  FreeAndNil(TSqliteLogger.FInstance);
  FreeAndNil(TSqliteLogger.FLock);

end.

