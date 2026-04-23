unit debug.info.msf;

(*
 * Copyright (c) 2021 Anders Melander
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *)

interface

{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}
{$SCOPEDENUMS ON}

{-$define MSF_OFFSET_ROUNDTRIP}  // Define to verify that Logical/Physical offset calculations can roundtrip
{-$define MSF_POISON}            // Define to write MSF poison padding

uses
  System.Generics.Collections,
  System.Classes,
  debug.info.pdb;


// -----------------------------------------------------------------------------
//
//      TBinaryBlockWriter
//
// -----------------------------------------------------------------------------
// A binary writer with block knowledge.
// -----------------------------------------------------------------------------
type
  TBinaryBlockWriter = class
  private type
    TBlockWriterBookmark = record
    private
      FWriter: TBinaryBlockWriter;
      FPosition: Int64; // Physical position
      function GetPosition: Int64;
    public
      // Return a new bookmark for the current position and restore the saved position
      function Restore: TBlockWriterBookmark;
      // Logical position
      property Position: Int64 read GetPosition;
    end;
  strict private
    FBlockSize: Cardinal;
    FIntervalSize: Cardinal;
    FStream: TStream;
    FStreamSize: Int64; // Cached/calculated Stream.Size to avoid flushing TBufferedFileStream buffers
  strict private
    function GetBlockCount: Cardinal;
    function GetIntervalIndex: Cardinal;
    function GetBlockIndex: Cardinal;
    procedure SetBlockIndex(const Value: Cardinal);
    function GetPosition: Int64;
    procedure SetPosition(const Value: Int64);
  protected
    procedure WriteBlockMap;
{$ifdef MSF_OFFSET_ROUNDTRIP}
    class function DoLogicalToPhysicalOffset(Offset: Int64; BlockSize: Cardinal): Int64;
    class function DoPhysicalToLogicalOffset(Offset: Int64; BlockSize: Cardinal): Int64;
{$endif MSF_OFFSET_ROUNDTRIP}
    class function LogicalToPhysicalOffset(Offset: Int64; BlockSize: Cardinal): Int64; overload;
    function LogicalToPhysicalOffset(Offset: Int64): Int64; overload;
    class function PhysicalToLogicalOffset(Offset: Int64; BlockSize: Cardinal): Int64; overload;
    function PhysicalToLogicalOffset(Offset: Int64): Int64; overload;
  public
    constructor Create(AStream: TStream; ABlockSize: Cardinal);

    // Logical seek
    function Seek(Offset: Int64; Origin: TSeekOrigin): Int64;

    // Write Bytes, Words and DWords
    procedure Write(Value: Byte); overload;
    procedure Write(Value: Word); overload;
    procedure Write(Value: Cardinal); overload;
    // Writes strings as zero terminated ansi strings. Does not write the length byte/word
    procedure Write(const Str: string); overload;
    procedure Write(const Str: AnsiString); overload;
    // Write a record (or any other typed value)
    procedure Write<T>(const Value: T); overload;
    // Write a dynamic array
    procedure WriteArray<T>(const Values: TArray<T>);
    // Write arbitrary untyped data
    procedure WriteBuffer(const Buffer; Count: NativeInt);

    function BeginBlock(Poison: boolean = False): Cardinal;
    procedure EndBlock(Expand: boolean = False);

    function PadToAligment(Alignment: Cardinal; Poison: boolean = False): Int64; // Returns amount written
    function WritePadding(DesiredPos: Int64; Poison: boolean = False): Int64; // Returns amount written

    function SaveBookmark: TBlockWriterBookmark;

    property BlockSize: Cardinal read FBlockSize;
    property BlockCount: Cardinal read GetBlockCount;
    property BlockIndex: Cardinal read GetBlockIndex write SetBlockIndex;
    property IntervalIndex: Cardinal read GetIntervalIndex;
    // Logical position
    property Position: Int64 read GetPosition write SetPosition;
  end;


// -----------------------------------------------------------------------------
//
//      TMSFStream
//
// -----------------------------------------------------------------------------
// Encapsulates a MSF stream
// -----------------------------------------------------------------------------
type
  TMSFFile = class;

  // Take care when writing stream index values as some places we write the values
  // as DWORDs (e.g. hash tables).
  TMSFStreamIndex = Word;

  TMSFStreamState = (
    ssAllocated,        // Stream has been allocated
    ssIndex,            // A stream index has been assigned
    ssOpen,             // Stream has been opened
    ssClosed            // Stream has been closed
  );

  TMSFStream = class
  public
    const NullBlockIndex = $FFFFFFFF;
    const NullStreamIndex: TMSFStreamIndex = $FFFF;
  strict private
    FMSFFile: TMSFFile;
    FWriter: TBinaryBlockWriter;
    FState: TMSFStreamState;
    FIndex: TMSFStreamIndex;
    FBlockIndex: Cardinal;
    FLength: Cardinal;
    FOffset: Int64;
  strict private
    function GetIsFixed: boolean;
    function GetIsValid: boolean;
    function GetIndex: TMSFStreamIndex;
    function GetWriter: TBinaryBlockWriter;
    function GetHasIndex: boolean;
  public
    constructor Create(AMSFFile: TMSFFile);

    // Opens the stream.
    // Returns the start block index of the stream (same as the BlockIndex property).
    function BeginStream(Poison: boolean = False): Cardinal;

    // Closes the stream.
    // Returns the size of data written to the stream (same as the Length property).
    function EndStream: Cardinal;

    // Mark the stream in-use.
    // This ensures that the stream index is allocated and that the stream
    // will be persisted in the directory even if the stream hasn't been opened
    // or written to.
    procedure Touch;

    property Writer: TBinaryBlockWriter read GetWriter;

    // Stream index
    property Index: TMSFStreamIndex read GetIndex;

    // Logical start byte offset within MSF file
    property Offset: Int64 read FOffset;
    // Logical length of stream in bytes
    property Length: Cardinal read FLength;
    // Physical start MSF block index
    property BlockIndex: Cardinal read FBlockIndex;

    // IsFixed: True if stream is one of the fixed streams
    property IsFixed: boolean read GetIsFixed;
    // IsValid: True if stream has been opened or the Index value referenced
    property IsValid: boolean read GetIsValid;

    property HasIndex: boolean read GetHasIndex;
    property State: TMSFStreamState read FState;
  end;


// -----------------------------------------------------------------------------
//
//      TMSFFile
//
// -----------------------------------------------------------------------------
// Encapsulates a MSF container file
// -----------------------------------------------------------------------------
  TMSFFile = class
  public
    const DefaultBlockSize = 4096;
  strict private type
    TFileState = (fsInit, fsOpen, fsClosed);
  strict private
    FState: TFileState;
    FStreams: TList<TMSFStream>;
    FWriter: TBinaryBlockWriter;
    FBlockSize: Cardinal;
    FCurrentStream: TMSFStream;
    FNextStreamIndex: TMSFStreamIndex;
  strict private
    procedure WriteSuperBlock(var MSFSuperBlock: TMSFSuperBlock; IndexStream, DirectoryStream: TMSFStream);
    procedure WriteStreamBlockList(Writer: TBinaryBlockWriter; Stream: TMSFStream);
    procedure WriteDirectoryIndex(IndexStream, DirectoryStream: TMSFStream);
    procedure WriteDirectory(DirectoryStream: TMSFStream);
    procedure WriteFreeBlockMap(const MSFSuperBlock: TMSFSuperBlock);

    function GetCount: integer;
    function GetStream(Index: TMSFStreamIndex): TMSFStream;
    function GetFixedStream(Index: PDBStreamIndex): TMSFStream;
  protected

    function BeginStream(Stream: TMSFStream): TBinaryBlockWriter;
    procedure EndStream(Stream: TMSFStream);

    function AllocateStreamIndex: TMSFStreamIndex;
  public
    constructor Create(AStream: TStream; ABlockSize: Cardinal);
    destructor Destroy; override;

    procedure BeginFile;
    procedure EndFile;

    function AllocateStream: TMSFStream;

    property Writer: TBinaryBlockWriter read FWriter;
    property CurrentStream: TMSFStream read FCurrentStream;

    property Count: integer read GetCount;
    property Streams[Index: TMSFStreamIndex]: TMSFStream read GetStream; default;
    property FixedStreams[Index: PDBStreamIndex]: TMSFStream read GetFixedStream;

    function GetEnumerator: TEnumerator<TMSFStream>;
  end;


// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------

implementation

uses
  System.Generics.Defaults,
  System.Math;


// -----------------------------------------------------------------------------
//
//      TMSFFile
//
// -----------------------------------------------------------------------------
constructor TMSFFile.Create(AStream: TStream; ABlockSize: Cardinal);
begin
  inherited Create;

  FBlockSize := ABlockSize;
  FStreams := TObjectList<TMSFStream>.Create(True);
  FWriter := TBinaryBlockWriter.Create(AStream, FBlockSize);
end;

destructor TMSFFile.Destroy;
begin
  FWriter.Free;
  FStreams.Free;

  inherited;
end;

function TMSFFile.AllocateStreamIndex: TMSFStreamIndex;
begin
  Result := FNextStreamIndex;
  Inc(FNextStreamIndex);
end;

procedure TMSFFile.BeginFile;
begin
  Assert(FState = TFileState.fsInit);
  FState := TFileState.fsOpen;


  // Preallocate the fixed streams so their indices aren't used by other streams
  for var StreamIndex := Low(PDBStreamIndex) to High(PDBStreamIndex) do
    // Allocate and touch the stream so the stream index is assigned
    AllocateStream.Touch;


  // The MSF Superblock occupies block #0 - we write that last so skip it now
  FWriter.BlockIndex := 1;


  // Write the two Free Block Maps (FBM). Block #1 and #2
  FWriter.WriteBlockMap;
  Assert(FWriter.BlockIndex = 2);

  FWriter.WriteBlockMap;
  Assert(FWriter.BlockIndex = 3);

  // FPM (or FBM) = Free Page Map (or Free Block Map)
  //
  // The FPM exists either at block 1 or block 2 of the MSF.  However, this
  // allows for a maximum of BlockSize * 8 blocks bits in the FPM, and
  // thusly an equal number of total blocks in the file.  For a block size
  // of 4Kb (very common), this would yield 32Kb total blocks in file, for a
  // maximum file size of 32Kb * 4Kb = 128Mb.  Obviously this won't do, so
  // the FPM is split across the file at `BlockSize` intervals.  As a
  // result, every block whose index is of the form |{1,2} + BlockSize * k|
  // for any non-negative integer k is an FPM block.  In theory, we only really
  // need to reserve blocks of the form |{1,2} + BlockSize * 8 * k|, but
  // current versions of the MSF format already expect the FPM to be arranged
  // at BlockSize intervals, so we have to be compatible.
  // See the function fpmPn() for more information:
  // https://github.com/Microsoft/microsoft-pdb/blob/master/PDB/msf/msf.cpp#L489

end;

procedure TMSFFile.EndFile;
begin
  Assert(FState = TFileState.fsOpen);

  Assert(FCurrentStream = nil);

  // Create streams directly so they do not appear in the stream list
  var IndexStream := TMSFStream.Create(Self);
  var DirectoryStream := TMSFStream.Create(Self);
  try

    // Sort streams in Index order for the directory
    FStreams.Sort(IComparer<TMSFStream>(
      function(const A, B: TMSFStream): integer
      begin
        if (A.HasIndex) then
        begin
          if (not B.HasIndex) then
            Exit(-1);
        end else
        if (not B.HasIndex) then
          Exit(1);

        // Both indices are valid
        Result := integer(A.Index) - integer(B.Index);
      end));


    // Now that all other streams have been written we can write the MSF directory stream.
    WriteDirectory(DirectoryStream);


    // Write a pointer to the directory stream.
    // The MSF Superblock will point to this stream.
    WriteDirectoryIndex(IndexStream, DirectoryStream);


    // The above was the last block so make sure file is physically padded.
    FWriter.BeginBlock;
    FWriter.EndBlock(True);


    // Rewind and write the MSF Superblock at block #0.
    // At this point all streams, and the directory, must have been written.
    Writer.BlockIndex := 0;
    var MSFSuperBlock: TMSFSuperBlock;
    WriteSuperBlock(MSFSuperBlock, IndexStream, DirectoryStream);


    // Finally update the Free Block Map
    WriteFreeBlockMap(MSFSuperBlock);

  finally
    IndexStream.Free;
    DirectoryStream.Free;
  end;

  FState := TFileState.fsClosed;
end;

function TMSFFile.AllocateStream: TMSFStream;
begin
  Assert(FState = TFileState.fsOpen);

  Result := TMSFStream.Create(Self);

  FStreams.Add(Result);
end;

function TMSFFile.BeginStream(Stream: TMSFStream): TBinaryBlockWriter;
begin
  Assert(FState = TFileState.fsOpen);
  Assert(FCurrentStream = nil);

  FCurrentStream := Stream;

  Result := FWriter;
end;

procedure TMSFFile.EndStream(Stream: TMSFStream);
begin
  Assert(FState = TFileState.fsOpen);
  Assert(FCurrentStream = Stream);

  FCurrentStream := nil;
end;

function TMSFFile.GetCount: integer;
begin
  Result := FStreams.Count;
end;

function TMSFFile.GetEnumerator: TEnumerator<TMSFStream>;
begin
  Result := FStreams.GetEnumerator;
end;

function TMSFFile.GetFixedStream(Index: PDBStreamIndex): TMSFStream;
begin
  Result := nil;
  // The list contains streams in allocation order, not Index order.
  for var i := 0 to FStreams.Count-1 do
    if (FStreams[i].HasIndex) and (FStreams[i].Index = Word(Ord(Index))) then
      Exit(FStreams[i]);
  Assert(False);
end;

function TMSFFile.GetStream(Index: TMSFStreamIndex): TMSFStream;
begin
  Result := nil;
  // The list contains streams in allocation order, not Index order.
  for var i := 0 to FStreams.Count-1 do
    if (FStreams[i].HasIndex) and (FStreams[i].Index = Index) then
      Exit(FStreams[i]);
  Assert(False);
end;

procedure TMSFFile.WriteStreamBlockList(Writer: TBinaryBlockWriter; Stream: TMSFStream);
begin
//  Assert(Stream.BlockIndex <> TMSFStream.NullBlockIndex);

  // We take advantage of the fact that in our case all blocks within a stream are
  // contiguous (except where the stream straddles an interval boundary). That is,
  // blocks from different streams do not interleave.

  var BlockCount := Ceil(Stream.Length / FBlockSize);
  var Offset := Stream.Offset;
  while (BlockCount > 0) do
  begin
    // Convert the logical offset to a physical offset, and then the
    // physical offset to a block index.
    var PhysicalOffset: Cardinal := TBinaryBlockWriter.LogicalToPhysicalOffset(Offset, FBlockSize);
    var BlockIndex: Cardinal := PhysicalOffset div FBlockSize;

    Writer.Write(BlockIndex);

    Dec(BlockCount);
    Inc(Offset, FBlockSize);
  end;
end;

procedure TMSFFile.WriteSuperBlock(var MSFSuperBlock: TMSFSuperBlock; IndexStream, DirectoryStream: TMSFStream);
begin
  MSFSuperBlock := Default(TMSFSuperBlock);
  MSFSuperBlock.Magic := MSFMagic;
  MSFSuperBlock.BlockSize := FBlockSize;
  MSFSuperBlock.FreeBlockMapBlock := 1; // 1 or 2. In our case it's always block #1
  MSFSuperBlock.NumBlocks := FWriter.BlockCount;
  MSFSuperBlock.NumDirectoryBytes := DirectoryStream.Length;
  MSFSuperBlock.Unknown := 0;
  MSFSuperBlock.BlockMapAddr := IndexStream.BlockIndex;

  FWriter.Write<TMSFSuperBlock>(MSFSuperBlock);
end;

procedure TMSFFile.WriteFreeBlockMap(const MSFSuperBlock: TMSFSuperBlock);
begin

  // Rewind and update all FBMs so all blocks (essentially all blocks "inside"
  // the file) are marked as allocated.
  // See: WriteBlockMap

  var BlockCount := MSFSuperBlock.NumBlocks;
  var FreeBlockMapIndex := MSFSuperBlock.FreeBlockMapBlock;

  while (BlockCount > 0) do
  begin
    // Seek to update FBM
    FWriter.BlockIndex := FreeBlockMapIndex;

    var SpaceInFreeBlockMap := MSFSuperBlock.BlockSize;

    // Write chunks of 8 blocks allocated
    while (SpaceInFreeBlockMap > 0) and (BlockCount > 8) do
    begin
      FWriter.Write($00); // No bits set = 8 blocks allocated
      Dec(BlockCount, 8);
      Dec(SpaceInFreeBlockMap);
    end;

    // Still space left in FBM and more blocks to allocate?
    if (SpaceInFreeBlockMap > 0) and (BlockCount > 0) then
    begin
      // We must have less than 8 blocks remaining. Write it as an actual bit mask.
      var Mask: Byte := $FF;
      var BitMask: Word := 1; // Word to avoid overflow if BlockCount=8
      while (BlockCount > 0) do
      begin
        Mask := Mask and (not BitMask);
        BitMask := BitMask shl 1;
        Dec(BlockCount);
      end;
      FWriter.Write(Mask);
    end;

    // Move to next interval. There are <BlockSize> blocks between the FPMs.
    Inc(FreeBlockMapIndex, FBlockSize);
  end;
end;

procedure TMSFFile.WriteDirectoryIndex(IndexStream, DirectoryStream: TMSFStream);
begin
  IndexStream.BeginStream;

  // Write list of blocks of where the directory actually lives
  WriteStreamBlockList(IndexStream.Writer, DirectoryStream);

  IndexStream.EndStream;
end;

procedure TMSFFile.WriteDirectory(DirectoryStream: TMSFStream);
begin
  DirectoryStream.BeginStream;

  // Disregard streams that has been allocated but not opened (except fixed streams).

  // Number of streams
  var Count: Cardinal := 0;
  for var Stream in FStreams do
    if (Stream.IsValid) or (Stream.IsFixed) then
    begin
      Assert(Stream.State in [TMSFStreamState.ssIndex, TMSFStreamState.ssClosed]);
      Inc(Count);
    end;
  DirectoryStream.Writer.Write(Cardinal(Count));

  // Stream sizes
  for var Stream in FStreams do
    if (Stream.IsValid) or (Stream.IsFixed) then
      DirectoryStream.Writer.Write(Stream.Length);

  // Stream blocks
  for var Stream in FStreams do
    if (Stream.IsValid) then
      WriteStreamBlockList(DirectoryStream.Writer, Stream);

  DirectoryStream.EndStream;
end;


// -----------------------------------------------------------------------------
//
//      TMSFStream
//
// -----------------------------------------------------------------------------
constructor TMSFStream.Create(AMSFFile: TMSFFile);
begin
  inherited Create;

  FMSFFile := AMSFFile;
  FIndex := NullStreamIndex;
  FBlockIndex := NullBlockIndex;
end;

function TMSFStream.BeginStream(Poison: boolean): Cardinal;
begin
  Assert(FWriter = nil);
  Assert(FState in [TMSFStreamState.ssAllocated, TMSFStreamState.ssIndex]);

  Touch;

  FWriter := FMSFFile.BeginStream(Self);

  FBlockIndex := FWriter.BeginBlock(Poison);
  FOffset := FWriter.Position;
  FState := TMSFStreamState.ssOpen;

  Result := FBlockIndex;
end;

function TMSFStream.EndStream: Cardinal;
begin
  Assert(FWriter <> nil);
  Assert(FState = TMSFStreamState.ssOpen);

  FLength := Cardinal(FWriter.Position - FOffset);
  FWriter.EndBlock;

  FMSFFile.EndStream(Self);
  FWriter := nil;
  FState := TMSFStreamState.ssClosed;

  Result := FLength;
end;

function TMSFStream.GetHasIndex: boolean;
begin
  Result := (FIndex <> NullStreamIndex);
end;

function TMSFStream.GetIndex: TMSFStreamIndex;
begin
  Touch;

  Result := FIndex;
end;

function TMSFStream.GetIsFixed: boolean;
begin
  Result := (integer(FIndex) <= Ord(High(PDBStreamIndex)));
end;

function TMSFStream.GetIsValid: boolean;
begin
  Result := (FState > TMSFStreamState.ssAllocated);
end;

function TMSFStream.GetWriter: TBinaryBlockWriter;
begin
  Assert(FState = TMSFStreamState.ssOpen);
  Assert(FIndex <> NullStreamIndex);
  Assert(FBlockIndex <> NullBlockIndex);

  Result := FWriter;
end;

procedure TMSFStream.Touch;
begin
  // Stream has now been referenced. Allocate a stream index to ensure the stream will
  // be written to the directory.
  if (FIndex = NullStreamIndex) then
  begin
    Assert(FState = TMSFStreamState.ssAllocated);

    FIndex := FMSFFile.AllocateStreamIndex;
    FState := TMSFStreamState.ssIndex;
  end;

  Assert(FState >= TMSFStreamState.ssIndex);
end;


// -----------------------------------------------------------------------------
//
//      TBinaryBlockWriter
//
// -----------------------------------------------------------------------------

(*
  MSF Block and Interval layout

  Interval    |                          0                           |                    1
  ------------+------------+------+------+------+------+------+------+------+------+------+------+------+- - -
  Block index |      0     |   1  |   2  |   3  |   4  | ...  | 4095 | 4096 | 4097 | 4095 | 4096 | 4097 | ...
  ------------+------------+------+------+------+------+------+------+------+------+------+------+------+- - -
  Log block   |   0 (N/A)  | N/A  | N/A  |   1  |   2  | ...  | ...  | 4094 | N/A  | N/A  | 4095 | ...  | ...
  ------------+------------+------+------+------+------+------+------+------+------+------+------+------+- - -
  Phys offset |      0     | 4096 | 8192 |12288 |16384 | ...  | ...  |4096^2|+4096 |+8192 | ...  | ...  | ...
  ------------+------------+------+------+------+------+------+------+------+------+------+------+------+- - -
  Content     | Superblock | FPM1 | FPM2 | Data | Data | Data | Data | Data | FPM1 | FPM2 | Data | Data | Data
*)

constructor TBinaryBlockWriter.Create(AStream: TStream; ABlockSize: Cardinal);
begin
  inherited Create;

  FStream := AStream;
  FBlockSize := ABlockSize;
  FIntervalSize := FBlockSize * FBlockSize;
end;

{$ifdef MSF_OFFSET_ROUNDTRIP}
class function TBinaryBlockWriter.DoLogicalToPhysicalOffset(Offset: Int64; BlockSize: Cardinal): Int64;
begin
  Result := Offset + 2 * BlockSize * ((Offset - BlockSize) div (BlockSize * (BlockSize - 2)) + 1);
end;

class function TBinaryBlockWriter.DoPhysicalToLogicalOffset(Offset: Int64; BlockSize: Cardinal): Int64;
begin
  Result := Offset - 2 * BlockSize * ((Offset - BlockSize) div (BlockSize * BlockSize) + 1);
end;
{$endif MSF_OFFSET_ROUNDTRIP}

class function TBinaryBlockWriter.LogicalToPhysicalOffset(Offset: Int64; BlockSize: Cardinal): Int64;
begin
  (*
    For each logical Interval (4096-2 blocks), add the two FPM blocks.
    Shift the offset 1 block before calculating Interval to account for the block at the start of the interval.

                            OfsLog - Block
    OfsPhys = OfsLog + [ --------------------- +1 ] * Block * 2
                          Block * (Block - 2)
  *)

  Assert(Offset >= BlockSize, 'Invalid logical offset');
{$ifdef MSF_OFFSET_ROUNDTRIP}

  Result := DoLogicalToPhysicalOffset(Offset, BlockSize);

  Assert(Offset = DoPhysicalToLogicalOffset(Result, BlockSize), 'LogicalToPhysicalOffset roundtrip failed');

  // Physical offsets within the two FPMs have no logical mapping
  Assert((Result - BlockSize) and (BlockSize*BlockSize-1) >= 2*BlockSize);

{$else MSF_OFFSET_ROUNDTRIP}

  Result := Offset + 2 * BlockSize * ((Offset - BlockSize) div (BlockSize * (BlockSize - 2)) + 1);

{$endif MSF_OFFSET_ROUNDTRIP}
  Assert(Result >= 0);
end;

function TBinaryBlockWriter.LogicalToPhysicalOffset(Offset: Int64): Int64;
begin
  Result := LogicalToPhysicalOffset(Offset, FBlockSize);
end;

class function TBinaryBlockWriter.PhysicalToLogicalOffset(Offset: Int64; BlockSize: Cardinal): Int64;
begin
  (*
    For each physical Interval (4096 blocks), subtract the two FPM blocks.
    Shift the offset 1 block before calculating Interval to account for the block at the start of the interval.

                           OfsPhys - Block
    OfsLog = OfsPhys  - [ ----------------- +1 ] * Block * 2
                            Block * Block
  *)

  Assert(Offset >= BlockSize*3, 'Physical offset out of logical bounds');
{$ifdef MSF_OFFSET_ROUNDTRIP}

  // Physical offsets within the two FPMs have no logical mapping
  Assert((Offset - BlockSize) and (BlockSize*BlockSize-1) >= 2*BlockSize);

  Result := DoPhysicalToLogicalOffset(Offset, BlockSize);

  Assert(Offset = DoLogicalToPhysicalOffset(Result, BlockSize), 'PhysicalToLogicalOffset roundtrip failed'); // Roundtrip

{$else MSF_OFFSET_ROUNDTRIP}

  Result := Offset - 2 * BlockSize * ((Offset - BlockSize) div (BlockSize * BlockSize) + 1);

{$endif MSF_OFFSET_ROUNDTRIP}
  Assert(Result >= 0);
end;

function TBinaryBlockWriter.PhysicalToLogicalOffset(Offset: Int64): Int64;
begin
  Result := PhysicalToLogicalOffset(Offset, FBlockSize);
end;

function TBinaryBlockWriter.WritePadding(DesiredPos: Int64; Poison: boolean): Int64;
begin
  Result := DesiredPos - Position;
  Assert(Result >= 0);

  if (Result = 0) then
    Exit;

  // CodeView leaf records are either padded to 4 bytes (if this type stream appears in a TPI/IPI stream
  // of a PDB) or not padded at all (if this type stream appears in the .debug$T section of an object
  // file). Padding is implemented by inserting a decreasing sequence of bytes (LF_PAD15..LF_PAD0) that
  // terminates with LF_PAD0.

{$ifdef MSF_POISON}
  if (Poison) then
  begin
    Assert(Result <= $0F);
    var Count := Result;
    while (Count > 0) do
    begin
      Dec(Count);
      Write(Byte((Count and $0F) or $F0)); // http://moyix.blogspot.com/2007/10/types-stream.html
    end;
  end else
{$endif MSF_POISON}
    // We're allowed to seek past EOF. File will be physically expanded once we
    // actually write something or explicitly set the size.
    // Note however that if we expand the file this way and the close it with out
    // writing anything, then the file is truncated to the point where we last wrote
    // something. EndBlock(Expand=True) can be used to force the stream to be
    // expanded to the current position.
    Seek(Result, soCurrent);
  FStreamSize := Max(FStreamSize, FStream.Position);
end;

procedure TBinaryBlockWriter.WriteBlockMap;
const
  AllVacancies: Byte = $FF;
begin
  BeginBlock;
  Assert((BlockIndex mod FBlockSize) in [1, 2]);

  // Mark all BlockSize*8 blocks free
  for var i := 0 to FBlockSize-1 do
    FStream.WriteBuffer(AllVacancies, 1);

  FStreamSize := Max(FStreamSize, FStream.Position);

  EndBlock(True);
end;

procedure TBinaryBlockWriter.Write(Value: Byte);
begin
  WriteBuffer(Value, SizeOf(Value));
end;

procedure TBinaryBlockWriter.Write(Value: Word);
begin
  WriteBuffer(Value, SizeOf(Value));
end;

procedure TBinaryBlockWriter.Write(Value: Cardinal);
begin
  WriteBuffer(Value, SizeOf(Value));
end;

procedure TBinaryBlockWriter.Write<T>(const Value: T);
begin
  WriteBuffer(Value, SizeOf(T));
end;

procedure TBinaryBlockWriter.WriteArray<T>(const Values: TArray<T>);
begin
  if (Length(Values) = 0) then
    Exit;

  WriteBuffer(Values[0], Length(Values) * SizeOf(T));
end;

procedure TBinaryBlockWriter.Write(const Str: string);
begin
  // TODO : Handle UTF8 here
  if (Str <> '') then
    Write(AnsiString(Str))
  else
    Write(Byte(0));
end;

procedure TBinaryBlockWriter.Write(const Str: AnsiString);
begin
  if (Str <> '') then
    WriteBuffer(Str[1], Length(Str)+1) // Include terminating zero
  else
    Write(Byte(0));
end;

procedure TBinaryBlockWriter.WriteBuffer(const Buffer; Count: NativeInt);
begin
  // Find start interval of this piece of data.
  // Disregard the first block so intervals start with the two FPM blocks
  var Interval := (FStream.Position - FBlockSize) div FIntervalSize;
  var Source: PByte := @Buffer;

  while (Count > 0) do
  begin
    // How many bytes from current position to end of current interval
    var BytesInThisInterval := (Interval+1) * FIntervalSize + FBlockSize - FStream.Position;
    // ...but no more than what we need
    BytesInThisInterval := Min(Count, BytesInThisInterval);

    // Write part
    FStream.WriteBuffer(Source^, BytesInThisInterval);
    Inc(Source, BytesInThisInterval);
    Dec(Count, BytesInThisInterval);

    // More to write or end of interval?
    if (Count >= 0) then
    begin
      // We have either written all the data, we are at the end of the
      // current interval, or both.
      var NewInterval := (FStream.Position - FBlockSize) div FIntervalSize;

      // If we are at a new interval...
      if (NewInterval <> Interval) then
      begin
        // ...write the two FPM blocks to start a new interval
        WriteBlockMap;
        WriteBlockMap;

        Interval := NewInterval;
      end;
    end;
  end;
end;

function TBinaryBlockWriter.BeginBlock(Poison: boolean): Cardinal;
begin
  // Move up to next block. Return block index.
  PadToAligment(FBlockSize, Poison);
  Result := BlockIndex;
end;

procedure TBinaryBlockWriter.EndBlock(Expand: boolean);
begin
  // In case we have used Seek to align the position then the physical
  // size can be smaller than the current position in which case we will
  // need to move the position back and write something to actually
  // expand then stream.
  // Note that we're testing against the real stream size here. Not the
  // cached one.
  if (Expand) then
  begin
    FStreamSize := FStream.Size;
    if (FStream.Position > FStream.Size) then
    begin
      Assert(FStreamSize - FStream.Position < FBlockSize);
      FStream.Position := FStreamSize;
    end;
  end;

  var Padding := FBlockSize - (FStream.Position and (FBlockSize-1));

  // Move up to nearest whole block
  if (Padding <> FBlockSize) then
  begin
    if (Expand) then
    begin
      if (Padding > 1) then
        Position := Position + Padding - 1;
      // Physically expand file
      Write(Byte($00));
    end else
      // Just do a seek. File will be automatically expanded if we write anything
      Position := Position + Padding;
  end;
  Assert(FStream.Position and (FBlockSize-1) = 0);
  FStreamSize := Max(FStreamSize, FStream.Position);
end;

function TBinaryBlockWriter.GetBlockCount: Cardinal;
begin
  Result := (FStreamSize + FBlockSize - 1) div FBlockSize;
end;

function TBinaryBlockWriter.GetBlockIndex: Cardinal;
begin
  Result := FStream.Position div FBlockSize;
end;

function TBinaryBlockWriter.GetIntervalIndex: Cardinal;
begin
  Result := FStream.Position div FIntervalSize;
end;

function TBinaryBlockWriter.GetPosition: Int64;
begin
  Result := PhysicalToLogicalOffset(FStream.Position);
end;

function TBinaryBlockWriter.PadToAligment(Alignment: Cardinal; Poison: boolean): Int64;
begin
  Result := Alignment - (FStream.Position and (Alignment - 1));
  if (Result <> Alignment) then
    Result := WritePadding(Position + Result, Poison)
  else
    Result := 0;
  Assert(FStream.Position and (Alignment - 1) = 0);
end;

function TBinaryBlockWriter.SaveBookmark: TBlockWriterBookmark;
begin
  Result.FWriter := Self;
  Result.FPosition := FStream.Position;
end;

function TBinaryBlockWriter.Seek(Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Assert(Origin <> soEnd); // Not supported. No need for it.

  // Make offset absolute
  case Origin of

    soBeginning:
      Result := Offset;

    soCurrent:
      Result := Position + Offset;

  else
    Result := 0;
  end;

  Position := Result;
end;

procedure TBinaryBlockWriter.SetBlockIndex(const Value: Cardinal);
begin
  FStream.Position := Value * FBlockSize;
  FStreamSize := Max(FStreamSize, FStream.Position);
end;

procedure TBinaryBlockWriter.SetPosition(const Value: Int64);
begin
  var NewPosition := LogicalToPhysicalOffset(Value);

  // If we're expanding the stream then we need to take intervals into account and
  // write the FPMs when we cross an interval boundary.
  // If we're not expanding then they have already been handled.
  if (NewPosition > FStreamSize) then
  begin

    var OldInterval := (FStream.Position - FBlockSize) div FIntervalSize;
    var NewInterval := (NewPosition - FBlockSize) div FIntervalSize;
    Assert(OldInterval <= NewInterval);

    // NewInterval /should/ generally be OldInterval+1 but just in case we for
    // some reason expand more than one interval then we handle the general
    // case by iteratively expanding one interval at a time.

    while (OldInterval < NewInterval) do
    begin
      Inc(OldInterval);

      // Move up to the start of the FPMs in the next interval
      FStream.Position := OldInterval * FIntervalSize + FBlockSize;

      // Write the two FPM blocks
      WriteBlockMap;
      WriteBlockMap;
    end;

    Assert(PhysicalToLogicalOffset(NewPosition) = Value);
  end;

  FStream.Position := NewPosition;
  FStreamSize := Max(FStreamSize, FStream.Position);
end;


// -----------------------------------------------------------------------------
//
//      TBlockWriterBookmark
//
// -----------------------------------------------------------------------------
function TBinaryBlockWriter.TBlockWriterBookmark.GetPosition: Int64;
begin
  Result := FWriter.PhysicalToLogicalOffset(FPosition);
end;

function TBinaryBlockWriter.TBlockWriterBookmark.Restore: TBlockWriterBookmark;
begin
  Result.FWriter := FWriter;
  Result.FPosition := FWriter.FStream.Position;

  FWriter.FStream.Position := FPosition;
end;

end.

