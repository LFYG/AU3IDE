unit au3Compiler;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Project, DOM, XMLRead, XMLWrite, AsyncProcess, process, strutils,
  Dialogs, LazFileUtils;

type
  TCompileArch = (cax86, ca64);
  TOutputEvent = procedure(Sender: TObject; FileName: string; Output: string) of object;
  TErrorEvent = procedure(Sender: TObject; FileName: string; Line: Integer; Column: Integer; Message: String) of object;

  Tau3Compiler = class
  private
    FCurrentProject: Tau3Project;
    FArch: TCompileArch;
    FOutput: TStringList;
    FPath: string;
    FSaveIntData: boolean;
    FCProcess: TAsyncProcess;
    FIsCompiling: boolean;
    FSTDOptions: TProcessOptions;
    FOnOutput: TOutputEvent;
    FOnFinishedRun: TNotifyEvent;
    FOnFinishedCompiling: TNotifyEvent;
    FOnRunTimeError: TErrorEvent;
    function isRunning: boolean;
    procedure ReadData(Sender: TObject);
    procedure ProcTerm(Sender: TObject);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Stop;
    procedure Run(P: Tau3Project; Arch: TCompileArch);
    procedure ReadConf(Path: string);
    procedure WriteConf(Path: string);
    procedure Compile(P: Tau3Project; Arch: TCompileArch);

    property Active: boolean read isRunning;
    property Path: string read FPath write FPath;
    property SaveIntData: boolean read FSaveIntData write FSaveIntData;
    property OnOutput: TOutputEvent read FOnOutput write FOnOutput;
    property OnFinishedRunning: TNotifyEvent read FOnFinishedRun write FOnFinishedRun;
    property OnFinishedCompiling: TNotifyEvent
      read FOnFinishedCompiling write FOnFinishedCompiling;
    property OnRunTimeError: TErrorEvent read FOnRunTimeError write FOnRunTimeError;
  end;

implementation

procedure Tau3Compiler.ReadConf(Path: string);
var
  doc: TXMLDocument;
  tmpNode: TDOMNode;
begin
  try
    ReadXMLFile(doc, Path);
    tmpNode := doc.DocumentElement.FindNode('Path');
    FPath := tmpNode.TextContent;
    tmpNode := doc.DocumentElement.FindNode('SaveOutput');
    FSaveIntData:=tmpNode.TextContent='True';
    FSaveIntData := tmpNode.TextContent = 'True';
  finally
    doc.Free;
  end;
end;

procedure Tau3Compiler.WriteConf(Path: string);
var
  doc: TXMLDocument;
  tmpNode, rootnode: TDOMNode;
begin
  doc := TXMLDocument.Create;
  try
    rootnode := doc.CreateElement('CompilerConfig');
    doc.AppendChild(rootnode);
    tmpNode := doc.CreateElement('Path');
    rootnode.AppendChild(tmpNode);
    // Write Path
    tmpNode.AppendChild(doc.CreateTextNode(FPath));

    tmpNode := doc.CreateElement('SaveOutput');
    rootnode.AppendChild(tmpNode);
    // Write SaveData
    tmpNode.AppendChild(doc.CreateTextNode(IfThen(FSaveIntData, 'True', 'False')));

    WriteXML(doc, Path);
  finally
    doc.Free;
  end;
end;

procedure Tau3Compiler.Compile(P: Tau3Project; Arch: TCompileArch);
var v: TVersion;
  i: Integer;
begin
  Stop;
  FArch := Arch;
  FCurrentProject := P;
  FOutput.Clear;
  FIsCompiling := True;
  FCProcess.OnTerminate := @ProcTerm;
  FCProcess.Options := FSTDOptions + [poUsePipes, poStderrToOutPut];

  FCProcess.Executable := IncludeTrailingPathDelimiter(FPath) + 'Aut2Exe' +
    PathDelim + 'Aut2exe.exe';

  FCProcess.Parameters.Clear;
  FCProcess.Parameters.Add('/in');
  FCProcess.Parameters.Add(P.MainFile);
  if Length(FCurrentProject.CompilerOptions.OutPath)>0 then
  begin
  FCProcess.Parameters.Add('/out');
  FCProcess.Parameters.Add(CreateAbsoluteSearchPath(
    FCurrentProject.CompilerOptions.OutPath, FCurrentProject.ProjectDir));
  end;
  if Length(FCurrentProject.CompilerOptions.IconPath) > 0 then
  begin
    FCProcess.Parameters.Add('/icon');
    FCProcess.Parameters.Add(FCurrentProject.CompilerOptions.IconPath);
  end;
  FCProcess.Parameters.Add('/comp');
  FCProcess.Parameters.Add(IntToStr(Ord(FCurrentProject.CompilerOptions.Compression)));
  if FCurrentProject.CompilerOptions.PackUPX then
    FCProcess.Parameters.Add('/pack');
  if FCurrentProject.AppType<>atConsole then
    FCProcess.Parameters.Add('/gui')
  else
    FCProcess.Parameters.Add('/console');
  if Arch = cax86 then
    FCProcess.Parameters.Add('/x86')
  else
    FCProcess.Parameters.Add('/x64');

  if FCurrentProject.Version.IncreaseBuilt and FCurrentProject.Version.UseVersion then
  begin
    v:=FCurrentProject.Version;
    v.Built:=v.Built+1;
    FCurrentProject.Version:=v;
    FCurrentProject.VersionData.Values['FileVersion']:=
      Format('%d.%d.%d.%d', [v.Version, v.Subversion, v.Revision, v.Built]);
  end;

  for i:=0 to FCurrentProject.VersionData.Count-1 do
    if FCurrentProject.VersionData.ValueFromIndex[i]<>'' then
    begin
      FCProcess.Parameters.Add('/'+LowerCase(FCurrentProject.VersionData.Names[i]));
      FCProcess.Parameters.Add(Format('"%s"', [FCurrentProject.VersionData.ValueFromIndex[i]]));
    end;

  ForceDirectory(ExtractFilePath(CreateAbsoluteSearchPath(
    FCurrentProject.CompilerOptions.OutPath, FCurrentProject.ProjectDir)));

  FCProcess.Execute;
end;

function Tau3Compiler.isRunning: boolean;
begin
  Result := FCProcess.Running;
end;

procedure Tau3Compiler.ReadData(Sender: TObject);
function ExtractBetween(const Value, A, B: string): string;
var
  aPos, bPos: integer;
begin
  Result := '';
  aPos := Pos(A, Value);
  if aPos > 0 then
  begin
    aPos := aPos + Length(A);
    bPos := PosEx(B, Value, aPos);
    if bPos > 0 then
    begin
      Result := Copy(Value, aPos, bPos - aPos);
    end;
  end;
end;
var
  sl: TStringList;
  i, errline, errp, s, l, delPos: integer;
  errFile, ErrMsg, ln: String;
begin
  sl := TStringList.Create;
  try
    sl.LoadFromStream(FCProcess.Output);
    if sl.Count=0 then exit;
    ln:=sl[0];
    delPos := Pos(') : ==>', ln);
    if (delPos>0) and Assigned(FOnRunTimeError) then
    begin
      l:=0;
      for i:=delPos-1 downto 1 do
        if ln[i] in ['0'..'9'] then inc(l)
        else
        begin
          s:=i+1;
          break;
        end;
      errline:=StrToInt(Copy(ln, s, l));
      errFile:=ExtractBetween(ln, '"', '"');
      ErrMsg:=Copy(ln, delPos+7, Length(ln))+' ';
      for i:=1 to sl.Count-3 do ErrMsg:= ErrMsg + sl[i] + ' ';
      if sl.Count>1 then
      begin
        errp:=Pos('^ ERROR', sl[sl.Count-1]);
        if errp > 0 then
        begin
          ln:=sl[sl.Count-2];
          l:=0;
          for i:=errp to Length(ln) do
            if ln[i] in ['_', 'A'..'Z', 'a'..'z', '0'..'9'] then
              inc(l)
            else break;
          ErrMsg:= ErrMsg+Copy(ln, errp, l);
        end
        else
        begin
          if sl.Count>2 then
          ErrMsg:=ErrMsg+sl[sl.Count-2]+' ';
          ErrMsg:=ErrMsg+sl[sl.Count-1];
        end;
      end;
      FOnRunTimeError(self, errFile, errline, errp, ErrMsg);
      exit;
    end;
    for i := 0 to sl.Count - 1 do
      if Assigned(FOnOutput) then
        FOnOutput(Self, FCurrentProject.MainFile, sl[i]);
  finally
    sl.Free;
  end;
end;

procedure Tau3Compiler.ProcTerm(Sender: TObject);
begin
  ReadData(nil);
  if not FIsCompiling and FSaveIntData then
    FOutput.SaveToFile(IncludeTrailingPathDelimiter(
      FCurrentProject.ProjectDir) + 'Run.log');
  if FIsCompiling and Assigned(FOnFinishedCompiling) then
    FOnFinishedCompiling(Self)
  else if not FIsCompiling and Assigned(FOnFinishedRun) then
    FOnFinishedRun(Self);
end;

constructor Tau3Compiler.Create;
begin
  FCProcess := TAsyncProcess.Create(nil);
  FOutput := TStringList.Create;
  FCProcess.OnReadData := @ReadData;
  FSTDOptions := FCProcess.Options;
end;

destructor Tau3Compiler.Destroy;
begin
  FCProcess.Free;
  FOutput.Free;
  inherited;
end;

procedure Tau3Compiler.Stop;
begin
  if FCProcess.Running then
    FCProcess.Terminate(-1);
end;

procedure Tau3Compiler.Run(P: Tau3Project; Arch: TCompileArch);
begin
  Stop;
  FArch := Arch;
  FCurrentProject := P;
  FOutput.Clear;
  FIsCompiling := False;
  FCProcess.OnTerminate := @ProcTerm;
  FCProcess.Options := FSTDOptions + [poUsePipes, poStderrToOutPut];

  if Arch = cax86 then
  FCProcess.Executable := IncludeTrailingPathDelimiter(FPath) + 'AutoIt3.exe'
  else
  FCProcess.Executable := IncludeTrailingPathDelimiter(FPath) + 'AutoIt3_x64.exe';

  FCProcess.Parameters.Clear;
  FCProcess.Parameters.Add('/ErrorStdOut');
  FCProcess.Parameters.Add(P.MainFile);
  FCProcess.Parameters.AddStrings(FCurrentProject.RunParams);

  FCProcess.Execute;
end;

end.
