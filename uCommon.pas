unit uCommon;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, Winapi.ShlObj, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, System.StrUtils, Vcl.Dialogs, System.TypInfo, System.NetEncoding, System.Zip, System.ZLib,
  System.UITypes, System.Generics.Collections;


var
  StartupDir: string;

const
  MaxSet = 255;
  BitsPerByte = 8;
  ByteBoundaryMask =not  ( BitsPerByte - 1);
  WhiteSpace =[ #0.. ' '];
  Alphabetic =[ 'a'.. 'z',  'A'.. 'Z',  '_'];
  Digits =[ '0'.. '9'];
  HexDigits =[ 'a'.. 'f',  'A'.. 'F'] + Digits;
  CharBegin =[ '#',  ''''];
  AsciiChars =[ ' '.. '~'];
  AlphaNumeric = Alphabetic + Digits;

type
  TDBConnectionParams = record
    DriverName: string;
    Server: string;
    Database: string;
    UserName: string;
    Password: string;
    OSAuth: Boolean;
    Encrypt: Boolean;
  end;

type
  TEnumUtils = class
  private
    class function GetTypeInfo<T>: PTypeInfo; static;
  public
    class function AsString<T>(const Value: T): string; static;
    class function FromString<T>(const Str: string): T; static;
    class function FromStringDef<T>(const Str: string; const Default: T): T; static;

    class function ByIndex<T>(Index: Integer): string; static;
    class function IndexOf<T>(const Value: T): Integer; static;

    class function Count<T>: Integer; static;
    class function MinValue<T>: Integer; static;
    class function MaxValue<T>: Integer; static;
    class function IsValid<T>(Index: Integer): Boolean; static;
    class function IsValidName<T>(const Name: string): Boolean; static;

    class function GetNames<T>: TArray<string>; static;
    class function GetValues<T>: TArray<T>; static;

    class function TryParse<T>(const Str: string; out Value: T): Boolean; static;
    class function RemovePrefix<T>(const Value: T; const Prefix: string): string; static;
  end;

procedure MsgError(const AMsg: string);

procedure MsgWarning(const AMsg: string);

procedure MsgInformation(const AMsg: string);

function MsgConfirmation(const AMsg: string): Boolean;

function MsgConfirmation_YNC(const AMsg: string): Byte;

function MsgConfirmation_YNCAN(const AMsg: string): Integer;

procedure SkipWhiteSpace(const Str: string; var I: Integer);

procedure StringToStream(const AString: string; AStream: TStream);

function StringFromStream(AStream: TStream): string;

function StrToStream(const S: string; Encoding: TEncoding = nil): TStream;

function StreamToStr(Stream: TStream; Encoding: TEncoding = nil): string;

function StreamToBase64String(AStream: TStream): string;

procedure Base64StringToStream(Base64String: string; AStream: TStream);

procedure SaveStreamAsZip(SourceStream: TStream; const ZipFileName: string; const InternalFileName: string = 'data.bin');

function VariantToStrEx(const Value: Variant): string;

function GetSpecialPath(CSIDL: word): string;

procedure CompressStream(SourceStream, CompressedStream: TStream; CompressionLevel: TZCompressionLevel = zcDefault);

procedure DecompressStream(CompressedStream, OutputStream: TStream);

function CountOfWords(const Str: string; Delimiter: Char; CountRepeatedDelims: Boolean): Integer;

function GetWordNum(const Str: string; Delimiter: Char; Index: Integer; CountRepeatedDelims: Boolean): string;

resourcestring
  sNotASet = 'SetToString: argument must be a set type; %s not allowed';
  sCvtError = 'OrdToString: type kind must be ordinal, not %s';
  sInvalidSetString = 'StringToSet: %s not a valid literal for the set type';
  sOutOfRange = 'StringToSet: %0:d is out of range [%1:d..%2:d]';
  sNotAChar = 'StringToSet: Not a valid character (%.10s)';
  sCharOutOfRange = 'StringToSet: Character #%0:d is out of range [#%1:d..#%2:d]';
  sTStringsNotAssigned = 'TStrings not assigned';

implementation


function CountOfWords(const Str: string; Delimiter: Char; CountRepeatedDelims: Boolean): Integer;
var
  I: Integer;
  InWord: Boolean;
begin
  Result := 0;
  InWord := False;

  if Length(Str) = 0 then
    Exit;

  for I := 1 to Length(Str) do
  begin
    if Str[I] = Delimiter then
    begin
      if CountRepeatedDelims then
      begin
        Inc(Result);
        InWord := False;
      end
      else if InWord then
      begin
        Inc(Result);
        InWord := False;
      end;
    end
    else
    begin
      if not InWord then
        InWord := True;
    end;
  end;

  if InWord then
    Inc(Result)
  else if CountRepeatedDelims and (Str[Length(Str)] = Delimiter) then
    Inc(Result);
end;

function GetWordNum(const Str: string; Delimiter: Char; Index: Integer; CountRepeatedDelims: Boolean): string;
var
  StartPos, EndPos, CurrentIndex: Integer;
  Found: Boolean;
begin
  Result := '';

  if Index < 1 then
    Exit;

  StartPos := 1;
  CurrentIndex := 0;
  Found := False;

  while (StartPos <= Length(Str)) and (not Found) do
  begin
    if CountRepeatedDelims then
    begin
      if (Str[StartPos] = Delimiter) then
      begin
        Inc(CurrentIndex);
        if CurrentIndex = Index then
        begin
          Result := '';
          Found := True;
          Break;
        end;
        Inc(StartPos);
        Continue;
      end;
    end
    else
    begin
      while (StartPos <= Length(Str)) and (Str[StartPos] = Delimiter) do
        Inc(StartPos);
    end;
    if StartPos > Length(Str) then
      Break;
    EndPos := StartPos;
    while (EndPos <= Length(Str)) and (Str[EndPos] <> Delimiter) do
      Inc(EndPos);
    Inc(CurrentIndex);
    if CurrentIndex = Index then
    begin
      Result := Copy(Str, StartPos, EndPos - StartPos);
      Found := True;
      Break;
    end;
    StartPos := EndPos + 1;
  end;
end;

procedure DecompressStream(CompressedStream, OutputStream: TStream);
var
  DecompressionStream: TZDecompressionStream;
begin
  CompressedStream.Position := 0;
  OutputStream.Position := 0;

  DecompressionStream := TZDecompressionStream.Create(CompressedStream);
  try
    OutputStream.CopyFrom(DecompressionStream, 0);
  finally
    DecompressionStream.Free;
  end;

  OutputStream.Position := 0;
end;

procedure CompressStream(SourceStream, CompressedStream: TStream; CompressionLevel: TZCompressionLevel = zcDefault);
var
  CompressionStream: TZCompressionStream;
begin
  SourceStream.Position := 0;
  CompressedStream.Position := 0;
  CompressedStream.Size := 0;
  CompressionStream := TZCompressionStream.Create(CompressedStream, CompressionLevel, 15);
  try
    CompressionStream.CopyFrom(SourceStream);
  finally
    CompressionStream.Free;
  end;
  CompressedStream.Position := 0;
end;


function GetSpecialPath(CSIDL: word): string;
var
  S: string;
begin
  SetLength(S, MAX_PATH);
  if SHGetSpecialFolderPath(0, PChar(S), CSIDL, True) then
  begin
    Result := PChar(S);
    Exit;
  end;


  if (CSIDL <> CSIDL_APPDATA) then
  begin
    SetLength(S, MAX_PATH);
    if SHGetSpecialFolderPath(0, PChar(S), CSIDL_APPDATA, True) then
    begin
      Result := PChar(S);
      Exit;
    end;
  end;

  Result := GetEnvironmentVariable('APPDATA');
  if Result = '' then
    Result := GetEnvironmentVariable('LOCALAPPDATA');
  if Result = '' then
    Result := GetEnvironmentVariable('TEMP');
  if Result = '' then
    Result := ExtractFileDir(ParamStr(0));
end;


function VariantToStrEx(const Value: Variant): string;
begin
  case VarType(Value) of
    varEmpty, varNull:
      Result := '';
    varString, varUString, varOleStr:
      Result := string(Value);
    varSmallint, varInteger, varShortInt, varByte, varWord, varLongWord, varInt64:
      Result := IntToStr(Value);
    varSingle, varDouble, varCurrency:
      Result := FloatToStr(Value);
    varBoolean:
      Result := BoolToStr(Value, True);
    varDate:
      Result := DateTimeToStr(Value);
  else
    try
      Result := VarToStr(Value);
    except
      Result := '';
    end;
  end;
end;

procedure SaveStreamAsZip(SourceStream: TStream; const ZipFileName: string; const InternalFileName: string = 'data.bin');
var
  ZipFile: TZipFile;
begin
  ZipFile := TZipFile.Create;
  try
    ZipFile.Open(ZipFileName, zmWrite);
    SourceStream.Position := 0;
    ZipFile.Add(SourceStream, InternalFileName, TZipCompression.zcDeflate);

    ZipFile.Close;
  finally
    ZipFile.Free;
  end;
end;

procedure StringToStream(const AString: string; AStream: TStream);
var
  Writer: TStreamWriter;
begin
  AStream.Position := 0;
  Writer := TStreamWriter.Create(AStream);
  try
    Writer.Write(AString);
  finally
    Writer.Free;
  end;
  AStream.Position := 0;
end;

function StringFromStream(AStream: TStream): string;
var
  Reader: TStreamReader;
begin
  AStream.Position := 0;
  Reader := TStreamReader.Create(AStream);
  try
    Result := Reader.ReadToEnd;
  finally
    Reader.Free;
  end;
end;

function StrToStream(const S: string; Encoding: TEncoding = nil): TStream;
begin
  if Encoding = nil then
    Encoding := TEncoding.UTF8;

  Result := TStringStream.Create(S, Encoding);
end;

function StreamToStr(Stream: TStream; Encoding: TEncoding = nil): string;
var
  StringStream: TStringStream;
begin
  if Encoding = nil then
    Encoding := TEncoding.UTF8;

  Stream.Position := 0;
  StringStream := TStringStream.Create('', Encoding);
  try
    StringStream.CopyFrom(Stream, Stream.Size);
    Result := StringStream.DataString;
  finally
    StringStream.Free;
  end;
end;

function StreamToBase64String(AStream: TStream): string;
var
  Bytes: TBytes;
begin
  Result := '';
  if not Assigned(AStream) then
    Exit;
  if AStream.Size = 0 then
    Exit;

  AStream.Position := 0;
  SetLength(Bytes, AStream.Size);
  AStream.ReadBuffer(Bytes, AStream.Size);

  Result := TNetEncoding.Base64.EncodeBytesToString(Bytes);
end;

procedure Base64StringToStream(Base64String: string; AStream: TStream);
var
  Bytes: TBytes;
begin
  if Base64String = '' then
    Exit;
  Bytes := TNetEncoding.Base64.DecodeStringToBytes(Base64String);
  AStream.WriteBuffer(Bytes[0], Length(Bytes));
  AStream.Position := 0;
end;

procedure SkipWhiteSpace(const Str: string; var I: Integer);
begin
  while (I <= Length(Str)) and CharInSet(Str[I], WhiteSpace) do
    Inc(I);
end;

procedure MsgError(const AMsg: string);
begin
  Application.MessageBox(PChar(AMsg), 'Ошибка', MB_OK + MB_ICONERROR);
end;

procedure MsgWarning(const AMsg: string);
begin
  Application.MessageBox(PChar(AMsg), 'Предупреждение', MB_OK + MB_ICONWARNING);
end;

procedure MsgInformation(const AMsg: string);
begin
  Application.MessageBox(PChar(AMsg), 'Информация', MB_OK + MB_ICONINFORMATION);
end;

function MsgConfirmation(const AMsg: string): Boolean;
begin
  result := False;
  if Application.MessageBox(PChar(AMsg), 'Подтвердите', MB_YESNO + MB_ICONQUESTION) = ID_YES then
    result := True;
end;

function MsgConfirmation_YNC(const AMsg: string): Byte;
begin
  // 0=ID_CANCEL
  // 1=ID_YES
  // 2=ID_NO
  case Application.MessageBox(PChar(AMsg), 'Подтвердите', MB_YESNOCANCEL + MB_ICONQUESTION) of
    ID_CANCEL:
      result := 0;
    ID_YES:
      result := 1;
    ID_NO:
      result := 2;
  else
    result := 0;
  end;
end;

function MsgConfirmation_YNCAN(const AMsg: string): Integer;
begin
  Result := MessageDlg(PChar(AMsg), mtConfirmation, [mbYes, mbYesToAll, mbNo, mbNoToAll, mbCancel, mbNoToAll], 0)
end;

{ TEnumUtils }

class function TEnumUtils.GetTypeInfo<T>: PTypeInfo;
begin
  Result := System.TypeInfo(T);
  if Result.Kind <> tkEnumeration then
    raise Exception.Create('Тип T должен быть перечислением');
end;

class function TEnumUtils.AsString<T>(const Value: T): string;
begin
  Result := GetEnumName(GetTypeInfo<T>, PByte(@Value)^);
end;

class function TEnumUtils.FromString<T>(const Str: string): T;
var
  Value: Integer;
begin
  Value := GetEnumValue(GetTypeInfo<T>, Str);
  if Value = -1 then
    raise Exception.CreateFmt('Неверное значение перечисления: %s', [Str]);
  PByte(@Result)^ := Value;
end;

class function TEnumUtils.FromStringDef<T>(const Str: string; const Default: T): T;
begin
  if not TryParse<T>(Str, Result) then
    Result := Default;
end;

class function TEnumUtils.ByIndex<T>(Index: Integer): string;
var
  TypeData: PTypeData;
begin
  TypeData := GetTypeData(GetTypeInfo<T>);
  if (Index < TypeData.MinValue) or (Index > TypeData.MaxValue) then
    raise Exception.CreateFmt('Индекс %d вне диапазона перечисления', [Index]);
  Result := GetEnumName(GetTypeInfo<T>, Index);
end;

class function TEnumUtils.IndexOf<T>(const Value: T): Integer;
begin
  Result := PByte(@Value)^;
end;

class function TEnumUtils.Count<T>: Integer;
var
  TypeData: PTypeData;
begin
  TypeData := GetTypeData(GetTypeInfo<T>);
  Result := TypeData.MaxValue - TypeData.MinValue + 1;
end;

class function TEnumUtils.MinValue<T>: Integer;
begin
  Result := GetTypeData(GetTypeInfo<T>).MinValue;
end;

class function TEnumUtils.MaxValue<T>: Integer;
begin
  Result := GetTypeData(GetTypeInfo<T>).MaxValue;
end;

class function TEnumUtils.IsValid<T>(Index: Integer): Boolean;
begin
  Result := (Index >= MinValue<T>) and (Index <= MaxValue<T>);
end;

class function TEnumUtils.IsValidName<T>(const Name: string): Boolean;
begin
  Result := GetEnumValue(GetTypeInfo<T>, Name) <> -1;
end;

class function TEnumUtils.GetNames<T>: TArray<string>;
var
  TypeData: PTypeData;
  i, Count: Integer;
begin
  TypeData := GetTypeData(GetTypeInfo<T>);
  Count := TypeData.MaxValue - TypeData.MinValue + 1;
  SetLength(Result, Count);

  for i := 0 to Count - 1 do
    Result[i] := GetEnumName(GetTypeInfo<T>, TypeData.MinValue + i);
end;

class function TEnumUtils.GetValues<T>: TArray<T>;
var
  TypeData: PTypeData;
  i, Count: Integer;
  Value: T;
begin
  TypeData := GetTypeData(GetTypeInfo<T>);
  Count := TypeData.MaxValue - TypeData.MinValue + 1;
  SetLength(Result, Count);

  for i := 0 to Count - 1 do
  begin
    PByte(@Value)^ := TypeData.MinValue + i;
    Result[i] := Value;
  end;
end;

class function TEnumUtils.TryParse<T>(const Str: string; out Value: T): Boolean;
var
  EnumValue: Integer;
begin
  EnumValue := GetEnumValue(GetTypeInfo<T>, Str);
  Result := EnumValue <> -1;
  if Result then
    PByte(@Value)^ := EnumValue;
end;

class function TEnumUtils.RemovePrefix<T>(const Value: T; const Prefix: string): string;
begin
  Result := AsString<T>(Value);
  if Result.StartsWith(Prefix) then
    Delete(Result, 1, Length(Prefix));
end;

initialization
  ReportMemoryLeaksOnShutdown := True;
  StartupDir := Copy(ParamStr(0), 1, LastDelimiter(PathDelim, ParamStr(0)));
end.

