program map2pdb;

(*
 * Copyright (c) 2021 Anders Melander
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *)

{$APPTYPE CONSOLE}
{$WARN SYMBOL_PLATFORM OFF}
{$WEAKLINKRTTI ON}

{$R *.res}

uses
  {$ifdef MADEXCEPT}
  madExcept,
  {$endif MADEXCEPT}
  System.SysUtils,
  System.IOUtils,
  System.Diagnostics,
  System.Generics.Collections,
  System.StrUtils,
  amVersionInfo,
  debug.info in 'debug.info.pas',
  debug.info.writer in 'debug.info.writer.pas',
  debug.info.writer.pdb in 'debug.info.writer.pdb.pas',
  debug.info.writer.yaml in 'debug.info.writer.yaml.pas',
  debug.info.reader in 'debug.info.reader.pas',
  debug.info.reader.map in 'debug.info.reader.map.pas',
  debug.info.reader.test in 'debug.info.reader.test.pas',
  debug.info.reader.jdbg in 'debug.info.reader.jdbg.pas',
  debug.info.codeview in 'debug.info.codeview.pas',
  debug.info.msf in 'debug.info.msf.pas',
  debug.info.pdb in 'debug.info.pdb.pas',
  debug.info.pdb.bind in 'debug.info.pdb.bind.pas',
  debug.info.log in 'debug.info.log.pas',
  debug.info.utilities in 'debug.info.utilities.pas';

var
  Logger: IDebugInfoModuleLogger;

// Find parameter by index (zero based), ignores switches.
function FindParam(Index: integer; var Value: string; const Default: string = ''): boolean;
begin
  for var i := 1 to ParamCount do
  begin
    Value := ParamStr(i);

    if (CharInSet(Value[1], SwitchChars)) then
      continue;

    if (Index = 0) then
      Exit(True);

    Dec(Index);
  end;
  Value := Default;
  Result := False;
end;

procedure DisplayBanner;
begin
  Writeln('map2pdb - Copyright (c) 2021 Anders Melander');
  Writeln(Format('Version %s', [TVersionInfo.FileVersionString(ParamStr(0))]));
  Writeln;
end;

procedure DisplayHelp;
begin
  //                1         2         3         4         5         6         7         8
  //       12345678901234567890123456789012345678901234567890123456789012345678901234567890
  //
  Writeln('Parses the map file produced by Delphi and writes a PDB file.');
  Writeln;
  Writeln('Usage: map2pdb [options] <map-filename>');
  Writeln;
  Writeln('Options:');
  Writeln('  -v                         Verbose output');
  Writeln('  -pdb[:<output-filename>]   Writes a PDB file (default)');
  Writeln('  -yaml[:<output-filename>]  Writes an YAML file that can be used with');
  Writeln('                             llvm-pdbutil');
  Writeln('  -bind[:<filename>]         Patches the specified exe/dll file to include');
  Writeln('                             a reference to the pdb file');
  Writeln('  -include:<filenames>       Include the specified list of modules in the pdb');
  Writeln('                             (semicolor separated list, wildcards supported)');
  Writeln('  -include:<nnnn>            Include the specified segment in the pdb');
  Writeln('                             (number must be a 4 digit decimal number)');
  Writeln('  -exclude:<filenames>       Exclude the specified list of modules from the pdb');
  Writeln('                             (semicolor separated list, wildcards supported)');
  Writeln('  -exclude:<nnnn>            Exclude the specified segment from the pdb');
  Writeln('                             (number must be a 4 digit decimal number)');
  Writeln('  -blocksize:<nnnn>          Set MSF block size');
  Writeln('                             (default: 4096, valid values are 1024, 2048, 4096,');
  Writeln('                             8192, etc.)');
  Writeln('  -format:<source format>    Specify input file format: Map or Jdbg');
  Writeln('                             By default auto detects from file type and falls');
  Writeln('                             back to map format.');
  Writeln('  -pause                     Prompt after completion');
  Writeln;
  Writeln('Examples:');
  Writeln;
  Writeln('* Read from foobar.map, create foobar.pdb, patch foobar.exe to reference');
  Writeln('  foobar.pdb and ignore all units starting with "system" or "dx":');
  Writeln;
  Writeln('    map2pdb -exclude:system*;dx* -bind foobar.map');
  Writeln;
  Writeln('* Read from mypackage.map, create mypackage.pdb, patch mypackage.bpl to');
  Writeln('  reference mypackage.pdb:');
  Writeln;
  Writeln('    map2pdb -bind:mypackage.bpl mypackage.map');
  Writeln;
end;

procedure DisplayElapsedTime(ms: Int64);
const
  MillisecondsPerSecond = 1000;
  MillisecondsPerMinute = 60 * Int64(MillisecondsPerSecond);
  MillisecondsPerHour = 60 * Int64(MillisecondsPerMinute);
begin
  Logger.Info('Elapsed time: %.2d:%.2d:%.2d.%d', [
    (ms div MillisecondsPerHour) mod 24,
    (ms div MillisecondsPerMinute) mod 60,
    (ms div MillisecondsPerSecond) mod 60,
    (ms mod MillisecondsPerSecond)]);
end;

type
  TDebugInfoConsoleLogger = class(TInterfacedObject, IDebugInfoLogger)
  protected
    // IDebugInfoLogger
    procedure Log(Category: TDebugInfoLogCategory; LogModule: TDebugInfoLogModule; const Msg: string);
  public
    class function New: IDebugInfoLogger;
  end;

procedure TDebugInfoConsoleLogger.Log(Category: TDebugInfoLogCategory; LogModule: TDebugInfoLogModule; const Msg: string);
const
  sLogCategory: array[TDebugInfoLogCategory] of string = ('Debug: ', '', 'Warning: ', 'Error: ', 'Fatal: ');
begin
  if (Category >= DebugInfoLogLevel) then
    Writeln(Format('%s%s', [sLogCategory[Category], Msg]));

  if (Category = lcFatal) then
    Abort;
end;

class function TDebugInfoConsoleLogger.New: IDebugInfoLogger;
begin
  Result := TDebugInfoConsoleLogger.Create;
end;

type
  TTargetType = (ttPDB, ttYAML);
const
  sOutputFileTypes: array[TTargetType] of string = ('.pdb', '.yaml');
  WriterClasses: array[TTargetType] of TDebugInfoWriterClass = (TDebugInfoPdbWriter, TDebugInfoYamlWriter);

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

begin
  var DoPause := FindCmdLineSwitch('pause');
  var sw := TStopwatch.StartNew;
  try

    RegisterDebugInfoLogger(TDebugInfoConsoleLogger.New);
    Logger := RegisterDebugInfoModuleLogger('main');

    DisplayBanner;

    var SourceFilename: string;
    var TargetFilename: string := '';
    var PEFilename: string := '';

    FindCmdLineSwitch('bind', PEFilename, True, [clstValueAppended]);

    if (not FindParam(0, SourceFilename)) or (FindCmdLineSwitch('h')) or (FindCmdLineSwitch('?')) then
    begin
      DisplayHelp;

      if (DoPause) then
      begin
        Writeln('Press enter to continue');
        Readln;
      end;

      exit;
    end;

    if FindCmdLineSwitch('debug') then
      SetDebugInfoLogLevel(lcDebug)
    else
    if FindCmdLineSwitch('v') or FindCmdLineSwitch('verbose') then
      SetDebugInfoLogLevel(lcInfo);

    var TargetType: TTargetType := ttPDB;
    if (FindCmdLineSwitch('yaml', TargetFilename, True, [clstValueAppended])) or (FindCmdLineSwitch('yaml')) then
    begin

      TargetType := ttYAML;

    end else
    begin

      FindCmdLineSwitch('pdb', TargetFilename, True, [clstValueAppended]);

      // If we're both building a PDB and binding it in one go then we can use
      // a new GUID for both.
      if (PEFilename <> '') or (FindCmdLineSwitch('bind')) then
      begin
        PdbBuildSignature := TGUID.NewGuid;

        Logger.Info('Constructed a new PDB GUID: %s', [PdbBuildSignature.ToString]);
      end;
    end;

    if (TargetFilename = '') then
    begin
      TargetFilename := TPath.ChangeExtension(SourceFilename, sOutputFileTypes[TargetType]);

      Logger.Info('Output filename not specified. Defaulting to %s', [TPath.GetFileName(TargetFilename)]);
    end;


    var DebugInfo := TDebugInfo.Create;
    try


      (*
      ** Determine source file format
      *)
      // Default to map format
      var InputFormat: TInputFormat := ifMap;

      var FileType: string;
      // First try to get the format from the command line
      if (not FindCmdLineSwitch('format', FileType, True, [clstValueAppended])) or
        (not TryStrToInputFormat('.'+FileType, InputFormat)) then
      begin
        // Then try to get it from the file type
        FileType := TPath.GetExtension(SourceFilename);
        TryStrToInputFormat(FileType, InputFormat);
      end;


      (*
      ** Read source file
      *)
      var ReaderClass: TDebugInfoReaderClass := ReaderClasses[InputFormat];

      var Reader := ReaderClass.Create;
      try

        Reader.LoadFromFile(SourceFilename, DebugInfo);

      finally
        Reader.Free;
      end;


      (*
      ** Apply filters
      *)

      // Eliminate modules that doesn't satisfy include filter
      var Filter := ''; // Include everything by default
      if (FindCmdLineSwitch('include', Filter, True, [clstValueAppended])) and (Filter <> '') then
        FilterModules(DebugInfo, Filter, True, Logger);

      // Eliminate modules that satisfies exclude filter
      Filter := ''; // Exclude nothing by default
      if (FindCmdLineSwitch('exclude', Filter, True, [clstValueAppended])) and (Filter <> '') then
        FilterModules(DebugInfo, Filter, False, Logger);


      if (DebugInfoLogLevel <= lcInfo) then
      begin
        var SymbolCount := 0;
        var LineCount := 0;
        for var Module in DebugInfo.Modules do
        begin
          Inc(SymbolCount, Module.Symbols.Count);
          Inc(LineCount, Module.SourceLines.Count);
        end;
        Logger.Info('Collected %.0n modules, %.0n symbols, %.0n lines, %.0n source files', [DebugInfo.Modules.Count * 1.0, SymbolCount * 1.0, LineCount * 1.0, DebugInfo.SourceFiles.Count * 1.0]);
      end;


      (*
      ** Validation
      *)
      if (DebugInfoLogLevel <= lcDebug) then
        PostImportValidation(DebugInfo, Logger);


      (*
      ** Write target file
      *)
      begin
        var BlockSize: Integer := 0;
        var Param: string;
        if (FindCmdLineSwitch('blocksize', Param, True, [clstValueAppended])) and (TryStrToInt(Param, BlockSize)) then
          Logger.Info('MSF block size: %.0n bytes', [BlockSize * 1.0]);

        var Writer := WriterClasses[TargetType].Create(BlockSize);
        try

          Writer.SaveToFile(TargetFilename, DebugInfo);

        finally
          Writer.Free;
        end;

      end;

    finally
      DebugInfo.Free;
    end;


    (*
    ** Bind PE file to PDB
    *)
    if (PEFilename <> '') or (FindCmdLineSwitch('bind')) then
    begin
      if (TargetType <> ttPDB) then
        raise EDebugInfo.Create('-bind requires PDB output');

      if (PEFilename = '') then
      begin
        PEFilename := TPath.ChangeExtension(SourceFilename, '.exe');

        Logger.Info('PE filename not specified. Defaulting to %s', [TPath.GetFileName(PEFilename)]);
      end;

      PatchPE(PEFilename, TargetFilename);
    end;

  except
    on E: Exception do
    begin
{$ifdef MADEXCEPT}
      // There's no need to scare the user with a madExcept stack trace for
      // internally generated exceptions. Just show a simple error message.
      if not (E is EDebugInfo) then
        madExcept.HandleException
      else
{$endif MADEXCEPT}
      Logger.Error('%s: %s', [E.ClassName, E.Message], False);

      if (DebugHook <> 0) then
        DoPause := True;

      ExitCode := 1;
    end;
  end;

  DisplayElapsedTime(sw.ElapsedMilliseconds);

  if (DoPause) then
  begin
    Writeln('Done - Press enter to continue');
    Readln;
  end;

end.
