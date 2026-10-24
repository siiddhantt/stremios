#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const MSPlaybackPreferencesDidChangeNotification;
/// Validated local presentation defaults; never contains stream URLs or account data.
@interface MSPlaybackPreferences : NSObject
+ (instancetype)sharedPreferences;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@property (nonatomic) double subtitleFontSize; // 14–40 points; default 24.
@property (nonatomic, copy) NSString *fontFamily; // system, serif, monospace
@property (nonatomic, copy) NSString *style; // white-dark, yellow-dark, white-shadow
@property (nonatomic, copy) NSString *subtitleFontWeight; // regular, medium, semibold (default), bold
@property (nonatomic, copy) NSString *subtitleColorHex; // six-digit sRGB; empty retains legacy style colour
@property (nonatomic, copy, readonly) NSString *effectiveSubtitleColorHex;
@property (nonatomic, copy) NSString *position; // bottom, middle, top
@property (nonatomic, copy) NSString *playbackQuality; // auto, 720p, 1080p; adaptive preference only
@property (nonatomic, copy) NSString *preferredAudioLanguage; // system, eng, hin
@property (nonatomic, copy) NSString *preferredSubtitleLanguage; // system, eng, hin, none
- (void)resetSubtitleAppearance;
@end
/// Per-player adaptive rendition preferences. Fixed files are unchanged;
/// VLC may use the lowest available rendition when none meets these limits.
FOUNDATION_EXPORT NSArray<NSString *> *MSVLCAdaptiveOptions(MSPlaybackPreferences *preferences);
NS_ASSUME_NONNULL_END
