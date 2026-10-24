#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * const MSAddonsDidChangeNotification;

@interface MSAddonCatalogExtra : NSObject
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) BOOL isRequired;
@property(nonatomic, copy, readonly) NSArray<NSString *> *options;
@property(nonatomic, readonly) NSUInteger optionsLimit;
@end

@interface MSAddonCatalog : NSObject
@property(nonatomic, copy, readonly) NSString *connectionIdentifier;
@property(nonatomic, copy, readonly) NSString *addonName;
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *type;
@property(nonatomic, copy, readonly) NSString *name;
// Contains only the local connection UUID and catalog type/id, never a URL.
@property(nonatomic, copy, readonly) NSString *identity;
@property(nonatomic, copy, readonly) NSArray<MSAddonCatalogExtra *> *extras;
- (nullable MSAddonCatalogExtra *)extraNamed:(NSString *)name;
// Rejects undeclared/invalid values and unsatisfied required extras. skip is
// added only when declared; catalogs without pagination accept only skip=0.
- (nullable NSDictionary<NSString *, NSString *> *)requestExtrasForValues:(nullable NSDictionary<NSString *, NSString *> *)values skip:(NSUInteger)skip error:(NSError * _Nullable * _Nullable)error;
@end

@interface MSAddon : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
// Separate from the manifest ID so existing playback fingerprints stay valid.
@property(nonatomic, copy, readonly) NSString *connectionIdentifier;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *version;
@property(nonatomic, copy, readonly) NSArray<MSAddonCatalog *> *catalogs;
@property(nonatomic, readonly) BOOL configurable;
@property(nonatomic, readonly) BOOL configurationRequired;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *configurationFields;
// May contain a secret. Display only name and manifestURL.host; never log the URL.
@property(nonatomic, strong, readonly) NSURL *manifestURL;
@property(nonatomic, strong, readonly, nullable) NSURL *configureURL;
@property(nonatomic, readonly) BOOL builtIn;
+ (nullable NSURL *)manifestURLFromString:(NSString *)string error:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)addonWithManifest:(NSDictionary *)manifest URL:(NSURL *)URL error:(NSError * _Nullable * _Nullable)error;
- (BOOL)supportsResource:(NSString *)resource type:(NSString *)type identifier:(NSString *)identifier;
- (nullable NSURL *)resourceURL:(NSString *)resource type:(NSString *)type identifier:(NSString *)identifier extras:(nullable NSDictionary<NSString *, NSString *> *)extras;
@end

@interface MSAddonStore : NSObject
+ (instancetype)sharedStore;
@property(nonatomic, copy, readonly) NSArray<MSAddon *> *addons;
@property(nonatomic, copy, readonly) NSArray<MSAddonCatalog *> *allCatalogs;
- (nullable MSAddon *)addonForConnectionIdentifier:(NSString *)identifier;
// A failed protected-storage read is surfaced rather than silently replacing stored entries.
@property(nonatomic, strong, readonly, nullable) NSError *loadError;
- (BOOL)reloadWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)addManifest:(NSDictionary *)manifest URL:(NSURL *)URL error:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceAddon:(MSAddon *)existing manifest:(NSDictionary *)manifest URL:(NSURL *)URL error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeAddon:(MSAddon *)addon error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
