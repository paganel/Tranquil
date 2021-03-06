#import "TQNodeOperator.h"
#import "TQNode+Private.h"
#import "TQNodeVariable.h"
#import "TQNodeCustom.h"
#import "TQNodeConditionalBlock.h"
#import "TQNodeMemberAccess.h"
#import "TQProgram.h"
#import "../Shared/TQDebug.h"
#import "TQNodeNumber.h"
#import "TQNodeConditionalBlock.h"
#import "../Runtime/TQRuntime.h"
#import "TQNodeValid.h"
#import "../Runtime/TQNumber.h"
#import <llvm/IR/Intrinsics.h>

using namespace llvm;

@implementation TQNodeOperator
@synthesize type=_type, left=_left, right=_right;

+ (TQNodeOperator *)nodeWithType:(TQOperatorType)aType left:(TQNode *)aLeft right:(TQNode *)aRight
{
    if(aType == kTQOperatorAssign)
        return [TQNodeAssignOperator nodeWithType:aType
                                             left:[NSMutableArray arrayWithObject:aLeft]
                                            right:[NSMutableArray arrayWithObject:aRight]];
    return [[[self alloc] initWithType:aType left:aLeft right:aRight] autorelease];
}

- (id)initWithType:(TQOperatorType)aType left:(TQNode *)aLeft right:(TQNode *)aRight
{
    if(!(self = [super init]))
        return nil;

    _type = aType;
    _left = [aLeft retain];
    _right = [aRight retain];

    return self;
}

- (void)dealloc
{
    [_left release];
    [_right release];
    [super dealloc];
}

- (BOOL)isEqual:(id)aOther
{
    if(![aOther isMemberOfClass:[self class]])
        return NO;
    return [_left isEqual:[aOther left]] && [_right isEqual:[aOther right]];
}

- (TQNode *)referencesNode:(TQNode *)aNode
{
    TQNode *ref = nil;
    if([self isEqual:aNode])
        return self;
    else if((ref = [_left referencesNode:aNode]))
        return ref;
    else if((ref = [_right referencesNode:aNode]))
        return ref;
    return nil;
}

- (void)iterateChildNodes:(TQNodeIteratorBlock)aBlock
{
    if(_left)
        aBlock(_left);
    if(_right)
        aBlock(_right);
}

- (BOOL)replaceChildNodesIdenticalTo:(TQNode *)aNodeToReplace with:(TQNode *)aNodeToInsert
{
    BOOL ret = NO;
    if(_left == aNodeToReplace) {
        self.left = aNodeToInsert;
        ret = YES;
    }
    if(_right == aNodeToReplace) {
        self.right = aNodeToInsert;
        ret = YES;
    }
    return ret;
}

#define B aBlock.builder
- (llvm::Value *)generateCodeInProgram:(TQProgram *)aProgram
                                 block:(TQNodeBlock *)aBlock
                                  root:(TQNodeRootBlock *)aRoot
                                 error:(NSError **)aoErr
{
    if(_type == kTQOperatorAssign) {
        TQAssert(NO, @"Use TQNodeAssignOperator to implement assignments");
        return NULL;
    } else if(_type == kTQOperatorUnaryMinus) {
        Value *right = [_right generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
        if(*aoErr)
            return NULL;
        Value *selector = [aProgram getSelector:@"negate" inBlock:aBlock root:aRoot];
        Value *ret = B->CreateCall2(aProgram.objc_msgSend, right, selector);
        [self _attachDebugInformationToInstruction:ret inProgram:aProgram block:aBlock root:aRoot];
        return ret;
    } else if(_type == kTQOperatorIncrement || _type == kTQOperatorDecrement) {
        TQAssert(!_left || !_right, @"Panic! in/decrement can't have both left&right hand sides");
        Value *beforeVal = NULL;

        // Return original value and increment (var++)
        TQNode *incrementee = _left ?: _right;
        if([incrementee respondsToSelector:@selector(createStorageInProgram:block:root:error:)])
            [(TQNodeVariable *)incrementee createStorageInProgram:aProgram block:aBlock root:aRoot error:aoErr];
        if(_left) {
            beforeVal = [incrementee generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
            if(*aoErr)
                return NULL;
        }
        TQNodeOperator *op = [TQNodeOperator nodeWithType:_type == kTQOperatorIncrement ? kTQOperatorAdd : kTQOperatorSubtract
                                                     left:incrementee
                                                    right:[TQNodeNumber nodeWithDouble:1.0]];

        Value *incrementedVal = [op generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
        [incrementee store:incrementedVal inProgram:aProgram block:aBlock root:aRoot error:aoErr];
        if(*aoErr)
            return NULL;

        if(beforeVal)
            return beforeVal;
        return incrementedVal;
    } else if(_type == kTQOperatorAnd || _type == kTQOperatorOr) {
        Value *leftVal = [_left generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
        if(*aoErr)
            return NULL;
        TQNodeCustom *leftWrapper = [TQNodeCustom nodeReturningValue:leftVal];
        TQNodeTernaryOperator *tern = [TQNodeTernaryOperator nodeWithCondition:leftWrapper
                                                                        ifExpr:nil // Use condition result without re-evaluating
                                                                          else:_right];
        tern.isNegated  = (_type == kTQOperatorAnd);
        tern.lineNumber = self.lineNumber;
        return [tern generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
    } else {
        Value *left  = [_left generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
        if(*aoErr)
            return NULL;
        Value *right = [_right generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
        if(*aoErr)
            return NULL;

        Value *selector = NULL;       // Selector to be sent in the general case (where one or both of the operands are not tagged numbers)
        TQNodeCustom *fastpath = nil; // Block to use in the case where both are tagged numbers
        BOOL fastpathResultIsNumber = YES;

        Value *numTag     = ConstantInt::get(aProgram.llIntPtrTy, kTQNumberTag);
        Value *nullPtr    = ConstantPointerNull::get(aProgram.llInt8PtrTy);

#define PtrToInt(val) B->CreatePtrToInt((val), aProgram.llIntPtrTy)
#define IntToPtr(val) B->CreateIntToPtr((val), aProgram.llInt8PtrTy)
#define IntCast(val) B->CreateZExt(B->CreateBitCast((val), aProgram.llInt32Ty), aProgram.llIntPtrTy)
#define FPCast(val) B->CreateBitCast(B->CreateTrunc((val), aProgram.llInt32Ty), aProgram.llFloatTy)
#define GET_AB() Value *a = FPCast(B->CreateAShr(PtrToInt(left),  4)); \
                 Value *b = FPCast(B->CreateAShr(PtrToInt(right), 4))
#define GET_VALID() [[TQNodeValid node] generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr]
#define GET_TQNUM(val) IntToPtr(B->CreateOr(B->CreateShl(IntCast(val), 4), numTag))

        switch(_type) {
            case kTQOperatorEqual: {
                fastpathResultIsNumber = NO;
                selector = [aProgram getSelector:@"isEqualTo:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateSelect(B->CreateFCmpOEQ(a, b), GET_VALID(), nullPtr);
                }];

            } break;
            case kTQOperatorInequal: {
                fastpathResultIsNumber = NO;
                selector = [aProgram getSelector:@"notEqualTo:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateSelect(B->CreateFCmpONE(a, b), GET_VALID(), nullPtr);
                }];
            } break;
            case kTQOperatorLesser:
                fastpathResultIsNumber = NO;
                selector = [aProgram getSelector:@"isLesserThan:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateSelect(B->CreateFCmpOLT(a, b), GET_VALID(), nullPtr);
                }];
                break;
            case kTQOperatorGreater:
                fastpathResultIsNumber = NO;
                selector = [aProgram getSelector:@"isGreaterThan:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateSelect(B->CreateFCmpOGT(a, b), GET_VALID(), nullPtr);
                }];
                break;
            case kTQOperatorMultiply:
                selector = [aProgram getSelector:@"multiply:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateFMul(a, b);
                }];
                break;
            case kTQOperatorDivide:
                selector = [aProgram getSelector:@"divideBy:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateFDiv(a, b);
                }];
                break;
            case kTQOperatorModulo:
                selector = [aProgram getSelector:@"modulo:" inBlock:aBlock root:aRoot];
                break;
            case kTQOperatorAdd:
                selector = [aProgram getSelector:@"add:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateFAdd(a, b);
                }];
                break;
            case kTQOperatorSubtract:
                selector = [aProgram getSelector:@"subtract:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateFSub(a, b);
                }];
                break;
            case kTQOperatorGreaterOrEqual:
                fastpathResultIsNumber = NO;
                selector = [aProgram getSelector:@"isGreaterOrEqualTo:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateSelect(B->CreateFCmpOGE(a, b), GET_VALID(), nullPtr);
                }];
                break;
            case kTQOperatorLesserOrEqual:
                fastpathResultIsNumber = NO;
                selector = [aProgram getSelector:@"isLesserOrEqualTo:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    return B->CreateSelect(B->CreateFCmpOLE(a, b), GET_VALID(), nullPtr);
                }];
                break;
            case kTQOperatorSubscript:
                selector = [aProgram getSelector:@"at:" inBlock:aBlock root:aRoot];
                break;
            case kTQOperatorExponent:
                selector = [aProgram getSelector:@"pow:" inBlock:aBlock root:aRoot];
                fastpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
                    GET_AB();
                    Function *pow = Intrinsic::getDeclaration(p.llModule, Intrinsic::pow, p.llFloatTy);
                    return (Value *)B->CreateCall2(pow, a, b);
                }];
                break;
            default:
                TQAssertSoft(NO, kTQGenericErrorDomain, kTQGenericError, NULL, @"Unknown binary operator");
        }
        TQNodeCustom *slowpath = [TQNodeCustom nodeWithBlock:^(TQProgram *p, TQNodeBlock *aBlock, TQNodeRootBlock *r, NSError **) {
            return (Value *)B->CreateCall3(p.tq_msgSend_noBoxing, left, selector, right);
        }];
        if(fastpath) {
            // If the operator supports a fast path then we must create the necessary branches
            Value *zeroInt = ConstantInt::get(aProgram.llIntPtrTy, 0);
            // if (!a | a isa TaggedNumber) & (!b | b isa TaggedNumber)
            Value *aCond = B->CreateICmpEQ(B->CreateAnd(PtrToInt(left),  numTag), numTag);
            Value *bCond = B->CreateICmpEQ(B->CreateAnd(PtrToInt(right), numTag), numTag);
            Value *cond = B->CreateAnd(aCond, bCond);

            BasicBlock *fastBB  = BasicBlock::Create(aProgram.llModule->getContext(), "opFastpath", aBlock.function);
            BasicBlock *slowBB  = BasicBlock::Create(aProgram.llModule->getContext(), "opSlowpath", aBlock.function);
            BasicBlock *contBB  = BasicBlock::Create(aProgram.llModule->getContext(), "cont", aBlock.function);

            B->CreateCondBr(cond, fastBB, slowBB);

            IRBuilder<> fastBuilder(fastBB);
            aBlock.basicBlock = fastBB;
            aBlock.builder = &fastBuilder;
            Value *fastVal = [fastpath generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];

            Value *resultCheck;
            if(fastpathResultIsNumber) {
#ifdef __LP64__
                resultCheck = B->CreateOr(B->CreateFCmpOGT(fastVal, ConstantFP::get(aProgram.llModule->getContext(), APFloat(1.0f/FLT_EPSILON))),
                                          B->CreateFCmpOLT(fastVal, ConstantFP::get(aProgram.llModule->getContext(), APFloat(-1.0f/FLT_EPSILON))));

                Function *expect = Intrinsic::getDeclaration(aProgram.llModule, Intrinsic::expect, aProgram.llInt1Ty);
                resultCheck = B->CreateCall2(expect, resultCheck, ConstantInt::get(aProgram.llInt1Ty, 0));
#else
                resultCheck = B->CreateCall(aProgram.TQFloatFitsInTaggedNumber, fastVal);
                resultCheck = B->CreateICmpEQ(resultCheck, ConstantInt::get(aProgram.llInt8Ty, 0));
#endif
                fastVal = GET_TQNUM(fastVal);
            }


            IRBuilder<> slowBuilder(slowBB);
            aBlock.basicBlock = slowBB;
            aBlock.builder = &slowBuilder;
            Value *slowVal = [slowpath generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];

            IRBuilder<> *contBuilder = new IRBuilder<>(contBB);
            aBlock.basicBlock = contBB;
            aBlock.builder = contBuilder;

            if(fastpathResultIsNumber)
                fastBuilder.CreateCondBr(resultCheck, slowBB, contBB);
            else
                fastBuilder.CreateBr(contBB);
            slowBuilder.CreateBr(contBB);

            PHINode *phi = contBuilder->CreatePHI(aProgram.llInt8PtrTy, 2);
            phi->addIncoming(fastVal, fastBB);
            phi->addIncoming(slowVal, slowBB);

            return phi;
        } else {
            Value *ret = [slowpath generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
            return ret;
        }
    }
}

- (NSString *)_descriptionFormat
{
    if(_type == kTQOperatorSubscript)
        return @"(%@[%@])";
    else if(_type == kTQOperatorUnaryMinus)
        return @"%@(-%@)";
    else {
        NSString *opStr = nil;
        switch(_type) {
            case kTQOperatorMultiply: opStr = @"*";
            break;
            case kTQOperatorAdd: opStr = @"+";
            break;
            case kTQOperatorSubtract: opStr = @"-";
            break;
            case kTQOperatorDivide: opStr = @"/";
            break;
            case kTQOperatorAnd: opStr = @"&&";
            break;
            case kTQOperatorOr: opStr = @"||";
            break;
            case kTQOperatorLesser: opStr = @"<";
            break;
            case kTQOperatorAssign: opStr = @"=";
            break;
            case kTQOperatorGreater: opStr = @">";
            break;
            case kTQOperatorLesserOrEqual: opStr = @"<=";
            break;
            case kTQOperatorGreaterOrEqual: opStr = @"=>";
            break;
            case kTQOperatorEqual: opStr = @"==";
            break;
            case kTQOperatorInequal: opStr = @"!=";
            break;
            break;
            case kTQOperatorExponent: opStr = @"^";
            break;

            default: opStr = @"<unknown>";
        }
        return [NSString stringWithFormat:@"(%@ %@ %@)", @"%@", opStr, @"%@"];
    }
}
- (NSString *)toString
{
    return [NSString stringWithFormat:[self _descriptionFormat], _left ? [_left toString] : @"", _right ? [_right toString] : @""];
}
- (NSString *)description
{
    return [NSString stringWithFormat:[self _descriptionFormat], _left ? _left : @"", _right ? _right : @""];
}

- (llvm::Value *)store:(llvm::Value *)aValue
             inProgram:(TQProgram *)aProgram
                 block:(TQNodeBlock *)aBlock
                  root:(TQNodeRootBlock *)aRoot
                 error:(NSError **)aoErr
{
    assert(_type == kTQOperatorSubscript);

    // Call []:=:
    Value *selector = [aProgram getSelector:@"set:to:" inBlock:aBlock root:aRoot];
    Value *key = [_right generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
    if(*aoErr)
        return NULL;
    Value *settee = [_left generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
    if(*aoErr)
        return NULL;

    IRBuilder<> *builder = aBlock.builder;
    return builder->CreateCall4(aProgram.objc_msgSend, settee, selector, key, aValue);
}
@end

@implementation TQNodeAssignOperator
//@synthesize left=_left, right=_right, type=_type;

+ (TQNodeAssignOperator *)nodeWithType:(int)aType left:(NSMutableArray *)aLeft right:(NSMutableArray *)aRight
{
    TQNodeAssignOperator *ret = [self new];
    ret.type = aType;
    ret.left = aLeft;
    ret.right = aRight;
    return [ret autorelease];
}

- (id)init
{
    if(!(self = [super init]))
        return nil;

    self.type  = kTQOperatorAssign;
    self.left  = [NSMutableArray array];
    self.right = [NSMutableArray array];

    return self;
}

- (llvm::Value *)generateCodeInProgram:(TQProgram *)aProgram
                                 block:(TQNodeBlock *)aBlock
                                  root:(TQNodeRootBlock *)aRoot
                                 error:(NSError **)aoErr
{
    // We must first evaluate the values in order for cases like a,b = b,a to work
    std::vector<Value*> values;
    Value *curr;
    unsigned valueCount = MIN([self.right count], [self.left count]);
    for(int i = 0; i < valueCount; ++i) {
        if([[self.left objectAtIndex:i] respondsToSelector:@selector(createStorageInProgram:block:root:error:)])
            [[self.left objectAtIndex:i] createStorageInProgram:aProgram block:aBlock root:aRoot error:aoErr];
        curr = [[self.right objectAtIndex:i] generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
        if(*aoErr)
            return NULL;
        if(valueCount > 1)
            curr = aBlock.builder->CreateCall(aProgram.objc_retain, curr);
        values.push_back(curr);
    }

    // Then store the values
    unsigned maxIdx = [self.right count] - 1;
    Value *val;
    for(int i = 0; i < [self.left count]; ++i) {
        val = values[MIN(i, maxIdx)];
        switch(self.type) {
            case kTQOperatorAdd:
            case kTQOperatorSubtract:
            case kTQOperatorMultiply:
            case kTQOperatorOr:
            case kTQOperatorDivide: {
                TQNodeOperator *op = [TQNodeOperator nodeWithType:self.type left:[self.left objectAtIndex:i] right:[TQNodeCustom nodeReturningValue:val]];
                val = [op generateCodeInProgram:aProgram block:aBlock root:aRoot error:aoErr];
                if(*aoErr)
                    return NULL;
            } break;
            case kTQOperatorAssign:
                // Do nothing
            break;
            default:
                TQAssert(NO, @"Unsupported operator type for multi assign");
        }
        [[self.left objectAtIndex:i] store:val
                                 inProgram:aProgram
                                     block:aBlock
                                      root:aRoot
                                     error:aoErr];
    }

    if(valueCount > 1) {
        for(int i = 0; i < values.size(); ++i) {
            aBlock.builder->CreateCall(aProgram.objc_release, values[i]);
        }
    }
    // TODO: Add some way of detecting whether the return value actually gets referenced; and if so return an array containing the right hand sides if n>1
    if(self.type == kTQOperatorAssign && [self.left count] == 1 && [self.right count] == 1)
        return values[0];
    return ConstantPointerNull::get(aProgram.llInt8PtrTy);
}

- (NSString *)description
{
    NSMutableString *str = [NSMutableString stringWithString:@"<multiassgn@"];
    for(TQNode *assignee in self.left) {
        [str appendFormat:@"%@, ", assignee];
    }
    [str appendString:@"= "];
    for(TQNode *value in self.right) {
        [str appendFormat:@"%@, ", value];
    }
    [str appendString:@">"];
    return str;
}

- (TQNode *)referencesNode:(TQNode *)aNode
{
    TQNode *ref = nil;
    if((ref = [self.left tq_referencesNode:aNode]))
        return ref;
    else if((ref = [self.right tq_referencesNode:aNode]))
        return ref;
    return nil;
}

- (void)iterateChildNodes:(TQNodeIteratorBlock)aBlock
{
    for(TQNode *node in [[self.left copy] autorelease]) {
        aBlock(node);
    }
    for(TQNode *node in [[self.right copy] autorelease]) {
        aBlock(node);
    }
}


- (BOOL)replaceChildNodesIdenticalTo:(TQNode *)aNodeToReplace with:(TQNode *)aNodeToInsert
{
    BOOL success = NO;
    for(int i = 0; i < [self.left count]; ++i) {
        if([self.left objectAtIndex:i] == aNodeToReplace) {
            success |= YES;
            [self.left replaceObjectAtIndex:i withObject:aNodeToInsert];
        }
    }
    for(int i = 0; i < [self.right count]; ++i) {
        if([self.right objectAtIndex:i] == aNodeToReplace) {
            success |= YES;
            [self.right replaceObjectAtIndex:i withObject:aNodeToInsert];
        }
    }
    return success;
}
@end
