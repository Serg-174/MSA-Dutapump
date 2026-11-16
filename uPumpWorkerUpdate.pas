unit uPumpWorkerUpdate;

interface

uses
  System.SysUtils, System.Classes, System.Diagnostics, System.Variants, System.Math, Data.DB, FireDAC.Comp.Client,
  FireDAC.Stan.Param, FireDAC.Stan.Option, uPumpTypes, uPumpWorker, MSA.Logger;

type
  TPumpWorkerUpdate = class(TPumpWorker)
  private
    function ComparePKValues(const V1, V2: Variant): Integer;
    function FieldValuesEqual(F1, F2: TField): Boolean;
  protected
    procedure DoWork(const ATask: TPumpTask; const AQuery: TQueries); override;
  end;

implementation

const
  UPDATE_COMMIT_EVERY = 1000;

function TPumpWorkerUpdate.ComparePKValues(const V1, V2: Variant): Integer;
begin
  if VarIsNull(V1) and VarIsNull(V2) then
    Exit(0);
  if VarIsNull(V1) then
    Exit(-1);
  if VarIsNull(V2) then
    Exit(1);

  try
    if VarType(V1) in [varInt64, varInteger, varSmallint, varShortInt,
        varByte, varWord, varLongWord] then
    begin
      try
        Result := CompareValue(Int64(V1), Int64(V2));
        Exit;
      except
      end;
    end;

    if V1 = V2 then
      Exit(0);
    if V1 < V2 then
      Exit(-1);
    Result := 1;
  except
    Result := CompareText(VarToStr(V1), VarToStr(V2));
  end;
end;

function TPumpWorkerUpdate.FieldValuesEqual(F1, F2: TField): Boolean;
begin
  if F1.IsNull and F2.IsNull then
    Exit(True);
  if F1.IsNull or F2.IsNull then
    Exit(False);

  case F1.DataType of
    ftDate, ftTime, ftDateTime, ftTimeStamp:
      Result := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', F1.AsDateTime) =
        FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', F2.AsDateTime);
    ftBoolean:
      Result := F1.AsBoolean = F2.AsBoolean;
  else
    Result := F1.AsString = F2.AsString;
  end;
end;

procedure TPumpWorkerUpdate.DoWork(const ATask: TPumpTask; const AQuery: TQueries);
var
  SrcQ, TgtQ, UpdQ: TFDQuery;
  KeyField, ColName, SetSQL, WhereSQL: string;
  I, Cmp: Integer;
  SrcPK, TgtPK: Variant;
  NeedUpdate, StopRequested: Boolean;
  RowsRead, RowsChanged, InBatch: Int64;
  SW: TStopwatch;
begin
  SW := TStopwatch.StartNew;

  KeyField := Trim(AQuery.KeyFields);
  if Pos(';', KeyField) > 0 then
  begin
    Log('Update: составной PK Ч пропуск', llWarning);
    Exit;
  end;
  if KeyField = '' then
  begin
    Log('Update: нет ключевого пол€ Ч пропуск', llWarning);
    Exit;
  end;

  Log('Update: ключ ' + KeyField);

  SrcQ := TFDQuery.Create(nil);
  TgtQ := TFDQuery.Create(nil);
  UpdQ := TFDQuery.Create(nil);
  try

    SrcQ.Connection := Connections.Source;

    SrcQ.SQL.Text := AQuery.SelectSQL + ' ORDER BY ' + KeyField;

    TgtQ.Connection := Connections.Target;
    TgtQ.SQL.Text := AQuery.SelectSQL + ' ORDER BY ' + KeyField;

    MakeQueryStreaming(SrcQ, 1000);
    MakeQueryStreaming(TgtQ, 1000);

    Log('Update: открытие source...');
    SrcQ.Open;
    if SrcQ.IsEmpty then
    begin
      Log('Update: источник пуст Ч выход');
      Exit;
    end;

    Log('Update: открытие target...');
    TgtQ.Open;
    if TgtQ.IsEmpty then
    begin
      Log('Update: приЄмник пуст Ч нечего обновл€ть');
      Exit;
    end;

    SetSQL := '';
    WhereSQL := '';
    for I := 0 to SrcQ.FieldCount - 1 do
    begin
      ColName := SrcQ.Fields[I].FieldName;
      if SameText(ColName, KeyField) then
      begin
        WhereSQL := ColName + ' = :p_' + ColName;
        Continue;
      end;
      if SetSQL <> '' then
        SetSQL := SetSQL + ', ';
      SetSQL := SetSQL + ColName + ' = :' + ColName;
    end;

    UpdQ.Connection := Connections.Target;
    UpdQ.SQL.Text := 'UPDATE ' + ATask.TableName + ' SET ' + SetSQL +
      ' WHERE ' + WhereSQL;

    for I := 0 to SrcQ.FieldCount - 1 do
    begin
      ColName := SrcQ.Fields[I].FieldName;
      if SameText(ColName, KeyField) then
        UpdQ.ParamByName('p_' + ColName).DataType := SrcQ.Fields[I].DataType
      else
        UpdQ.ParamByName(ColName).DataType := SrcQ.Fields[I].DataType;
    end;
    UpdQ.Prepare;
    Log('Update: UPDATE подготовлен (' + IntToStr(UpdQ.ParamCount) + ' параметров)');

    RowsRead := 0;
    RowsChanged := 0;
    InBatch := 0;
    StopRequested := False;

    Connections.Target.StartTransaction;
    try
      while (not SrcQ.EOF) and (not TgtQ.EOF) do
      begin
        if FStopFlag^ or Terminated then
        begin
          StopRequested := True;
          Break;
        end;

        SrcPK := SrcQ.FieldByName(KeyField).Value;
        TgtPK := TgtQ.FieldByName(KeyField).Value;
        Cmp := ComparePKValues(SrcPK, TgtPK);

        if Cmp = 0 then
        begin
          Inc(RowsRead);

          NeedUpdate := False;
          for I := 0 to SrcQ.FieldCount - 1 do
          begin
            ColName := SrcQ.Fields[I].FieldName;
            if not FieldValuesEqual(SrcQ.Fields[I], TgtQ.FieldByName(ColName)) then
            begin
              NeedUpdate := True;
              Break;
            end;
          end;

          if NeedUpdate then
          begin
            for I := 0 to SrcQ.FieldCount - 1 do
            begin
              ColName := SrcQ.Fields[I].FieldName;
              if SameText(ColName, KeyField) then
                UpdQ.ParamByName('p_' + ColName).Value := SrcQ.Fields[I].Value
              else
                UpdQ.ParamByName(ColName).Value := SrcQ.Fields[I].Value;
            end;
            UpdQ.ExecSQL;
            Inc(RowsChanged);
            Inc(InBatch);

            if InBatch >= UPDATE_COMMIT_EVERY then
            begin
              Connections.Target.Commit;
              Connections.Target.StartTransaction;
              InBatch := 0;
              Log(Format('Update: коммит, изменено %d', [RowsChanged]));
            end;
          end;

          SrcQ.Next;
          TgtQ.Next;
        end
        else if Cmp < 0 then
        begin

          SrcQ.Next;
        end
        else
        begin

          TgtQ.Next;
        end;
      end;

      Connections.Target.Commit;
    except
      Connections.Target.Rollback;
      Log(Format('Update: ROLLBACK после %d изменений', [RowsChanged]), llError);
      raise;
    end;

    FStats.RowsRead := FStats.RowsRead + RowsRead;
    FStats.RowsWritten := FStats.RowsWritten + RowsChanged;

    SW.Stop;
    if StopRequested then
      Log(Format('Update: прервано, прочитано %d, изменено %d за %d мс',
          [RowsRead, RowsChanged, SW.ElapsedMilliseconds]), llWarning)
    else
      Log(Format('Update: завершено, прочитано %d, изменено %d за %d мс',
          [RowsRead, RowsChanged, SW.ElapsedMilliseconds]));
  finally
    UpdQ.Free;
    TgtQ.Free;
    SrcQ.Free;
  end;
end;

end.

