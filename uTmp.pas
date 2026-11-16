unit uTmp;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ExtCtrls, System.Generics.Collections;

type
  TfTmp = class(TForm)
    Memo1: TMemo;
    Panel1: TPanel;
    Label1: TLabel;
    CheckBox1: TCheckBox;
    Button1: TButton;
    Button2: TButton;
    Button3: TButton;
    Button4: TButton;
    Button5: TButton;
    Button6: TButton;
    procedure Button1Click(Sender: TObject);
    procedure Button2Click(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormDestroy(Sender: TObject);
    procedure Button3Click(Sender: TObject);
    procedure Button4Click(Sender: TObject);
    procedure Button5Click(Sender: TObject);
    procedure Button6Click(Sender: TObject);
  private
    { Private declarations }
  public
    { Public declarations }
    procedure AddLogLine(const S: string);
    procedure ShowStatistics;
  end;

var
  fTmp: TfTmp;

implementation

{$R *.dfm}

uses
  uMain, uPumpTypes;

procedure TfTmp.ShowStatistics;
var
  Stat: TTableStat;
  AllTables: TStringList;
  TableName: string;
  TotalRead, TotalWritten, TotalMs, TotalGap: Int64;
  Count, ErrorCount, NoRunsCount: Integer;
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  AllTables := TStringList.Create;
  try
    Lines.Add('=== Статистика по таблицам ===');
    Lines.Add('SessionID: ' + GUIDToString(GSessionID));

    GConfigLock.Enter;
    try
      AllTables.Sorted := True;
      AllTables.Duplicates := dupIgnore;
      AllTables.AddStrings(GTablesToLoad);
      AllTables.AddStrings(GTablesToLoadGapFill);
    finally
      GConfigLock.Leave;
    end;

    TotalRead := 0;
    TotalWritten := 0;
    TotalMs := 0;
    TotalGap := 0;
    Count := 0;
    ErrorCount := 0;
    NoRunsCount := 0;

    if AllTables.Count = 0 then
    begin
      Lines.Add('  (список таблиц пуст)');
    end
    else
    begin
      GConfigLock.Enter;
      try
        for TableName in AllTables do
        begin
          Inc(Count);

          if GTableStats.TryGetValue(TableName, Stat) then
          begin
            Inc(TotalRead, Stat.RowsRead);
            Inc(TotalWritten, Stat.RowsWritten);
            Inc(TotalMs, Stat.TotalMs);
            Inc(TotalGap, Stat.GapFilled);
            if Stat.LastError <> '' then
              Inc(ErrorCount);

          //Ы  Lines.Add(Format('  %s', [TableName]));
            Lines.Add(Format(' %s :    runs=%d, read=%d, written=%d, gapFilled=%d, time=%d мс, lastRun=%s', [TableName, Stat.Runs, Stat.RowsRead, Stat.RowsWritten, Stat.GapFilled, Stat.TotalMs, FormatDateTime('dd.mm.yyyy hh:nn:ss', Stat.LastRunAt)]));

            if Stat.LastError <> '' then
              Lines.Add('    lastErr: ' + Stat.LastError);
          end
          else
          begin
            // Таблица в списке, но ещё не обрабатывалась
            Inc(NoRunsCount);
            Lines.Add(Format('  %s', [TableName]));
            Lines.Add('    (ещё не обрабатывалась в этом сеансе)');
          end;
        end;
      finally
        GConfigLock.Leave;
      end;
    end;

    Lines.Add('');
    Lines.Add('=== Итого ===');
    Lines.Add(Format('  таблиц в списке: %d (без обработки: %d, с ошибками: %d)', [Count, NoRunsCount, ErrorCount]));
    Lines.Add(Format('  read=%d, written=%d, gapFilled=%d, time=%d мс', [TotalRead, TotalWritten, TotalGap, TotalMs]));
    Lines.Add('=== Конец ===');

    Memo1.Lines.AddStrings(Lines);
  finally
    AllTables.Free;
    Lines.Free;
  end;
end;

procedure TfTmp.AddLogLine(const S: string);
begin
  if TThread.CurrentThread.ThreadID = MainThreadID then
    Memo1.Lines.Add(S)
  else
    TThread.Queue(nil,
      procedure
      begin
        Memo1.Lines.Add(S);
      end);
end;

procedure TfTmp.Button1Click(Sender: TObject);
begin
  msadpsvc.DatapumpServiceStart;
end;

procedure TfTmp.Button2Click(Sender: TObject);
begin
  msadpsvc.DatapumpServiceStop;
end;

procedure TfTmp.Button3Click(Sender: TObject);
var
  Tables: string;
begin
  msadpsvc.InitOracleSession;
  Tables := msadpsvc.GetVPDTablesAsString;
  msadpsvc.WriteLog('VPD-таблицы: ' + Tables);
  // "A_ACODE;A_ACODE_EXT;A_OBJECT;..."
end;

procedure TfTmp.Button4Click(Sender: TObject);
begin
 msadpsvc.ReloadConfig;
end;

procedure TfTmp.Button5Click(Sender: TObject);
begin
  msadpsvc.LogQueries;
end;

procedure TfTmp.Button6Click(Sender: TObject);
begin
  ShowStatistics;
end;

procedure TfTmp.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  msadpsvc.DatapumpServiceStop;
end;

procedure TfTmp.FormDestroy(Sender: TObject);
begin
  msadpsvc.DatapumpServiceStop;
end;

end.

