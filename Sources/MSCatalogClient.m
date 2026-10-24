#import "MSCatalogClient.h"
#import "MSHTTPClient.h"
#import <math.h>
static NSString *MSString(id value, NSUInteger limit) { return [value isKindOfClass:NSString.class] ? ([value length] > limit ? [value substringToIndex:limit] : value) : @""; }
static NSString *MSIMDbRating(id value) {
    NSString *text = nil;
    if ([value isKindOfClass:NSString.class] && [value length] <= 16)
        text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    else if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())
        text = [value stringValue];
    if (!text.length || text.length > 16) return @"";
    static NSRegularExpression *decimal; static dispatch_once_t once;
    dispatch_once(&once, ^{ decimal = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(?:\\.[0-9]+)?$" options:0 error:nil]; });
    if (![decimal firstMatchInString:text options:0 range:NSMakeRange(0,text.length)]) return @"";
    double number = text.doubleValue;
    return isfinite(number) && number >= 0 && number <= 10 ? [NSString stringWithFormat:@"%.1f",number] : @"";
}
@implementation MSEpisode
+ (instancetype)fromDictionary:(NSDictionary *)raw {
    NSString *identifier = [raw[@"id"] isKindOfClass:NSString.class] && [raw[@"id"] length] <= 1024 ? raw[@"id"] : @""; if (!identifier.length) return nil;
    MSEpisode *episode = [self new]; episode->_identifier = identifier;
    episode->_title = MSString(raw[@"title"] ?: raw[@"name"], 300);
    episode->_season = [raw[@"season"] respondsToSelector:@selector(integerValue)] ? MAX(0, [raw[@"season"] integerValue]) : 0;
    episode->_episode = [raw[@"episode"] respondsToSelector:@selector(integerValue)] ? MAX(0, [raw[@"episode"] integerValue]) : 0;
    episode->_released = MSString(raw[@"released"], 80); return episode;
}
@end
@implementation MSMetadata
+ (instancetype)metadataWithDictionary:(NSDictionary *)raw fallbackType:(NSString *)type {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    NSString *identifier = [raw[@"id"] isKindOfClass:NSString.class] && [raw[@"id"] length] <= 1024 ? raw[@"id"] : @"", *title = MSString(raw[@"name"], 400);
    if (!identifier.length || !title.length) return nil;
    MSMetadata *item = [self new]; item->_identifier = identifier; item->_title = title;
    item->_type = [@[@"movie", @"series"] containsObject:raw[@"type"]] ? raw[@"type"] : type;
    item->_releaseInfo = MSString(raw[@"releaseInfo"], 80); item->_runtime = MSString(raw[@"runtime"], 80); item->_summary = MSString(raw[@"description"], 12000);
    item->_imdbRating = MSIMDbRating(raw[@"imdbRating"]);
    NSURL *poster = [NSURL URLWithString:MSString(raw[@"poster"], 4096)]; item->_posterURL = MSIsSafeRemoteURL(poster) ? poster : nil;
    NSURL *background = [NSURL URLWithString:MSString(raw[@"background"], 4096)]; item->_backgroundURL = MSIsSafeRemoteURL(background) ? background : nil;
    NSString *logoText = [raw[@"logo"] isKindOfClass:NSString.class] && [raw[@"logo"] length] <= 4096 ? raw[@"logo"] : nil;
    NSURL *logo = logoText.length ? [NSURL URLWithString:logoText] : nil; item->_logoURL = MSIsSafeRemoteURL(logo) ? logo : nil;
    NSMutableArray *genres = [NSMutableArray array], *episodes = [NSMutableArray array];
    if ([raw[@"genres"] isKindOfClass:NSArray.class]) for (id genre in raw[@"genres"]) { if (genres.count >= 20) break; if ([genre isKindOfClass:NSString.class]) [genres addObject:MSString(genre, 80)]; }
    if ([raw[@"videos"] isKindOfClass:NSArray.class]) for (id video in raw[@"videos"]) { if (episodes.count >= 5000) break; if ([video isKindOfClass:NSDictionary.class]) { MSEpisode *e = [MSEpisode fromDictionary:video]; if(e) [episodes addObject:e]; } }
    [episodes sortUsingComparator:^NSComparisonResult(MSEpisode *a, MSEpisode *b) { if (a.season != b.season) return a.season < b.season ? NSOrderedAscending : NSOrderedDescending; return a.episode < b.episode ? NSOrderedAscending : a.episode > b.episode ? NSOrderedDescending : NSOrderedSame; }];
    item->_genres = [genres copy]; item->_episodes = [episodes copy]; return item;
}
@end
@interface MSCatalogPage ()
@property(nonatomic,copy,readwrite) NSArray<MSMetadata *> *items;
@property(nonatomic,readwrite) NSUInteger receivedCount, nextSkip;
@property(nonatomic,readwrite) BOOL hasMore;
@end
@implementation MSCatalogPage
@end
@implementation MSCatalogClient
+ (instancetype)sharedClient { static MSCatalogClient *client; static dispatch_once_t once; dispatch_once(&once, ^{ client = [self new]; }); return client; }
- (id<MSCancellable>)loadCatalogType:(NSString *)type search:(NSString *)search skip:(NSUInteger)skip completion:(void (^)(MSCatalogPage *, NSError *))completion {
    NSString *kind = [type isEqualToString:@"series"] ? @"series" : @"movie";
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    NSString *query = [MSString(search, 200) stringByAddingPercentEncodingWithAllowedCharacters:safe];
    NSString *extra = query.length ? [NSString stringWithFormat:@"search=%@&skip=%lu", query, (unsigned long)skip] : [NSString stringWithFormat:@"skip=%lu", (unsigned long)skip];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://v3-cinemeta.strem.io/catalog/%@/top/%@.json", kind, extra]];
    return [[MSHTTPClient sharedClient] fetchJSONURL:url completion:^(NSDictionary *document, NSError *error) {
        if (error) { completion(nil,error); return; }
        NSArray *raw = [document[@"metas"] isKindOfClass:NSArray.class] ? document[@"metas"] : nil;
        if (!raw) { completion(nil,MSNetworkError(@"The catalog response was incomplete.")); return; }
        NSMutableArray *items = [NSMutableArray array];
        for (id row in raw) { if(items.count >= 500) break; MSMetadata *item = [MSMetadata metadataWithDictionary:row fallbackType:kind]; if(item) [items addObject:item]; }
        MSCatalogPage *page = [MSCatalogPage new]; page.items = items; page.receivedCount = raw.count; page.nextSkip = skip + raw.count; page.hasMore = raw.count > 0; completion(page,nil);
    }];
}
- (id<MSCancellable>)loadMetadataType:(NSString *)type identifier:(NSString *)identifier completion:(void (^)(MSMetadata *, NSError *))completion {
    NSString *kind = [type isEqualToString:@"series"] ? @"series" : @"movie";
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    NSString *escaped = [identifier stringByAddingPercentEncodingWithAllowedCharacters:safe];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://v3-cinemeta.strem.io/meta/%@/%@.json", kind, escaped]];
    return [[MSHTTPClient sharedClient] fetchJSONURL:url completion:^(NSDictionary *document, NSError *error) {
        MSMetadata *item = [MSMetadata metadataWithDictionary:document[@"meta"] fallbackType:kind]; completion(item,error ?: (item ? nil : MSNetworkError(@"The title's details are unavailable.")));
    }];
}
@end
