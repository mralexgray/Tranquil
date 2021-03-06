#import "TQFFIType.h"
#import "TQBoxedObject.h"
#import "../Runtime/TQRuntime.h"

@implementation TQFFIType
+ (ffi_type *)scalarTypeToFFIType:(const char *)aType
{
    switch(*aType) {
        case _C_ID:
        case _C_CLASS:
        case _C_SEL:
        case _C_PTR:
        case _C_CHARPTR:
            return &ffi_type_pointer;
        case _C_DBL:
            return &ffi_type_double;
        case _C_FLT:
            return &ffi_type_float;
        case _C_INT:
            return &ffi_type_sint;
        case _C_SHT:
            return &ffi_type_sshort;
        case _C_CHR:
            return &ffi_type_sint8;
        case _C_BOOL:
            return &ffi_type_uchar;
        case _C_LNG:
            return &ffi_type_slong;
        case _C_LNG_LNG:
            return &ffi_type_sint64;
        case _C_UINT:
            return &ffi_type_uint;
        case _C_USHT:
            return &ffi_type_ushort;
        case _C_UCHR:
            return &ffi_type_uchar;
        case _C_ULNG:
            return &ffi_type_ulong;
        case _C_ULNG_LNG:
            return &ffi_type_uint64;
        case _C_VOID:
            return &ffi_type_void;
        default:
            [NSException raise:NSGenericException
                        format:@"Unsupported scalar type %c!", *aType];
            return NULL;
    }
}

+ (TQFFIType *)typeWithEncoding:(const char *)aEncoding
{
    return [self typeWithEncoding:aEncoding nextType:NULL];
}
+ (TQFFIType *)typeWithEncoding:(const char *)aEncoding nextType:(const char **)aoNextType
{
    return [[[self alloc] initWithEncoding:aEncoding nextType:aoNextType] autorelease];
}

- (id)initWithEncoding:(const char *)aEncoding nextType:(const char **)aoNextType
{
    if(!(self = [super init]))
        return nil;
    _encoding = aEncoding;
    _referencedTypes = nil;

    if(aoNextType) {
        const char *next = TQGetSizeAndAlignment(_encoding, NULL, NULL);
        *aoNextType = next;
    }

    if([TQBoxedObject typeIsScalar:_encoding])
        _ffiType = [TQFFIType scalarTypeToFFIType:_encoding];
    else if(*_encoding == _TQ_C_LAMBDA_B || *_encoding == _C_PTR)
        _ffiType = &ffi_type_pointer;
    else if(*_encoding == _C_STRUCT_B || *_encoding ==_C_ARY_B) {
        BOOL isArray = *_encoding ==_C_ARY_B; // An array is essentially a struct containing fields all with the same type.

        _referencedTypes = [NSMutableArray new];
        ffi_type type;
        _ffiType = (ffi_type*)malloc(sizeof(ffi_type));
        _ffiType->type = FFI_TYPE_STRUCT;
        _ffiType->size = _ffiType->alignment= 0;
        int numFields = 0;
        const char *fieldEncoding;
        if(isArray) {
            ++aEncoding; // Skip past the '['
            assert(isdigit(*aEncoding));
            numFields = atoi(aEncoding);
            // Move on to the enclosed type
            while(isdigit(*aEncoding)) ++aEncoding;
            fieldEncoding = aEncoding;
        } else { // Is struct
            fieldEncoding = strstr(_encoding, "=") + 1;
            if(*fieldEncoding != _C_STRUCT_E) {
                const char *currField = fieldEncoding;
                do {
                    ++numFields;
                } while((currField = TQGetSizeAndAlignment(currField, NULL, NULL)) && *currField != _C_STRUCT_E);
            }
        }
        _ffiType->elements = (ffi_type **)malloc(sizeof(ffi_type*) * numFields + 1);

        if(isArray) {
            TQFFIType *fieldType = [TQFFIType typeWithEncoding:fieldEncoding];
            [_referencedTypes addObject:fieldType];
            for(int i = 0; i < numFields; i++) {
                _ffiType->elements[i] = fieldType.ffiType;
            }
        } else {
            for(int i = 0; i < numFields; i++) {
                TQFFIType *fieldType = [TQFFIType typeWithEncoding:fieldEncoding];
                [_referencedTypes addObject:fieldType];
                _ffiType->elements[i] = fieldType.ffiType;
                fieldEncoding = TQGetSizeAndAlignment(fieldEncoding, NULL, NULL);
            }
        }
        _ffiType->elements[numFields] = NULL;
    } else if(_C_UNION_B) {
        // For unions we just return the ffi type for the first element in the union
        const char *fieldEncoding = strstr(_encoding, "=") + 1;
        return [self initWithEncoding:fieldEncoding nextType:NULL];
    } else {
        // TODO: handle unions by returning a type matching the largest field?
        TQAssert(NO, @"Unhandled encoding: %s", _encoding);
    }
    return self;
}

- (void)dealloc
{
    if(![TQBoxedObject typeIsScalar:_encoding] && _ffiType != &ffi_type_pointer) {
        free(_ffiType->elements);
        free(_ffiType);
    }
    [_referencedTypes release];

    TQ_BATCH_DEALLOC
}

#pragma mark - Batch allocation code
TQ_BATCH_IMPL(TQFFIType)
@end
