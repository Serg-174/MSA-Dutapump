unit uPumpWorkerPQ;

interface

uses
  System.SysUtils, System.Classes, System.Math, System.StrUtils, System.Diagnostics, System.Generics.Collections,
  System.Variants, System.TimeSpan, Data.DB, FireDAC.Comp.Client, FireDAC.Stan.Param, FireDAC.Stan.Option, uPumpTypes,
  uPumpWorker, uPumpInsert, uPumpPQProgress, MSA.Logger;

type
  TPumpWorkerPQ = class(TPumpWorker)
  private
    FSource: TPQDataSource;
    FParamSet: TPQParamSet;
    FSetIndex: Integer;
    FPkInfo: TPkInfo;
    FProgressDB: TPQProgressDB;
    FProgress: TPQProgress;
    FRunStartedAt: TDateTime;
    FChunkIndex: Integer;
    procedure DoWorkRid;
    function BuildParamValue(const AValue: string): Variant;
    function WrapCountSQL: string;
    function WrapMinMaxSQL: string;

    function WrapMinPK_SQL: string;
    function WrapMaxPK_SQL: string;
    function RunScalarUserSQL(const ASQL, APhase: string): Int64;
    function ComputeTotalRows: Int64;
    function ComputeMinPK: Int64;
    function ComputeMaxPK: Int64;

    function WrapWindowPKsSQL: string;
    function WrapWindowDataSQL: string;
    function BuildInsertSQL(const AFields: TArray<string>): string;

    procedure BindUserParams(AQ: TFDQuery);
    function BindUserParamsResult(AQ: TFDQuery): Boolean;

    function LoadWindowPKs(var ALastPK, ANewLastPK: Int64; ASourcePKs: TList<Int64>): Boolean;

    procedure LoadExistingTargetPKs(AFrom, ATo: Int64; AExisting: TDictionary<Int64, Boolean>);

    function InsertMissingRows(AFrom, ATo: Int64; ASourcePKs: TList<Int64>; AExisting: TDictionary<Int64, Boolean>): Int64;

    procedure DoWorkSource;
    procedure LogProgress(const APhase: string; AWindowFrom, AWindowTo: Int64; AWindowWritten, ATotalWritten: Int64);
    function FormatDuration(ADuration: TTimeSpan): string;
  protected
    procedure Execute; override;
    procedure DoWork(const ATask: TPumpTask; const AQuery: TQueries); override;
  public
    constructor Create(AWorkerId: Integer; const ASource: TPQDataSource; const AParamSet: TPQParamSet; ASetIndex:
      Integer; AStopFlag: PBoolean; const ASettings: TPumpSettings; AChunkIndex: Integer = 0);

    destructor Destroy; override;
  end;

implementation

{ TPumpWorkerPQ }

constructor TPumpWorkerPQ.Create(AWorkerId: Integer; const ASource: TPQDataSource; const AParamSet: TPQParamSet;
  ASetIndex: Integer; AStopFlag: PBoolean; const ASettings: TPumpSettings; AChunkIndex: Integer);
begin
  inherited Create(AWorkerId, 'PQ', nil, AStopFlag, ASettings);
  FSource := ASource;
  FParamSet := AParamSet;
  FSetIndex := ASetIndex;
  FChunkIndex := AChunkIndex;
  if AChunkIndex > 0 then
    FCurrentTable := Format('%s #%d/%d', [ASource.SectionName, ASetIndex, AChunkIndex])
  else
    FCurrentTable := Format('%s #%d', [ASource.SectionName, ASetIndex]);
end;

destructor TPumpWorkerPQ.Destroy;
begin
  FProgressDB.Free;
  inherited;
end;

procedure TPumpWorkerPQ.DoWork(const ATask: TPumpTask; const AQuery: TQueries);
begin

end;

function TPumpWorkerPQ.BuildParamValue(const AValue: string): Variant;
var
  IntVal: Int64;
  FltVal: Double;
  FS: TFormatSettings;
begin

  if TryStrToInt64(AValue, IntVal) then
    Result := IntVal
  else
  begin
    FS := TFormatSettings.Invariant;
    if TryStrToFloat(AValue, FltVal, FS) then
      Result := FltVal
    else
      Result := AValue;
  end;
end;

function TPumpWorkerPQ.WrapCountSQL: string;
begin
  Result := 'SELECT COUNT(*) AS CNT FROM (' + sLineBreak +
    FSource.SelectSQL + sLineBreak + ')';
end;

function TPumpWorkerPQ.WrapMinMaxSQL: string;
begin
  Result := 'SELECT MIN(' + FPkInfo.FieldName + ') AS MN, ' +
    '       MAX(' + FPkInfo.FieldName + ') AS MX ' +
    '  FROM (' + sLineBreak + FSource.SelectSQL + sLineBreak + ')';
end;

function TPumpWorkerPQ.WrapWindowPKsSQL: string;
begin
  Result :=
    'SELECT ' + FPkInfo.FieldName + ' FROM (' + sLineBreak +
    '  SELECT ' + FPkInfo.FieldName + ' FROM (' + sLineBreak +
    FSource.SelectSQL + sLineBreak + ')' + sLineBreak +
    '   WHERE ' + FPkInfo.FieldName + ' > :__pq_lastpk ' +
    '   ORDER BY ' + FPkInfo.FieldName + sLineBreak +
    ') WHERE ROWNUM <= :__pq_chunk';
end;

function TPumpWorkerPQ.WrapWindowDataSQL: string;
begin
  Result :=
    'SELECT * FROM (' + sLineBreak + FSource.SelectSQL + sLineBreak + ')' +
    ' WHERE ' + FPkInfo.FieldName + ' > :__pq_from ' +
    '   AND ' + FPkInfo.FieldName + ' <= :__pq_to ' +
    ' ORDER BY ' + FPkInfo.FieldName;
end;

function TPumpWorkerPQ.BuildInsertSQL(const AFields: TArray<string>): string;
var
  Cols, Params: string;
  I: Integer;
begin
  Cols := '';
  Params := '';
  for I := 0 to High(AFields) do
  begin
    if I > 0 then
    begin
      Cols := Cols + ', ';
      Params := Params + ', ';
    end;
    Cols := Cols + AFields[I];
    Params := Params + ':' + AFields[I];
  end;

  Result := 'INSERT INTO ' + FSource.TableName +
    ' (' + Cols + ') VALUES (' + Params + ')';
end;

procedure TPumpWorkerPQ.BindUserParams(AQ: TFDQuery);
var
  I: Integer;
  P: TFDParam;
begin
  for I := 0 to High(FSource.ParamNames) do
  begin
    P := AQ.FindParam(FSource.ParamNames[I]);
    if P = nil then
      Continue;
    P.Value := BuildParamValue(FParamSet[I]);
  end;
end;

function TPumpWorkerPQ.BindUserParamsResult(AQ: TFDQuery): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to High(FSource.ParamNames) do
  begin
    if AQ.FindParam(FSource.ParamNames[I]) = nil then
    begin
      Log(Format('bind: параметр "%s" отсутствует в SQL',
          [FSource.ParamNames[I]]), llError);
      Exit(False);
    end;
  end;
  BindUserParams(AQ);
end;

function TPumpWorkerPQ.LoadWindowPKs(var ALastPK, ANewLastPK: Int64; ASourcePKs: TList<Int64>): Boolean;
var
  Q: TFDQuery;
  Pk: Int64;
begin
  Result := False;
  ASourcePKs.Clear;
  ANewLastPK := ALastPK;

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Connections.Source;
    Q.SQL.Text := WrapWindowPKsSQL;
    if not BindUserParamsResult(Q) then
      Exit;

    Q.ParamByName('__pq_lastpk').AsLargeInt := ALastPK;
    Q.ParamByName('__pq_chunk').AsInteger := FSource.ChunkSize;

    MakeQueryStreaming(Q, FSource.ChunkSize);
    Q.Open;

    while not Q.EOF do
    begin
      Pk := Q.Fields[0].AsLargeInt;
      ASourcePKs.Add(Pk);
      ANewLastPK := Pk;
      Q.Next;
    end;

    Result := ASourcePKs.Count > 0;
  finally
    Q.Free;
  end;
end;

procedure TPumpWorkerPQ.LoadExistingTargetPKs(AFrom, ATo: Int64; AExisting: TDictionary<Int64, Boolean>);
var
  Q: TFDQuery;
  Pk: Int64;
begin
  AExisting.Clear;

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Connections.Target;
    Q.SQL.Text :=
      'SELECT ' + FPkInfo.FieldName + ' FROM ' + FSource.TableName +
      ' WHERE ' + FPkInfo.FieldName + ' > :from_pk ' +
      '   AND ' + FPkInfo.FieldName + ' <= :to_pk';
    Q.ParamByName('from_pk').AsLargeInt := AFrom;
    Q.ParamByName('to_pk').AsLargeInt := ATo;
    Q.FetchOptions.Mode := fmOnDemand;
    Q.FetchOptions.RowsetSize := 5000;
    Q.Open;

    while not Q.EOF do
    begin
      Pk := Q.Fields[0].AsLargeInt;
      AExisting.AddOrSetValue(Pk, True);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TPumpWorkerPQ.InsertMissingRows(AFrom, ATo: Int64; ASourcePKs: TList<Int64>; AExisting: TDictionary<Int64,
  Boolean>): Int64;
var
  SrcQ, DstQ: TFDQuery;
  I, RowInBatch, Written, Missing: Integer;
  ColName: string;
  ColInfo: TDictionary<string, TTargetColInfo>;
  Info: TTargetColInfo;
  SrcFields: TArray<string>;
  FieldNames: TStringList;
  SrcPk: Int64;
begin
  Result := 0;
  Written := 0;

  Missing := 0;
  for I := 0 to ASourcePKs.Count - 1 do
    if not AExisting.ContainsKey(ASourcePKs[I]) then
      Inc(Missing);

  if Missing = 0 then
  begin
    Log(Format('окно (%d; %d]: %d src, 0 missing — пропуск',
        [AFrom, ATo, ASourcePKs.Count]));
    Exit;
  end;

  ColInfo := GetTargetColumnInfo(Connections.Target, FSource.TableName);
  try
    SrcQ := TFDQuery.Create(nil);
    try
      SrcQ.Connection := Connections.Source;
      SrcQ.SQL.Text := WrapWindowDataSQL;
      if not BindUserParamsResult(SrcQ) then
        Exit;

      SrcQ.ParamByName('__pq_from').AsLargeInt := AFrom;
      SrcQ.ParamByName('__pq_to').AsLargeInt := ATo;
      MakeQueryStreaming(SrcQ, FSource.ChunkSize);
      SrcQ.Open;

      if SrcQ.IsEmpty then
      begin
        Log(Format('окно (%d; %d]: source пуст (проход 2)', [AFrom, ATo]), llWarning);
        Exit;
      end;

      FieldNames := TStringList.Create;
      try
        for I := 0 to SrcQ.FieldCount - 1 do
          FieldNames.Add(SrcQ.Fields[I].FieldName);
        SrcFields := FieldNames.ToStringArray;
      finally
        FieldNames.Free;
      end;

      for I := 0 to High(SrcFields) do
      begin
        if not ColInfo.ContainsKey(SrcFields[I]) then
        begin
          Log(Format('поле "%s" отсутствует в target %s — пропуск окна',
              [SrcFields[I], FSource.TableName]), llError);
          Exit;
        end;
      end;

      DstQ := TFDQuery.Create(nil);
      try
        DstQ.Connection := Connections.Target;
        DstQ.SQL.Text := BuildInsertSQL(SrcFields);
        DstQ.FormatOptions.MaxStringSize := 4000;

        for I := 0 to DstQ.ParamCount - 1 do
        begin
          ColName := DstQ.Params[I].Name;
          if ColInfo.TryGetValue(ColName, Info) and (Info.DataType <> ftUnknown) then
          begin
            DstQ.Params[I].DataType := Info.DataType;
            case Info.DataType of
              ftBCD:
                begin
                  DstQ.Params[I].Precision := Info.Precision;
                  DstQ.Params[I].NumericScale := Info.Scale;
                end;
              ftString, ftWideString:
                if Info.Size > 0 then
                  DstQ.Params[I].Size := Info.Size;
            end;
          end
          else
          begin
            DstQ.Params[I].DataType := SrcQ.FieldByName(ColName).DataType;
          end;
          DstQ.Params[I].ArraySize := FSource.ChunkSize;
        end;
        DstQ.Prepare;

        Connections.Target.StartTransaction;
        try
          RowInBatch := 0;
          while not SrcQ.EOF do
          begin
            if FStopFlag^ then
              Break;

            SrcPk := SrcQ.FieldByName(FPkInfo.FieldName).AsLargeInt;
            if not AExisting.ContainsKey(SrcPk) then
            begin
              CopyFieldValues(SrcQ, DstQ, RowInBatch);
              Inc(RowInBatch);
              if RowInBatch >= FSource.ChunkSize then
              begin
                DstQ.Execute(RowInBatch, 0);
                Inc(Written, RowInBatch);
                RowInBatch := 0;
              end;
            end;

            SrcQ.Next;
          end;

          if RowInBatch > 0 then
          begin
            DstQ.Execute(RowInBatch, 0);
            Inc(Written, RowInBatch);
          end;

          Connections.Target.Commit;
          Result := Written;

          FStats.RowsRead := FStats.RowsRead + ASourcePKs.Count;
          FStats.RowsWritten := FStats.RowsWritten + Written;

          Log(Format('окно (%d; %d]: %d src, %d missing, вставлено %d',
              [AFrom, ATo, ASourcePKs.Count, Missing, Written]));
        except
          Connections.Target.Rollback;
          Log(Format('ROLLBACK окна (%d; %d] после %d записей',
              [AFrom, ATo, Written]), llError);
          raise;
        end;
      finally
        DstQ.Free;
      end;
    finally
      SrcQ.Free;
    end;
  finally
    ColInfo.Free;
  end;
end;

procedure TPumpWorkerPQ.DoWorkSource;
var
  TotalRows, MinPK, MaxPK: Int64;
  CurrentLastPK, NewLastPK: Int64;
  SourcePKs: TList<Int64>;
  ExistingPKs: TDictionary<Int64, Boolean>;
  WindowWritten, TotalWritten: Int64;
  LastProgressTime, NowTime: TDateTime;
  WindowCount: Integer;
  Elapsed: TTimeSpan;
  SW: TStopwatch;
begin
  SW := TStopwatch.StartNew;

  if (FSource.RowIdSQL <> '') and (FChunkIndex > 0) then
  begin
    SW.Stop;
    DoWorkRid;
    Exit;
  end;

  FPkInfo := GetTablePKSingle(Connections.Target, FSource.TableName);
  if FPkInfo.ErrorMsg <> '' then
  begin
    Log('PK target: ' + FPkInfo.ErrorMsg + ' — источник пропускается', llError);
    Exit;
  end;
  Log(Format('PK target: %s (Int64-совместим: %s)',
      [FPkInfo.FieldName, BoolToStr(FPkInfo.IsInt64, True)]));

  FProgressDB := TPQProgressDB.Create(Connections.Target);
  try
    FProgressDB.EnsureExists;

    if FProgressDB.TryRead(FSource.SectionName, FSetIndex, FProgress) then
    begin
      if FProgress.CompletedAt <> 0 then
      begin
        Log(Format('уже завершён %s — пропуск (удалите строку из tiger.DataPumpPQProgress для повтора)',
            [FormatDateTime('yyyy-mm-dd hh:nn:ss', FProgress.CompletedAt)]), llWarning);
        Exit;
      end;
      Log(Format('прогресс найден: last_pk=%d, written=%d, total=%d',
          [FProgress.LastPK, FProgress.RowsWritten, FProgress.TotalRows]));
    end
    else
    begin

      Log('прогресс не найден — инициализация TotalRows, MinPK, MaxPK...');

      try
        TotalRows := ComputeTotalRows;

        if TotalRows = 0 then
        begin
          Log('источник пуст (TotalRows=0) — помечаем как завершённый');
          FProgressDB.Init(FSource.SectionName, FSetIndex, 0, 0, 0);
          FProgressDB.MarkCompleted(FSource.SectionName, FSetIndex);
          Exit;
        end;

        MinPK := ComputeMinPK;
        MaxPK := ComputeMaxPK;
      except
        on E: Exception do
        begin
          Log('Ошибка подготовки (TotalRows/MinPK/MaxPK): ' +
            E.ClassName + ': ' + E.Message, llError);
          Exit;
        end;
      end;

      Log(Format('INIT: total=%d, min_pk=%d, max_pk=%d',
          [TotalRows, MinPK, MaxPK]));

      FProgressDB.Init(FSource.SectionName, FSetIndex, MinPK, MaxPK, TotalRows);
      if not FProgressDB.TryRead(FSource.SectionName, FSetIndex, FProgress) then
      begin
        Log('не удалось прочитать прогресс после Init — источник пропускается', llError);
        Exit;
      end;
    end;

    CurrentLastPK := FProgress.LastPK;
    TotalWritten := FProgress.RowsWritten;
    FRunStartedAt := Now;
    WindowCount := 0;
    LastProgressTime := Now;

    SourcePKs := TList<Int64>.Create;
    ExistingPKs := TDictionary<Int64, Boolean>.Create;
    try
      while not FStopFlag^ do
      begin
        Inc(WindowCount);

        if not LoadWindowPKs(CurrentLastPK, NewLastPK, SourcePKs) then
        begin
          Log(Format('окно #%d пустое — источник исчерпан', [WindowCount]));
          FProgressDB.MarkCompleted(FSource.SectionName, FSetIndex);
          Break;
        end;

        LoadExistingTargetPKs(CurrentLastPK, NewLastPK, ExistingPKs);

        WindowWritten := InsertMissingRows(CurrentLastPK, NewLastPK,
          SourcePKs, ExistingPKs);

        Inc(TotalWritten, WindowWritten);
        FProgressDB.Update(FSource.SectionName, FSetIndex,
          NewLastPK, TotalWritten);
        CurrentLastPK := NewLastPK;

        NowTime := Now;
        if (NowTime - LastProgressTime) * SecsPerDay >= FSettings.PQProgressEverySec then
        begin
          LastProgressTime := NowTime;
          LogProgress('in progress', CurrentLastPK, NewLastPK,
            WindowWritten, TotalWritten);
        end;
      end;

      if FStopFlag^ then
        Log(Format('остановка, прогресс сохранён: last_pk=%d, written=%d',
            [CurrentLastPK, TotalWritten]), llWarning);
    finally
      SourcePKs.Free;
      ExistingPKs.Free;
    end;

    SW.Stop;
    Elapsed := TTimeSpan.FromMilliseconds(SW.ElapsedMilliseconds);
    Log(Format('завершено: окон=%d, written=%d, elapsed=%s, avg=%.0f rows/s',
        [WindowCount, TotalWritten, FormatDuration(Elapsed),
          TotalWritten * 1000.0 / (SW.ElapsedMilliseconds + 1)]));
  finally
    FProgressDB.Free;
    FProgressDB := nil;
  end;
end;

procedure TPumpWorkerPQ.LogProgress(const APhase: string; AWindowFrom, AWindowTo: Int64; AWindowWritten, ATotalWritten: Int64);
var
  ElapsedSpan: TTimeSpan;
  Speed, Percent: Double;
  Total, Range: Int64;
  Eta: TTimeSpan;
begin
  ElapsedSpan := TTimeSpan.FromMilliseconds((Now - FRunStartedAt) * MSecsPerDay);
  Speed := 0;
  if ElapsedSpan.TotalSeconds > 0 then
    Speed := ATotalWritten / ElapsedSpan.TotalSeconds;

  Total := FProgress.TotalRows;
  if Total > 0 then
    Percent := ATotalWritten * 100.0 / Total
  else if FProgress.MaxPK > FProgress.MinPK then
  begin
    Range := FProgress.MaxPK - FProgress.MinPK;
    Percent := (AWindowTo - FProgress.MinPK) * 100.0 / Range;
  end
  else
    Percent := 0;

  if (Speed > 0) and (Total > ATotalWritten) then
    Eta := TTimeSpan.FromSeconds((Total - ATotalWritten) / Speed)
  else
    Eta := TTimeSpan.Zero;

  Log(Format('[%s] written=%d / total=%d (%.1f%%), window=(%d; %d], window_written=%d, ' +
      'elapsed=%s, speed=%.0f rows/s, ETA=%s',
      [APhase, ATotalWritten, Total, Percent,
        AWindowFrom, AWindowTo, AWindowWritten,
        FormatDuration(ElapsedSpan), Speed, FormatDuration(Eta)]));
end;

function TPumpWorkerPQ.FormatDuration(ADuration: TTimeSpan): string;
begin
  Result := Format('%dd %02d:%02d:%02d',
    [ADuration.Days, ADuration.Hours, ADuration.Minutes, ADuration.Seconds]);
end;

procedure TPumpWorkerPQ.Execute;
var
  IntervalMs, Elapsed, SleepMs: Integer;
begin
  try
    Log(Format('PQ: старт set #%d/%d [%s]',
        [FSetIndex, FChunkIndex, JoinStrArray(FParamSet)]));

    if Trim(FSource.SelectSQL) = '' then
    begin
      Log('PQ: SelectSQL пуст — воркер не может работать', llError);
      Exit;
    end;

    Log('PQ: открытие соединений...');
    FConnections.Open;
    Log('PQ: соединения открыты');

    try
      while not FStopFlag^ do
      begin
        FStats.SessionID := GSessionID;

        if FChunkIndex > 0 then
          FStats.TableName := Format('%s #%d/%d', [FSource.SectionName, FSetIndex, FChunkIndex])
        else
          FStats.TableName := Format('%s #%d', [FSource.SectionName, FSetIndex]);

        FStats.Operation := poPQ;
        FStats.RowsRead := 0;
        FStats.RowsWritten := 0;
        FStats.GapFilled := 0;
        FStats.ElapsedMs := 0;
        FStats.ErrorMsg := '';

        var SW := TStopwatch.StartNew;
        var TaskError := '';
        try
          Log(Format('>>> %s [PQ set #%d]',
              [FSource.TableName, FSetIndex]));
          DoWorkSource;
          SW.Stop;
        except
          on E: Exception do
          begin
            SW.Stop;
            TaskError := E.ClassName + ': ' + E.Message;
            Log(Format('!!! %s (после %d мс)',
                [TaskError, SW.ElapsedMilliseconds]), llError);

            Break;
          end;
        end;

        FStats.ElapsedMs := SW.ElapsedMilliseconds;
        FStats.ErrorMsg := TaskError;

        UpdateTableStat(FStats.TableName, FStats.RowsRead, FStats.RowsWritten,
          SW.ElapsedMilliseconds, FStats.GapFilled, TaskError);

        if Assigned(GStatWriteProc) then
          GStatWriteProc(FStats);

        if FSource.IntervalSec <= 0 then
        begin
          Log('PQ: одноразовый режим — завершение');
          Break;
        end;

        IntervalMs := FSource.IntervalSec * 1000;
        Log(Format('PQ: пауза %d сек', [FSource.IntervalSec]));
        Elapsed := 0;
        SleepMs := 200;
        while (Elapsed < IntervalMs) and (not FStopFlag^) do
        begin
          Sleep(SleepMs);
          Inc(Elapsed, SleepMs);
        end;
      end;
    finally
      Log('PQ: закрытие соединений');
      FConnections.Close;
      Log('PQ: воркер завершён');
    end;
  except
    on E: Exception do
      GLog(Format('[PQ%d] КРИТИЧЕСКАЯ ОШИБКА: %s: %s',
          [FWorkerId, E.ClassName, E.Message]), llError);
  end;
end;

function TPumpWorkerPQ.WrapMinPK_SQL: string;
begin
  Result := 'SELECT MIN(' + FPkInfo.FieldName + ') FROM (' + sLineBreak +
    FSource.SelectSQL + sLineBreak + ')';
end;

function TPumpWorkerPQ.WrapMaxPK_SQL: string;
begin
  Result := 'SELECT MAX(' + FPkInfo.FieldName + ') FROM (' + sLineBreak +
    FSource.SelectSQL + sLineBreak + ')';
end;

function TPumpWorkerPQ.RunScalarUserSQL(const ASQL, APhase: string): Int64;
var
  Q: TFDQuery;
begin

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Connections.Source;
    Q.SQL.Text := ASQL;
    BindUserParams(Q);
    Q.Open;
    if Q.IsEmpty or Q.Fields[0].IsNull then
      raise Exception.CreateFmt('%s: результат NULL/пусто', [APhase]);
    Result := Q.Fields[0].AsLargeInt;
  finally
    Q.Free;
  end;
end;

function TPumpWorkerPQ.ComputeTotalRows: Int64;
var
  Q: TFDQuery;
begin

  if FSource.TotalRows > 0 then
  begin
    Log(Format('COUNT: из конфига (TotalRows=%d)', [FSource.TotalRows]));
    Exit(FSource.TotalRows);
  end;

  if FSource.CountSQL <> '' then
  begin
    Log('COUNT: пользовательский CountSQL...');
    Result := RunScalarUserSQL(FSource.CountSQL, 'CountSQL');
    Log(Format('COUNT (user) = %d', [Result]));
    Exit;
  end;

  Log('COUNT: обёртка SELECT COUNT(*) FROM (user_sql)...');
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Connections.Source;
    Q.SQL.Text := WrapCountSQL;
    if not BindUserParamsResult(Q) then
      raise Exception.Create('COUNT wrapper: bind parameters failed');
    Q.Open;
    if Q.IsEmpty or Q.Fields[0].IsNull then
      raise Exception.Create('COUNT wrapper: no result');
    Result := Q.Fields[0].AsLargeInt;
    Log(Format('COUNT (wrapper) = %d', [Result]));
  finally
    Q.Free;
  end;
end;

function TPumpWorkerPQ.ComputeMinPK: Int64;
var
  Q: TFDQuery;
begin
  if FSource.MinPK >= 0 then
  begin
    Log(Format('MIN: из конфига (MinPK=%d)', [FSource.MinPK]));
    Exit(FSource.MinPK);
  end;

  if FSource.MinPKSQL <> '' then
  begin
    Log('MIN: пользовательский MinPK_SQL...');
    Result := RunScalarUserSQL(FSource.MinPKSQL, 'MinPK_SQL');
    Log(Format('MIN (user) = %d', [Result]));
    Exit;
  end;

  Log('MIN: обёртка SELECT MIN(pk) FROM (user_sql)...');
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Connections.Source;
    Q.SQL.Text := WrapMinPK_SQL;
    if not BindUserParamsResult(Q) then
      raise Exception.Create('MIN wrapper: bind parameters failed');
    Q.Open;
    if Q.IsEmpty or Q.Fields[0].IsNull then
      raise Exception.Create('MIN wrapper: no result');
    Result := Q.Fields[0].AsLargeInt;
    Log(Format('MIN (wrapper) = %d', [Result]));
  finally
    Q.Free;
  end;
end;

function TPumpWorkerPQ.ComputeMaxPK: Int64;
var
  Q: TFDQuery;
begin
  if FSource.MaxPK >= 0 then
  begin
    Log(Format('MAX: из конфига (MaxPK=%d)', [FSource.MaxPK]));
    Exit(FSource.MaxPK);
  end;

  if FSource.MaxPKSQL <> '' then
  begin
    Log('MAX: пользовательский MaxPK_SQL...');
    Result := RunScalarUserSQL(FSource.MaxPKSQL, 'MaxPK_SQL');
    Log(Format('MAX (user) = %d', [Result]));
    Exit;
  end;

  Log('MAX: обёртка SELECT MAX(pk) FROM (user_sql)...');
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Connections.Source;
    Q.SQL.Text := WrapMaxPK_SQL;
    if not BindUserParamsResult(Q) then
      raise Exception.Create('MAX wrapper: bind parameters failed');
    Q.Open;
    if Q.IsEmpty or Q.Fields[0].IsNull then
      raise Exception.Create('MAX wrapper: no result');
    Result := Q.Fields[0].AsLargeInt;
    Log(Format('MAX (wrapper) = %d', [Result]));
  finally
    Q.Free;
  end;
end;

procedure TPumpWorkerPQ.DoWorkRid;
var
  SrcQ, DstQ: TFDQuery;
  ColInfo: TDictionary<string, TTargetColInfo>;
  Info: TTargetColInfo;
  SrcFields: TArray<string>;
  FieldNames: TStringList;
  ColName, LastRid, RidTo: string;
  I, RowInBatch, InTxRows, RowsInWindow: Integer;
  TotalWritten: Int64;
  SW: TStopwatch;
  ChunkSize, CommitEvery: Integer;
  StopRequested: Boolean;
  P: TFDParam;
begin
  SW := TStopwatch.StartNew;

  FProgressDB := TPQProgressDB.Create(Connections.Target);
  try
    FProgressDB.EnsureExists;

    if not FProgressDB.TryRead(FSource.SectionName, FSetIndex, FProgress, FChunkIndex) then
    begin
      Log(Format('нет прогресса для диапазона #%d — менеджер не инициализировал, выход',
          [FChunkIndex]), llError);
      Exit;
    end;

    if FProgress.CompletedAt <> 0 then
    begin
      Log('диапазон уже завершён — пропуск', llInfo);
      Exit;
    end;

    RidTo := FProgress.RidTo;
    LastRid := FProgress.LastRowId;
    TotalWritten := FProgress.RowsWritten;

    Log(Format('RID-диапазон #%d: [%s .. %s], last=%s, уже вставлено %d',
        [FChunkIndex,
          IfThen(FProgress.RidFrom = '', '<null>', FProgress.RidFrom),
          IfThen(RidTo = '', '<null>', RidTo),
          IfThen(LastRid = '', '<null>', LastRid),
          TotalWritten]));

    if RidTo = '' then
    begin
      Log('RidTo пуст — диапазон не инициализирован, пропуск', llWarning);
      Exit;
    end;

    ChunkSize := FSource.ChunkSize;
    if ChunkSize < 100 then
      ChunkSize := 100;
    CommitEvery := FSource.CommitEvery;
    if CommitEvery < 0 then
      CommitEvery := 0;

    FRunStartedAt := Now;

    while not FStopFlag^ do
    begin
      SrcQ := TFDQuery.Create(nil);
      try
        SrcQ.Connection := Connections.Source;
        SrcQ.SQL.Text := FSource.RowIdSQL;

        if not BindUserParamsResult(SrcQ) then
          Exit;

        P := SrcQ.FindParam('__pq_lastrid');
        if P = nil then
        begin
          Log('RowIdSQL: отсутствует :__pq_lastrid — выход', llError);
          Exit;
        end;
        P.DataType := ftString;
        if LastRid = '' then
          P.Clear
        else
          P.AsString := LastRid;

        P := SrcQ.FindParam('__pq_ridto');
        if P = nil then
        begin
          Log('RowIdSQL: отсутствует :__pq_ridto — выход', llError);
          Exit;
        end;
        P.DataType := ftString;
        P.AsString := RidTo;

        P := SrcQ.FindParam('__pq_chunk');
        if P = nil then
        begin
          Log('RowIdSQL: отсутствует :__pq_chunk — выход', llError);
          Exit;
        end;
        P.DataType := ftInteger;
        P.AsInteger := ChunkSize;

        MakeQueryStreaming(SrcQ, ChunkSize);
        SrcQ.Open;

        if SrcQ.IsEmpty then
        begin
          Log(Format('диапазон #%d: пустое окно — завершён', [FChunkIndex]));
          FProgressDB.MarkCompleted(FSource.SectionName, FSetIndex, FChunkIndex);
          Break;
        end;

        FieldNames := TStringList.Create;
        try
          for I := 0 to SrcQ.FieldCount - 1 do
            if not SameText(SrcQ.Fields[I].FieldName, '__PQ_RID') then
              FieldNames.Add(SrcQ.Fields[I].FieldName);
          SrcFields := FieldNames.ToStringArray;
        finally
          FieldNames.Free;
        end;

        ColInfo := GetTargetColumnInfo(Connections.Target, FSource.TableName);
        try
          for I := 0 to High(SrcFields) do
            if not ColInfo.ContainsKey(SrcFields[I]) then
            begin
              Log(Format('поле "%s" отсутствует в target %s — диапазон пропущен',
                  [SrcFields[I], FSource.TableName]), llError);
              Exit;
            end;

          DstQ := TFDQuery.Create(nil);
          try
            DstQ.Connection := Connections.Target;
            DstQ.SQL.Text := BuildInsertSQL(SrcFields);
            DstQ.FormatOptions.MaxStringSize := 4000;

            for I := 0 to DstQ.ParamCount - 1 do
            begin
              ColName := DstQ.Params[I].Name;
              if ColInfo.TryGetValue(ColName, Info) and (Info.DataType <> ftUnknown) then
              begin
                DstQ.Params[I].DataType := Info.DataType;
                case Info.DataType of
                  ftBCD:
                    begin
                      DstQ.Params[I].Precision := Info.Precision;
                      DstQ.Params[I].NumericScale := Info.Scale;
                    end;
                  ftString, ftWideString:
                    if Info.Size > 0 then
                      DstQ.Params[I].Size := Info.Size;
                end;
              end
              else
                DstQ.Params[I].DataType := SrcQ.FieldByName(ColName).DataType;
              DstQ.Params[I].ArraySize := ChunkSize;
            end;
            DstQ.Prepare;

            RowInBatch := 0;
            InTxRows := 0;
            RowsInWindow := 0;
            StopRequested := False;

            Connections.Target.StartTransaction;
            try
              while not SrcQ.Eof do
              begin
                if FStopFlag^ then
                begin
                  StopRequested := True;
                  Break;
                end;

                CopyFieldValues(SrcQ, DstQ, RowInBatch);
                Inc(RowInBatch);
                Inc(RowsInWindow);
                LastRid := SrcQ.FieldByName('__PQ_RID').AsString;

                if RowInBatch >= ChunkSize then
                begin
                  DstQ.Execute(RowInBatch, 0);
                  Inc(InTxRows, RowInBatch);
                  Inc(TotalWritten, RowInBatch);
                  RowInBatch := 0;

                  if (CommitEvery > 0) and (InTxRows >= CommitEvery) then
                  begin
                    Connections.Target.Commit;
                    FProgressDB.Update(FSource.SectionName, FSetIndex,
                      0, TotalWritten, FChunkIndex, LastRid);
                    Connections.Target.StartTransaction;
                    InTxRows := 0;
                  end;
                end;

                SrcQ.Next;
              end;

              if RowInBatch > 0 then
              begin
                DstQ.Execute(RowInBatch, 0);
                Inc(InTxRows, RowInBatch);
                Inc(TotalWritten, RowInBatch);
              end;

              Connections.Target.Commit;
              FProgressDB.Update(FSource.SectionName, FSetIndex,
                0, TotalWritten, FChunkIndex, LastRid);

              Log(Format('диапазон #%d: окно вставлено %d (всего %d), last_rid=%s',
                  [FChunkIndex, RowsInWindow, TotalWritten, LastRid]));

              if LastRid >= RidTo then
              begin
                Log(Format('диапазон #%d достиг верхней границы — завершён',
                    [FChunkIndex]));
                FProgressDB.MarkCompleted(FSource.SectionName, FSetIndex, FChunkIndex);
                Break;
              end;

              if RowsInWindow < ChunkSize then
              begin

                Log(Format('диапазон #%d: RowsInWindow (%d) < ChunkSize (%d) — завершён',
                    [FChunkIndex, RowsInWindow, ChunkSize]));
                FProgressDB.MarkCompleted(FSource.SectionName, FSetIndex, FChunkIndex);
                Break;
              end;

              if StopRequested then
                Break;
            except
              Connections.Target.Rollback;
              Log(Format('ROLLBACK диапазона #%d после %d записей',
                  [FChunkIndex, TotalWritten]), llError);
              raise;
            end;
          finally
            DstQ.Free;
          end;
        finally
          ColInfo.Free;
        end;
      finally
        SrcQ.Free;
      end;
    end;

    SW.Stop;
    Log(Format('RID-диапазон #%d итого: вставлено %d за %d мс',
        [FChunkIndex, TotalWritten, SW.ElapsedMilliseconds]));
  finally
    FProgressDB.Free;
    FProgressDB := nil;
  end;
end;

end.

