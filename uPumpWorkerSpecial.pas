unit uPumpWorkerSpecial;

interface

uses
  System.SysUtils, System.Classes, System.Diagnostics, System.Generics.Collections, Data.DB, FireDAC.Comp.Client,
  FireDAC.Stan.Param, FireDAC.Stan.Option, uPumpTypes, uPumpWorker, uPumpInsert, MSA.Logger;

type
  TPumpWorkerSpecial = class(TPumpWorker)
  private
    FSource: TSpecialDataSource;
    procedure DoWorkSource;
  protected
    procedure Execute; override;
    procedure DoWork(const ATask: TPumpTask; const AQuery: TQueries); override;
  public
    constructor Create(AWorkerId: Integer; const ASource: TSpecialDataSource; AStopFlag: PBoolean; const ASettings:
      TPumpSettings);
  end;

implementation


{ TPumpWorkerSpecial }
constructor TPumpWorkerSpecial.Create(AWorkerId: Integer; const ASource: TSpecialDataSource; AStopFlag: PBoolean; const
  ASettings: TPumpSettings);
begin
  inherited Create(AWorkerId, 'S', nil, AStopFlag, ASettings);
  FSource := ASource;
  FCurrentTable := ASource.SectionName;
end;

procedure TPumpWorkerSpecial.DoWork(const ATask: TPumpTask; const AQuery: TQueries);
begin

end;

procedure TPumpWorkerSpecial.Execute;
var
  IntervalMs, Elapsed: Integer;
begin
  try
    FCurrentTable := FSource.TableName;
    Log('Special: Execute START');
    Log(Format('Special: IntervalSec=%d, Enabled=%s',
        [FSource.IntervalSec, BoolToStr(FSource.Enabled, True)]));

    if Trim(FSource.InsertSQL) = '' then
    begin
      Log('Special: InsertSQL пуст Ч воркер не может работать', llError);
      Exit;
    end;

    Log('Special: открытие соединений...');
    FConnections.Open;
    Log('Special: соединени€ открыты');

    try
      while not FStopFlag^ do
      begin
        Log('Special: начало итерации');

        FStats.SessionID := GSessionID;
        FStats.TableName := FSource.TableName;
        FStats.Operation := poSpecial;
        FStats.RowsRead := 0;
        FStats.RowsWritten := 0;
        FStats.GapFilled := 0;
        FStats.ElapsedMs := 0;
        FStats.ErrorMsg := '';

        var SW := TStopwatch.StartNew;
        var TaskError := '';
        try
          Log(Format('>>> %s [Special]', [FSource.TableName]));
          DoWorkSource;
          SW.Stop;
          Log(Format('<<< added=%d, врем€=%d мс',
              [FStats.RowsWritten, SW.ElapsedMilliseconds]));
        except
          on E: Exception do
          begin
            SW.Stop;
            TaskError := E.ClassName + ': ' + E.Message;
            Log(Format('!!! %s (после %d мс)',
                [TaskError, SW.ElapsedMilliseconds]), llError);
          end;
        end;

        FStats.ElapsedMs := SW.ElapsedMilliseconds;
        FStats.ErrorMsg := TaskError;

        UpdateTableStat(FSource.TableName, FStats.RowsRead, FStats.RowsWritten,
          SW.ElapsedMilliseconds, FStats.GapFilled, TaskError);

        if Assigned(GStatWriteProc) then
          GStatWriteProc(FStats);

        if FSource.IntervalSec <= 0 then
        begin
          Log('Special: одноразовый режим Ч завершение');
          Break;
        end;

        IntervalMs := FSource.IntervalSec * 1000;
        Log(Format('Special: пауза %d сек', [FSource.IntervalSec]));
        Elapsed := 0;
        while (Elapsed < IntervalMs) and (not FStopFlag^) do
        begin
          Sleep(200);
          Inc(Elapsed, 200);
        end;
      end;
    finally
      Log('Special: закрытие соединений');
      FConnections.Close();
      Log('Special-воркер завершЄн');
    end;
  except
    on E: Exception do
      GLog(Format('[S%d]  –»“»„≈— јя ќЎ»Ѕ ј: %s: %s',
          [FWorkerId, E.ClassName, E.Message]), llError);
  end;
end;

procedure TPumpWorkerSpecial.DoWorkSource;
var
  SrcQ, DstQ: TFDQuery;
  I: Integer;
  ParamName: string;
  SW, SWStep: TStopwatch;
  RowsAffected: Integer;
  WrittenTotal, FailedTotal: Int64;
  ColInfo: TDictionary<string, TTargetColInfo>;
  Info: TTargetColInfo;
  CommitEvery: Integer;
  InBatch: Integer;
  Stopped: Boolean;
begin
  SW := TStopwatch.StartNew;
  Log('DoWorkSource: START');

  if FStopFlag^ then
  begin
    Log('DoWorkSource: стоп-флаг установлен Ч выход');
    Exit;
  end;

  SWStep := TStopwatch.StartNew;
  SrcQ := TFDQuery.Create(nil);
  try
    SrcQ.Connection := Connections.Source;
    SrcQ.SQL.Text := FSource.SelectSQL;
    {
    SrcQ.FetchOptions.Mode := fmOnDemand;
    SrcQ.FetchOptions.AutoFetchAll := afDisable;
    SrcQ.FetchOptions.RowsetSize := 1000;
    }
    MakeQueryStreaming(SrcQ, 1000);

    SrcQ.FormatOptions.MaxStringSize := 4000;

    Log('DoWorkSource: открытие SELECT из Oracle...');
    SrcQ.Open;
    Log('DoWorkSource: SELECT открыт');

    if SrcQ.IsEmpty then
    begin
      SWStep.Stop;
      Log(Format('[1/3] Ќет данных из Oracle (IsEmpty=True, %d мс)',
          [SWStep.ElapsedMilliseconds]), llWarning);
      Exit;
    end;

    SWStep.Stop;
    Log(Format('[1/3] »сточник открыт, данные есть (%d мс)',
        [SWStep.ElapsedMilliseconds]));

    if FStopFlag^ then
    begin
      Log('Special: сигнал остановки после SELECT', llWarning);
      Exit;
    end;

    SWStep := TStopwatch.StartNew;
    Log('DoWorkSource: чтение схемы target ' + FSource.TableName + '...');
    ColInfo := GetTargetColumnInfo(Connections.Target, FSource.TableName);
    try
      Log(Format('[2/3] —хема target прочитана: %d колонок (%d мс)',
          [ColInfo.Count, SWStep.ElapsedMilliseconds]));

      SWStep := TStopwatch.StartNew;
      DstQ := TFDQuery.Create(nil);
      try
        DstQ.Connection := Connections.Target;
        DstQ.SQL.Text := FSource.InsertSQL;
        DstQ.FormatOptions.MaxStringSize := 4000;

        if DstQ.ParamCount = 0 then
        begin
          Log('DoWorkSource: ParamCount=0 Ч InsertSQL битый!', llError);
          Exit;
        end;

        for I := 0 to DstQ.ParamCount - 1 do
        begin
          ParamName := DstQ.Params[I].Name;
          if ColInfo.TryGetValue(ParamName, Info) and (Info.DataType <> ftUnknown) then
          begin
            DstQ.Params[I].DataType := Info.DataType;

            case Info.DataType of
              ftBCD:
                begin
                  DstQ.Params[I].Precision := Info.Precision;
                  DstQ.Params[I].NumericScale := Info.Scale;
                end;
              ftString, ftWideString:
                begin
                  if Info.Size > 0 then
                    DstQ.Params[I].Size := Info.Size;
                end;
            end;
          end
          else
          begin

            DstQ.Params[I].DataType := SrcQ.FieldByName(ParamName).DataType;
            Log('DoWorkSource: fallback дл€ ' + ParamName + ', тип из source', llWarning);
          end;
        end;
         {

        for I := 0 to DstQ.ParamCount - 1 do
        begin
          ParamName := DstQ.Params[I].Name;
          Log(Format('  param[%d] %s dstType=%d prec=%d scale=%d size=%d',
            [I, ParamName,
             Ord(DstQ.Params[I].DataType),
             DstQ.Params[I].Precision,
             DstQ.Params[I].NumericScale,
             DstQ.Params[I].Size]));
        end;
        }

        try
          DstQ.Prepare;
        except
          on E: Exception do
          begin
            Log('DoWorkSource: ошибка Prepare: ' + E.ClassName + ': ' + E.Message, llError);
            raise;
          end;
        end;
        Log(Format('[3/3] INSERT подготовлен (%d мс, %d параметров)',
            [SWStep.ElapsedMilliseconds, DstQ.ParamCount]));

        WrittenTotal := 0;
        FailedTotal := 0;
        CommitEvery := FSource.CommitEvery;
        if CommitEvery < 0 then
          CommitEvery := 0;
        InBatch := 0;
        Stopped := False;

        Connections.Target.StartTransaction;
        try
          while not SrcQ.Eof do
          begin
            if FStopFlag^ then
            begin
              Stopped := True;
              Break;
            end;

            for I := 0 to DstQ.ParamCount - 1 do
            begin
              ParamName := DstQ.Params[I].Name;
              DstQ.Params[I].Value := SrcQ.FieldByName(ParamName).Value;
            end;

            try
              DstQ.ExecSQL;
              RowsAffected := DstQ.RowsAffected;
              Inc(WrittenTotal, RowsAffected);
              Inc(InBatch, RowsAffected);
              if RowsAffected = 0 then
                Inc(FailedTotal);
            except
              on E: Exception do
              begin
                Inc(FailedTotal);
                if FailedTotal <= 5 then
                  Log('  строка пропущена: ' + E.ClassName + ': ' + E.Message, llWarning);
              end;
            end;

            SrcQ.Next;

            if (CommitEvery > 0) and (InBatch >= CommitEvery) then
            begin
              Connections.Target.Commit;
              Log(Format('  [Special] закоммичено %d, всего вставлено %d (ошибок/пропусков: %d)',
                  [InBatch, WrittenTotal, FailedTotal]));
              Connections.Target.StartTransaction;
              InBatch := 0;
            end;
          end;

          if InBatch > 0 then
          begin
            Connections.Target.Commit;
            Log(Format('  [Special] закоммичено %d (финальный батч), всего вставлено %d (ошибок/пропусков: %d)',
                [InBatch, WrittenTotal, FailedTotal]));
            InBatch := 0;
          end
          else
          begin

            Connections.Target.Commit;
          end;

          SWStep.Stop;

          FStats.RowsRead := FStats.RowsRead + WrittenTotal + FailedTotal;
          FStats.RowsWritten := FStats.RowsWritten + WrittenTotal;

          if Stopped then
            Log(Format('[3/3] INSERT прерван по стоп-флагу: вставлено %d за %d мс, ' +
                'пропущено/ошибок: %d',
                [WrittenTotal, SWStep.ElapsedMilliseconds, FailedTotal]), llWarning)
          else if WrittenTotal = 0 then
            Log(Format('[3/3] INSERT завершЄн: 0 записей (все уже есть или ошибки) ' +
                'за %d мс, пропущено/ошибок: %d',
                [SWStep.ElapsedMilliseconds, FailedTotal]), llWarning)
          else
            Log(Format('[3/3] INSERT завершЄн: %d записей за %d мс (%.0f зап/с), пропущено: %d',
                [WrittenTotal, SWStep.ElapsedMilliseconds,
                  WrittenTotal * 1000.0 / (SWStep.ElapsedMilliseconds + 1),
                  FailedTotal]));
        except
          Connections.Target.Rollback;
          Log(Format('[3/3] ROLLBACK после %d записей (в несохранЄнном батче Ч %d)',
              [WrittenTotal, InBatch]), llError);
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

  SW.Stop;
  Log(Format('Special: итого %d мс', [SW.ElapsedMilliseconds]));
  Log('DoWorkSource: END');
end;

end.

