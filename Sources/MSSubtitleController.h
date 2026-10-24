#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A foreground playback clock and embedded-caption adapter. The owner retains
/// this controller; the controller keeps the playback source weakly.
@protocol MSSubtitlePlaybackSource <NSObject>
- (NSTimeInterval)subtitlePlaybackTime;
- (BOOL)subtitlePlaybackActive;
/// Each entry contains id (NSNumber), name and language (NSString).
- (NSArray<NSDictionary *> *)subtitleEmbeddedTracks;
- (NSInteger)subtitleSelectedEmbeddedTrackID;
- (void)subtitleSelectEmbeddedTrackID:(NSInteger)identifier; // -1 disables captions
@end

/// Own one controller per player item. Call these methods on the main queue.
/// Call invalidate before replacing the item or dismissing the player.
/// Construction performs no network requests.
@interface MSSubtitleController : NSObject
- (instancetype)initWithPlayer:(nullable AVPlayer *)player
                   overlayView:(UIView *)overlay
                          type:(NSString *)type
                       videoID:(NSString *)videoID
                        extras:(NSDictionary<NSString *, NSString *> *)extras;
- (instancetype)initWithPlaybackSource:(id<MSSubtitlePlaybackSource>)source
                          overlayView:(UIView *)overlay
                                 type:(NSString *)type
                              videoID:(NSString *)videoID
                               extras:(NSDictionary<NSString *, NSString *> *)extras;
/// Refresh a non-AVPlayer source after its embedded track list changes.
- (void)refreshEmbeddedTracks;
- (void)presentFromViewController:(UIViewController *)viewController;
/// Set before stream subtitles/restoration. A missing fingerprint keeps source
/// caption choices session-only; playback addresses are never used as identity.
- (void)setStreamSourceFingerprint:(nullable NSString *)fingerprint;
- (void)setStreamSubtitles:(NSArray<NSDictionary *> *)subtitles;
/// Call once after the item is ready, using the exact library video/episode ID.
/// Restores stable identities; external URLs are re-queried from installed add-ons.
- (void)restoreSelectionForContentIdentifier:(NSString *)identifier;
- (void)invalidate;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
