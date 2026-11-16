unit msaClassHelpers;

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Winapi.ShlObj, FireDAC.Comp.Client, FireDAC.Stan.Def, FireDAC.DApt,
  System.IOUtils, FireDAC.Stan.Param, Data.DB, System.Generics.Collections, DataSetEnumerator, System.Variants,
  System.DateUtils, FireDAC.UI.Intf, FireDAC.VCLUI.Wait, FireDAC.Stan.Intf, FireDAC.Comp.UI, FireDAC.Stan.Async;

type
  TFDRdbmsDataSetHelper = class helper for TFDRdbmsDataSet
  public
    procedure CloseOpen;
    function FBN(const FieldName: string): TField;
    function PBN(const ParamName: string): TFDParam;
    procedure PVal(const ParamName: string; AVal: variant);
    procedure PInt(const ParamName: string; AVal: Integer);
    procedure PStr(const ParamName: string; AVal: string);
    function FVal(const FieldName: string): variant;
    function FStr(const FieldName: string): string;
    function FInt(const FieldName: string): Integer;
    function FBool(const FieldName: string): boolean;
    function FullName: string;
    function IsClodedOrEmpty(DoOpen: boolean = false): boolean;
    procedure PrepareIfNot;
  end;

implementation

{ TFDRdbmsDataSet }

procedure TFDRdbmsDataSetHelper.CloseOpen;
begin
  Close;
  Open;
end;

function TFDRdbmsDataSetHelper.FBN(const FieldName: string): TField;
begin
  Result := FieldByName(FieldName);
end;

function TFDRdbmsDataSetHelper.FBool(const FieldName: string): boolean;
begin
  Result := FieldByName(FieldName).AsBoolean;
end;

function TFDRdbmsDataSetHelper.FInt(const FieldName: string): Integer;
begin
  Result := FieldByName(FieldName).AsInteger;
end;

function TFDRdbmsDataSetHelper.FStr(const FieldName: string): string;
begin
  Result := FieldByName(FieldName).AsString;
end;

function TFDRdbmsDataSetHelper.FullName: string;
var
  OwnerName: string;
begin
  if Owner <> nil then
    OwnerName := Owner.Name
  else
    OwnerName := '<NoOwner>';

  if Self is TFDQuery then
    Result := OwnerName + '.' + name;
  if Self is TFDStoredProc then
    Result := OwnerName + '.' + name + '(' + TFDStoredProc(Self).StoredProcName + ')';
end;

function TFDRdbmsDataSetHelper.FVal(const FieldName: string): variant;
begin
  Result := FieldByName(FieldName).Value;
end;

function TFDRdbmsDataSetHelper.IsClodedOrEmpty(DoOpen: boolean): boolean;
begin
  Result := (not Active) or IsEmpty;
  if Result then
    Open;
end;

function TFDRdbmsDataSetHelper.PBN(const ParamName: string): TFDParam;
begin
  Result := ParamByName(ParamName);
end;

procedure TFDRdbmsDataSetHelper.PInt(const ParamName: string; AVal: Integer);
begin
  ParamByName(ParamName).AsInteger := AVal;
end;

procedure TFDRdbmsDataSetHelper.PrepareIfNot;
begin
  if (not Prepared) then
    Prepare;
end;

procedure TFDRdbmsDataSetHelper.PStr(const ParamName: string; AVal: string);
begin
  ParamByName(ParamName).AsString := AVal;
end;

procedure TFDRdbmsDataSetHelper.PVal(const ParamName: string; AVal: variant);
begin
  ParamByName(ParamName).Value := AVal;
end;

end.

