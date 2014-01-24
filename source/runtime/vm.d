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

module runtime.vm;

import core.memory;
import std.stdio;
import std.string;
import std.array;
import std.conv;
import std.stdint;
import std.typecons;
import std.path;
import std.file;
import options;
import stats;
import util.misc;
import analysis.typeset;
import parser.parser;
import parser.ast;
import ir.ir;
import ir.ast;
import runtime.layout;
import runtime.string;
import runtime.object;
import runtime.gc;
import jit.codeblock;
import jit.jit;

/**
Run-time error
*/
class RunError : Error
{
    /// Associated virtual machine
    VM vm;

    /// Exception value
    ValuePair excVal;

    /// Error message
    string message;

    /// Stack trace
    IRInstr[] trace;

    this(VM vm, ValuePair excVal, IRInstr[] trace)
    {
        this.vm = vm;
        this.excVal = excVal;
        this.trace = trace;

        if (valIsLayout(excVal, LAYOUT_OBJ))
        {
            auto msgStr = getProp(
                vm, 
                excVal.word.ptrVal,
                "message"w
            );

            this.message = valToString(msgStr);
        }
        else
        {
            this.message = valToString(excVal);
        }

        super(toString());
    }

    override string toString()
    {
        string str = message;

        foreach (instr; trace)
        {
            auto fun = instr.block.fun;
            str ~= "\n" ~ fun.getName ~ " (" ~ to!string(fun.ast.pos) ~ ")";
        }

        return str;
    }
}

/**
Memory word union
*/
union Word
{
    static Word int32v(int32 i) { Word w; w.int32Val = i; return w; }
    static Word int64v(int64 i) { Word w; w.int64Val = i; return w; }
    static Word uint32v(uint32 i) { Word w; w.uint32Val = i; return w; }
    static Word uint64v(uint64 i) { Word w; w.uint64Val = i; return w; }
    static Word float64v(float64 f) { Word w; w.floatVal = f; return w; }
    static Word refv(refptr p) { Word w; w.ptrVal = p; return w; }
    static Word ptrv(rawptr p) { Word w; w.ptrVal = p; return w; }

    int8    int8Val;
    int16   int16Val;
    int32   int32Val;
    int64   int64Val;
    uint8   uint8Val;
    uint16  uint16Val;
    uint32  uint32Val;
    uint64  uint64Val;
    float64 floatVal;
    refptr  refVal;
    rawptr  ptrVal;

    IRFunction  funVal;
    IRInstr     insVal;
    ObjMap      mapVal;
}

unittest
{
    assert (
        Word.sizeof == rawptr.sizeof,
        "word size does not match pointer size"
    );
}

// Note: low byte is set to allow for one byte immediate comparison
Word NULL    = { uint64Val: 0x0000000000000000 };
Word TRUE    = { uint64Val: 0x0000000000000001 };
Word FALSE   = { uint64Val: 0x0000000000000002 };
Word UNDEF   = { uint64Val: 0x0000000000000003 };
Word MISSING = { uint64Val: 0x0000000000000004 };

/// Word type values
enum Type : ubyte
{
    INT32 = 0,
    INT64,
    FLOAT64,
    REFPTR,
    RAWPTR,
    RETADDR,
    CONST,
    FUNPTR,
    MAPPTR
}

/// Word and type pair
alias Tuple!(Word, "word", Type, "type") ValuePair;

/**
Produce a string representation of a type tag
*/
string typeToString(Type type)
{
    // Switch on the type tag
    switch (type)
    {
        case Type.INT32:    return "int32";
        case Type.INT64:    return "int64";
        case Type.FLOAT64:  return "float64";
        case Type.RAWPTR:   return "raw pointer";
        case Type.REFPTR:   return "ref pointer";
        case Type.RETADDR:  return "return address";
        case Type.CONST:    return "const";
        case Type.FUNPTR:   return "funptr";
        case Type.MAPPTR:   return "mapptr";

        default:
        assert (false, "unsupported type");
    }
}

/**
Test if a reference points to an object of a given layout
*/
bool refIsLayout(refptr ptr, uint32 layoutId)
{
    return (ptr !is null && obj_get_header(ptr) == layoutId);
}

/**
Test if a value is an object of a given layout
*/
bool valIsLayout(ValuePair val, uint32 layoutId)
{
    return (
        val.type is Type.REFPTR && 
        refIsLayout(val.word.ptrVal, layoutId)
    );
}

/**
Test if a value is a string
*/
bool valIsString(ValuePair val)
{
    return valIsLayout(val, LAYOUT_STR);
}

/**
Produce a string representation of a value pair
*/
string valToString(ValuePair value)
{
    auto w = value.word;

    // Switch on the type tag
    switch (value.type)
    {
        case Type.INT32:
        return to!string(w.int32Val);

        case Type.FLOAT64:
        if (w.floatVal != w.floatVal)
            return "NaN";
        if (w.floatVal == 1.0/0)
            return "Infinity";
        if (w.floatVal == -1.0/0)
            return "-Infinity";
        return to!string(w.floatVal);

        case Type.RAWPTR:
        return to!string(w.ptrVal);

        case Type.REFPTR:
        if (w == NULL)
            return "null";
        if (ptrValid(w.ptrVal) is false)
            return "invalid refptr";
        if (valIsLayout(value, LAYOUT_OBJ))
            return "object";
        if (valIsLayout(value, LAYOUT_CLOS))
            return "function";
        if (valIsLayout(value, LAYOUT_ARR))
            return "array";
        if (valIsString(value))
            return extractStr(w.ptrVal);
        return "refptr";

        case Type.RETADDR:
        return to!string(w.ptrVal);

        case Type.CONST:
        if (w == TRUE)
            return "true";
        if (w == FALSE)
            return "false";
        if (w == UNDEF)
            return "undefined";
        if (w == MISSING)
            return "missing";
        assert (
            false, 
            "unsupported constant " ~ to!string(value.word.uint64Val)
        );

        case Type.FUNPTR:
        return "funptr";
        break;

        case Type.MAPPTR:
        return "mapptr";
        break;

        default:
        assert (false, "unsupported value type");
    }
}

/// Stack size, 256K words (2MB)
immutable size_t STACK_SIZE = 2^^18;

/// Initial heap size, 16M bytes
immutable size_t HEAP_INIT_SIZE = 2^^24;

/// Initial link table size
immutable size_t LINK_TBL_INIT_SIZE = 8192;

/// Initial base object size
immutable size_t BASE_OBJ_INIT_SIZE = 128;

/// Initial global object size
immutable size_t GLOBAL_OBJ_INIT_SIZE = 512;

/// Initial executable heap size, 16M bytes
immutable size_t EXEC_HEAP_INIT_SIZE = 2 ^^ 24;

/**
Virtual Machine (VM) instance
*/
class VM
{
    /// Word stack
    Word* wStack;

    /// Type stack
    Type* tStack;

    /// Word stack upper limit
    Word* wUpperLimit;

    /// Type stack upper limit
    Type* tUpperLimit;

    /// Word and type stack pointers (stack top)
    Word* wsp;

    /// Type stack pointer (stack top)
    Type* tsp;

    /// Heap start pointer
    ubyte* heapStart;

    /// Heap size
    size_t heapSize;

    /// Heap upper limit
    ubyte* heapLimit;

    /// Allocation pointer
    ubyte* allocPtr;

    /// To-space heap pointers, for garbage collection
    ubyte* toStart;
    ubyte* toLimit;
    ubyte* toAlloc;

    /// Linked list of GC roots
    GCRoot* firstRoot;

    /// Linked list of type sets
    TypeSet* firstSet;

    /// Set of weak references to functions referenced in the heap
    /// To be cleaned up by the GC
    IRFunction[void*] funRefs;

    /// Set of functions found live by the GC during collection
    IRFunction[void*] liveFuns;

    /// Set of weak references to class maps referenced in the heap
    /// To be cleaned up by the GC
    ObjMap[void*] mapRefs;

    /// Set of maps found live by the GC during collection
    ObjMap[void*] liveMaps;

    /// Garbage collection count
    size_t gcCount = 0;

    /// Link table words
    Word* wLinkTable;

    /// Link table types
    Type* tLinkTable;

    /// Link table size
    uint32 linkTblSize;

    /// Free link table entries
    uint32[] linkTblFree;

    /// String table reference
    refptr strTbl;

    /// Object prototype object
    refptr objProto;

    /// Array prototype object
    refptr arrProto;

    /// Function prototype object
    refptr funProto;

    /// Global object reference
    refptr globalObj;

    /// Runtime error value (uncaught exceptions)
    RunError runError;

    /// Executable heap
    CodeBlock execHeap;

    /// Topmost call context (when calling host code)
    CallCtx callCtx;

    /// Map of return addresses to return entries
    RetEntry[CodePtr] retAddrMap;

    /// List of code fragments, in memory order
    CodeFragment[] fragList;

    /// Map of blocks to lists of existing versions
    BlockVersion[][IRBlock] versionMap;

    /// Queue of block versions to be compiled
    BlockVersion[] compQueue;

    /// List of references to code fragments to be linked
    FragmentRef[] refList;

    /// Function entry stub
    EntryStub entryStub;

    /// Constructor entry stub
    EntryStub ctorStub;

    /**
    Constructor, initializes the VM state
    */
    this(bool loadRuntime = true, bool loadStdLib = true)
    {
        assert (
            !(loadStdLib && !loadRuntime),
            "cannot load stdlib without loading runtime"
        );

        // Allocate the word stack
        wStack = cast(Word*)GC.malloc(
            Word.sizeof * STACK_SIZE,
            GC.BlkAttr.NO_SCAN |
            GC.BlkAttr.NO_INTERIOR
        );

        // Allocate the type stack
        tStack = cast(Type*)GC.malloc(
            Type.sizeof * STACK_SIZE,
            GC.BlkAttr.NO_SCAN |
            GC.BlkAttr.NO_INTERIOR
        );

        // Initialize the stack limit pointers
        wUpperLimit = wStack + STACK_SIZE;
        tUpperLimit = tStack + STACK_SIZE;

        // Initialize the stack pointers just past the end of the stack
        wsp = wUpperLimit;
        tsp = tUpperLimit;

        // Allocate a block of immovable memory for the heap
        heapSize = HEAP_INIT_SIZE;
        heapStart = cast(ubyte*)GC.malloc(
            heapSize, 
            GC.BlkAttr.NO_SCAN |
            GC.BlkAttr.NO_INTERIOR
        );

        // Check that the allocation was successful
        if (heapStart is null)
            throw new Error("heap allocation failed");

        // Initialize the allocation and limit pointers
        allocPtr = heapStart;
        heapLimit = heapStart + heapSize;

        /// Link table size
        linkTblSize = LINK_TBL_INIT_SIZE;

        /// Free link table entries
        linkTblFree = new LinkIdx[linkTblSize];
        for (uint32 i = 0; i < linkTblSize; ++i)
            linkTblFree[i] = i;

        /// Link table words
        wLinkTable = cast(Word*)GC.malloc(
            Word.sizeof * linkTblSize,
            GC.BlkAttr.NO_SCAN |
            GC.BlkAttr.NO_INTERIOR
        );

        /// Link table types
        tLinkTable = cast(Type*)GC.malloc(
            Type.sizeof * linkTblSize,
            GC.BlkAttr.NO_SCAN |
            GC.BlkAttr.NO_INTERIOR
        );

        // Initialize the link table
        for (size_t i = 0; i < linkTblSize; ++i)
        {
            wLinkTable[i].int32Val = 0;
            tLinkTable[i] = Type.INT32;
        }

        // Allocate and initialize the string table
        strTbl = strtbl_alloc(this, STR_TBL_INIT_SIZE);

        // Allocate the object prototype object
        objProto = newObj(
            this, 
            new ObjMap(this, BASE_OBJ_INIT_SIZE),
            NULL.ptrVal            
        );

        // Allocate the array prototype object
        arrProto = newObj(
            this, 
            new ObjMap(this, BASE_OBJ_INIT_SIZE),
            objProto
        );

        // Allocate the function prototype object
        funProto = newObj(
            this, 
            new ObjMap(this, BASE_OBJ_INIT_SIZE),
            objProto
        );

        // Allocate the global object
        globalObj = newObj(
            this,
            new ObjMap(this, GLOBAL_OBJ_INIT_SIZE),
            objProto
        );

        // Allocate the executable heap
        execHeap = new CodeBlock(EXEC_HEAP_INIT_SIZE, opts.jit_dumpasm);

        // If the runtime library should be loaded
        if (loadRuntime)
        {
            // Load the layout code
            load("runtime/layout.js");

            // Load the runtime library
            load("runtime/runtime.js");
        }

        // If the standard library should be loaded
        if (loadStdLib)
        {
            load("stdlib/error.js");
            load("stdlib/object.js");
            load("stdlib/function.js");
            load("stdlib/math.js");
            load("stdlib/string.js");
            load("stdlib/array.js");
            load("stdlib/number.js");
            load("stdlib/boolean.js");
            load("stdlib/date.js");
            load("stdlib/json.js");
            load("stdlib/regexp.js");
            load("stdlib/map.js");
            load("stdlib/global.js");
            load("stdlib/commonjs.js");
        }
    }

    /**
    Set the value and type of a stack slot
    */
    void setSlot(LocalIdx idx, Word w, Type t)
    {
        assert (
            &wsp[idx] >= wStack && &wsp[idx] < wUpperLimit,
            "invalid stack slot index"
        );

        assert (
            t != Type.REFPTR ||
            w.ptrVal == null ||
            (w.ptrVal >= heapStart && w.ptrVal < heapLimit),
            "ref ptr out of heap in setSlot: " ~
            to!string(w.ptrVal)
        );

        wsp[idx] = w;
        tsp[idx] = t;
    }

    /**
    Set the value and type of a stack slot from a value/type pair
    */
    void setSlot(LocalIdx idx, ValuePair val)
    {
        setSlot(idx, val.word, val.type);
    }

    /**
    Set a stack slot to a boolean value
    */
    void setSlot(LocalIdx idx, bool val)
    {
        setSlot(idx, val? TRUE:FALSE, Type.CONST);
    }

    /**
    Set a stack slot to an integer value
    */
    void setSlot(LocalIdx idx, uint32 val)
    {
        setSlot(idx, Word.int32v(val), Type.INT32);
    }

    /**
    Set a stack slot to a float value
    */
    void setSlot(LocalIdx idx, float64 val)
    {
        setSlot(idx, Word.float64v(val), Type.FLOAT64);
    }

    /**
    Get a word from the word stack
    */
    Word getWord(LocalIdx idx)
    {
        assert (
            &wsp[idx] >= wStack && &wsp[idx] < wUpperLimit,
            "invalid stack slot index"
        );

        return wsp[idx];
    }

    /**
    Get a type from the type stack
    */
    Type getType(LocalIdx idx)
    {
        assert (
            &tsp[idx] >= tStack && &tsp[idx] < tUpperLimit,
            "invalid stack slot index"
        );

        return tsp[idx];
    }

    /**
    Get a value/type pair from the stack
    */
    ValuePair getSlot(LocalIdx idx)
    {
        return ValuePair(getWord(idx), getType(idx));
    }

    /**
    Copy a value from one stack slot to another
    */
    void move(LocalIdx src, LocalIdx dst)
    {
        assert (
            &wsp[src] >= wStack && &wsp[src] < wUpperLimit,
            "invalid move src index"
        );

        assert (
            &wsp[dst] >= wStack && &wsp[dst] < wUpperLimit,
            "invalid move dst index"
        );

        wsp[dst] = wsp[src];
        tsp[dst] = tsp[src];
    }

    /**
    Push a word and type on the stack
    */
    void push(Word w, Type t)
    {
        push(1);
        setSlot(0, w, t);
    }

    /**
    Push a value pair on the stack
    */
    void push(ValuePair val)
    {
        push(1);
        setSlot(0, val.word, val.type);
    }

    /**
    Allocate space on the stack
    */
    void push(size_t numWords)
    {
        wsp -= numWords;
        tsp -= numWords;

        if (wsp < wStack)
            throw new Error("stack overflow");
    }

    /**
    Free space on the stack
    */
    void pop(size_t numWords)
    {
        wsp += numWords;
        tsp += numWords;

        if (wsp > wUpperLimit)
            throw new Error("stack underflow");
    }

    /**
    Get the number of stack slots
    */
    size_t stackSize()
    {
        return wUpperLimit - wsp;
    }

    /**
    Allocate a link table entry
    */
    LinkIdx allocLink()
    {
        if (linkTblFree.length == 0)
        {
            assert (false, "no free link entries");
        }

        auto idx = linkTblFree.back;
        linkTblFree.popBack();

        return idx;
    }

    /**
    Free a link table entry
    */
    void freeLink(LinkIdx idx)
    {
        assert (
            idx <= linkTblSize,
            "invalid link index"
        );

        // Remove any heap reference
        wLinkTable[idx].uint32Val = 0;
        tLinkTable[idx] = Type.INT32;

        linkTblFree ~= idx;
    }

    /**
    Get the word associated with a link value
    */
    Word getLinkWord(LinkIdx idx)
    {
        assert (
            idx <= linkTblSize,
            "invalid link index"
        );

        return wLinkTable[idx];
    }

    /**
    Get the type associated with a link value
    */
    Type getLinkType(LinkIdx idx)
    {
        assert (
            idx <= linkTblSize,
            "invalid link index"
        );

        return tLinkTable[idx];
    }

    /**
    Set the word associated with a link value
    */
    void setLinkWord(LinkIdx idx, Word word)
    {
        assert (
            idx <= linkTblSize,
            "invalid link index"
        );

        wLinkTable[idx] = word;
    }

    /**
    Set the type associated with a link value
    */
    void setLinkType(LinkIdx idx, Type type)
    {
        assert (
            idx <= linkTblSize,
            "invalid link index"
        );

        tLinkTable[idx] = type;
    }

    /**
    Get the value pair for an IR value
    */
    ValuePair getValue(IRValue val)
    {
        // If the value has an associated output slot
        if (auto dstVal = cast(IRDstValue)val)
        {
            assert (
                dstVal.outSlot != NULL_LOCAL, 
                "out slot unassigned for:\n" ~
                dstVal.toString()
            );

            //writefln("getting value from slot of %s", val);

            // Get the value at the output slot
            return getSlot(dstVal.outSlot);
        }

        // Get the constant value pair for this IR value
        return val.cstValue();
    }

    /**
    Get the value of an instruction's argument
    */
    ValuePair getArgVal(IRInstr instr, size_t argIdx)
    {
        // Get the argument IRValue
        auto val = instr.getArg(argIdx);

        return getValue(val);
    }

    /**
    Get a boolean argument value
    */
    bool getArgBool(IRInstr instr, size_t argIdx)
    {
        auto argVal = getArgVal(instr, argIdx);

        assert (
            argVal.type == Type.CONST,
            "expected constant value for arg " ~ to!string(argIdx)
        );

        return (argVal.word.int8Val == TRUE.int8Val);
    }

    /**
    Get an argument value and ensure it is an uint32
    */
    uint32_t getArgUint32(IRInstr instr, size_t argIdx)
    {
        auto argVal = getArgVal(instr, argIdx);

        assert (
            argVal.type == Type.INT32,
            "expected uint32 value for arg " ~ to!string(argIdx)
        );

        assert (
            argVal.word.int32Val >= 0,
            "expected positive value"
        );

        return argVal.word.uint32Val;
    }

    /**
    Get an argument value and ensure it is a string object pointer
    */
    refptr getArgStr(IRInstr instr, size_t argIdx)
    {
        auto strVal = getArgVal(instr, argIdx);

        assert (
            valIsString(strVal),
            "expected string value for arg " ~ to!string(argIdx)
        );

        return strVal.word.ptrVal;
    }

    /**
    Prepares the callee stack-frame for a call
    */
    void callFun(
        IRFunction fun,         // Function to call
        CodePtr retAddr,        // Return address
        refptr closPtr,         // Closure pointer
        Word thisWord,          // This value word
        Type thisType,          // This value type
        uint32_t argCount,
        ValuePair* argVals
    )
    {
        //writefln("call to %s (%s)", fun.name, cast(void*)fun);
        //writefln("num args: %s", argCount);
        //writeln("clos ptr: ", closPtr);

        assert (
            fun !is null, 
            "null IRFunction pointer"
        );

        // Compute the number of missing arguments
        size_t argDiff = (fun.numParams > argCount)? (fun.numParams - argCount):0;

        // Push undefined values for the missing last arguments
        for (size_t i = 0; i < argDiff; ++i)
            push(UNDEF, Type.CONST);

        // Push the visible function arguments in reverse order
        for (size_t i = 0; i < argCount; ++i)
        {
            auto argVal = argVals[argCount-(1+i)];
            push(argVal);
        }

        // Push the argument count
        push(Word.int32v(argCount), Type.INT32);

        // Push the "this" argument
        push(thisWord, thisType);

        // Push the closure argument
        push(Word.ptrv(closPtr), Type.REFPTR);

        // Push the return address
        push(Word.ptrv(cast(rawptr)retAddr), Type.RETADDR);
     
        // Push space for the callee locals
        auto numLocals = fun.numLocals - NUM_HIDDEN_ARGS - fun.numParams;
        push(numLocals);
    }

    /**
    Execute a unit-level IR function
    */
    ValuePair exec(IRFunction fun)
    {
        assert (
            fun.entryBlock !is null,
            "function has no entry block"
        );

        //writeln(fun.toString());

        // Register this function in the function reference set
        funRefs[cast(void*)fun] = fun;

        // Compile the entry block of the unit function
        auto entryFn = compileUnit(this, fun);

        // Call into the compiled code
        entryFn();

        // If a runtime error occurred, throw the exception object
        if (runError)
        {
            auto error = runError;
            runError = null;
            throw error;
        }

        // Ensure the stack contains at least one value
        assert (
            stackSize() >= 1,
            "stack is empty, no return value found"
        );

        // Get the return value
        auto retVal = ValuePair(*wsp, *tsp); 

        // Pop the return value off the stack
        pop(1);

        return retVal;
    }

    /**
    Execute a unit-level function
    */
    ValuePair exec(FunExpr fun)
    {
        auto ir = astToIR(fun);
        return exec(ir);
    }

    /**
    Get the path for a load command based on a (potentially relative) path
    */
    string getLoadPath(string fileName)
    {
        // If the path is relative, first check the Higgs lib dir
        if (!isAbsolute(fileName))
        {
            auto libFile = buildPath("/etc/higgs", fileName);
            if (!exists(fileName) && exists(libFile))
                fileName = to!string(libFile);
        }

        return fileName;
    }

    /**
    Parse and execute a source file
    */
    ValuePair load(string fileName)
    {
        auto file = getLoadPath(fileName);
        auto ast = parseFile(file);
        return exec(ast);
    }

    /**
    Parse and execute a source string
    */
    ValuePair evalString(string input, string fileName = "string")
    {
        //writefln("input: %s", input);

        auto ast = parseString(input, fileName);
        auto result = exec(ast);

        return result;
    }

    /// Stack frame visit function
    alias void delegate(
        IRFunction fun, 
        Word* wsp, 
        Type* tsp, 
        size_t depth,
        size_t frameSize,
        IRInstr callInstr
    ) VisitFrameFn;

    /**
    Visit each stack frame currently on the stack
    */
    void visitStack(VisitFrameFn visitFrame)
    {
        // If the stack is empty, stop
        if (this.stackSize() == 0)
            return;

        // Get the current stack pointers
        auto wsp = this.wsp;
        auto tsp = this.tsp;

        // Current call context
        auto curCtx = callCtx;

        // For each stack frame, starting from the topmost
        for (size_t depth = 0;; depth++)
        {
            assert (curCtx !is null);
            auto curFun = curCtx.fun;
            assert (curFun !is null);

            auto numLocals = curFun.numLocals + curCtx.extraLocals;
            auto numParams = curFun.numParams;
            auto argcSlot  = curFun.argcVal.outSlot;
            auto raSlot    = curFun.raVal.outSlot;

            assert (
                wsp + numLocals <= this.wUpperLimit, 
                "no room for numLocals in stack frame"
            );

            // Get the argument count
            auto argCount = wsp[argcSlot].int32Val;

            // Compute the actual number of extra arguments to pop
            size_t extraArgs = (argCount > numParams)? (argCount - numParams):0;

            // Compute the number of locals in this frame
            auto frameSize = numLocals + extraArgs;

            /*
            writeln("curFun: ", curFun.getName);
            writeln("numLocals=", numLocals);
            writeln("argcSlot=", argcSlot);
            writeln("raSlot=", raSlot);
            writeln("argCount=", argCount);
            writeln("frameSize=", frameSize);
            */

            // Get the return address
            assert (
                tsp[raSlot] is Type.RETADDR,
                "invalid type tag at return address slot"
            );
            auto retAddr = cast(CodePtr)wsp[raSlot].ptrVal;

            // Find the return address entry
            assert (
                retAddr in retAddrMap,
                "no return entry for return address: " ~ to!string(retAddr)
            );
            auto retEntry = retAddrMap[retAddr];

            // Visit this stack frame
            visitFrame(
                curFun,
                wsp,
                tsp,
                depth,
                frameSize,
                retEntry.callInstr
            );

            // If we reached the bottom of the stack, stop
            if (retEntry.callInstr is null)
                break;

            // Pop the stack frame
            wsp += frameSize;
            tsp += frameSize;

            // Move to the caller frame's context
            curCtx = retEntry.callCtx;
        }
    }
}

/**
Throw an exception, unwinding the stack until an exception handler
is found. Returns a pointer to the exception handler code.
*/
extern (C) CodePtr throwExc(
    VM vm,
    CallCtx callCtx,
    IRInstr throwInstr,
    CodeFragment throwHandler,
    Word excWord,
    Type excType
)
{
    //writefln("throw");

    // Stack trace (throwing instruction and call instructions)
    IRInstr[] trace;

    // Current call context when the exception was thrown
    auto curCtx = callCtx;

    // Get the exception handler code, if supplied
    auto curHandler = throwHandler? throwHandler.getCodePtr(vm.execHeap):null;

    // Until we're done unwinding the stack
    for (IRInstr curInstr = throwInstr;;)
    {
        assert (curInstr !is null);

        // Add the current instruction to the stack trace
        trace ~= curInstr;    

        //writeln("unwinding: ", curInstr.toString, " in ", curInstr.block.fun.getName);
        //writeln("stack size: ", vm.stackSize);

        // If the current instruction has an exception handler
        if (curHandler !is null)
        {
            //writefln("found exception handler");

            // Push the exception value on the stack
            vm.push(excWord, excType);

            // Return the exception handler address
            return curHandler;
        }

        auto curFun = curCtx.fun;
        assert (curFun !is null);

        auto numLocals = curFun.numLocals + curCtx.extraLocals;
        auto numParams = curFun.numParams;
        auto argcSlot  = curFun.argcVal.outSlot;
        auto raSlot    = curFun.raVal.outSlot;

        // Get the return address
        auto retAddr = cast(CodePtr)vm.wsp[raSlot].ptrVal;

        // Find the return address entry
        assert (
            retAddr in vm.retAddrMap,
            "no return entry for return address: " ~ to!string(retAddr)
        );
        auto retEntry = vm.retAddrMap[retAddr];

        // Get the calling instruction and context for this stack frame
        curInstr = retEntry.callInstr;
        curCtx = retEntry.callCtx;

        // If we have reached the bottom of the stack
        if (curInstr is null)
        {
            //writeln("reached stack bottom");

            assert (retEntry.retCode !is null);

            // Set the runtime error value
            vm.runError = new RunError(vm, ValuePair(excWord, excType), trace);

            // Return the return code branch
            return retEntry.retCode.getCodePtr(vm.execHeap);
        }

        // Get the exception handler code for the calling instruction
        curHandler = retEntry.excCode? retEntry.excCode.getCodePtr(vm.execHeap):null;

        // Get the argument count
        auto argCount = vm.wsp[argcSlot].int32Val;

        // Compute the actual number of extra arguments to pop
        size_t extraArgs = (argCount > numParams)? (argCount - numParams):0;

        // Pop all local stack slots and arguments
        vm.pop(numLocals + extraArgs);
    }

    assert (false);
}

/**
Throw a JavaScript error object as an exception
*/
extern (C) CodePtr throwError(
    VM vm,
    CallCtx callCtx,
    IRInstr throwInstr,
    CodeFragment throwHandler,
    string ctorName, 
    string errMsg
)
{
    auto errStr = GCRoot(vm, getString(vm, to!wstring(errMsg)));

    auto errCtor = GCRoot(
        vm,
        getProp(
            vm,
            vm.globalObj,
            to!wstring(ctorName)
        )
    );

    // If the error constructor is an object
    if (valIsLayout(errCtor.pair, LAYOUT_OBJ))
    {
        auto errProto = GCRoot(
            vm,
            getProp(
                vm,
                errCtor.ptr,
                "prototype"w
            )
        );

        // If the error prototype is an object
        if (valIsLayout(errCtor.pair, LAYOUT_OBJ))
        {
            // Create the error object
            auto excObj = GCRoot(
                vm,
                    newObj(
                    vm, 
                    new ObjMap(vm, 1), 
                    errProto.ptr
                )
            );

            // Set the error "message" property
            setProp(
                vm,
                excObj.ptr,
                "message"w,
                errStr.pair
            );

            return throwExc(
                vm,
                callCtx,
                throwInstr,
                throwHandler,
                excObj.word,
                excObj.type
            );
        }
    }

    // Throw the error string directly
    return throwExc(
        vm,
        callCtx,
        throwInstr,
        throwHandler,
        errStr.word,
        errStr.type,
    );
}

