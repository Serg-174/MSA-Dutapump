unit uPumpPQProgress;

interface

uses
  System.SysUtils, Data.DB, FireDAC.Comp.Client, FireDAC.Stan.Param;

type
  TPQProgress = record
    LastPK: Int64;
    LastRowId: string;
    RidFrom: string;
    RidTo: string;
    TotalRows: Int64;
    MinPK: Int64;
    MaxPK: Int64;
    RowsWritten: Int64;
    StartedAt: TDateTime;
    UpdatedAt: TDateTime;
    CompletedAt: TDateTime;
  end;

  TPQProgressDB = class
  private
    FConn: TFDConnection;
  public
    constructor Create(AConn: TFDConnection);
    procedure EnsureExists;

    function  TryRead(const ASectionName: string; ASetIndex: Integer;
      out AProgress: TPQProgress; AChunkIndex: Integer = 0): Boolean;

    procedure Init(const ASectionName: string; ASetIndex: Integer;
      AMinPK, AMaxPK, ATotalRows: Int64;
      AChunkIndex: Integer = 0;
      const ARidFrom: string = ''; const ARidTo: string = '');

    procedure Update(const ASectionName: string; ASetIndex: Integer;
      ALastPK, ARowsWritten: Int64;
      AChunkIndex: Integer = 0; const ALastRowId: string = '');

    procedure MarkCompleted(const ASectionName: string; ASetIndex: Integer;
      AChunkIndex: Integer = 0);

    procedure Delete(const ASectionName: string; ASetIndex: Integer;
      AChunkIndex: Integer = 0);


    procedure DeleteAllChunks(const ASectionName: string; ASetIndex: Integer);
    function  HasChunks(const ASectionName: string; ASetIndex: Integer): Boolean;
    function  GetChunkCount(const ASectionName: string; ASetIndex: Integer): Integer;
  end;

implementation

const
  PROGRESS_TABLE = 'tiger.DataPumpPQProgress';

constructor TPQProgressDB.Create(AConn: TFDConnection);
begin
  inherited Create;
  FConn := AConn;
end;

procedure TPQProgressDB.EnsureExists;
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;


    Q.SQL.Text :=
      'IF NOT EXISTS (SELECT * FROM sys.objects ' +
      '                WHERE object_id = OBJECT_ID(''' + PROGRESS_TABLE + ''') ' +
      '                  AND type = ''U'') ' +
      'BEGIN ' +
      'CREATE TABLE ' + PROGRESS_TABLE + ' ( ' +
      '  SectionName NVARCHAR(255) NOT NULL, ' +
      '  SetIndex    INT           NOT NULL, ' +
      '  ChunkIndex  INT           NOT NULL DEFAULT 0, ' +
      '  LastPK      BIGINT        NOT NULL DEFAULT 0, ' +
      '  LastRowId   NVARCHAR(30)  NULL, ' +
      '  RidFrom     NVARCHAR(30)  NULL, ' +
      '  RidTo       NVARCHAR(30)  NULL, ' +
      '  TotalRows   BIGINT        NULL, ' +
      '  MinPK       BIGINT        NULL, ' +
      '  MaxPK       BIGINT        NULL, ' +
      '  RowsWritten BIGINT        NOT NULL DEFAULT 0, ' +
      '  StartedAt   DATETIME      NULL, ' +
      '  UpdatedAt   DATETIME      NOT NULL DEFAULT GETDATE(), ' +
      '  CompletedAt DATETIME      NULL, ' +
      '  CONSTRAINT PK_DataPumpPQProgress PRIMARY KEY (SectionName, SetIndex, ChunkIndex) ' +
      '); ' +
      'END';
    Q.ExecSQL;


    Q.SQL.Text := 'IF COL_LENGTH(''' + PROGRESS_TABLE + ''', ''ChunkIndex'') IS NULL ' +
                  '  ALTER TABLE ' + PROGRESS_TABLE + ' ADD ChunkIndex INT NULL;';
    Q.ExecSQL;
    Q.SQL.Text := 'UPDATE ' + PROGRESS_TABLE + ' SET ChunkIndex = 0 WHERE ChunkIndex IS NULL;';
    Q.ExecSQL;
    Q.SQL.Text := 'IF EXISTS (SELECT 1 FROM sys.columns ' +
                  ' WHERE object_id = OBJECT_ID(''' + PROGRESS_TABLE + ''') ' +
                  '   AND name = ''ChunkIndex'' AND is_nullable = 1) ' +
                  '  ALTER TABLE ' + PROGRESS_TABLE + ' ALTER COLUMN ChunkIndex INT NOT NULL;';
    Q.ExecSQL;

    Q.SQL.Text := 'IF COL_LENGTH(''' + PROGRESS_TABLE + ''', ''LastRowId'') IS NULL ' +
                  '  ALTER TABLE ' + PROGRESS_TABLE + ' ADD LastRowId NVARCHAR(30) NULL;';
    Q.ExecSQL;
    Q.SQL.Text := 'IF COL_LENGTH(''' + PROGRESS_TABLE + ''', ''RidFrom'') IS NULL ' +
                  '  ALTER TABLE ' + PROGRESS_TABLE + ' ADD RidFrom NVARCHAR(30) NULL;';
    Q.ExecSQL;
    Q.SQL.Text := 'IF COL_LENGTH(''' + PROGRESS_TABLE + ''', ''RidTo'') IS NULL ' +
                  '  ALTER TABLE ' + PROGRESS_TABLE + ' ADD RidTo NVARCHAR(30) NULL;';
    Q.ExecSQL;


    Q.SQL.Text :=
      'IF EXISTS (SELECT 1 FROM sys.indexes i ' +
      '            WHERE i.object_id = OBJECT_ID(''' + PROGRESS_TABLE + ''') ' +
      '              AND i.is_primary_key = 1) ' +
      '   AND NOT EXISTS (SELECT 1 FROM sys.indexes i ' +
      '                     JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id ' +
      '                     JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id ' +
      '                    WHERE i.object_id = OBJECT_ID(''' + PROGRESS_TABLE + ''') ' +
      '                      AND i.is_primary_key = 1 AND c.name = ''ChunkIndex'') ' +
      'BEGIN ' +
      '  ALTER TABLE ' + PROGRESS_TABLE + ' DROP CONSTRAINT PK_DataPumpPQProgress; ' +
      'END;';


    try Q.ExecSQL; except end;

    Q.SQL.Text :=
      'IF NOT EXISTS (SELECT 1 FROM sys.key_constraints ' +
      '                WHERE name = ''PK_DataPumpPQProgress'' ' +
      '                  AND parent_object_id = OBJECT_ID(''' + PROGRESS_TABLE + ''')) ' +
      '  ALTER TABLE ' + PROGRESS_TABLE + ' ADD CONSTRAINT PK_DataPumpPQProgress ' +
      '    PRIMARY KEY (SectionName, SetIndex, ChunkIndex);';
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

function TPQProgressDB.TryRead(const ASectionName: string; ASetIndex: Integer;
  out AProgress: TPQProgress; AChunkIndex: Integer): Boolean;
var
  Q: TFDQuery;
begin
  Result := False;
  FillChar(AProgress, SizeOf(AProgress), 0);
  AProgress.LastRowId := '';
  AProgress.RidFrom := '';
  AProgress.RidTo := '';

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'SELECT LastPK, LastRowId, RidFrom, RidTo, TotalRows, MinPK, MaxPK, RowsWritten, ' +
      '       StartedAt, UpdatedAt, CompletedAt ' +
      '  FROM ' + PROGRESS_TABLE +
      ' WHERE SectionName = :sn AND SetIndex = :si AND ChunkIndex = :ci';
    Q.ParamByName('sn').AsString  := ASectionName;
    Q.ParamByName('si').AsInteger := ASetIndex;
    Q.ParamByName('ci').AsInteger := AChunkIndex;
    Q.Open;
    if Q.IsEmpty then Exit;

    AProgress.LastPK := Q.FieldByName('LastPK').AsLargeInt;
    if not Q.FieldByName('LastRowId').IsNull then AProgress.LastRowId := Q.FieldByName('LastRowId').AsString;
    if not Q.FieldByName('RidFrom').IsNull  then AProgress.RidFrom  := Q.FieldByName('RidFrom').AsString;
    if not Q.FieldByName('RidTo').IsNull    then AProgress.RidTo    := Q.FieldByName('RidTo').AsString;
    if not Q.FieldByName('TotalRows').IsNull then AProgress.TotalRows := Q.FieldByName('TotalRows').AsLargeInt;
    if not Q.FieldByName('MinPK').IsNull    then AProgress.MinPK := Q.FieldByName('MinPK').AsLargeInt;
    if not Q.FieldByName('MaxPK').IsNull    then AProgress.MaxPK := Q.FieldByName('MaxPK').AsLargeInt;
    AProgress.RowsWritten := Q.FieldByName('RowsWritten').AsLargeInt;
    if not Q.FieldByName('StartedAt').IsNull   then AProgress.StartedAt   := Q.FieldByName('StartedAt').AsDateTime;
    if not Q.FieldByName('UpdatedAt').IsNull   then AProgress.UpdatedAt   := Q.FieldByName('UpdatedAt').AsDateTime;
    if not Q.FieldByName('CompletedAt').IsNull then AProgress.CompletedAt := Q.FieldByName('CompletedAt').AsDateTime;

    Result := True;
  finally
    Q.Free;
  end;
end;

procedure TPQProgressDB.Init(const ASectionName: string; ASetIndex: Integer;
  AMinPK, AMaxPK, ATotalRows: Int64; AChunkIndex: Integer;
  const ARidFrom, ARidTo: string);
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'IF NOT EXISTS (SELECT 1 FROM ' + PROGRESS_TABLE +
      '                WHERE SectionName = :sn AND SetIndex = :si AND ChunkIndex = :ci) ' +
      '  INSERT INTO ' + PROGRESS_TABLE +
      '    (SectionName, SetIndex, ChunkIndex, LastPK, LastRowId, RidFrom, RidTo, ' +
      '     TotalRows, MinPK, MaxPK, RowsWritten, StartedAt, UpdatedAt) ' +
      '  VALUES ' +
      '    (:sn, :si, :ci, :lp, :rid_last, :rid_from, :rid_to, ' +
      '     :total, :minpk, :maxpk, 0, GETDATE(), GETDATE());';
    Q.ParamByName('sn').AsString    := ASectionName;
    Q.ParamByName('si').AsInteger   := ASetIndex;
    Q.ParamByName('ci').AsInteger   := AChunkIndex;
    Q.ParamByName('lp').AsLargeInt  := AMinPK - 1;
    if ARidFrom = '' then Q.ParamByName('rid_last').Clear
    else Q.ParamByName('rid_last').AsString := ARidFrom;
    if ARidFrom = '' then Q.ParamByName('rid_from').Clear
    else Q.ParamByName('rid_from').AsString := ARidFrom;
    if ARidTo   = '' then Q.ParamByName('rid_to').Clear
    else Q.ParamByName('rid_to').AsString   := ARidTo;
    Q.ParamByName('total').AsLargeInt := ATotalRows;
    Q.ParamByName('minpk').AsLargeInt := AMinPK;
    Q.ParamByName('maxpk').AsLargeInt := AMaxPK;
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

procedure TPQProgressDB.Update(const ASectionName: string; ASetIndex: Integer;
  ALastPK, ARowsWritten: Int64; AChunkIndex: Integer; const ALastRowId: string);
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'UPDATE ' + PROGRESS_TABLE +
      '   SET LastPK = :lp, LastRowId = :rid, RowsWritten = :rw, UpdatedAt = GETDATE() ' +
      ' WHERE SectionName = :sn AND SetIndex = :si AND ChunkIndex = :ci';
    Q.ParamByName('lp').AsLargeInt  := ALastPK;
    if ALastRowId = '' then Q.ParamByName('rid').Clear
    else Q.ParamByName('rid').AsString := ALastRowId;
    Q.ParamByName('rw').AsLargeInt  := ARowsWritten;
    Q.ParamByName('sn').AsString    := ASectionName;
    Q.ParamByName('si').AsInteger   := ASetIndex;
    Q.ParamByName('ci').AsInteger   := AChunkIndex;
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

procedure TPQProgressDB.MarkCompleted(const ASectionName: string; ASetIndex, AChunkIndex: Integer);
var Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'UPDATE ' + PROGRESS_TABLE +
      '   SET CompletedAt = GETDATE(), UpdatedAt = GETDATE() ' +
      ' WHERE SectionName = :sn AND SetIndex = :si AND ChunkIndex = :ci';
    Q.ParamByName('sn').AsString  := ASectionName;
    Q.ParamByName('si').AsInteger := ASetIndex;
    Q.ParamByName('ci').AsInteger := AChunkIndex;
    Q.ExecSQL;
  finally Q.Free; end;
end;

procedure TPQProgressDB.Delete(const ASectionName: string; ASetIndex, AChunkIndex: Integer);
var Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'DELETE FROM ' + PROGRESS_TABLE +
      ' WHERE SectionName = :sn AND SetIndex = :si AND ChunkIndex = :ci';
    Q.ParamByName('sn').AsString  := ASectionName;
    Q.ParamByName('si').AsInteger := ASetIndex;
    Q.ParamByName('ci').AsInteger := AChunkIndex;
    Q.ExecSQL;
  finally Q.Free; end;
end;

procedure TPQProgressDB.DeleteAllChunks(const ASectionName: string; ASetIndex: Integer);
var Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'DELETE FROM ' + PROGRESS_TABLE +
      ' WHERE SectionName = :sn AND SetIndex = :si';
    Q.ParamByName('sn').AsString  := ASectionName;
    Q.ParamByName('si').AsInteger := ASetIndex;
    Q.ExecSQL;
  finally Q.Free; end;
end;

function TPQProgressDB.HasChunks(const ASectionName: string; ASetIndex: Integer): Boolean;
var Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'SELECT TOP 1 1 FROM ' + PROGRESS_TABLE +
      ' WHERE SectionName = :sn AND SetIndex = :si AND ChunkIndex > 0 AND RidTo IS NOT NULL';
    Q.ParamByName('sn').AsString  := ASectionName;
    Q.ParamByName('si').AsInteger := ASetIndex;
    Q.Open;
    Result := not Q.IsEmpty;
  finally Q.Free; end;
end;

function TPQProgressDB.GetChunkCount(const ASectionName: string; ASetIndex: Integer): Integer;
var Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'SELECT COUNT(*) FROM ' + PROGRESS_TABLE +
      ' WHERE SectionName = :sn AND SetIndex = :si AND ChunkIndex > 0 AND RidTo IS NOT NULL';
    Q.ParamByName('sn').AsString  := ASectionName;
    Q.ParamByName('si').AsInteger := ASetIndex;
    Q.Open;
    Result := Q.Fields[0].AsInteger;
  finally Q.Free; end;
end;

end.
