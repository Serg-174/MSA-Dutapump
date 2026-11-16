unit uPumpWorkerAppend;

interface

uses
  System.SysUtils, System.Classes, System.Diagnostics, System.StrUtils, Data.DB, FireDAC.Comp.Client, FireDAC.Stan.Param,
  FireDAC.Stan.Option, uPumpTypes, uPumpWorker, uPumpInsert, MSA.Logger;

type
  TPumpWorkerAppend = class(TPumpWorker)
  protected
    procedure DoWork(const ATask: TPumpTask; const AQuery: TQueries); override;
  end;

implementation

procedure TPumpWorkerAppend.DoWork(const ATask: TPumpTask; const AQuery: TQueries);
var
  KeyField: string;
  MaxId: Int64;
  TargetIsEmpty: Boolean;
  SrcQ, DstQ: TFDQuery;
  I, RowInBatch, BatchesInTx: Integer;
  WrittenTotal: Int64;
  ParamName: string;
  SW, SWStep: TStopwatch;
  LastProgressMs: Int64;
  StopRequested: Boolean;
begin
  SW := TStopwatch.StartNew;

  KeyField := Trim(AQuery.KeyFields.Split([';'])[0]);
  if KeyField = '' then
  begin
    Log('Нет ключевого поля — пропуск', llWarning);
    Exit;
  end;
  Log('Append: ключ ' + KeyField);

  SWStep := TStopwatch.StartNew;
  MaxId := 0;
  TargetIsEmpty := True;
  DstQ := TFDQuery.Create(nil);
  try
    DstQ.Connection := Connections.Target;
    DstQ.SQL.Text := 'SELECT MAX(' + KeyField + ') AS mx FROM ' + ATask.TableName;
    DstQ.Open;
    if not DstQ.Fields[0].IsNull then
    begin
      MaxId := DstQ.Fields[0].AsLargeInt;
      TargetIsEmpty := False;
    end;
    SWStep.Stop;
    Log(Format('[1/3] MAX(%s) = %d, target %s (%d мс)',
        [KeyField, MaxId,
          IfThen(TargetIsEmpty, 'пуст', 'не пуст'),
          SWStep.ElapsedMilliseconds]));
  finally
    DstQ.Free;
  end;

  if FStopFlag^ then
  begin
    Log('Append: получен сигнал остановки после MAX', llWarning);
    Exit;
  end;

  SWStep := TStopwatch.StartNew;
  SrcQ := TFDQuery.Create(nil);
  try
    SrcQ.Connection := Connections.Source;

    if TargetIsEmpty then
    begin

      SrcQ.SQL.Text := AQuery.SelectSQL + ' ORDER BY ' + KeyField;
    end
    else
    begin

      SrcQ.SQL.Text := AQuery.SelectSQL + ' WHERE ' + KeyField +
        ' > :max_id ORDER BY ' + KeyField;
      SrcQ.ParamByName('max_id').AsLargeInt := MaxId;
    end;

    MakeQueryStreaming(SrcQ, PUMP_INSERT_BATCH);
    SrcQ.Open;

    if SrcQ.IsEmpty then
    begin
      SWStep.Stop;
      Log(Format('[2/3] Новых записей нет (%d мс)', [SWStep.ElapsedMilliseconds]));
      Exit;
    end;

    SWStep.Stop;

    Log(Format('[2/3] SELECT открыт, читаем потоково (%d мс)',
        [SWStep.ElapsedMilliseconds]));

    if FStopFlag^ then
    begin
      Log('Append: получен сигнал остановки после SELECT', llWarning);
      Exit;
    end;

    SWStep := TStopwatch.StartNew;
    DstQ := TFDQuery.Create(nil);
    try
      DstQ.Connection := Connections.Target;
      DstQ.SQL.Text := AQuery.InsertSQL;

      for I := 0 to DstQ.ParamCount - 1 do
      begin
        ParamName := DstQ.Params[I].Name;
        DstQ.Params[I].DataType := SrcQ.FieldByName(ParamName).DataType;
        DstQ.Params[I].ArraySize := PUMP_INSERT_BATCH;
      end;
      DstQ.Prepare;
      Log(Format('[3/3] INSERT подготовлен (%d мс, %d параметров, батч=%d)',
          [SWStep.ElapsedMilliseconds, DstQ.ParamCount, PUMP_INSERT_BATCH]));

      WrittenTotal := 0;
      RowInBatch := 0;
      BatchesInTx := 0;
      LastProgressMs := 0;
      StopRequested := False;

      Connections.Target.StartTransaction;
      try
        while not SrcQ.EOF do
        begin
          CopyFieldValues(SrcQ, DstQ, RowInBatch);
          Inc(RowInBatch);
          SrcQ.Next;

          if RowInBatch >= PUMP_INSERT_BATCH then
          begin
            DstQ.Execute(RowInBatch, 0);
            Inc(WrittenTotal, RowInBatch);
            Inc(BatchesInTx);
            FStats.RowsRead := FStats.RowsRead + RowInBatch;
            FStats.RowsWritten := FStats.RowsWritten + RowInBatch;
            RowInBatch := 0;

            if (SWStep.ElapsedMilliseconds - LastProgressMs >= PUMP_PROGRESS_MS) or
              (BatchesInTx >= PUMP_COMMIT_EVERY) then
            begin

              Log(Format('  ... вставлено %d, время %d мс',
                  [WrittenTotal, SWStep.ElapsedMilliseconds]));
              LastProgressMs := SWStep.ElapsedMilliseconds;
            end;

            if BatchesInTx >= PUMP_COMMIT_EVERY then
            begin
              Connections.Target.Commit;
              Connections.Target.StartTransaction;
              BatchesInTx := 0;
            end;

            if FStopFlag^ then
            begin
              StopRequested := True;
              Break;
            end;
          end;
        end;

        if (not StopRequested) and (RowInBatch > 0) then
        begin
          DstQ.Execute(RowInBatch, 0);
          Inc(WrittenTotal, RowInBatch);
          FStats.RowsRead := FStats.RowsRead + RowInBatch;
          FStats.RowsWritten := FStats.RowsWritten + RowInBatch;
        end;

        Connections.Target.Commit;
        SWStep.Stop;

        var Rate: Double := 0;
        if SWStep.ElapsedMilliseconds > 0 then
          Rate := WrittenTotal * 1000.0 / SWStep.ElapsedMilliseconds;

        if StopRequested then
          Log(Format('[3/3] ОСТАНОВЛЕНО: вставлено %d записей за %d мс',
              [WrittenTotal, SWStep.ElapsedMilliseconds]), llWarning)
        else
          Log(Format('[3/3] INSERT завершён: %d записей за %d мс (%.0f зап/с)',
              [WrittenTotal, SWStep.ElapsedMilliseconds, Rate]));
      except
        Connections.Target.Rollback;
        Log(Format('[3/3] ROLLBACK после %d записей', [WrittenTotal]), llError);
        raise;
      end;
    finally
      DstQ.Free;
    end;
  finally
    SrcQ.Free;
  end;

  SW.Stop;
  Log(Format('Append: итого %d мс', [SW.ElapsedMilliseconds]));
end;

end.

