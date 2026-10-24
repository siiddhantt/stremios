#import "MSSettingsComponents.h"
#import "MSAddons.h"
NS_ASSUME_NONNULL_BEGIN
// Presentation names only; request keys and values remain exactly as declared.
NSString *MSCatalogFilterTitle(MSAddonCatalog *catalog, MSAddonCatalogExtra *extra);
@interface MSCatalogPickerViewController : MSSettingsTableController
- (instancetype)initWithCatalogs:(NSArray<MSAddonCatalog *> *)catalogs selectedIdentity:(nullable NSString *)identity selection:(void (^)(MSAddonCatalog *catalog))selection;
@end
@interface MSCatalogFiltersViewController : MSSettingsTableController
- (instancetype)initWithCatalog:(MSAddonCatalog *)catalog values:(NSDictionary<NSString *,NSString *> *)values apply:(void (^)(NSDictionary<NSString *,NSString *> *values))apply;
@end
NS_ASSUME_NONNULL_END
