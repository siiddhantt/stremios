#import <Foundation/Foundation.h>
#import "MSCatalogClient.h"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL MSIsSafeRemoteURL(NSURL * _Nullable url);
FOUNDATION_EXPORT NSError *MSNetworkError(NSString *message);
@interface MSHTTPClient : NSObject
+ (instancetype)sharedClient;
- (id<MSCancellable>)fetchJSONURL:(NSURL *)url completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
- (id<MSCancellable>)fetchDataURL:(NSURL *)url maximumBytes:(NSUInteger)limit completion:(void (^)(NSData * _Nullable, NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
