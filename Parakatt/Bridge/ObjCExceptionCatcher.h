#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and catches any Objective-C NSException, returning it as an NSError.
/// Returns YES on success, NO if an exception was caught.
BOOL catchObjCException(void (NS_NOESCAPE ^_Nonnull block)(void),
                        NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
