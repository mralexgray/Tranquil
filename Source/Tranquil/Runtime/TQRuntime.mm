#import "TQRuntime.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "TQNumber.h"

id TQSentinel = @"3d2c9ac0bf3911e1afa70800200c9a66aaaaaaaaa";

TQValidObject *TQValid;

static const NSString *_TQDynamicIvarTableKey = @"TQDynamicIvarTableKey";

SEL TQEqOpSel;
SEL TQNeqOpSel;
SEL TQLTOpSel;
SEL TQGTOpSel;
SEL TQGTEOpSel;
SEL TQLTEOpSel;
SEL TQMultOpSel;
SEL TQDivOpSel;
SEL TQAddOpSel;
SEL TQSubOpSel;
SEL TQUnaryMinusOpSel;
SEL TQLShiftOpSel;
SEL TQRShiftOpSel;
SEL TQConcatOpSel;
SEL TQSetterOpSel;
SEL TQGetterOpSel;

SEL TQNumberWithDoubleSel;//        = @selector(numberWithDouble:);
SEL TQStringWithUTF8StringSel;
SEL TQPointerArrayWithObjectsSel;
SEL TQMapWithObjectsAndKeysSel;
SEL TQRegexWithPatSel;

Class TQNumberClass;

struct TQBlock_byref {
    void *isa;
    struct TQBlock_byref *forwarding;
    int flags;
    int size;
    void (*byref_keep)(struct TQBlock_byref *dst, struct TQBlock_byref *src);
    void (*byref_destroy)(struct TQBlock_byref *);
    id capture;
};

#pragma mark - Utilities

// Hack from libobjc, allows tail call optimization for objc_msgSend
extern id _objc_msgSend_hack(id, SEL)            asm("_objc_msgSend");
extern id _objc_msgSend_hack2(id, SEL, id)       asm("_objc_msgSend");
extern id _objc_msgSend_hack3(id, SEL, id, id)   asm("_objc_msgSend");
extern id _objc_msgSend_hack2i(id, SEL, int)     asm("_objc_msgSend");
extern id _objc_msgSend_hack3i(id, SEL, id, int) asm("_objc_msgSend");


id TQRetainObject(id obj)
{
    return _objc_msgSend_hack(obj, @selector(retain));
}

void TQReleaseObject(id obj)
{
    _objc_msgSend_hack(obj, @selector(release));
}

id TQAutoreleaseObject(id obj)
{
    return _objc_msgSend_hack(obj, @selector(autorelease));
}

id TQRetainAutoreleaseObject(id obj)
{
    return TQAutoreleaseObject(TQRetainObject(obj));
}

#pragma mark -
Class TQGetOrCreateClass(const char *name, const char *superName)
{
    Class klass = objc_getClass(name);
    if(klass)
        return klass;
    Class superKlass = objc_getClass(superName);
    assert(superKlass != nil);
    klass = objc_allocateClassPair(superKlass, name, 0);
    assert(klass != nil);
    objc_registerClassPair(klass);

    return klass;
}

Class TQObjectGetSuperClass(id aObj)
{
    return class_getSuperclass(object_getClass(aObj));
}


// We either must use these functions to test nil for equality, or use the private _objc_setNilResponder which I don't feel good doing
// For non equality test operators testing against nil is simply always false so we do not need to implement equivalents for them.
id TQObjectsAreEqual(id a, id b)
{
    if(a)
        return _objc_msgSend_hack2(a, TQEqOpSel, b);
    return b == nil ? TQValid : nil;
}

id TQObjectsAreNotEqual(id a, id b)
{
    if(a)
        return _objc_msgSend_hack2(a, TQNeqOpSel, b);
    return b != nil ? TQValid : nil;
}


#pragma mark - Dynamic instance variables

static inline NSMapTable *_TQGetDynamicIvarTable(id obj)
{
    NSMapTable *ivarTable = objc_getAssociatedObject(obj, _TQDynamicIvarTableKey);
    if(!ivarTable) {
        ivarTable = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks, NSObjectMapValueCallBacks, 0);
        objc_setAssociatedObject(obj, _TQDynamicIvarTableKey, ivarTable, OBJC_ASSOCIATION_RETAIN);
    }
    return ivarTable;
}

static inline size_t _accessorNameLen(const char *accessorNameLoc)
{
    const char *accessorNameEnd = strstr(accessorNameLoc, ",");
    if(!accessorNameEnd)
        return strlen(accessorNameLoc);
    else
        return accessorNameEnd - accessorNameLoc;
}

id TQValueForKey(id obj, char *key)
{
    if(!obj)
        return nil;
    objc_property_t property = class_getProperty(object_getClass(obj), key);
    if(property) {
        // TODO: Use the type encoding to box values if necessary
        const char *attrs = property_getAttributes(property);
        char *getterNameLoc = strstr(attrs, ",S");
        if(!getterNameLoc) {
            // Standard getter
            return objc_msgSend(obj, sel_registerName(key));
        } else {
            // Custom getter
            char getterName[_accessorNameLen(getterNameLoc)];
            strcpy(getterName, getterNameLoc);
            return objc_msgSend(obj, sel_registerName(getterName));
        }
    } else {
        NSMapTable *ivarTable = _TQGetDynamicIvarTable(obj);
        return (id)NSMapGet(ivarTable, key);
    }
}

void TQSetValueForKey(id obj, char *key, id value)
{
    if(!obj)
        return;
    objc_property_t property = class_getProperty(object_getClass(obj), key);
    if(property) {
        // TODO: Use the type encoding to unbox values if necessary
        const char *attrs = property_getAttributes(property);
        char *setterNameLoc = strstr(attrs, ",S");
        if(!setterNameLoc) {
            // Standard setter
            size_t setterNameLen = 3 + strlen(key);
            char setterName[setterNameLen];
            strcpy(setterName, "set");
            strcpy(setterName + 3, key);
            objc_msgSend(obj, sel_registerName(setterName), value);
        } else {
            // Custom setter
            char setterName[_accessorNameLen(setterNameLoc)];
            strcpy(setterName, setterNameLoc);
            objc_msgSend(obj, sel_registerName(setterName), value);
        }
    } else {
        NSMapTable *ivarTable = _TQGetDynamicIvarTable(obj);
        if(value)
            NSMapInsert(ivarTable, key, value);
        else
            NSMapRemove(ivarTable, key);
    }
}

#pragma mark -

BOOL TQObjectIsStackBlock(id obj)
{
    return obj != nil && *(void**)obj == _NSConcreteStackBlock;
}

id TQPrepareObjectForReturn(id obj)
{
    if(TQObjectIsStackBlock(obj))
        return _objc_msgSend_hack(obj, @selector(copy));
    return TQRetainObject(obj);
}

NSPointerArray *TQVaargsToArray(va_list *items)
{
    register id arg;
    NSPointerArray *arr = [NSPointerArray pointerArrayWithWeakObjects];
    while((arg = va_arg(*items, id)) != TQSentinel) {
        [arr addPointer:arg];
    }
    return arr;
}

#pragma mark - Operators

BOOL TQAugmentClassWithOperators(Class klass)
{
    // ==
    IMP imp = imp_implementationWithBlock(^(id a, id b) { return [a isEqual:b] ? TQValid : nil; });
    class_addMethod(klass, TQEqOpSel, imp, "@@:@");
    // !=
    imp = imp_implementationWithBlock(^(id a, id b)     { return [a isEqual:b] ? nil : TQValid; });
    class_addMethod(klass, TQNeqOpSel, imp, "@@:@");

    // + (Unimplemented by default)
    imp = imp_implementationWithBlock(^(id a, id b) { return _objc_msgSend_hack2(a, @selector(add:), b); });
    class_addMethod(klass, TQAddOpSel, imp, "@@:@");
    // - (Unimplemented by default)
    imp = imp_implementationWithBlock(^(id a, id b) { return _objc_msgSend_hack2(a, @selector(subtract:), b); });
    class_addMethod(klass, TQSubOpSel, imp, "@@:@");
    // unary - (Unimplemented by default)
    imp = imp_implementationWithBlock(^(id a)       { return _objc_msgSend_hack(a, @selector(negate)); });
    class_addMethod(klass, TQUnaryMinusOpSel, imp, "@@:");

    // * (Unimplemented by default)
    imp = imp_implementationWithBlock(^(id a, id b) { return _objc_msgSend_hack2(a, @selector(multiply:), b); });
    class_addMethod(klass, TQMultOpSel, imp, "@@:@");
    // / (Unimplemented by default)
    imp = imp_implementationWithBlock(^(id a, id b) { return  _objc_msgSend_hack2(a, @selector(divideBy:), b); });
    class_addMethod(klass, TQDivOpSel, imp, "@@:@");

    // <
    imp = imp_implementationWithBlock(^(id a, id b) { return ([a compare:b] == NSOrderedAscending) ? TQValid : nil; });
    class_addMethod(klass, TQLTOpSel, imp, "@@:@");
    // >
    imp = imp_implementationWithBlock(^(id a, id b) { return ([a compare:b] == NSOrderedDescending) ? TQValid : nil; });
    class_addMethod(klass, TQGTOpSel, imp, "@@:@");
    // <=
    imp = imp_implementationWithBlock(^(id a, id b) { return ([a compare:b] != NSOrderedDescending) ? TQValid : nil; });
    class_addMethod(klass, TQLTEOpSel, imp, "@@:@");
    // >=
    imp = imp_implementationWithBlock(^(id a, id b) { return ([a compare:b] != NSOrderedAscending) ? TQValid : nil; });
    class_addMethod(klass, TQGTEOpSel, imp, "@@:@");


    // []
    imp = imp_implementationWithBlock(^(id a, id key)         { return _objc_msgSend_hack2(a, @selector(valueForKey:), key); });
    class_addMethod(klass, TQGetterOpSel, imp, "@@:@");
    // []=
    imp = imp_implementationWithBlock(^(id a, id key, id val) { return _objc_msgSend_hack3(a, @selector(setValue:forKey:), val, key); });
    class_addMethod(klass, TQSetterOpSel, imp, "@@:@@");

    return YES;
}

void TQInitializeRuntime()
{
    TQValid = [TQValidObject sharedInstance];

    TQEqOpSel                    = sel_registerName("==:");
    TQNeqOpSel                   = sel_registerName("!=:");
    TQAddOpSel                   = sel_registerName("+:");
    TQSubOpSel                   = sel_registerName("-:");
    TQUnaryMinusOpSel            = sel_registerName("-");
    TQMultOpSel                  = sel_registerName("*:");
    TQDivOpSel                   = sel_registerName("/:");
    TQLTOpSel                    = sel_registerName("<:");
    TQGTOpSel                    = sel_registerName(">:");
    TQLTEOpSel                   = sel_registerName("<=:");
    TQGTEOpSel                   = sel_registerName(">=:");
    TQLShiftOpSel                = sel_registerName("<<:");
    TQRShiftOpSel                = sel_registerName(">>:");
    TQConcatOpSel                = sel_registerName("..:");
    TQGetterOpSel                = sel_registerName("[]:");
    TQSetterOpSel                = sel_registerName("[]=::");
    
    TQNumberWithDoubleSel        = @selector(numberWithDouble:);
    TQStringWithUTF8StringSel    = @selector(stringWithUTF8String:);
    TQPointerArrayWithObjectsSel = @selector(tq_pointerArrayWithObjects:);
    TQMapWithObjectsAndKeysSel   = @selector(tq_mapTableWithObjectsAndKeys:);
    TQRegexWithPatSel            = @selector(tq_regularExpressionWithUTF8String:options:);

    TQNumberClass     = [TQNumber class];

    TQAugmentClassWithOperators([NSObject class]);

    // Variation of [] for collections
    IMP imp;
    imp = imp_implementationWithBlock(^(id a, id key)         { return _objc_msgSend_hack2(a, @selector(objectForKeyedSubscript:), key); });
    class_addMethod([NSDictionary class], TQGetterOpSel, imp, "@@:@");
    class_addMethod([NSMapTable class], TQGetterOpSel, imp, "@@:@");

    imp = imp_implementationWithBlock(^(id a, TQNumber *idx)   {
        return _objc_msgSend_hack2i(a, @selector(objectAtIndexedSubscript:), (int)[idx value]);
    });
    class_addMethod([NSArray class], TQGetterOpSel, imp, "@@:@");
    class_addMethod([NSPointerArray class], TQGetterOpSel, imp, "@@:@");

    // []=
    imp = imp_implementationWithBlock(^(id a, id key, id val) {
        return _objc_msgSend_hack3(a, @selector(setObject:forKeyedSubscript:), val, key);
    });
    class_addMethod([NSMutableDictionary class], TQSetterOpSel, imp, "@@:@@");
    class_addMethod([NSMapTable class], TQSetterOpSel, imp, "@@:@@");

    imp = imp_implementationWithBlock(^(id a, TQNumber *idx, id val)   {
        return _objc_msgSend_hack3i(a, @selector(setObject:atIndexedSubscript:), val, (int)[idx value]);
    });
    class_addMethod([NSMutableArray class], TQSetterOpSel, imp, "@@:@");
    class_addMethod([NSPointerArray class], TQSetterOpSel, imp, "@@:@");


    // Operators for NS(Mutable)String
    imp = class_getMethodImplementation([NSString class], @selector(stringByAppendingString:));
    class_addMethod([NSString class], TQConcatOpSel, imp, "@@:@");
    imp = class_getMethodImplementation([NSMutableString class], @selector(appendString:));
    imp = imp_implementationWithBlock(^(id a, id b)   {
         _objc_msgSend_hack2(a, @selector(appendString:), b);
         return a;
    });
    class_addMethod([NSMutableString class], TQLShiftOpSel, imp, "@@:@");
    imp = imp_implementationWithBlock(^(id a, id b)   {
        _objc_msgSend_hack3i(a, @selector(insertString:atIndex:), b, 0);
        return a;
    });
    class_addMethod([NSMutableString class], TQRShiftOpSel, imp, "@@:@");


    // Add optimized operators to TQNumber
    // ==
    imp = imp_implementationWithBlock(^(TQNumber *a, TQNumber *b) {
        return object_getClass(a) == object_getClass(b) && a->_value == b->_value ? TQValid : nil;
    });
    class_replaceMethod(TQNumberClass, TQEqOpSel, imp, "@@:@");
    // !=
    imp = imp_implementationWithBlock(^(TQNumber *a, TQNumber *b) {
        if(object_getClass(a) != object_getClass(b))
            return (id)nil;
        return (a->_value != b->_value) ? nil : (id)TQValid;
    });
    class_replaceMethod(TQNumberClass, TQNeqOpSel, imp, "@@:@");

    class_replaceMethod(TQNumberClass, TQAddOpSel,  class_getMethodImplementation(TQNumberClass, @selector(add:)),             "@@:@");
    class_replaceMethod(TQNumberClass, TQSubOpSel,  class_getMethodImplementation(TQNumberClass, @selector(subtract:)),        "@@:@");
    class_replaceMethod(TQNumberClass, TQUnaryMinusOpSel, class_getMethodImplementation(TQNumberClass, @selector(negate)),     "@@:" );
    class_replaceMethod(TQNumberClass, TQMultOpSel, class_getMethodImplementation(TQNumberClass, @selector(multiply:)),        "@@:@");
    class_replaceMethod(TQNumberClass, TQDivOpSel,  class_getMethodImplementation(TQNumberClass, @selector(divideBy:)),        "@@:@");

    class_replaceMethod(TQNumberClass, TQLTOpSel,  class_getMethodImplementation(TQNumberClass, @selector(isLesser:)),         "@@:@");
    class_replaceMethod(TQNumberClass, TQGTOpSel,  class_getMethodImplementation(TQNumberClass, @selector(isGreater:)),        "@@:@");
    class_replaceMethod(TQNumberClass, TQLTEOpSel, class_getMethodImplementation(TQNumberClass, @selector(isLesserOrEqual:)),  "@@:@");
    class_replaceMethod(TQNumberClass, TQGTEOpSel, class_getMethodImplementation(TQNumberClass, @selector(isGreaterOrEqual:)), "@@:@");

}
