#import <UIKit/UIKit.h>
#import "MSCatalogViewController.h"
@class MSMedia;
NS_ASSUME_NONNULL_BEGIN
@interface MSBrowseViewController : UICollectionViewController
- (instancetype)initWithCatalog:(NSArray<MSMedia *> *)catalog libraryOnly:(BOOL)libraryOnly;
- (instancetype)initWithCatalog:(NSArray<MSMedia *> *)catalog libraryOnly:(BOOL)libraryOnly videoSelection:(nullable MSVideoSelection)selection;
@end
NS_ASSUME_NONNULL_END
