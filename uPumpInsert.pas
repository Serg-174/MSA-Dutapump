unit uPumpInsert;

interface

uses
  System.SysUtils, Data.DB, System.Classes, System.Generics.Collections, uPumpTypes, FireDAC.Comp.Client,
  FireDAC.Stan.Param, FireDAC.Stan.Option, MSA.Logger;

type
  TTargetColInfo = record
    DataType: TFieldType;
    Precision: Integer;
    Scale: Integer;
    Size: Integer;
  end;

type
  TPkInfo = record
    FieldName: string;
    IsInt64: Boolean;
    ErrorMsg: string;
  end;

function GetTargetColumnInfo(AConn: TFDConnection; const AFullTableName: string): TDictionary<string, TTargetColInfo>;

procedure CopyFieldValues(SrcQ, DstQ: TFDQuery; ARowIdx: Integer);

function InsertRowsByIds(AConnSource, AConnTarget: TFDConnection; const ASelectSQL, AInsertSQL, AKeyField: string; const
  AValues: TArray<Int64>): Int64;

function GetTablePKSingle(AConn: TFDConnection; const ATableName: string): TPkInfo;

implementation

function GetTablePKSingle(AConn: TFDConnection; const ATableName: string): TPkInfo;
var
  Q: TFDQuery;
  P: Integer;
  Schema, Table, DataType: string;
  PkCols: TStringList;
  Precision, Scale: Integer;
begin
  Result.FieldName := '';
  Result.IsInt64 := False;
  Result.ErrorMsg := '';

  P := Pos('.', ATableName);
  if P > 0 then
  begin
    Schema := Copy(ATableName, 1, P - 1);
    Table := Copy(ATableName, P + 1, MaxInt);
  end
  else
  begin
    Schema := 'dbo';
    Table := ATableName;
  end;

  PkCols := TStringList.Create;
  try

    Q := TFDQuery.Create(nil);
    try
      Q.Connection := AConn;
      Q.SQL.Text :=
        'SELECT kcu.COLUMN_NAME ' +
        '  FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc ' +
        '  JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu ' +
        '    ON kcu.CONSTRAINT_NAME   = tc.CONSTRAINT_NAME ' +
        '   AND kcu.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA ' +
        ' WHERE tc.CONSTRAINT_TYPE = ''PRIMARY KEY'' ' +
        '   AND tc.TABLE_SCHEMA    = :schema ' +
        '   AND tc.TABLE_NAME      = :table ' +
        ' ORDER BY kcu.ORDINAL_POSITION';
      Q.ParamByName('schema').AsString := Schema;
      Q.ParamByName('table').AsString := Table;
      Q.Open;
      while not Q.EOF do
      begin
        PkCols.Add(Trim(Q.FieldByName('COLUMN_NAME').AsString));
        Q.Next;
      end;
    finally
      Q.Free;
    end;

    if PkCols.Count = 0 then
    begin
      Result.ErrorMsg := 'первичный ключ не найден';
      Exit;
    end;
    if PkCols.Count > 1 then
    begin
      Result.ErrorMsg := Format('составной PK (%d колонки) — не поддерживается',
        [PkCols.Count]);
      Exit;
    end;

    Result.FieldName := PkCols[0];

    Q := TFDQuery.Create(nil);
    try
      Q.Connection := AConn;
      Q.SQL.Text :=
        'SELECT DATA_TYPE, NUMERIC_PRECISION, NUMERIC_SCALE ' +
        '  FROM INFORMATION_SCHEMA.COLUMNS ' +
        ' WHERE TABLE_SCHEMA = :schema ' +
        '   AND TABLE_NAME   = :table ' +
        '   AND COLUMN_NAME  = :col';
      Q.ParamByName('schema').AsString := Schema;
      Q.ParamByName('table').AsString := Table;
      Q.ParamByName('col').AsString := Result.FieldName;
      Q.Open;
      if Q.IsEmpty then
      begin
        Result.ErrorMsg := 'PK-колонка не найдена в INFORMATION_SCHEMA.COLUMNS';
        Exit;
      end;

      DataType := LowerCase(Trim(Q.FieldByName('DATA_TYPE').AsString));
      Precision := Q.FieldByName('NUMERIC_PRECISION').AsInteger;
      Scale := Q.FieldByName('NUMERIC_SCALE').AsInteger;

      if (DataType = 'int') or (DataType = 'bigint') or
        (DataType = 'smallint') or (DataType = 'tinyint') then
        Result.IsInt64 := True
      else if (DataType = 'numeric') or (DataType = 'decimal') then
      begin

        if (Scale = 0) and (Precision > 0) and (Precision <= 18) then
          Result.IsInt64 := True
        else
          Result.ErrorMsg := Format(
            'PK numeric(%d,%d) — поддерживается только numeric(p,0) при p<=18',
            [Precision, Scale]);
      end
      else
        Result.ErrorMsg := 'PK тип "' + DataType +
          '" не поддерживается (нужен целочисленный: ' +
          'int/bigint/smallint/tinyint/numeric(p,0))';
    finally
      Q.Free;
    end;
  finally
    PkCols.Free;
  end;
end;

function GetTargetColumnInfo(AConn: TFDConnection; const AFullTableName: string): TDictionary<string, TTargetColInfo>;
var
  Q: TFDQuery;
  P: Integer;
  Schema, Table, DT: string;
  Info: TTargetColInfo;
  MaxLen: Integer;
begin
  Result := TDictionary<string, TTargetColInfo>.Create;

  P := Pos('.', AFullTableName);
  if P > 0 then
  begin
    Schema := Copy(AFullTableName, 1, P - 1);
    Table := Copy(AFullTableName, P + 1, MaxInt);
  end
  else
  begin
    Schema := 'dbo';
    Table := AFullTableName;
  end;

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := AConn;
    Q.SQL.Text :=
      'SELECT COLUMN_NAME, DATA_TYPE, NUMERIC_PRECISION, NUMERIC_SCALE, ' +
      '       CHARACTER_MAXIMUM_LENGTH ' +
      '  FROM INFORMATION_SCHEMA.COLUMNS ' +
      ' WHERE TABLE_SCHEMA = :schema AND TABLE_NAME = :table';
    Q.ParamByName('schema').AsString := Schema;
    Q.ParamByName('table').AsString := Table;
    Q.Open;

    while not Q.EOF do
    begin
      DT := LowerCase(Trim(Q.FieldByName('DATA_TYPE').AsString));

      if (DT = 'numeric') or (DT = 'decimal') or (DT = 'money') or (DT = 'smallmoney') then
      begin
        Info.DataType := ftBCD;
        Info.Precision := Q.FieldByName('NUMERIC_PRECISION').AsInteger;
        Info.Scale := Q.FieldByName('NUMERIC_SCALE').AsInteger;
        Info.Size := 0;
      end
      else if DT = 'int' then
      begin
        Info.DataType := ftInteger;
        Info.Precision := 10;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else if DT = 'bigint' then
      begin
        Info.DataType := ftLargeint;
        Info.Precision := 19;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else if DT = 'smallint' then
      begin
        Info.DataType := ftSmallint;
        Info.Precision := 5;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else if DT = 'tinyint' then
      begin
        Info.DataType := ftByte;
        Info.Precision := 3;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else if DT = 'bit' then
      begin
        Info.DataType := ftBoolean;
        Info.Precision := 1;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else if (DT = 'datetime') or (DT = 'datetime2') or (DT = 'smalldatetime') then
      begin
        Info.DataType := ftDateTime;
        Info.Precision := 0;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else if DT = 'date' then
      begin
        Info.DataType := ftDate;
        Info.Precision := 0;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else if DT = 'time' then
      begin
        Info.DataType := ftTime;
        Info.Precision := 0;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else if (DT = 'varchar') or (DT = 'char') or (DT = 'text') then
      begin
        MaxLen := Q.FieldByName('CHARACTER_MAXIMUM_LENGTH').AsInteger;
        if MaxLen < 0 then
          MaxLen := 8000;
        Info.DataType := ftString;
        Info.Precision := 0;
        Info.Scale := 0;
        Info.Size := MaxLen;
      end
      else if (DT = 'nvarchar') or (DT = 'nchar') or (DT = 'ntext') then
      begin
        MaxLen := Q.FieldByName('CHARACTER_MAXIMUM_LENGTH').AsInteger;
        if MaxLen < 0 then
          MaxLen := 4000;
        Info.DataType := ftWideString;
        Info.Precision := 0;
        Info.Scale := 0;
        Info.Size := MaxLen;
      end
      else if (DT = 'float') then
      begin
        Info.DataType := ftFloat;
        Info.Precision := 0;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else if (DT = 'real') then
      begin
        Info.DataType := ftSingle;
        Info.Precision := 0;
        Info.Scale := 0;
        Info.Size := 0;
      end
      else
      begin
        Info.DataType := ftUnknown;
        Info.Precision := 0;
        Info.Scale := 0;
        Info.Size := 0;
        GLog('Special: неизвестный тип target ' + DT + ' для поля ' +
          Q.FieldByName('COLUMN_NAME').AsString, llWarning);
      end;

      Result.AddOrSetValue(Q.FieldByName('COLUMN_NAME').AsString, Info);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure CopyFieldValues(SrcQ, DstQ: TFDQuery; ARowIdx: Integer);
var
  K: Integer;
  ParamName: string;
  SrcField: TField;
begin
  for K := 0 to DstQ.ParamCount - 1 do
  begin
    ParamName := DstQ.Params[K].Name;
    SrcField := SrcQ.FieldByName(ParamName);
    case SrcField.DataType of
      ftString, ftWideString, ftFixedChar, ftFixedWideChar, ftMemo, ftWideMemo:
        DstQ.Params[K].AsStrings[ARowIdx] := SrcField.AsString;
      ftSmallint:
        DstQ.Params[K].AsSmallInts[ARowIdx] := SrcField.AsInteger;
      ftInteger:
        DstQ.Params[K].AsIntegers[ARowIdx] := SrcField.AsInteger;
      ftLargeint:
        DstQ.Params[K].AsLargeInts[ARowIdx] := SrcField.AsLargeInt;
      ftFloat, ftCurrency:
        DstQ.Params[K].AsFloats[ARowIdx] := SrcField.AsFloat;
      ftDate, ftTime, ftDateTime, ftTimeStamp:
        DstQ.Params[K].Values[ARowIdx] := SrcField.AsDateTime;
      ftBoolean:
        DstQ.Params[K].AsBooleans[ARowIdx] := SrcField.AsBoolean;
    else
      DstQ.Params[K].Values[ARowIdx] := SrcField.Value;
    end;
  end;
end;

function InsertRowsByIds(AConnSource, AConnTarget: TFDConnection; const ASelectSQL, AInsertSQL, AKeyField: string; const
  AValues: TArray<Int64>): Int64;
var
  InList, ParamName: string;
  K, RowInBatch: Integer;
  SrcQ, DstQ: TFDQuery;
begin
  Result := 0;
  if Length(AValues) = 0 then
    Exit;

  InList := '';
  for K := 0 to High(AValues) do
  begin
    if K > 0 then
      InList := InList + ',';
    InList := InList + ':' + AKeyField + IntToStr(K);
  end;

  SrcQ := TFDQuery.Create(nil);
  try
    SrcQ.Connection := AConnSource;
    SrcQ.SQL.Text := ASelectSQL + ' WHERE ' + AKeyField + ' IN (' + InList + ')';
    for K := 0 to High(AValues) do
      SrcQ.Params[K].AsLargeInt := AValues[K];
    MakeQueryStreaming(SrcQ, 5000);
    SrcQ.Open;
    if SrcQ.IsEmpty then
      Exit;

    DstQ := TFDQuery.Create(nil);
    try
      DstQ.Connection := AConnTarget;
      DstQ.SQL.Text := AInsertSQL;
      for K := 0 to DstQ.ParamCount - 1 do
      begin
        ParamName := DstQ.Params[K].Name;
        DstQ.Params[K].DataType := SrcQ.FieldByName(ParamName).DataType;
        DstQ.Params[K].ArraySize := Length(AValues);
      end;
      DstQ.Prepare;

      RowInBatch := 0;
      while not SrcQ.EOF do
      begin
        CopyFieldValues(SrcQ, DstQ, RowInBatch);
        Inc(RowInBatch);
        SrcQ.Next;
      end;

      AConnTarget.StartTransaction;
      try
        DstQ.Execute(RowInBatch, 0);
        AConnTarget.Commit;
        Result := RowInBatch;
      except
        AConnTarget.Rollback;
        raise;
      end;
    finally
      DstQ.Free;
    end;
  finally
    SrcQ.Free;
  end;
end;

end.

