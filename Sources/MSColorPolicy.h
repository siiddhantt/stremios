#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Six uppercase sRGB digits, optionally accepting a leading #. Empty if invalid.
FOUNDATION_EXPORT NSString *MSNormalizedColorHex(id _Nullable value);
FOUNDATION_EXPORT uint32_t MSColorRGB(NSString *hex);
FOUNDATION_EXPORT double MSColorContrastRatio(uint32_t first, uint32_t second);
/// Brightens only as needed for readable text/tints; no opacity or animation.
FOUNDATION_EXPORT NSString *MSReadableAccentHex(NSString *hex);
FOUNDATION_EXPORT NSString *MSReadableSubtitleHex(NSString *hex);
NS_ASSUME_NONNULL_END
