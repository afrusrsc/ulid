{*******************************************************************************
*  Copyright (c) 2023 Jesse Jin Authors. All rights reserved.                  *
*                                                                              *
*  Use of this source code is governed by a MIT-style                          *
*  license that can be found in the LICENSE file.                              *
*                                                                              *
*  版权由作者 Jesse Jin 所有。                                                 *
*  此源码的使用受 MIT 开源协议约束，详见 LICENSE 文件。                        *
*******************************************************************************}

{*******************************************************************************
  ULID 通用唯一按字典排序的标识符

  内存模型：48位UNIX时间戳(毫秒) + 80位随机数
  +---------------------------------+---------------------------------+
  | 0                               | 1                               |
  | 0 1 2 3 4 5 6 7 8 9 A B C D E F | 0 1 2 3 4 5 6 7 8 9 A B C D E F |
  +---------------------------------+---------------------------------+
  |                      32_bit_uint_time_high                        |
  +---------------------------------+---------------------------------+
  |       16_bit_uint_time_low      |       16_bit_uint_random        |
  +---------------------------------+---------------------------------+
  |                       32_bit_uint_random                          |
  +---------------------------------+---------------------------------+
  |                       32_bit_uint_random                          |
  +---------------------------------+---------------------------------+
  编码后模型：10位UNIX时间戳字符 + 16位随机数字符
*******************************************************************************}
unit uULID;

{$mode ObjFPC}{$H+}
{$modeswitch ADVANCEDRECORDS}

interface

uses
  Classes, SysUtils, DateUtils;

type
  EULID = class(Exception);

  //48位时间戳
  TUInt48 = packed record
    Data: array[0..5] of byte;
  end;

  { TUInt48Helper }

  TUInt48Helper = record helper for TUInt48
    procedure Create(AValue: int64); overload;
    procedure Create(AValue: TDateTime; AIsUTC: boolean = True); overload;
    function ToTimestamp: int64;
    function ToDateTime(AIsUTC: boolean = True): TDateTime;
    function Encode: string;
  end;

  //80位随机数
  TUInt80 = packed record
    case integer of
      0: (
        Data: array[0..9] of byte;
      );
      1: (
        hi16: word;
        lo64: uint64;
      );
  end;

  //随机数生成器
  TRandomGenerator = procedure(out AData: TBytes);

  { TUInt80Helper }

  TUInt80Helper = record helper for TUInt80
    procedure Create(ARand: TRandomGenerator = nil);
    function Encode: string;
    function Add(N: uint64): boolean;
    function IsZero: boolean;
  end;

  //ULID
  TULID = packed record
    case integer of
      0: (
        Data: array[0..15] of byte;
      );
      1: (
        t: TUInt48; //时间戳
        r: TUInt80; //随机数
      );
  end;

  { TULIDHelper }

  TULIDHelper = record helper for TULID
    class function Create: TULID; overload; static;
    class function Create(ATimestamp: int64; ARand: TRandomGenerator = nil): TULID;
      overload; static;
    class function Create(ADateTime: TDateTime; AIsUTC: boolean = True;
      ARand: TRandomGenerator = nil): TULID; overload; static;
    function Encode: string;
    function Decode(AValue: string): boolean;
    function ToTimestamp: int64;
    function ToDateTime(AIsUTC: boolean = True): TDateTime;
  end;

implementation

const
  //最大时间戳
  MaxTime = uint64($0000FFFFFFFFFFFF);
  //Crockford's base32 符号集
  Symbols = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  BitsMask = $1F;

  ULIDSize = 16; //ULID大小
  ULIDLen = 26;  //ULID编码后长度
  TimeSize = 6;  //时间戳部分的大小
  TimeLen = 10;  //时间戳部分编码后长度
  RandSize = 10; //随机数部分的大小
  RnadLen = 16;  //随机数部分编码后长度

  //解码表
  DecodeTable: array[0..$FF] of byte = (
    //0   1    2    3    4    5    6    7    8    9    A    B    C    D    E    F
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //0
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //1
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //2
    000, 001, 002, 003, 004, 005, 006, 007, 008, 009, $FF, $FF, $FF, $FF, $FF, $FF, //3
    $FF, 010, 011, 012, 013, 014, 015, 016, 017, $FF, 018, 019, $FF, 020, 021, $FF, //4
    022, 023, 024, 025, 026, $FF, 027, 028, 029, 030, 031, $FF, $FF, $FF, $FF, $FF, //5
    $FF, 010, 011, 012, 013, 014, 015, 016, 017, $FF, 018, 019, $FF, 020, 021, $FF, //6
    022, 023, 024, 025, 026, $FF, 027, 028, 029, 030, 031, $FF, $FF, $FF, $FF, $FF, //7
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //8
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //9
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //A
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //B
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //C
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //D
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, //E
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF  //F
    );

//时间转时间戳
function DateTimeToTimestamp(const AValue: TDateTime;
  AInputIsUTC: boolean = True): int64;
begin
  Result := DateTimeToUnix(AValue, AInputIsUTC) * 1000 + MilliSecondOf(AValue);
end;

//时间戳转时间
function TimestampToDateTime(const AValue: int64;
  aReturnUTC: boolean = True): TDateTime;
begin
  Result := IncMilliSecond(UnixEpoch, AValue);
  if not aReturnUTC then
    Result := IncMinute(Result, -GetLocalTimeOffset);
end;

//默认的随机数生成器
procedure DefaultRandomGenerator(out AData: TBytes);
var
  i: integer;
begin
  SetLength(AData, RandSize);
  for i := 0 to RandSize - 1 do
  begin
    Randomize;
    AData[i] := Random(256);
  end;
end;

{ TULIDHelper }

class function TULIDHelper.Create: TULID;
begin
  Result := Create(Now, False);
end;

class function TULIDHelper.Create(ATimestamp: int64; ARand: TRandomGenerator): TULID;
begin
  Result.t.Create(ATimestamp);
  Result.r.Create(ARand);
end;

class function TULIDHelper.Create(ADateTime: TDateTime; AIsUTC: boolean;
  ARand: TRandomGenerator): TULID;
begin
  Result.t.Create(ADateTime, AIsUTC);
  Result.r.Create(ARand);
end;

function TULIDHelper.Encode: string;
begin
  Result := Self.t.Encode + Self.r.Encode;
end;

function TULIDHelper.Decode(AValue: string): boolean;
begin
  Result := False;
  if Length(AValue) <> ULIDLen then
    Exit;
  FillByte(Self.Data, ULIDSize, 0);
  //时间戳
  Self.Data[0] := ((DecodeTable[Ord(AValue[1])] shl 5) or
    DecodeTable[Ord(AValue[2])]) and $FF;
  Self.Data[1] := ((DecodeTable[Ord(AValue[3])] shl 3) or
    (DecodeTable[Ord(AValue[4])] shr 2)) and $FF;
  Self.Data[2] := ((DecodeTable[Ord(AValue[4])] shl 6) or
    (DecodeTable[Ord(AValue[5])] shl 1) or (DecodeTable[Ord(AValue[6])] shr 4)) and $FF;
  Self.Data[3] := ((DecodeTable[Ord(AValue[6])] shl 4) or
    (DecodeTable[Ord(AValue[7])] shr 1)) and $FF;
  Self.Data[4] := ((DecodeTable[Ord(AValue[7])] shl 7) or
    (DecodeTable[Ord(AValue[8])] shl 2) or (DecodeTable[Ord(AValue[9])] shr 3)) and $FF;
  Self.Data[5] := ((DecodeTable[Ord(AValue[9])] shl 5) or
    (DecodeTable[Ord(AValue[10])])) and $FF;
  //随机数分组1
  Self.Data[6] := ((DecodeTable[Ord(AValue[11])] shl 3) or
    (DecodeTable[Ord(AValue[12])] shr 2)) and $FF;
  Self.Data[7] := ((DecodeTable[Ord(AValue[12])] shl 6) or
    (DecodeTable[Ord(AValue[13])] shl 1) or (DecodeTable[Ord(AValue[14])] shr
    4)) and $FF;
  Self.Data[8] := ((DecodeTable[Ord(AValue[14])] shl 4) or
    (DecodeTable[Ord(AValue[15])] shr 1)) and $FF;
  Self.Data[9] := ((DecodeTable[Ord(AValue[15])] shl 7) or
    (DecodeTable[Ord(AValue[16])] shl 2) or (DecodeTable[Ord(AValue[17])] shr
    3)) and $FF;
  Self.Data[10] := ((DecodeTable[Ord(AValue[17])] shl 5) or
    DecodeTable[Ord(AValue[18])]) and $FF;
  //随机数分组2
  Self.Data[11] := ((DecodeTable[Ord(AValue[19])] shl 3) or
    (DecodeTable[Ord(AValue[20])] shr 2)) and $FF;
  Self.Data[12] := ((DecodeTable[Ord(AValue[20])] shl 6) or
    (DecodeTable[Ord(AValue[21])] shl 1) or (DecodeTable[Ord(AValue[22])] shr
    4)) and $FF;
  Self.Data[13] := ((DecodeTable[Ord(AValue[22])] shl 4) or
    (DecodeTable[Ord(AValue[23])] shr 1)) and $FF;
  Self.Data[14] := ((DecodeTable[Ord(AValue[23])] shl 7) or
    (DecodeTable[Ord(AValue[24])] shl 2) or (DecodeTable[Ord(AValue[25])] shr
    3)) and $FF;
  Self.Data[15] := ((DecodeTable[Ord(AValue[25])] shl 5) or
    (DecodeTable[Ord(AValue[26])])) and $FF;
  Result := True;
end;

function TULIDHelper.ToTimestamp: int64;
begin
  Result := Self.t.ToTimestamp;
end;

function TULIDHelper.ToDateTime(AIsUTC: boolean): TDateTime;
begin
  Result := Self.t.ToDateTime(AIsUTC);
end;

{ TUInt80Helper }

procedure TUInt80Helper.Create(ARand: TRandomGenerator);
var
  bs: TBytes;
  l: integer;
begin
  if Assigned(ARand) then
    ARand(bs)
  else
    DefaultRandomGenerator(bs);
  l := Length(bs);
  if l >= RandSize then
    Move(bs[0], Self.Data[0], RandSize)
  else
  begin
    Move(bs[0], Self.Data[0], l);
    //不足的部分用默认生成器填充
    DefaultRandomGenerator(bs);
    Move(bs[0], Self.Data[l], RandSize - l);
  end;
end;

function TUInt80Helper.Encode: string;
begin
  Result := '';
  SetLength(Result, 16);
  //随机数分组1
  Result[1] := Symbols[(Self.Data[0] shr 3) and BitsMask + 1];
  Result[2] := Symbols[((Self.Data[0] shl 2) or (Self.Data[1] shr 6)) and BitsMask + 1];
  Result[3] := Symbols[(Self.Data[1] shr 1) and BitsMask + 1];
  Result[4] := Symbols[((Self.Data[1] shl 4) or (Self.Data[2] shr 4)) and BitsMask + 1];
  Result[5] := Symbols[((Self.Data[2] shl 1) or (Self.Data[3] shr 7)) and BitsMask + 1];
  Result[6] := Symbols[(Self.Data[3] shr 2) and BitsMask + 1];
  Result[7] := Symbols[((Self.Data[3] shl 3) or (Self.Data[4] shr 5)) and BitsMask + 1];
  Result[8] := Symbols[Self.Data[4] and BitsMask + 1];
  //随机数分组2
  Result[9] := Symbols[(Self.Data[5] shr 3) and BitsMask + 1];
  Result[10] := Symbols[((Self.Data[5] shl 2) or (Self.Data[6] shr 6)) and BitsMask + 1];
  Result[11] := Symbols[(Self.Data[6] shr 1) and BitsMask + 1];
  Result[12] := Symbols[((Self.Data[6] shl 4) or (Self.Data[7] shr 4)) and BitsMask + 1];
  Result[13] := Symbols[((Self.Data[7] shl 1) or (Self.Data[8] shr 7)) and BitsMask + 1];
  Result[14] := Symbols[(Self.Data[8] shr 2) and BitsMask + 1];
  Result[15] := Symbols[((Self.Data[8] shl 3) or (Self.Data[9] shr 5)) and BitsMask + 1];
  Result[16] := Symbols[Self.Data[9] and BitsMask + 1];
end;

function TUInt80Helper.Add(N: uint64): boolean;
var
  oldHi, newHi: word;
  oldLo, newLo: uint64;
begin
  Result := False;
{$IFDEF ENDIAN_BIG}
  oldHi :=Self.hi16;
  oldLo := Self.lo64;
{$ELSE}
  oldHi := SwapEndian(Self.hi16);
  oldLo := SwapEndian(Self.lo64);
{$ENDIF}
  newHi := oldHi;
  newLo := (oldLo + N) and $FFFFFFFFFFFFFFFF;
  if newLo < oldLo then
    newHi := (newHi + 1) and $FFFF;
{$IFDEF ENDIAN_BIG}
  Self.hi16 := newHi;
  Self.lo64 := newLo;
{$ELSE}
  Self.hi16 := SwapEndian(newHi);
  Self.lo64 := SwapEndian(newLo);
{$ENDIF}
  Result := newHi >= oldHi;
end;

function TUInt80Helper.IsZero: boolean;
begin
  Result := (Self.hi16 = 0) and (Self.lo64 = 0);
end;

{ TUInt48Helper }

procedure TUInt48Helper.Create(AValue: int64);
begin
  if AValue > MaxTime then
    Exit;
  Self.Data[0] := (Hi(AValue) shr 8) and $FF;
  Self.Data[1] := Hi(AValue) and $FF;
  Self.Data[2] := (Lo(AValue) shr 24) and $FF;
  Self.Data[3] := (Lo(AValue) shr 16) and $FF;
  Self.Data[4] := (Lo(AValue) shr 8) and $FF;
  Self.Data[5] := Lo(AValue) and $FF;
end;

procedure TUInt48Helper.Create(AValue: TDateTime; AIsUTC: boolean);
var
  t: int64;
begin
  t := DateTimeToTimestamp(AValue, AIsUTC);
  Create(t);
end;

function TUInt48Helper.ToTimestamp: int64;
var
  i: byte;
begin
  Result := 0;
  for i in Self.Data do
    Result := ((Result shl 8) or i) and $FFFFFFFFFFFFFFFF;
end;

function TUInt48Helper.ToDateTime(AIsUTC: boolean): TDateTime;
begin
  Result := TimestampToDateTime(Self.ToTimestamp, AIsUTC);
end;

function TUInt48Helper.Encode: string;
begin
  Result := '';
  SetLength(Result, 10);
  Result[1] := Symbols[(Self.Data[0] shr 5) and BitsMask + 1];
  Result[2] := Symbols[Self.Data[0] and BitsMask + 1];
  Result[3] := Symbols[(Self.Data[1] shr 3) and BitsMask + 1];
  Result[4] := Symbols[((Self.Data[1] shl 2) or (Self.Data[2] shr 6)) and BitsMask + 1];
  Result[5] := Symbols[(Self.Data[2] shr 1) and BitsMask + 1];
  Result[6] := Symbols[((Self.Data[2] shl 4) or (Self.Data[3] shr 4)) and BitsMask + 1];
  Result[7] := Symbols[((Self.Data[3] shl 1) or (Self.Data[4] shr 7)) and BitsMask + 1];
  Result[8] := Symbols[(Self.Data[4] shr 2) and BitsMask + 1];
  Result[9] := Symbols[((Self.Data[4] shl 3) or (Self.Data[5] shr 5)) and BitsMask + 1];
  Result[10] := Symbols[Self.Data[5] and BitsMask + 1];
end;

end.
