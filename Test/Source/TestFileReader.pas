unit TestFileReader;

interface

uses
  Classes, Types,
  TestFramework,
  FileTestFramework,
  debug.info,
  debug.info.reader;

type
  TCustomMapTest = class(TFileTestCase)
  strict private
    FDebugInfo: TDebugInfo;
  private
  protected
    procedure DoLoadFromFile;
    procedure ProcessDebugInfo(DebugInfo: TDebugInfo); virtual;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  end;

  TTestFileReader = class(TCustomMapTest)
  published
    procedure TestLoadFromFile;
  end;

  TTestFileReaderErrors = class(TTestFileReader)
  protected
    procedure RunTest(TestResult: TTestResult); override;
  end;

type
  TFolderTestSuiteSkipErrors = class(TFolderTestSuite)
  protected
    procedure ProcessFolder(Suite: ITestSuite; TestClass: TFileTestCaseClass; const NameOfMethod, Path, FileMask: string; Recursive: Boolean); override;
  end;

type
  TFolderTestSuiteOnlyErrors = class(TFolderTestSuite)
  protected
    procedure ProcessFolder(Suite: ITestSuite; TestClass: TFileTestCaseClass; const NameOfMethod, Path, FileMask: string; Recursive: Boolean); override;
  end;

type
  TTestFileReaderWriter = class(TCustomMapTest)
  private
    class constructor Create;
  private class var
    FDumper: string;
    FHasDumper: boolean;
  protected
    procedure ProcessDebugInfo(DebugInfo: TDebugInfo); override;
  public
    constructor Create(const AMethodName, ATestFileName: string); override;
  published
    procedure TestCVDUMP;
  end;

implementation

uses
  Windows,
  SysUtils,
  IOUtils,
  System.Character,
  debug.info.reader.map,
  debug.info.reader.test,
  debug.info.reader.jdbg,
  debug.info.writer.pdb;

type
  TInputFormat = (ifMap, ifJdbg, ifTest);
const
  sInputFileTypes: array[TInputFormat] of string = ('.map', '.jdbg', '.test');
  ReaderClasses: array[TInputFormat] of TDebugInfoReaderClass = (TDebugInfoMapReader, TDebugInfoJdbgReader, TDebugInfoSyntheticReader);

function TryStrToInputFormat(const AName: string; var InputFormat: TInputFormat): boolean;
begin
  for var InFormat := Low(TInputFormat) to High(TInputFormat) do
    if (SameText(AName, sInputFileTypes[InFormat])) then
    begin
      InputFormat := InFormat;
      Exit(True);
    end;
  Result := False;
end;

procedure TCustomMapTest.SetUp;
begin
  FDebugInfo := TDebugInfo.Create;
end;

procedure TCustomMapTest.TearDown;
begin
  FDebugInfo.Free;
  FDebugInfo := nil;
end;

procedure TCustomMapTest.DoLoadFromFile;
begin
  (*
  ** Determine source file format
  *)
  var InputFormat: TInputFormat;
  var FileType := TPath.GetExtension(TestFileName);
  if (not TryStrToInputFormat(FileType, InputFormat)) then
  begin
    Check(True);
    Status('Unknown file format');
    exit;
  end;

  (*
  ** Read source file
  *)
  var ReaderClass: TDebugInfoReaderClass := ReaderClasses[InputFormat];

  var Reader := ReaderClass.Create;
  try

    Reader.LoadFromFile(TestFileName, FDebugInfo);

  finally
    Reader.Free;
  end;

  ProcessDebugInfo(FDebugInfo);
end;

procedure TCustomMapTest.ProcessDebugInfo(DebugInfo: TDebugInfo);
begin
  Check(DebugInfo.Segments.Count > 0, 'No segments');
  Check(DebugInfo.Modules.Count > 0, 'No modules');
  if (DebugInfo.SourceFiles.Count = 0) then
    Self.Status('No source files');
end;

procedure TTestFileReader.TestLoadFromFile;
begin
  DoLoadFromFile;
end;


constructor TTestFileReaderWriter.Create(const AMethodName, ATestFileName: string);
begin
  inherited;

end;

class constructor TTestFileReaderWriter.Create;
begin
  var RelativePath := 'Tools\cvdump.exe';
  FDumper := TPath.GetFullPath(RelativePath);

  while (not TFile.Exists(FDumper)) do
  begin
    var LastAbsolutePath := FDumper;
    RelativePath := TPath.Combine('..', RelativePath);
    FDumper := TPath.GetFullPath(RelativePath);

    if (FDumper = LastAbsolutePath) then
      break; // We're at the root
  end;

  FHasDumper := TFile.Exists(FDumper);
end;

procedure TTestFileReaderWriter.ProcessDebugInfo(DebugInfo: TDebugInfo);

  function ExecAndWait(const ExePath: string; Params: TArray<string>; WorkDir: string = ''; TimeoutMS: DWORD = INFINITE): DWORD;
  var
    SI: TStartupInfoW;
    PI: TProcessInformation;
    CmdLine: string;
    WaitRes: DWORD;
    ExitCode: DWORD;
  begin
    Result := DWORD($FFFFFFFF);

    CmdLine := '"' + ExePath + '"';
    if Params <> nil then
      for var Param in Params do
        CmdLine := CmdLine + ' ' + Param;

    SI := Default(TStartupInfoW);
    SI.cb := SizeOf(SI);

    PI := Default(TProcessInformation);
    try

      if not CreateProcessW(nil, PChar(CmdLine), nil, nil, False, 0, nil, PChar(WorkDir), SI, PI) then
        raise Exception.CreateFmt('CreateProcess failed, error=%d', [GetLastError]);

      WaitRes := WaitForSingleObject(PI.hProcess, TimeoutMS);
      case WaitRes of

        WAIT_OBJECT_0:
          begin
            if not GetExitCodeProcess(PI.hProcess, ExitCode) then
              raise Exception.CreateFmt('GetExitCodeProcess failed, error=%d', [GetLastError]);
            Result := ExitCode;
          end;

        WAIT_TIMEOUT:
          raise Exception.Create('Process timed out');

      else
        raise Exception.CreateFmt('WaitForSingleObject failed, error=%d', [GetLastError]);

      end;
    finally
      CloseHandle(PI.hThread);
      CloseHandle(PI.hProcess);
    end;
  end;

begin
  inherited;

  var BlockSize: Integer := 0;

  var TargetFilename := TPath.ChangeExtension(TestFileName, '.pdb');
  try

    var Writer := TDebugInfoPdbWriter.Create(BlockSize);
    try

      Writer.SaveToFile(TargetFilename, DebugInfo);

    finally
      Writer.Free;
    end;

    // cvdump.exe -x -headers -m -p <pdb file>
    var Res := ExecAndWait(FDumper, ['-x', '-m', '-p', '"'+TPath.GetFileName(TargetFilename)+'"'], TPath.GetDirectoryName(TargetFilename));
    CheckEquals(0, Res);

  finally
    TFile.Delete(TargetFilename);
  end;

end;

procedure TTestFileReaderWriter.TestCVDUMP;
begin
  if FHasDumper then
    DoLoadFromFile
  else
    Check(True);
end;


{ TFolderTestSuiteSkipErrors }

procedure TFolderTestSuiteSkipErrors.ProcessFolder(Suite: ITestSuite; TestClass: TFileTestCaseClass; const NameOfMethod, Path,
  FileMask: string; Recursive: Boolean);
begin
  if SameText(TPath.GetFileName(Path), 'errors') then
    exit;

  inherited;
end;

{ TFolderTestSuiteOnlyErrors }

procedure TFolderTestSuiteOnlyErrors.ProcessFolder(Suite: ITestSuite; TestClass: TFileTestCaseClass; const NameOfMethod, Path,
  FileMask: string; Recursive: Boolean);
begin
  if SameText(TPath.GetFileName(Path), 'errors') then
  begin
    inherited;
    exit;
  end;

  if Recursive then
    for var Folder in TDirectory.GetDirectories(Path) do
      ProcessFolder(Suite, TestClass, NameOfMethod, Folder, FileMask, true);
end;

{ TTestFileReaderErrors }

procedure TTestFileReaderErrors.RunTest(TestResult: TTestResult);
begin
  try

    inherited;

    Fail('Passed without expected error: '+TPath.GetFileNameWithoutExtension(TestFileName));

  except
    on E: ETestFailure do
      raise; // otherwise the above Fail will be caught by the logic below and validated with Check(True)

    on E: Exception do
    begin
      var Msg := E.Message.ToLower;
      Msg := StringReplace(Msg, '/', '-', [rfReplaceAll]);
      Msg := StringReplace(Msg, '"', '', [rfReplaceAll]);

      // Allow multiple test cases with same error by postfixing the filename with a number
      var ExpectedError := TestFileName;
      while (ExpectedError[Length(ExpectedError)].IsDigit) do
        SetLength(ExpectedError, Length(ExpectedError)-1);

      if (Msg.Contains(TPath.GetFileNameWithoutExtension(ExpectedError).ToLower)) then
        Check(True)
      else
        raise;
    end;
  end;
end;

initialization
  var TestSuite: TTestSuite := TFolderTestSuiteSkipErrors.Create('Load map files', TTestFileReader, '..\..\..\Data', '*.*', True);
  RegisterTest(TestSuite);

  TestSuite := TFolderTestSuiteOnlyErrors.Create('Reader errors', TTestFileReaderErrors, '..\..\..\Data', '*.*', True);
  RegisterTest(TestSuite);

  TestSuite := TFolderTestSuiteSkipErrors.Create('Validate produced PDB files', TTestFileReaderWriter, '..\..\..\Data', '*.*', True);
  RegisterTest(TestSuite);

end.


