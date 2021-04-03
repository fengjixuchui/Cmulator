{$IFDEF FPC}
    {$MODE Delphi}
    {$PackRecords C}
    {$AsmMode intel}
    {$SMARTLINK ON}
{$ENDIF}
unit Emu;


interface

uses
  Classes, SysUtils, cmem, strutils ,math,
  Unicorn_dyn , UnicornConst, X86Const,
  quickjs,
  Segments,Utils,PE_loader,xxHash,superobject,
  PE.Image,
  FnHook,TEP_PEB,
  Generics.Collections,Generics.Defaults,
  EThreads,
  Zydis,
  Zydis.Formatter;

type
  TLibs = TFastHashMap<String, TNewDll>;

  TOnExit = TFastHashMap<DWORD, THookFunction>;

  THookByName    = TFastHashMap<UInt64, THookFunction>;
  THookByOrdinal = TFastHashMap<UInt64, THookFunction>;
  THookByAddress = TFastHashMap<UInt64, THookFunction>;

  THooks = record
    ByName : THookByName;
    ByOrdinal : THookByOrdinal;
    ByAddr : THookByAddress;
  end;

  flush_r = record
    address : UInt64;
    value   : Int64;
    size    : UInt32;
  end;

  TApiRed = record
    count : Byte;
    first,
    last,
    _alias : string;
  end;
  TApiSetSchema = TFastHashMap<String, TApiRed>;

  TApiInfo = record
    ISAPI,
    APIHandled,
    CalledFromMainExe : Boolean;
  end;

{ TEmu }
  TEmu = class
  private
    CPU_MODE : uc_mode;
    FilePath, Shellcode : String;
    Is_x64, IsSC, Stop_Emu : Boolean;
    tmpbool : byte;

    Ferr : uc_err;

    // Segments things :D .
    gdt : PSegmentDescriptor;
    gdt_address,
    TEB_Address,
    PEB_address,
    fs_address,
    gs_address : UInt64;
    gdtr : uc_x86_mmr;

    // Stack Var.
    SP : Int64;

    PE,SCode : TMemoryStream;
    MapedPE : Pointer;

    // Handle Dlls and it's Memory .
    FLibs : TLibs;

    OnExitList : TOnExit;
  public

    Formatter : Zydis.Formatter.TZydisFormatter;

    Entry, LastGoodPC : UInt64;
    Flags : TFlags;
    r_cs,r_ss,r_ds,r_es,r_fs,r_gs : DWORD;

    MemFix : TStack<UInt64>;
    FlushMem : TStack<flush_r>;

    RunOnDll, IsException : Boolean;
    SEH_Handler : Int64;

    DLL_BASE_LOAD,
    DLL_NEXT_LOAD : UInt64;

    stack_size : Cardinal;
    stack_base,stack_limit : UInt64;

    PID : Cardinal;

    Img: TPEImage;
    uc : uc_engine;
    tContext : uc_context;
    Hooks : THooks;


    ApiSetSchema : TApiSetSchema;

    property TEB : UInt64 read TEB_Address write TEB_Address;
    property PEB : UInt64 read PEB_address write PEB_address;
    property Libs : TLibs read FLibs write FLibs;
    property isx64 : boolean read Is_x64;
    property isShellCode : Boolean read IsSC write IsSC;
    property Stop : boolean read Stop_Emu write Stop_Emu;
    property err : uc_err read Ferr write Ferr;

    procedure SetHooks();
    function MapPEtoUC() : Boolean;
    procedure Start();
    function SaveCPUState : Boolean;
    function RestoreCPUState : Boolean;
    procedure ResetEFLAGS();
    function init_segments() : boolean;
    function GetGDT(index : Integer): Pointer;
    constructor Create(_FilePath : string; _Shellcode, SCx64 : Boolean); virtual;
    destructor Destroy(); override;
  end;

var
  Ident : Cardinal = 0;
  lastExceptionHandler : UInt64 = 0;

implementation
  uses
    Globals,NativeHooks,JSPlugins_Engine;

function Handle_SEH(uc : uc_engine; ExceptionCode : DWORD): Boolean;
var
  ZwContinue , PC , Zer0 , Old_ESP , New_ESP : UInt64;
  SEH , SEH_Handler : Int64;
  i : UInt32;
  ExceptionRecord : EXCEPTION_RECORD_32;
  ContextRecord : CONTEXT_32;
  ExceptionRecord_Addr , ContextRecord_Addr : UInt64;
begin

  SEH := 0; PC := 0; ZwContinue := 0; Zer0 := 0; Old_ESP := 0; New_ESP := 0;

  Emulator.err := uc_reg_read(uc, ifthen(Emulator.isx64,UC_X86_REG_RSP,UC_X86_REG_ESP), @Old_ESP);

  Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @PC);
  ZwContinue := Utils.GetProcAddr(Utils.CmuGetModulehandle('ntdll'),'ZwContinue');

  SEH := ReadDword(Emulator.TEB);
  if Emulator.err <> UC_ERR_OK then
    Exit(False);

  if (SEH = 0) or
     (SEH = $FFFFFFFF) then
  begin
    TextColor(LightRed);
    Writeln('SEH Is 0xFFFFFFFF or 0');
    NormVideo;
    Exit(False);
  end;

  SEH_Handler := ReadDword(SEH+4);
  if Emulator.err <> UC_ERR_OK then
    Exit(False);

  if (SEH_Handler = 0) or
     (SEH_Handler = $FFFFFFFF) then
     Exit(False);


  Emulator.SEH_Handler := SEH_Handler;

  if SEH_Handler <> lastExceptionHandler then
     lastExceptionHandler := SEH_Handler
  else
  begin
    // TODO: walk the SEH Chain .
  end;

  if VerboseExcp then
  begin
    TextColor(Yellow);
    Writeln(Format('0x%x Exception caught SEH 0x%x - Handler 0x%x',
                         [PC,SEH,SEH_Handler]));
    NormVideo;
  end;

  // Space for the "EXCEPTION_POINTERS" .
  for i := 0 to Pred(376) do
  begin
    Utils.push(0);
  end;

  Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RSP,UC_X86_REG_ESP), @New_ESP);

  Initialize(ExceptionRecord);
  FillByte(ExceptionRecord,SizeOf(ExceptionRecord),0);
  ExceptionRecord.ExceptionCode := ExceptionCode;
  ExceptionRecord.ExceptionFlags := 0;
  ExceptionRecord.ExceptionRecord := 0;
  ExceptionRecord.ExceptionAddress := PC;
  ExceptionRecord.NumberParameters := 0; // TODO .

  Initialize(ContextRecord);
  FillByte(ContextRecord,SizeOf(ContextRecord),0);
  ContextRecord.ContextFlags := $1007F; // taken from Debuggers while testing :D //
  // TODO : Save FLOATING_SAVE_AREA ..
  ContextRecord.SegGs := Emulator.r_gs;
  ContextRecord.SegFs := Emulator.r_fs;
  ContextRecord.SegEs := Emulator.r_es;
  ContextRecord.SegDs := Emulator.r_ds;

  ContextRecord.Edi := reg_read_x32(uc,UC_X86_REG_EDI);
  ContextRecord.Esi := reg_read_x32(uc,UC_X86_REG_ESI);
  ContextRecord.Ebx := reg_read_x32(uc,UC_X86_REG_EBX);
  ContextRecord.Edx := reg_read_x32(uc,UC_X86_REG_EDX);
  ContextRecord.Ecx := reg_read_x32(uc,UC_X86_REG_ECX);
  ContextRecord.Eax := reg_read_x32(uc,UC_X86_REG_EAX);
  ContextRecord.Ebp := reg_read_x32(uc,UC_X86_REG_EBP);
  ContextRecord.Eip := DWORD(Emulator.LastGoodPC);
  ContextRecord.SegCs  := Emulator.r_cs;
  ContextRecord.EFlags := DWORD(reg_read_x64(uc,UC_X86_REG_EFLAGS));
  ContextRecord.Esp    := Old_ESP;
  ContextRecord.SegSs  := Emulator.r_ss;

  ExceptionRecord_Addr := New_ESP + 32;
  ContextRecord_Addr := ExceptionRecord_Addr + SizeOf(EXCEPTION_RECORD_32);

  Emulator.err := uc_mem_write_(uc,ExceptionRecord_Addr,@ExceptionRecord,SizeOf(ExceptionRecord));

  Emulator.err := uc_mem_write_(uc,ContextRecord_Addr,@ContextRecord,SizeOf(ContextRecord));

  Utils.push(ContextRecord_Addr); // ContextRecord ..
  Utils.push(SEH);// SEH Ptr
  Utils.push(ExceptionRecord_Addr); // ExceptionRecord ..
  Utils.push(ZwContinue); // ZwContinue to set Context .

  uc_reg_write(uc,ifthen(Emulator.isx64,UC_X86_REG_RAX,UC_X86_REG_EAX),@Zer0);
  uc_reg_write(uc,ifthen(Emulator.isx64,UC_X86_REG_RBX,UC_X86_REG_EBX),@Zer0);
  uc_reg_write(uc,ifthen(Emulator.isx64,UC_X86_REG_RSI,UC_X86_REG_ESI),@Zer0);
  uc_reg_write(uc,ifthen(Emulator.isx64,UC_X86_REG_RDI,UC_X86_REG_EDI),@Zer0);

  uc_reg_write(uc,ifthen(Emulator.isx64,UC_X86_REG_RCX,UC_X86_REG_ECX),@SEH_Handler);

  //if (ExceptionCode = EXCEPTION_ACCESS_VIOLATION){ or (ExceptionCode = EXCEPTION_BREAKPOINT)} then
     //Emulator.err := uc_reg_write(uc,ifthen(Emulator.isx64,UC_X86_REG_RIP,UC_X86_REG_EIP),@Emulator.SEH_Handler)
  //else
     Emulator.IsException := True;

  Result := True; // Check if everything is ok :D ...
end;

function HookMemInvalid(uc: uc_engine; _type: uc_mem_type; address: UInt64; size: Cardinal; value: Int64; user_data: Pointer): Boolean; cdecl;
begin
  Result := False;
  if Emulator.Stop then exit;

  TextColor(LightRed);
  case _type of
    UC_MEM_WRITE_UNMAPPED:
      begin
        if not Emulator.RunOnDll then
        begin

          if VerboseExcp then
          begin
            TextColor(LightCyan);
            WriteLn(Format('>>> EXCEPTION_ACCESS_VIOLATION WRITE_UNMAPPED at 0x%x, data size = %u, data value = 0x%x', [address, size, value]));
            NormVideo;
          end;

          if Handle_SEH(uc,EXCEPTION_ACCESS_VIOLATION) then
          begin
            Emulator.err := uc_mem_map(uc, address, UC_PAGE_SIZE, UC_PROT_ALL);
            Emulator.MemFix.Push(address);
            Result := True;
          end;
        end;
      end;
    UC_MEM_READ_UNMAPPED:
      begin
        if not Emulator.RunOnDll then
        begin

          if VerboseExcp then
          begin
            TextColor(LightCyan);
            WriteLn(Format('EXCEPTION_ACCESS_VIOLATION READ_UNMAPPED : addr 0x%x, data size = %u, data value = 0x%x', [address, size, value]));
            NormVideo;
          end;

          if Handle_SEH(uc,EXCEPTION_ACCESS_VIOLATION) then
          begin
            Emulator.err := uc_mem_map(uc, address, UC_PAGE_SIZE, UC_PROT_ALL);
            Emulator.MemFix.Push(address);
            Result := True;
          end;
        end;
      end;
    UC_ERR_FETCH_UNMAPPED:
      begin
        if not Emulator.RunOnDll then
           WriteLn(Format('>>> UC_ERR_FETCH_UNMAPPED : addr 0x%x, data size = %u, data value = 0x%x', [address, size, value]));
      end;
    UC_ERR_EXCEPTION:
      begin
           if (address <> $DEADC0DE) and (not Emulator.RunOnDll) then
           WriteLn(Format('>>> UC_ERR_EXCEPTION : addr 0x%x, data size = %u, data value = 0x%x', [address, size, value]));
      end;
    else
      begin
        if not Emulator.RunOnDll then
        begin
          WriteLn(Format('>>> Errrrror : addr 0x%x, data size = %u, data value = 0x%x - Type %d ',
          [address, size, value, _type]));
        end;
        Writeln('Type = ',_type);
        // return false to indicate we want to stop emulation
        Result := false;
      end;
  end;
  NormVideo;
end;

procedure HookMemX86(uc: uc_engine; _type: uc_mem_type; address: UInt64; size: Cardinal; value: Int64; user_data: Pointer); cdecl;
var
  flush : flush_r;
begin
  //if not VerboseEx then Exit;
  if Emulator.Stop then exit;
  case _type of
    UC_MEM_READ:
      begin
        if (not Emulator.RunOnDll) then
          //if (address > Emulator.PEB_address ) then
          //begin
            WriteLn(Format('>>> Memory is being READ at 0x%x, data size = %u, data value = 0x%x', [address, size, value]));
          //end;
      end;
    UC_MEM_WRITE:
      begin
        // A small fix for unicorn#820 .
        if (not Emulator.RunOnDll) and (address > Emulator.Img.ImageBase) then
        begin
          flush.address := address;
          flush.value := value;
          flush.size := size;
          Emulator.FlushMem.Push(flush);
          //WriteLn(Format('>>> Memory is being WRITE at 0x%x, data size = %u, data value = 0x%x', [address, size, value]));
        end;
      end;
  end;
end;

procedure FlushMemMapping(uc : uc_engine);
var
  flush : flush_r;
begin
  if Emulator.FlushMem.Count > 0 then
  begin
    for flush in Emulator.FlushMem do
    begin
      uc_mem_write_(uc,flush.address,@flush.value,flush.size);
    end;
    Emulator.FlushMem.Clear;
  end;
end;

function CallJS(var API : TLibFunction; var Hook : THookFunction ;ret : UInt64) : boolean;
var
  Args : array[0..1] of JSValueConst;
  AResult , JSErr : JSValue;
  JSAPI : JSValue;
  isEx : Boolean;
begin
  Result := False;

  if Assigned(ctx) and JS_IsObject(Hook.JSAPI.JSHook) and JS_IsFunction(ctx,Hook.JSAPI.OnCallBack) then
  begin
    //Writeln(#10'====================== CallBack to JS =========================='#10);

    JSAPI := JS_NewObject(ctx);

    isEx := API.FuncName.EndsWith('Ex') or
            API.FuncName.EndsWith('ExA') or
            API.FuncName.EndsWith('ExW');

    JS_SetPropertyStr(ctx,JSAPI,'IsEx',JS_NewBool(ctx,isEx));
    JS_SetPropertyStr(ctx,JSAPI,'IsWapi',JS_NewBool(ctx,API.FuncName.EndsWith('W')));
    JS_SetPropertyStr(ctx,JSAPI,'IsFW',JS_NewBool(ctx,API.IsForwarder));
    JS_SetPropertyStr(ctx,JSAPI,'LibName',JS_NewString(ctx,PChar(API.LibName)));
    JS_SetPropertyStr(ctx,JSAPI,'name',  JS_NewString(ctx,PChar(API.FuncName)));
    JS_SetPropertyStr(ctx,JSAPI,'FWName',JS_NewString(ctx,PChar(API.FWName)));
    JS_SetPropertyStr(ctx,JSAPI,'Address',JS_NewInt64(ctx,API.VAddress));
    JS_SetPropertyStr(ctx,JSAPI,'Ordinal',JS_NewInt32(ctx,API.ordinal));


    Args[0]:= JSAPI;
    Args[1]:= JS_NewInt64(ctx,ret);
    AResult := JS_FALSE;

    if JS_IsFunction(ctx,Hook.JSAPI.OnCallBack) then
    begin
      AResult := JS_Call(ctx,Hook.JSAPI.OnCallBack,Hook.JSAPI.JSHook,Length(Args),@Args);
      if JS_IsException(AResult) then
      begin
        js_std_dump_error(ctx);
        halt();
      end;
    end;
    if JS_IsBool(AResult) then
    begin
      if VerboseEx and (not Emulator.RunOnDll) then
      begin
        Writeln('JS Return : ' ,JS_VALUE_GET_BOOL(AResult));
      end;
      Result := JS_VALUE_GET_BOOL(AResult);
    end;
    JS_FreeValue(ctx,JSAPI);
    //Writeln(#10'================================================================'#10);
  end
  else
  begin
    JSErr := JS_GetException(ctx);
    if JS_IsException(JSErr) then
    begin
      js_std_dump_error(ctx);
    end;
  end;
end;

function CheckHook(uc : uc_engine ; PC : UInt64) : TApiInfo;
var
  lib  : TNewDll;
  API  : TLibFunction;
  Hook : THookFunction;
  Hash : UInt64;
  ret : UInt64;
begin
  ret := 0;
  Initialize(API);
  Initialize(lib);
  FillByte(API,SizeOf(API),0);
  FillByte(lib,SizeOf(lib),0);
  Initialize(Hook);

  Result.ISAPI := False; Result.APIHandled := False;
  for lib in Emulator.Libs.Values do
  begin
    if (PC > lib.BaseAddress) and (PC < (lib.BaseAddress + lib.ImageSize)) then
    begin
      if lib.Dllname.Length < 3 then Continue;
      if lib.Dllname.IsEmpty then Continue;
      if lib.FnByAddr.TryGetValue(PC,API) then
      begin
        // this's here cuz in some cases we don't let the API go far to the ret :D .
        if not Emulator.RunOnDll then
           Ident -= 3;

        Emulator.err := uc_reg_read(uc,ifthen(Emulator.Is_x64,UC_X86_REG_RSP,UC_X86_REG_ESP),@ret);
        Emulator.err := uc_mem_read_(uc,ret,@ret,Emulator.Img.ImageWordSize);

        if API.IsOrdinal then
        begin
          Hash := xxHash64Calc(LowerCase(ExtractFileNameWithoutExt(ExtractFileName(API.LibName))) + '.' + IntToStr(API.ordinal));
          Emulator.Hooks.ByOrdinal.TryGetValue(Hash,Hook);
        end
        else
        begin
          Hash := xxHash64Calc(LowerCase(ExtractFileNameWithoutExt(ExtractFileName(API.LibName))) + '.' + API.FuncName);
          Emulator.Hooks.ByName.TryGetValue(Hash, Hook);
          {
            This Check is for Ordinal Hook for normal API with Exported name
            like "LoadLibraryA" - ORDINAL = 829 .
            so the first Check by name will fail so we need to Check the
              Ordinal One :D .
          }
          // todo: check this code with some malformed samples for testing.
          if (Hook.FuncName.IsEmpty) and  (Hook.ordinal > 0) then
            Emulator.Hooks.ByOrdinal.TryGetValue(API.ordinal,Hook);
        end;

        API.Hits += 1; // how many times this API Called .API
        API.Return := ret; // the Return Address used for OnExit CallBack .
        if JS_IsObject(Hook.JSAPI.JSHook) and JS_IsFunction(ctx,Hook.JSAPI.OnExit) then
        begin
          Hook.API := API;
          Emulator.OnExitList.AddOrSetValue(ret,Hook);
        end;

        Result.ISAPI := True;
        if (ret > Emulator.Img.ImageBase) and
        (ret < (Emulator.Img.ImageBase + Emulator.Img.SizeOfImage)) then
        begin
          Result.CalledFromMainExe := True;
        end;

        if Verbose and (not Emulator.RunOnDll) then
        begin
          WriteLn(Format(#10'[+] Call to "%s.%s"',[API.LibName,IfThen(API.FuncName<>'',API.FuncName,'#'+hexStr(API.ordinal,3))]));
          Writeln(Format('[#] Will Return to : 0x%x',[ret]));
          if Api.IsForwarder then
          begin
            Writeln(Format('[!] "%s" is Forwarded to : "%s"',[IfThen(API.FuncName<>'',API.FuncName,'#'+hexStr(API.ordinal,3)),API.FWName]));
          end;
        end;

        if JS_IsObject(Hook.JSAPI.JSHook) and (JS_IsFunction(ctx,Hook.JSAPI.OnCallBack)) then
        begin
          Result.APIHandled := CallJS(Api,Hook,ret);
        end
        else if (Hook.NativeCallBack <> nil) then
        begin
          Result.APIHandled := TFnCallBack(Hook.NativeCallBack)(uc,PC,ret);
        end
        else
        begin
          if VerboseEx or (not Emulator.RunOnDll) then
          begin
            TextColor(LightRed);
            Writeln();
            WriteLn(Format('[x] UnHooked Call to %s.%-30s',[API.LibName,IfThen(API.FuncName<>'',API.FuncName,'#'+hexStr(API.ordinal,3))]));
            Writeln(Format('[#] Will Return to : 0x%x',[ret]));
            Writeln('!!! Stack Pointer May get Corrupted '#10);
            NormVideo;
          end;
        end;

        if (not Emulator.Stop) then
        begin
          if not Result.APIHandled then
          begin
            //====================== Fix Stack Pointer ================================//
            Utils.pop(); // but this may Corrupt the Stack
            //=========================================================================//
            Emulator.err := uc_reg_write(uc,ifthen(Emulator.isx64,UC_X86_REG_RIP,UC_X86_REG_EIP),@ret);
          end;
        end;
        Break; // never ever delete this :V // Break from for loop.
      end;
    end;
  end;
end;

procedure CheckOnExitCallBack(IsAPI : boolean; PC : UInt64);
var
  Args : array[0..0] of JSValueConst;
  JSAPI : JSValue;
  AResult : JSValue;
  Hook : THookFunction;
  API : TLibFunction;
  isEx : Boolean;
begin
  // Check if it's no an API Call :D just to make sure .
  if (not IsAPI) then
  if Emulator.OnExitList.TryGetValue(PC,Hook) then
  if Assigned(ctx) and JS_IsObject(Hook.JSAPI.JSHook) then // Check if an API already Called .
  begin
    if Hook.API.Return = PC then
    begin
      if JS_IsFunction(ctx,Hook.JSAPI.OnExit) then // check if we have OnExit Callback .
      begin
        API := Hook.API;

        JSAPI := JS_NewObject(ctx);

        isEx := API.FuncName.EndsWith('Ex')  or
                API.FuncName.EndsWith('ExA') or
                API.FuncName.EndsWith('ExW');

        JS_SetPropertyStr(ctx,JSAPI,'IsEx',JS_NewBool(ctx,isEx));
        JS_SetPropertyStr(ctx,JSAPI,'IsWapi',JS_NewBool(ctx,API.FuncName.EndsWith('W')));
        JS_SetPropertyStr(ctx,JSAPI,'IsFW',JS_NewBool(ctx,API.IsForwarder));
        JS_SetPropertyStr(ctx,JSAPI,'LibName',JS_NewString(ctx,PChar(API.LibName)));
        JS_SetPropertyStr(ctx,JSAPI,'name',  JS_NewString(ctx,PChar(API.FuncName)));
        JS_SetPropertyStr(ctx,JSAPI,'FWName',JS_NewString(ctx,PChar(API.FWName)));
        JS_SetPropertyStr(ctx,JSAPI,'Address',JS_NewInt64(ctx,API.VAddress));
        JS_SetPropertyStr(ctx,JSAPI,'Ordinal',JS_NewInt32(ctx,API.ordinal));

        Args[0]:= JSAPI;
        if JS_IsFunction(ctx,Hook.JSAPI.OnExit) then
        begin
          AResult := JS_Call(ctx,Hook.JSAPI.OnExit,Hook.JSAPI.JSHook,Length(Args),@Args);
          if JS_IsException(AResult) then
          begin
            js_std_dump_error(ctx);
            halt(-1);
          end;
        end;
        JS_FreeValue(ctx,JSAPI);
      end;
    end;
  end;
end;

function CheckAddrHooks(PC : UInt64) : Boolean;
var
  Hook : THookFunction;
  AResult : JSValue;
begin
  Result := False;

  if Emulator.Hooks.ByAddr.TryGetValue(PC,Hook) then // Check if Any hook for current addr.
  if Assigned(ctx) and JS_IsObject(Hook.JSAPI.JSHook) and JS_IsFunction(ctx,Hook.JSAPI.OnCallBack) then
  begin
    AResult := JS_Call(ctx,Hook.JSAPI.OnCallBack,Hook.JSAPI.JSHook,0,nil);
    if JS_IsException(AResult) then
    begin
      js_std_dump_error(ctx);
      halt(-1);
    end;

    if JS_IsBool(AResult) then
    begin
      if VerboseEx and (not Emulator.RunOnDll) then
      begin
        Writeln('Address Hook JS Return : ' ,JS_VALUE_GET_BOOL(AResult));
      end;
      Result := JS_VALUE_GET_BOOL(AResult);
    end;
  end;
end;

procedure HookCode(uc: uc_engine; address: UInt64; size: Cardinal; {%H-}user_data: Pointer); cdecl;
var
  PC : UInt64;
  code : Array [0..49] of byte; // 50 is huge :P for asm ins .
  API : TApiInfo;
  APIPrintFix : Boolean;
  ins : TZydisDecodedInstruction;
  FixAddr : UInt64;
begin
  //CheckForSig(); // Check for ^C .

  PC := 0;  FixAddr := 0;
  FillChar(API,SizeOf(API),0);

  {
    TODO: Check if we are on the stack
        (Prevent or continue) based on user options.
  }


  // Get PC (EIP - RIP) .
  Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @PC);
  Emulator.LastGoodPC := PC;

  FlushMemMapping(uc); // A small fix for unicorn#820 .

  if Emulator.MemFix.Count > 0 then
  begin
    for FixAddr in Emulator.MemFix do
    begin
      uc_mem_unmap(uc,FixAddr,$1000);
    end;
  end;

  if Emulator.IsException then
  begin
    Emulator.err := uc_reg_write(uc,ifthen(Emulator.isx64,UC_X86_REG_RIP,UC_X86_REG_EIP),@Emulator.SEH_Handler);
    Emulator.IsException := False;
    Exit;
  end;

  if Steps_limit <> 0 then
    if Steps >= Steps_limit then
       Emulator.Stop := True;

  if Emulator.Stop then
  begin
    Emulator.err := uc_emu_stop(uc);
    exit;
  end;

  // Address Hook Check .
  if not Speed then // Check only in normal mode .
  begin
    CheckAddrHooks(PC);
  end;

  // TODO: add InterActive Commands .

  //Emulator.Flags.FLAGS := reg_read_x64(uc,UC_X86_REG_EFLAGS);
  API := CheckHook(uc,PC);
  // Check if the API has an OnExit CallBack .
  CheckOnExitCallBack(API.ISAPI,PC);

  APIPrintFix := API.ISAPI and (not API.APIHandled);

  if (ShowASM) and (not APIPrintFix) and (not Emulator.RunOnDll) then
  begin
    Initialize(code);
    FillByte(code,Length(code),0);
    Emulator.err := uc_mem_read_(uc,address,@code,15);
    ins := DisAsm(@code,address,size);

    if (ins.Mnemonic >= ZYDIS_MNEMONIC_JB) and
       (ins.Mnemonic <= ZYDIS_MNEMONIC_JZ) then
      TextColor(Magenta);

    if ins.Mnemonic = ZYDIS_MNEMONIC_CALL then
      TextColor(Yellow);

    if ins.Mnemonic = ZYDIS_MNEMONIC_RET then
      TextColor(LightCyan);

    WriteLn(Format('0x%x| %s %s',[Address,DupeString(' ',Ident), Emulator.Formatter.FormatInstruction(ins)]));

    if ins.Mnemonic = ZYDIS_MNEMONIC_CALL then Ident += 3;
    if ins.Mnemonic = ZYDIS_MNEMONIC_RET then Ident -= 3;

    NormVideo;
  end;

  if (size = 3) and (not Emulator.RunOnDll) then
  begin
    if Emulator.isShellCode then
    begin
      FillByte(code,Length(code),0);
      uc_mem_read_(uc,address,@code,3);
      // xor [reg] [31 47 1A]
      if (code[0] = $31) then
      begin
        if (Emulator.tmpbool = 1) then
        begin
          PC += size;
          Emulator.err := uc_reg_write(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @PC);
          Emulator.tmpbool += 1;
        end
        else
        if (code[0] = $31) and (Emulator.tmpbool = 0) then
        begin
          Emulator.tmpbool += 1;
        end;
      end;
    end;
  end;

  if size = 2 then
  begin
    FillByte(code,Length(code),0);
    uc_mem_read_(uc,address,@code,2);
     //rdtsc
    if (code[0] = $F) and (code[1] = $31) then
    begin
      reg_write_x32(uc,UC_X86_REG_EAX,RandomRange(100,400));
      reg_write_x32(uc,UC_X86_REG_EDX,RandomRange(100,400));

      if not Emulator.RunOnDll then
         Writeln(Format('rdtsc at 0x%x',[PC]));

      PC += size;
      Emulator.err := uc_reg_write(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @PC);
    end;
    // CPUID 0F A2 .
    if (code[0] = $F) and (code[1] = $A2) then
    begin
      reg_write_x32(uc,UC_X86_REG_EAX,0);
      if not Emulator.RunOnDll then
         Writeln(Format('CPUID at 0x%x',[PC]));
      //PC += size;
      //Emulator.err := uc_reg_write(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @PC);
    end;
  end;

  if (not Emulator.RunOnDll) and (Steps_limit <> 0) then
     Steps += 1;
end;

procedure hook_intr(uc: uc_engine; intno: UInt32; {%H-}user_data: Pointer); cdecl;
var
  PC : UInt64;
begin
  if Emulator.isx64 then
  begin
    Emulator.Stop := True;
    Writeln('Exception interrupt is not supported yet in x64 ');
  end;
  if Emulator.Stop then
  begin
    Emulator.err := uc_emu_stop(uc);
    exit;
  end;
  if Emulator.RunOnDll then Exit;

  PC := 0;
  Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @PC);

  TextColor(LightMagenta);
  Writeln();
  Writeln(Format('Exception interrupt 0x%x at : 0x%x',[intno,PC]));
  Writeln();
  NormVideo;

  case intno of
    $3,$2D :
    begin
      Handle_SEH(uc,EXCEPTION_BREAKPOINT);
    end;
    1:
    begin
      Emulator.ResetEFLAGS();
      Handle_SEH(uc,EXCEPTION_ACCESS_VIOLATION);
    end;
  else
    Writeln('interrupt ',intno , ' not supported yet ...');
    Emulator.Stop := True;
  end;
end;

procedure HookSysCall(uc : uc_engine; {%H-}UserData : Pointer);
var
  PC,EAX,ESP,V_ESP : UInt64;
begin
  PC := 0; EAX := 0; // ESP := 0; V_ESP := 0;
  Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @PC);
  Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RAX,UC_X86_REG_EAX), @EAX);

  TextColor(LightMagenta);
  Writeln(Format('EAX : 0x%x',[EAX]));
  Writeln(Format('Syscall at : 0x%x',[PC]));

  //TODO: Add JS Global Callback Function.

  uc_reg_read(uc,ifthen(Emulator.Is_x64,UC_X86_REG_RSP,UC_X86_REG_ESP),@ESP);
  V_ESP := ESP;

 // Utils.DumpStack(ESP,8);

  if (EAX = $19) then // NtQueryInformationProcess .
  begin
    reg_write_x32(uc,UC_X86_REG_EAX,$C0000353);
    Utils.WriteDword(Utils.reg_read_x64(uc,UC_X86_REG_R8),4);
    //Utils.DumpStack(Utils.reg_read_x64(uc,UC_X86_REG_R8),2);
  end;

  if EAX = $D then // NtSetInformationThread .
  begin
    reg_write_x64(uc,UC_X86_REG_RAX,0);
  end;

  if EAX = $50 then // NtProtectVirtualMemory .
  begin
      reg_write_x64(uc,UC_X86_REG_RAX,0);
  end;

  NormVideo;
end;

procedure HookSysEnter(uc : uc_engine; {%H-}UserData : Pointer);
var
  PC,EAX : UInt64;
  V_ESP,ESP: Int64;
begin
  PC := 0; EAX := 0; V_ESP := 0; ESP := 0;
  Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @PC);
  Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RAX,UC_X86_REG_EAX), @EAX);

  TextColor(LightMagenta);
  Writeln(Format('EAX : 0x%x',[EAX]));
  Writeln(Format('SysEnter at : 0x%x',[PC]));
  NormVideo;

  //TODO: Add JS Global Callback Function.

  // For VMProtect ..

  ESP := reg_read_x32(uc,ifthen(Emulator.Is_x64,UC_X86_REG_RSP,UC_X86_REG_ESP));
  V_ESP := ESP;
 // Utils.DumpStack(ESP,8);

  if (EAX = $B5) then // NtQueryInformationProcess
  begin
    reg_write_x32(uc,UC_X86_REG_EAX,$C0000353);
    V_ESP := Utils.ReadDword(V_ESP+4*4);
    Utils.WriteDword(V_ESP,4);
    //Utils.WriteDword(V_ESP+4,4);
    //Utils.DumpStack(V_ESP,2);
  end;

  if EAX = $4C then // NtSetInformationThread .
  begin
    //V_ESP := Utils.ReadDword(ESP+4*2);
    //Utils.WriteDword(ESP+4*2,$FFFFFFFD);
    reg_write_x32(uc,UC_X86_REG_EAX,0); // $C0000004

    //Utils.DumpStack(ESP,8);
    //
  end;

  if (EAX = $C8)then // NtProtectVirtualMemory
  begin
    //writeln('sysenter : NtProtectVirtualMemory');
    //Writeln('BaseAddr      = ',IntToHex(Utils.ReadDword(Utils.ReadDword(ESP+4*3)),8));
    //Writeln('NumberOfBytes = ',IntToHex(Utils.ReadDword(Utils.ReadDword(ESP+4*4)),8));
    //
    reg_write_x32(uc,UC_X86_REG_EAX,0);
  end;
end;

procedure TEmu.SetHooks();
var
  trace1, {trace2,} trace3, trace4, trace5, trace6 , trace7: uc_hook;
begin
  //uc_hook_add(uc, trace2, UC_HOOK_MEM_READ, @HookMemX86, nil, 1, 0,[]);
  Emulator.err := uc_hook_add(uc, trace3,
  UC_HOOK_MEM_READ_UNMAPPED or
  UC_HOOK_MEM_WRITE_UNMAPPED or
  //UC_HOOK_MEM_READ_PROT or
  //UC_HOOK_MEM_WRITE_PROT or
  //UC_HOOK_MEM_FETCH_PROT or
  UC_HOOK_MEM_FETCH_UNMAPPED,
  @HookMemInvalid, nil,1,0,[]);

  if Speed then
    Emulator.err := uc_hook_add(uc, trace4, UC_HOOK_BLOCK, @HookCode, nil, 1, 0,[])
  else
  begin
    Emulator.err := uc_hook_add(uc, trace4, UC_HOOK_CODE, @HookCode, nil, 1, 0,[]);
    uc_hook_add(uc, trace1, UC_HOOK_MEM_WRITE, @HookMemX86, nil, 1, 0,[]);
  end;

  Emulator.err := uc_hook_add(uc, trace5, UC_HOOK_INTR, @hook_intr, nil, 1, 0,[]);

  Emulator.err := uc_hook_add(uc, trace6, UC_HOOK_INSN, @HookSysCall, nil, 1, 0,[UC_X86_INS_SYSCALL]);

  Emulator.err := uc_hook_add(uc, trace7, UC_HOOK_INSN, @HookSysEnter, nil, 1, 0,[UC_X86_INS_SYSENTER]);

end;

function TEmu.MapPEtoUC() : Boolean;
var
  Err : uc_err;
  MapSize : Cardinal;
begin
  Result := False;

  MapSize := ifthen(Align(PE.Size,UC_PAGE_SIZE) > Align(img.SizeOfImage,UC_PAGE_SIZE),
             Integer(Align(PE.Size,UC_PAGE_SIZE)),
             Integer(Align(img.SizeOfImage,UC_PAGE_SIZE)));

  if uc_mem_map(uc,img.ImageBase,MapSize,UC_PROT_ALL) = UC_ERR_OK then
  begin
    Writeln(Format('[√] Alloc Memory for PE in Unicorn @ 0x%x',[img.ImageBase]));

    Err := uc_mem_write_(uc,img.ImageBase,MapedPE,PE.Size);
    if Err = UC_ERR_OK then
    begin
      Writeln('[√] PE Written to Unicorn');

      Writeln();
      Writeln('[---------------- PE Info --------------]');
      Writeln('[*] File Name        : ', ExtractFileName(img.FileName));
      Writeln('[*] Image Base       : ', hexStr(img.ImageBase,16));
      Writeln('[*] Address Of Entry : ', hexStr(img.EntryPointRVA,16));
      Writeln('[*] Size Of Headers  : ', hexStr(img.OptionalHeader.SizeOfHeaders,16));
      Writeln('[*] Size Of Image    : ', hexStr(img.SizeOfImage,16));
      Writeln('[---------------------------------------]');
      Result := True;
    end
    else
    begin
      TextColor(LightRed);
      WriteLn('[x] Erorr while write PE to Unicorn <', uc_strerror(Err),'>');
      NormVideo;
    end;

    if isShellCode then
    begin
      if Assigned(SCode) then
      begin
        Writeln('[√] Writing Shellcode to memory ...');
        if uc_mem_write_(uc,img.ImageBase + Img.EntryPointRVA,SCode.Memory,SCode.Size) = UC_ERR_OK then
        begin
          Writeln('[√] Shellcode Written to Unicorn');
        end;
      end;
    end;

  end
  else
  begin
    WriteLn('[x] Erorr while Mapping to Unicorn');
  end;
  Writeln();
end;

procedure TEmu.Start();
var
  RtlExit : UInt64 = 0;
  Start, _End, PC, RIP : UInt64;
begin
  Entry := 0; PC := 0; Start := 0; _End := 0; RIP := 0;

  // A Temp Context
  uc_context_alloc(self.uc,self.tContext);
  if tContext = nil then
  begin
    writeln('[X] Error while Allocating CPU Context');
  end;

  SetHooks();
  Writeln('[√] Set Hooks');
  if MapPEtoUC then
  begin

    if not init_segments() then
    begin
      Writeln('Can''t init Segments , last Err : ',uc_strerror(err));
      halt(-1);
    end;

    if load_sys_dll(uc,'ntdll.dll') then    // loaded by Default in Win so we load it first .
    if load_sys_dll(uc,'kernel32.dll') then // second :D but maybe i should put kernelbase.dll ..
    if load_sys_dll(uc,'kernelbase.dll') then
    begin
      load_sys_dll(uc,'ucrtbase.dll');
      // Hook PE Imports - TODO: use a good PE Parser .
      HookImports_Pse(uc,Img,FilePath);
      //HookImports(uc,Img);

      {
          The Order here is Important - first we load all JS API Hooks
          Then init all dlls and TLS then call Entry Point .
      }


      InstallNativeHooks(); // 0 .


      Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @RIP);
      writeln(Format('Before Init - IP : %x',[RIP]));


      Init_QJS; // 1.
      InitJSEmu(); // 2.
      LoadScript(PChar(JSAPI)); // 3 .

      Init_dlls(); // 4 .
      InitTLS(uc,Self.Img); // 5 .

      Writeln();
      TextColor(LightCyan);
      Writeln('[>] Run ',ExtractFileName(self.Img.FileName),#10);
      NormVideo;

      // initial stack Pointer .
      SP := ((Emulator.stack_base + Emulator.stack_size) - $100);
      SP := SP and $FFFFFF00; // align the stack .

      err := uc_reg_write(uc, UC_X86_REG_ESP, @SP); // ESP .
      err := uc_reg_write(uc, UC_X86_REG_EBP, @SP); // EBP .

      // Reseting the EFLAGS is important for some caeses \
      // so { don't Delete it :D }
      ResetEFLAGS();

      // to emulate "call edx" :D .. needed in some cases - Don't Delete it .
      uc_reg_write(uc,ifthen(Emulator.isx64,UC_X86_REG_RDX,UC_X86_REG_EDX),@Entry);

      RtlExit := GetProcAddr(CmuGetModulehandle('ntdll.dll'),'RtlExitUserThread');
      WriteDword(SP,RtlExit);


      tmpbool := 0; // tmp_fix: this is important for "xor" shellcodes near IP.

      Entry := img.ImageBase + img.EntryPointRVA;

      Emulator.err := uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @RIP);
      writeln(Format('IP : %x',[RIP]));
      if RIP <> 0 then
        Entry := RIP;

      Start := GetTickCount64;

      if isShellCode then
      err := uc_emu_start(uc,Entry,
          img.ImageBase + img.EntryPointRVA + SCode.Size,0,0)
      else
      err := uc_emu_start(uc,Entry,
          img.ImageBase + img.SizeOfImage,0,0);

      _End := GetTickCount64;
    end;
  end;
  Writeln();

  if Steps_limit <> 0 then
  begin
    Write(Format('%d %s - ',[Steps, ifthen(Speed,'Branches','Steps')]));
  end;
  Writeln(Format('Executed in %d ms',[(_end - Start)]));
  uc_reg_read(uc, ifthen(Emulator.Is_x64,UC_X86_REG_RIP,UC_X86_REG_EIP), @PC);
  Writeln('Last Known Good (R/E)IP : 0x', PC.ToHexString);

  Writeln();
  Writeln('Cmulator Stop >> last Error : ',uc_strerror(err));
end;

function TEmu.SaveCPUState: Boolean;
begin
  Result := uc_context_save(Self.uc,self.tContext) = UC_ERR_OK;
end;

function TEmu.RestoreCPUState: Boolean;
begin
  Result := uc_context_restore(Self.uc,self.tContext) = UC_ERR_OK;
end;

function TEmu.GetGDT(index : Integer): Pointer;
begin
  Result := {%H-}Pointer({%H-}QWord(gdt) + (index * SizeOf(TSegmentDescriptor)));
end;

procedure TEmu.ResetEFLAGS();
begin
  Flags.FLAGS := $202;
  reg_write_x64(uc,UC_X86_REG_EFLAGS,Flags.FLAGS);
end;

function TEmu.init_segments() : boolean;
var
  msr : uc_x86_msr;
  tmp : UInt64;
begin
  Result := false;

  stack_base := $200000;
  stack_size := $60000;
  stack_limit := stack_base - stack_size;
  SP := ((stack_base + stack_size) - $70); // initial stack Pointer .

  gs_address := 0;

  if Is_x64 then
  begin
     fs_address  := $7FFFFFC0000; // i think this one not set in x64 :D .
     gs_address  := $7FFFFFE0000; // TEB  ...
     TEB_Address := gs_address;
     PEB_address := gs_address - $10000; // PEB ...
  end
  else
  begin
     fs_address  := $7FFE0000;
     TEB_Address := fs_address;
     PEB_address := fs_address - $10000; // PEB ...
  end;
  Emulator.PEB := PEB_address;

  if Is_x64 then
  begin
    // FS not accessable from usermode for x64 - i think :D..
    //msr.rid := FSMSR;
    //msr.value := fs_address;
    //uc_reg_write(uc,UC_X86_REG_MSR,@msr);


    // GS Point to TIB in x64 ..
    msr.rid := GSMSR;
    msr.value := gs_address;
    uc_reg_write(uc,UC_X86_REG_MSR,@msr);
  end;

  // Setup FLAFS :D ..
  ResetEFLAGS();

  r_cs := CreateSelector(14, S_GDT or S_PRIV_3); // $73;
  r_ds := CreateSelector(15, S_GDT or S_PRIV_3); // $7b;
  r_es := CreateSelector(15, S_GDT or S_PRIV_3); // $7b;
  r_gs := CreateSelector(15, S_GDT or S_PRIV_3); // $7b;
  r_fs := CreateSelector(16, S_GDT or S_PRIV_3); // $83;
  r_ss := CreateSelector(17, S_GDT or S_PRIV_0); // $88; //ring 0 .

  gdt_address := $C0000000;
  gdtr.base := gdt_address;
  gdtr.limit := 31 * sizeof(TSegmentDescriptor) - 1;

  gdt := CAlloc(31,SizeOf(TSegmentDescriptor));

  Init_Descriptor(GetGDT(14),0,$fffff000,true);      // code segment .
  Init_Descriptor(GetGDT(15),0,$fffff000,false);     // data segment .
  Init_Descriptor(GetGDT(16),fs_address,$fff,false); // one page data segment simulate fs | gs
  Init_Descriptor(GetGDT(17),0,$fffff000,false);     // ring 0 data
  PSegmentDescriptor(GetGDT(17))^.dpl := 0;     // set descriptor privilege level .

  // TODO: remove it after implementing Mem Manager.
  tmp := $40000000;
  err := uc_mem_map(uc, tmp, $30000000, UC_PROT_ALL);

  // Now map everything :D ..
  if err = UC_ERR_OK then
  err := uc_mem_map(uc, stack_base, stack_size, UC_PROT_READ or UC_PROT_WRITE);
  if err = UC_ERR_OK then
  begin
    err := uc_mem_map(uc, gdt_address, $10000, UC_PROT_WRITE or UC_PROT_READ);
    if err = UC_ERR_OK then
    begin
      err := uc_reg_write(uc, UC_X86_REG_GDTR, @gdtr);
      if err = UC_ERR_OK then
      begin
        err := uc_mem_write_(uc, gdt_address, gdt, 31 * SizeOf(TSegmentDescriptor));
        if err = UC_ERR_OK then
        begin
          err := uc_mem_map(uc, fs_address, $4000, UC_PROT_WRITE or UC_PROT_READ);
          if err = UC_ERR_OK then
          begin
            begin
              err := uc_reg_write(uc, UC_X86_REG_ESP, @SP);
              if err = UC_ERR_OK then
              begin
                err := uc_reg_write(uc, UC_X86_REG_SS, @r_ss);
                if err = UC_ERR_OK then
                begin
                  err := uc_reg_write(uc, UC_X86_REG_CS, @r_cs);
                  if err = UC_ERR_OK then
                  begin
                    err := uc_reg_write(uc, UC_X86_REG_DS, @r_ds);
                    if err = UC_ERR_OK then
                    begin
                      err := uc_reg_write(uc, UC_X86_REG_ES, @r_es);
                      if err = UC_ERR_OK then
                      begin
                        err := uc_reg_write(uc, UC_X86_REG_FS, @r_fs);
                        if err = UC_ERR_OK then
                        begin
                          if Is_x64 then
                          begin
                            err := uc_mem_map(uc, gs_address, $4000, UC_PROT_WRITE or UC_PROT_READ);
                            if err = UC_ERR_OK then
                              Result := true;
                          end
                          else
                              Result := true;

                          err := uc_mem_map(uc, PEB_address, $10000, UC_PROT_WRITE or UC_PROT_READ);
                          if err = UC_ERR_OK then
                          begin
                            if Result then
                               if InitTEB_PEB(uc,fs_address,gs_address,PEB_address,stack_base,stack_limit,Is_x64) then
                                  Writeln('[+] Segments & (TIB - PEB) Init Done .')
                               else
                                  Result := False;
                          end
                          else
                            Result := False;
                        end;
                      end;
                    end;
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    end;
  end
  else
  begin
    TextColor(LightRed);
    Writeln(Format('Can''t Map Stack to Unicorn, Error : %s',[uc_strerror(err)]));
    NormVideo;
  end;
  Writeln();
end;

procedure LoadApiSetSchema(var ApiSetSchema : TApiSetSchema);
var
  Redirect : TApiRed;
  JSON : TStrings;
  APIS, item : ISuperObject;
  name : string;
begin
  name := '';
  JSON := TStringList.Create();
  try
     JSON.LoadFromFile(string(ApiSetSchemaPath));
     APIS := SO(UnicodeString(JSON.Text));
     for item in APIS['WIN7_APIS'] do
     begin
       Redirect.first := string(item.S['red.F']);
       Redirect.last  := string(item.S['red.L']);
       Redirect.count := item.I['count'];
       name := string(LowerCase(item.S['name']));

       ApiSetSchema.AddOrSetValue(name,Redirect);
       ApiSetSchema.AddOrSetValue(SplitReg(string(LowerCase(item.S['name']))),Redirect);
     end;

     for item in APIS['WIN10_APIS'] do
     begin
       Redirect.first  := string(item.S['red[0]']);
       Redirect.last   := string(item.S['red[1]']);
       Redirect.count  := item.I['count'];
       Redirect._alias := string(item.S['alias']);
       name := string(LowerCase(item.S['name']));
       ApiSetSchema.AddOrSetValue(name,Redirect);
       ApiSetSchema.AddOrSetValue(SplitReg(string(LowerCase(item.S['name']))),Redirect);
     end;
  finally
    JSON.Free;
  end;
end;

constructor TEmu.Create(_FilePath: string; _Shellcode, SCx64: Boolean);
begin
  // Until Unicorn Engine fix it :D
  MemFix := TStack<UInt64>.Create;
  FlushMem := TStack<flush_r>.Create;
  Formatter := Zydis.Formatter.TZydisFormatter.Create(ZYDIS_FORMATTER_STYLE_INTEL);

  LastGoodPC := 0;
  SEH_Handler := 0;
  IsException := False;
  Shellcode := _FilePath;
  // the file is Shellcode .
  isShellCode := _ShellCode;

  FilePath := _FilePath;
  Self.Stop := False;

  PE := nil; SCode := nil;
  OnExitList := TOnExit.Create();

  Hooks.ByName    := THookByName.Create();
  Hooks.ByOrdinal := THookByOrdinal.Create();
  Hooks.ByAddr    := THookByAddress.Create();

  ApiSetSchema := TFastHashMap<String, TApiRed>.Create();
  LoadApiSetSchema(ApiSetSchema);

  if isShellCode then
  begin
    FilePath := './shellcode/' + IfThen(SCx64,'sc64.exe','sc32.exe'); // these are empty files with PE header.
  end;
  if FileExists(FilePath) then
  begin
    img := TPEImage.Create();
    if img.LoadFromFile(FilePath) then
    begin
      Is_x64 := img.Is64bit;
      CPU_MODE := ifthen(Is_x64,UC_MODE_64,UC_MODE_32);

      Write(Format('"%s"',[ExtractFileName(FilePath)]));
      Writeln(IfThen(Is_x64,' is : x64',' is : x32'));

      Writeln('Mapping the File ..'#10);
      PE := MapPE(img,FilePath);
      if PE = nil then // Check if Mapping Ok .
      begin
        PE.Free; // Free the Stream before Exit .
        Writeln('Error while Map the PE');
        halt(1);
      end;
      MapedPE := PE.Memory;
      if isShellCode then
      begin
        SCode := TMemoryStream.Create;
        SCode.LoadFromFile(Shellcode);
        SCode.Position := 0;
      end;

      // Libraries Stuff ....
      Libs := TLibs.Create;

      // Set Dll Base loading ...
      if Is_x64 then
      begin
        Self.DLL_BASE_LOAD := $0000000700000000;
      end
      else
      begin
        Self.DLL_BASE_LOAD := $0000000070000000;
      end;
      Self.DLL_NEXT_LOAD := Self.DLL_BASE_LOAD;
    end
    else
    begin
      Writeln('Error While Loading : "',FilePath,'" not a valid PE File');
      halt(-1);
    end;
  end
  else
  begin
    Writeln('file not found !');
    halt(-1);
  end;

  err := uc_open(UC_ARCH_X86,CPU_MODE,uc);

  if err = UC_ERR_OK then
  begin
    Writeln('[+] Unicorn Init done  .');
  end
  else
  begin
    Writeln('Error While loading Unicorn : ',uc_strerror(err));
    halt(-1);
  end;
end;

destructor TEmu.Destroy();
begin
  Self.Stop := True;// just to make sure :D .

  if uc <> nil then
     uc_close(uc);

  if Assigned(OnExitList) then
     FreeAndNil(OnExitList);

  if Assigned(Formatter) then
     FreeAndNil(Formatter);

  if Assigned(PE) then
  begin
    FreeAndNil(PE);
  end;
  if Assigned(SCode) then
  begin
    FreeAndNil(SCode);
  end;
  if Assigned(Self.FLibs) then
  begin
    Self.FLibs.Clear;
    FreeAndNil(FLibs);
  end;
  if Assigned(MemFix) then
  begin
    MemFix.Clear;
    FreeAndNil(MemFix);
  end;

  if Assigned(FlushMem) then
  begin
    FlushMem.Clear;
    FreeAndNil(FlushMem);
  end;

  if Assigned(ApiSetSchema) then
  begin
    ApiSetSchema.Clear;
    FreeAndNil(ApiSetSchema);
  end;

  Uninit_JSEngine;

  inherited Destroy;
end;

end.
