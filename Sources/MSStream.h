#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface MSStream : NSObject
@property(nonatomic,copy,readonly) NSString *name, *detail, *compatibility;
@property(nonatomic,copy,readonly) NSString *providerIdentifier, *providerName, *filename;
// Reported labels, not a probe of the video. Empty resolution means unreported.
@property(nonatomic,copy,readonly) NSString *reportedResolution, *codecLabel, *bingeGroup, *sourceFingerprint;
@property(nonatomic,strong,readonly,nullable) NSURL *URL;
@property(nonatomic,readonly) BOOL canAttemptPlayback;
/// Audio labels known to require the bundled decoder, even inside MP4.
@property(nonatomic,readonly) BOOL prefersVLC;
@property(nonatomic,copy,readonly) NSArray<NSDictionary *> *providedSubtitles;
@property(nonatomic,copy,readonly) NSDictionary<NSString *, NSString *> *subtitleExtras;
+ (nullable instancetype)streamWithDictionary:(NSDictionary *)dictionary addonName:(NSString *)name;
+ (nullable instancetype)streamWithDictionary:(NSDictionary *)dictionary addonName:(NSString *)name addonIdentifier:(NSString *)identifier;
- (BOOL)matchesProvider:(nullable NSString *)provider resolution:(nullable NSString *)resolution compatibleOnly:(BOOL)compatibleOnly;
@end
NS_ASSUME_NONNULL_END
