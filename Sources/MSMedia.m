#import "MSMedia.h"
#import <math.h>

@implementation MSMedia
+ (instancetype)mediaWithIdentifier:(NSString *)identifier title:(NSString *)title type:(NSString *)type streamURL:(NSURL *)url format:(NSString *)format subtitleExtras:(NSDictionary<NSString *, NSString *> *)extras {
    MSMedia *item = [self new]; item->_identifier = [identifier copy]; item->_title = [title copy]; item->_mediaType = [type copy];
    item->_streamURL = url; item->_format = [format copy]; item->_subtitleExtras = [extras copy];
    item->_summary = @""; item->_attribution = @""; item->_license = @"";
    item->_libraryMetadata = @{@"metadataID":identifier ?: @"", @"type":type ?: @"movie", @"title":title ?: @""}; return item;
}

+ (NSArray<MSMedia *> *)bundledCatalogWithError:(NSError **)error {
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"DemoCatalog" withExtension:@"json"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url options:0 error:error] : nil;
    if (!data || data.length > 65536) {
        if (error && !*error) *error = [NSError errorWithDomain:@"MiniStream.Catalog" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The bundled sample could not be loaded."}];
        return @[];
    }
    id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![document isKindOfClass:NSDictionary.class] || ![document[@"items"] isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *items = [NSMutableArray array];
    for (id raw in document[@"items"]) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        BOOL valid = YES;
        for (NSString *key in @[@"id", @"title", @"summary", @"format", @"attribution", @"license", @"licenseURL", @"sourceURL", @"streamURL"]) {
            if (![raw[key] isKindOfClass:NSString.class] || [raw[key] length] == 0) valid = NO;
        }
        if (!valid || ![raw[@"year"] isKindOfClass:NSNumber.class] || ![raw[@"duration"] isKindOfClass:NSNumber.class]) continue;
        NSURL *stream = [NSURL URLWithString:raw[@"streamURL"]];
        NSURL *license = [NSURL URLWithString:raw[@"licenseURL"]];
        NSURL *source = [NSURL URLWithString:raw[@"sourceURL"]];
        if (!stream || !license || !source) continue;
        for (NSURL *address in @[stream, license, source]) {
            if (![address.scheme.lowercaseString isEqualToString:@"https"] || !address.host.length || address.user || address.password) valid = NO;
        }
        double duration = [raw[@"duration"] doubleValue];
        if (!valid || !isfinite(duration) || duration <= 0) continue;
        MSMedia *item = [MSMedia new];
        item->_identifier = [raw[@"id"] copy]; item->_title = [raw[@"title"] copy];
        item->_summary = [raw[@"summary"] copy]; item->_format = [raw[@"format"] copy];
        item->_attribution = [raw[@"attribution"] copy]; item->_license = [raw[@"license"] copy];
        item->_year = [raw[@"year"] integerValue]; item->_duration = duration;
        item->_streamURL = stream; item->_licenseURL = license; item->_sourceURL = source;
        item->_mediaType = @"movie"; item->_subtitleExtras = @{};
        item->_libraryMetadata = @{@"metadataID":item.identifier, @"type":@"movie", @"title":item.title, @"releaseInfo":[NSString stringWithFormat:@"%ld", (long)item.year]};
        [items addObject:item];
    }
    if (!items.count && error && !*error) *error = [NSError errorWithDomain:@"MiniStream.Catalog" code:2 userInfo:@{NSLocalizedDescriptionKey:@"The bundled sample is invalid."}];
    return items;
}
@end
