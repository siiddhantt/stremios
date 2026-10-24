#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Main-thread only. Claim immediately after successful audio activation.
/// A later claim supersedes every earlier player/retirement token.
FOUNDATION_EXPORT NSObject *MSClaimAudioSession(void);
/// Deactivate only if token still owns the shared session. Repeated or stale
/// releases do nothing. Stop/detach that owner's playback before releasing it.
FOUNDATION_EXPORT void MSReleaseAudioSession(NSObject * _Nullable token);
/// Forget the current owner after media services loss/reset, without calling AV.
FOUNDATION_EXPORT void MSAbandonAudioSession(NSObject * _Nullable token);
NS_ASSUME_NONNULL_END
