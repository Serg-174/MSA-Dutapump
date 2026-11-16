unit uConfigWatcher;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, MSA.Logger;

type
  TConfigWatcherThread = class(TThread)
  private
    FIntervalMs: Integer;
    FOnReload: TProc;
    FStopEvent: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(AIntervalMs: Integer; AOnReload: TProc);
    destructor Destroy; override;
    procedure Stop;
  end;

implementation

{ TConfigWatcherThread }

constructor TConfigWatcherThread.Create(AIntervalMs: Integer; AOnReload: TProc);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FIntervalMs := AIntervalMs;
  FOnReload := AOnReload;
  FStopEvent := TEvent.Create(nil, True, False, '');
end;

destructor TConfigWatcherThread.Destroy;
begin
  Stop;
  if Handle <> 0 then
    WaitFor;
  FStopEvent.Free;
  inherited;
end;

procedure TConfigWatcherThread.Stop;
begin
  Terminate;
  if Assigned(FStopEvent) then
    FStopEvent.SetEvent;
end;

procedure TConfigWatcherThread.Execute;
begin
  TSqliteLogger.GetInstance.Log('Watcher: старт, интервал=' + IntToStr(FIntervalMs) + ' мс', llInfo);

  while not Terminated do
  begin
    if FStopEvent.WaitFor(FIntervalMs) = wrSignaled then
      Break;
    if Terminated then
      Break;
    try
      if Assigned(FOnReload) then
        FOnReload();
    except
      on E: Exception do
        TSqliteLogger.GetInstance.Log('ConfigWatcher: ошибка перечитывания конфига: ' + E.ClassName + ': ' + E.Message, llError);
    end;
  end;
end;

end.

