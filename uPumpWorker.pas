unit uPumpWorker;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections, System.Diagnostics, uPumpTypes,
  uPumpConnection, MSA.Logger;

type
  TPumpWorker = class(TThread)
  private
    FLogPrefix: string;
    FQueue: TThreadedQueue<TPumpTask>;
  protected
    FWorkerId: Integer;
    FCurrentTable: string;
    FStopFlag: PBoolean;
    FSettings: TPumpSettings;
    FStats: TPumpStats;
    FConnections: TPumpConnections;
    procedure Execute; override;
    procedure DoWork(const ATask: TPumpTask; const AQuery: TQueries); virtual; abstract;
    procedure Log(const Msg: string; Level: TLogLevel = llInfo);
    property Connections: TPumpConnections read FConnections;
  public
    constructor Create(AWorkerId: Integer; const ALogPrefix: string; AQueue: TThreadedQueue<TPumpTask>; AStopFlag:
      PBoolean; const ASettings: TPumpSettings);
    destructor Destroy; override;
  end;

implementation

constructor TPumpWorker.Create(AWorkerId: Integer; const ALogPrefix: string; AQueue: TThreadedQueue<TPumpTask>;
  AStopFlag: PBoolean; const ASettings: TPumpSettings);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FWorkerId := AWorkerId;
  FLogPrefix := ALogPrefix;
  FCurrentTable := '';
  FQueue := AQueue;
  FStopFlag := AStopFlag;
  FSettings := ASettings;

  FConnections := TPumpConnections.Create(ASettings);
end;

destructor TPumpWorker.Destroy;
begin
  FConnections.Free;
  inherited;
end;

procedure TPumpWorker.Log(const Msg: string; Level: TLogLevel);
var
  Prefix: string;
begin
  if FCurrentTable <> '' then
    Prefix := Format('[%s%d (%s)] ', [FLogPrefix, FWorkerId, FCurrentTable])
  else
    Prefix := Format('[%s%d] ', [FLogPrefix, FWorkerId]);
  GLog(Prefix + Msg, Level);
end;

procedure TPumpWorker.Execute;
var
  Task: TPumpTask;
  Query: TQueries;
  Found: Boolean;
begin
  try
    Log('Старт воркера');
    FConnections.Open;

    try
      while not FStopFlag^ do
      begin
        Task.TableName := '';

        if FQueue.PopItem(Task) <> wrSignaled then
        begin
          if FStopFlag^ then
            Break;
          Continue;
        end;

        if Task.TableName = '' then
          Break;

        if FStopFlag^ then
          Break;

        GConfigLock.Enter;
        try
          if Task.Operation = poUpdate then
            Found := GUpdateQueries.TryGetValue(Task.TableName, Query)
          else
            Found := GQueries.TryGetValue(Task.TableName, Query);
        finally
          GConfigLock.Leave;
        end;

        if not Found then
        begin
          Log('Нет запроса для таблицы ' + Task.TableName, llWarning);
          Continue;
        end;

        FStats.SessionID := GSessionID;
        FStats.TableName := Task.TableName;
        FStats.Operation := Task.Operation;
        FStats.RowsRead := 0;
        FStats.RowsWritten := 0;
        FStats.GapFilled := 0;
        FStats.ElapsedMs := 0;
        FStats.ErrorMsg := '';

        FCurrentTable := Task.TableName;
        var SW := TStopwatch.StartNew;
        var TaskError := '';
        try
          Log(Format('>>> %s [%s]', [Task.TableName, PUMP_OPS_NAMES[Task.Operation]]));
          DoWork(Task, Query);
          SW.Stop;

          if Task.Operation = poGapFill then
          begin
            if FSettings.GapFillIntervalSec = 0 then
            begin
              GConfigLock.Enter;
              try
                GGapFillDone.AddOrSetValue(Task.TableName, True);
              finally
                GConfigLock.Leave;
              end;
            end;
          end;

          case FStats.Operation of
            poAppend:
              Log(Format('<<< added=%d, время=%d мс',
                  [FStats.RowsWritten, SW.ElapsedMilliseconds]));
            poGapFill:
              Log(Format('<<< gapFilled=%d, время=%d мс',
                  [FStats.GapFilled, SW.ElapsedMilliseconds]));
          else
            Log(Format('<<< written=%d, время=%d мс',
                [FStats.RowsWritten, SW.ElapsedMilliseconds]));
          end;
        except
          on E: Exception do
          begin
            SW.Stop;
            TaskError := E.ClassName + ': ' + E.Message;
            Log(Format('!!! %s (после %d мс)',
                [TaskError, SW.ElapsedMilliseconds]), llError);
          end;
        end;
        FCurrentTable := '';

        FStats.ElapsedMs := SW.ElapsedMilliseconds;
        FStats.ErrorMsg := TaskError;

        UpdateTableStat(Task.TableName, FStats.RowsRead, FStats.RowsWritten,
          SW.ElapsedMilliseconds, FStats.GapFilled, TaskError);

        if Assigned(GStatWriteProc) then
          GStatWriteProc(FStats);
      end;
    finally
      FConnections.Close;
      Log('Воркер завершён');
    end;
  except
    on E: Exception do
      GLog(Format('[%s%d] КРИТИЧЕСКАЯ ОШИБКА воркера: %s: %s',
          [FLogPrefix, FWorkerId, E.ClassName, E.Message]), llError);
  end;
end;

end.

