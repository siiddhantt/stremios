#import <Foundation/Foundation.h>
#import "MSCatalogClient.h"

NS_ASSUME_NONNULL_BEGIN
// Keys and configured addresses are secrets. No method logs or persists them.
@interface MSTorBoxClient : NSObject
+ (nullable NSString *)normalizedAPIKey:(NSString *)input error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSURL *)torrentioManifestURLForAPIKey:(NSString *)key error:(NSError * _Nullable * _Nullable)error;
// First-party TorBox request only. Account data is discarded after validation.
+ (id<MSCancellable>)validateAPIKey:(NSString *)key completion:(void (^)(NSError * _Nullable))completion;
// Call only after explicit consent to send the key to Torrentio.
+ (id<MSCancellable>)fetchTorrentioManifestWithAPIKey:(NSString *)key
    completion:(void (^)(NSDictionary * _Nullable, NSURL * _Nullable, NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
