unit debug.info;

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
  System.Generics.Collections,
  System.Generics.Defaults,
  System.SysUtils;

type
  TDebugInfoOffset = UInt64;

type
  TDebugInfo = class;
  TDebugInfoModule = class;


  TDebugInfoSegmentClass = (
    sctCODE,            // Code
    sctICODE,           // Initialization code
    sctDATA,            // Data
    sctIDATA,           // Import data
    sctEDATA,           // Export data
    sctRSRC,            // Resource data
    sctTLS,             // Thread Local Storage data
    sctDEBUG            // Debug data
  );
  TDebugInfoSegmentClasses = set of TDebugInfoSegmentClass;
  //
  // The predefined sections are:
  //   .text, .bss, .rdata, .data, .rsrc, .edata, .idata, .pdata and .debug
  // The names however are not significant.
  //

  TDebugInfoSegments = class;

  TDebugInfoSegment = class
  private
    FOwner: TDebugInfoSegments;
    FSegClassType: TDebugInfoSegmentClass;
    FName: string;
    FOffset: TDebugInfoOffset;
    FSize: TDebugInfoOffset;
    FIndex: Cardinal;
    FCharacteristics: Cardinal;
    FSegClassName: string;
  private
    procedure CheckOverlap;
  protected
    procedure SetOffset(const Value: TDebugInfoOffset);
    procedure SetSize(const Value: TDebugInfoOffset);
  public
    constructor Create(AOwner: TDebugInfoSegments; AIndex: Cardinal; const AName: string; AClassType: TDebugInfoSegmentClass = sctDATA); overload;

    class function GuessClassType(const AName: string): TDebugInfoSegmentClass;

    function FindOverlap(AIgnoredClassTypes: TDebugInfoSegmentClasses = []): TDebugInfoSegment;

    property Index: Cardinal read FIndex; // 1 based value
    property SegClassType: TDebugInfoSegmentClass read FSegClassType;
    property Name: string read FName write FName;
    property Offset: TDebugInfoOffset read FOffset write SetOffset;
    property Size: TDebugInfoOffset read FSize write SetSize;
    property Characteristics: Cardinal read FCharacteristics write FCharacteristics; // TODO
    // Class name as specified in map file. Might not correspond to SegClassType.
    property SegClassName: string read FSegClassName write FSegClassName;
  end;

  TDebugInfoSegments = class
  private
    FSegments: TDictionary<Cardinal, TDebugInfoSegment>;
    FNames: TDictionary<string, TDebugInfoSegment>;
    FOrdered: TList<TDebugInfoSegment>; // Segments ordered by Segment.Index
  protected
    function GetCount: integer;
    function GetSegment(AIndex: Cardinal): TDebugInfoSegment;
  public
    constructor Create;
    destructor Destroy; override;

    function Add(AIndex: Cardinal; const AName: string; AClassType: TDebugInfoSegmentClass = sctDATA): TDebugInfoSegment;
    function FindByIndex(AIndex: Cardinal): TDebugInfoSegment;
    function FindByName(const AName: string): TDebugInfoSegment;
    function FindByOffset(AOffset: TDebugInfoOffset): TDebugInfoSegment;
    function FindByClassName(const AClassName: string): TDebugInfoSegment;

    property Count: integer read GetCount;
    property Segments[Index: Cardinal]: TDebugInfoSegment read GetSegment; default;

    // The enumerator is guaranteed to return the segments in index order
    function GetEnumerator: TEnumerator<TDebugInfoSegment>;
  end;


  TDebugInfoSourceFile = class
  private
    FFilename: string;
  public
    constructor Create(const AFilename: string);

    property Filename: string read FFilename;
  end;

  TDebugInfoSourceFiles = class
  private type
    TDebugInfoSourceFileList = TObjectDictionary<string, TDebugInfoSourceFile>;
  private
    FSourceFiles: TDebugInfoSourceFileList;
    FOwner: TDebugInfo;
  protected
    function GetCount: integer;
  public
    constructor Create(AOwner: TDebugInfo = nil);
    destructor Destroy; override;

    function Add(const AFilename: string): TDebugInfoSourceFile;
    function First: TDebugInfoSourceFile;
    function Contains(SourceFile: TDebugInfoSourceFile): boolean; // Expensive!

    property Count: integer read GetCount;

    function GetEnumerator: TEnumerator<TDebugInfoSourceFile>;
  end;


  TDebugInfoSourceLine = class
  private
    FSourceFile: TDebugInfoSourceFile;
    FModule: TDebugInfoModule;
    FLineNumber: integer;
    FOffset: TDebugInfoOffset;
  protected
    function GetAddress: TDebugInfoOffset;
  public
    property Module: TDebugInfoModule read FModule write FModule;
    property SourceFile: TDebugInfoSourceFile read FSourceFile write FSourceFile;
    property LineNumber: integer read FLineNumber write FLineNumber;
    // Offset is relative to module
    property Offset: TDebugInfoOffset read FOffset write FOffset;

    // Address = Line.Offset + Line.Module.Offset + Line.Module.Segment.Offset
    property Address: TDebugInfoOffset read GetAddress;
  end;

  TDebugInfoSourceLines = class
  private
    FModule: TDebugInfoModule;
    FSourceLines: TObjectList<TDebugInfoSourceLine>;
    FComparer: IComparer<TDebugInfoSourceLine>;
  protected
    function GetCount: integer;
    function GetEmpty: boolean;
  public
    constructor Create(AModule: TDebugInfoModule);
    destructor Destroy; override;

    function Add(ASourceFile: TDebugInfoSourceFile; ALineNumber: integer; AOffset: TDebugInfoOffset): TDebugInfoSourceLine;

    property Count: integer read GetCount;
    property Empty: boolean read GetEmpty;

    function GetEnumerator: TEnumerator<TDebugInfoSourceLine>;
  end;


  TDebugInfoSymbol = class
  private
    FModule: TDebugInfoModule;
    FName: string;
    FOffset: TDebugInfoOffset;
    FSize: TDebugInfoOffset;
  protected
    function GetAddress: TDebugInfoOffset;
  public
    constructor Create(AModule: TDebugInfoModule; const AName: string; AOffset: TDebugInfoOffset);

    property Module: TDebugInfoModule read FModule write FModule;
    property Name: string read FName write FName;
    // Offset is relative to module
    property Offset: TDebugInfoOffset read FOffset;
    property Size: TDebugInfoOffset read FSize write FSize;

    // Address = Symbol.Offset + Symbol.Module.Offset + Symbol.Module.Segment.Offset
    property Address: TDebugInfoOffset read GetAddress;
  end;

  TDebugInfoSymbols = class
  private type
    TDebugInfoSymbolList = TObjectList<TDebugInfoSymbol>;
  private
    FModule: TDebugInfoModule;
    FSymbols: TDebugInfoSymbolList;
  protected
    function GetCount: integer;
  public
    constructor Create(AModule: TDebugInfoModule);
    destructor Destroy; override;

    function Add(const AName: string; AOffset: TDebugInfoOffset): TDebugInfoSymbol;

    procedure CalculateSizes;

    property Count: integer read GetCount;

    function GetEnumerator: TEnumerator<TDebugInfoSymbol>;
  end;


  TDebugInfoModule = class
  private
    FDebugInfo: TDebugInfo;
    FName: string;
    FObjectName: string;
    FSegment: TDebugInfoSegment;
    FOffset: TDebugInfoOffset;
    FSize: TDebugInfoOffset;
    FSourceFiles: TDebugInfoSourceFiles;
    FSourceLines: TDebugInfoSourceLines;
    FSymbols: TDebugInfoSymbols;
  protected
    function GetObjectName: string;
    function GetAddress: TDebugInfoOffset;
  public
    constructor Create(ADebugInfo: TDebugInfo; const AName: string; ASegment: TDebugInfoSegment; AOffset, ASize: TDebugInfoOffset);
    destructor Destroy; override;

    procedure CalculateSize;

    property DebugInfo: TDebugInfo read FDebugInfo;

    property Name: string read FName;
    property ObjectName: string read GetObjectName write FObjectName;
    property Segment: TDebugInfoSegment read FSegment;
    // Offset is relative to segment
    property Offset: TDebugInfoOffset read FOffset;
    property Size: TDebugInfoOffset read FSize;

    // Address = Module.Offset + Module.Segment.Offset
    property Address: TDebugInfoOffset read GetAddress;

    property SourceFiles: TDebugInfoSourceFiles read FSourceFiles;
    property SourceLines: TDebugInfoSourceLines read FSourceLines;
    property Symbols: TDebugInfoSymbols read FSymbols;
  end;

  TDebugInfoModules = class
  private type
    TDebugInfoModuleList = TObjectList<TDebugInfoModule>;
  private
    FDebugInfo: TDebugInfo;
    FModules: TDebugInfoModuleList;
    FComparer: IComparer<TDebugInfoModule>;
  protected
    function GetModule(Index: integer): TDebugInfoModule;
    function GetCount: integer;
    function GetEmpty: boolean;
  public
    constructor Create(ADebugInfo: TDebugInfo);
    destructor Destroy; override;

    function Add(const AName: string; ASegment: TDebugInfoSegment; AOffset, ASize: TDebugInfoOffset): TDebugInfoModule;
    procedure Remove(Module: TDebugInfoModule);

    function FindByName(const AName: string; ASegment: TDebugInfoSegment): TDebugInfoModule;
    function FindByOffset(ASegment: TDebugInfoSegment; AOffset: TDebugInfoOffset): TDebugInfoModule;
    function FindOverlap(ASegment: TDebugInfoSegment; AOffset, ASize: TDebugInfoOffset): TDebugInfoModule;

    property Modules[Index: integer]: TDebugInfoModule read GetModule; default;
    property Count: integer read GetCount;
    property Empty: boolean read GetEmpty;

    function GetEnumerator: TEnumerator<TDebugInfoModule>;
  end;


  TDebugInfo = class
  private
    FSegments: TDebugInfoSegments;
    FModules: TDebugInfoModules;
    FSourceFiles: TDebugInfoSourceFiles;
  public
    constructor Create;
    destructor Destroy; override;

    property Segments: TDebugInfoSegments read FSegments;
    property Modules: TDebugInfoModules read FModules;
    property SourceFiles: TDebugInfoSourceFiles read FSourceFiles;
  end;

type
  EDebugInfo = class(Exception);


implementation

uses
  Winapi.Windows,
  System.Math;

{ TDebugInfo }

constructor TDebugInfo.Create;
begin
  inherited Create;

  FSegments := TDebugInfoSegments.Create;
  FModules := TDebugInfoModules.Create(Self);
  FSourceFiles := TDebugInfoSourceFiles.Create;
end;

destructor TDebugInfo.Destroy;
begin
  FSegments.Free;
  FModules.Free;
  FSourceFiles.Free;

  inherited;
end;

{ TDebugInfoModule }

constructor TDebugInfoModule.Create(ADebugInfo: TDebugInfo; const AName: string; ASegment: TDebugInfoSegment; AOffset, ASize: TDebugInfoOffset);
begin
  inherited Create;

  FDebugInfo := ADebugInfo;

  FName := AName;
  FSegment := ASegment;
  FOffset := AOffset;
  FSize := ASize;

  FSourceFiles := TDebugInfoSourceFiles.Create(FDebugInfo);
  FSourceLines := TDebugInfoSourceLines.Create(Self);
  FSymbols := TDebugInfoSymbols.Create(Self);
end;

destructor TDebugInfoModule.Destroy;
begin
  FSourceLines.Free;
  FSourceFiles.Free;
  FSymbols.Free;

  inherited;
end;

function TDebugInfoModule.GetAddress: TDebugInfoOffset;
begin
  Result := Segment.Offset + Offset;
end;

function TDebugInfoModule.GetObjectName: string;
begin
  Result := FObjectName;
  if (Result = '') then
    Result := FName;;
end;

procedure TDebugInfoModule.CalculateSize;
begin
  // Determine max size of module
  var MaxModuleSize := FSize;
  for var SourceLine in FSourceLines do
    MaxModuleSize := Max(MaxModuleSize, SourceLine.Offset);

  for var Symbol in FSymbols do
    MaxModuleSize := Max(MaxModuleSize, Symbol.Offset + Symbol.Size);

  FSize := MaxModuleSize;
end;

{ TDebugInfoSymbols }

procedure TDebugInfoSymbols.CalculateSizes;
begin
  for var i := 0 to FSymbols.Count-2 do
    FSymbols[i].Size := FSymbols[i+1].Offset - FSymbols[i].Offset;

  // Assume last symbol extends to end of module
  if (FSymbols.Count > 0) then
    FSymbols[FSymbols.Count-1].Size := FModule.Size - FSymbols[FSymbols.Count-1].Offset;
end;

constructor TDebugInfoSymbols.Create(AModule: TDebugInfoModule);
begin
  inherited Create;

  FModule := AModule;
  FSymbols := TDebugInfoSymbolList.Create(True);
end;

destructor TDebugInfoSymbols.Destroy;
begin
  FSymbols.Free;

  inherited;
end;

function TDebugInfoSymbols.GetCount: integer;
begin
  Result := FSymbols.Count;
end;

function TDebugInfoSymbols.GetEnumerator: TEnumerator<TDebugInfoSymbol>;
begin
  Result := FSymbols.GetEnumerator;
end;

function TDebugInfoSymbols.Add(const AName: string; AOffset: TDebugInfoOffset): TDebugInfoSymbol;
begin
  // Binary search
  var L := 0;
  var H := FSymbols.Count-1;

  while (L <= H) do
  begin
    var mid := L + (H - L) shr 1;

    var Symbol := FSymbols[mid];

    if (AOffset < Symbol.Offset) then
      H := mid - 1
    else
    if (AOffset >= Symbol.Offset) then
      L := mid + 1
    else
    begin
      // Return existing if we have an exact duplicate of Name+Offset
      if (Symbol.Name = AName) then
        Exit(Symbol);

      // Disallow duplicate offset but don't fail
      Exit(nil);
    end;
  end;

  Result := TDebugInfoSymbol.Create(FModule, AName, AOffset);
  FSymbols.Insert(L, Result);
end;

{ TDebugInfoModules }

function TDebugInfoModules.Add(const AName: string; ASegment: TDebugInfoSegment; AOffset, ASize: TDebugInfoOffset): TDebugInfoModule;
begin
  Result := TDebugInfoModule.Create(FDebugInfo, AName, ASegment, AOffset, ASize);
  try

    var Index: integer;
    if (FModules.BinarySearch(Result, Index, FComparer)) then
      raise EDebugInfo.Create('Cannot add overlapping modules');

    FModules.Insert(Index, Result);

  except
    Result.Free;
    raise;
  end;
end;

constructor TDebugInfoModules.Create(ADebugInfo: TDebugInfo);
begin
  inherited Create;

  FDebugInfo := ADebugInfo;
  FModules := TDebugInfoModuleList.Create(True);
  FComparer := IComparer<TDebugInfoModule>(
    function(const Left, Right: TDebugInfoModule): Integer
    begin
      Result := integer(Left.Segment.Index) - integer(Right.Segment.Index);
      if (Result = 0) then
        Result := integer(Left.Offset) - integer(Right.Offset); // Cast to avoid integer overflow
    end);
end;

destructor TDebugInfoModules.Destroy;
begin
  FModules.Free;

  inherited;
end;

function TDebugInfoModules.FindByName(const AName: string; ASegment: TDebugInfoSegment): TDebugInfoModule;
begin
  for var Module in FModules do
    if (Module.Segment = ASegment) and (Module.Name = AName) then
      Exit(Module);
  Result := nil;
end;

function TDebugInfoModules.FindByOffset(ASegment: TDebugInfoSegment; AOffset: TDebugInfoOffset): TDebugInfoModule;
begin
  // Binary search
  var L := 0;
  var H := FModules.Count-1;

  while (L <= H) do
  begin
    var mid := L + (H - L) shr 1;

    var Module := FModules[mid];

    if (ASegment.Index < Module.Segment.Index) then
      H := mid - 1
    else
    if (ASegment.Index > Module.Segment.Index) then
      L := mid + 1
    else
    begin
      if (AOffset < Module.Offset) then
        H := mid - 1
      else
      if (AOffset >= Module.Offset+Module.Size) then
        L := mid + 1
      else
        Exit(Module);
    end;
  end;

  Result := nil;
end;

function TDebugInfoModules.FindOverlap(ASegment: TDebugInfoSegment; AOffset, ASize: TDebugInfoOffset): TDebugInfoModule;
begin
  // Binary search
  var L := 0;
  var H := FModules.Count-1;

  while (L <= H) do
  begin
    var mid := L + (H - L) shr 1;

    var Module := FModules[mid];

    if (ASegment.Index < Module.Segment.Index) then
      H := mid - 1
    else
    if (ASegment.Index > Module.Segment.Index) then
      L := mid + 1
    else
    begin
      if (AOffset < Module.Offset) then
      begin
        if (AOffset+ASize < Module.Offset) then
          H := mid - 1
        else
          Exit(Module);
      end else
      if (AOffset >= Module.Offset+Module.Size) then
        L := mid + 1
      else
        Exit(Module);
    end;
  end;

  Result := nil;
end;

function TDebugInfoModules.GetCount: integer;
begin
  Result := FModules.Count;
end;

function TDebugInfoModules.GetEmpty: boolean;
begin
  Result := (FModules.Count = 0);
end;

function TDebugInfoModules.GetEnumerator: TEnumerator<TDebugInfoModule>;
begin
  Result := FModules.GetEnumerator;
end;

function TDebugInfoModules.GetModule(Index: integer): TDebugInfoModule;
begin
  Result := FModules[Index];
end;

procedure TDebugInfoModules.Remove(Module: TDebugInfoModule);
begin
  FModules.Remove(Module);
end;

{ TDebugInfoSymbol }

constructor TDebugInfoSymbol.Create(AModule: TDebugInfoModule; const AName: string; AOffset: TDebugInfoOffset);
begin
  inherited Create;

  FModule := AModule;
  FName := AName;
  FOffset := AOffset;
end;

function TDebugInfoSymbol.GetAddress: TDebugInfoOffset;
begin
  Result := Module.Address + Offset;
end;

{ TDebugInfoSegments }

constructor TDebugInfoSegments.Create;
begin
  inherited Create;

  FSegments := TObjectDictionary<Cardinal, TDebugInfoSegment>.Create([doOwnsValues]);
  FNames := TDictionary<string, TDebugInfoSegment>.Create;
  FOrdered := TList<TDebugInfoSegment>.Create(TComparer<TDebugInfoSegment>.Construct(
    function(const A, B: TDebugInfoSegment): integer
    begin
      Result := integer(Int64(A.Index) - Int64(B.Index));
    end));
end;

destructor TDebugInfoSegments.Destroy;
begin
  FNames.Free;
  FSegments.Free;
  FOrdered.Free;

  inherited;
end;

function TDebugInfoSegments.Add(AIndex: Cardinal; const AName: string; AClassType: TDebugInfoSegmentClass): TDebugInfoSegment;
begin
  if (AIndex = 0) then
    raise EDebugInfo.CreateFmt('Invalid Segment index: %d', [AIndex]);

  if (FSegments.ContainsKey(AIndex)) then
    raise EDebugInfo.CreateFmt('Duplicate Segment index: %d', [AIndex]);

  if (FNames.ContainsKey(AName)) then
    raise EDebugInfo.CreateFmt('Duplicate Segment name: %s', [AName]);

  Result := TDebugInfoSegment.Create(Self, AIndex, AName, AClassType);

  FSegments.Add(AIndex, Result);
  FNames.Add(AName, Result);
  var Index: integer;
  FOrdered.BinarySearch(Result, Index);
  FOrdered.Insert(Index, Result);
end;

function TDebugInfoSegments.FindByName(const AName: string): TDebugInfoSegment;
begin
  if (not FNames.TryGetValue(AName, Result)) then
    Result := nil;
end;

function TDebugInfoSegments.FindByIndex(AIndex: Cardinal): TDebugInfoSegment;
begin
  if (AIndex = 0) then
    raise EDebugInfo.CreateFmt('Invalid Segment index: %d', [AIndex]);

  if (not FSegments.TryGetValue(AIndex, Result)) then
    Result := nil;
end;

function TDebugInfoSegments.GetCount: integer;
begin
  Result := FSegments.Count;
end;

function TDebugInfoSegments.GetEnumerator: TEnumerator<TDebugInfoSegment>;
begin
  Result := FOrdered.GetEnumerator;
end;

function TDebugInfoSegments.GetSegment(AIndex: Cardinal): TDebugInfoSegment;
begin
  if (not FSegments.TryGetValue(AIndex, Result)) then
    raise EDebugInfo.CreateFmt('Segment index does not exist: %d', [AIndex]);
end;

function TDebugInfoSegments.FindByOffset(AOffset: TDebugInfoOffset): TDebugInfoSegment;
begin
  for Result in FOrdered do
    if (AOffset >= Result.Offset) and (AOffset < Result.Offset+Result.Size) then
      Exit;

  Result := nil;
end;

function TDebugInfoSegments.FindByClassName(const AClassName: string): TDebugInfoSegment;
begin
  for Result in FOrdered do
    if (SameText(AClassName, Result.SegClassName)) then
      Exit;

  Result := nil;
end;

{ TDebugInfoSegment }

constructor TDebugInfoSegment.Create(AOwner: TDebugInfoSegments; AIndex: Cardinal; const AName: string; AClassType: TDebugInfoSegmentClass);
begin
  inherited Create;

  FOwner := AOwner;
  FIndex := AIndex;
  FName := AName;
  FSegClassType := AClassType;

  FCharacteristics := IMAGE_SCN_MEM_READ;
  if (AClassType = sctCODE) then
    FCharacteristics := FCharacteristics or IMAGE_SCN_MEM_EXECUTE or IMAGE_SCN_CNT_CODE;
end;

class function TDebugInfoSegment.GuessClassType(const AName: string): TDebugInfoSegmentClass;
type
  TSectionName = record
    Name: string;
    SegmentClass: TDebugInfoSegmentClass;
  end;
const
  CommonNames: array[0..5] of TSectionName = (
    (Name: 'CODE';      SegmentClass: sctCODE),
    (Name: 'ICODE';     SegmentClass: sctICODE),
    (Name: 'DATA';      SegmentClass: sctDATA),
    (Name: 'BSS';       SegmentClass: sctDATA),
    (Name: 'PDATA';     SegmentClass: sctDATA),
    (Name: 'TLS';       SegmentClass: sctTLS)
  );
begin
  for var i := 0 to High(CommonNames) do
    if (SameText(CommonNames[i].Name, AName)) then
      Exit(CommonNames[i].SegmentClass);
  Result := sctDATA;
end;

procedure TDebugInfoSegment.SetOffset(const Value: TDebugInfoOffset);
begin
  FOffset := Value;
  CheckOverlap;
end;

procedure TDebugInfoSegment.SetSize(const Value: TDebugInfoOffset);
begin
  FSize := Value;
  CheckOverlap;
end;

function TDebugInfoSegment.FindOverlap(AIgnoredClassTypes: TDebugInfoSegmentClasses): TDebugInfoSegment;
begin
  Result := nil;

  if (Size = 0) then
    Exit;

  if (SegClassType in AIgnoredClassTypes) then
    Exit;

  for var Segment in FOwner do
  begin
    // Ignore self and empty segments
    if (Segment = Self) or (Segment.Size = 0) then
      continue;

    if (Segment.SegClassType in AIgnoredClassTypes) then
      continue;

    if ((Offset >= Segment.Offset) and (Offset < Segment.Offset+Segment.Size)) or // Start is within other range
      ((Offset+Size <= Segment.Offset) and (Offset+Size > Segment.Offset+Segment.Size)) or // Start is within other range
      ((Offset <= Segment.Offset) and (Offset+Size > Segment.Offset)) then // Other is within range
      Exit(Segment);
  end;
end;

procedure TDebugInfoSegment.CheckOverlap;
begin
  // Ignore overlap in .tls segment; Delphi is known to produce map files with invalid .tls segment offset.
  var OverlappingSegment := FindOverlap([sctTLS]);

  if (OverlappingSegment <> nil) then
    raise EDebugInfo.CreateFmt('Overlapping segments: %s [%.4X:%.16X] and %s [%.4X:%.16X]',
      [Self.Name, Self.Index, Self.Offset, OverlappingSegment.Name, OverlappingSegment.Index, OverlappingSegment.Offset]);
end;

{ TDebugInfoSourceFile }

constructor TDebugInfoSourceFile.Create(const AFilename: string);
begin
  inherited Create;

  FFilename := AFilename;
end;

{ TDebugInfoSourceFiles }

function TDebugInfoSourceFiles.Add(const AFilename: string): TDebugInfoSourceFile;
begin
  if (FOwner <> nil) then
  begin
    // Delegate lookup/creation to owner...
    Result := FOwner.SourceFiles.Add(AFilename);

    // ... and add result to local list
    FSourceFiles.AddOrSetValue(AFilename, Result);
  end else
  if (not FSourceFiles.TryGetValue(AFilename, Result)) then
  begin
    Result := TDebugInfoSourceFile.Create(AFilename);
    FSourceFiles.Add(AFilename, Result);
  end;
end;

function TDebugInfoSourceFiles.Contains(SourceFile: TDebugInfoSourceFile): boolean;
begin
  Result := FSourceFiles.ContainsValue(SourceFile);
end;

constructor TDebugInfoSourceFiles.Create(AOwner: TDebugInfo);
begin
  inherited Create;

  FOwner := AOwner;

  // If Owner=nil then we own the values
  var Ownerships: TDictionaryOwnerships;
  if (FOwner = nil) then
    Ownerships:= [doOwnsValues]
  else
    Ownerships:= [];

  FSourceFiles := TDebugInfoSourceFileList.Create(Ownerships);
end;

destructor TDebugInfoSourceFiles.Destroy;
begin
  FSourceFiles.Free;

  inherited;
end;

function TDebugInfoSourceFiles.First: TDebugInfoSourceFile;
begin
  // It's more efficient to create an enumerator than to access the Values array
  if (FSourceFiles.Count > 0) then
    for var Pair in FSourceFiles do
      Exit(Pair.Value);

  Result := nil;
end;

function TDebugInfoSourceFiles.GetCount: integer;
begin
  Result := FSourceFiles.Count;
end;

function TDebugInfoSourceFiles.GetEnumerator: TEnumerator<TDebugInfoSourceFile>;
begin
  Result := FSourceFiles.Values.GetEnumerator;
end;

{ TDebugInfoSourceLines }

function TDebugInfoSourceLines.Add(ASourceFile: TDebugInfoSourceFile; ALineNumber: integer;
  AOffset: TDebugInfoOffset): TDebugInfoSourceLine;
begin
  Result := TDebugInfoSourceLine.Create;

  Result.Module := FModule;
  Result.SourceFile := ASourceFile;
  Result.LineNumber := ALineNumber;
  Result.Offset := AOffset;

  // Note that multiple offsets can map to the same Source File+Line Number.
  // This can for example be caused by include files, inlining and generics
  // expansion.

  var Index: integer;
  if (not FSourceLines.BinarySearch(Result, Index, FComparer)) then
    FSourceLines.Insert(Index, Result)
  else
    Result.Free;
end;

constructor TDebugInfoSourceLines.Create(AModule: TDebugInfoModule);
begin
  inherited Create;

  FModule := AModule;
  FSourceLines := TObjectList<TDebugInfoSourceLine>.Create(True);

  // Order lines by SourceFile, LineNumber, Offset
  FComparer := IComparer<TDebugInfoSourceLine>(
    function(const Left, Right: TDebugInfoSourceLine): integer
    begin
      Result := NativeInt(Left.SourceFile)-NativeInt(Right.SourceFile);

      if (Result = 0) then
        Result := Left.LineNumber - Right.LineNumber;

      if (Result = 0) then
        Result := integer(Left.Offset) - integer(Right.Offset);
    end);
end;

destructor TDebugInfoSourceLines.Destroy;
begin
  FSourceLines.Free;

  inherited;
end;

function TDebugInfoSourceLines.GetCount: integer;
begin
  Result := FSourceLines.Count;
end;

function TDebugInfoSourceLines.GetEmpty: boolean;
begin
  Result := (FSourceLines.Count = 0);
end;

function TDebugInfoSourceLines.GetEnumerator: TEnumerator<TDebugInfoSourceLine>;
begin
  Result := FSourceLines.GetEnumerator;
end;

{ TDebugInfoSourceLine }

function TDebugInfoSourceLine.GetAddress: TDebugInfoOffset;
begin
  Result := Offset + Module.Offset + Module.Segment.Offset
end;

end.

