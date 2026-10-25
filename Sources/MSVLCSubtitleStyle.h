#import <Foundation/Foundation.h>
@class MSPlaybackPreferences;
/// Defaults for plain embedded text, applied when starting a new decoder.
NSArray<NSString *> *MSVLCSubtitleOptions(MSPlaybackPreferences *preferences);
/// Startup-only margin from parsed video height; invalid/unknown dimensions and
/// zero offset preserve native position. Shadow/margin require reopening playback.
NSArray<NSString *> *MSVLCSubtitleOptionsForVideoHeight(MSPlaybackPreferences *preferences, double videoHeightPixels);
/// Guarded adapter for the exact four selectors in pinned MobileVLCKit 3.7.4.
/// These implementation selectors are also used by VideoLAN's iOS player, but
/// are absent from the public header. No private ivars or generic VLC variables.
BOOL MSVLCApplySubtitleLiveStyle(id player, MSPlaybackPreferences *preferences);
