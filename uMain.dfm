object msadpsvc: Tmsadpsvc
  OnCreate = ServiceCreate
  AllowPause = False
  DisplayName = 'MSA DataPump'
  AfterInstall = ServiceAfterInstall
  OnStart = ServiceStart
  OnStop = ServiceStop
  Height = 356
  Width = 655
end
