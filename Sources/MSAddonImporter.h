#import <Foundation/Foundation.h>
#import "MSCatalogClient.h"

NS_ASSUME_NONNULL_BEGIN
typedef void (^MSAddonImportCompletion)(NSUInteger added, NSError * _Nullable error);
@interface MSAddonImporter : NSObject
// Local, user-authorized provisioning only: Documents/AddonImport.json (max 32 KiB).
// Schema: {"manifestURLs":["https://…/manifest.json"]}, at most 12 entries.
// There is no network listener, remote command, or account login. Each URL is fetched
// only for its manifest, then stored through MSAddonStore's protected private-file path.
// Main-queue completion; cancellation suppresses completion. A retry marker prevents
// failed or interrupted imports being repeated automatically on the next launch.
+ (id<MSCancellable>)importPendingConfigurationWithCompletion:(MSAddonImportCompletion)completion;
+ (id<MSCancellable>)retryPendingConfigurationWithCompletion:(MSAddonImportCompletion)completion;
+ (BOOL)hasPendingRetry;
@end
NS_ASSUME_NONNULL_END
