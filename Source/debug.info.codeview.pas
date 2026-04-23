unit debug.info.codeview;

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

uses
  WinApi.Windows,
  System.SysUtils; // TBytes

{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}
{$SCOPEDENUMS ON}

//
// PE debug directory structure
//
type
  CV_INFO_PDB70 = record
    CvSignature: Cardinal;
    Signature: TGUID;
    Age: Cardinal;
    { Variable length elements follows:
    PdbFileName: AnsiString;
    }
  end;
  TCodeViewInfoPDB70 = CV_INFO_PDB70;


//
// MS: CV_CPU_TYPE_e
//
//   https://msdn.microsoft.com/en-us/library/b2fc64ek.aspx
//
type
  CVCPUType = (
    CV_CFL_8080         = $00,
    CV_CFL_8086         = $01,
    CV_CFL_80286        = $02,
    CV_CFL_80386        = $03,
    CV_CFL_80486        = $04,
    CV_CFL_PENTIUM      = $05,
    CV_CFL_PENTIUMII    = $06, // CV_CFL_PENTIUMPRO
    //      = ,
    CV_CFL_PENTIUMIII   = $07,
    CV_CFL_MIPS         = $10, // CV_CFL_MIPSR4000
    CV_CFL_MIPS16       = $11,
    CV_CFL_MIPS32       = $12,
    CV_CFL_MIPS64       = $13,
    CV_CFL_MIPSI        = $14,
    CV_CFL_MIPSII       = $15,
    CV_CFL_MIPSIII      = $16,
    CV_CFL_MIPSIV       = $17,
    CV_CFL_MIPSV        = $18,
    CV_CFL_M68000       = $20,
    CV_CFL_M68010       = $21,
    CV_CFL_M68020       = $22,
    CV_CFL_M68030       = $23,
    CV_CFL_M68040       = $24,
    CV_CFL_ALPHA        = $30,
    CV_CFL_ALPHA_21064  = $30,
    CV_CFL_ALPHA_21164  = $31,
    CV_CFL_ALPHA_21164A = $32,
    CV_CFL_ALPHA_21264  = $33,
    CV_CFL_ALPHA_21364  = $34,
    CV_CFL_PPC601       = $40,
    CV_CFL_PPC603       = $41,
    CV_CFL_PPC604       = $42,
    CV_CFL_PPC620       = $43,
    CV_CFL_PPCFP        = $44,
    CV_CFL_SH3          = $50,
    CV_CFL_SH3E         = $51,
    CV_CFL_SH3DSP       = $52,
    CV_CFL_SH4          = $53,
    CV_CFL_SHMEDIA      = $54,
    CV_CFL_ARM3         = $60,
    CV_CFL_ARM4         = $61,
    CV_CFL_ARM4T        = $62,
    CV_CFL_ARM5         = $63,
    CV_CFL_ARM5T        = $64,
    CV_CFL_ARM6         = $65,
    CV_CFL_ARM_XMAC     = $66,
    CV_CFL_ARM_WMMX     = $67,
    CV_CFL_OMNI         = $70,
    CV_CFL_IA64         = $80,
    CV_CFL_IA64_1       = $80,
    CV_CFL_IA64_2       = $81,
    CV_CFL_CEE          = $90,
    CV_CFL_AM33         = $A0,
    CV_CFL_M32R         = $B0,
    CV_CFL_TRICORE      = $C0,
    CV_CFL_X64          = $D0, // CV_CFL_AMD64
    CV_CFL_EBC          = $E0,
    CV_CFL_THUMB        = $F0,
    CV_CFL_ARMNT        = $F4,
    CV_CFL_D3D11_SHADER = $100
  );


//
// LLVM: SourceLanguage
//
//   http://llvm-cs.pcc.me.uk/include/llvm/DebugInfo/CodeView/CodeView.h#143
//
// MS: CV_CFL_LANG
//
//   https://msdn.microsoft.com/en-us/library/bw3aekw6.aspx
//
type
  CVSourceLanguage = (
    C                   = $00,
    Cpp                 = $01,
    Fortran             = $02,
    Masm                = $03,
    Pascal              = $04,
    Basic               = $05,
    Cobol               = $06,
    Link                = $07,
    Cvtres              = $08,
    Cvtpgd              = $09,
    CSharp              = $0a,
    VB                  = $0b,
    ILAsm               = $0c,
    Java                = $0d,
    JScript             = $0e,
    MSIL                = $0f,
    HLSL                = $10,

    // The DMD & Swift compilers emit 'D' and 'S', respectively, for the CV
    // source language. Microsoft does not have enumerators for them yet.
    D                   = Ord('D'),
    Swift               = Ord('S')
  );


type
  //
  // MS: SYM_ENUM_e
  //
  //   https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L2735
  //
  // LLVM: CV_SYMBOL & SymbolRecordKind
  //
  // Distinguishes individual records in the Symbols subsection of a .debug$S
  // section.
  //
  CVSymbolRecordKind = (
    // 16 bit symbol types. Not very useful, provided only for reference.
    S_COMPILE             = $0001,
    S_REGISTER_16t        = $0002,
    S_CONSTANT_16t        = $0003,
    S_UDT_16t             = $0004,
    S_SSEARCH             = $0005,
    S_SKIP                = $0007,
    S_CVRESERVE           = $0008,
    S_OBJNAME_ST          = $0009,
    S_ENDARG              = $000a,
    S_COBOLUDT_16t        = $000b,
    S_MANYREG_16t         = $000c,
    S_RETURN              = $000d,
    S_ENTRYTHIS           = $000e,
    S_BPREL16             = $0100,
    S_LDATA16             = $0101,
    S_GDATA16             = $0102,
    S_PUB16               = $0103,
    S_LPROC16             = $0104,
    S_GPROC16             = $0105,
    S_THUNK16             = $0106,
    S_BLOCK16             = $0107,
    S_WITH16              = $0108,
    S_LABEL16             = $0109,
    S_CEXMODEL16          = $010a,
    S_VFTABLE16           = $010b,
    S_REGREL16            = $010c,
    S_BPREL32_16t         = $0200,
    S_LDATA32_16t         = $0201,
    S_GDATA32_16t         = $0202,
    S_PUB32_16t           = $0203,
    S_LPROC32_16t         = $0204,
    S_GPROC32_16t         = $0205,
    S_THUNK32_ST          = $0206,
    S_BLOCK32_ST          = $0207,
    S_WITH32_ST           = $0208,
    S_LABEL32_ST          = $0209,
    S_CEXMODEL32          = $020a,
    S_VFTABLE32_16t       = $020b,
    S_REGREL32_16t        = $020c,
    S_LTHREAD32_16t       = $020d,
    S_GTHREAD32_16t       = $020e,
    S_SLINK32             = $020f,
    S_LPROCMIPS_16t       = $0300,
    S_GPROCMIPS_16t       = $0301,
    S_PROCREF_ST          = $0400,
    S_DATAREF_ST          = $0401,
    S_ALIGN               = $0402,
    S_LPROCREF_ST         = $0403,
    S_OEM                 = $0404,
    // All post 16 bit symbol types have the $1000 bit set.
    S_TI16_MAX            = $1000,
    // Mostly unused "start" symbol types.
    S_REGISTER_ST         = $1001,
    S_CONSTANT_ST         = $1002,
    S_UDT_ST              = $1003,
    S_COBOLUDT_ST         = $1004,
    S_MANYREG_ST          = $1005,
    S_BPREL32_ST          = $1006,
    S_LDATA32_ST          = $1007,
    S_GDATA32_ST          = $1008,
    S_PUB32_ST            = $1009,
    S_LPROC32_ST          = $100a,
    S_GPROC32_ST          = $100b,
    S_VFTABLE32           = $100c,
    S_REGREL32_ST         = $100d,
    S_LTHREAD32_ST        = $100e,
    S_GTHREAD32_ST        = $100f,
    S_LPROCMIPS_ST        = $1010,
    S_GPROCMIPS_ST        = $1011,
    S_COMPILE2_ST         = $1013,
    S_MANYREG2_ST         = $1014,
    S_LPROCIA64_ST        = $1015,
    S_GPROCIA64_ST        = $1016,
    S_LOCALSLOT_ST        = $1017,
    S_PARAMSLOT_ST        = $1018,
    S_GMANPROC_ST         = $101a,
    S_LMANPROC_ST         = $101b,
    S_RESERVED1           = $101c,
    S_RESERVED2           = $101d,
    S_RESERVED3           = $101e,
    S_RESERVED4           = $101f,
    S_LMANDATA_ST         = $1020,
    S_GMANDATA_ST         = $1021,
    S_MANFRAMEREL_ST      = $1022,
    S_MANREGISTER_ST      = $1023,
    S_MANSLOT_ST          = $1024,
    S_MANMANYREG_ST       = $1025,
    S_MANREGREL_ST        = $1026,
    S_MANMANYREG2_ST      = $1027,
    S_MANTYPREF           = $1028,
    S_UNAMESPACE_ST       = $1029,
    // End of S_*_ST symbols, which do not appear to be generated by modern compilers.
    S_ST_MAX              = $1100,
    S_WITH32              = $1104,
    S_MANYREG             = $110a,
    S_LPROCMIPS           = $1114,
    S_GPROCMIPS           = $1115,
    S_MANYREG2            = $1117,
    S_LPROCIA64           = $1118,
    S_GPROCIA64           = $1119,
    S_LOCALSLOT           = $111a,
    S_PARAMSLOT           = $111b,
    // Managed code symbols.
    S_MANFRAMEREL         = $111e,
    S_MANREGISTER         = $111f,
    S_MANSLOT             = $1120,
    S_MANMANYREG          = $1121,
    S_MANREGREL           = $1122,
    S_MANMANYREG2         = $1123,
    S_DATAREF             = $1126,
    S_ANNOTATIONREF       = $1128,
    S_TOKENREF            = $1129,
    S_GMANPROC            = $112a,
    S_LMANPROC            = $112b,
    S_ATTR_FRAMEREL       = $112e,
    S_ATTR_REGISTER       = $112f,
    S_ATTR_REGREL         = $1130,
    S_ATTR_MANYREG        = $1131,
    S_SEPCODE             = $1132,
    S_LOCAL_2005          = $1133,
    S_DEFRANGE_2005       = $1134,
    S_DEFRANGE2_2005      = $1135,
    S_DISCARDED           = $113b,
    // Current symbol types for most procedures as of this writing.
    S_LPROCMIPS_ID        = $1148,
    S_GPROCMIPS_ID        = $1149,
    S_LPROCIA64_ID        = $114a,
    S_GPROCIA64_ID        = $114b,
    S_DEFRANGE_HLSL       = $1150,
    S_GDATA_HLSL          = $1151,
    S_LDATA_HLSL          = $1152,
    S_LOCAL_DPC_GROUPSHARED = $1154,
    S_DEFRANGE_DPC_PTR_TAG  = $1157,
    S_DPC_SYM_TAG_MAP     = $1158,
    S_ARMSWITCHTABLE      = $1159,
    S_POGODATA            = $115c,
    S_INLINESITE2         = $115d,
    S_MOD_TYPEREF         = $115f,
    S_REF_MINIPDB         = $1160,
    S_PDBMAP              = $1161,
    S_GDATA_HLSL32        = $1162,
    S_LDATA_HLSL32        = $1163,
    S_GDATA_HLSL32_EX     = $1164,
    S_LDATA_HLSL32_EX     = $1165,
    S_FASTLINK            = $1167, // Undocumented
    S_INLINEES            = $1168, // Undocumented
    // Known symbol types
    S_END                 = $0006, // ScopeEndSym
    S_INLINESITE_END      = $114e, // InlineSiteEnd, ScopeEndSym
    S_PROC_ID_END         = $114f, // ProcEnd, ScopeEndSym
    S_THUNK32             = $1102, // Thunk32Sym
    S_TRAMPOLINE          = $112c, // TrampolineSym
    S_SECTION             = $1136, // SectionSym
    S_COFFGROUP           = $1137, // CoffGroupSym
    S_EXPORT              = $1138, // ExportSym
    S_LPROC32             = $110f, // ProcSym
    S_GPROC32             = $1110, // GlobalProcSym, ProcSym
    S_LPROC32_ID          = $1146, // ProcIdSym, ProcSym
    S_GPROC32_ID          = $1147, // GlobalProcIdSym, ProcSym
    S_LPROC32_DPC         = $1155, // DPCProcSym, ProcSym
    S_LPROC32_DPC_ID      = $1156, // DPCProcIdSym, ProcSym
    S_REGISTER            = $1106, // RegisterSym
    S_PUB32               = $110e, // PublicSym32
    S_PROCREF             = $1125, // ProcRefSym
    S_LPROCREF            = $1127, // LocalProcRef, ProcRefSym
    S_ENVBLOCK            = $113d, // EnvBlockSym
    S_INLINESITE          = $114d, // InlineSiteSym
    S_LOCAL               = $113e, // LocalSym
    S_DEFRANGE            = $113f, // DefRangeSym
    S_DEFRANGE_SUBFIELD   = $1140, // DefRangeSubfieldSym
    S_DEFRANGE_REGISTER   = $1141, // DefRangeRegisterSym
    S_DEFRANGE_FRAMEPOINTER_REL   = $1142, // DefRangeFramePointerRelSym
    S_DEFRANGE_SUBFIELD_REGISTER  = $1143, // DefRangeSubfieldRegisterSym
    S_DEFRANGE_FRAMEPOINTER_REL_FULL_SCOPE = $1144, // DefRangeFramePointerRelFullScopeSym
    S_DEFRANGE_REGISTER_REL       = $1145, // DefRangeRegisterRelSym
    S_BLOCK32             = $1103, // BlockSym
    S_LABEL32             = $1105, // LabelSym
    S_OBJNAME             = $1101, // ObjNameSym
    S_COMPILE2            = $1116, // Compile2Sym
    S_COMPILE3            = $113c, // Compile3Sym
    S_FRAMEPROC           = $1012, // FrameProcSym
    S_CALLSITEINFO        = $1139, // CallSiteInfoSym
    S_FILESTATIC          = $1153, // FileStaticSym
    S_HEAPALLOCSITE       = $115e, // HeapAllocationSiteSym
    S_FRAMECOOKIE         = $113a, // FrameCookieSym
    S_CALLEES             = $115a, // CallerSym
    S_CALLERS             = $115b, // CalleeSym, CallerSym
    S_UDT                 = $1108, // UDTSym
    S_COBOLUDT            = $1109, // CobolUDT, UDTSym
    S_BUILDINFO           = $114c, // BuildInfoSym
    S_BPREL32             = $110b, // BPRelativeSym
    S_REGREL32            = $1111, // RegRelativeSym
    S_CONSTANT            = $1107, // ConstantSym
    S_MANCONSTANT         = $112d, // ManagedConstant, ConstantSym
    S_LDATA32             = $110c, // DataSym
    S_GDATA32             = $110d, // GlobalData, DataSym
    S_LMANDATA            = $111c, // ManagedLocalData, DataSym
    S_GMANDATA            = $111d, // ManagedGlobalData, DataSym
    S_LTHREAD32           = $1112, // ThreadLocalDataSym
    S_GTHREAD32           = $1113, // GlobalTLS, ThreadLocalDataSym
    S_UNAMESPACE          = $1124, // UsingNamespaceSym
    S_ANNOTATION          = $1019  // AnnotationSym
  );


//
// Common header for symbol records
//
type
  TCVTypeRecordHeader = packed record
    RecordLen: Word;            // Record length, aligned to 4 bytes, not including this
                                // 2 byte field.

    RecordKind: Word;           // Record kind enum. See CVTypeRecordKind.
  end;

// Limit on the size of all codeview symbol and type records, including the
// TCVTypeRecordHeader. MSVC does not emit any records larger than this.
const
  CVMaxRecordLength = $FF00;


type
  //
  // LLVM: CVSymbol = CVRecord<SymbolKind>;
  //
  TCVSymbol = record
    Header: TCVTypeRecordHeader;
    Data: TBytes;
  public
    function Length: Byte; // Total size - not same as Header.RecordLen
    function Name: UTF8String; overload;
    class function Name(AKind: CVSymbolRecordKind): UTF8String; overload; static;
  end;


type
  //
  // RecordKind = S_SECTION
  //
  // LLVM: SectionSym
  //
  //   https://llvm.org/doxygen/classllvm_1_1codeview_1_1SectionSym.html
  //
  // MS: SECTIONSYM
  //
  //   https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L4432
  //
  TCVTypeSectionSym = packed record
    Header: TCVTypeRecordHeader;

    SectionNumber: Word;        // Section number

    Alignment: Byte;            // Aligment of this section (power of 2). LLVM has this declared as a Word. MS as a byte.

    Reserved: Byte;             // Reserved. Must be zero.

    Rva: Cardinal;              // Relative address (i.e. offset)

    Length: Cardinal;           // Size of segment

    Characteristics: Cardinal;

    { Variable length elements follows:
    Name: AnsiString;
    }
  end;


type
  //
  // RecordKind = S_OBJNAME
  //
  // LLVM: ObjNameSym
  //
  //   https://llvm.org/doxygen/classllvm_1_1codeview_1_1ObjNameSym.html
  //
  // MS: OBJNAMESYM
  //
  //   https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L3382
  //
  TCVTypeObjNameSym = packed record
    Header: TCVTypeRecordHeader;

    Signature: Cardinal;        // Zero.

    { Variable length elements follows:
    Name: AnsiString;           // MS comment says "Length-prefixed name" but PDBs produced by MS contains
                                // regular zero terminated strings.
    }
  end;


type
  //
  // RecordKind = S_COMPILE3
  //
  // LLVM: Compile3Sym
  //
  //   http://llvm-cs.pcc.me.uk/include/llvm/DebugInfo/CodeView/SymbolRecord.h#721
  //
  // MS: COMPILESYM3
  //
  //   https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L3341
  //
  TCVTypeCompile3Sym = packed record
    Header: TCVTypeRecordHeader;

    Flags: Cardinal;            { Bit field:
                                  iLanguage       :  8;   // Language index. A value from TCVSourceLanguage.
                                  fEC             :  1;   // Compiled for E/C
                                  fNoDbgInfo      :  1;   // Not compiled with debug info
                                  fLTCG           :  1;   // Compiled with LTCG
                                  fNoDataAlign    :  1;   // Compiled with -Bzalign
                                  fManagedPresent :  1;   // Managed code/data present
                                  fSecurityChecks :  1;   // Compiled with /GS
                                  fHotPatch       :  1;   // Compiled with /hotpatch
                                  fCVTCIL         :  1;   // Converted with CVTCIL
                                  fMSILModule     :  1;   // MSIL netmodule
                                  fSdl            :  1;   // Compiled with /sdl
                                  fPGO            :  1;   // Compiled with /ltcg:pgo or pgu
                                  fExp            :  1;   // .exp module
                                  pad             : 12;   // Reserved, must be 0
                                }
    Machine: Word;              // Target processor: CVCPUType

    VersionFrontEndMajor: Word; // Front end major version #
    VersionFrontEndMinor: Word; // Front end minor version #
    VersionFrontEndBuild: Word; // Front end build version #
    VersionFrontEndQFE: Word;   // Front end QFE version #

    VersionBackendMajor: Word;  // Back end major version #
    VersionBackendMinor: Word;  // Back end minor version #
    VersionBackendBuild: Word;  // Back end build version #
    VersionBackendQFE: Word;    // Back end QFE version #

    { Variable length elements follows:
    VersionName: AnsiString;    // Zero terminated compiler version string
    }
  end;


type
  //
  // RecordKind = S_PUB32
  //
  // LLVM: PublicSym32Header / PublicSym32
  //
  //   https://llvm.org/doxygen/structllvm_1_1codeview_1_1PublicSym32Header.html
  //
  // MS: PUBSYM32
  //
  //   https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L3696
  //
  TCVPublicSym32 = packed record
    Header: TCVTypeRecordHeader;

    Flags: Cardinal;            // CVPubSymFlags

    Offset: Cardinal;           // Offset, relative to segment

    Segment: Word;              // Segment #

    { Variable length elements follows:
    Name: AnsiString;           // Zero terminated name
    }
  private
    function GetName: UTF8String;
  public
    property Name: UTF8String read GetName;
  end;

  //
  // MS: CV_PUBSYMFLAGS_e / CV_PUBSYMFLAGS
  //
  CVPubSymFlags = (
    cvpsfNone     = 0,
    cvpsfCode     = $00000001,  // Set if public symbol refers to a code address
    cvpsfFunction = $00000002,  // Set if public symbol is a function
    cvpsfManaged  = $00000004,  // Set if managed code (native or IL)
    cvpsfMSIL     = $00000008   // Set if managed IL code
  );


type
  //
  // RecordKind = S_GPROC32
  //
  // LLVM: ProcSym
  //
  //   https://llvm.org/doxygen/classllvm_1_1codeview_1_1ProcSym.html
  //
  // MS: PROCSYM32
  //
  //   https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L3722
  //
  TCVProcSym = packed record
    Header: TCVTypeRecordHeader;

    // Pointer values appear to be offsets in symbol stream. Specifically, offsets
    // to the first byte after the Header.
    OffsetParent: Cardinal;     // Pointer to the parent
    OffsetEnd: Cardinal;        // Pointer to this blocks end
    OffsetNext: Cardinal;       // Pointer to next symbol

    CodeSize: Cardinal;         // Proc length
    DbgStart: Cardinal;         // Debug start offset - relative to CodeOffset
    DbgEnd: Cardinal;           // Debug end offset - relative to CodeOffset
    FunctionType: Cardinal;     // Type index or ID
    CodeOffset: Cardinal;       // Offset, relative to segment
    Segment: Word;              // Segment #
    Flags: Byte;                // Bit mask of CVProcFlags values

    { Variable length elements follows:
    Name: AnsiString;           // Zero terminated name
    }
  end;

  //
  // MS: CV_PROCFLAGS
  // LLVM: ProcSymFlags
  //
  CVProcFlags = (
    CVPFlagNone                 = 0,
    CVPFlagHasFP                = $01,  // Frame pointer present
    CVPFlagHasIntRet            = $02,  // Interrupt return
    CVPFlagHasFarRet            = $04,  // Far return
    CVPFlagIsNoReturn           = $08,  // Function does not return
    CVPFlagIsUnreachable        = $10,  // Label isn't fallen into
    CVPFlagHasCustomCallConv    = $20,  // Custom calling convention
    CVPFlagIsNoInline           = $40,  // Function marked as noinline
    CVPFlagHasOptimizedDebugInfo= $80   // Function has debug information for optimized code
  );


type
  //
  // RecordKind = S_END
  //
  // LLVM: ScopeEndSym
  //
  //   https://llvm.org/doxygen/classllvm_1_1codeview_1_1ScopeEndSym.html
  //
  // MS: (none)
  //
  //   https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h
  //
  TCVScopeEndSym = packed record
    Header: TCVTypeRecordHeader;
  end;


type
  //
  // MS: CV_DebugSSubsectionHeader_t
  //
  // LLVM: DebugSubsectionHeader
  //
  TCVDebugSubsectionHeader = packed record
    Kind: Cardinal;             // DebugSubsectionKind
    Length: Cardinal;           // number of bytes occupied by this record.
  end;

  DebugSubsectionKind = (
    None                = $00,
    Symbols             = $f1,
    Lines               = $f2,
    StringTable         = $f3,
    FileChecksums       = $f4,
    FrameData           = $f5,
    InlineeLines        = $f6,
    CrossScopeImports   = $f7,
    CrossScopeExports   = $f8,

    // These appear to relate to .Net assembly info.
    ILLines             = $f9,
    FuncMDTokenMap      = $fa,
    TypeMDTokenMap      = $fb,
    MergedAssemblyInput = $fc,

    CoffSymbolRVA       = $fd
  );

// If the subsection kind has this bit set, then the linker should ignore it.
const
  SubsectionIgnoreFlag: Cardinal = $80000000;


type
  //
  // LLVM: LineFragmentHeader
  //
  //   https://llvm.org/doxygen/structllvm_1_1codeview_1_1LineFragmentHeader.html
  //
  // MS: CV_DebugSLinesHeader_t
  //
  //   https://github.com/Microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L4601
  //
  TCVLineFragmentHeader = packed record
    RelocOffset: Cardinal;      // Code offset of line contribution.

    RelocSegment: Word;         // Code segment of line contribution.

    Flags: Word;                // See CVLineFragmentFlags enumeration below.

    CodeSize: Cardinal;         // Code size of this line contribution.
  end;

  CVLineFragmentFlags = (
    LF_None             = 0,
    LF_HaveColumns      = 1     // CV_LINES_HAVE_COLUMNS
  );


  //
  // LLVM: LineBlockFragmentHeader
  //
  //   https://llvm.org/doxygen/structllvm_1_1codeview_1_1LineBlockFragmentHeader.html
  //
  // MS: CV_DebugSLinesFileBlockHeader_t
  //
  //   https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L4608
  //
  TCVLineBlockFragmentHeader = packed record
    NameIndex: Cardinal;        // Offset of FileChecksum entry in File
                                // checksums buffer.  The checksum entry then
                                // contains another offset into the string
                                // table of the actual name.

    NumLines: Cardinal;         // Number of lines.

    BlockSize: Cardinal;        // Size of this structure, in bytes, including the Lines and
                                // Columns members.

    { Variable length elements follows:

    Lines: TCVLineNumberEntry[NumLines];
    Columns: TCVColumnNumberEntry[NumLines]
    }
  end;


  //
  // LLVM : LineNumberEntry
  //
  //   https://llvm.org/doxygen/structllvm_1_1codeview_1_1LineNumberEntry.html
  //
  // MS: CV_Line_t
  //
  //   https://github.com/microsoft/microsoft-pdb/blob/master/include/cvinfo.h#L4621
  //
  TCVLineNumberEntry = packed record
    Offset: Cardinal;           // Offset to start of code bytes for line number.

    Flags: Cardinal;            // Line number. Encoded as a bitfield:
                                //   Start:24           Line where statement/expression starts
                                //   End:7              Delta to line where statement ends (optional)
                                //   IsStatement:1      If 1 a statement linenumber, if 0 an expression line num
                                // Use CVLineMask enum to decode.
  end;

  CVLineMask = (
    StartLineMask       = integer($00ffffff),
    EndLineDeltaMask    = integer($7f000000),
    StatementFlag       = integer($80000000)
  );


type
  //
  // MS: CV_SourceChksum_t
  //
  // LLVM: FileChecksumKind
  //
  //   https://llvm.org/doxygen/namespacellvm_1_1codeview.html#ac62eaa823ce96895afe82d6676aaae21
  //
  FileChecksumKind = (None, MD5, SHA1, SHA256);

  //
  // FileChecksumEntryHeader
  //
  TCVFileChecksumEntryHeader = packed record
    FileNameOffset: Cardinal;   // Byte offset of filename in global string table.

    ChecksumSize: Byte;         // Number of bytes of checksum.

    ChecksumKind: Byte;         // TFileChecksumKind

    { Variable length elements follows:

    Checksum: Byte[];           // The bytes of the checksum.
    }
  end;


implementation

const
  // Map TCVSymbolRecordKind value to its name.
  // The array must be ordered by value since we're doing a binary search on it.
  SymbolTypeNames: array[0..195] of record
    Value: CVSymbolRecordKind;
    Name: UTF8String;
  end = (
    (Value: CVSymbolRecordKind.S_COMPILE;             Name: 'S_COMPILE'),
    (Value: CVSymbolRecordKind.S_REGISTER_16t;        Name: 'S_REGISTER_16t'),
    (Value: CVSymbolRecordKind.S_CONSTANT_16t;        Name: 'S_CONSTANT_16t'),
    (Value: CVSymbolRecordKind.S_UDT_16t;             Name: 'S_UDT_16t'),
    (Value: CVSymbolRecordKind.S_SSEARCH;             Name: 'S_SSEARCH'),
    (Value: CVSymbolRecordKind.S_SKIP;                Name: 'S_SKIP'),
    (Value: CVSymbolRecordKind.S_CVRESERVE;           Name: 'S_CVRESERVE'),
    (Value: CVSymbolRecordKind.S_OBJNAME_ST;          Name: 'S_OBJNAME_ST'),
    (Value: CVSymbolRecordKind.S_ENDARG;              Name: 'S_ENDARG'),
    (Value: CVSymbolRecordKind.S_COBOLUDT_16t;        Name: 'S_COBOLUDT_16t'),
    (Value: CVSymbolRecordKind.S_MANYREG_16t;         Name: 'S_MANYREG_16t'),
    (Value: CVSymbolRecordKind.S_RETURN;              Name: 'S_RETURN'),
    (Value: CVSymbolRecordKind.S_ENTRYTHIS;           Name: 'S_ENTRYTHIS'),
    (Value: CVSymbolRecordKind.S_BPREL16;             Name: 'S_BPREL16'),
    (Value: CVSymbolRecordKind.S_LDATA16;             Name: 'S_LDATA16'),
    (Value: CVSymbolRecordKind.S_GDATA16;             Name: 'S_GDATA16'),
    (Value: CVSymbolRecordKind.S_PUB16;               Name: 'S_PUB16'),
    (Value: CVSymbolRecordKind.S_LPROC16;             Name: 'S_LPROC16'),
    (Value: CVSymbolRecordKind.S_GPROC16;             Name: 'S_GPROC16'),
    (Value: CVSymbolRecordKind.S_THUNK16;             Name: 'S_THUNK16'),
    (Value: CVSymbolRecordKind.S_BLOCK16;             Name: 'S_BLOCK16'),
    (Value: CVSymbolRecordKind.S_WITH16;              Name: 'S_WITH16'),
    (Value: CVSymbolRecordKind.S_LABEL16;             Name: 'S_LABEL16'),
    (Value: CVSymbolRecordKind.S_CEXMODEL16;          Name: 'S_CEXMODEL16'),
    (Value: CVSymbolRecordKind.S_VFTABLE16;           Name: 'S_VFTABLE16'),
    (Value: CVSymbolRecordKind.S_REGREL16;            Name: 'S_REGREL16'),
    (Value: CVSymbolRecordKind.S_BPREL32_16t;         Name: 'S_BPREL32_16t'),
    (Value: CVSymbolRecordKind.S_LDATA32_16t;         Name: 'S_LDATA32_16t'),
    (Value: CVSymbolRecordKind.S_GDATA32_16t;         Name: 'S_GDATA32_16t'),
    (Value: CVSymbolRecordKind.S_PUB32_16t;           Name: 'S_PUB32_16t'),
    (Value: CVSymbolRecordKind.S_LPROC32_16t;         Name: 'S_LPROC32_16t'),
    (Value: CVSymbolRecordKind.S_GPROC32_16t;         Name: 'S_GPROC32_16t'),
    (Value: CVSymbolRecordKind.S_THUNK32_ST;          Name: 'S_THUNK32_ST'),
    (Value: CVSymbolRecordKind.S_BLOCK32_ST;          Name: 'S_BLOCK32_ST'),
    (Value: CVSymbolRecordKind.S_WITH32_ST;           Name: 'S_WITH32_ST'),
    (Value: CVSymbolRecordKind.S_LABEL32_ST;          Name: 'S_LABEL32_ST'),
    (Value: CVSymbolRecordKind.S_CEXMODEL32;          Name: 'S_CEXMODEL32'),
    (Value: CVSymbolRecordKind.S_VFTABLE32_16t;       Name: 'S_VFTABLE32_16t'),
    (Value: CVSymbolRecordKind.S_REGREL32_16t;        Name: 'S_REGREL32_16t'),
    (Value: CVSymbolRecordKind.S_LTHREAD32_16t;       Name: 'S_LTHREAD32_16t'),
    (Value: CVSymbolRecordKind.S_GTHREAD32_16t;       Name: 'S_GTHREAD32_16t'),
    (Value: CVSymbolRecordKind.S_SLINK32;             Name: 'S_SLINK32'),
    (Value: CVSymbolRecordKind.S_LPROCMIPS_16t;       Name: 'S_LPROCMIPS_16t'),
    (Value: CVSymbolRecordKind.S_GPROCMIPS_16t;       Name: 'S_GPROCMIPS_16t'),
    (Value: CVSymbolRecordKind.S_PROCREF_ST;          Name: 'S_PROCREF_ST'),
    (Value: CVSymbolRecordKind.S_DATAREF_ST;          Name: 'S_DATAREF_ST'),
    (Value: CVSymbolRecordKind.S_ALIGN;               Name: 'S_ALIGN'),
    (Value: CVSymbolRecordKind.S_LPROCREF_ST;         Name: 'S_LPROCREF_ST'),
    (Value: CVSymbolRecordKind.S_OEM;                 Name: 'S_OEM'),
    (Value: CVSymbolRecordKind.S_TI16_MAX;            Name: 'S_TI16_MAX'),
    (Value: CVSymbolRecordKind.S_REGISTER_ST;         Name: 'S_REGISTER_ST'),
    (Value: CVSymbolRecordKind.S_CONSTANT_ST;         Name: 'S_CONSTANT_ST'),
    (Value: CVSymbolRecordKind.S_UDT_ST;              Name: 'S_UDT_ST'),
    (Value: CVSymbolRecordKind.S_COBOLUDT_ST;         Name: 'S_COBOLUDT_ST'),
    (Value: CVSymbolRecordKind.S_MANYREG_ST;          Name: 'S_MANYREG_ST'),
    (Value: CVSymbolRecordKind.S_BPREL32_ST;          Name: 'S_BPREL32_ST'),
    (Value: CVSymbolRecordKind.S_LDATA32_ST;          Name: 'S_LDATA32_ST'),
    (Value: CVSymbolRecordKind.S_GDATA32_ST;          Name: 'S_GDATA32_ST'),
    (Value: CVSymbolRecordKind.S_PUB32_ST;            Name: 'S_PUB32_ST'),
    (Value: CVSymbolRecordKind.S_LPROC32_ST;          Name: 'S_LPROC32_ST'),
    (Value: CVSymbolRecordKind.S_GPROC32_ST;          Name: 'S_GPROC32_ST'),
    (Value: CVSymbolRecordKind.S_VFTABLE32;           Name: 'S_VFTABLE32'),
    (Value: CVSymbolRecordKind.S_REGREL32_ST;         Name: 'S_REGREL32_ST'),
    (Value: CVSymbolRecordKind.S_LTHREAD32_ST;        Name: 'S_LTHREAD32_ST'),
    (Value: CVSymbolRecordKind.S_GTHREAD32_ST;        Name: 'S_GTHREAD32_ST'),
    (Value: CVSymbolRecordKind.S_LPROCMIPS_ST;        Name: 'S_LPROCMIPS_ST'),
    (Value: CVSymbolRecordKind.S_GPROCMIPS_ST;        Name: 'S_GPROCMIPS_ST'),
    (Value: CVSymbolRecordKind.S_COMPILE2_ST;         Name: 'S_COMPILE2_ST'),
    (Value: CVSymbolRecordKind.S_MANYREG2_ST;         Name: 'S_MANYREG2_ST'),
    (Value: CVSymbolRecordKind.S_LPROCIA64_ST;        Name: 'S_LPROCIA64_ST'),
    (Value: CVSymbolRecordKind.S_GPROCIA64_ST;        Name: 'S_GPROCIA64_ST'),
    (Value: CVSymbolRecordKind.S_LOCALSLOT_ST;        Name: 'S_LOCALSLOT_ST'),
    (Value: CVSymbolRecordKind.S_PARAMSLOT_ST;        Name: 'S_PARAMSLOT_ST'),
    (Value: CVSymbolRecordKind.S_GMANPROC_ST;         Name: 'S_GMANPROC_ST'),
    (Value: CVSymbolRecordKind.S_LMANPROC_ST;         Name: 'S_LMANPROC_ST'),
    (Value: CVSymbolRecordKind.S_RESERVED1;           Name: 'S_RESERVED1'),
    (Value: CVSymbolRecordKind.S_RESERVED2;           Name: 'S_RESERVED2'),
    (Value: CVSymbolRecordKind.S_RESERVED3;           Name: 'S_RESERVED3'),
    (Value: CVSymbolRecordKind.S_RESERVED4;           Name: 'S_RESERVED4'),
    (Value: CVSymbolRecordKind.S_LMANDATA_ST;         Name: 'S_LMANDATA_ST'),
    (Value: CVSymbolRecordKind.S_GMANDATA_ST;         Name: 'S_GMANDATA_ST'),
    (Value: CVSymbolRecordKind.S_MANFRAMEREL_ST;      Name: 'S_MANFRAMEREL_ST'),
    (Value: CVSymbolRecordKind.S_MANREGISTER_ST;      Name: 'S_MANREGISTER_ST'),
    (Value: CVSymbolRecordKind.S_MANSLOT_ST;          Name: 'S_MANSLOT_ST'),
    (Value: CVSymbolRecordKind.S_MANMANYREG_ST;       Name: 'S_MANMANYREG_ST'),
    (Value: CVSymbolRecordKind.S_MANREGREL_ST;        Name: 'S_MANREGREL_ST'),
    (Value: CVSymbolRecordKind.S_MANMANYREG2_ST;      Name: 'S_MANMANYREG2_ST'),
    (Value: CVSymbolRecordKind.S_MANTYPREF;           Name: 'S_MANTYPREF'),
    (Value: CVSymbolRecordKind.S_UNAMESPACE_ST;       Name: 'S_UNAMESPACE_ST'),
    (Value: CVSymbolRecordKind.S_ST_MAX;              Name: 'S_ST_MAX'),
    (Value: CVSymbolRecordKind.S_WITH32;              Name: 'S_WITH32'),
    (Value: CVSymbolRecordKind.S_MANYREG;             Name: 'S_MANYREG'),
    (Value: CVSymbolRecordKind.S_LPROCMIPS;           Name: 'S_LPROCMIPS'),
    (Value: CVSymbolRecordKind.S_GPROCMIPS;           Name: 'S_GPROCMIPS'),
    (Value: CVSymbolRecordKind.S_MANYREG2;            Name: 'S_MANYREG2'),
    (Value: CVSymbolRecordKind.S_LPROCIA64;           Name: 'S_LPROCIA64'),
    (Value: CVSymbolRecordKind.S_GPROCIA64;           Name: 'S_GPROCIA64'),
    (Value: CVSymbolRecordKind.S_LOCALSLOT;           Name: 'S_LOCALSLOT'),
    (Value: CVSymbolRecordKind.S_PARAMSLOT;           Name: 'S_PARAMSLOT'),
    (Value: CVSymbolRecordKind.S_MANFRAMEREL;         Name: 'S_MANFRAMEREL'),
    (Value: CVSymbolRecordKind.S_MANREGISTER;         Name: 'S_MANREGISTER'),
    (Value: CVSymbolRecordKind.S_MANSLOT;             Name: 'S_MANSLOT'),
    (Value: CVSymbolRecordKind.S_MANMANYREG;          Name: 'S_MANMANYREG'),
    (Value: CVSymbolRecordKind.S_MANREGREL;           Name: 'S_MANREGREL'),
    (Value: CVSymbolRecordKind.S_MANMANYREG2;         Name: 'S_MANMANYREG2'),
    (Value: CVSymbolRecordKind.S_DATAREF;             Name: 'S_DATAREF'),
    (Value: CVSymbolRecordKind.S_ANNOTATIONREF;       Name: 'S_ANNOTATIONREF'),
    (Value: CVSymbolRecordKind.S_TOKENREF;            Name: 'S_TOKENREF'),
    (Value: CVSymbolRecordKind.S_GMANPROC;            Name: 'S_GMANPROC'),
    (Value: CVSymbolRecordKind.S_LMANPROC;            Name: 'S_LMANPROC'),
    (Value: CVSymbolRecordKind.S_ATTR_FRAMEREL;       Name: 'S_ATTR_FRAMEREL'),
    (Value: CVSymbolRecordKind.S_ATTR_REGISTER;       Name: 'S_ATTR_REGISTER'),
    (Value: CVSymbolRecordKind.S_ATTR_REGREL;         Name: 'S_ATTR_REGREL'),
    (Value: CVSymbolRecordKind.S_ATTR_MANYREG;        Name: 'S_ATTR_MANYREG'),
    (Value: CVSymbolRecordKind.S_SEPCODE;             Name: 'S_SEPCODE'),
    (Value: CVSymbolRecordKind.S_LOCAL_2005;          Name: 'S_LOCAL_2005'),
    (Value: CVSymbolRecordKind.S_DEFRANGE_2005;       Name: 'S_DEFRANGE_2005'),
    (Value: CVSymbolRecordKind.S_DEFRANGE2_2005;      Name: 'S_DEFRANGE2_2005'),
    (Value: CVSymbolRecordKind.S_DISCARDED;           Name: 'S_DISCARDED'),
    (Value: CVSymbolRecordKind.S_LPROCMIPS_ID;        Name: 'S_LPROCMIPS_ID'),
    (Value: CVSymbolRecordKind.S_GPROCMIPS_ID;        Name: 'S_GPROCMIPS_ID'),
    (Value: CVSymbolRecordKind.S_LPROCIA64_ID;        Name: 'S_LPROCIA64_ID'),
    (Value: CVSymbolRecordKind.S_GPROCIA64_ID;        Name: 'S_GPROCIA64_ID'),
    (Value: CVSymbolRecordKind.S_DEFRANGE_HLSL;       Name: 'S_DEFRANGE_HLSL'),
    (Value: CVSymbolRecordKind.S_GDATA_HLSL;          Name: 'S_GDATA_HLSL'),
    (Value: CVSymbolRecordKind.S_LDATA_HLSL;          Name: 'S_LDATA_HLSL'),
    (Value: CVSymbolRecordKind.S_LOCAL_DPC_GROUPSHARED; Name: 'S_LOCAL_DPC_GROUPSHARED'),
    (Value: CVSymbolRecordKind.S_DEFRANGE_DPC_PTR_TAG;  Name: 'S_DEFRANGE_DPC_PTR_TAG'),
    (Value: CVSymbolRecordKind.S_DPC_SYM_TAG_MAP;     Name: 'S_DPC_SYM_TAG_MAP'),
    (Value: CVSymbolRecordKind.S_ARMSWITCHTABLE;      Name: 'S_ARMSWITCHTABLE'),
    (Value: CVSymbolRecordKind.S_POGODATA;            Name: 'S_POGODATA'),
    (Value: CVSymbolRecordKind.S_INLINESITE2;         Name: 'S_INLINESITE2'),
    (Value: CVSymbolRecordKind.S_MOD_TYPEREF;         Name: 'S_MOD_TYPEREF'),
    (Value: CVSymbolRecordKind.S_REF_MINIPDB;         Name: 'S_REF_MINIPDB'),
    (Value: CVSymbolRecordKind.S_PDBMAP;              Name: 'S_PDBMAP'),
    (Value: CVSymbolRecordKind.S_GDATA_HLSL32;        Name: 'S_GDATA_HLSL32'),
    (Value: CVSymbolRecordKind.S_LDATA_HLSL32;        Name: 'S_LDATA_HLSL32'),
    (Value: CVSymbolRecordKind.S_GDATA_HLSL32_EX;     Name: 'S_GDATA_HLSL32_EX'),
    (Value: CVSymbolRecordKind.S_LDATA_HLSL32_EX;     Name: 'S_LDATA_HLSL32_EX'),
    (Value: CVSymbolRecordKind.S_FASTLINK;            Name: 'S_FASTLINK'),
    (Value: CVSymbolRecordKind.S_INLINEES;            Name: 'S_INLINEES'),
    (Value: CVSymbolRecordKind.S_END;                 Name: 'S_END'),
    (Value: CVSymbolRecordKind.S_INLINESITE_END;      Name: 'S_INLINESITE_END'),
    (Value: CVSymbolRecordKind.S_PROC_ID_END;         Name: 'S_PROC_ID_END'),
    (Value: CVSymbolRecordKind.S_THUNK32;             Name: 'S_THUNK32'),
    (Value: CVSymbolRecordKind.S_TRAMPOLINE;          Name: 'S_TRAMPOLINE'),
    (Value: CVSymbolRecordKind.S_SECTION;             Name: 'S_SECTION'),
    (Value: CVSymbolRecordKind.S_COFFGROUP;           Name: 'S_COFFGROUP'),
    (Value: CVSymbolRecordKind.S_EXPORT;              Name: 'S_EXPORT'),
    (Value: CVSymbolRecordKind.S_LPROC32;             Name: 'S_LPROC32'),
    (Value: CVSymbolRecordKind.S_GPROC32;             Name: 'S_GPROC32'),
    (Value: CVSymbolRecordKind.S_LPROC32_ID;          Name: 'S_LPROC32_ID'),
    (Value: CVSymbolRecordKind.S_GPROC32_ID;          Name: 'S_GPROC32_ID'),
    (Value: CVSymbolRecordKind.S_LPROC32_DPC;         Name: 'S_LPROC32_DPC'),
    (Value: CVSymbolRecordKind.S_LPROC32_DPC_ID;      Name: 'S_LPROC32_DPC_ID'),
    (Value: CVSymbolRecordKind.S_REGISTER;            Name: 'S_REGISTER'),
    (Value: CVSymbolRecordKind.S_PUB32;               Name: 'S_PUB32'),
    (Value: CVSymbolRecordKind.S_PROCREF;             Name: 'S_PROCREF'),
    (Value: CVSymbolRecordKind.S_LPROCREF;            Name: 'S_LPROCREF'),
    (Value: CVSymbolRecordKind.S_ENVBLOCK;            Name: 'S_ENVBLOCK'),
    (Value: CVSymbolRecordKind.S_INLINESITE;          Name: 'S_INLINESITE'),
    (Value: CVSymbolRecordKind.S_LOCAL;               Name: 'S_LOCAL'),
    (Value: CVSymbolRecordKind.S_DEFRANGE;            Name: 'S_DEFRANGE'),
    (Value: CVSymbolRecordKind.S_DEFRANGE_SUBFIELD;   Name: 'S_DEFRANGE_SUBFIELD'),
    (Value: CVSymbolRecordKind.S_DEFRANGE_REGISTER;   Name: 'S_DEFRANGE_REGISTER'),
    (Value: CVSymbolRecordKind.S_DEFRANGE_FRAMEPOINTER_REL;   Name: 'S_DEFRANGE_FRAMEPOINTER_REL'),
    (Value: CVSymbolRecordKind.S_DEFRANGE_SUBFIELD_REGISTER;  Name: 'S_DEFRANGE_SUBFIELD_REGISTER'),
    (Value: CVSymbolRecordKind.S_DEFRANGE_FRAMEPOINTER_REL_FULL_SCOPE; Name: 'S_DEFRANGE_FRAMEPOINTER_REL_FULL_SCOPE'),
    (Value: CVSymbolRecordKind.S_DEFRANGE_REGISTER_REL;       Name: 'S_DEFRANGE_REGISTER_REL'),
    (Value: CVSymbolRecordKind.S_BLOCK32;             Name: 'S_BLOCK32'),
    (Value: CVSymbolRecordKind.S_LABEL32;             Name: 'S_LABEL32'),
    (Value: CVSymbolRecordKind.S_OBJNAME;             Name: 'S_OBJNAME'),
    (Value: CVSymbolRecordKind.S_COMPILE2;            Name: 'S_COMPILE2'),
    (Value: CVSymbolRecordKind.S_COMPILE3;            Name: 'S_COMPILE3'),
    (Value: CVSymbolRecordKind.S_FRAMEPROC;           Name: 'S_FRAMEPROC'),
    (Value: CVSymbolRecordKind.S_CALLSITEINFO;        Name: 'S_CALLSITEINFO'),
    (Value: CVSymbolRecordKind.S_FILESTATIC;          Name: 'S_FILESTATIC'),
    (Value: CVSymbolRecordKind.S_HEAPALLOCSITE;       Name: 'S_HEAPALLOCSITE'),
    (Value: CVSymbolRecordKind.S_FRAMECOOKIE;         Name: 'S_FRAMECOOKIE'),
    (Value: CVSymbolRecordKind.S_CALLEES;             Name: 'S_CALLEES'),
    (Value: CVSymbolRecordKind.S_CALLERS;             Name: 'S_CALLERS'),
    (Value: CVSymbolRecordKind.S_UDT;                 Name: 'S_UDT'),
    (Value: CVSymbolRecordKind.S_COBOLUDT;            Name: 'S_COBOLUDT'),
    (Value: CVSymbolRecordKind.S_BUILDINFO;           Name: 'S_BUILDINFO'),
    (Value: CVSymbolRecordKind.S_BPREL32;             Name: 'S_BPREL32'),
    (Value: CVSymbolRecordKind.S_REGREL32;            Name: 'S_REGREL32'),
    (Value: CVSymbolRecordKind.S_CONSTANT;            Name: 'S_CONSTANT'),
    (Value: CVSymbolRecordKind.S_MANCONSTANT;         Name: 'S_MANCONSTANT'),
    (Value: CVSymbolRecordKind.S_LDATA32;             Name: 'S_LDATA32'),
    (Value: CVSymbolRecordKind.S_GDATA32;             Name: 'S_GDATA32'),
    (Value: CVSymbolRecordKind.S_LMANDATA;            Name: 'S_LMANDATA'),
    (Value: CVSymbolRecordKind.S_GMANDATA;            Name: 'S_GMANDATA'),
    (Value: CVSymbolRecordKind.S_LTHREAD32;           Name: 'S_LTHREAD32'),
    (Value: CVSymbolRecordKind.S_GTHREAD32;           Name: 'S_GTHREAD32'),
    (Value: CVSymbolRecordKind.S_UNAMESPACE;          Name: 'S_UNAMESPACE'),
    (Value: CVSymbolRecordKind.S_ANNOTATION;          Name: 'S_ANNOTATION')
  );


function TCVSymbol.Length: Byte;
begin
  Result := SizeOf(Header) + System.Length(Data);
end;

var
  CachedSymbolKind: CVSymbolRecordKind;
  CachedNameIndex: integer = -1;

class function TCVSymbol.Name(AKind: CVSymbolRecordKind): UTF8String;
begin
  // Well, this sucks!
  // E2134 Type 'TCVSymbolRecordKind' has no type info
  // Result := GetEnumName(TypeInfo(CVSymbolRecordKind), Ord(Kind));

  // Try to resolve lookup from cache
  // Not thread safe!
  if (CachedNameIndex <> -1) and (CachedSymbolKind = AKind) then
    Exit(SymbolTypeNames[CachedNameIndex].Name);

  // Binary search by Kind to get Name
  var L := Low(SymbolTypeNames);
  var H := High(SymbolTypeNames);

  while (L <= H) do
  begin
    var mid := L + (H - L) shr 1;

    if (AKind < SymbolTypeNames[mid].Value) then
      H := mid - 1
    else
    if (AKind > SymbolTypeNames[mid].Value) then
      L := mid + 1
    else
    begin
      CachedSymbolKind := AKind;
      CachedNameIndex := mid;
      Exit(SymbolTypeNames[mid].Name);
    end;
  end;

  Assert(False, 'Failed to find TCVSymbol.Name');
end;

function TCVSymbol.Name: UTF8String;
begin
  Result := TCVSymbol.Name(CVSymbolRecordKind(Header.RecordKind));
end;

{ TPublicSym32 }

function TCVPublicSym32.GetName: UTF8String;
begin
  // Note: string is length prefixed so we skip that with +SizeOf(Word)
  // No it's not. Maybe in an older version of PDB ist was.

  Result := PAnsiChar(pointer(NativeUInt(@Self) + SizeOf(Self) { + SizeOf(Word)}));
end;

end.

