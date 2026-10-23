#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil when it completed.
/// Swift cannot catch an NSException, so a call into AppKit that may throw has to go through
/// here or it aborts the app. Keep the blocks small: the stack is unwound past the throw
/// without running cleanup, so anything the block half-did stays half-done.
FOUNDATION_EXPORT NSException *_Nullable NostromoCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
