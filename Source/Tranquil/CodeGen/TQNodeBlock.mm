#import "TQNodeBlock.h"
#import "TQProgram.h"
#import "../Shared/TQDebug.h"
#import "ObjcSupport/TQHeaderParser.h"
#import "TQNodeVariable.h"
#import "TQNodeArgumentDef.h"
#import "TQNodeCustom.h"
#import "TQNode+Private.h"
#import <llvm/Intrinsics.h>
#import <llvm/InstrTypes.h>
#include <iostream>

// The struct index where captured variables begin
#define TQ_CAPTURE_IDX 5

using namespace llvm;

@interface TQNodeBlock (Private)
- (llvm::Function *)_generateCopyHelperInProgram:(TQProgram *)aProgram;
- (llvm::Function *)_generateDisposeHelperInProgram:(TQProgram *)aProgram;
@end

@implementation TQNodeBlock
@synthesize arguments=_arguments, statements=_statements, cleanupStatements=_cleanupStatements, locals=_locals, capturedVariables=_capturedVariables,
    basicBlock=_basicBlock, function=_function, builder=_builder, autoreleasePool=_autoreleasePool,
    isCompactBlock=_isCompactBlock, parent=_parent, isVariadic=_isVariadic, isTranquilBlock=_isTranquilBlock,
    invokeName=_invokeName, argTypes=_argTypes, retType=_retType, dispatchGroup=_dispatchGroup,
    nonLocalReturnTarget=_nonLocalReturnTarget, nonLocalReturnThread=_nonLocalReturnThread, literalPtr=_literalPtr;

+ (TQNodeBlock *)node { return (TQNodeBlock *)[super node]; }

- (id)init
{
    if(!(self = [super init]))
        return nil;

    _arguments         = [NSMutableArray new];
    _statements        = [NSMutableArray new];
    _cleanupStatements = [NSMutableArray new];
    _locals            = [NSMutableDictionary new];
    _capturedVariables = [NSMutableDictionary new];
    _function          = NULL;
    _basicBlock        = NULL;
    _isTranquilBlock   = YES;
    _invokeName        = @"__tranquil";
    _literalPtr        = [TQNodePointerVariable tempVar];
    [self.locals setObject:_literalPtr forKey:_literalPtr.name];

    // Block invocations are always passed the block itself as the first argument
    [self addArgument:[TQNodeArgumentDef nodeWithName:@"__blockPtr"] error:nil];

    return self;
}

- (void)dealloc
{
    [_locals release];
    [_arguments release];
    [_statements release];
    [_argTypes release];
    [_retType release];
    delete _builder;
    [super dealloc];
}

- (NSString *)description
{
    NSMutableString *out = [NSMutableString stringWithString:@"<blk@ {"];
    if(_arguments.count > 0 || _isVariadic) {
        int i = 1;
        for(TQNodeArgumentDef *arg in _arguments) {
            [out appendFormat:@"%@", [arg name]];
            if([arg defaultArgument])
                [out appendFormat:@" = %@", [arg defaultArgument]];

            if(i++ < [_arguments count] || _isVariadic)
                [out appendString:@", "];
        }
        if(_isVariadic)
            [out appendString:@"..."];
        [out appendString:@"|"];
    }
    if(_statements.count > 0) {
        [out appendString:@"\n"];
        for(TQNode *stmt in _statements) {
            [out appendFormat:@"\t%@\n", stmt];
        }
    }
    [out appendString:@"}>"];
    return out;
}

- (NSString *)toString
{
    return @"block";
}

- (NSString *)signatureInProgram:(TQProgram *)aProgram
{
    return [_argTypes componentsJoinedByString:@""];
    // Return type
    NSMutableString *sig = [NSMutableString stringWithString:@"@"];
    // Argument types
    for(int i = 0; i < _arguments.count; ++i)
        [sig appendString:@"@"];
    return sig;
}

- (BOOL)addArgument:(TQNodeArgumentDef *)aArgument error:(NSError **)aoErr
{
    TQAssertSoft(![_arguments containsObject:aArgument],
                 kTQSyntaxErrorDomain, kTQUnexpectedIdentifier, NO,
                 @"Duplicate arguments for '%@'", aArgument);

    [_arguments addObject:aArgument];

    return YES;
}

- (void)setStatements:(NSMutableArray *)aStatements
{
    NSArray *old = _statements;
    _statements = [aStatements mutableCopy];
    [old release];
}


- (llvm::Type *)_blockDescriptorTypeInProgram:(TQProgram *)aProgram
{
    static Type *descriptorType = NULL;
    if(descriptorType)
        return descriptorType;

    Type *i8PtrTy = aProgram.llInt8PtrTy;
    Type *i8Ty = aProgram.llInt8Ty;
    Type *int32Ty = aProgram.llInt32Ty;
    Type *longTy  = aProgram.llLongTy; // Should be unsigned

    descriptorType = StructType::create("struct.__block_descriptor",
                                        longTy,  // reserved
                                        longTy,  // size ( = sizeof(literal))
                                        i8PtrTy, // copy_helper(void *dst, void *src)
                                        i8PtrTy, // dispose_helper(void *blk)
                                        i8PtrTy, // signature
                                        i8PtrTy, // GC info (Unused in objc2 => always NULL)
                                        // Following are only read if the block's flags indicate TQ_BLOCK_IS_TRANQUIL_BLOCK
                                        // (Which they do for all tranquil blocks)
                                        int32Ty,    // numArgs
                                        i8Ty,    // isVariadic
                                        NULL);
    descriptorType = PointerType::getUnqual(descriptorType);
    return descriptorType;
}

- (llvm::Type *)_blockLiteralTypeInProgram:(TQProgram *)aProgram
{
    if(_literalType)
        return _literalType;

    Type *i8PtrTy = aProgram.llInt8PtrTy;
    Type *intTy   = aProgram.llIntTy;

    std::vector<Type*> fields;
    fields.push_back(i8PtrTy); // isa
    fields.push_back(intTy);   // flags
    fields.push_back(intTy);   // reserved
    fields.push_back(i8PtrTy); // invoke(void *blk, ...)
    fields.push_back([self _blockDescriptorTypeInProgram:aProgram]);

    // Fields for captured vars
    for(NSString *name in [[_capturedVariables allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        TQNodeVariable *var = [_capturedVariables objectForKey:name];
        if(var.isAnonymous)
            fields.push_back([[var class] valueTypeInProgram:aProgram]);
        else
            fields.push_back(i8PtrTy);
    }

    _literalType = StructType::get(aProgram.llModule->getContext(), fields, true);
    return _literalType;
}


#pragma mark - Code generation

- (NSUInteger)argumentCount
{
    return [_arguments count] - 1;
}

// Descriptor is a constant struct describing all instances of this block
- (llvm::Constant *)_generateBlockDescriptorInProgram:(TQProgram *)aProgram
{
    if(_blockDescriptor)
        return _blockDescriptor;

    llvm::Module *mod = aProgram.llModule;
    Type *int8Ty = aProgram.llInt8Ty;
    Type *int32Ty = aProgram.llInt32Ty;
    Type *longTy  = aProgram.llLongTy;

    SmallVector<llvm::Constant*, 6> elements;

    // reserved
    elements.push_back(llvm::ConstantInt::get( aProgram.llLongTy, 0));

    // Size
    elements.push_back(ConstantExpr::getIntegerCast(ConstantExpr::getSizeOf([self _blockLiteralTypeInProgram:aProgram]), longTy, TRUE));

    elements.push_back([self _generateCopyHelperInProgram:aProgram]);
    elements.push_back([self _generateDisposeHelperInProgram:aProgram]);

    // Signature
    elements.push_back(ConstantExpr::getBitCast((GlobalVariable*)[aProgram getGlobalStringPtr:[self signatureInProgram:aProgram] inBlock:self],
                       aProgram.llInt8PtrTy));

    // GC Layout (unused in objc 2)
    elements.push_back(llvm::Constant::getNullValue(aProgram.llInt8PtrTy));

    elements.push_back(llvm::ConstantInt::get(int32Ty, [self argumentCount]));
    elements.push_back(llvm::ConstantInt::get(int8Ty, _isVariadic)); // isVariadic? always false for now

    llvm::Constant *init = llvm::ConstantStruct::getAnon(elements);

    const char *globalName = [[NSString stringWithFormat:@"%@_blockDescriptor", [self invokeName]] UTF8String];
    llvm::GlobalVariable *global = new llvm::GlobalVariable(*mod, init->getType(), true,
                                    llvm::GlobalValue::InternalLinkage,
                                    init, globalName);

    _blockDescriptor = llvm::ConstantExpr::getBitCast(global, [self _blockDescriptorTypeInProgram:aProgram]);

    return _blockDescriptor;
}

// The block literal is a stack allocated struct representing a single instance of this block
- (llvm::Value *)_generateBlockLiteralInProgram:(TQProgram *)aProgram parentBlock:(TQNodeBlock *)aParentBlock root:(TQNodeRootBlock *)aRoot
{
    Module *mod = aProgram.llModule;
    IRBuilder<> *pBuilder = aParentBlock.builder;

    Type *i8PtrTy = aProgram.llInt8PtrTy;
    Type *intTy   = aProgram.llIntTy;

    // Build the block struct
    std::vector<Constant *> fields;

    // isa
    Value *isaPtr = mod->getNamedValue("_NSConcreteStackBlock");
    if(!isaPtr)
        isaPtr = new GlobalVariable(*mod, i8PtrTy, false,
                             llvm::GlobalValue::ExternalLinkage,
                             0, "_NSConcreteStackBlock");
    isaPtr =  pBuilder->CreateBitCast(isaPtr, i8PtrTy);

    // __flags
    int flags = TQ_BLOCK_HAS_COPY_DISPOSE | TQ_BLOCK_HAS_SIGNATURE;
    if(_isTranquilBlock)
        flags |= TQ_BLOCK_IS_TRANQUIL_BLOCK;

    Value *invoke = pBuilder->CreateBitCast(_function, i8PtrTy, "invokePtr");
    Constant *descriptor = [self _generateBlockDescriptorInProgram:aProgram];

    IRBuilder<> entryBuilder(&aParentBlock.function->getEntryBlock(), aParentBlock.function->getEntryBlock().begin());
    Type *literalTy = [self _blockLiteralTypeInProgram:aProgram];
    AllocaInst *alloca = entryBuilder.CreateAlloca(literalTy, 0, "block");
    alloca->setAlignment(8);

    pBuilder->CreateStore(isaPtr,                         pBuilder->CreateStructGEP(alloca, 0 , "block.isa"));
    pBuilder->CreateStore(ConstantInt::get(intTy, flags), pBuilder->CreateStructGEP(alloca, 1,  "block.flags"));
    pBuilder->CreateStore(ConstantInt::get(intTy, 0),     pBuilder->CreateStructGEP(alloca, 2,  "block.reserved"));
    pBuilder->CreateStore(invoke,                         pBuilder->CreateStructGEP(alloca, 3 , "block.invoke"));
    pBuilder->CreateStore(descriptor,                     pBuilder->CreateStructGEP(alloca, 4 , "block.descriptor"));

    // Now that we've initialized the basic block info, we need to capture the variables in the parent block scope
    if(_capturedVariables) {
        int i = TQ_CAPTURE_IDX;
        for(NSString *name in [[_capturedVariables allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
            TQNodeVariable *varToCapture = [_capturedVariables objectForKey:name];
            [varToCapture createStorageInProgram:aProgram block:aParentBlock root:aRoot error:nil];
            NSString *fieldName = [NSString stringWithFormat:@"block.%@", name];

            Value *valToStore = varToCapture.alloca;
            if(varToCapture.isAnonymous)
                valToStore = pBuilder->CreateLoad(varToCapture.alloca);
            else
                valToStore = pBuilder->CreateBitCast(valToStore, i8PtrTy);
            pBuilder->CreateStore(valToStore, pBuilder->CreateStructGEP(alloca, i++, [fieldName UTF8String]));
        }
    }

    return pBuilder->CreateBitCast(alloca, i8PtrTy);
}

// Copies the captured variables when this block is copied to the heap
- (llvm::Function *)_generateCopyHelperInProgram:(TQProgram *)aProgram
{
    // void (*copy_helper)(void *dst, void *src)
    Type *int8PtrTy = aProgram.llInt8PtrTy;
    Type *intTy = aProgram.llIntTy;
    std::vector<Type *> paramTypes;
    paramTypes.push_back(int8PtrTy);
    paramTypes.push_back(int8PtrTy);

    FunctionType* funType = FunctionType::get(aProgram.llVoidTy, paramTypes, false);

    llvm::Module *mod = aProgram.llModule;

    const char *functionName = [[NSString stringWithFormat:@"%@_copy", [self invokeName]] UTF8String];
    Function *function;
    function = Function::Create(funType, GlobalValue::ExternalLinkage, functionName, mod);
    function->setCallingConv(CallingConv::C);

    BasicBlock *basicBlock = BasicBlock::Create(mod->getContext(), "entry", function, 0);
    IRBuilder<> *builder = new IRBuilder<>(basicBlock);

    Type *blockPtrTy = PointerType::getUnqual([self _blockLiteralTypeInProgram:aProgram]);

    // Load the passed arguments
    AllocaInst *dstAlloca = builder->CreateAlloca(int8PtrTy, 0, "dstBlk.alloca");
    AllocaInst *srcAlloca = builder->CreateAlloca(int8PtrTy, 0, "srcBlk.alloca");

    Function::arg_iterator args = function->arg_begin();
    builder->CreateStore(args, dstAlloca);
    builder->CreateStore(++args, srcAlloca);

    Value *dstBlock = builder->CreateBitCast(builder->CreateLoad(dstAlloca), blockPtrTy, "dstBlk");
    Value *srcBlock = builder->CreateBitCast(builder->CreateLoad(srcAlloca), blockPtrTy, "srcBlk");
    Value *byrefFlags = ConstantInt::get(intTy, TQ_BLOCK_FIELD_IS_BYREF);
    Value *constFlags = ConstantInt::get(intTy, TQ_BLOCK_FIELD_IS_OBJECT);

    int i = TQ_CAPTURE_IDX;
    Value *src, *destAddr;
    Type *captureStructTy;
    for(NSString *name in [[_capturedVariables allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        TQNodeVariable *var = [_capturedVariables objectForKey:name];
        if(![[var class] valueIsObject]) {
            ++i;
            continue;
        }
        Value *flags = var.isAnonymous ? constFlags : byrefFlags;

        NSString *dstName = [NSString stringWithFormat:@"dstBlk.%@Addr", var.name];
        NSString *srcName = [NSString stringWithFormat:@"srcBlk.%@", var.name];

        destAddr  = builder->CreateBitCast(builder->CreateStructGEP(dstBlock, i), int8PtrTy, [dstName UTF8String]);
        src = builder->CreateLoad(builder->CreateStructGEP(srcBlock, i++), [srcName UTF8String]);
        builder->CreateCall3(aProgram._TQ_Block_object_assign, destAddr, builder->CreateBitCast(src, int8PtrTy), flags);
    }

    builder->CreateRetVoid();
    delete builder;
    return function;
}

// Releases the captured variables when this block's retain count reaches 0
- (llvm::Function *)_generateDisposeHelperInProgram:(TQProgram *)aProgram
{
    // void dispose_helper(void *src)
    Type *int8PtrTy = aProgram.llInt8PtrTy;
    std::vector<Type *> paramTypes;
    Type *intTy = aProgram.llIntTy;
    paramTypes.push_back(int8PtrTy);

    FunctionType *funType = FunctionType::get(aProgram.llVoidTy, paramTypes, false);

    llvm::Module *mod = aProgram.llModule;

    const char *functionName = [[NSString stringWithFormat:@"%@_dispose", [self invokeName]] UTF8String];
    Function *function;
    function = Function::Create(funType, GlobalValue::ExternalLinkage, functionName, mod);
    function->setCallingConv(CallingConv::C);

    BasicBlock *basicBlock = BasicBlock::Create(mod->getContext(), "entry", function, 0);
    IRBuilder<> *builder = new IRBuilder<>(basicBlock);
    // Load the block
    Value *block = builder->CreateBitCast(function->arg_begin(), PointerType::getUnqual([self _blockLiteralTypeInProgram:aProgram]), "block");
    Value *byrefFlags = ConstantInt::get(intTy, TQ_BLOCK_FIELD_IS_BYREF);
    Value *constFlags = ConstantInt::get(intTy, TQ_BLOCK_FIELD_IS_OBJECT);

    int i = TQ_CAPTURE_IDX;
    Value *varToDisposeOf, *valueToRelease;
    Type *captureStructTy;
    for(NSString *name in [[_capturedVariables allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        TQNodeVariable *var = [_capturedVariables objectForKey:name];
        if(![[var class] valueIsObject]) {
            ++i;
            continue;
        }
        Value *flags = var.isAnonymous ? constFlags : byrefFlags;

        NSString *irName = [NSString stringWithFormat:@"block.%@", var.name];
        varToDisposeOf =  builder->CreateLoad(builder->CreateStructGEP(block, i++), [irName UTF8String]);

        if(!var.isAnonymous) {
            captureStructTy = PointerType::getUnqual([[var class] captureStructTypeInProgram:aProgram]);
            valueToRelease = builder->CreateBitCast(varToDisposeOf, captureStructTy);
            valueToRelease = builder->CreateLoad(builder->CreateStructGEP(valueToRelease, 1)); // var->forwarding
            valueToRelease = builder->CreateBitCast(valueToRelease, captureStructTy);
            valueToRelease = builder->CreateStructGEP(valueToRelease, 4); // forwarding->capture

            builder->CreateCall(aProgram.objc_release, builder->CreateLoad(valueToRelease));
        } else if([[var class] valueIsObject])
            builder->CreateCall(aProgram.objc_release, varToDisposeOf);
        builder->CreateCall2(aProgram._Block_object_dispose, builder->CreateBitCast(varToDisposeOf, int8PtrTy), flags);
    }

    builder->CreateRetVoid();
    delete builder;
    return function;
}

// Invokes the body of this block
- (llvm::Function *)_generateInvokeInProgram:(TQProgram *)aProgram root:(TQNodeRootBlock *)aRoot block:(TQNodeBlock *)aBlock error:(NSError **)aoErr
{
    if(_function)
        return _function;

    llvm::PointerType *int8PtrTy = aProgram.llInt8PtrTy;

    // Build the invoke function
    std::vector<Type *> paramTypes;

    Type *retType = [aProgram llvmTypeFromEncoding:[_retType UTF8String]];

    NSUInteger retTypeSize;
    NSGetSizeAndAlignment([_retType UTF8String], &retTypeSize, NULL);
    // Return doesn't fit in a register so we must pass an alloca before the function arguments
    // TODO: Make this cross platform
    BOOL returningOnStack = TQStructSizeRequiresStret(retTypeSize);
    if(returningOnStack) {
        paramTypes.push_back(PointerType::getUnqual(retType));
        retType = aProgram.llVoidTy;
    }

    NSString *argTypeEncoding;
    NSUInteger argTypeSize;
    NSMutableArray *byValArgIndices = [NSMutableArray array];
    const char *currEncoding;
    for(int i = 0; i < [_argTypes count]; ++i) {
        currEncoding = [[_argTypes objectAtIndex:i] UTF8String];
        NSGetSizeAndAlignment(currEncoding, &argTypeSize, NULL);
        Type *llType = [aProgram llvmTypeFromEncoding:currEncoding];
        if(TQStructSizeRequiresStret(argTypeSize)) {
            llType = PointerType::getUnqual(llType);
            [byValArgIndices addObject:[NSNumber numberWithInt:i+1]]; // Add one to jump over retval
        }
        paramTypes.push_back(llType);
    }
    FunctionType* funType = FunctionType::get(retType, paramTypes, _isVariadic);

    Module *mod = aProgram.llModule;

    const char *functionName = [[self invokeName] UTF8String];
    _function = Function::Create(funType, GlobalValue::ExternalLinkage, functionName, mod);
    if(returningOnStack) {
        Attributes structRetAttr = Attributes::get(mod->getContext(), ArrayRef<Attributes::AttrVal>(Attributes::StructRet));
        _function->addAttribute(1, structRetAttr);
    }
    Attributes byvalAttr = Attributes::get(mod->getContext(), ArrayRef<Attributes::AttrVal>(Attributes::ByVal));
    for(NSNumber *idx in byValArgIndices) {
        _function->addAttribute([idx intValue], byvalAttr);
    }

    _basicBlock = BasicBlock::Create(mod->getContext(), "entry", _function, 0);
    _builder = new IRBuilder<>(_basicBlock);

    // Debug scope
    DIScope scope = DIScope(aProgram.debugBuilder->getCU());
    std::vector<Value *> debugRetArgTypes;
    DIType debugI8PtrTy = aProgram.debugBuilder->createBasicType("uint8", 8, 8, llvm::dwarf::DW_ATE_unsigned);
    debugI8PtrTy = aProgram.debugBuilder->createPointerType(debugI8PtrTy, aProgram.llPointerWidthInBits); // TODO : cache types so duplicates are not created
    debugRetArgTypes.push_back(debugI8PtrTy);
    for(id unused in _arguments) {
        debugRetArgTypes.push_back(debugI8PtrTy);
    }


    llvm::DIArray diTypeArr  = aProgram.debugBuilder->getOrCreateArray(debugRetArgTypes);
    DIType subroutineTy = aProgram.debugBuilder->createSubroutineType(aRoot.file, diTypeArr);
    assert(subroutineTy.Verify());

    _debugInfo = aProgram.debugBuilder->createFunction(aBlock.scope ?: DIScope(aProgram.debugBuilder->getCU()),
                                                       functionName, functionName,
                                                       aRoot.file,
                                                       self.lineNumber,
                                                       subroutineTy,
                                                       false,
                                                       true,
                                                       self.lineNumber,
                                                       0,
                                                       false,
                                                       _function);
    assert(_debugInfo.Verify());

    _scope = aProgram.debugBuilder->createLexicalBlock(_debugInfo, aRoot.file, self.lineNumber, 0);
    assert(_scope.Verify());
    _builder->SetCurrentDebugLocation(DebugLoc::get(self.lineNumber, 0, _scope, NULL));


    // Start building the function
    if(!_isCompactBlock)
        _autoreleasePool = _builder->CreateCall(aProgram.objc_autoreleasePoolPush);

    // Load the block pointer argument (must do this before captures, which must be done before arguments in case a default value references a capture)
    llvm::Function::arg_iterator argumentIterator = _function->arg_begin();
    Value *thisBlock = NULL;
    Value *thisBlockPtr = NULL;
    if([_arguments count] > 0) {
        thisBlockPtr = argumentIterator;
        [_literalPtr store:thisBlockPtr inProgram:aProgram block:self root:aRoot error:aoErr];
        thisBlock = _builder->CreateBitCast(thisBlockPtr, PointerType::getUnqual([self _blockLiteralTypeInProgram:aProgram]));
        argumentIterator++;
    } else
        [_literalPtr store:ConstantPointerNull::get(int8PtrTy) inProgram:aProgram block:self root:aRoot error:aoErr];

    // Load captured variables
    if(thisBlock) {
        int i = TQ_CAPTURE_IDX;
        TQNodeVariable *varToLoad;
        for(NSString *name in [[_capturedVariables allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
            TQNodeVariable *parentVar = [_capturedVariables objectForKey:name];
            varToLoad = [parentVar copy];
            Value *valueToLoad = _builder->CreateStructGEP(thisBlock, i++, [varToLoad.name UTF8String]);
            if(![varToLoad isAnonymous])
                valueToLoad = _builder->CreateBitCast(_builder->CreateLoad(valueToLoad), PointerType::getUnqual([[varToLoad class] captureStructTypeInProgram:aProgram]));
            varToLoad.alloca = (AllocaInst *)valueToLoad;

            [_locals setObject:varToLoad forKey:varToLoad.name];
            [varToLoad release];
        }
    }

    // Load the rest of arguments
    Value *sentinel = _builder->CreateLoad(mod->getOrInsertGlobal("TQNothing", aProgram.llInt8PtrTy));
    Value *argValue;
    for(unsigned i = 1; i < _arguments.count; ++i, ++argumentIterator)
    {
        TQNodeArgumentDef *argDef = [_arguments objectAtIndex:i];
        if(![argDef name])
            continue;

        argTypeEncoding = [_argTypes objectAtIndex:i];
        NSGetSizeAndAlignment([argTypeEncoding UTF8String], &argTypeSize, NULL);

        // If the value is an object type we treat it the normal way
        if([argTypeEncoding isEqualToString:@"@"]) {
            Value *defaultValue, *isMissingCond;
            // Load the default argument if the argument was not passed
            if(![argDef defaultArgument])
                defaultValue = ConstantPointerNull::get(aProgram.llInt8PtrTy);
            else
                defaultValue = [[argDef defaultArgument] generateCodeInProgram:aProgram block:self root:aRoot error:aoErr];

            isMissingCond = _builder->CreateICmpEQ(argumentIterator, sentinel);
            argValue = _builder->CreateSelect(isMissingCond, defaultValue, argumentIterator);
        }
        // Otherwise we need to box the value & we are not able to use default arguments
        else {
            IRBuilder<> entryBuilder(&_function->getEntryBlock(), _function->getEntryBlock().begin());
            if(TQStructSizeRequiresStret(argTypeSize))
                argValue = argumentIterator;
            else {
                argValue = entryBuilder.CreateAlloca(paramTypes[i], 0,
                                                     [[@"boxingBuffer_" stringByAppendingString:[[_arguments objectAtIndex:i] name]] UTF8String]);
                _builder->CreateStore(argumentIterator, argValue);
            }
            argValue = _builder->CreateCall2(aProgram.TQBoxValue,
                                             _builder->CreateBitCast(argValue, int8PtrTy),
                                             [aProgram getGlobalStringPtr:argTypeEncoding withBuilder:_builder]);
        }
        TQNodeVariable *local = [TQNodeVariable nodeWithName:[argDef name]];
        local.lineNumber = self.lineNumber;
        local.shadows = YES;
        [local store:argValue
            retained:!argDef.unretained
           inProgram:aProgram
               block:self
                root:aRoot
               error:aoErr];
    }
    if(_isVariadic) {
        // Create an array and loop through the va_list till we reach the sentinel
        Value *vaList = _builder->CreateAlloca(aProgram.llVaListTy, NULL, "valist");
        Function *vaStart = Intrinsic::getDeclaration(mod, Intrinsic::vastart);
        Function *vaEnd = Intrinsic::getDeclaration(mod, Intrinsic::vaend);

        Value *valistCast = _builder->CreateBitCast(vaList, aProgram.llInt8PtrTy);
        _builder->CreateCall(vaStart, valistCast);
        Value *vaargArray = _builder->CreateCall(aProgram.TQVaargsToArray, valistCast);
        _builder->CreateCall(vaEnd, valistCast);

        TQNodeVariable *dotDotDot = [TQNodeVariable nodeWithName:@"TQArguments"];
        dotDotDot.lineNumber = self.lineNumber;
        dotDotDot.shadows = YES;
        [dotDotDot store:vaargArray inProgram:aProgram block:self root:aRoot error:aoErr];
    }

    // Set up the non-local return jump point if required
    if(_nonLocalReturnTarget) {
        BasicBlock *nonLocalReturnBlock = BasicBlock::Create(mod->getContext(), "nonLocalRet", _function, 0);
        BasicBlock *nonLocalReturnPerfBlock = BasicBlock::Create(mod->getContext(), "nonLocalRetPerf", _function, 0);
        BasicBlock *nonLocalReturnPropBlock = BasicBlock::Create(mod->getContext(), "nonLocalRetProp", _function, 0);
        BasicBlock *bodyBlock = BasicBlock::Create(mod->getContext(), "body", _function, 0);

        Value *jmpBuf  = _builder->CreateCall(aProgram.TQPushNonLocalReturnStack, thisBlockPtr ? thisBlockPtr : ConstantPointerNull::get(int8PtrTy));
        Value *jmpRes  = _builder->CreateCall(aProgram.setjmp, jmpBuf);
        Value *jmpTest = _builder->CreateICmpEQ(jmpRes, ConstantInt::get(aProgram.llIntTy, 0));
        _builder->CreateCondBr(jmpTest, bodyBlock, nonLocalReturnBlock);

        IRBuilder<> nlrBuilder(nonLocalReturnBlock);
        Value *shouldProp = nlrBuilder.CreateCall(aProgram.TQShouldPropagateNonLocalReturn, thisBlockPtr ? thisBlockPtr : ConstantPointerNull::get(int8PtrTy));
        shouldProp = nlrBuilder.CreateICmpEQ(shouldProp, ConstantInt::get(aProgram.llIntTy, 1));
        nlrBuilder.CreateCondBr(shouldProp, nonLocalReturnPropBlock, nonLocalReturnPerfBlock);

        IRBuilder<> nlrPerfBuilder(nonLocalReturnPerfBlock);
        Value *nonLocalRetVal = nlrPerfBuilder.CreateCall(aProgram.TQGetNonLocalReturnValue);
        nlrPerfBuilder.CreateRet(nonLocalRetVal);

        IRBuilder<> nlrPropBuilder(nonLocalReturnPropBlock);
        nlrPropBuilder.CreateCall2(aProgram.longjmp, nlrPropBuilder.CreateCall(aProgram.TQGetNonLocalReturnPropagationJumpTarget), ConstantInt::get(aProgram.llIntTy, 0));
        nlrPropBuilder.CreateRet(ConstantPointerNull::get(aProgram.llInt8PtrTy));

        _basicBlock = bodyBlock;
        delete _builder;
        _builder = new IRBuilder<>(bodyBlock);

        [_nonLocalReturnTarget store:_builder->CreateCall(aProgram.TQNonLocalReturnStackHeight)
                           inProgram:aProgram block:self root:aRoot error:aoErr];
        [_nonLocalReturnThread store:_builder->CreateCall(aProgram.pthread_self)
                           inProgram:aProgram block:self root:aRoot error:aoErr];
    }

    // Evaluate the statements
    Value *val;
    NSUInteger stmtCount = [_statements count];
    for(int i = 0; i < stmtCount; ++i) {
        TQNode *stmt = [_statements objectAtIndex:i];
        if([_retType isEqualToString:@"@"] && ((i == (stmtCount-1) && ![stmt isKindOfClass:[TQNodeReturn class]]))) {
            int line = stmt.lineNumber;
            stmt = [TQNodeReturn nodeWithValue:stmt];
            stmt.lineNumber = line;
        }

        @try {
            [stmt generateCodeInProgram:aProgram block:self root:aRoot error:aoErr];
        } @catch (NSException *e) {
            *aoErr = [NSError errorWithDomain:kTQSyntaxErrorDomain
                                         code:kTQObjCException
                                     userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[e reason], NSLocalizedDescriptionKey,
                                                                                         e, @"exception", nil]];
        }

       if(*aoErr) {
            _function->eraseFromParent();
            _function = NULL;
            return NULL;
        }
        if([stmt isKindOfClass:[TQNodeReturn class]])
            break;
    }
    if(!_basicBlock->getTerminator()) {
        TQNode *ret = [TQNodeReturn node];
        ret.lineNumber = self.lineNumber;
        [ret generateCodeInProgram:aProgram block:self root:aRoot error:aoErr];
    }
    return _function;
}

- (void)_prepareNonLocalRetInProgram:(TQProgram *)aProgram
{
    // Check if there are any child blocks that contain a non-local return targeted at us
    __block void (^nonLocalRetChecker)(TQNode*, int);
    nonLocalRetChecker = ^(TQNode *n, int depth) {
        if([n isKindOfClass:[TQNodeReturn class]]) {
            int destDepth = [(TQNodeReturn *)n depth];
            if(!_nonLocalReturnTarget && depth > 0 && destDepth == depth) {
                _nonLocalReturnTarget = [TQNodeIntVariable tempVar];
                _nonLocalReturnThread = [TQNodeLongVariable tempVar];
            } else if(destDepth > depth) {
                // If there is a return that passes us, we need to capture the jump stack index of that parent
                TQNodeBlock *dest = self;
                for(int i = depth; i < destDepth; ++i) {
                    dest = dest.parent;
                }
                TQAssert(dest, @"Tried to jump to high");
                TQNodeIntVariable *target = dest.nonLocalReturnTarget;
                TQNodeVariable *targetPtr = dest.literalPtr;
                TQNodeIntVariable *thread = dest.nonLocalReturnThread;
                // If the target is not our immediate parent, we need to capture the var that our immediate parent captured.
                if(dest != _parent) {
                    target    = [_parent.locals objectForKey:target.name];
                    thread    = [_parent.locals objectForKey:thread.name];
                    targetPtr = [_parent.locals objectForKey:targetPtr.name];
                }
                [_capturedVariables setObject:target    forKey:target.name];
                [_capturedVariables setObject:thread    forKey:thread.name];
                [_capturedVariables setObject:targetPtr forKey:targetPtr.name];
            }
        } else if([n isKindOfClass:[TQNodeBlock class]])
            ++depth;
        [n iterateChildNodes:^(TQNode *child) { nonLocalRetChecker(child, depth); }];
    };
    nonLocalRetChecker(self, -1);


}
// Generates a block on the stack
- (llvm::Value *)generateCodeInProgram:(TQProgram *)aProgram
                                 block:(TQNodeBlock *)aBlock
                                  root:(TQNodeRootBlock *)aRoot
                                 error:(NSError **)aoErr
{
    TQAssert(!_basicBlock && !_function, @"Tried to regenerate code for block");
    _parent = aBlock;

    if(!_retType)
        _retType = @"@";
    if(!_argTypes) {
        _argTypes = [[NSMutableArray alloc] initWithCapacity:_arguments.count];
        for(TQNodeArgumentDef *arg in _arguments) {
            [_argTypes addObject:@"@"];
        }
    }

    [self _prepareNonLocalRetInProgram:aProgram];

    // Generate a list of variables to capture
    if(aBlock) {
        // Load actual captured variables
        for(NSString *name in [aBlock.locals allKeys]) {
            if([_locals objectForKey:name]) // Only arguments are contained in _locals at this point
                continue; // Arguments to this block override locals in the parent (Not that  you should write code like that)
            TQNodeVariable *parentVar = [aBlock.locals objectForKey:name];
            if(![self referencesNode:parentVar] || (!parentVar.shadows && [aProgram.globals objectForKey:name]))
                continue;

            [_capturedVariables setObject:parentVar forKey:name];
        }
    }

    [self _generateInvokeInProgram:aProgram root:aRoot block:aBlock error:aoErr];
    if(*aoErr)
        return NULL;

    Value *literal = [self _generateBlockLiteralInProgram:aProgram parentBlock:aBlock root:aRoot];

    return literal;
}

- (void)generateCleanupInProgram:(TQProgram *)aProgram
{
    for(TQNode *stmt in _cleanupStatements) {
        [stmt generateCodeInProgram:aProgram block:self root:nil error:nil];
    }
    if(_autoreleasePool)
        _builder->CreateCall(aProgram.objc_autoreleasePoolPop, _autoreleasePool);
    if(_nonLocalReturnTarget)
        _builder->CreateCall(aProgram.TQPopNonLocalReturnStack);
}

- (void)createDispatchGroupInProgram:(TQProgram *)aProgram
{
    if(_dispatchGroup)
        return;
    IRBuilder<> entryBuilder(&_function->getEntryBlock(), _function->getEntryBlock().begin());
    _dispatchGroup = entryBuilder.CreateCall(aProgram.dispatch_group_create);
    [self.cleanupStatements addObject:[TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *b, TQNodeRootBlock *r, NSError **) {
        _builder->CreateCall(aProgram.dispatch_release, _dispatchGroup);
        return (Value *)NULL;
    }]];
}

- (TQNode *)referencesNode:(TQNode *)aNode
{
    TQNode *ref = nil;

    if((ref = [_statements tq_referencesNode:aNode]))
        return ref;
    else if((ref = [_arguments tq_referencesNode:aNode]))
        return ref;

    return nil;
}

- (void)iterateChildNodes:(TQNodeIteratorBlock)aBlock
{
    NSMutableArray *statements = [_statements copy];
    for(TQNode *node in statements) {
        aBlock(node);
    }
    [statements release];
}

- (BOOL)insertChildNode:(TQNode *)aNodeToInsert before:(TQNode *)aNodeToShift
{
    NSUInteger idx = [_statements indexOfObject:aNodeToShift];
    if(idx == NSNotFound)
        return NO;
    [_statements insertObject:aNodeToInsert atIndex:idx];
    return YES;
}

- (BOOL)insertChildNode:(TQNode *)aNodeToInsert after:(TQNode *)aExistingNode
{
    NSUInteger idx = [_statements indexOfObject:aExistingNode];
    if(idx == NSNotFound)
        return NO;
    [_statements insertObject:aNodeToInsert atIndex:idx+1];
    return YES;
}

- (BOOL)replaceChildNodesIdenticalTo:(TQNode *)aNodeToReplace with:(TQNode *)aNodeToInsert
{
    NSUInteger idx = [_statements indexOfObject:aNodeToReplace];
    if(idx == NSNotFound)
        return NO;
    [_statements replaceObjectAtIndex:idx withObject:aNodeToInsert];
    return NO;
}

@end


#pragma mark - Root block

@implementation TQNodeRootBlock
@synthesize file=_file;

+ (TQNodeRootBlock *)node
{
    return [[self new] autorelease];
}

- (id)init
{
    if(!(self = [super init]))
        return nil;

    // No arguments for the root block ([super init] adds the block itself as an arg)
    [self.arguments removeAllObjects];
    _retType = @"@";
    _argTypes = [NSMutableArray new];
    _invokeName = @"__tranquil_root";
    self.lineNumber = 1;

    return self;
}

- (llvm::Value *)generateCodeInProgram:(TQProgram *)aProgram
                                 block:(TQNodeBlock *)aBlock
                                  root:(TQNodeRootBlock *)aRoot
                                 error:(NSError **)aoErr
{
    // The root block is just a function that executes the body of the program
    // so we only need to create&return it's invocation function
    [self _prepareNonLocalRetInProgram:aProgram];
    return [self _generateInvokeInProgram:aProgram root:aRoot block:aBlock error:aoErr];
}

@end
