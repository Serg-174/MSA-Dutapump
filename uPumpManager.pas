unit uPumpManager;

interface

uses
  System.SysUtils, System.Classes, System.Math, System.StrUtils, System.Generics.Collections, System.SyncObjs,
  System.Diagnostics, uPumpTypes, uPumpWorker, uPumpWorkerAppend, uPumpWorkerGapFill, uPumpWorkerSpecial,
  uPumpWorkerUpdate, uPumpWorkerPQ;

type
  TPumpRun = class
  private
    FOperation: TPumpOperation;
    FWorkers: TObjectList<TPumpWorker>;
    FQueue: TThreadedQueue<TPumpTask>;
    FStopFlag: PBoolean;
    FSettings: TPumpSettings;
    function CreateWorker(AWorkerId: Integer): TPumpWorker;
    procedure FillQueue(var ATableCount: Integer);
  public
    constructor Create(const ASettings: TPumpSettings; AOperation: TPumpOperation; AStopFlag: PBoolean);
    destructor Destroy; override;
    procedure Run;
  end;

  TAppendScheduler = class(TThread)
  private
    FRunIndex: Integer;
    FStopFlag: PBoolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AStopFlag: PBoolean);
  end;

  TGapFillScheduler = class(TThread)
  private
    FStopFlag: PBoolean;
    function HasNewTables: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AStopFlag: PBoolean);
  end;

  TUpdateScheduler = class(TThread)
  private
    FStopFlag: PBoolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AStopFlag: PBoolean);
  end;

  TPumpManager = class
  private
    FAppendScheduler: TAppendScheduler;
    FGapFillScheduler: TGapFillScheduler;
    FUpdateScheduler: TUpdateScheduler;
    FSpecialWorkers: TObjectList<TPumpWorkerSpecial>;
    FPQWorkers: TObjectList<TPumpWorkerPQ>;
    FSpecialStopFlag: Boolean;
    FManagerStopFlag: Boolean;
    FPQStopFlag: Boolean;
    FProgressInitialized: Boolean;

    procedure StartSpecialWorkers;
    procedure StopSpecialWorkers;

    procedure StartPQWorkers;
    procedure StopPQWorkers;

    procedure EnsureProgressTable;

    function InitRidRanges(const Src: TPQDataSource; ASetIndex: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

implementation

uses
  MSA.Logger, FireDAC.Comp.Client, FireDAC.Stan.Def, FireDAC.Stan.Param, FireDAC.Stan.Option, FireDAC.Phys.MSSQL,
  FireDAC.Phys.Oracle, uPumpPQProgress, uPumpInsert;

const
  GAPFILL_POLL_MS = 5000;
  POP_TIMEOUT_MS = 500;

{ TPumpRun }

constructor TPumpRun.Create(const ASettings: TPumpSettings; AOperation: TPumpOperation; AStopFlag: PBoolean);
begin
  inherited Create;
  FOperation := AOperation;
  FSettings := ASettings;
  FStopFlag := AStopFlag;
  FWorkers := TObjectList<TPumpWorker>.Create(True);
  FQueue := TThreadedQueue<TPumpTask>.Create(1024, 0, POP_TIMEOUT_MS);
end;

destructor TPumpRun.Destroy;
begin
  FQueue.Free;
  FWorkers.Free;
  inherited;
end;

function TPumpRun.CreateWorker(AWorkerId: Integer): TPumpWorker;
begin
  case FOperation of
    poAppend:
      Result := TPumpWorkerAppend.Create(AWorkerId, 'A', FQueue, FStopFlag, FSettings);
    poGapFill:
      Result := TPumpWorkerGapFill.Create(AWorkerId, 'G', FQueue, FStopFlag, FSettings);
    poUpdate:
      Result := TPumpWorkerUpdate.Create(AWorkerId, 'U', FQueue, FStopFlag, FSettings);
  else
    Result := nil;
  end;
end;

procedure TPumpRun.FillQueue(var ATableCount: Integer);
var
  TableName: string;
  Task: TPumpTask;
begin
  ATableCount := 0;
  GConfigLock.Enter;
  try
    case FOperation of
      poAppend:
        for TableName in GTablesToLoad do
        begin
          Task.TableName := TableName;
          Task.Operation := poAppend;
          FQueue.PushItem(Task);
          Inc(ATableCount);
        end;
      poGapFill:
        for TableName in GTablesToLoadGapFill do
        begin
          if GGapFillDone.ContainsKey(TableName) then
            Continue;
          if not GQueries.ContainsKey(TableName) then
            Continue;
          Task.TableName := TableName;
          Task.Operation := poGapFill;
          FQueue.PushItem(Task);
          Inc(ATableCount);
        end;
      poUpdate:
        for TableName in GTablesToUpdate do
        begin
          if not GUpdateQueries.ContainsKey(TableName) then
            Continue;
          Task.TableName := TableName;
          Task.Operation := poUpdate;
          FQueue.PushItem(Task);
          Inc(ATableCount);
        end;
    end;
  finally
    GConfigLock.Leave;
  end;
end;

procedure TPumpRun.Run;
var
  I, WorkerCount, TableCount, ActualWorkers: Integer;
  W: TPumpWorker;
  SW: TStopwatch;
begin
  case FOperation of
    poAppend:
      WorkerCount := FSettings.PumpWorkerCount;
    poGapFill:
      WorkerCount := FSettings.GapFillWorkerCount;
    poUpdate:
      WorkerCount := FSettings.UpdateWorkerCount;
  else
    WorkerCount := 1;
  end;

  if WorkerCount < 1 then
    WorkerCount := 1;
  if WorkerCount > 64 then
    WorkerCount := 64;

  FillQueue(TableCount);
  if TableCount = 0 then
    Exit;

  ActualWorkers := WorkerCount;
  if TableCount < ActualWorkers then
    ActualWorkers := TableCount;

  SW := TStopwatch.StartNew;
  GLog(Format('PumpRun [%s]: старт, воркеров=%d, задач=%d',
      [PUMP_OPS_NAMES[FOperation], ActualWorkers, TableCount]));

  for I := 1 to ActualWorkers do
  begin
    if Assigned(FStopFlag) and FStopFlag^ then
      Break;
    W := CreateWorker(I);
    if W = nil then
      Continue;
    FWorkers.Add(W);
    W.Start;
  end;

  for W in FWorkers do
    if not W.Finished then
      W.WaitFor;

  SW.Stop;
  GLog(Format('PumpRun [%s]: завершЄн за %d мс',
      [PUMP_OPS_NAMES[FOperation], SW.ElapsedMilliseconds]));
end;

{ TAppendScheduler }

constructor TAppendScheduler.Create(AStopFlag: PBoolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRunIndex := 0;
  FStopFlag := AStopFlag;
end;

procedure TAppendScheduler.Execute;
var
  Run: TPumpRun;
  IntervalMs, Elapsed: Integer;
  Settings: TPumpSettings;
begin
  while not Terminated do
  begin
    Inc(FRunIndex);
    GLog(Format('=== Append: цикл #%d ===', [FRunIndex]));

    Settings := CurrentSettings;

    Run := TPumpRun.Create(Settings, poAppend, FStopFlag);
    try
      Run.Run;
    finally
      Run.Free;
    end;

    if Terminated then
      Break;
    if Assigned(FStopFlag) and FStopFlag^ then
      Break;

    IntervalMs := Settings.PumpIntervalSec * 1000;
    if IntervalMs < 1000 then
      IntervalMs := 1000;

    Elapsed := 0;
    while (Elapsed < IntervalMs) and (not Terminated) do
    begin
      if Assigned(FStopFlag) and FStopFlag^ then
        Break;
      Sleep(500);
      Inc(Elapsed, 500);
    end;
  end;

  GLog('Append: остановлен');
end;

{ TGapFillScheduler }

constructor TGapFillScheduler.Create(AStopFlag: PBoolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FStopFlag := AStopFlag;
end;

function TGapFillScheduler.HasNewTables: Boolean;
var
  TableName: string;
begin
  Result := False;
  GConfigLock.Enter;
  try
    if not GSettings.GapFillEnabled then
      Exit;
    if Trim(GSettings.GapFillMask) = '' then
      Exit;
    for TableName in GTablesToLoadGapFill do
    begin
      if GGapFillDone.ContainsKey(TableName) then
        Continue;
      if not GQueries.ContainsKey(TableName) then
        Continue;
      Result := True;
      Break;
    end;
  finally
    GConfigLock.Leave;
  end;
end;

procedure TGapFillScheduler.Execute;
var
  Run: TPumpRun;
  Elapsed: Integer;
  Settings: TPumpSettings;
  IntervalMs, SleepMs: Integer;
begin
  GLog('GapFill: scheduler запущен');

  while not Terminated do
  begin
    if Assigned(FStopFlag) and FStopFlag^ then
      Break;

    Settings := CurrentSettings;

    if Settings.GapFillEnabled and (Trim(Settings.GapFillMask) <> '') then
    begin
      if HasNewTables then
      begin
        Run := TPumpRun.Create(Settings, poGapFill, FStopFlag);
        try
          Run.Run;
        finally
          Run.Free;
        end;
      end;
    end;

    if Terminated then
      Break;
    if Assigned(FStopFlag) and FStopFlag^ then
      Break;

    if Settings.GapFillIntervalSec > 0 then
      IntervalMs := Settings.GapFillIntervalSec * 1000
    else
      IntervalMs := GAPFILL_POLL_MS;

    if IntervalMs < 1000 then
      IntervalMs := 1000;

    Elapsed := 0;
    SleepMs := 200;
    while (Elapsed < IntervalMs) and (not Terminated) do
    begin
      if Assigned(FStopFlag) and FStopFlag^ then
        Break;
      Sleep(SleepMs);
      Inc(Elapsed, SleepMs);
    end;
  end;

  GLog('GapFill: остановлен');
end;

{ TUpdateScheduler }

constructor TUpdateScheduler.Create(AStopFlag: PBoolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FStopFlag := AStopFlag;
end;

procedure TUpdateScheduler.Execute;
var
  Run: TPumpRun;
  Settings: TPumpSettings;
  IntervalMs, Elapsed: Integer;
begin
  GLog('Update: scheduler запущен');

  while not Terminated do
  begin
    if Assigned(FStopFlag) and FStopFlag^ then
      Break;

    Settings := CurrentSettings;

    if Trim(Settings.UpdateTables) = '' then
    begin
      GLog('Update: список таблиц пуст Ч scheduler завершЄн');
      Break;
    end;

    GLog('=== Update: цикл ===');
    Run := TPumpRun.Create(Settings, poUpdate, FStopFlag);
    try
      Run.Run;
    finally
      Run.Free;
    end;

    if Terminated then
      Break;
    if Assigned(FStopFlag) and FStopFlag^ then
      Break;

    if Settings.UpdateIntervalSec <= 0 then
    begin
      GLog('Update: интервал = 0 Ч scheduler завершЄн после одного запуска');
      Break;
    end;

    IntervalMs := Settings.UpdateIntervalSec * 1000;
    if IntervalMs < 1000 then
      IntervalMs := 1000;

    Elapsed := 0;
    while (Elapsed < IntervalMs) and (not Terminated) do
    begin
      if Assigned(FStopFlag) and FStopFlag^ then
        Break;
      Sleep(500);
      Inc(Elapsed, 500);
    end;
  end;

  GLog('Update: остановлен');
end;

{ TPumpManager }

constructor TPumpManager.Create;
begin
  inherited Create;
  FAppendScheduler := nil;
  FGapFillScheduler := nil;
  FUpdateScheduler := nil;
  FSpecialWorkers := nil;
  FPQWorkers := nil;
  FSpecialStopFlag := False;
  FManagerStopFlag := False;
  FPQStopFlag := False;
  FProgressInitialized := False;
end;

destructor TPumpManager.Destroy;
begin
  Stop;
  inherited;
end;

procedure TPumpManager.EnsureProgressTable;
var
  Conn: TFDConnection;
  Prog: TPQProgressDB;
begin
  if FProgressInitialized then
    Exit;

  Conn := TFDConnection.Create(nil);
  try
    Conn.LoginPrompt := False;
    Conn.Params.Clear;
    Conn.Params.Add('DriverID=MSSQL');
    Conn.Params.Add('Server=' + GSettings.Target.Host + ',' + IntToStr(GSettings.Target.Port));
    Conn.Params.Add('Database=' + GSettings.Target.Database);
    Conn.Params.Add('User_Name=' + GSettings.Target.User);
    Conn.Params.Add('Password=' + GSettings.Target.Pass);
    Conn.Params.Add('OSAuthent=No');
    Conn.Params.Add('ODBCAdvanced=TrustServerCertificate=yes');
    try
      Conn.Connected := True;
      Prog := TPQProgressDB.Create(Conn);
      try
        Prog.EnsureExists;
        GLog('PQ: progress-таблица проверена/создана');
        FProgressInitialized := True;
      finally
        Prog.Free;
      end;
    except
      on E: Exception do
        GLog('PQ: ќЎ»Ѕ ј EnsureProgressTable: ' + E.ClassName + ': ' + E.Message, llError);
    end;
  finally
    Conn.Free;
  end;
end;

function TPumpManager.InitRidRanges(const Src: TPQDataSource; ASetIndex: Integer): Boolean;
var
  SrcConn, TgtConn: TFDConnection;
  Q: TFDQuery;
  Prog: TPQProgressDB;
  PkInfo: TPkInfo;
  MinPK, MaxPK, TotalRows, StepPK, BoundPK: Int64;
  RidBounds: TArray<string>;
  ParamSet: TPQParamSet;
  N, I: Integer;
  NeedMinMax, NeedCount: Boolean;

  function BindUserParams(AQ: TFDQuery): Boolean;
  var
    K: Integer;
    P: TFDParam;
  begin
    Result := True;
    for K := 0 to High(Src.ParamNames) do
    begin
      P := AQ.FindParam(Src.ParamNames[K]);
      if P = nil then
        Continue;
      try
        P.AsLargeInt := StrToInt64(ParamSet[K]);
      except
        try
          P.AsFloat := StrToFloat(ParamSet[K]);
        except
          P.AsString := ParamSet[K];
        end;
      end;
    end;
  end;

  function RidAtPk(APk: Int64): string;
  begin
    Result := '';
    Q.ParamByName('pk').AsLargeInt := APk;
    Q.Open;
    if not Q.IsEmpty then
      Result := Q.Fields[0].AsString;
    Q.Close;
  end;

begin
  Result := False;

  N := Src.RidChunkWorkers;
  if N < 1 then
    N := 1;
  if N > 32 then
    N := 32;

  if (ASetIndex < 1) or (ASetIndex > Length(Src.ParamValues)) then
    Exit;
  ParamSet := Src.ParamValues[ASetIndex - 1];

  TgtConn := TFDConnection.Create(nil);
  try
    TgtConn.LoginPrompt := False;
    TgtConn.Params.Clear;
    TgtConn.Params.Add('DriverID=MSSQL');
    TgtConn.Params.Add('Server=' + GSettings.Target.Host + ',' + IntToStr(GSettings.Target.Port));
    TgtConn.Params.Add('Database=' + GSettings.Target.Database);
    TgtConn.Params.Add('User_Name=' + GSettings.Target.User);
    TgtConn.Params.Add('Password=' + GSettings.Target.Pass);
    TgtConn.Params.Add('OSAuthent=No');
    TgtConn.Params.Add('ODBCAdvanced=TrustServerCertificate=yes');
    TgtConn.Connected := True;

    Prog := TPQProgressDB.Create(TgtConn);
    try
      Prog.EnsureExists;

      if Prog.HasChunks(Src.SectionName, ASetIndex) then
      begin
        GLog(Format('RID-init: "%s" #%d диапазоны уже есть (%d) Ч init пропущен',
            [Src.SectionName, ASetIndex, Prog.GetChunkCount(Src.SectionName, ASetIndex)]));
        Result := True;
        Exit;
      end;

      PkInfo := GetTablePKSingle(TgtConn, Src.TableName);
      if PkInfo.ErrorMsg <> '' then
      begin
        GLog(Format('RID-init: "%s" Ч PK target: %s',
            [Src.SectionName, PkInfo.ErrorMsg]), llError);
        Exit;
      end;
      GLog(Format('RID-init: "%s" Ч PK target = %s',
          [Src.SectionName, PkInfo.FieldName]));

      MinPK := Src.MinPK;
      MaxPK := Src.MaxPK;
      TotalRows := Src.TotalRows;

      NeedMinMax := (MinPK < 0) or (MaxPK <= 0) or (MaxPK <= MinPK);
      NeedCount := TotalRows <= 0;

      if NeedMinMax or NeedCount then
      begin
        GLog(Format('RID-init: "%s" #%d Ч MinPK/MaxPK/TotalRows не заданы, считаем из source...',
            [Src.SectionName, ASetIndex]));

        SrcConn := TFDConnection.Create(nil);
        try
          SrcConn.LoginPrompt := False;
          SrcConn.Params.Clear;
          SrcConn.Params.Add('DriverID=Ora');
          SrcConn.Params.Add('Database=' + GSettings.Source.Host + ':' +
            IntToStr(GSettings.Source.Port) + '/' + GSettings.Source.Database);
          SrcConn.Params.Add('User_Name=' + GSettings.Source.User);
          SrcConn.Params.Add('Password=' + GSettings.Source.Pass);
          SrcConn.Connected := True;

          Q := TFDQuery.Create(nil);
          try
            Q.Connection := SrcConn;

            if NeedMinMax and NeedCount then
              Q.SQL.Text :=
                'SELECT COUNT(*) AS CNT, MIN(' + PkInfo.FieldName + ') AS MN, MAX(' +
                PkInfo.FieldName + ') AS MX FROM (' + Src.SelectSQL + ')'
            else if NeedMinMax then
              Q.SQL.Text :=
                'SELECT MIN(' + PkInfo.FieldName + ') AS MN, MAX(' +
                PkInfo.FieldName + ') AS MX FROM (' + Src.SelectSQL + ')'
            else
              Q.SQL.Text :=
                'SELECT COUNT(*) AS CNT FROM (' + Src.SelectSQL + ')';

            if not BindUserParams(Q) then
            begin
              GLog('RID-init: не удалось прив€зать параметры', llError);
              Exit;
            end;

            Q.Open;
            if Q.IsEmpty then
            begin
              GLog('RID-init: пустой результат COUNT/MIN/MAX', llWarning);
              Exit;
            end;

            if NeedCount then
              TotalRows := Q.FieldByName('CNT').AsLargeInt;

            if NeedMinMax then
            begin
              if Q.FieldByName('MN').IsNull or Q.FieldByName('MX').IsNull then
              begin
                GLog(Format('RID-init: "%s" #%d Ч источник пуст (MIN/MAX = NULL)',
                    [Src.SectionName, ASetIndex]));
                for I := 0 to N - 1 do
                begin
                  Prog.Init(Src.SectionName, ASetIndex, 0, 0, 0, I + 1, '', '');
                  Prog.MarkCompleted(Src.SectionName, ASetIndex, I + 1);
                end;
                Result := True;
                Exit;
              end;
              MinPK := Q.FieldByName('MN').AsLargeInt;
              MaxPK := Q.FieldByName('MX').AsLargeInt;
            end;

            GLog(Format('RID-init: "%s" #%d Ч COUNT=%d, MIN=%d, MAX=%d',
                [Src.SectionName, ASetIndex, TotalRows, MinPK, MaxPK]));
          finally
            Q.Free;
          end;
        finally
          SrcConn.Free;
        end;
      end;

      if (MinPK < 0) or (MaxPK <= 0) or (MaxPK <= MinPK) then
      begin
        GLog(Format('RID-init: "%s" #%d Ч некорректные MinPK/MaxPK (MinPK=%d, MaxPK=%d)',
            [Src.SectionName, ASetIndex, MinPK, MaxPK]), llError);
        Exit;
      end;

      SrcConn := TFDConnection.Create(nil);
      try
        SrcConn.LoginPrompt := False;
        SrcConn.Params.Clear;
        SrcConn.Params.Add('DriverID=Ora');
        SrcConn.Params.Add('Database=' + GSettings.Source.Host + ':' +
          IntToStr(GSettings.Source.Port) + '/' + GSettings.Source.Database);
        SrcConn.Params.Add('User_Name=' + GSettings.Source.User);
        SrcConn.Params.Add('Password=' + GSettings.Source.Pass);
        SrcConn.Connected := True;

        Q := TFDQuery.Create(nil);
        try
          Q.Connection := SrcConn;
          Q.SQL.Text :=
            'SELECT ROWID FROM (SELECT ROWID FROM ' + Src.TableName +
            ' WHERE ' + PkInfo.FieldName + ' >= :pk ORDER BY ' + PkInfo.FieldName +
            ') WHERE ROWNUM = 1';

          StepPK := (MaxPK - MinPK) div N;
          if StepPK < 1 then
            StepPK := 1;
          SetLength(RidBounds, N + 1);

          RidBounds[0] := '';
          for I := 1 to N - 1 do
          begin
            BoundPK := MinPK + I * StepPK;
            RidBounds[I] := RidAtPk(BoundPK);
          end;
          RidBounds[N] := '';

          for I := 0 to N - 1 do
          begin
            Prog.Init(Src.SectionName, ASetIndex,
              MinPK, MaxPK, TotalRows,
              I + 1,
              RidBounds[I], RidBounds[I + 1]);
            GLog(Format('RID-init: "%s" #%d диапазон #%d/%d: [%s .. %s]',
                [Src.SectionName, ASetIndex, I + 1, N,
                  IfThen(RidBounds[I] = '', '<null>', RidBounds[I]),
                  IfThen(RidBounds[I + 1] = '', '<null>', RidBounds[I + 1])]));
          end;

          Result := True;
        finally
          Q.Free;
        end;
      finally
        SrcConn.Free;
      end;
    finally
      Prog.Free;
    end;
  finally
    TgtConn.Free;
  end;
end;

procedure TPumpManager.StartSpecialWorkers;
var
  I: Integer;
  Source: TSpecialDataSource;
  Worker: TPumpWorkerSpecial;
begin
  FSpecialStopFlag := False;
  FSpecialWorkers := TObjectList<TPumpWorkerSpecial>.Create(True);
  GLog(Format('Special: старт, источников в GSpecialSources: %d', [GSpecialSources.Count]));

  GConfigLock.Enter;
  try
    for I := 0 to GSpecialSources.Count - 1 do
    begin
      Source := GSpecialSources[I];
      if not Source.Enabled then
      begin
        GLog('Special: пропуск отключЄнного источника ' + Source.TableName);
        Continue;
      end;

      GLog(Format('Special: создание воркера S%d дл€ %s...', [I + 1, Source.TableName]));
      try
        Worker := TPumpWorkerSpecial.Create(I + 1, Source, @FSpecialStopFlag, GSettings);
        FSpecialWorkers.Add(Worker);
        Worker.Start;
        GLog(Format('Special: воркер S%d дл€ %s запущен (интервал=%d сек)',
            [I + 1, Source.TableName, Source.IntervalSec]));
      except
        on E: Exception do
          GLog(Format('Special: ќЎ»Ѕ ј создани€ воркера S%d дл€ %s: %s: %s',
              [I + 1, Source.TableName, E.ClassName, E.Message]), llError);
      end;
    end;
  finally
    GConfigLock.Leave;
  end;

  GLog(Format('Special: запущено воркеров: %d', [FSpecialWorkers.Count]));
end;

procedure TPumpManager.StopSpecialWorkers;
var
  W: TPumpWorkerSpecial;
begin
  if FSpecialWorkers = nil then
    Exit;

  FSpecialStopFlag := True;

  for W in FSpecialWorkers do
  begin
    W.Terminate;
    W.WaitFor;
  end;
  FreeAndNil(FSpecialWorkers);
end;

procedure TPumpManager.StartPQWorkers;
var
  I, J, K, WorkerId, N: Integer;
  Src: TPQDataSource;
  Worker: TPumpWorkerPQ;
begin
  FPQStopFlag := False;
  FPQWorkers := TObjectList<TPumpWorkerPQ>.Create(True);
  WorkerId := 0;

  EnsureProgressTable;

  GConfigLock.Enter;
  try
    GLog(Format('PQ: старт, источников в GPQSources: %d', [GPQSources.Count]));

    for I := 0 to GPQSources.Count - 1 do
    begin
      Src := GPQSources[I];

      if not Src.Enabled then
      begin
        GLog('PQ: пропуск отключЄнного источника ' + Src.SectionName);
        Continue;
      end;

      for J := 0 to High(Src.ParamValues) do
      begin
        if Src.RowIdSQL <> '' then
        begin

          N := Src.RidChunkWorkers;
          if N < 1 then
            N := 1;
          if N > 32 then
            N := 32;

          if not InitRidRanges(Src, J + 1) then
          begin
            GLog(Format('PQ: "%s" #%d Ч ROWID-инициализаци€ не удалась, ' +
                'воркеры не запускаютс€',
                [Src.SectionName, J + 1]), llError);
            Continue;
          end;

          for K := 1 to N do
          begin
            Inc(WorkerId);
            try
              Worker := TPumpWorkerPQ.Create(WorkerId, Src, Src.ParamValues[J],
                J + 1, @FPQStopFlag, GSettings, K);
              FPQWorkers.Add(Worker);
              Worker.Start;
              GLog(Format('PQ: воркер PQ%d запущен (%s, set #%d, chunk #%d/%d)',
                  [WorkerId, Src.SectionName, J + 1, K, N]));
            except
              on E: Exception do
                GLog(Format('PQ: ќЎ»Ѕ ј создани€ воркера %s/set#%d/chunk#%d: %s: %s',
                    [Src.SectionName, J + 1, K, E.ClassName, E.Message]), llError);
            end;
          end;
        end
        else
        begin

          Inc(WorkerId);
          try
            Worker := TPumpWorkerPQ.Create(WorkerId, Src, Src.ParamValues[J],
              J + 1, @FPQStopFlag, GSettings);
            FPQWorkers.Add(Worker);
            Worker.Start;
            GLog(Format('PQ: воркер PQ%d запущен (%s, set #%d)',
                [WorkerId, Src.SectionName, J + 1]));
          except
            on E: Exception do
              GLog(Format('PQ: ќЎ»Ѕ ј создани€ воркера %s/set#%d: %s: %s',
                  [Src.SectionName, J + 1, E.ClassName, E.Message]), llError);
          end;
        end;
      end;
    end;
  finally
    GConfigLock.Leave;
  end;

  GLog(Format('PQ: запущено воркеров: %d', [FPQWorkers.Count]));
end;

procedure TPumpManager.StopPQWorkers;
var
  W: TPumpWorkerPQ;
begin
  if FPQWorkers = nil then
    Exit;

  FPQStopFlag := True;

  for W in FPQWorkers do
  begin
    W.Terminate;
    W.WaitFor;
  end;
  FreeAndNil(FPQWorkers);
end;

procedure TPumpManager.Start;
begin
  FManagerStopFlag := False;

  if FAppendScheduler = nil then
  begin
    FAppendScheduler := TAppendScheduler.Create(@FManagerStopFlag);
    FAppendScheduler.Start;
    GLog('PumpManager: append scheduler запущен');
  end;

  if FGapFillScheduler = nil then
  begin
    FGapFillScheduler := TGapFillScheduler.Create(@FManagerStopFlag);
    FGapFillScheduler.Start;
    GLog('PumpManager: gapfill scheduler запущен');
  end;

  if FUpdateScheduler = nil then
  begin
    FUpdateScheduler := TUpdateScheduler.Create(@FManagerStopFlag);
    FUpdateScheduler.Start;
    GLog('PumpManager: update scheduler запущен');
  end;

  StartSpecialWorkers;
  StartPQWorkers;
end;

procedure TPumpManager.Stop;
begin
  FManagerStopFlag := True;

  if FAppendScheduler <> nil then
  begin
    GLog('PumpManager: остановка append воркеров');
    FAppendScheduler.Terminate;
    FAppendScheduler.WaitFor;
    FreeAndNil(FAppendScheduler);
  end;

  if FGapFillScheduler <> nil then
  begin
    GLog('PumpManager: остановка gapfill воркеров');
    FGapFillScheduler.Terminate;
    FGapFillScheduler.WaitFor;
    FreeAndNil(FGapFillScheduler);
  end;

  if FUpdateScheduler <> nil then
  begin
    GLog('PumpManager: остановка update scheduler');
    FUpdateScheduler.Terminate;
    FUpdateScheduler.WaitFor;
    FreeAndNil(FUpdateScheduler);
  end;

  if FSpecialWorkers <> nil then
  begin
    GLog('PumpManager: остановка special воркеров');
    StopSpecialWorkers;
  end;

  if FPQWorkers <> nil then
  begin
    GLog('PumpManager: остановка PQ воркеров');
    StopPQWorkers;
  end;
end;

end.

