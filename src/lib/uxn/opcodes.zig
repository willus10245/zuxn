const std = @import("std");

pub const BaseOpcode = enum(u5) {
    /// `( -- a )` (LIT)
    /// `( cond8 -- )` (JCI)
    /// `( -- )` (BRK, JMI)
    /// `( -- | pc )` (JSI)
    BRK,

    /// `(a -- a+1)`
    INC,

    /// `( a -- )`
    POP,

    /// `( a b -- b)`
    NIP,

    /// `( a b -- b a )`
    SWP,

    /// `( a b c -- b c a )`
    ROT,

    /// `( a -- a a )`
    DUP,

    /// `( a b -- a b a )`
    OVR,

    /// `( a b -- bool8 )`
    EQU,

    /// `( a b -- bool8 )`
    NEQ,

    /// `( a b -- bool8 )`
    GTH,

    /// `( a b -- bool8 )`
    LTH,

    /// `( addr -- )`
    JMP,

    /// `( cond8 addr -- )`
    JCN,

    /// `( addr -- | ret16 )`
    JSR,

    /// `( a -- | a)`
    STH,

    /// `( addr8 -- v )`
    LDZ,

    /// `( v addr8 -- )`
    STZ,

    /// `( addr8 -- v )`
    LDR,

    /// `( v addr8 -- )`
    STR,

    /// `( addr16 -- v )`
    LDA,

    /// `( v addr16 -- )`
    STA,

    /// `( dev8 -- v )`
    DEI,

    /// `( v dev8 -- )`
    DEO,

    /// `( a b -- a+b )`
    ADD,

    /// `( a b -- a-b )`
    SUB,

    /// `( a b -- a*b )`
    MUL,

    /// `( a b -- a/b )`
    DIV,

    /// `( a b -- a&b )`
    AND,

    /// `( a b -- a|b )`
    ORA,

    /// `( a b -- a^b )`
    EOR,

    /// `( a shift8 -- b )`
    SFT,
};

pub const Opcode = enum(u8) {
    // zig fmt: off
    // 0    1       2       3       4       5       6       7       8       9       a       b       c       d       e       f
    BRK,    INC,    POP,    NIP,    SWP,    ROT,    DUP,    OVR,    EQU,    NEQ,    GTH,    LTH,    JMP,    JCN,    JSR,    STH,
    LDZ,    STZ,    LDR,    STR,    LDA,    STA,    DEI,    DEO,    ADD,    SUB,    MUL,    DIV,    AND,    ORA,    EOR,    SFT,
    JCI,    INC2,   POP2,   NIP2,   SWP2,   ROT2,   DUP2,   OVR2,   EQU2,   NEQ2,   GTH2,   LTH2,   JMP2,   JCN2,   JSR2,   STH2,
    LDZ2,   STZ2,   LDR2,   STR2,   LDA2,   STA2,   DEI2,   DEO2,   ADD2,   SUB2,   MUL2,   DIV2,   AND2,   ORA2,   EOR2,   SFT2,
    JMI,    INCr,   POPr,   NIPr,   SWPr,   ROTr,   DUPr,   OVRr,   EQUr,   NEQr,   GTHr,   LTHr,   JMPr,   JCNr,   JSRr,   STHr,
    LDZr,   STZr,   LDRr,   STRr,   LDAr,   STAr,   DEIr,   DEOr,   ADDr,   SUBr,   MULr,   DIVr,   ANDr,   ORAr,   EORr,   SFTr,
    JSI,    INC2r,  POP2r,  NIP2r,  SWP2r,  ROT2r,  DUP2r,  OVR2r,  EQU2r,  NEQ2r,  GTH2r,  LTH2r,  JMP2r,  JCN2r,  JSR2r,  STH2r,
    LDZ2r,  STZ2r,  LDR2r,  STR2r,  LDA2r,  STA2r,  DEI2r,  DEO2r,  ADD2r,  SUB2r,  MUL2r,  DIV2r,  AND2r,  ORA2r,  EOR2r,  SFT2r,

    LIT,    INCk,   POPk,   NIPk,   SWPk,   ROTk,   DUPk,   OVRk,   EQUk,   NEQk,   GTHk,   LTHk,   JMPk,   JCNk,   JSRk,   STHk,
    LDZk,   STZk,   LDRk,   STRk,   LDAk,   STAk,   DEIk,   DEOk,   ADDk,   SUBk,   MULk,   DIVk,   ANDk,   ORAk,   EORk,   SFTk,
    LIT2,   INC2k,  POP2k,  NIP2k,  SWP2k,  ROT2k,  DUP2k,  OVR2k,  EQU2k,  NEQ2k,  GTH2k,  LTH2k,  JMP2k,  JCN2k,  JSR2k,  STH2k,
    LDZ2k,  STZ2k,  LDR2k,  STR2k,  LDA2k,  STA2k,  DEI2k,  DEO2k,  ADD2k,  SUB2k,  MUL2k,  DIV2k,  AND2k,  ORA2k,  EOR2k,  SFT2k,
    LITr,   INCkr,  POPkr,  NIPkr,  SWPkr,  ROTkr,  DUPkr,  OVRkr,  EQUkr,  NEQkr,  GTHkr,  LTHkr,  JMPkr,  JCNkr,  JSRkr,  STHkr,
    LDZkr,  STZkr,  LDRkr,  STRkr,  LDAkr,  STAkr,  DEIkr,  DEOkr,  ADDkr,  SUBkr,  MULkr,  DIVkr,  ANDkr,  ORAkr,  EORkr,  SFTkr,
    LIT2r,  INC2kr, POP2kr, NIP2kr, SWP2kr, ROT2kr, DUP2kr, OVR2kr, EQU2kr, NEQ2kr, GTH2kr, LTH2kr, JMP2kr, JCN2kr, JSR2kr, STH2kr,
    LDZ2kr, STZ2kr, LDR2kr, STR2kr, LDA2kr, STA2kr, DEI2kr, DEO2kr, ADD2kr, SUB2kr, MUL2kr, DIV2kr, AND2kr, ORA2kr, EOR2kr, SFT2kr,
    // zig fmt: on

    pub inline fn fromByte(raw: u8) Opcode {
        return @enumFromInt(raw);
    }

    pub inline fn asByte(opcode: Opcode) u8 {
        return @intFromEnum(opcode);
    }

    pub fn mnemonic(opcode: Opcode) []const u8 {
        return @tagName(opcode);
    }

    pub inline fn baseOpcode(opcode: Opcode) BaseOpcode {
        return @enumFromInt(@intFromEnum(opcode) & 0x1F);
    }

    pub inline fn shortMode(opcode: Opcode) bool {
        return (@intFromEnum(opcode) & 0x20) > 0;
    }

    pub inline fn returnMode(opcode: Opcode) bool {
        return (@intFromEnum(opcode) & 0x40) > 0;
    }

    pub inline fn keepMode(opcode: Opcode) bool {
        return (@intFromEnum(opcode) & 0x80) > 0;
    }

    pub inline fn operandType(opcode: Opcode) type {
        return if (opcode.shortMode()) u16 else u8;
    }
};
