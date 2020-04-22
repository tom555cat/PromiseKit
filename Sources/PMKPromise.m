#import <assert.h>
#import <dispatch/dispatch.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSError.h>
#import <Foundation/NSException.h>
#import <Foundation/NSKeyValueCoding.h>
#import <Foundation/NSMethodSignature.h>
#import <Foundation/NSOperation.h>
#import <Foundation/NSPointerArray.h>
#import <objc/runtime.h>
#import "Private/NSMethodSignatureForBlock.m"
#import <PromiseKit/Promise.h>
#import <string.h>

#define IsPromise(o) ([o isKindOfClass:[PMKPromise class]])
#define IsError(o) ([o isKindOfClass:[NSError class]])
#define PMKE(txt) [NSException exceptionWithName:@"PromiseKit" reason:@"PromiseKit: " txt userInfo:nil]

#ifndef PMKLog
#define PMKLog NSLog
#endif

static const id PMKNull = @"PMKNull";



@interface PMKArray : NSObject
- (id)objectAtIndexedSubscript:(NSUInteger)idx;
@end



static inline NSError *NSErrorFromNil() {
    PMKLog(@"PromiseKit: Warning: Promise rejected with nil");
    return [NSError errorWithDomain:PMKErrorDomain code:PMKInvalidUsageError userInfo:nil];
}

static inline NSError *NSErrorFromException(id exception) {
    if (!exception)
        return NSErrorFromNil();

    id userInfo = @{
        PMKUnderlyingExceptionKey: exception,
        NSLocalizedDescriptionKey: [exception isKindOfClass:[NSException class]]
            ? [exception reason]
            : [exception description]
    };
    return [NSError errorWithDomain:PMKErrorDomain code:PMKUnhandledExceptionError userInfo:userInfo];
}



@interface PMKError : NSObject @end @implementation PMKError {
    NSError *error;
    BOOL consumed;
}

static void *PMKErrorAssociatedObject = &PMKErrorAssociatedObject;

- (void)dealloc {
    if (!consumed && PMKUnhandledErrorHandler)
        PMKUnhandledErrorHandler(error);
}

+ (void)consume:(NSError *)error {
    PMKError *pmke = objc_getAssociatedObject(error, PMKErrorAssociatedObject);
    pmke->consumed = YES;    
}

+ (void)unconsume:(NSError *)error {
    PMKError *pmke = objc_getAssociatedObject(error, PMKErrorAssociatedObject);

    if (!pmke) {
        pmke = [PMKError new];

        // we take a copy to avoid a retain cycle. A weak ref
        // is no good because then the error is deallocated
        // before we can call PMKUnhandledErrorHandler()
        pmke->error = [error copy];

        // this is how we know when the error is deallocated
        // because we will be deallocated at the same time
        objc_setAssociatedObject(error, PMKErrorAssociatedObject, pmke, OBJC_ASSOCIATION_RETAIN_NONATOMIC);        
    }
    else
        pmke->consumed = NO;
}

@end

void (^PMKUnhandledErrorHandler)(id) = ^(NSError *error){
    PMKLog(@"PromiseKit: Unhandled error: %@", error);
};



// deprecated
NSString const*const PMKThrown = PMKUnderlyingExceptionKey;



/**
 `then` and `catch` are method-signature tolerant, this function calls
 the block correctly and normalizes the return value to `id`.
 */
id pmk_safely_call_block(id frock, id result) {
    assert(frock);

    if (result == PMKNull)
        result = nil;

    @try {
        NSMethodSignature *sig = NSMethodSignatureForBlock(frock);
        const NSUInteger nargs = sig.numberOfArguments;
        const char rtype = sig.methodReturnType[0];

        #define call_block_with_rtype(type) ({^type{ \
            switch (nargs) { \
                case 1: \
                    return ((type(^)(void))frock)(); \
                case 2: { \
                    const id arg = [result class] == [PMKArray class] ? ((PMKArray *)result)[0] : result; \
                    return ((type(^)(id))frock)(arg); \
                } \
                case 3: { \
                    type (^block)(id, id) = frock; \
                    return [result class] == [PMKArray class] \
                        ? block(((PMKArray *)result)[0], ((PMKArray *)result)[1]) \
                        : block(result, nil); \
                } \
                case 4: { \
                    type (^block)(id, id, id) = frock; \
                    return [result class] == [PMKArray class] \
                        ? block(((PMKArray *)result)[0], ((PMKArray *)result)[1], ((PMKArray *)result)[2]) \
                        : block(result, nil, nil); \
                } \
                default: \
                    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"PromiseKit: The provided block’s argument count is unsupported." userInfo:nil]; \
            }}();})

        switch (rtype) {
            case 'v':
                call_block_with_rtype(void);
                return PMKNull;
            case '@':
                return call_block_with_rtype(id) ?: PMKNull;
            case '*': {
                char *str = call_block_with_rtype(char *);
                return str ? @(str) : PMKNull;
            }
            case 'c': return @(call_block_with_rtype(char));
            case 'i': return @(call_block_with_rtype(int));
            case 's': return @(call_block_with_rtype(short));
            case 'l': return @(call_block_with_rtype(long));
            case 'q': return @(call_block_with_rtype(long long));
            case 'C': return @(call_block_with_rtype(unsigned char));
            case 'I': return @(call_block_with_rtype(unsigned int));
            case 'S': return @(call_block_with_rtype(unsigned short));
            case 'L': return @(call_block_with_rtype(unsigned long));
            case 'Q': return @(call_block_with_rtype(unsigned long long));
            case 'f': return @(call_block_with_rtype(float));
            case 'd': return @(call_block_with_rtype(double));
            case 'B': return @(call_block_with_rtype(_Bool));
            case '^':
                if (strcmp(sig.methodReturnType, "^v") == 0) {
                    call_block_with_rtype(void);
                    return PMKNull;
                }
                // else fall through!
            default:
                @throw PMKE(@"Unsupported method signature… Why not fork and fix?");
        }
    } @catch (id e) {
      #ifdef PMK_RETHROW_LIKE_A_MOFO
        if ([e isKindOfClass:[NSException class]] && (
            [e name] == NSGenericException ||
            [e name] == NSRangeException ||
            [e name] == NSInvalidArgumentException ||
            [e name] == NSInternalInconsistencyException ||
            [e name] == NSObjectInaccessibleException ||
            [e name] == NSObjectNotAvailableException ||
            [e name] == NSDestinationInvalidException ||
            [e name] == NSPortTimeoutException ||
            [e name] == NSInvalidSendPortException ||
            [e name] == NSInvalidReceivePortException ||
            [e name] == NSPortSendException ||
            [e name] == NSPortReceiveException))
                @throw e;
      #endif
        return NSErrorFromException(e);
    }
}



@implementation PMKPromise {
/**
 We have public @implementation instance variables so PMKResolve()
 can fulfill promises. Our usage is like the C++ `friend` keyword.
 */
@public
	dispatch_queue_t _promiseQueue;
    NSMutableArray *_handlers;
    id _result;
}

- (instancetype)init {
    @throw PMKE(@"init is not a valid initializer for PMKPromise");
    return nil;
}

#if OS_OBJECT_USE_OBJC == 0
- (void)dealloc {
    dispatch_release(_promiseQueue);
}
#endif

- (PMKPromise *(^)(id))then {
    return ^(id block){
        return self.thenOn(dispatch_get_main_queue(), block);
    };
}

- (PMKPromise *(^)(id))thenInBackground {
    return ^(id block){
        return self.thenOn(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
    };
}

- (PMKPromise *(^)(id))catch {
    return ^(id block){
        return self.catchOn(dispatch_get_main_queue(), block);
    };
}

- (PMKPromise *(^)(dispatch_block_t))finally {
    return ^(dispatch_block_t block) {
        return self.finallyOn(dispatch_get_main_queue(), block);
    };
}

typedef PMKPromise *(^PMKResolveOnQueueBlock)(dispatch_queue_t, id block);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wimplicit-retain-self"

// Convoluted helper method that returns a block that is called
// from a thenOn/catchOn/finallyOn. It returns a block that when
// executed calls the user’s block with our result. The method
// takes two blocks that allow the callee to alter the behavior
// when calling the user’s block. The first for the already-
// resolved state, the second for the pending state.

- (id)resolved:(PMKResolveOnQueueBlock(^)(id result))mkresolvedCallback
       pending:(void(^)(id result, PMKPromise *next, dispatch_queue_t q, id block, void (^resolver)(id)))mkpendingCallback
{
    __block PMKResolveOnQueueBlock callBlock;
    __block id result;
    
    dispatch_sync(_promiseQueue, ^{
        // 如果_result有值了，那么就是resolved状态了，那就无需再创建callBlock了。
        if ((result = _result))
            return;

        // 这里就是self.thenOn(dispatch_get_main_queue(), block)传递进来的两个参数。
        callBlock = ^(dispatch_queue_t q, id block) {

            // HACK we seem to expose some bug in ARC where this block can
            // be an NSStackBlock which then gets deallocated by the time
            // we get around to using it. So we force it to be malloc'd.
            block = [block copy];

            __block PMKPromise *next = nil;

            // 执行then提供的回调函数，是在_promiseQueue中通过dispatch_barrier_sync调用的。
            dispatch_barrier_sync(_promiseQueue, ^{
                if ((result = _result))
                    return;

                __block PMKPromiseFulfiller resolver;
                
                /// 这里对应着JS Promise的then创建Promise的调用第一个Promise的handle函数。
                
                // 这里then返回的promise，
                // 其实fuifiller中也包着resolve，所以new方法和promiseWithResolver类似。
                // Promise.new传入的fn在执行时传入的fulfill带入的是自己Promise的resolve。
                next = [PMKPromise new:^(PMKPromiseFulfiller fulfill, PMKPromiseRejecter reject) {
                    
                    // 将next自己的resolve暴露出来，而最内层调用resolve的方式是resolve(this, result)
                    resolver = ^(id o){
                        if (IsError(o)) reject(o); else fulfill(o);
                    };
                }];
                // 将then传入的回调保存进_handlers中，
                // 这里的resolver是next这个promise的resolver。
                [_handlers addObject:^(id value){
                    mkpendingCallback(value, next, q, block, resolver);
                }];
            });
            
            // next can still be `nil` if the promise was resolved after
            // 1) `-thenOn` read it and decided which block to return; and
            // 2) the call to the block.

            return next ?: mkresolvedCallback(result)(q, block);
        };
    });

    // We could just always return the above block, but then every caller would
    // trigger a barrier_sync on the promise queue. Instead, if we know that the
    // promise is resolved (since that makes it immutable), we can return a simpler
    // block that doesn't use a barrier in those cases.

    // if ((result = _result)) return; 会直接进入这里，而此时callBlock不存在，直接调用resolved回调。
    return callBlock ?: mkresolvedCallback(result);
}

#pragma clang diagnostic pop

// thenOn(queue, block)的执行流程就是执行原始Promise的handler过程。
- (PMKResolveOnQueueBlock)thenOn {
    // 1.如果是resolved的状态，应该执行用户提供的block，
    // 然后再调用then_promise(也就是PMKPromise *next)的resolve方法。
    // 2.如果是pending状态，
    // 应该将用户提供的handler(包括block和then_promise的resolve)保存进原始Promise的handler中。
    return [self resolved:^(id result) {
        if (IsPromise(result))
            return ((PMKPromise *)result).thenOn;

        if (IsError(result)) return ^(dispatch_queue_t q, id block) {
            return [PMKPromise promiseWithValue:result];
        };
        
        // 直接在用户提供的q上执行then提供的block
        return ^(dispatch_queue_t q, id block) {

            // HACK we seem to expose some bug in ARC where this block can
            // be an NSStackBlock which then gets deallocated by the time
            // we get around to using it. So we force it to be malloc'd.
            block = [block copy];

            // 在resolved状态的promise上执行then，也要创建promise_then
            return dispatch_promise_on(q, ^{
                return pmk_safely_call_block(block, result);
            });
        };
    }
    pending:^(id result, PMKPromise *next, dispatch_queue_t q, id block, void (^resolve)(id)) {
        // 这个pending block参数,next就是promise_then创建的promise，resolve是promise_then自己的resolve;
        // resolver = ^(id o){
        //      if (IsError(o)) reject(o); else fulfill(o);
        // };
        if (IsError(result))
            PMKResolve(next, result);
        else dispatch_async(q, ^{
            id blockReturn = pmk_safely_call_block(block, result);
            resolve(blockReturn);
        });
    }];
}

- (PMKResolveOnQueueBlock)catchOn {
    return [self resolved:^(id result) {
        if (IsPromise(result))
            return ((PMKPromise *)result).catchOn;
        
        if (IsError(result)) return ^(dispatch_queue_t q, id block) {

            // HACK we seem to expose some bug in ARC where this block can
            // be an NSStackBlock which then gets deallocated by the time
            // we get around to using it. So we force it to be malloc'd.
            block = [block copy];

            return dispatch_promise_on(q, ^{
                [PMKError consume:result];
                return pmk_safely_call_block(block, result);
            });
        };
        
        return ^(dispatch_queue_t q, id block) {
            return [PMKPromise promiseWithValue:result];
        };
    }
    pending:^(id result, PMKPromise *next, dispatch_queue_t q, id block, void (^resolve)(id)) {
        if (IsError(result)) {
            dispatch_async(q, ^{
                [PMKError consume:result];
                resolve(pmk_safely_call_block(block, result));
            });
        } else
            PMKResolve(next, result);
    }];
}

- (PMKPromise *(^)(dispatch_queue_t, dispatch_block_t))finallyOn {
    return [self resolved:^(id passthru) {
        if (IsPromise(passthru))
            return ((PMKPromise *)passthru).finallyOn;

        return ^(dispatch_queue_t q, dispatch_block_t block) {

            // HACK we seem to expose some bug in ARC where this block can
            // be an NSStackBlock which then gets deallocated by the time
            // we get around to using it. So we force it to be malloc'd.
            block = [block copy];

            return dispatch_promise_on(q, ^{
                block();
                return passthru;
            });
        };
    } pending:^(id passthru, PMKPromise *next, dispatch_queue_t q, dispatch_block_t block, void (^resolve)(id)) {
        dispatch_async(q, ^{
            @try {
                block();
                resolve(passthru);
            } @catch (id e) {
                resolve(NSErrorFromException(e));
            }
        });
    }];
}

- (instancetype)then:(id (^)(id))onFulfilled :(id (^)(id))onRejected {
    return self.then(onFulfilled).catch(onRejected);
}

+ (PMKPromise *)promiseWithValue:(id)value {
    PMKPromise *p = [PMKPromise alloc];
    p->_promiseQueue = PMKCreatePromiseQueue();
    p->_result = PMKSanitizeResult(value);
    return p;
}

static dispatch_queue_t PMKCreatePromiseQueue() {
    return dispatch_queue_create("org.promiseKit.Q", DISPATCH_QUEUE_CONCURRENT);
}

static id PMKGetResult(PMKPromise *this) {
    __block id result;
    dispatch_sync(this->_promiseQueue, ^{
        result = this->_result;
    });
    return result;
}

static id PMKSanitizeResult(id value) {
    if (!value)
        return PMKNull;
    if (IsError(value))
        [PMKError unconsume:value];
    return value;
}

// 返回then提供的回调
static NSArray *PMKSetResult(PMKPromise *this, id result) {
    __block NSArray *handlers;

    result = PMKSanitizeResult(result);

    dispatch_barrier_sync(this->_promiseQueue, ^{
        handlers = this->_handlers;
        this->_result = result;
        this->_handlers = nil;
    });

    return handlers;
}

/// Resolve的作用就是完成任务，执行then传入的回调。
/// @param this 执行环境
/// @param result task的执行结果
static void PMKResolve(PMKPromise *this, id result) {
    // 查找deferred
    void (^set)(id) = ^(id r){
        NSArray *handlers = PMKSetResult(this, r);
        for (void (^handler)(id) in handlers)
            handler(r);
    };

    if (IsPromise(result)) {
        // 如果resolve传入的result是promise，还会继续对result继续then(resolve)，
        // 而传入的resolve是当前promise的resolve。
        PMKPromise *next = result;
        dispatch_barrier_sync(next->_promiseQueue, ^{
            id nextResult = next->_result;
            
            if (nextResult == nil) {  // ie. pending
                // 将当前this promise的resolve保存进next这个Promise的then的回调数组里。
                // 也就是next.then(this.resolve)，当next这个Promise在resolve完成之后，还会
                // 回到当前这个resolve里边，相当于是一个递归。
                [next->_handlers addObject:^(id o){
                    PMKResolve(this, o);
                }];
            } else
                set(nextResult);
        });
    } else     // 执行deferred，deferred中是一些列
        set(result);
}

+ (instancetype)promiseWithResolver:(void (^)(PMKResolver))block {
    PMKPromise *this = [self alloc];
    this->_promiseQueue = PMKCreatePromiseQueue();
    this->_handlers = [NSMutableArray new];

    @try {
        // block就是fn，JS中fn的参数就是resolve函数，而在OC中，为了传递resolve函数，
        // 将resolve包裹在了一个block中。
        block(^(id result){
            if (PMKGetResult(this))
                return PMKLog(@"PromiseKit: Warning: Promise already resolved");

            // 回调函数中参数为当前自己Promise的resolve
            PMKResolve(this, result);
        });
    } @catch (id e) {
        // at this point, no pointer to the Promise has been provided
        // to the user, so we can’t have any handlers, so all we need
        // to do is set _result. Technically using PMKSetResult is
        // not needed either, but this seems better safe than sorry.
        PMKSetResult(this, NSErrorFromException(e));
    }

    return this;
}

// new方法就是Promise(function(resolve, reject))，新增加了reject；
// 将resolve函数封装在了fulfiller中。
+ (instancetype)new:(void(^)(PMKFulfiller, PMKRejecter))block {
    return [self promiseWithResolver:^(PMKResolver resolve) {
        id rejecter = ^(id error){
            if (error == nil) {
                error = NSErrorFromNil();
            } else if (IsPromise(error) && [error rejected]) {
                // this is safe, acceptable and (basically) valid
            } else if (!IsError(error)) {
                id userInfo = @{NSLocalizedDescriptionKey: [error description], PMKUnderlyingExceptionKey: error};
                error = [NSError errorWithDomain:PMKErrorDomain code:PMKInvalidUsageError userInfo:userInfo];
            }
            resolve(error);
        };

        // 其实fuifiller中也包着resolve，所以new方法和promiseWithResolver类似。
        id fulfiller = ^(id result){
            if (IsError(result))
                PMKLog(@"PromiseKit: Warning: PMKFulfiller called with NSError.");
            resolve(result);
        };

        block(fulfiller, rejecter);
    }];
}

+ (instancetype)promiseWithAdapter:(void (^)(PMKAdapter))block {
    return [self promiseWithResolver:^(PMKResolver resolve) {
        block(^(id value, id error){
            resolve(error ?: value);
        });
    }];
}

+ (instancetype)promiseWithIntegerAdapter:(void (^)(PMKIntegerAdapter))block {
    return [self promiseWithResolver:^(PMKResolver resolve) {
        block(^(NSInteger value, id error){
            if (error) {
                resolve(error);
            } else {
                resolve(@(value));
            }
        });
    }];
}

+ (instancetype)promiseWithBooleanAdapter:(void (^)(PMKBooleanAdapter adapter))block {
    return [self promiseWithResolver:^(PMKResolver resolve) {
        block(^(BOOL value, id error){
            if (error) {
                resolve(error);
            } else {
                resolve(@(value));
            }
        });
    }];
}

- (BOOL)pending {
	id result = PMKGetResult(self);
    if (IsPromise(result)) {
        return [result pending];
    } else
        return result == nil;
}

- (BOOL)resolved {
    return PMKGetResult(self) != nil;
}

- (BOOL)fulfilled {
	id result = PMKGetResult(self);
    return result != nil && !IsError(result);
}

- (BOOL)rejected {
	id result = PMKGetResult(self);
    return result != nil && IsError(result);
}

- (id)value {
	id result = PMKGetResult(self);
    if (IsPromise(result))
        return [(PMKPromise *)result value];
    if ([result isKindOfClass:[PMKArray class]])
        return ((PMKArray *)result)[0];
    if (result == PMKNull)
        return nil;
    else
        return result;
}

- (NSString *)description {
    __block id result;
    __block NSUInteger handlerCount;
    dispatch_sync(_promiseQueue, ^{
        result = self->_result;
        handlerCount = self->_handlers.count;
    });
    
    BOOL pending = IsPromise(result) ? [result pending] : (result == nil);
    BOOL resolved = result != nil;
    BOOL fulfilled = resolved && !IsError(result);
    BOOL rejected = resolved && IsError(result);
    
    if (pending)
        return [NSString stringWithFormat:@"Promise: %lu pending handlers", (unsigned long)handlerCount];
    if (rejected)
        return [NSString stringWithFormat:@"Promise: rejected: %@", result];
    
    assert(fulfilled);
    
    return [NSString stringWithFormat:@"Promise: fulfilled: %@", result];
}

@end



PMKPromise *dispatch_promise(id block) {
    return dispatch_promise_on(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
}

PMKPromise *dispatch_promise_on(dispatch_queue_t queue, id block) {
    return [PMKPromise new:^(void(^fulfiller)(id), void(^rejecter)(id)){
        dispatch_async(queue, ^{
            id result = pmk_safely_call_block(block, nil);
            if (IsError(result))
                rejecter(result);
            else
                // 这个fulfiller是then_promise的，里边包含了自己的resolve
                fulfiller(result);
        });
    }];
}


@implementation PMKArray {
@public id objs[3];
@public NSUInteger count;
}

- (id)objectAtIndexedSubscript:(NSUInteger)idx {
	if (count <= idx) {
        // this check is necessary due to lack of checks in `pmk_safely_call_block`
		return nil;
    }
    return objs[idx];
}

@end

id __PMKArrayWithCount(NSUInteger count, ...) {
    PMKArray *this = [PMKArray new];
    this->count = count;
    va_list args;
    va_start(args, count);
    for (NSUInteger x = 0; x < count; ++x)
        this->objs[x] = va_arg(args, id);
    va_end(args);
    return this;
}



NSOperationQueue *PMKOperationQueue() {
    static NSOperationQueue *q;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = [NSOperationQueue new];
        q.name = @"org.promisekit.Q";
    });
    return q;
}



void *PMKManualReferenceAssociatedObject = &PMKManualReferenceAssociatedObject;
