#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any Objective-C exception into an NSError.
/// Returns YES if the block completed without throwing.
/// Only pass blocks that call Objective-C APIs directly: an exception unwinding through Swift
/// frames is undefined behaviour.
BOOL MMTryObjC(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

/// Filters `objects` with `predicate` entirely in Objective-C, so exceptions raised by KVC or
/// type mismatches never unwind through Swift code. Returns nil and sets `error` on an exception.
NSArray *_Nullable MMFilterWithPredicate(NSArray *objects, NSPredicate *predicate, NSError *_Nullable *_Nullable error);

@class AVAudioEngine, AVAudioNode, AVAudioFormat;

/// `[engine connect:from to:to format:format]`, returning NO instead of raising when
/// AVAudioEngine refuses (e.g. a format change it can't make while running).
BOOL MMConnectNodes(AVAudioEngine *engine, AVAudioNode *from, AVAudioNode *to, AVAudioFormat *_Nullable format, NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
