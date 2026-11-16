unit uPumpConnection;

interface

uses
  System.SysUtils, FireDAC.Comp.Client, FireDAC.Phys.Oracle, FireDAC.Phys.MSSQL, FireDAC.Stan.Def, FireDAC.Stan.Intf,
  FireDAC.Stan.Async, MSA.Logger, uPumpTypes;

type
  TPumpConnections = class
  private
    FSource: TFDConnection;
    FTarget: TFDConnection;
    procedure InitOracleSession;
  public
    constructor Create(const Settings: TPumpSettings);
    destructor Destroy; override;
    procedure Open;
    procedure Close;
    property Source: TFDConnection read FSource;
    property Target: TFDConnection read FTarget;
  end;

implementation

uses
  uConst;

constructor TPumpConnections.Create(const Settings: TPumpSettings);
begin
  inherited Create;

  FSource := TFDConnection.Create(nil);
  FSource.LoginPrompt := False;
  FSource.Params.Clear;
  FSource.Params.Add('DriverID=Ora');
  FSource.Params.Add('Database=' + Settings.Source.Host + ':' +
    IntToStr(Settings.Source.Port) + '/' +
    Settings.Source.Database);
  FSource.Params.Add('User_Name=' + Settings.Source.User);
  FSource.Params.Add('Password=' + Settings.Source.Pass);

  FTarget := TFDConnection.Create(nil);
  FTarget.LoginPrompt := False;
  FTarget.Params.Clear;
  FTarget.Params.Add('DriverID=MSSQL');
  FTarget.Params.Add('Server=' + Settings.Target.Host + ',' +
    IntToStr(Settings.Target.Port));
  FTarget.Params.Add('Database=' + Settings.Target.Database);
  FTarget.Params.Add('User_Name=' + Settings.Target.User);
  FTarget.Params.Add('Password=' + Settings.Target.Pass);
  FTarget.Params.Add('OSAuthent=No');
  FTarget.Params.Add('ODBCAdvanced=TrustServerCertificate=yes');
  FTarget.Params.Add('ApplicationName=' + ServiceDescr);
end;

destructor TPumpConnections.Destroy;
begin
  Close;
  FSource.Free;
  FTarget.Free;
  inherited;
end;

procedure TPumpConnections.InitOracleSession;
begin
  try
    FSource.ExecSQL('begin tiger.admission_for_ues_users.init_user_context; end;');
  except
    on E: Exception do
      GLog('Oracle: ошибка init_user_context: ' + E.Message, llError);
  end;
end;

procedure TPumpConnections.Open;
begin

  FSource.Connected := True;

  InitOracleSession;

  FTarget.Connected := True;
end;

procedure TPumpConnections.Close;
begin
  if Assigned(FSource) and FSource.Connected then
    FSource.Connected := False;
  if Assigned(FTarget) and FTarget.Connected then
    FTarget.Connected := False;
end;

end.

