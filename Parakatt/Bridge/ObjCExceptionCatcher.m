#import "ObjCExceptionCatcher.h"

BOOL catchObjCException(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.parakatt.objc-exception"
                                         code:-1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name
            }];
        }
        return NO;
    }
}
