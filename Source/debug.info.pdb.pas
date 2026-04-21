unit debug.info.pdb;

(*
 * Copyright (c) 2021 Anders Melander
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *)

(*
 * This implementation of a PDB writer was inspired by Microsoft's PDB
 * source, the Epoch linker's half finished PDB emitter and the LLVM
 * documentation of the PDB and MSF file format. Many of the comments
 * have been copied verbatim from one of these sources.
 *
 *   - The LLVM Project
 *     Apache License v2.0 with LLVM Exceptions
 '     https://releases.llvm.org/11.0.0/LICENSE.TXT
 *
 *   - The microsoft-pdb repository
 *     Copyright (c) 2015 Microsoft Corporation. All rights reserved.
 *     MIT License
 '     https://github.com/microsoft/microsoft-pdb/blob/master/LICENSE
 *
 *   - Epoch Language Project
 *     Copyright (c) 2008-2018, Michael A. Lewis. All rights reserved.
 *     https://github.com/apoch/epoch-language/blob/renewal/License.txt
 *
 *)

interface

{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}
{$SCOPEDENUMS ON}

var
  PdbBuildSignature: TGUID = '{CBB17264-89FA-4AED-A2D7-814EE276EF3E}';
  PdbBuildAge: Cardinal = 1;


(*
    Wrappers and structures for generating PDB files

    Noteworthy resources for understanding how all this works:

      - Microsoft PDB source code (incomplete):
        https://github.com/Microsoft/microsoft-pdb

      - Microsoft CVDUMP utility:
        https://github.com/microsoft/microsoft-pdb/tree/master/cvdump

      - LLVM PDB and MSF file format documentation
        https://llvm.org/docs/PDB/index.html

      - LLVM llvm-pdbutil utility:
        https://llvm.org/docs/CommandGuide/llvm-pdbutil.html

      - LLVM PDB related source code:
        https://github.com/llvm-mirror/llvm/tree/master/lib/DebugInfo

      - Epoch compiler (incomplete):
        https://github.com/apoch/epoch-language/wiki/Knowledge-Dump---Debugging-Epoch-Programs
        https://github.com/apoch/epoch-language/tree/master/EpochDevTools/PDB

    PDB files are the basis of serialized debug information for Microsoft-platform
    programming and debugging tools. Notably: Visual Studio, WinDbg, DbgHelp.dll all
    use PDB format to describe debuggees. Both "in vitro" and "post mortem" debug
    tools rely heavily on the symbol data and other information (such as source code
    line mappings) stored in PDBs.

    Historically, the PDB format was a total black box, and it has only been in
    the relatively recent past that Microsoft has begun opening up details of how
    these files work. The "container" format is something known as MSF, or Multiple
    Stream Format. MSF files are like a simplistic filesystem. Within the streams of
    data of a host MSF, PDBs store a variety of useful data about the debug target,
    namely things like what code files are compiled in, what machine code instructions
    correspond to what source text, the types of variables used and how they all
    interrelate, and so on.
*)

(*
**
** MSF Container File on-disk structures
**
*)

type
  TMSFMagic = array[0..31] of AnsiChar;

const
  MSFMagic: TMSFMagic = 'Microsoft C/C++ MSF 7.00'#13#10#26'DS'#0#0#0; // MSF Magic header

type
  TMSFSuperBlock = packed record
    Magic: TMSFMagic;
    BlockSize: Cardinal;                // The block size of the internal file system. Valid values are 512, 1024, 2048, and 4096
                                        // bytes. Certain aspects of the MSF file layout vary depending on the block sizes. This
                                        // implementation handles only a block size of 4094 bytes.

    FreeBlockMapBlock: Cardinal;        // The index of a block within the file, at which begins a bitfield representing the set
                                        // of all blocks within the file which are “free” (i.e. the data within that block is not
                                        // used). See The Free Block Map for more information. Important: FreeBlockMapBlock can
                                        // only be 1 or 2!

    NumBlocks: Cardinal;                // The total number of blocks in the file. NumBlocks * BlockSize should equal the size of
                                        // the file on disk.

    NumDirectoryBytes: Cardinal;        // The size of the stream directory, in bytes. The stream directory contains information
                                        // about each stream’s size and the set of blocks that it occupies.

    Unknown: Cardinal;

    BlockMapAddr: Cardinal;             // The index of a block within the MSF file. At this block is an array of dwords listing
                                        // the blocks that the stream directory resides on. For large MSF files, the stream
                                        // directory (which describes the block layout of each stream) may not fit entirely on a
                                        // single block. As a result, this extra layer of indirection is introduced, whereby this
                                        // block contains the list of blocks that the stream directory occupies, and the stream
                                        // directory itself can be stitched together accordingly. The number of dwords in this
                                        // array is given by ceil(NumDirectoryBytes / BlockSize).
  end;


(*
**
** PDB on-disk structures
**
*)

const
  // See https://github.com/Microsoft/microsoft-pdb/blob/master/PDB/dbi/gsi.cpp, line 24-26
  // LLVM has IPHR_HASH hardcoded to 4096 which causes massive hash collisions with anything
  // but the smallest projects. The MS source determines the value based on the presence of
  // the MinimalDebugInfo PDB feature flag.
  //
  // Hash tables built with IPHR_HASH_MINIMAL can be read by CVDUMP as the MS implementation
  // calculates the size of the hash table from the size of the data being read. llvm-pdbutil
  // on the other hand is hardcoded to only handle hash tables with a size of 4096 buckets so
  // any other size can not be handled by llvm-pdbutil. This is clearly a bug in LLVM.
  //
  // Additionally, even though VTune uses msdia140.dll to read the pdb it also does not appear
  // to handle hash table sizes other than 4096 as it fails to resolve source files with other
  // hash table sizes. It has not been determined if this is because of the hash table size or
  // if it is the larger size requires some flag set somewhere in the pdb file.
  IPHR_HASH             = 4096;
  IPHR_HASH_MINIMAL     = $3FFFF; // Use this size together with PDBRawFeatureSig.MinimalDebugInfo feature code

//
// Fixed stream indices
//
type
  PDBStreamIndex = (
    // Stream 0 contains the copy of previous version of the MSF directory.
    // We are not currently using it, but technically if we find the main
    // MSF is corrupted, we could fallback to it.
    OldMSFDirectory = 0,

    StreamPDB = 1,
    StreamTPI = 2,
    StreamDBI = 3,
    StreamIPI = 4
  );

  PDBDbgHeaderType = (
    FPO,
    Exception,
    Fixup,
    OmapToSrc,
    OmapFromSrc,
    SectionHdr,
    TokenRidMap,
    Xdata,
    Pdata,
    NewFPO,
    SectionHdrOrig
  );


//
// PDB: PDB Info Stream
//
// The stream contains:
//
// - Basic File Information.
// - Fields to match EXE to the PDB.
// - Map of named streams to stream indices.
//
type
  PDBStreamVersion = (
    VC2         = 19941610,
    VC4         = 19950623,
    VC41        = 19950814,
    VC50        = 19960307,
    VC98        = 19970604,
    VC70Dep     = 19990604,
    VC70        = 20000404,
    VC80        = 20030901,
    VC110       = 20091201,
    VC140       = 20140508
  );


type
  TPDBStreamHeader = packed record
    Version: Cardinal;          // A Value from the PDBStreamVersion enum. While the meaning of this field appears
                                // to be obvious, in practice we have never observed a value other than VC70, even
                                // with modern versions of the toolchain, and it is unclear why the other values exist.
                                // It is assumed that certain aspects of the PDB stream’s layout, and perhaps even
                                // that of the other streams, will change if the value is something other than VC70.

    Signature: Cardinal;        // A 32-bit time-stamp generated with a call to time() at the time the PDB file is
                                // written. Note that due to the inherent uniqueness problems of using a timestamp
                                // with 1-second granularity, this field does not really serve its intended purpose,
                                // and as such is typically ignored in favor of the Guid field, described below.

    Age: Cardinal;              // The number of times the PDB file has been written. This can be used along with Guid
                                // to match the PDB to its corresponding executable.

    UniqueId: TGUID;            // A 128-bit identifier guaranteed to be unique across space and time.
  end;


type
  PDBRawFeatureSig = (
    VC110               = 20091201,     // No other features flags are present
                                        // PDB contains an IPI Stream

    VC140               = 20140508,     // Other feature flags may be present
                                        // PDB contains an IPI Stream

    NoTypeMerge         = $4D544F4E,    // Presumably duplicate types can appear in the TPI Stream, although it’s
                                        // unclear why this might happen.

    MinimalDebugInfo    = $494E494D     // Program was linked with /DEBUG:FASTLINK
                                        // There is no TPI / IPI stream, all type info is contained in the original
                                        // object files.
  );


//
// TPI & IPI: Type Info Stream
//
// The PDB TPI Stream (Index 2) and IPI Stream (Index 4) contain information about all types used in the program.
// It is organized as a header followed by a list of CodeView Type Records. Types are referenced from various
// streams and records throughout the PDB by their type index. In general, the sequence of type records following
// the header forms a topologically sorted DAG (directed acyclic graph), which means that a type record B can only
// refer to the type A if A.TypeIndex < B.TypeIndex. While there are rare cases where this property will not hold
// (particularly when dealing with object files compiled with MASM), an implementation should try very hard to
// make this property hold, as it means the entire type graph can be constructed in a single pass.
//
// Recent versions of the PDB format have 2 streams with identical layout, henceforth referred to as the TPI
// stream and IPI stream. Subsequent descriptions of the on-disk format apply equally whether it is for the TPI
// Stream or the IPI Stream. The only difference between the two is in which CodeView records are allowed to
// appear in each one.
//
type
  TPIStreamVersion = (
    V40 = 19950410,
    V41 = 19951122,
    V50 = 19961031,
    V70 = 19990903,
    V80 = 20040203
  );

  // At offset 0 of the TPI Stream is a header with the following layout:
  TTPIStreamHeader = packed record
    Version: Cardinal;                  // A value from the TPIStreamVersion enum.

    HeaderSize: Cardinal;               // SizeOf(TTPIStreamHeader)

    TypeIndexBegin: Cardinal;           // The numeric value of the type index representing the first type record
                                        // in the TPI stream. This is usually the value $1000 as type indices
                                        // lower than this are reserved (see Type Indices for a discussion of
                                        // reserved type indices).

    TypeIndexEnd: Cardinal;             // One greater than the numeric value of the type index representing the
                                        // last type record in the TPI stream. The total number of type records
                                        // in the TPI stream can be computed as TypeIndexEnd-TypeIndexBegin.

    TypeRecordBytes: Cardinal;          // The number of bytes of type record data following the header.

    HashStreamIndex: Word;              // The index of a stream which contains a list of hashes for every type
                                        // record. This value may be -1, indicating that hash information is not
                                        // present. In practice a valid stream index is always observed, so any
                                        // producer implementation should be prepared to emit this stream to
                                        // ensure compatibility with tools which may expect it to be present.

    HashAuxStreamIndex: Word;           // Presumably the index of a stream which contains a separate hash table,
                                        // although this has not been observed in practice and it’s unclear what
                                        // it might be used for.

    HashKeySize: Cardinal;              // The size of a hash value (usually 4 bytes).

    NumHashBuckets: Cardinal;           // The number of buckets used to generate the hash values in the
                                        // aforementioned hash streams.

    HashValueBufferOffset: integer;     // The offset and size within the TPI Hash Stream of the list of hash
    HashValueBufferLength: Cardinal;    // values. It should be assumed that there are either 0 hash values, or a
                                        // number equal to the number of type records in the TPI stream
                                        // (TypeIndexEnd-TypeEndBegin). Thus, if HashBufferLength is not equal to
                                        // (TypeIndexEnd-TypeEndBegin)*HashKeySize we can consider the PDB
                                        // malformed.

    IndexOffsetBufferOffset: integer;   // The offset and size within the TPI Hash Stream of the Type Index
    IndexOffsetBufferLength: Cardinal;  // Offsets Buffer. This is a list of pairs of DWORDs where the first
                                        // value is a Type Index and the second value is the offset in the type
                                        // record data of the type with this index. This can be used to do a
                                        // binary search followed by a linear search to get O(log n) lookup by
                                        // type index.

    HashAdjBufferOffset: integer;       // The offset and size within the TPI hash stream of a serialized hash
    HashAdjBufferLength: Cardinal;      // table whose keys are the hash values in the hash value buffer and
                                        // whose values are type indices. This appears to be useful in
                                        // incremental linking scenarios, so that if a type is modified an entry
                                        // can be created mapping the old hash value to the new type index so
                                        // that a PDB file consumer can always have the most up to date version
                                        // of the type without forcing the incremental linker to garbage collect
                                        // and update references that point to the old version to now point to
                                        // the new version.
  end;


//
// DBI: Debug Info Stream
//
// MS: NewDBIHdr
//
//   https://github.com/microsoft/microsoft-pdb/blob/master/PDB/dbi/dbi.h#L124
//
type
  DBIStreamVersion = (
    VC41 = 930803,
    V50 = 19960307,
    V60 = 19970606,
    V70 = 19990903,
    V110 = 20091201
  );

  DBIStreamFlags = (
    WasIncrementallyLinked      = $0001,
    ArePrivateSymbolsStripped   = $0002,
    HasConflictingTypes         = $0004,
    Reserved                    = $FFF8
  );

  TDBIStreamHeader = packed record
    VersionSignature: integer;          // Unknown meaning. Appears to always be -1.

    VersionHeader: Cardinal;            // A value from the DBIStreamVersion enum.

    Age: Cardinal;                      // The number of times the PDB has been written. Equal to the same field
                                        // from the PDB Stream header.

    GlobalStreamIndex: Word;            // The index of the Global Symbol Stream, which contains CodeView symbol
                                        // records for all global symbols.
                                        // Actual records are stored in the symbol record stream, and are referenced
                                        // from this stream.

    BuildNumber: Word;                  // A bitfield containing values representing the major and minor version
                                        // number of the toolchain (e.g. 12.0 for MSVC 2013) used to build the
                                        // program, with the following layout:
                                        // Word(MinorVersion:8; MajorVersion:7; NewVersionFormat: 1)

    PublicStreamIndex: Word;            // The index of the Public Symbol Stream, which contains CodeView symbol
                                        // records for all public symbols. Actual records are stored in the symbol
                                        // record stream, and are referenced from this stream.

    PdbDllVersion: Word;                // The version number of mspdbXXXX.dll if it was used to produce this PDB.

    SymRecordStreamIndex: Word;         // The stream containing all CodeView symbol records used by the program.
                                        // This is used for deduplication, so that many different compilands can
                                        // refer to the same symbols without having to include the full record
                                        // content inside of each module stream.

    PdbDllRbld: Word;                   // Unknown

    ModInfoSize: integer;               // The length of the Module Info Substream.
    SectionContributionSize: integer;   // The length of the Section Contribution Substream.
    SectionMapSize: integer;            // The length of the Section Map Substream.
    SourceInfoSize: integer;            // The length of the File Info Substream.
    TypeServerMapSize: integer;         // The length of the Type Server Map Substream.

    MFCTypeServerIndex: Cardinal;       // The index of the MFC type server in the Type Server Map Substream.

    OptionalDbgHeaderSize: integer;     // The length of the Optional Debug Header Stream.
    ECSubstreamSize: integer;           // The length of the EC Substream.

    Flags: Word;                        // A bitfield containing various information about how the program was
                                        // built. Values are from the DBIStreamFlags enum.

    Machine: Word;                      // A value from the CV_CPU_TYPE_e enumeration. Common values are 0x8664
                                        // (x86-64) and 0x14C (x86).

    Padding: Cardinal;
  end;


//
// DBI - Module Info Substream
//
// Begins at offset 0 immediately after the header. The module info substream is an array of variable-length
// records, each one describing a single module (e.g. object file) linked into the program. Each record in
// the array has the format described in the TModInfo structure.
// SectionContr: Describes the properties of the section in the final binary which contain the code and
// data from this module.
//
// MS: SC
//
//   https://github.com/microsoft/microsoft-pdb/blob/master/PDB/include/dbicommon.h#L42
//
type
  TSectionContribEntry = packed record
    Section: Word;
    Padding1: Word;
    Offset: integer;
    Size: integer;
    Characteristics: Cardinal;          // Corresponds to the Characteristics field of the IMAGE_SECTION_HEADER
                                        // structure.
    ModuleIndex: Word;                  // External module index; 0 based
    Padding2: Word;
    DataCrc: Cardinal;
    RelocCrc: Cardinal;
  end;

  TSectionContribEntry2 = packed record
    SectionContribEntry: TSectionContribEntry;
    ISectCoff: Cardinal;
  end;

  TModInfo = packed record
    Unused1: Cardinal;                  // Mod: Currently opened module.
                                        // This field is a pointer in the reference implementation, but that
                                        // won't work on 64-bit systems, and anyway it doesn't make sense to
                                        // read a pointer from a file. For now it is unused, so just ignore it.

    // SectionContr:
    SectionContrib: TSectionContribEntry;// Describes the properties of the section in the final binary which
                                        // contain the code and data from this module.

    Flags: Word;                        // A bitfield with the following format:
                                        //   Word(Dirty:1; EC: 1; Unused: 6; TSM: 8).

    ModuleSymStreamIndex: Word;         // The index of the stream that contains symbol information for this
                                        // module. This includes CodeView symbol information as well as source
                                        // and line information. If this field is -1, then no additional debug
                                        // info will be present for this module (for example, this is what
                                        // happens when you strip private symbols from a PDB).

    SymByteSize: Cardinal;              // The number of bytes of data from the stream identified by
                                        // ModuleSymStream that represent CodeView symbol records.

    C11ByteSize: Cardinal;              // The number of bytes of data from the stream identified by
                                        // ModuleSymStream that represent C11-style CodeView line information.

    C13ByteSize: Cardinal;              // The number of bytes of data from the stream identified by
                                        // ModuleSymStream that represent C13-style CodeView line information.
                                        // At most one of C11ByteSize and C13ByteSize will be non-zero. Modern
                                        // PDBs always use C13 instead of C11.

    SourceFileCount: Word;              // The number of source files that contributed to this module during
    Padding: Word;                      // compilation.

    Unused2: Cardinal;                  // FileNameOffs: array of [0..NumFiles]
                                        // DBI name buffer offsets.
                                        // This field is a pointer in the reference implementation, but as
                                        // with `Mod` (Unused1), we ignore it for now since it is unused.

    SourceFileNameIndex: Cardinal;      // The offset in the names buffer of the primary translation unit used
                                        // to build this module. All PDB files observed to date always have
                                        // this value equal to 0.

    PdbFilePathNameIndex: Cardinal;     // The offset in the names buffer of the PDB file containing this
                                        // module’s symbol information. This has only been observed to be
                                        // non-zero for the special "* Linker *" module.

    { Remaining fields are variable length zero terminated strings:

    ModuleName: AnsiString;             // The module name. This is usually either a full path to an object file
                                        // (either directly passed to link.exe or from an archive) or a string
                                        // of the form Import:<dll name>.

    ObjFileName: AnsiString;            // The object file name. In the case of an module that is linked
                                        // directly passed to link.exe, this is the same as ModuleName. In the
                                        // case of a module that comes from an archive, this is usually the full
                                        // path to the archive.
    }
  end;


//
// DBI - Section Contribution Substream
//
// Begins at offset 0 immediately after the Module Info Substream ends, and consumes
// Header.SectionContributionSize bytes.
// This substream begins with a single DWORD which will be one of the TSectionContrSubstreamVersion values.
// Ver60 is the only value which has been observed in a PDB so far. Following this is an array of fixed-length
// structures. If the version is Ver60, it is an array of TSectionContribEntry structures (this is the nested
// structure from the TModInfo type). If the version is V2, it is an array of SectionContribEntry2 structures
// (not used here).
//
type
  SectionContrSubstreamVersion = (
    Ver60       = Integer($effe0000 + 19970605), // Must cast to integer to avoid overflow at compile time
    V2          = Integer($effe0000 + 20140516)
  );


//
// DBI - Section Map Substream
//
// Begins at offset 0 immediately after the Section Contribution Substream ends, and consumes
// Header.SectionMapSize bytes. This substream begins with an 4 byte header (TSectionMapHeader)
// followed by an array of fixed-length records (TSectionMapEntry).
//
type
  //
  // MS: OMFSegMap
  //
  // LLVM: SecMapHeader
  //
  //   https://llvm.org/doxygen/structllvm_1_1pdb_1_1SecMapHeader.html
  //
  TSectionMapHeader = packed record
    Count: Word;                // Number of segment descriptors.
    LogCount: Word;             // Number of logical segment descriptors.
  end;

  //
  // MS: OMFSegMapDesc
  //
  // LLVM: SecMapEntry
  //
  //   https://llvm.org/doxygen/structllvm_1_1pdb_1_1SecMapEntry.html
  //
  // The definition is not present in the reference implementation, but the layout
  // is derived from code that accesses the fields.
  //
  TSectionMapEntry = packed record
    Flags: Word;                // See the SectionMapEntryFlags enum below.

    Ovl: Word;                  // Logical overlay number.

    Group: Word;                // Group index into descriptor array.

    Frame: Word;

    SectionName: Word;          // Byte index of segment / group name in string table, or $FFFF.

    ClassName: Word;            // Byte index of class in string table, or $FFFF.

    Offset: Cardinal;           // Byte offset of the logical segment within physical segment.  If group is
                                // set in flags, this is the offset of the group.

    SectionLength: Cardinal;    // Byte count of the segment or group.
  end;

  SectionMapEntryFlags = (
    Read                = $0001,        // Segment is readable.
    Write               = $0002,        // Segment is writable.
    Execute             = $0004,        // Segment is executable.
    AddressIs32Bit      = $0008,        // Descriptor describes a 32-bit linear address.
    IsSelector          = $0080,        // Frame represents a selector.
    IsAbsoluteAddress   = $0100,        // Frame represents an absolute address.
    IsGroup             = $0200         // If set, descriptor represents a group.
  );


//
// DBI - File Info Substream
//
// Begins at offset 0 immediately after the Section Map Substream ends, and consumes Header.SourceInfoSize bytes.
// This substream defines the mapping from module to the source files that contribute to that module. Since
// multiple modules can use the same source file (for example, a header file), this substream uses a string table
// to store each unique file name only once, and then have each module use offsets into the string table rather
// than embedding the string’s value directly.
//
type
  TFileInfoSubstream = packed record
    // Note: I have swapped the position of NumSourceFiles/NumModules and ModFileCounts/ModIndices compared to the LLVM docs.

    NumModules: Word;                   // The number of modules for which source file information is contained
                                        // within this substream. Should match the corresponding value from the
                                        // ref:dbi_header.

    NumSourceFiles: Word;               // In theory this is supposed to contain the number of source files for
                                        // which this substream contains information. But that would present a
                                        // problem in that the width of this field being 16-bits would prevent
                                        // one from having more than 64K source files in a program. In early
                                        // versions of the file format, this seems to have been the case. In
                                        // order to support more than this, this field of the is simply ignored,
                                        // and computed dynamically by summing up the values of the
                                        // ModFileCounts array (discussed below). In short, this value should
                                        // be ignored.

    { Variable length elements follows:

    ModIndices: array[NumModules] of Word;
                                        //  This array is present, but does not appear to be useful.

    ModFileCounts: array[NumModules] of Word;
                                        // An array of NumModules integers, each one containing the number of
                                        // source files which contribute to the module at the specified index.
                                        // While each individual module is limited to 64K contributing source
                                        // files, the union of all modules’ source files may be greater than
                                        // 64K. The real number of source files is thus computed by summing this
                                        // array. Note that summing this array does not give the number of
                                        // unique source files, only the total number of source file
                                        // contributions to modules.

    FileNameOffsets: array[NumSourceFiles] of Cardinal;
                                        // An array of NumSourceFiles integers (where NumSourceFiles here refers
                                        // to the 32-bit value obtained from summing the ModFileCount array), where
                                        // each integer is an offset into NamesBuffer pointing to a null
                                        // terminated string.

    NamesBuffer: array[NumSourceFiles] of AnsiString;
                                        // An array of null terminated strings containing the actual source
                                        // file names.
    }
  end;


//
// DBI - Name Hash Table Substream
//
// I haven't found any documentation for this
//
const
  PDBStringTableSignature = $EFFEEFFE;

type
  TPDBStringTableHeader = packed record
    Signature: Cardinal;                // PDBStringTableSignature

    HashVersion: Cardinal;              // Hash method version; Either 1 or 2.

    ByteSize: Cardinal;                 // Number of bytes of names buffer.
  end;


//
// MODI - Module Information Stream
//
// The Module Info Stream (henceforth referred to as the Modi stream) contains information about a single module
// (object file, import library, etc that contributes to the binary this PDB contains debug information about.
// There is one modi stream for each module, and the mapping between modi stream index and module is contained
// in the DBI Stream. The modi stream for a single module contains line information for the compiland, as well
// as all CodeView information for the symbols defined in the compiland. Finally, there is a “global refs”
// substream which is not well understood.
//
type
  TModiStream = packed record
    Signature: Cardinal;                // A value from the CVSignature enum. In practice only the value of 4
                                        // (CV_SIGNATURE_C13) been observed.

    { Variable length elements follows:

    Symbols: TBytes[SymbolSize-4];      // The CodeView Symbol Substream. SymbolSize is equal to the value of
                                        // SymByteSize for the corresponding module’s entry in the Module Info
                                        // Substream of the DBI Stream.

    C11LineInfo: TBytes[C11Size];       // A block containing CodeView line information in C11 format. C11Size is
                                        // equal to the value of C11ByteSize from the Module Info Substream of
                                        // the DBI Stream. If this value is 0, then C11 line information is not
                                        // present.

    C13LineInfo: TBytes[C13Size];       // A block containing CodeView line information in C13 format. C13Size is
                                        // equal to the value of C13ByteSize from the Module Info Substream of
                                        // the DBI Stream. If this value is 0, then C13 line information is not
                                        // present.

    GlobalRefsSize: Cardinal;           // The meaning of this substream is not understood.
    GlobalRefs: TBytes[GlobalRefsSize];
    }
  end;

  //
  // https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L83
  //
  CVSignature = (
    CV_SIGNATURE_C6     = 0,    // Actual signature is >64K
    CV_SIGNATURE_C7     = 1,    // First explicit signature
    CV_SIGNATURE_C11    = 2,    // C11 (vc5.x) 32-bit types
    CV_SIGNATURE_C13    = 4     // C13 (vc7.x) zero terminated names
  );  // All signatures from 5 to 64K are reserved




//
// Public Stream
//
//   Contains:
//     - Public (Exported) Symbol Records.
//     - Index of Public Hash Stream.
//
// Section contribution structure
// Globals and Publics Section Hash Table header
//
// MS: PSGSIHDR
//
//   https://github.com/Microsoft/microsoft-pdb/blob/master/PDB/dbi/gsi.h
//
// LLVM: PublicsStreamHeader
//
//   https://llvm.org/doxygen/structllvm_1_1pdb_1_1PublicsStreamHeader.html
//
type
  TPublicsStreamHeader  = packed record
    SymHash: Cardinal;
    AddrMap: Cardinal;
    NumThunks: Cardinal;
    SizeOfThunk: Cardinal;
    ISectThunkTable: Word;
    Padding: Word;
    OffThunkTable: Cardinal;
    NumSections: Cardinal;
  end;


//
// Section contribution structure
// Globals and Publics Section Hash Table header
//
// MS: GSIHashHdr
//
//   https://github.com/Microsoft/microsoft-pdb/blob/master/PDB/dbi/gsi.h#L62
//
// LLVM: GSIHashHeader
//
const
  // Section contribution version, before V70 there was no section version
  GSIHashHeaderSignature        = $FFFFFFFF;
  GSIHashHeaderVersionV70       = $EFFE0000 + 19990810;

type
  TGSIHashHeader = packed record
    VerSignature: Cardinal;             // GSIHashHeaderSignature

    VerHdr: Cardinal;                   // GSIHashHeaderVersionV70

    HrSize: Cardinal;                   // Specifies the number of bytes of TPSHashRecords
                                        // that follows immediately after this structure.
                                        // HrSize = Length(HashRecords)*SizeOf(TPSHashRecord)

    NumBuckets: Cardinal;               // Specifies the size of the bitmap plus the number
                                        // of bytes of offset values that follows after the
                                        // TPSHashRecord array.
                                        // NumBuckets = SizeOf(THashBitmap) + Length(Offsets)*SizeOf(Cardinal)
    { Variable length elements follows:

    HashRecords: array[] of TPSHashRecord
    Bitmap: THashBitmap
    Offsets: array of Cardinal
    }
  end;

  //
  // MS: HRFile
  //
  //   https://github.com/Microsoft/microsoft-pdb/blob/master/PDB/dbi/gsi.h#L8
  //
  TPSHashRecord = packed record
    Off: Cardinal;                      // Offset in the symbol record stream
    CRef: Cardinal;
  end;


//
// String V1 hasher
//
// MS: Hasher::HashPbCb
//
//   https://github.com/microsoft/microsoft-pdb/blob/master/PDB/include/misc.h#L15
//
// Note: We do not perform truncation (modulus) on the result. It is up to the caller to do that.
//
function HashStringV1(const Str: UTF8String): Cardinal;


//
// String V2 hasher
//
// MS: HasherV2::lhashPbCb
//
//   https://github.com/microsoft/microsoft-pdb/blob/master/PDB/include/misc.h#L91
//
// Note: We do not perform truncation (modulus) on the result. It is up to the caller to do that.
//
function HashStringV2(const Str: UTF8String): Cardinal;


implementation


function HashStringV1(const Str: UTF8String): Cardinal;
begin
  Result := 0;

  var p := PAnsiChar(Str);
  var Count := Length(Str);

  // Hash 4 characters/one DWORD at a time.
  while (Count >= SizeOf(Cardinal)) do
  begin
    Result := Result xor PCardinal(p)^;
    Inc(PCardinal(p));
    Dec(Count, SizeOf(Cardinal));
  end;

  // Maximum of 3 bytes left.  Hash a 2 byte word if possible, then hash the
  // possibly remaining 1 byte.
  if (Count >= 2) then
  begin
    Result := Result xor Cardinal(PWord(p)^);
    Inc(PWord(p));
    Dec(Count, SizeOf(Word));
  end;

  // Hash the rest 1 by 1.
  if (Count = 1) then
    Result := Result xor Cardinal(Ord(p^));

  Result := Result or $20202020; // Make lowercase
  Result := Result xor (Result shr 11);
  Result := Result xor (Result shr 16);
end;

function HashStringV2(const Str: UTF8String): Cardinal;
begin
  Result := $b170a1bf;

  var p := PAnsiChar(Str);
  var Count := Length(Str);

  // Hash 4 characters/one DWORD at a time.
  while (Count >= SizeOf(Cardinal)) do
  begin
    Result := Result + PCardinal(p)^;
    Result := Result + (Result shl 10);
    Result := Result xor (Result shr 6);
    Inc(PCardinal(p));
    Dec(Count, SizeOf(Cardinal));
  end;

  // Hash the rest 1 by 1.
  while (Count > 0) do
  begin
    Result := Result + Ord(p^);
    Result := Result + (Result shl 10);
    Result := Result xor (Result shr 6);
    Inc(p);
    Dec(Count);
  end;

  // From Numerical Recipes in C, second edition, pg 284.
  Result := Result * 1664525 + 1013904223;
end;

end.

