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

{$define RECOVER_MODULE_OVERLAP}

uses
  System.Classes,
  debug.info,
  debug.info.reader,
  debug.info.log;

type
  IDebugInfoLineLogger = interface
    ['{1EA6E06A-0491-4BCF-BFA5-508BC88912BD}']
    procedure Warning(LineNumber: integer; const Msg: string); overload;
    procedure Warning(LineNumber: integer; const Fmt: string; const Args: array of const); overload;
    procedure Error(LineNumber: integer; const Msg: string); overload;
    procedure Error(LineNumber: integer; const Fmt: string; const Args: array of const); overload;
  end;

type
  TDebugInfoMapReader = class(TDebugInfoReader)
  private
    FLineLogger: IDebugInfoLineLogger;
  protected
    property LineLogger: IDebugInfoLineLogger read FLineLogger;
  public
    constructor Create; override;
    procedure LoadFromStream(Stream: TStream; DebugInfo: TDebugInfo); override;
  end;

// More a beautyfier than a demangler since the MAP symbols aren't really mangled
function DemangleMapSymbol(Module: TDebugInfoModule; const Name: string): string;


implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Math;

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

type
  TDebugInfoLineModuleLogger = class(TInterfacedObject, IDebugInfoLineLogger)
  private
    FModuleLogger: IDebugInfoModuleLogger;
  protected
    // IDebugInfoLineModuleLogger
    procedure Warning(LineNumber: integer; const Msg: string); overload;
    procedure Warning(LineNumber: integer; const Fmt: string; const Args: array of const); overload;
    procedure Error(LineNumber: integer; const Msg: string); overload;
    procedure Error(LineNumber: integer; const Fmt: string; const Args: array of const); overload;
  public
    constructor Create(const AModuleLogger: IDebugInfoModuleLogger);
  end;

procedure TDebugInfoLineModuleLogger.Error(LineNumber: integer; const Msg: string);
begin
  FModuleLogger.Error('[%5d] %s', [LineNumber, Msg]);
end;

constructor TDebugInfoLineModuleLogger.Create(const AModuleLogger: IDebugInfoModuleLogger);
begin
  inherited Create;
  FModuleLogger := AModuleLogger;
end;

procedure TDebugInfoLineModuleLogger.Error(LineNumber: integer; const Fmt: string; const Args: array of const);
begin
  Error(LineNumber, Format(Fmt, Args));
end;

procedure TDebugInfoLineModuleLogger.Warning(LineNumber: integer; const Msg: string);
begin
  FModuleLogger.Warning('[%5d] %s', [LineNumber, Msg]);
end;

procedure TDebugInfoLineModuleLogger.Warning(LineNumber: integer; const Fmt: string; const Args: array of const);
begin
  Warning(LineNumber, Format(Fmt, Args));
end;

type
  TLineReader = class
  strict private
    FReader: TStreamReader;
    FLineNumber: integer;
    FLineBuffer: string;
    FHasLineBuffer: boolean;
    FPeekBuffer: string;
    FHasPeekBuffer: boolean;
  private
  public
    constructor Create(Stream: TStream);
    destructor Destroy; override;

    function CurrentLine(Skip: boolean = False): string;
    function HasData: boolean;
    function NextLine(Skip: boolean = False): string;
    function PeekLine(Skip: boolean = False): string;

    property LineBuffer: string read FLineBuffer;
    property LineNumber: integer read FLineNumber;
  end;

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

{ TDebugInfoMapReader }

constructor TDebugInfoMapReader.Create;
begin
  inherited;
  FLineLogger := TDebugInfoLineModuleLogger.Create(Logger);
end;

procedure TDebugInfoMapReader.LoadFromStream(Stream: TStream; DebugInfo: TDebugInfo);
var
  Reader: TLineReader;

  function HexToNibble(c: char): Cardinal;
  begin
    case c of
      '0'..'9': Result := Ord(c)-Ord('0');
      'a'..'f': Result := 10 + Ord(c)-Ord('a');
      'A'..'F': Result := 10 + Ord(c)-Ord('A');
    else
      Result := $FF;
    end;
  end;

  function HexToInt16(const s: string; var Offset: integer): Word;
  begin
    Result := 0;
    var FirstOffset := Offset;
    var i := SizeOf(Result) * 2;
    while (i > 0) and (Offset < Length(s)) do
    begin
      var Nibble := HexToNibble(s[Offset+1]);
      if (Nibble = $FF) then
        break;

      Result := (Result SHL 4) or Nibble;
      Inc(Offset);
      Dec(i);
    end;

    if (Offset = FirstOffset) then
      LineLogger.Error(Reader.LineNumber, 'Invalid %d-bit hex number: "%s"', [SizeOf(Result)*8, Copy(s, FirstOffset+1, SizeOf(Result)*2)]);
  end;

  function HexToInt32(const s: string; var Offset: integer): Cardinal;
  begin
    Result := 0;
    var FirstOffset := Offset;
    var i := SizeOf(Result) * 2;
    while (i > 0) and (Offset < Length(s)) do
    begin
      var Nibble := HexToNibble(s[Offset+1]);
      if (Nibble = $FF) then
        break;

      Result := (Result SHL 4) or Nibble;
      Inc(Offset);
      Dec(i);
    end;

    if (Offset = FirstOffset) then
      LineLogger.Error(Reader.LineNumber, 'Invalid %d-bit hex number: "%s"', [SizeOf(Result)*8, Copy(s, FirstOffset+1, SizeOf(Result)*2)]);
  end;

  function HexToInt64(const s: string; var Offset: integer): Int64;
  begin
    // Note:
    // - We need to allow 32-bit hex value (Segment offset is 16 digits in map files
    //   produced by Delphi 11.2, 8 digits in older versions)
    Result := 0;
    var FirstOffset := Offset;
    var i := SizeOf(Result) * 2;
    while (i > 0) and (Offset < Length(s)) do
    begin
      var Nibble := HexToNibble(s[Offset+1]);
      if (Nibble = $FF) then
        break;

      Result := (Result SHL 4) or Nibble;
      Inc(Offset);
      Dec(i);
    end;

    if (Offset = FirstOffset) then
      LineLogger.Error(Reader.LineNumber, 'Invalid %d-bit hex number: "%s"', [SizeOf(Result)*8, Copy(s, FirstOffset+1, SizeOf(Result)*2)]);
  end;

  function DecToInt32(const s: string; var Offset: integer): integer;
  begin
    Result := 0;
    var Any := False;
    var p: PChar := @s[Offset+1];
    while Ord(p^) in [Ord('0') .. Ord('9')] do
    begin
      Result := (Result * 10) + (Ord(p^) - Ord('0'));
      Inc(p);
      Inc(Offset);
      Any := True;
    end;
    if (not Any) then
      LineLogger.Error(Reader.LineNumber, 'Invalid integer number: "%s"', [Copy(s, Offset+1, MaxInt)]);
  end;

begin
  Logger.Info('Reading MAP file');

  Reader := TLineReader.Create(Stream);
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
    while (Reader.HasData) and (not Reader.CurrentLine(True).StartsWith('Start')) and (not Reader.LineBuffer.EndsWith('Class')) do
      Reader.NextLine(True);

    // Skip empty lines and exit if no more lines
    if (Reader.NextLine(True).IsEmpty) then
      Exit;

    var LegacyMapFile := False;

    // Delphi:
    // " 0001:00401000 000F47FCH .text                   CODE"
    //
    // C++ Builder:
    // " 0001:00401000 0009DF6A4H _TEXT                  CODE"
    while (not Reader.CurrentLine.IsEmpty) do
    begin
      var n: integer := 0;
      var SegmentID: Cardinal := DecToInt32(Reader.LineBuffer, n);

      n := Pos(':', Reader.LineBuffer, n+1);
      var Offset: TDebugInfoOffset := HexToInt64(Reader.LineBuffer, n);

      n := Pos(' ', Reader.LineBuffer, n+1);
      // C++ Builder size is a 32-bit value specified with 9 hex digits so we need to read is as a 64-bit value
      var Size: TDebugInfoOffset := HexToInt64(Reader.LineBuffer, n);

      n := Pos('.', Reader.LineBuffer, n+1);
      var n2 := Pos(' ', Reader.LineBuffer, n+1);
      var Name := Copy(Reader.LineBuffer, n, n2-n);
      if (Name.IsEmpty) then
        LineLogger.Error(Reader.LineNumber, 'Invalid segment name'#13#10'%s', [Reader.LineBuffer]);

      var ClassName := Copy(Reader.LineBuffer, n2+1, MaxInt).Trim;
      if (ClassName.IsEmpty) then
        LineLogger.Error(Reader.LineNumber, 'Invalid segment class name'#13#10'%s', [Reader.LineBuffer]);

      // Try to detect ancient map files with invalid segment info
      if (not LegacyMapFile) and (SegmentID = 2) and (Offset = 0) then
      begin
        LegacyMapFile := True;
        LineLogger.Warning(Reader.LineNumber, 'Legacy map file detected. An attempt will be made to handle invalid Segment and Module data.');
      end;

      if (LegacyMapFile) then
      begin
        // Try to recover from invalid segment info
        var ConflictingSegment := DebugInfo.Segments.FindByOffset(Offset);
        if (ConflictingSegment <> nil) then
        begin
          LineLogger.Warning(Reader.LineNumber, 'Overlapping segments: %s [%.4X:%.16X] and %s [%.4X:%.16X]',
            [Name, SegmentID, Offset, ConflictingSegment.Name, ConflictingSegment.Index, ConflictingSegment.Offset]);
          // Calculate a bogus offset so we can get on with it
          for var Segment in DebugInfo.Segments do
            Offset := Max(Offset, Segment.Offset + Segment.Size);
          // Align to $1000
          Offset := (Offset + $0FFF) and (not $0FFF);
          LineLogger.Warning(Reader.LineNumber, 'Calculated segment offset assigned: %s [%.4X:%.16X]', [Name, SegmentID, Offset]);
        end;

        ConflictingSegment := DebugInfo.Segments.FindByIndex(SegmentID);
        if (ConflictingSegment <> nil) then
        begin
          LineLogger.Warning(Reader.LineNumber, 'Duplicate segment index: %s [%.4X:%.16X] and %s [%.4X:%.16X]',
            [Name, SegmentID, Offset, ConflictingSegment.Name, ConflictingSegment.Index, ConflictingSegment.Offset]);
          // Calculate a bogus index
          for var Segment in DebugInfo.Segments do
            SegmentID := Max(SegmentID, Segment.Index+1);
          LineLogger.Warning(Reader.LineNumber, 'Calculated segment index assigned: %s [%.4X:%.16X]', [Name, SegmentID, Offset]);
        end;
      end;

      var SegmentClass := TDebugInfoSegment.GuessClassType(ClassName);
      var Segment := DebugInfo.Segments.Add(SegmentID, Name, SegmentClass);

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
        LineLogger.Warning(Reader.LineNumber, 'Empty segment: %s [%.4d:%.16X]', [Name, SegmentID, Segment.Offset]);

      // Check for non-fatal overlapping segments (specifically .tls):
      //   "0001:0000000000401000 006CD7B8H .text                   CODE"
      //   "0004:0000000000400000 00008260H .tls                    TLS"
      // Fatal overlaps have already been checked when we assigned Segment.Offset above.
      var OverlappingSegment := Segment.FindOverlap;

      if (OverlappingSegment <> nil) then
        LineLogger.Warning(Reader.LineNumber, 'Overlapping segments: %s [%.4X:%.16X] and %s [%.4X:%.16X]',
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
      Exit;

    // Delphi:
    // " 0001:00000000 0000F684 C=CODE     S=.text    G=(none)   M=System   ACBP=A9"
    //
    // C++ Builder:
    // " 0001:000040C4 00000163 C=CODE    S=_TEXT    G=(none)   M=C:\PROGRAM FILES (X86)\EMBARCADERO\STUDIO\22.0\LIB\WIN32\RELEASE\C0FMX32W.OBJ ACBP=A9"
    // " 0001:0002C4D8 0000551C C=CODE    S=_TEXT    G=(none)   M=C:\PROGRAM FILES (X86)\EMBARCADERO\STUDIO\22.0\LIB\WIN32\DEBUG\RTL.LIB|System.Types ACBP=A9"
    // " 0002:00030048 00001228 C=DATA    S=_DATA    G=DGROUP   M=<internal> ACBP=A9"
    while (not Reader.CurrentLine.IsEmpty) do
    begin
      var ModulePos := Pos(' C=', Reader.LineBuffer);
      var ClassName := Copy(Reader.LineBuffer, ModulePos+2, Pos(' ', Reader.LineBuffer, ModulePos+2)-ModulePos-2);
      var Address := Copy(Reader.LineBuffer, 1, ModulePos-1);

      ModulePos := Pos('M=', Reader.LineBuffer);
      var ModuleName := Copy(Reader.LineBuffer, ModulePos+2, Pos(' ACBP=', Reader.LineBuffer, ModulePos+2)-ModulePos-2).Trim;
      ModulePos := Pos('|', ModuleName);
      if (ModulePos = 0) then
      begin
        if (not ModuleName.IsEmpty) and (TPath.IsValidFileNameChar(ModuleName[1])) then
          // Remove path and file type (C++ Builder modules)
          ModuleName := TPath.GetFileNameWithoutExtension(ModuleName)
      end else
        ModuleName := Copy(ModuleName, ModulePos+1, MaxInt);
      if (ModuleName.IsEmpty) then
        LineLogger.Error(Reader.LineNumber, 'Invalid module name'#13#10'%s', [Reader.LineBuffer]);

      ModulePos := 0;
      var SegmentID: Cardinal := DecToInt32(Address, ModulePos);

      ModulePos := Pos(':', Address, ModulePos+1);
      var Offset: TDebugInfoOffset := HexToInt64(Address, ModulePos);

      ModulePos := Pos(' ', Address, ModulePos+1);
      var Size: TDebugInfoOffset := HexToInt32(Address, ModulePos);
      if (Size = 0) then
        LineLogger.Error(Reader.LineNumber, 'Invalid module size'#13#10'%s', [Reader.LineBuffer]);

      var Segment: TDebugInfoSegment := nil;
      if (LegacyMapFile) then
        // We can't trust the SegmentIDs in old map files. Use the class name instead
        Segment := DebugInfo.Segments.FindByClassName(ClassName);

      if (Segment = nil) then
        Segment := DebugInfo.Segments.FindByIndex(SegmentID);

      if (Segment = nil) then
        LineLogger.Error(Reader.LineNumber, 'Unknown segment: %.4d (%s)'#13#10'%s', [SegmentID, ClassName, Reader.LineBuffer]);

      // Look for existing module
      var Module := DebugInfo.Modules.FindOverlap(Segment, Offset, Size);
      if (Module <> nil) then
{$if defined(RECOVER_MODULE_OVERLAP)}
      begin
        LineLogger.Warning(Reader.LineNumber, 'Modules overlap: %s, %s'#13#10'%s', [ModuleName, Module.Name, Reader.LineBuffer]);
        var Overlap := Module.Offset + Module.Size - Offset;
        if (Overlap > 0) then
        begin
          // Existing module extends into this one. Move this one.
          if (Size <= Overlap) then
          begin
            LineLogger.Warning(Reader.LineNumber, 'Unable to recover by moving module as module is too small. Module ignored: %s', [ModuleName]);
            Size := 0;
          end else
          begin
            LineLogger.Warning(Reader.LineNumber, 'Recovered by moving and shrinking module %d bytes', [Overlap]);
            Offset := Offset + Overlap;
            Size := Size - Overlap;
          end;
        end else
        begin
          // This module extends into existing module. Shrink this one.
          if (Size <= -Overlap) then
          begin
            LineLogger.Warning(Reader.LineNumber, 'Unable to recover by moving module as module is too small. Module ignored: %s', [ModuleName]);
            Size := 0;
          end else
          begin
            LineLogger.Warning(Reader.LineNumber, 'Recovered by shrinking module %d bytes', [-Overlap]);
            Size := Size + Overlap;
          end;
        end;

        // If new module still overlap something we give up on it
        if (Size > 0) then
        begin
          Module := DebugInfo.Modules.FindOverlap(Segment, Offset, Size);
          if (Module <> nil) then
          begin
            LineLogger.Warning(Reader.LineNumber, 'Unable to recover from multiple module overlaps. New overlap: %s', [Module.Name]);
            Size := 0;
          end;
        end;
      end;
{$else}
        LineLogger.Error(Reader.LineNumber, 'Modules overlap: %s, %s'#13#10'%s', [ModuleName, Module.Name, Reader.LineBuffer]);
{$ifend}

      if (Size > 0) and (Offset + Size > Segment.Size) then
      begin
        LineLogger.Warning(Reader.LineNumber, 'Module exceed segment bounds - ignored: %s [%.4d:%.16X-%.16X] > [%.16X] > ', [ModuleName, SegmentID, Offset, Offset+Size, Segment.Size]);
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
      Exit;

    // " 0001:000E99AC       debug.info..TDebugInfo"
    while (not Reader.CurrentLine.IsEmpty) do
    begin
      var n := Pos(' ', Reader.LineBuffer);
      var Address := Copy(Reader.LineBuffer, 1, n-1);

      var Name := Copy(Reader.LineBuffer, n+1, MaxInt).TrimLeft;
      if (Name.IsEmpty) then
        LineLogger.Error(Reader.LineNumber, 'Invalid symbol name'#13#10'%s', [Reader.LineBuffer]);

      n := 0;
      var SegmentID: Cardinal := DecToInt32(Address, n);

      n := Pos(':', Address, n+1);
      var Offset: TDebugInfoOffset := HexToInt64(Address, n);

      var Segment := DebugInfo.Segments.FindByIndex(SegmentID);
      if (Segment = nil) then
        LineLogger.Error(Reader.LineNumber, 'Unknown segment index: %.4d'#13#10'%s', [SegmentID, Reader.LineBuffer]);

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
            LineLogger.Warning(Reader.LineNumber, 'Symbol with duplicate offset ignored: [%.4d:%.16X] %s', [SegmentID, Offset, Name]);
        end;

      end else
        LineLogger.Warning(Reader.LineNumber, 'Failed to resolve symbol to module: [%.4d:%.16X] %s', [SegmentID, Offset, Name]);

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

      var n := Pos('(', Reader.LineBuffer);
      if (n = 0) then
        LineLogger.Error(Reader.LineNumber, 'Source file start marker "(" not found'#13#10'%s', [Reader.LineBuffer]);
      var ModuleName := Copy(Reader.LineBuffer, Length(sPrefix)+1, n-1-Length(sPrefix));

      var n2 := Pos(')', Reader.LineBuffer, n+1);
      if (n2 = 0) then
        LineLogger.Error(Reader.LineNumber, 'Source file end marker ")" not found'#13#10'%s', [Reader.LineBuffer]);
      var Filename := Copy(Reader.LineBuffer, n+1, n2-n-1);

      n := Pos('segment', Reader.LineBuffer, n2+1);
      if (n = 0) then
        LineLogger.Error(Reader.LineNumber, 'Source file segment marker "segment" not found'#13#10'%s', [Reader.LineBuffer]);
      Inc(n, 7);
      while (Reader.LineBuffer[n] = ' ') do
        Inc(n);

      var SegmentName := Copy(Reader.LineBuffer, n, MaxInt);
      var Segment := DebugInfo.Segments.FindByName(SegmentName);
      if (Segment = nil) then
        LineLogger.Error(Reader.LineNumber, 'Unknown segment name: %s'#13#10'%s', [SegmentName, Reader.LineBuffer]);

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
          n := 0;
          while (n < Reader.LineBuffer.Length) and (Reader.LineBuffer[n+1] = ' ') do
            Inc(n);

          while (n < Reader.LineBuffer.Length) do
          begin
            // Get line number
            var LineNumber: Cardinal := DecToInt32(Reader.LineBuffer, n);
            Inc(n); // Skip ' '

            // Get segment index (we already have that info from the header)
            var SegmentID: Cardinal := DecToInt32(Reader.LineBuffer, n);
            if (SegmentID <> Segment.Index) then
              LineLogger.Error(Reader.LineNumber, 'Segment mismatch. Module segment:%d (%s), Line segment:%d'#13#10'%s', [Segment.Index, Segment.Name, SegmentID, Reader.LineBuffer]);
            Inc(n); // Skip ':'

            // Get offset
            var Offset: TDebugInfoOffset := HexToInt64(Reader.LineBuffer, n);

            // Ignore line numbers with offset=0
            if (Offset <> 0) then
            begin
              if (Offset < Module.Offset) then
              begin
                LineLogger.Warning(Reader.LineNumber, 'Line number offset out of range for module. Offset:%.16X, Module:%s [%.16X - %.16X]', [Offset, Module.Name, Module.Offset, Module.Offset+Module.Size]);
              end else
              if (Offset < Module.Offset + Module.Size) then
              begin
                // Validate module
                var ModuleByOffset := DebugInfo.Modules.FindByOffset(Module.Segment, Offset);
                if (Module <> ModuleByOffset) then
                  LineLogger.Error(Reader.LineNumber, 'Module mismatch: Offset=%.16X, Module=%s, Found module:%s'#13#10'%s', [Offset, Module.Name, ModuleByOffset.Name, Reader.LineBuffer]);

                // Offset is relative to segment. Make it relative to module
                Dec(Offset, Module.Offset);
                Assert(Offset < Module.Size);

                Module.SourceLines.Add(SourceFile, LineNumber, Offset);
                HasLineNumbers := True;
              end else
              begin
                // This is typically the last "end." of the unit. The offset corresponds to the start of the next module.

                // We can get *a lot* of these so I've disabled output of them for now
                // Logger.Warning(Reader.LineNumber, 'Line number offset out of range for module: Offset=%.16X, Module=%s', [Offset, Module.Name]);
              end;
            end else
              LineLogger.Warning(Reader.LineNumber, 'Line number with zero offset ignored. Module:%s, Segment:%.4d, Source:%s, Line:%d', [Module.Name, SegmentID, SourceFile.Filename, LineNumber]);

            while (n < Reader.LineBuffer.Length) and (Reader.LineBuffer[n+1] = ' ') do
              Inc(n);
          end;

          if (Reader.NextLine.IsEmpty) then
            break;
        end;
      end else
      begin
        // Ignore empty modules. E.g.:
        // Line numbers for System.RTLConsts(System.RTLConsts.pas) segment .text
        //   611 0001:00000000

        // Error(Reader.LineNumber, 'Module not found: %s'#13#10'%s', [ModuleName, Reader.LineBuffer]);

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
      LineLogger.Warning(Reader.LineNumber, 'Map file contained NO line number information');


  finally
    Reader.Free;
  end;
end;

end.

