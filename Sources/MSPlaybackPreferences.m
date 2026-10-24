#import "MSPlaybackPreferences.h"
#import "MSColorPolicy.h"
#import <math.h>
NSNotificationName const MSPlaybackPreferencesDidChangeNotification = @"MSPlaybackPreferencesDidChangeNotification";
static NSString * const MSPrefsKey = @"MiniStream.PlaybackPreferences.v1";
@interface MSPlaybackPreferences ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@end

NSArray<NSString *> *MSVLCAdaptiveOptions(MSPlaybackPreferences *preferences) {
    if ([preferences.playbackQuality isEqual:@"720p"]) return @[@"--adaptive-maxwidth=1280", @"--adaptive-maxheight=720"];
    if ([preferences.playbackQuality isEqual:@"1080p"]) return @[@"--adaptive-maxwidth=1920", @"--adaptive-maxheight=1080"];
    return @[];
}
@implementation MSPlaybackPreferences
+ (instancetype)sharedPreferences { static id prefs; static dispatch_once_t once; dispatch_once(&once, ^{ prefs = [[self alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; }); return prefs; }
- (instancetype)init { return [self initWithDefaults:NSUserDefaults.standardUserDefaults]; }
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults { if ((self = [super init])) _defaults = defaults; return self; }
- (NSDictionary *)values { id value = [self.defaults objectForKey:MSPrefsKey]; return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
- (NSString *)stringFor:(NSString *)key allowed:(NSArray *)allowed fallback:(NSString *)fallback { id value = [self values][key]; return [value isKindOfClass:NSString.class] && [allowed containsObject:value] ? value : fallback; }
- (void)save:(id)value key:(NSString *)key old:(id)old {
    if ([value isEqual:old]) return;
    NSMutableDictionary *values = [[self values] mutableCopy]; values[key] = value;
    [self.defaults setObject:values forKey:MSPrefsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MSPlaybackPreferencesDidChangeNotification object:self];
}
- (double)subtitleFontSize { id value = [self values][@"fontSize"]; double size = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 24; return isfinite(size) ? fmin(40, fmax(14, size)) : 24; }
- (void)setSubtitleFontSize:(double)value { double size = isfinite(value) ? fmin(40, fmax(14, value)) : 24; [self save:@(size) key:@"fontSize" old:@(self.subtitleFontSize)]; }
#define MS_STRING_PREF(GETTER, SETTER, KEY, FALLBACK, ...) \
- (NSString *)GETTER { return [self stringFor:KEY allowed:@[__VA_ARGS__] fallback:FALLBACK]; } \
- (void)SETTER:(NSString *)value { NSArray *allowed = @[__VA_ARGS__]; NSString *normalized = [value isKindOfClass:NSString.class] && [allowed containsObject:value] ? value : FALLBACK; [self save:normalized key:KEY old:self.GETTER]; }
MS_STRING_PREF(fontFamily, setFontFamily, @"fontFamily", @"system", @"system", @"serif", @"monospace")
MS_STRING_PREF(style, setStyle, @"style", @"white-dark", @"white-dark", @"yellow-dark", @"white-shadow")
- (NSString *)subtitleFontWeight { return [self stringFor:@"fontWeight" allowed:@[@"regular",@"medium",@"semibold",@"bold"] fallback:[self.fontFamily isEqual:@"system"]?@"semibold":@"regular"]; }
- (void)setSubtitleFontWeight:(NSString *)value { NSArray *allowed=@[@"regular",@"medium",@"semibold",@"bold"];NSString *normalized=[value isKindOfClass:NSString.class]&&[allowed containsObject:value]?value:([self.fontFamily isEqual:@"system"]?@"semibold":@"regular");[self save:normalized key:@"fontWeight" old:self.subtitleFontWeight]; }
MS_STRING_PREF(position, setPosition, @"position", @"bottom", @"bottom", @"middle", @"top")
MS_STRING_PREF(playbackQuality, setPlaybackQuality, @"quality", @"auto", @"auto", @"720p", @"1080p")
MS_STRING_PREF(preferredAudioLanguage, setPreferredAudioLanguage, @"audioLanguage", @"system", @"system", @"eng", @"hin")
MS_STRING_PREF(preferredSubtitleLanguage, setPreferredSubtitleLanguage, @"subtitleLanguage", @"system", @"system", @"eng", @"hin", @"none")
#undef MS_STRING_PREF
- (NSString *)subtitleColorHex { NSString *hex=MSNormalizedColorHex([self values][@"subtitleColor"]); return hex.length?MSReadableSubtitleHex(hex):@""; }
- (void)setSubtitleColorHex:(NSString *)value { NSString *hex=MSNormalizedColorHex(value); [self save:hex.length?MSReadableSubtitleHex(hex):@"" key:@"subtitleColor" old:self.subtitleColorHex]; }
- (NSString *)effectiveSubtitleColorHex { return self.subtitleColorHex.length?self.subtitleColorHex:([self.style isEqual:@"yellow-dark"]?@"FFE859":@"FFFFFF"); }
- (void)resetSubtitleAppearance {
    NSMutableDictionary *values = [[self values] mutableCopy];
    BOOL changed = self.subtitleFontSize != 24 || ![self.fontFamily isEqual:@"system"] || ![self.style isEqual:@"white-dark"] || ![self.position isEqual:@"bottom"] || ![self.subtitleFontWeight isEqual:@"semibold"] || self.subtitleColorHex.length;
    for (NSString *key in @[@"fontSize", @"fontFamily", @"style", @"position", @"fontWeight", @"subtitleColor"]) [values removeObjectForKey:key];
    [self.defaults setObject:values forKey:MSPrefsKey];
    if (changed) [NSNotificationCenter.defaultCenter postNotificationName:MSPlaybackPreferencesDidChangeNotification object:self];
}
@end
