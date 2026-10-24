#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * const MSAddonsDidChangeNotification;

@interface MSAddon : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *name;
// May contain a secret. Display only name and manifestURL.host; never log the URL.
@property(nonatomic, strong, readonly) NSURL *manifestURL;
@property(nonatomic, readonly) BOOL builtIn;
+ (nullable NSURL *)manifestURLFromString:(NSString *)string error:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)addonWithManifest:(NSDictionary *)manifest URL:(NSURL *)URL error:(NSError * _Nullable * _Nullable)error;
- (BOOL)supportsResource:(NSString *)resource type:(NSString *)type identifier:(NSString *)identifier;
- (nullable NSURL *)resourceURL:(NSString *)resource type:(NSString *)type identifier:(NSString *)identifier extras:(nullable NSDictionary<NSString *, NSString *> *)extras;
@end

@interface MSAddonStore : NSObject
+ (instancetype)sharedStore;
@property(nonatomic, copy, readonly) NSArray<MSAddon *> *addons;
// A failed protected-storage read is surfaced rather than silently replacing stored entries.
@property(nonatomic, strong, readonly, nullable) NSError *loadError;
- (BOOL)reloadWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)addManifest:(NSDictionary *)manifest URL:(NSURL *)URL error:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceAddon:(MSAddon *)existing manifest:(NSDictionary *)manifest URL:(NSURL *)URL error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeAddon:(MSAddon *)addon error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
