unit debug.info.writer;

(*
 * Copyright (c) 2021 Anders Melander
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *)

interface

{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}

// Define SAVE_MEMSTREAM to use a TMemoryStream when constructing the PDB.
// Otherwise a TBufferedFileStream is used.
{$define SAVE_MEMSTREAM}

uses
  System.Classes,
  debug.info,
  debug.info.log;

type
  // Abstract writer base class
  TDebugInfoWriter = class abstract
  private
    FModuleLogger: IDebugInfoModuleLogger;
  protected
    property Logger: IDebugInfoModuleLogger read FModuleLogger;
  public
    constructor Create(ABlockSize: Cardinal = 0); virtual;

    procedure SaveToStream(Stream: TStream; DebugInfo: TDebugInfo); virtual; abstract;
    procedure SaveToFile(const Filename: string; DebugInfo: TDebugInfo);
  end;

  TDebugInfoWriterClass = class of TDebugInfoWriter;


implementation

uses
  System.SysUtils;

type
  // TSafeMemoryStream: A memory stream that clears the allocated memory
  // in order to avoid writing junk to the pdb file.
  TSafeMemoryStream = class(TMemoryStream)
  protected
{$if (CompilerVersion < 35.0)}
    function Realloc(var NewCapacity: LongInt): Pointer; override;
{$else}
    function Realloc(var NewCapacity: NativeInt): Pointer; override;
{$ifend}
  end;

{$if (CompilerVersion < 35.0)}
function TSafeMemoryStream.Realloc(var NewCapacity: LongInt): Pointer;
{$else}
function TSafeMemoryStream.Realloc(var NewCapacity: NativeInt): Pointer;
{$ifend}
begin
  Result := inherited Realloc(NewCapacity);

  if (NewCapacity > Capacity) then
    FillChar((PByte(Result) + Capacity)^, NewCapacity - Capacity, 0);
end;

constructor TDebugInfoWriter.Create(ABlockSize: Cardinal);
begin
  inherited Create;
  FModuleLogger := RegisterDebugInfoModuleLogger('writer');
end;

procedure TDebugInfoWriter.SaveToFile(const Filename: string; DebugInfo: TDebugInfo);
begin
  try

{$ifdef SAVE_MEMSTREAM}
    var Stream := TSafeMemoryStream.Create;
{$else SAVE_MEMSTREAM}
    var Stream := TBufferedFileStream.Create(Filename, fmCreate, $8000);
{$endif SAVE_MEMSTREAM}
    try

      SaveToStream(Stream, DebugInfo);

{$ifdef SAVE_MEMSTREAM}
      Stream.SaveToFile(Filename);
{$endif SAVE_MEMSTREAM}

    finally
      Stream.Free;
    end;

  except
    on E: EFCreateError do
      Logger.Error(E.Message);
  end;
end;

end.

