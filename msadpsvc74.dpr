program msadpsvc74;

{$I MyService.inc}

uses
{$IFDEF GUI_APP}
  Vcl.Forms,
  uTmp in 'uTmp.pas' {fTmp} ,
{$ENDIF }
{$IFDEF SVC_APP}
  Vcl.SvcMgr,
{$ENDIF }
  uMain in 'uMain.pas' {msadpsvc: TService},
  uConst in 'uConst.pas',
  uCommon in 'uCommon.pas',
  uFunctions in 'uFunctions.pas',
  SQLiteUserDatabase in 'SQLiteUserDatabase.pas',
  DataSetEnumerator in 'DataSetEnumerator.pas',
  MSA.Logger in 'MSA.Logger.pas',
  msaClassHelpers in 'msaClassHelpers.pas',
  uPumpTypes in 'uPumpTypes.pas',
  uPumpConnection in 'uPumpConnection.pas',
  uConfigWatcher in 'uConfigWatcher.pas',
  uPumpWorker in 'uPumpWorker.pas',
  uPumpWorkerAppend in 'uPumpWorkerAppend.pas',
  uPumpWorkerGapFill in 'uPumpWorkerGapFill.pas',
  uPumpInsert in 'uPumpInsert.pas',
  uPumpStatDB in 'uPumpStatDB.pas',
  uPumpManager in 'uPumpManager.pas',
  uPumpWorkerSpecial in 'uPumpWorkerSpecial.pas',
  uPumpWorkerUpdate in 'uPumpWorkerUpdate.pas',
  uPumpWorkerPQ in 'uPumpWorkerPQ.pas',
  uPumpPQProgress in 'uPumpPQProgress.pas';


{$R *.RES}

begin
{$IFDEF SVC_APP}
  if ((not Application.DelayInitialize) or Application.Installing) then
{$ENDIF}
    Application.Initialize;
  Application.CreateForm(Tmsadpsvc, msadpsvc);
{$IFDEF GUI_APP}
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfTmp, fTmp);
{$ENDIF}
  Application.Run;
end.


