/*****************************************************************************
*
*                      Higgs JavaScript Virtual Machine
*
*  This file is part of the Higgs project. The project is distributed at:
*  https://github.com/maximecb/Higgs
*
*  Copyright (c) 2012-2013, Maxime Chevalier-Boisvert. All rights reserved.
*
*  This software is licensed under the following license (Modified BSD
*  License):
*
*  Redistribution and use in source and binary forms, with or without
*  modification, are permitted provided that the following conditions are
*  met:
*   1. Redistributions of source code must retain the above copyright
*      notice, this list of conditions and the following disclaimer.
*   2. Redistributions in binary form must reproduce the above copyright
*      notice, this list of conditions and the following disclaimer in the
*      documentation and/or other materials provided with the distribution.
*   3. The name of the author may not be used to endorse or promote
*      products derived from this software without specific prior written
*      permission.
*
*  THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED
*  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
*  MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
*  NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
*  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
*  NOT LIMITED TO PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
*  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
*  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
*  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
*  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*
*****************************************************************************/

module jit.util;

import std.stdio;
import std.string;
import std.array;
import std.stdint;
import std.conv;
import std.typecons;
import options;
import ir.ir;
import runtime.vm;
import jit.codeblock;
import jit.x86;
import jit.jit;

/**
Create a relative 32-bit jump to a code fragment
*/
void writeJcc32Ref(string mnem, opcode...)(
    CodeBlock as, 
    VM vm, 
    CodeFragment frag
)
{
    // Write an asm comment
    as.writeASM(mnem, frag.getName);

    as.writeBytes(opcode);

    vm.addFragRef(as.getWritePos(), frag, 32);

    as.writeInt(0, 32);
}

/// 32-bit relative jumps with fragment references
alias writeJcc32Ref!("ja"  , 0x0F, 0x87) ja32Ref;
alias writeJcc32Ref!("jae" , 0x0F, 0x83) jae32Ref;
alias writeJcc32Ref!("jb"  , 0x0F, 0x82) jb32Ref;
alias writeJcc32Ref!("jbe" , 0x0F, 0x86) jbe32Ref;
alias writeJcc32Ref!("jc"  , 0x0F, 0x82) jc32Ref;
alias writeJcc32Ref!("je"  , 0x0F, 0x84) je32Ref;
alias writeJcc32Ref!("jg"  , 0x0F, 0x8F) jg32Ref;
alias writeJcc32Ref!("jge" , 0x0F, 0x8D) jge32Ref;
alias writeJcc32Ref!("jl"  , 0x0F, 0x8C) jl32Ref;
alias writeJcc32Ref!("jle" , 0x0F, 0x8E) jle32Ref;
alias writeJcc32Ref!("jna" , 0x0F, 0x86) jna32Ref;
alias writeJcc32Ref!("jnae", 0x0F, 0x82) jnae32Ref;
alias writeJcc32Ref!("jnb" , 0x0F, 0x83) jnb32Ref;
alias writeJcc32Ref!("jnbe", 0x0F, 0x87) jnbe32Ref;
alias writeJcc32Ref!("jnc" , 0x0F, 0x83) jnc32Ref;
alias writeJcc32Ref!("jne" , 0x0F, 0x85) jne32Ref;
alias writeJcc32Ref!("jng" , 0x0F, 0x8E) jng32Ref;
alias writeJcc32Ref!("jnge", 0x0F, 0x8C) jnge32Ref;
alias writeJcc32Ref!("jnl" , 0x0F, 0x8D) jnl32Ref;
alias writeJcc32Ref!("jnle", 0x0F, 0x8F) jnle32Ref;
alias writeJcc32Ref!("jno" , 0x0F, 0x81) jno32Ref;
alias writeJcc32Ref!("jnp" , 0x0F, 0x8b) jnp32Ref;
alias writeJcc32Ref!("jns" , 0x0F, 0x89) jns32Ref;
alias writeJcc32Ref!("jnz" , 0x0F, 0x85) jnz32Ref;
alias writeJcc32Ref!("jo"  , 0x0F, 0x80) jo32Ref;
alias writeJcc32Ref!("jp"  , 0x0F, 0x8A) jp32Ref;
alias writeJcc32Ref!("jpe" , 0x0F, 0x8A) jpe32Ref;
alias writeJcc32Ref!("jpo" , 0x0F, 0x8B) jpo32Ref;
alias writeJcc32Ref!("js"  , 0x0F, 0x88) js32Ref;
alias writeJcc32Ref!("jz"  , 0x0F, 0x84) jz32Ref;
alias writeJcc32Ref!("jmp" , 0xE9) jmp32Ref;

/**
Move an absolute reference to a fragment's address into a register
*/
void movAbsRef(CodeBlock as, VM vm, X86Reg dstReg, CodeFragment frag)
{
    as.writeASM("mov", dstReg, frag.getName);
    as.mov(dstReg.opnd(64), X86Opnd(uint64_t.max));
    vm.addFragRef(as.getWritePos() - 8, frag, 64);
}

/// Load a pointer constant into a register
void ptr(TPtr)(CodeBlock as, X86Reg dstReg, TPtr ptr)
{
    as.mov(X86Opnd(dstReg), X86Opnd(X86Imm(cast(void*)ptr)));
}

/// Increment a global JIT stat counter variable
void incStatCnt(CodeBlock as, ulong* pCntVar, X86Reg scrReg)
{
    if (!opts.stats)
        return;

    as.ptr(scrReg, pCntVar);

    as.inc(X86Opnd(8 * ulong.sizeof, RAX));
}

void getField(CodeBlock as, X86Reg dstReg, X86Reg baseReg, size_t fOffset)
{
    assert (dstReg.type is X86Reg.GP);
    as.mov(X86Opnd(dstReg), X86Opnd(dstReg.size, baseReg, cast(int32_t)fOffset));
}

void setField(CodeBlock as, X86Reg baseReg, size_t fOffset, X86Reg srcReg)
{
    assert (srcReg.type is X86Reg.GP);
    as.mov(X86Opnd(srcReg.size, baseReg, cast(int32_t)fOffset), X86Opnd(srcReg));
}

void getMember(string fName)(CodeBlock as, X86Reg dstReg, X86Reg baseReg)
{
    mixin("auto fOffset = " ~ fName ~ ".offsetof;");

    as.getField(dstReg, baseReg, fOffset);
}

void setMember(string fName)(CodeBlock as, X86Reg baseReg, X86Reg srcReg)
{
    mixin("auto fOffset = " ~ fName ~ ".offsetof;");

    as.setField(baseReg, fOffset, srcReg);
}

/// Read from the word stack
void getWord(CodeBlock as, X86Reg dstReg, int32_t idx)
{
    if (dstReg.type is X86Reg.GP)
        as.mov(X86Opnd(dstReg), X86Opnd(dstReg.size, wspReg, 8 * idx));
    else if (dstReg.type is X86Reg.XMM)
        as.movsd(X86Opnd(dstReg), X86Opnd(64, wspReg, 8 * idx));
    else
        assert (false, "unsupported register type");
}

/// Read from the type stack
void getType(CodeBlock as, X86Reg dstReg, int32_t idx)
{
    as.mov(X86Opnd(dstReg), X86Opnd(8, tspReg, idx));
}

/// Write to the word stack
void setWord(CodeBlock as, int32_t idx, X86Opnd src)
{
    auto memOpnd = X86Opnd(64, wspReg, 8 * idx);

    if (src.isGPR)
        as.mov(memOpnd, src);
    else if (src.isXMM)
        as.movsd(memOpnd, src);
    else if (src.isImm)
        as.mov(memOpnd, src);
    else
        assert (false, "unsupported src operand type");
}

// Write a constant to the word type
void setWord(CodeBlock as, int32_t idx, int32_t imm)
{
    as.mov(X86Opnd(64, wspReg, 8 * idx), X86Opnd(imm));
}

/// Write to the type stack
void setType(CodeBlock as, int32_t idx, X86Opnd srcOpnd)
{
    as.mov(X86Opnd(8, tspReg, idx), srcOpnd);
}

/// Write a constant to the type stack
void setType(CodeBlock as, int32_t idx, Type type)
{
    as.mov(X86Opnd(8, tspReg, idx), X86Opnd(type));
}

/// Store/save the JIT state register
void pushJITRegs(CodeBlock as)
{
    // Save word and type stack pointers on the VM object
    as.setMember!("VM.wsp")(vmReg, wspReg);
    as.setMember!("VM.tsp")(vmReg, tspReg);

    // Push the VM register on the stack
    as.push(vmReg);
    as.push(vmReg);
}

// Load/restore the JIT state registers
void popJITRegs(CodeBlock as)
{
    // Pop the VM register from the stack
    as.pop(vmReg);
    as.pop(vmReg);

    // Load the word and type stack pointers from the VM object
    as.getMember!("VM.wsp")(wspReg, vmReg);
    as.getMember!("VM.tsp")(tspReg, vmReg);
}

/// Save caller-save registers on the stack before a C call
void pushRegs(CodeBlock as)
{
    as.push(RAX);
    as.push(RCX);
    as.push(RDX);
    as.push(RSI);
    as.push(RDI);
    as.push(R8);
    as.push(R9);
    as.push(R10);
    as.push(R11);
    as.push(R11);
}

/// Restore caller-save registers from the after before a C call
void popRegs(CodeBlock as)
{
    as.pop(R11);
    as.pop(R11);
    as.pop(R10);
    as.pop(R9);
    as.pop(R8);
    as.pop(RDI);
    as.pop(RSI);
    as.pop(RDX);
    as.pop(RCX);
    as.pop(RAX);
}

/*
void checkVal(Assembler as, X86Opnd wordOpnd, X86Opnd typeOpnd, string errorStr)
{
    extern (C) static void checkValFn(VM vm, Word word, Type type, char* errorStr)
    {
        if (type != Type.REFPTR)
            return;

        if (vm.inFromSpace(word.ptrVal) is false)
        {
            writefln(
                "pointer not in from-space: %s\n%s",
                word.ptrVal,
                to!string(errorStr)
            );
        }
    }

    as.pushRegs();

    auto STR_DATA = new Label("STR_DATA");
    auto AFTER_STR = new Label("AFTER_STR");

    as.instr(JMP, AFTER_STR);
    as.addInstr(STR_DATA);
    foreach (ch; errorStr)
        as.addInstr(new IntData(cast(uint)ch, 8));    
    as.addInstr(new IntData(0, 8));
    as.addInstr(AFTER_STR);

    as.instr(MOV, cargRegs[2].reg(8), typeOpnd);
    as.instr(MOV, cargRegs[1], wordOpnd);
    as.instr(MOV, cargRegs[0], vmReg);
    as.instr(LEA, cargRegs[3], new X86IPRel(8, STR_DATA));

    auto checkFn = &checkValFn;
    as.ptr(scrRegs64[0], checkFn);
    as.instr(jit.encodings.CALL, scrRegs64[0]);

    as.popRegs();
}
*/

void printUint(CodeBlock as, X86Opnd opnd)
{
    extern (C) void printUintFn(uint64_t v)
    {
        writefln("%s", v);
    }

    size_t opndSz;
    if (opnd.isImm)
        opndSz = 64;
    else if (opnd.isGPR)
        opndSz = opnd.reg.size;
    else if (opnd.isMem)
        opndSz = opnd.mem.size;
    else
        assert (false);

    as.pushRegs();

    if (opndSz < 64)
        as.movzx(cargRegs[0].opnd(64), opnd);
    else
        as.mov(cargRegs[0].opnd(opndSz), opnd);

    // Call the print function
    as.ptr(scrRegs[0], &printUintFn);
    as.call(scrRegs[0]);

    as.popRegs();
}

void printInt(CodeBlock as, X86Opnd opnd)
{
    extern (C) void printIntFn(int64_t v)
    {
        writefln("%s", v);
    }

    size_t opndSz;
    if (opnd.isImm)
        opndSz = 64;
    else if (opnd.isGPR)
        opndSz = opnd.reg.size;
    else if (opnd.isMem)
        opndSz = opnd.mem.size;
    else
        assert (false);

    as.pushRegs();

    if (opndSz < 64)
        as.movsx(cargRegs[0].opnd(64), opnd);
    else
        as.mov(cargRegs[0].opnd(64), opnd);

    // Call the print function
    as.ptr(scrRegs[0], &printIntFn);
    as.call(scrRegs[0]);

    as.popRegs();
}

void printStr(CodeBlock as, string str)
{
    extern (C) static void printStrFn(char* pStr)
    {
        printf("%s\n", pStr);
    }

    as.comment("printStr(\"" ~ str ~ "\")");

    as.pushRegs();

    // Load the string address and jump over the string data
    as.lea(cargRegs[0], X86Mem(8, RIP, 5));
    as.jmp32(cast(int32_t)str.length + 1);

    // Write the string chars and a null terminator
    foreach (ch; str)
        as.writeInt(cast(uint)ch, 8);
    as.writeInt(0, 8);

    as.ptr(scrRegs[0], &printStrFn);
    as.call(scrRegs[0].opnd(64));

    as.popRegs();
}

