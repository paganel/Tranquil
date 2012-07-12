#import "TQBoxedObject.h"
#import "bs.h"
#import "TQFFIType.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <ffi/ffi.h>

#define TQBoxedObject_PREFIX "TQBoxedObject_"
#define BlockImp imp_implementationWithBlock

static int _TQRetTypeAssocKey, _TQArgTypesAssocKey;

// Used to wrap blocks that take or return non-objects
struct TQBoxedBlockLiteral;
struct TQBoxedBlockDescriptor {
    unsigned long int reserved; // NULL
    unsigned long int size;     // sizeof(struct TQBoxedBlockLiteral)
};
struct TQBoxedBlockLiteral {
    void *isa; // _NSConcreteStackBlock
    int flags;
    int reserved;
    void *invoke;
    struct TQBoxedBlockDescriptor *descriptor;
    // The required data to call the boxed function
    void *funPtr;
    const char *type;
    NSInteger argSize;
    ffi_cif *cif;
};

static id __wrapperBlock_invoke(struct TQBoxedBlockLiteral *__blk, ...);

static struct TQBoxedBlockDescriptor boxedBlockDescriptor = {
    0,
    sizeof(struct TQBoxedBlockLiteral),
};

@interface TQBoxedObject ()
+ (NSString *)_classNameForType:(const char *)aType;
+ (Class)_prepareAggregate:(const char *)aClassName withType:(const char *)aType;
+ (Class)_prepareScalar:(const char *)aClassName withType:(const char *)aType;
+ (NSString *)_getFieldName:(const char **)aType;
+ (const char *)_findEndOfPair:(const char *)aStr start:(char)aStartChar end:(char)aEndChar;
@end

@implementation TQBoxedObject
@synthesize valuePtr=_ptr;

+ (id)box:(void *)aPtr withType:(const char *)aType
{
    // Check if this type has been handled already
    const char *className = [[self _classNameForType:aType] UTF8String];
    Class boxingClass = objc_getClass(className);
    if(boxingClass)
        return [boxingClass box:aPtr];

    // Seems it hasn't. Let's.
    if([self typeIsScalar:aType])
        boxingClass = [self _prepareScalar:className withType:aType];
    else if(*aType == _C_STRUCT_B || *aType == _C_UNION_B)
        boxingClass = [self _prepareAggregate:className withType:aType];
    else if(*aType == _MR_C_LAMBDA_B)
        boxingClass = [self _prepareLambda:className withType:aType];
    else
        return nil;
    objc_registerClassPair(boxingClass);

    return [boxingClass box:aPtr];
}

+ (id)box:(void *)aPtr
{
    return [[[self allocWithZone:NULL] initWithPtr:aPtr] autorelease];
}

+ (void)unbox:(id)aValue to:(void *)aDest usingType:(const char *)aType
{
    switch(*aType) {
        case _C_ID:
        case _C_CLASS:
            *(id*)aDest                  = aValue;
        break;
        case _C_SEL:
            *(SEL*)aDest                 = NSSelectorFromString(aValue);
        break;
        case _C_CHARPTR:
            *(const char **)aDest        = [(NSString *)aValue UTF8String];
        break;
        case _C_DBL:
            *(double *)aDest             = [(NSNumber *)aValue doubleValue];
        break;
        case _C_FLT:
            *(float *)aDest              = [(NSNumber *)aValue floatValue];
        break;
        case _C_INT:
            *(int *)aDest                = [(NSNumber *)aValue intValue];
        break;
        case _C_SHT:
            *(short *)aDest              = [(NSNumber *)aValue shortValue];
        break;
        case _C_BOOL:
            *(BOOL *)aDest               = [(NSNumber *)aValue boolValue];
        break;
        case _C_LNG:
            *(long *)aDest               = [(NSNumber *)aValue longValue];
        break;
        case _C_LNG_LNG:
            *(long long *)aDest          = [(NSNumber *)aValue longLongValue];
        break;
        case _C_UINT:
            *(unsigned int *)aDest       = [(NSNumber *)aValue unsignedIntValue];
        break;
        case _C_USHT:
            *(unsigned short *)aDest     = [(NSNumber *)aValue unsignedShortValue];
        break;
        case _C_ULNG:
            *(unsigned long *)aDest      = [(NSNumber *)aValue unsignedLongValue];
        break;
        case _C_ULNG_LNG:
            *(unsigned long long *)aDest = [(NSNumber *)aValue unsignedLongLongValue];
        break;
        case _C_STRUCT_B:
        case _C_UNION_B:
        case _MR_C_LAMBDA_B: {
            assert([aValue isKindOfClass:self]);
            NSUInteger size;
            NSGetSizeAndAlignment(aType, &size, NULL);

            TQBoxedObject *value = aValue;
            assert(value->_size == size);
            memmove(aDest, value->_ptr, size);
        } break;
        default:
            NSLog(@"Tried to unbox unsupported type %c!", *aType);
            return;
    }
}

- (id)initWithPtr:(void *)aPtr
{
    [NSException raise:@"Invalid Receiver" format:@"TQBoxedObject is an abstract class. Do not try to instantiate it directly."];
    // Implemented by subclasses
    return nil;
}

- (void)dealloc
{
    if(_isOnHeap)
        free(_ptr);
    [super dealloc];
}
- (void)_moveValueToHeap
{
    void *stackAddr = _ptr;
    _ptr = malloc(_size);
    memmove(_ptr, stackAddr, _size);
    _isOnHeap = YES;
}

- (id)retain
{
    id ret = [super retain];
    [self _moveValueToHeap];
    return ret;
}

#pragma mark -

+ (NSString *)_getFieldName:(const char **)aType
{
    if(*(*aType) != '"')
        return NULL;
    *aType = *aType + 1;
    const char *nameEnd = strstr(*aType, "\"");
    int len = nameEnd - *aType;

    NSString *ret = [[NSString alloc] initWithBytes:*aType length:len encoding:NSUTF8StringEncoding];
    (*aType) += len+1;
    return [ret autorelease];
}

+ (BOOL)typeIsScalar:(const char *)aType
{
    return !(*aType == _C_STRUCT_B || *aType == _C_UNION_B || *aType == _C_ARY_B || *aType == _MR_C_LAMBDA_B || *aType == _C_PTR);
}

+ (const char *)_findEndOfPair:(const char *)aStr start:(char)aStartChar end:(char)aEndChar
{
    for(int i = 0, depth = 0; i < strlen(aStr); ++i) {
        if(aStr[i] == aStartChar)
            ++depth;
        else if(aStr[i] == aEndChar) {
            if(--depth == 0)
                return aStr+i;
        }
    }
    return NULL;
}

+ (NSString *)_classNameForType:(const char *)aType
{
    NSUInteger len;
    if(*aType == _C_STRUCT_B)
        len = [self _findEndOfPair:aType start:_C_STRUCT_B end:_C_STRUCT_E] - aType + 1;
    else if(*aType == _C_UNION_B)
        len = [self _findEndOfPair:aType start:_C_UNION_B end:_C_UNION_E] - aType + 1;
    else if(*aType == _MR_C_LAMBDA_B)
        len = [self _findEndOfPair:aType start:_MR_C_LAMBDA_B end:_MR_C_LAMBDA_E] - aType + 1;
    else if(*aType == _C_PTR) {
        const char *nextType = NSGetSizeAndAlignment(aType, NULL, NULL);
        len = nextType - aType;
    } else
        len = 1;

    len += strlen(TQBoxedObject_PREFIX) + 1;
    char className[len+1];
    snprintf(className, len, "%s%s", TQBoxedObject_PREFIX, aType);

    return [NSString stringWithUTF8String:className];
}

+ (Class)_prepareScalar:(const char *)aClassName withType:(const char *)aType
{
    NSUInteger size, alignment;
    NSGetSizeAndAlignment(aType, &size, &alignment);

    IMP initImp      = nil;
    Class superClass = self;
    switch(*aType) {
        case _C_ID:
        case _C_CLASS:
            initImp = BlockImp(^(TQBoxedObject *self, id *aPtr)                 { return *aPtr; });
        break;
        case _C_SEL:
            initImp = BlockImp(^(TQBoxedObject *self, SEL *aPtr)                { return NSStringFromSelector(*aPtr); });
        break;
        case _C_CHARPTR:
            initImp = BlockImp(^(TQBoxedObject *self, const char *aPtr)         { return @(*aPtr); });
        break;
        case _C_DBL:
            initImp = BlockImp(^(TQBoxedObject *self, double *aPtr)             { return @(*aPtr); });
        break;
        case _C_FLT:
            initImp = BlockImp(^(TQBoxedObject *self, float *aPtr)              { return @(*aPtr); });
        break;
        case _C_INT:
            initImp = BlockImp(^(TQBoxedObject *self, int *aPtr)                { return @(*aPtr); });
        break;
        case _C_SHT:
            initImp = BlockImp(^(TQBoxedObject *self, short *aPtr)              { return @(*aPtr); });
        break;
        case _C_BOOL:
            initImp = BlockImp(^(TQBoxedObject *self, _Bool *aPtr)              { return @(*aPtr); });
        break;
        case _C_LNG:
            initImp = BlockImp(^(TQBoxedObject *self, long *aPtr)               { return @(*aPtr); });
        break;
        case _C_LNG_LNG:
            initImp = BlockImp(^(TQBoxedObject *self, long long *aPtr)          { return @(*aPtr); });
        break;
        case _C_UINT:
            initImp = BlockImp(^(TQBoxedObject *self, unsigned int *aPtr)       { return @(*aPtr); });
        break;
        case _C_USHT:
            initImp = BlockImp(^(TQBoxedObject *self, unsigned short *aPtr)     { return @(*aPtr); });
        break;
        case _C_ULNG:
            initImp = BlockImp(^(TQBoxedObject *self, unsigned long *aPtr)      { return @(*aPtr); });
        break;
        case _C_ULNG_LNG:
            initImp = BlockImp(^(TQBoxedObject *self, unsigned long long *aPtr) { return @(*aPtr); });
        break;

        default:
            NSLog(@"Unsupported scalar type %c!", *aType);
            return nil;
    }

    Class kls = objc_allocateClassPair(superClass, aClassName, 0);
    class_addMethod(kls->isa, @selector(box:), initImp, "@:*");

    return kls;
}

// Handles unions&structs
+ (Class)_prepareAggregate:(const char *)aClassName withType:(const char *)aType
{
    BOOL isStruct = *aType == _C_STRUCT_B;
    Class kls = objc_allocateClassPair(self, aClassName, 0);

    NSUInteger size, alignment;
    NSGetSizeAndAlignment(aType, &size, &alignment);

    // Store the accessors sequentially in order to allow indexed access (necessary for structs without field name information)
    NSMutableArray *fieldGetters = [NSMutableArray array];
    NSMutableArray *fieldSetters = [NSMutableArray array];

    id fieldGetter, fieldSetter;
    NSUInteger fieldSize, fieldOffset;
    const char *nextType;
    const char *fieldType = strstr(aType, "=")+1;

    // Add properties for each field
    fieldOffset = 0;
    while((nextType = NSGetSizeAndAlignment(fieldType, &fieldSize, NULL))) {
        NSString *name = [self _getFieldName:&fieldType];
        fieldGetter = [[^(TQBoxedObject *self) {
            return [TQBoxedObject box:(char*)self->_ptr+fieldOffset withType:fieldType];
        } copy] autorelease];
        fieldSetter = [[^(TQBoxedObject *self, id value) {
            [TQBoxedObject unbox:value to:(char*)self->_ptr+fieldOffset usingType:fieldType];
        } copy] autorelease];

        if(name) {
            class_addMethod(kls, NSSelectorFromString(name), BlockImp(fieldGetter), "@:");
            class_addMethod(kls, NSSelectorFromString([NSString stringWithFormat:@"set%@:", [name capitalizedString]]), BlockImp(fieldSetter), "@:");
        }
        [fieldGetters addObject:fieldGetter];
        [fieldSetters addObject:fieldSetter];

        if((isStruct && *nextType == _C_STRUCT_E) || (!isStruct && *nextType == _C_UNION_E))
            break;
        // If it's a union, the offset is always 0
        if(isStruct)
            fieldOffset += fieldSize;
        fieldType = nextType;
    }

    // Persistent immutable copies shared amongst instances
    fieldGetters = [fieldGetters copy];
    fieldSetters = [fieldSetters copy];
    IMP subscriptGetterImp = BlockImp(^(id self, NSInteger idx) {
        id (^getter)(id) = [fieldGetters objectAtIndex:idx];
        return getter(self);
    });
    const char *subscrGetterType = [[NSString stringWithFormat:@"@:%s", @encode(NSInteger)] UTF8String];
    class_replaceMethod(kls, @selector(objectAtIndexedSubscript:), subscriptGetterImp, subscrGetterType);
    IMP subscriptSetterImp = BlockImp(^(id self, id value, NSInteger idx) {
        id (^setter)(id, id) = [fieldSetters objectAtIndex:idx];
        return setter(self, value);
    });
    const char *subscrSetterType = [[NSString stringWithFormat:@"@:@%s", @encode(NSInteger)] UTF8String];
    class_replaceMethod(kls, @selector(setObject:atIndexedSubscript:), subscriptSetterImp, subscrSetterType);

    IMP initImp = BlockImp(^(TQBoxedObject *self, void *aPtr) {
        self->_ptr  = aPtr;
        self->_size = size;
        return self;
    });
    class_addMethod(kls, @selector(initWithPtr:), initImp, "@:*");

    return kls;
}

// Handles blocks&function pointers
+ (Class)_prepareLambda:(const char *)aClassName withType:(const char *)aType
{
    BOOL isBlock = *(++aType) == _MR_C_LAMBDA_BLOCK;

    BOOL needsWrapping = NO;
    // If the value is a funptr, the return value or any argument is not an object, then the block needs to be wrapped up
    for(int i = 0; i < strlen(aType)-1; ++i) {
        if(aType[i] != _C_ID) {
            needsWrapping = YES;
            break;
        }
    }

    Class kls = objc_allocateClassPair(self, aClassName, 0);

    IMP initImp;
    if(!needsWrapping) {
        initImp = BlockImp(^(TQBoxedObject *self, id *aPtr) { return *aPtr; });
    } else {
        const char *argTypes;
        // Figure out the return type
        TQFFIType *retType = [TQFFIType typeWithEncoding:aType+1 nextType:&argTypes];

        // And now the argument types
        NSUInteger numArgs = isBlock;
        if(*argTypes != _MR_C_LAMBDA_E) {
            const char *currArg = argTypes;
            ++numArgs;
            while((currArg = NSGetSizeAndAlignment(currArg, NULL, NULL)) && *currArg != '>')
                ++numArgs;
        }

        // These two "leak". TODO: figure out how to deallocate these if the class is disposed of (Maybe allocate in the extraBytes?)
        ffi_cif *cif = (ffi_cif*)malloc(sizeof(ffi_cif));
        ffi_type **args = (ffi_type**)malloc(sizeof(ffi_type*)*numArgs);
        NSMutableArray *argTypeObjects = [NSMutableArray arrayWithCapacity:numArgs];
        NSUInteger argSize;
        argSize = 0;

        int argIdx = 0;
        if(isBlock) {
            args[argIdx++] = &ffi_type_pointer;
            argSize += sizeof(void*);
        }

        TQFFIType *currTypeObj;
        for(int i = isBlock; i < numArgs; ++i) {
            currTypeObj = [TQFFIType typeWithEncoding:argTypes nextType:&argTypes];
            argSize += [currTypeObj size];
            args[argIdx++] = [currTypeObj ffiType];

            [argTypeObjects addObject:currTypeObj];
        }

        if(ffi_prep_cif(cif, FFI_DEFAULT_ABI, numArgs, retType.ffiType, args) != FFI_OK) {
            // TODO: be more graceful
            NSLog(@"unable to wrap block");
            exit(1);
        }

        initImp = BlockImp(^(TQBoxedObject *self, id *aPtr) {
            // Hold on to these guys:
            objc_setAssociatedObject(self, &_TQRetTypeAssocKey, retType, OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(self, &_TQArgTypesAssocKey, argTypeObjects, OBJC_ASSOCIATION_RETAIN);

            // Create and return the wrapper block
            struct TQBoxedBlockLiteral blk = {
                &_NSConcreteStackBlock,
                0, 0,
                (void*)&__wrapperBlock_invoke,
                &boxedBlockDescriptor,
                isBlock ? (id)*aPtr : (id)aPtr,
                aType,
                argSize,
                cif
            };
            return [[(id)&blk copy] autorelease];
        });
    }
    class_addMethod(kls, @selector(initWithPtr:), initImp, "@:^v");

    return kls;
}

- (id)objectAtIndexedSubscript:(NSInteger)aIdx
{
    return nil;
}
- (void)setObject:(id)aValue atIndexedSubscript:(NSInteger)aIdx
{
    // Implemented by subclasses
}
@end

// Block that takes a variable number of objects and calls the original function pointer using their unboxed values
id __wrapperBlock_invoke(struct TQBoxedBlockLiteral *__blk, ...)
{
    const char *type = __blk->type;
    void *funPtr = __blk->funPtr;
    BOOL isBlock = *(type++) == _C_ID;
    if(isBlock)
        funPtr = ((struct TQBoxedBlockLiteral *)funPtr)->invoke;

    void *ffiRet = alloca(__blk->cif->rtype->size);
    const char *retType = type;

    va_list argList;
    va_start(argList, __blk);

    const char *currType, *nextType;
    currType = NSGetSizeAndAlignment(retType, NULL, NULL);
    void *ffiArgs       = alloca(__blk->argSize);
    void **ffiArgValues = (void**)alloca(sizeof(void*) * __blk->cif->nargs);
    if(isBlock)
        ffiArgValues[0] = __blk->funPtr;

    id arg;
    for(int i = isBlock, ofs = 0; i < __blk->cif->nargs; ++i) {
        arg = va_arg(argList, id);
        [TQBoxedObject unbox:arg to:(char*)ffiArgs+ofs usingType:currType];
        ffiArgValues[i] = (char*)ffiArgs+ofs;

        ofs += __blk->cif->arg_types[i]->size;
        currType = NSGetSizeAndAlignment(currType, NULL, NULL);
    }
    va_end(argList);
    ffi_call(__blk->cif, FFI_FN(funPtr), ffiRet, ffiArgValues);

    // retain/autorelease to move the pointer onto the heap
    return [[[TQBoxedObject box:ffiRet withType:retType] retain] autorelease];
}
