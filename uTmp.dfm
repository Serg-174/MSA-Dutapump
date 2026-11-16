object fTmp: TfTmp
  Left = 0
  Top = 0
  Caption = 'fTmp'
  ClientHeight = 719
  ClientWidth = 1183
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  Position = poDesktopCenter
  OnClose = FormClose
  OnDestroy = FormDestroy
  TextHeight = 13
  object Memo1: TMemo
    Left = 0
    Top = 209
    Width = 1183
    Height = 510
    Align = alClient
    Font.Charset = RUSSIAN_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ScrollBars = ssBoth
    TabOrder = 0
    WordWrap = False
  end
  object Panel1: TPanel
    Left = 0
    Top = 0
    Width = 1183
    Height = 209
    Align = alTop
    Caption = 'Panel1'
    TabOrder = 1
    DesignSize = (
      1183
      209)
    object Label1: TLabel
      Left = 224
      Top = 0
      Width = 31
      Height = 13
      Caption = 'Label1'
    end
    object CheckBox1: TCheckBox
      Left = 4
      Top = 10
      Width = 53
      Height = 17
      Caption = #1042#1099#1082#1083
      TabOrder = 0
    end
    object Button1: TButton
      Left = 1007
      Top = 2
      Width = 75
      Height = 25
      Anchors = [akTop, akRight]
      Caption = #1057#1090#1072#1088#1090
      TabOrder = 1
      OnClick = Button1Click
    end
    object Button2: TButton
      Left = 1088
      Top = 2
      Width = 75
      Height = 25
      Anchors = [akTop, akRight]
      Caption = #1057#1090#1086#1087
      TabOrder = 2
      OnClick = Button2Click
    end
    object Button3: TButton
      Left = 0
      Top = 64
      Width = 137
      Height = 25
      Caption = 'GetVPDTablesAsString'
      TabOrder = 3
      OnClick = Button3Click
    end
    object Button4: TButton
      Left = 104
      Top = 144
      Width = 161
      Height = 25
      Caption = 'ReloadConfig'
      TabOrder = 4
      OnClick = Button4Click
    end
    object Button5: TButton
      Left = 368
      Top = 144
      Width = 129
      Height = 25
      Caption = 'LogQueries'
      TabOrder = 5
      OnClick = Button5Click
    end
    object Button6: TButton
      Left = 600
      Top = 144
      Width = 129
      Height = 25
      Caption = 'ShowStatistics'
      TabOrder = 6
      OnClick = Button6Click
    end
  end
end
