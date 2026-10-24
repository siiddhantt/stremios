#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MSSubtitlesErrorDomain;

typedef NS_ENUM(NSInteger, MSSubtitlesErrorCode) {
    MSSubtitlesErrorEmpty = 1,
    MSSubtitlesErrorUnsupportedFormat,
    MSSubtitlesErrorInvalidEncoding,
    MSSubtitlesErrorInvalidFormat,
    MSSubtitlesErrorLimitExceeded
};

@interface MSSubtitleCue : NSObject
@property (nonatomic, readonly) NSTimeInterval startTime;
@property (nonatomic, readonly) NSTimeInterval endTime;
@property (nonatomic, copy, readonly) NSString *text;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Plain-text SRT/WebVTT only. Limits: 2 MiB input, 20,000 cues, 2,000 UTF-16
/// code units per cue. UTF-8 and BOM-marked UTF-16 are supported, with a
/// Windows-1252 fallback for recognizable legacy SRT. Exact musical-symbol
/// mojibake signatures are repaired without re-encoding the rest of the cue.
/// Invalid cue blocks are skipped; an empty/unsupported/oversized track errors.
@interface MSSubtitleTrack : NSObject
@property (nonatomic, copy, readonly) NSArray<MSSubtitleCue *> *cues;
- (nullable instancetype)initWithData:(NSData *)data error:(NSError * _Nullable * _Nullable)error;
/// Start is inclusive and end exclusive. Returns up to four overlapping cues
/// in chronological order, joined by newlines, or an empty string. Safe for
/// arbitrary forward/backward seeks; NaN/infinite/negative time has no text.
- (NSString *)textAtTime:(NSTimeInterval)time;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
