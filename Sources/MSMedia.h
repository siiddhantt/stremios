#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MSMedia : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *summary;
@property (nonatomic, copy, readonly) NSString *format;
@property (nonatomic, copy, readonly) NSString *attribution;
@property (nonatomic, copy, readonly) NSString *license;
@property (nonatomic, strong, readonly) NSURL *licenseURL;
@property (nonatomic, strong, readonly) NSURL *sourceURL;
@property (nonatomic, strong, readonly) NSURL *streamURL;
@property (nonatomic, readonly) NSInteger year;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, copy, readonly) NSString *mediaType;
@property (nonatomic, copy) NSArray<NSDictionary *> *streamSubtitles;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *subtitleExtras;
/// In-memory routing metadata; the Library independently validates persistence.
@property (nonatomic, copy) NSDictionary *libraryMetadata;
@property (nonatomic, copy, nullable) NSString *sourceFingerprint;
+ (instancetype)mediaWithIdentifier:(NSString *)identifier title:(NSString *)title type:(NSString *)type streamURL:(NSURL *)url format:(NSString *)format subtitleExtras:(NSDictionary<NSString *, NSString *> *)extras;
+ (NSArray<MSMedia *> *)bundledCatalogWithError:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
