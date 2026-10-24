#import <UIKit/UIKit.h>
#import "MSCatalogViewController.h"
NS_ASSUME_NONNULL_BEGIN
@interface MSCatalogDetailViewController : UITableViewController
// Focus from Library without resolving or starting playback.
@property(nonatomic,copy,nullable) NSString *preferredVideoIdentifier;
// True only during selection from the explicit Resume button. Episode rows
// remain ordinary source selection; neither path resolves media in this view.
@property(nonatomic,readonly) BOOL resumeRequested;
- (instancetype)initWithMetadata:(MSMetadata *)metadata catalogClient:(MSCatalogClient *)client videoSelection:(nullable MSVideoSelection)selection;
@end
NS_ASSUME_NONNULL_END
