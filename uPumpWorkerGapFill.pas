unit uPumpWorkerGapFill;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs, System.Diagnostics, Data.DB,
  FireDAC.Comp.Client, FireDAC.Stan.Param, FireDAC.Stan.Option, uPumpTypes, uPumpWorker, uPumpInsert, MSA.Logger;

type
  TPumpWorkerGapFill = class(TPumpWorker)
  private
    function ReadIds(AConn: TFDConnection; const ATableName, AKeyField: string; AMinId, AMaxId: Int64): TList<Int64>;
    procedure FindGaps(const ATableName, AKeyField: string; AMinId, AMaxId: Int64; AChunkSize: Integer; AGapQueue:
      TThreadedQueue<Int64>; var ATotalGaps: Int64; var AStopped: Boolean);
    procedure FillGaps(const ASelectSQL, AInsertSQL, AKeyField: string; AGapQueue: TThreadedQueue<Int64>; ATotalGaps:
      Int64; var AWrittenTotal: Int64);
  protected
    procedure DoWork(const ATask: TPumpTask; const AQuery: TQueries); override;
  end;

implementation

function TPumpWorkerGapFill.ReadIds(AConn: TFDConnection; const ATableName, AKeyField: string; AMinId, AMaxId: Int64):
  TList<Int64>;
var
  Q: TFDQuery;
begin
  Result := TList<Int64>.Create;
  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := AConn;
      Q.SQL.Text := 'SELECT ' + AKeyField + ' FROM ' + ATableName +
        ' WHERE ' + AKeyField + ' BETWEEN :mn AND :mx ORDER BY ' + AKeyField;
      Q.ParamByName('mn').AsLargeInt := AMinId;
      Q.ParamByName('mx').AsLargeInt := AMaxId;
      Q.FetchOptions.Mode := fmAll;
      Q.Open;
      while not Q.EOF do
      begin
        Result.Add(Q.Fields[0].AsLargeInt);
        Q.Next;
      end;
    finally
      Q.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TPumpWorkerGapFill.FindGaps(const ATableName, AKeyField: string; AMinId, AMaxId: Int64; AChunkSize: Integer;
  AGapQueue: TThreadedQueue<Int64>; var ATotalGaps: Int64; var AStopped: Boolean);
var
  Cur, WindowEnd: Int64;
  TargetIds, SourceIds: TList<Int64>;
  I: Integer;
  SWProgress: TStopwatch;
  LastProgressMs: Int64;
  TotalWindows, ProcessedWindows: Integer;
begin
  ATotalGaps := 0;
  AStopped := False;
  TotalWindows := (AMaxId - AMinId) div AChunkSize + 1;
  ProcessedWindows := 0;
  Cur := AMinId;
  SWProgress := TStopwatch.StartNew;
  LastProgressMs := 0;

  while Cur <= AMaxId do
  begin
    if FStopFlag^ then
    begin
      AStopped := True;
      Log(Format('поиск прерван на окне [%d..%d]', [Cur, AMaxId]), llWarning);
      Break;
    end;

    WindowEnd := Cur + AChunkSize - 1;
    if WindowEnd > AMaxId then
      WindowEnd := AMaxId;

    TargetIds := ReadIds(Connections.Target, ATableName, AKeyField, Cur, WindowEnd);
    try
      SourceIds := ReadIds(Connections.Source, ATableName, AKeyField, Cur, WindowEnd);
      try
        TargetIds.Sort;
        SourceIds.Sort;

        var WindowGaps := 0;
        I := 0;
        for var IdVal in SourceIds do
        begin
          while (I < TargetIds.Count) and (TargetIds[I] < IdVal) do
            Inc(I);
          if (I < TargetIds.Count) and (TargetIds[I] = IdVal) then
            Continue;
          AGapQueue.PushItem(IdVal);
          Inc(WindowGaps);
        end;

        Inc(ATotalGaps, WindowGaps);

        if WindowGaps > 0 then
          Log(Format('окно [%d..%d] — пропущено %d',
              [Cur, WindowEnd, WindowGaps]));
      finally
        SourceIds.Free;
      end;
    finally
      TargetIds.Free;
    end;

    Inc(ProcessedWindows);
    if SWProgress.ElapsedMilliseconds - LastProgressMs >= PUMP_PROGRESS_MS then
    begin
      Log(Format('прогресс — окон %d/%d, найдено пропусков %d',
          [ProcessedWindows, TotalWindows, ATotalGaps]));
      LastProgressMs := SWProgress.ElapsedMilliseconds;
    end;

    Cur := WindowEnd + 1;
  end;

  if AStopped then
    Log(Format('поиск прерван — окон %d/%d, найдено пропусков %d',
        [ProcessedWindows, TotalWindows, ATotalGaps]), llWarning)
  else
    Log(Format('поиск завершён — окон %d/%d, пропусков всего %d',
        [ProcessedWindows, TotalWindows, ATotalGaps]));
end;

procedure TPumpWorkerGapFill.FillGaps(const ASelectSQL, AInsertSQL, AKeyField: string; AGapQueue: TThreadedQueue<Int64>;
  ATotalGaps: Int64; var AWrittenTotal: Int64);
var
  IdsArr: TArray<Int64>;
  Id: Int64;
  BatchCount: Integer;
  QueueSize: NativeInt;
  SW: TStopwatch;
  StopRequested: Boolean;
begin
  AWrittenTotal := 0;
  StopRequested := False;
  Log('заливка пропущенных записей...');
  SW := TStopwatch.StartNew;
  SetLength(IdsArr, PUMP_GAPFILL_INSERT_BATCH);

  while True do
  begin
    if FStopFlag^ then
    begin
      StopRequested := True;
      Break;
    end;

    BatchCount := 0;
    while BatchCount < PUMP_GAPFILL_INSERT_BATCH do
    begin
      if AGapQueue.PopItem(QueueSize, Id) <> wrSignaled then
        Break;
      IdsArr[BatchCount] := Id;
      Inc(BatchCount);
    end;
    if BatchCount = 0 then
      Break;

    var ActualIds: TArray<Int64>;
    SetLength(ActualIds, BatchCount);
    for var I := 0 to BatchCount - 1 do
      ActualIds[I] := IdsArr[I];

    AWrittenTotal := AWrittenTotal +
      InsertRowsByIds(Connections.Source, Connections.Target,
      ASelectSQL, AInsertSQL, AKeyField, ActualIds);

    if (AWrittenTotal > 0) and ((AWrittenTotal mod 5000) = 0) then
      Log(Format('залито %d из %d', [AWrittenTotal, ATotalGaps]));
  end;

  SW.Stop;
  if StopRequested then
    Log(Format('заливка прервана — залито %d из %d за %d мс',
        [AWrittenTotal, ATotalGaps, SW.ElapsedMilliseconds]), llWarning)
  else
    Log(Format('залито %d из %d пропущенных за %d мс',
        [AWrittenTotal, ATotalGaps, SW.ElapsedMilliseconds]));
end;

procedure TPumpWorkerGapFill.DoWork(const ATask: TPumpTask; const AQuery: TQueries);
var
  KeyField: string;
  MinId, MaxId: Int64;
  ChunkSize: Integer;
  GapQueue: TThreadedQueue<Int64>;
  TotalGaps, WrittenTotal: Int64;
  SW: TStopwatch;
  Stopped: Boolean;
begin
  SW := TStopwatch.StartNew;

  if Pos(';', AQuery.KeyFields) > 0 then
  begin
    Log('составной PK — пропуск', llWarning);
    Exit;
  end;
  KeyField := Trim(AQuery.KeyFields);
  if KeyField = '' then
  begin
    Log('нет ключевого поля — пропуск', llWarning);
    Exit;
  end;
  Log('GapFill: ключ ' + KeyField);

  MinId := 0;
  MaxId := 0;

  var QSrc := TFDQuery.Create(nil);
  try
    QSrc.Connection := Connections.Source;
    QSrc.SQL.Text := 'SELECT MIN(' + KeyField + ') AS mn FROM ' + ATask.TableName;
    QSrc.Open;
    if not QSrc.Fields[0].IsNull then
      MinId := QSrc.Fields[0].AsLargeInt;
  finally
    QSrc.Free;
  end;

  var QTgt := TFDQuery.Create(nil);
  try
    QTgt.Connection := Connections.Target;
    QTgt.SQL.Text := 'SELECT MAX(' + KeyField + ') AS mx FROM ' + ATask.TableName;
    QTgt.Open;
    if not QTgt.Fields[0].IsNull then
      MaxId := QTgt.Fields[0].AsLargeInt;
  finally
    QTgt.Free;
  end;

  if MaxId < MinId then
  begin
    Log(Format('пустой диапазон (min=%d, max=%d)', [MinId, MaxId]));
    Exit;
  end;

  ChunkSize := FSettings.GapFillChunkSize;
  if ChunkSize < 1000 then
    ChunkSize := 1000;

  Log(Format('диапазон %d..%d, размер окна=%d', [MinId, MaxId, ChunkSize]));

  GapQueue := TThreadedQueue<Int64>.Create(ChunkSize * 2, 0, 0);
  try
    TotalGaps := 0;
    Stopped := False;
    FindGaps(ATask.TableName, KeyField, MinId, MaxId, ChunkSize,
      GapQueue, TotalGaps, Stopped);

    FStats.RowsRead := TotalGaps;

    if Stopped or FStopFlag^ then
    begin
      Log('GapFill: остановка после поиска — заливка не запущена', llWarning);
      Exit;
    end;

    if TotalGaps = 0 then
    begin
      Log('пропусков нет');
      Exit;
    end;

    Log(Format('найдено пропусков: %d', [TotalGaps]));

    WrittenTotal := 0;
    FillGaps(AQuery.SelectSQL, AQuery.InsertSQL, KeyField,
      GapQueue, TotalGaps, WrittenTotal);

    FStats.RowsWritten := WrittenTotal;
    FStats.GapFilled := WrittenTotal;
  finally
    GapQueue.Free;
  end;

  SW.Stop;
  Log(Format('GapFill: итого %d мс', [SW.ElapsedMilliseconds]));
end;

end.

