#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// MediaFusion 6.2.0 can redact its own configured playback path. Restore only
// an exact redaction of this add-on's already-known configuration component.
// Unrelated or ambiguous inputs are returned unchanged. No storage or network.
FOUNDATION_EXPORT NSURL * _Nullable MSRestoreMediaFusionPlaybackURL(NSURL * _Nullable URL,
    NSURL * _Nullable manifestURL, NSString *addonIdentifier);
NS_ASSUME_NONNULL_END
