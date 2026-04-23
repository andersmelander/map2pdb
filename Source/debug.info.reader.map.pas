unit debug.info.reader.map;

(*
 * Copyright (c) 2021 Anders Melander
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *)

interface

{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}

uses
  System.Classes,
  debug.info,
  debug.info.reader,
  debug.info.log;

type
  IDebugInfoLineLogger = interface
    ['{1EA6E06A-0491-4BCF-BFA5-508BC88912BD}']
    procedure Warning(const Msg: string); overload;
    procedure Warning(const Fmt: string; const Args: array of const); overload;
    procedure Error(const Msg: string); overload;
    procedure Error(const Fmt: string; const Args: array of const); overload;
  end;

// -----------------------------------------------------------------------------
//
//      TDebugInfoMapReader
//
// -----------------------------------------------------------------------------
// Reader for map files
// -----------------------------------------------------------------------------
type
  TDebugInfoMapReader = class(TDebugInfoReader)
  private
    FLineLogger: IDebugInfoLineLogger;
  protected
    function HexToNibble(c: char): Cardinal;
    function HexToInt16(const s: string; var Offset: integer): Word;
    function HexToInt32(const s: string; var Offset: integer): Cardinal;
    function HexToInt64(const s: string; var Offset: integer): Int64;
    function DecToInt32(const s: string; var Offset: integer): integer;

    function ParseSegmentAndOffset(const s: string; var Index: integer; out SegmentID: Cardinal; out Offset: TDebugInfoOffset): integer;
    function GetSectionName(const Str: string; var Offset: integer): string;

    // Returned position is past last delimiter
    function SkipRequiredDelimiter(const Delimiter: Char; const Str: string; Offset: integer; const ErrorMsg: string): integer;

    // Returned position is at start of marker, unless SkipMarker=True in which case it's just past the marker
    function FindRequiredMarker(const Marker, Str: string; Offset: integer; const ErrorMsg: string; SkipMarker: boolean = False): integer;

  protected
    property LineLogger: IDebugInfoLineLogger read FLineLogger;

  public
    constructor Create; override;

    procedure LoadFromStream(Stream: TStream; DebugInfo: TDebugInfo); override;
  end;


// More a beautyfier than a demangler since the MAP symbols aren't really mangled
function DemangleMapSymbol(Module: TDebugInfoModule; const Name: string): string;


// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Math,
  Winapi.Windows;

// -----------------------------------------------------------------------------

function DemangleMapSymbol(Module: TDebugInfoModule; const Name: string): string;
begin
  var n := 1;

  // Strip module name from symbol name
  if (Name.StartsWith(Module.Name)) and (Name.Length > Module.Name.Length) and (Name[Module.Name.Length+1] = '.') then
    Inc(n, Module.Name.Length+1); // +1 to get rid of the separating "."

//  if (Pos('$thunk_', Name, n) = n) then
//    Inc(n, '$thunk_'.Length);

  if (n < Name.Length) then
  begin
    // Types start with "."
    if (n < Name.Length) and (Name[n] = '.') then
      Exit('');

    // Skip {module}
    if (Name[n] = '{') then
      n := Pos('}', Name, n+1)+1;

    // Strip leading "@"
    if (n < Name.Length) and (Name[n] = '@') then
      Inc(n);
  end;

  if (n > 1) then
    Result := Copy(Name, n, MaxInt)
  else
    Result := Name;

  // Remove type unit scopes
  //   TList<System.Generics.Collections.TPair<System.TypInfo.PTypeInfo,System.string>>.GetList
  //   TList<TPair<PTypeInfo,string>>.GetList
  n := Pos('<', Result);
  while (n < Result.Length) and (n <> 0) do
  begin

    // Find next '<' or ','
    while (n <= Result.Length) and (Result[n] <> '<') and (Result[n] <> ',') do
      Inc(n);
    Inc(n); // Skip it

    if (n > Result.Length) then
      break;

    // Find last '.'
    var n2 := n;
    var LastDot := -1;
    while (n2 <= Result.Length) and (Ord(Result[n2]) <= 255) and (AnsiChar(Result[n2]) in ['a'..'z', 'A'..'Z', '.']) do
    begin
      if (Result[n2] = '.') then
        LastDot := n2;
      inc(n2);
    end;
    if (LastDot <> -1) then
      Delete(Result, n, LastDot-n+1);

    inc(n);
  end;
end;

// -----------------------------------------------------------------------------
//
//      TDebugInfoLineModuleLogger
//
// -----------------------------------------------------------------------------
// Logger for map reader
// -----------------------------------------------------------------------------
type
  IDebugInfoLineLoggerContextProvider = interface
    ['{44664F53-A3E3-41FD-9DD4-6C98B8D4397D}']
    function GetLineNumber: integer;
    function GetLineText: string;
    property LineNumber: integer read GetLineNumber;
    property LineText: string read GetLineText;
  end;

type
  TDebugInfoLineModuleLogger = class(TInterfacedObject, IDebugInfoLineLogger)
  private
    FModuleLogger: IDebugInfoModuleLogger;
    FContextProvider: IDebugInfoLineLoggerContextProvider;
  protected
    // IDebugInfoLineModuleLogger
    procedure Warning(const Msg: string); overload;
    procedure Warning(const Fmt: string; const Args: array of const); overload;
    procedure Error(const Msg: string); overload;
    procedure Error(const Fmt: string; const Args: array of const); overload;
  public
    constructor Create(const AModuleLogger: IDebugInfoModuleLogger; const AContextProvider: IDebugInfoLineLoggerContextProvider);
  end;

procedure TDebugInfoLineModuleLogger.Error(const Msg: string);
begin
  FModuleLogger.Error('[%5d] %s'#13#10'%s', [FContextProvider.LineNumber, Msg, FContextProvider.LineText]);
end;

constructor TDebugInfoLineModuleLogger.Create(const AModuleLogger: IDebugInfoModuleLogger; const AContextProvider: IDebugInfoLineLoggerContextProvider);
begin
  inherited Create;
  FModuleLogger := AModuleLogger;
  FContextProvider := AContextProvider;
end;

procedure TDebugInfoLineModuleLogger.Error(const Fmt: string; const Args: array of const);
begin
  Error(Format(Fmt, Args));
end;

procedure TDebugInfoLineModuleLogger.Warning(const Msg: string);
begin
  FModuleLogger.Warning('[%5d] %s', [FContextProvider.LineNumber, Msg]);
end;

procedure TDebugInfoLineModuleLogger.Warning(const Fmt: string; const Args: array of const);
begin
  Warning(Format(Fmt, Args));
end;


// -----------------------------------------------------------------------------
//
//      TLineReader
//
// -----------------------------------------------------------------------------
// Present an input stream as a sequence of text lines
// -----------------------------------------------------------------------------
type
  TLineReader = class(TNoRefCountObject, IDebugInfoLineLoggerContextProvider)
  strict private
    FReader: TStreamReader;
    FLineNumber: integer;
    FLineBuffer: string;
    FHasLineBuffer: boolean;
    FPeekBuffer: string;
    FHasPeekBuffer: boolean;
  private
    // IDebugInfoLineLoggerContextProvider
    function GetLineNumber: integer;
    function GetLineText: string;
  public
    constructor Create(Stream: TStream);
    destructor Destroy; override;

    function CurrentLine(Skip: boolean = False): string;
    function HasData: boolean;
    function NextLine(Skip: boolean = False): string;
    function PeekLine(Skip: boolean = False): string;

    function SkipSpace(Offset: integer): integer;

    property LineBuffer: string read FLineBuffer;
    property LineNumber: integer read FLineNumber;
  end;

// -----------------------------------------------------------------------------

constructor TLineReader.Create(Stream: TStream);
begin
  inherited Create;

  FReader := TStreamReader.Create(Stream);
end;

destructor TLineReader.Destroy;
begin
  FReader.Free;

  inherited;
end;

function TLineReader.GetLineNumber: integer;
begin
  Result := FLineNumber;
end;

function TLineReader.GetLineText: string;
begin
  Result := FLineBuffer;
end;

function TLineReader.PeekLine(Skip: boolean): string;
begin
  while (not FHasPeekBuffer) and (not FReader.EndOfStream) do
  begin
    FPeekBuffer := FReader.ReadLine.TrimLeft;
    Inc(FLineNumber);
    if (not Skip) or (not FPeekBuffer.IsEmpty) then
      FHasPeekBuffer := True;
  end;

  if (FHasPeekBuffer) then
    Result := FPeekBuffer
  else
    Result := '';
end;

function TLineReader.SkipSpace(Offset: integer): integer;
begin
  Result := Offset;
  while (Result <= Length(FLineBuffer)) and (FLineBuffer[Result] = ' ') do
    Inc(Result);
end;

function TLineReader.CurrentLine(Skip: boolean): string;
begin
  if (not FHasLineBuffer) then
  begin
    if (not FHasPeekBuffer) then
    begin
      while (not FHasLineBuffer) and (not FReader.EndOfStream) do
      begin
        FLineBuffer := FReader.ReadLine.TrimLeft;
        Inc(FLineNumber);
        if (not Skip) or (not FLineBuffer.IsEmpty) then
          FHasLineBuffer := True;
      end;
    end else
    begin
      FLineBuffer := FPeekBuffer;
      FHasLineBuffer := True;
      FHasPeekBuffer := False;
      FPeekBuffer := '';
    end;
  end;

  if (FHasLineBuffer) then
    Result := FLineBuffer
  else
    Result := '';
end;

function TLineReader.NextLine(Skip: boolean): string;
begin
  FHasLineBuffer := False;
  FLineBuffer := '';
  Result := CurrentLine(Skip);
end;

function TLineReader.HasData: boolean;
begin
  Result := (FHasLineBuffer) or (FHasPeekBuffer) or (not FReader.EndOfStream);
end;


// -----------------------------------------------------------------------------
//
//      TDebugInfoMapReader
//
// -----------------------------------------------------------------------------
constructor TDebugInfoMapReader.Create;
begin
  inherited;
end;

// -----------------------------------------------------------------------------

procedure TDebugInfoMapReader.LoadFromStream(Stream: TStream; DebugInfo: TDebugInfo);
var
  Reader: TLineReader;
begin
  Logger.Info('Reading MAP file');

  Reader := TLineReader.Create(Stream);
  try
    FLineLogger := TDebugInfoLineModuleLogger.Create(Logger, Reader);
    try

      (*
      ** Segments
      *)

      Logger.Info('- Segments');
      // Delphi:
      // " Start         Length     Name                   Class"
      //
      // C++ Builder:
      // " Start Length Name Class"
      while (Reader.HasData) do
      begin
        if (Reader.CurrentLine(True).StartsWith('Start')) and (Reader.LineBuffer.EndsWith('Class')) then
          break;
        Reader.NextLine(True);
      end;

      // Skip empty lines and exit if no more lines
      if (Reader.NextLine(True).IsEmpty) then
      begin
        LineLogger.Warning('Segment list not found');
        Exit;
      end;

      var LegacyMapFile := False;

      // Delphi 32-bit:
      // " 0001:00401000 000F47FCH .text                   CODE"
      // Delphi 64-bit:
      // " 0001:0000000000301000 001FD57CH .text           CODE"
      //
      // C++ Builder:
      // " 0001:00401000 0009DF6A4H _TEXT                  CODE"
      while (not Reader.CurrentLine.IsEmpty) do
      begin
        var n: integer := 1;

        var SegmentID: Cardinal;
        var Offset: TDebugInfoOffset;
        var OffsetSize := ParseSegmentAndOffset(Reader.LineBuffer, n, SegmentID, Offset);

        if (DebugInfo.Architecture = IMAGE_FILE_MACHINE_UNKNOWN) then
        begin
          var Bits: integer;
          if (OffsetSize < 16) then
          begin
            DebugInfo.Architecture := IMAGE_FILE_MACHINE_I386;
            Bits := 32;
          end else
          begin
            DebugInfo.Architecture := IMAGE_FILE_MACHINE_AMD64;
            Bits := 64;
          end;
          Logger.Debug('Executable architecture: %d-bit', [Bits]);
        end;

        n := SkipRequiredDelimiter(' ', Reader.LineBuffer, n, 'Missing segment/size delimiter');
        // C++ Builder size is a 32-bit value specified with 9 hex digits so we need to read is as a 64-bit value
        var Size: TDebugInfoOffset := HexToInt64(Reader.LineBuffer, n);

        n := SkipRequiredDelimiter(' ', Reader.LineBuffer, n, 'Missing size/segment name delimiter');
        var SegmentName := GetSectionName(Reader.LineBuffer, n);

        n := SkipRequiredDelimiter(' ', Reader.LineBuffer, n, 'Missing segment name/class name delimiter');
        var ClassName := Copy(Reader.LineBuffer, n, MaxInt).Trim;
        if (ClassName.IsEmpty) then
          LineLogger.Error('Invalid segment class name');

        // Try to detect ancient map files with invalid segment info
        if (not LegacyMapFile) and (SegmentID = 2) and (Offset = 0) then
        begin
          LegacyMapFile := True;
          LineLogger.Warning('Legacy map file detected. An attempt will be made to handle invalid Segment and Module data.');
        end;

        if (LegacyMapFile) then
        begin
          // Try to recover from invalid segment info
          var ConflictingSegment := DebugInfo.Segments.FindByOffset(Offset);
          if (ConflictingSegment <> nil) then
          begin
            LineLogger.Warning('Overlapping segments: %s [%.4X:%.16X] and %s [%.4X:%.16X]',
              [SegmentName, SegmentID, Offset, ConflictingSegment.Name, ConflictingSegment.Index, ConflictingSegment.Offset]);
            // Calculate a bogus offset so we can get on with it
            for var Segment in DebugInfo.Segments do
              Offset := Max(Offset, Segment.Offset + Segment.Size);
            // Align to $1000
            Offset := (Offset + $0FFF) and (not $0FFF);
            LineLogger.Warning('Calculated segment offset assigned: %s [%.4X:%.16X]', [SegmentName, SegmentID, Offset]);
          end;

          ConflictingSegment := DebugInfo.Segments.FindByIndex(SegmentID);
          if (ConflictingSegment <> nil) then
          begin
            LineLogger.Warning('Duplicate segment index: %s [%.4X:%.16X] and %s [%.4X:%.16X]',
              [SegmentName, SegmentID, Offset, ConflictingSegment.Name, ConflictingSegment.Index, ConflictingSegment.Offset]);
            // Calculate a bogus index
            for var Segment in DebugInfo.Segments do
              SegmentID := Max(SegmentID, Segment.Index+1);
            LineLogger.Warning('Calculated segment index assigned: %s [%.4X:%.16X]', [SegmentName, SegmentID, Offset]);
          end;
        end;

        if (DebugInfo.Segments.FindByClassName(ClassName) <> nil) then
          LineLogger.Warning('Duplicate segment class name: %s', [ClassName]);

        var SegmentClass := TDebugInfoSegment.GuessClassType(ClassName);
        var Segment := DebugInfo.Segments.Add(SegmentID, SegmentName, SegmentClass);

        Segment.Offset := Offset;
        Segment.Size := Size;
        Segment.SegClassName := ClassName;

        // We previously ignored empty segments. E.g.:
        //   "0005:00000000 00000000H .tls                    TLS"
        //   "0006:00400000 00000000H .pdata                  PDATA"
        // but we need to allow them so symbols or lines referencing the segments doesn't cause errors. E.g.:
        //   "0005:00000000       OtlCommon.Utils.LastThreadName"
        //   "0005:00000100       SysInit.TlsLast"
        if (Size = 0) then
          LineLogger.Warning('Empty segment: %s [%.4X:%.16X]', [SegmentName, SegmentID, Segment.Offset]);

        // Check for non-fatal overlapping segments (specifically .tls):
        //   "0001:0000000000401000 006CD7B8H .text                   CODE"
        //   "0004:0000000000400000 00008260H .tls                    TLS"
        // Fatal overlaps have already been checked when we assigned Segment.Offset above.
        var OverlappingSegment := Segment.FindOverlap;

        if (OverlappingSegment <> nil) then
          LineLogger.Warning('Overlapping segments: %s [%.4X:%.16X] and %s [%.4X:%.16X]',
            [Segment.Name, Segment.Index, Segment.Offset, OverlappingSegment.Name, OverlappingSegment.Index, OverlappingSegment.Offset]);

        Reader.NextLine;
      end;


      (*
      ** Modules
      *)

      Logger.Info('- Modules');
      // "Detailed map of segments"
      while (Reader.HasData) and (Reader.CurrentLine(True) <> 'Detailed map of segments') do
        Reader.NextLine(True);

      // Skip empty lines and exit if no more lines
      if (Reader.NextLine(True).IsEmpty) then
      begin
        LineLogger.Warning('Module list not found');
        Exit;
      end;

      // Delphi:
      // " 0001:00000000 0000F684 C=CODE     S=.text    G=(none)   M=System   ACBP=A9"
      // " 0001:00000000 0001640C C=CODE     S=.text    G=(none)   M=System   ALIGN=4"
      //
      // C++ Builder:
      // " 0001:000040C4 00000163 C=CODE    S=_TEXT    G=(none)   M=C:\PROGRAM FILES (X86)\EMBARCADERO\STUDIO\22.0\LIB\WIN32\RELEASE\C0FMX32W.OBJ ACBP=A9"
      // " 0001:0002C4D8 0000551C C=CODE    S=_TEXT    G=(none)   M=C:\PROGRAM FILES (X86)\EMBARCADERO\STUDIO\22.0\LIB\WIN32\DEBUG\RTL.LIB|System.Types ACBP=A9"
      // " 0002:00030048 00001228 C=DATA    S=_DATA    G=DGROUP   M=<internal> ACBP=A9"
      while (not Reader.CurrentLine.IsEmpty) do
      begin
        var ModulePos := FindRequiredMarker(' C=', Reader.LineBuffer, 1, 'Missing segment class name marker', True);
        var n2 := FindRequiredMarker(' ', Reader.LineBuffer, ModulePos, 'Missing segment type separator'); // Here ' ' is considered the marker of the end of the class name
        var ClassName := Copy(Reader.LineBuffer, ModulePos, n2-ModulePos);
        var Address := Copy(Reader.LineBuffer, 1, ModulePos-4);

        ModulePos := FindRequiredMarker('M=', Reader.LineBuffer, n2+1, 'Missing module name marker', True);
        var StartOfName := ModulePos;
        // Find last ' ALIGN=' on line
        n2 := StartOfName;
        var EndOfName: integer;
        repeat
          EndOfName := n2;
          n2 := Pos(' ALIGN=', Reader.LineBuffer, n2+1);
        until (n2 = 0);
        // No "ALIGN"? Find last ' ACBP' on line instead
        if (EndOfName = StartOfName) then
        begin
          n2 := StartOfName;
          repeat
            EndOfName := n2;
            n2 := Pos(' ACBP=', Reader.LineBuffer, n2+1);
          until (n2 = 0);
        end;
        if (EndOfName = StartOfName) then
          LineLogger.Error('Missing module ALIGN/ACBP marker');

        // Trim trailing space
        while (EndOfName > StartOfName) and (Reader.LineBuffer[EndOfName] = ' ') do
          Dec(EndOfName);
        // Trim leading path
        n2 := EndOfName;
        ModulePos := StartOfName;
        while (n2 >= StartOfName) and (not CharInSet(Reader.LineBuffer[n2], ['\', '/', '|'])) do
        begin
          ModulePos := n2;
          Dec(n2);
        end;

        var IsPath := (n2 >= StartOfName) and CharInSet(Reader.LineBuffer[n2], ['\', '/']);
        var FilenameIsAlias := (n2 >= StartOfName) and (Reader.LineBuffer[n2] = '|');

        StartOfName := ModulePos;

        var ModuleName := Copy(Reader.LineBuffer, StartOfName, EndOfName-StartOfName+1);

        // If we got a path delimiter then filename is likely an object file (C++ Builder); Get rid of the filetype.
        // If we got a "|" then filename is an alias (C++ Builder); Get rid of the filetype.
        if (not ModuleName.IsEmpty) and (IsPath or FilenameIsAlias) then
          ModuleName := TPath.GetFileNameWithoutExtension(ModuleName);

        if (ModuleName.IsEmpty) then
          LineLogger.Error('Invalid module name');

        ModulePos := 1;
        var SegmentID: Cardinal;
        var Offset: TDebugInfoOffset;
        ParseSegmentAndOffset(Address, ModulePos, SegmentID, Offset);

        ModulePos := SkipRequiredDelimiter(' ', Address, ModulePos, 'Missing module offset/size separator');

        var Size: TDebugInfoOffset := HexToInt32(Address, ModulePos);
        if (Size = 0) then
          LineLogger.Error('Invalid module size');

        var Segment: TDebugInfoSegment := nil;
        if (LegacyMapFile) then
          // We can't trust the SegmentIDs in old map files. Use the class name instead
          Segment := DebugInfo.Segments.FindByClassName(ClassName);

        if (Segment = nil) then
          Segment := DebugInfo.Segments.FindByIndex(SegmentID);

        if (Segment = nil) then
          LineLogger.Error('Unknown segment: %.4X (%s)', [SegmentID, ClassName]);

        // Look for existing module
        var Module := DebugInfo.Modules.FindOverlap(Segment, Offset, Size);
        if (Module <> nil) then
        begin
          LineLogger.Warning('Modules overlap: %s, %s'#13#10'%s', [ModuleName, Module.Name, Reader.LineBuffer]);
          var Overlap := Module.Offset + Module.Size - Offset;
          if (Overlap > 0) then
          begin
            // Existing module extends into this one. Move this one.
            if (Size <= Overlap) then
            begin
              LineLogger.Warning('Unable to recover by moving module as module is too small. Module ignored: %s', [ModuleName]);
              Size := 0;
            end else
            begin
              LineLogger.Warning('Recovered by moving and shrinking module %d bytes', [Overlap]);
              Offset := Offset + Overlap;
              Size := Size - Overlap;
            end;
          end else
          begin
            // This module extends into existing module. Shrink this one.
            if (Size <= -Overlap) then
            begin
              LineLogger.Warning('Unable to recover by moving module as module is too small. Module ignored: %s', [ModuleName]);
              Size := 0;
            end else
            begin
              LineLogger.Warning('Recovered by shrinking module %d bytes', [-Overlap]);
              Size := Size + Overlap;
            end;
          end;

          // If new module still overlap something we give up on it
          if (Size > 0) then
          begin
            Module := DebugInfo.Modules.FindOverlap(Segment, Offset, Size);
            if (Module <> nil) then
            begin
              LineLogger.Warning('Unable to recover from multiple module overlaps. New overlap: %s', [Module.Name]);
              Size := 0;
            end;
          end;
        end;

        if (Size > 0) and (Offset + Size > Segment.Size) then
        begin
          LineLogger.Warning('Module exceed segment bounds - ignored: %s [%.4X:%.16X-%.16X] > [%.16X] > ', [ModuleName, SegmentID, Offset, Offset+Size, Segment.Size]);
          Size := 0;
        end;

        // Add new module
        if (Size > 0) then // Size = 0 if module has been ignored
          DebugInfo.Modules.Add(ModuleName, Segment, Offset, Size);

        Reader.NextLine;
      end;


      (*
      ** Symbols - sorted by name
      *)

      Logger.Info('- Symbols');
      // "  Address             Publics by Name"
      // Note: Beta versions produce the following:
      // "  Address             Publics by Name           Rva+Base"
      while (Reader.HasData) and (not Reader.CurrentLine(True).Contains('Publics by Name')) do
        Reader.NextLine(True);

      // Skip empty lines and exit if no more lines
      if (Reader.NextLine(True).IsEmpty) then
      begin
        LineLogger.Warning('Symbol list not found');
        Exit;
      end;

      // " 0001:000E99AC       debug.info..TDebugInfo"
      while (not Reader.CurrentLine.IsEmpty) do
      begin
        var n := FindRequiredMarker(' ', Reader.LineBuffer, 1, 'Missing address/symbol separator');
        var Address := Copy(Reader.LineBuffer, 1, n-1);

        var Name := Copy(Reader.LineBuffer, n+1, MaxInt).TrimLeft;
        if (Name.IsEmpty) then
          LineLogger.Error('Invalid symbol name');

        n := 1;
        var SegmentID: Cardinal;
        var Offset: TDebugInfoOffset;
        ParseSegmentAndOffset(Address, n, SegmentID, Offset);

        var Segment := DebugInfo.Segments.FindByIndex(SegmentID);
        if (Segment = nil) then
          LineLogger.Error('Unknown segment index: %.4X', [SegmentID]);

        var Module := DebugInfo.Modules.FindByOffset(Segment, Offset);

        if (Module <> nil) then
        begin

          Name := DemangleMapSymbol(Module, Name);

          if (Name <> '') then
          begin
            // Offset is relative to segment. Make it relative to module
            Dec(Offset, Module.Offset);

            var Symbol := Module.Symbols.Add(Name, Offset);
            if (Symbol = nil) then
              LineLogger.Warning('Symbol with duplicate offset ignored: [%.4X:%.16X] %s', [SegmentID, Offset, Name]);
          end;

        end else
          LineLogger.Warning('Failed to resolve symbol to module: [%.4X:%.16X] %s', [SegmentID, Offset, Name]);

        Reader.NextLine;
      end;

      // Once all symbols has been loaded we can calculate their size
      for var Module in DebugInfo.Modules do
      begin
        Module.Symbols.CalculateSizes;

        for var Symbol in Module.Symbols do
          if (Symbol.Size = 0) then
            Logger.Warning('Zero size symbol: %s.%s', [Module.Name, Symbol.Name]);
      end;


      (*
      ** Symbols - sorted by address
      **
      ** We skip this section - it duplicates the previous
      *)

      // "  Address             Publics by Value"
      // Note: Beta versions produce the following:
      // "  Address             Publics by Value          Rva+Base"
      while (Reader.HasData) and (not Reader.CurrentLine(True).Contains('Publics by Value')) do
        Reader.NextLine(True);


      (*
      ** Line numbers - grouped by module & segment
      *)


      Logger.Info('- Line numbers');
      var HasLineNumbers := False;
      // Rest of file is:
      // "Line numbers for System(WindowsAPIs.INC) segment .text"
      while (Reader.HasData) do
      begin
        const sPrefix = 'Line numbers for ';
        while (Reader.HasData) and (not Reader.CurrentLine(True).StartsWith(sPrefix)) do
          Reader.NextLine(True);

        if (not Reader.HasData) then
          break;

        var n := FindRequiredMarker('(', Reader.LineBuffer, 1, 'Source file start marker "(" not found');
        var ModuleName := Copy(Reader.LineBuffer, Length(sPrefix)+1, n-1-Length(sPrefix));

        var n2 := FindRequiredMarker(')', Reader.LineBuffer, n+1, 'Source file end marker ")" not found');
        var Filename := Copy(Reader.LineBuffer, n+1, n2-n-1);

        n := FindRequiredMarker('segment', Reader.LineBuffer, n2+1, 'Source file segment marker "segment" not found', True);
        n := Reader.SkipSpace(n);

        var SegmentName := GetSectionName(Reader.LineBuffer, n);
        var Segment := DebugInfo.Segments.FindByName(SegmentName);
        if (Segment = nil) then
          LineLogger.Error('Unknown segment name: %s', [SegmentName]);

        var Module := DebugInfo.Modules.FindByName(ModuleName, Segment);
        if (Module <> nil) then
        begin
          var SourceFile := Module.SourceFiles.Add(Filename);

          // Skip empty lines and exit if no more lines
          if (Reader.NextLine(True).IsEmpty) then
            break;

          // "   335 0001:00004068   338 0001:00004070   343 0001:00004078   349 0001:00004080"
          while (not Reader.CurrentLine.IsEmpty) do
          begin
            n := Reader.SkipSpace(1); // This is not necessary; Reader.CurrentLine already trims left space

            while (n <= Reader.LineBuffer.Length) do
            begin
              // Get line number
              var LineNumber: Cardinal := DecToInt32(Reader.LineBuffer, n);
              n := SkipRequiredDelimiter(' ', Reader.LineBuffer, n, 'Missing line number address separator');

              // Get segment index (we already have that info from the header)
              var SegmentID: Cardinal;
              var Offset: TDebugInfoOffset;
              ParseSegmentAndOffset(Reader.LineBuffer, n, SegmentID, Offset);

              if (SegmentID <> Segment.Index) then
                LineLogger.Error('Segment mismatch. Module segment:%.4X (%s), Line segment:%.4X', [Segment.Index, Segment.Name, SegmentID]);

              // Ignore line numbers with offset=0
              if (Offset <> 0) then
              begin
                if (Offset < Module.Offset) then
                begin
                  LineLogger.Warning('Line number offset out of range for module. Offset:%.16X, Module:%s [%.16X - %.16X]', [Offset, Module.Name, Module.Offset, Module.Offset+Module.Size]);
                end else
                if (Offset < Module.Offset + Module.Size) then
                begin
                  // Validate module
                  var ModuleByOffset := DebugInfo.Modules.FindByOffset(Module.Segment, Offset);
                  if (Module <> ModuleByOffset) then
                    LineLogger.Error('Module mismatch: Offset=%.16X, Module=%s, Found module:%s', [Offset, Module.Name, ModuleByOffset.Name]);

                  // Offset is relative to segment. Make it relative to module
                  Dec(Offset, Module.Offset);
                  Assert(Offset < Module.Size);

                  Module.SourceLines.Add(SourceFile, LineNumber, Offset);
                  HasLineNumbers := True;
                end else
                begin
                  // This is typically the last "end." of the unit. The offset corresponds to the start of the next module.

                  // We can get *a lot* of these so I've disabled output of them for now
                  // Logger.Warning('Line number offset out of range for module: Offset=%.16X, Module=%s', [Offset, Module.Name]);
                end;
              end else
                LineLogger.Warning('Line number with zero offset ignored. Module:%s, Segment:%.4X, Source:%s, Line:%d', [Module.Name, SegmentID, SourceFile.Filename, LineNumber]);

              n := Reader.SkipSpace(n);
            end;

            if (Reader.NextLine.IsEmpty) then
              break;
          end;
        end else
        begin
          // Ignore empty modules. E.g.:
          // Line numbers for System.RTLConsts(System.RTLConsts.pas) segment .text
          //   611 0001:00000000

          // Error('Module not found: %s'#13#10'%s', [ModuleName, Reader.LineBuffer]);

          // Skip empty lines and exit if no more lines
          if (Reader.NextLine(True).IsEmpty) then
            break;

          // Skip non-empty lines
          while (not Reader.CurrentLine.IsEmpty) do
          begin
            if (Reader.NextLine.IsEmpty) then
              break;
          end;
        end;

      end;

      if (not HasLineNumbers) then
        LineLogger.Warning('Map file contained NO line number information');

    finally
      FLineLogger := nil;
    end;
  finally
    Reader.Free;
  end;
end;

// -----------------------------------------------------------------------------

function TDebugInfoMapReader.HexToNibble(c: char): Cardinal;
begin
  case c of
    '0'..'9': Result := Ord(c)-Ord('0');
    'a'..'f': Result := 10 + Ord(c)-Ord('a');
    'A'..'F': Result := 10 + Ord(c)-Ord('A');
  else
    Result := $FF;
  end;
end;

function TDebugInfoMapReader.HexToInt16(const s: string; var Offset: integer): Word;
begin
  Result := 0;
  var FirstOffset := Offset;
  var i := SizeOf(Result) * 2;
  while (i > 0) and (Offset <= Length(s)) do
  begin
    var Nibble := HexToNibble(s[Offset]);
    if (Nibble = $FF) then
      break;

    Result := (Result SHL 4) or Nibble;
    Inc(Offset);
    Dec(i);
  end;

  if (Offset = FirstOffset) then
    LineLogger.Error('Invalid %d-bit hex number: "%s"', [SizeOf(Result)*8, Copy(s, FirstOffset, SizeOf(Result)*2)])
  else
  if (Offset <= Length(s)) and (CharInSet(s[Offset], ['H', 'h'])) then
    Inc(Offset); // Skip trailing Hex indicator if it's there
end;

function TDebugInfoMapReader.HexToInt32(const s: string; var Offset: integer): Cardinal;
begin
  Result := 0;
  var FirstOffset := Offset;
  var i := SizeOf(Result) * 2;
  while (i > 0) and (Offset <= Length(s)) do
  begin
    var Nibble := HexToNibble(s[Offset]);
    if (Nibble = $FF) then
      break;

    Result := (Result SHL 4) or Nibble;
    Inc(Offset);
    Dec(i);
  end;

  if (Offset = FirstOffset) then
    LineLogger.Error('Invalid %d-bit hex number: "%s"', [SizeOf(Result)*8, Copy(s, FirstOffset, SizeOf(Result)*2)])
  else
  if (Offset <= Length(s)) and (CharInSet(s[Offset], ['H', 'h'])) then
    Inc(Offset); // Skip trailing Hex indicator if it's there
end;

function TDebugInfoMapReader.HexToInt64(const s: string; var Offset: integer): Int64;
begin
  // Note:
  // - We need to allow 32-bit hex value (Segment offset is 16 digits in map files
  //   produced by Delphi 11.2, 8 digits in older versions)
  Result := 0;
  var FirstOffset := Offset;
  var i := SizeOf(Result) * 2;
  while (i > 0) and (Offset <= Length(s)) do
  begin
    var Nibble := HexToNibble(s[Offset]);
    if (Nibble = $FF) then
      break;

    Result := (Result SHL 4) or Nibble;
    Inc(Offset);
    Dec(i);
  end;

  if (Offset = FirstOffset) then
    LineLogger.Error('Invalid %d-bit hex number: "%s"', [SizeOf(Result)*8, Copy(s, FirstOffset, SizeOf(Result)*2)])
  else
  if (Offset <= Length(s)) and (CharInSet(s[Offset], ['H', 'h'])) then
    Inc(Offset); // Skip trailing Hex indicator if it's there
end;

// -----------------------------------------------------------------------------

function TDebugInfoMapReader.DecToInt32(const s: string; var Offset: integer): integer;
begin
  Result := 0;
  var Any := False;
  var p: PChar := @s[Offset];
  while Ord(p^) in [Ord('0') .. Ord('9')] do
  begin
    Result := (Result * 10) + (Ord(p^) - Ord('0'));
    Inc(p);
    Inc(Offset);
    Any := True;
  end;

  if (not Any) then
    LineLogger.Error('Invalid integer number: "%s"', [Copy(s, Offset, MaxInt)])
  else
  if (CharInSet(p^, ['H', 'h'])) then
    Inc(Offset); // Skip trailing Hex indicator if it's there
end;

// -----------------------------------------------------------------------------

function TDebugInfoMapReader.ParseSegmentAndOffset(const s: string; var Index: integer; out SegmentID: Cardinal; out Offset: TDebugInfoOffset): integer;
begin
  SegmentID := HexToInt32(s, Index);

  if (Index > Length(s)) or (s[Index] <> ':') then
    LineLogger.Error('Missing segment/offset separator');

  Inc(Index);
  Result := Index;
  Offset := HexToInt64(s, Index);

  // Return length of offset text; We need it to determine if the map file
  // was produced for a 32- or 64-bit application.
  Result := Index - Result;
end;

// -----------------------------------------------------------------------------

function TDebugInfoMapReader.GetSectionName(const Str: string; var Offset: integer): string;
begin
  var Start := Offset;
  while (Offset <= Length(Str)) do
    case Str[Offset] of
      'a'..'z', 'A'..'Z', '.', '$', '_': Inc(Offset);
    else
      break;
    end;

  // Allow trailing digits
  if (Start <> Offset) then
    while (Offset <= Length(Str)) do
      case Str[Offset] of
        '0'..'9': Inc(Offset);
      else
        break;
      end;

  if (Start = Offset) then
    LineLogger.Error('Invalid segment name');

  Result := Copy(Str, Start, Offset-Start);
end;

// -----------------------------------------------------------------------------

function TDebugInfoMapReader.SkipRequiredDelimiter(const Delimiter: Char; const Str: string; Offset: integer; const ErrorMsg: string): integer;
begin
  Result := 0;
  while (Offset <= Length(Str)) and (Str[Offset] = Delimiter) do
  begin
    Inc(Offset);
    Result := Offset;
  end;

  if (Result = 0) then
    LineLogger.Error(ErrorMsg);
end;

// -----------------------------------------------------------------------------

function TDebugInfoMapReader.FindRequiredMarker(const Marker, Str: string; Offset: integer; const ErrorMsg: string; SkipMarker: boolean): integer;
begin
  Result := Pos(Marker, Str, Offset);

  if (Result = 0) then
    LineLogger.Error(ErrorMsg)
  else
  if (SkipMarker) then
    Inc(Result, Length(Marker));
end;


end.

