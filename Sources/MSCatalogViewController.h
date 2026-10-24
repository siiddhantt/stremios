#import <UIKit/UIKit.h>
#import "MSCatalogClient.h"
@class MSMedia;
NS_ASSUME_NONNULL_BEGIN
typedef void (^MSVideoSelection)(MSMetadata *metadata, MSEpisode * _Nullable episode);
@interface MSCatalogViewController : UIViewController
- (instancetype)initWithCatalogClient:(MSCatalogClient *)client demoCatalog:(NSArray<MSMedia *> *)demo videoSelection:(nullable MSVideoSelection)selection;
@end
NS_ASSUME_NONNULL_END
