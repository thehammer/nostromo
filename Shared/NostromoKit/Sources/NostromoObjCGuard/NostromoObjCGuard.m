#import "NostromoObjCGuard.h"

NSException *_Nullable NostromoCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
