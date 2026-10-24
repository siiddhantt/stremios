#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@protocol MSCancellable <NSObject>
- (void)cancel;
@end
@interface MSEpisode : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, readonly) NSInteger season;
@property(nonatomic, readonly) NSInteger episode;
@property(nonatomic, copy, readonly, nullable) NSString *released;
@end
@interface MSMetadata : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *type;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, strong, readonly, nullable) NSURL *posterURL;
@property(nonatomic, strong, readonly, nullable) NSURL *backgroundURL;
// Optional title artwork supplied by the same metadata response.
@property(nonatomic, strong, readonly, nullable) NSURL *logoURL;
@property(nonatomic, copy, readonly) NSString *releaseInfo;
@property(nonatomic, copy, readonly) NSString *runtime;
// Validated 0–10 IMDb value from existing metadata, formatted to one decimal.
// Empty when absent or malformed; no separate ratings request is made.
@property(nonatomic, copy, readonly) NSString *imdbRating;
@property(nonatomic, copy, readonly) NSString *summary;
@property(nonatomic, copy, readonly) NSArray<NSString *> *genres;
@property(nonatomic, copy, readonly) NSArray<MSEpisode *> *episodes;
+ (nullable instancetype)metadataWithDictionary:(NSDictionary *)dictionary fallbackType:(NSString *)type;
@end
@interface MSCatalogPage : NSObject
@property(nonatomic, copy, readonly) NSArray<MSMetadata *> *items;
@property(nonatomic, readonly) NSUInteger receivedCount;
@property(nonatomic, readonly) NSUInteger nextSkip;
@property(nonatomic, readonly) BOOL hasMore;
@end
@interface MSCatalogClient : NSObject
+ (instancetype)sharedClient;
// Completion always runs on the main queue. Cancellation suppresses completion.
- (id<MSCancellable>)loadCatalogType:(NSString *)type search:(nullable NSString *)search skip:(NSUInteger)skip completion:(void (^)(MSCatalogPage * _Nullable page, NSError * _Nullable error))completion;
- (id<MSCancellable>)loadMetadataType:(NSString *)type identifier:(NSString *)identifier completion:(void (^)(MSMetadata * _Nullable metadata, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
