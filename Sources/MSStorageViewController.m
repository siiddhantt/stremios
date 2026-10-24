#import "MSStorageViewController.h"
#import "MSImageLoader.h"
#import "MSTheme.h"
// Logical sizes inside this app only; do not traverse links outside its container.
static unsigned long long MSFolderBytes(NSURL *root) {
    if (!root) return 0; unsigned long long total=0;
    NSDirectoryEnumerator *enumerator=[NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLFileSizeKey,NSURLIsSymbolicLinkKey] options:0 errorHandler:^BOOL(NSURL *URL,NSError *error){return YES;}];
    for (NSURL *URL in enumerator) {
        NSDictionary *values=[URL resourceValuesForKeys:@[NSURLIsRegularFileKey,NSURLFileSizeKey,NSURLIsSymbolicLinkKey] error:nil];
        if ([values[NSURLIsSymbolicLinkKey] boolValue]) { [enumerator skipDescendants]; continue; }
        if ([values[NSURLIsRegularFileKey] boolValue]) total+=[values[NSURLFileSizeKey] unsignedLongLongValue];
    } return total;
}
@interface MSStorageViewController ()
@property(nonatomic,copy) NSDictionary *sizes;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL clearing;
@end
@implementation MSStorageViewController
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"Storage"; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refreshStorage]; }
- (void)refreshStorage {
    NSUInteger generation=++self.generation; __weak typeof(self) weakSelf=self;
    NSURL *bundle=NSBundle.mainBundle.bundleURL;
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *library=[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *caches=[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        unsigned long long app=MSFolderBytes(bundle), docs=MSFolderBytes(documents), lib=MSFolderBytes(library), cache=MSFolderBytes(caches), temporary=MSFolderBytes([NSURL fileURLWithPath:NSTemporaryDirectory()]);
        dispatch_async(dispatch_get_main_queue(),^{
            [MSImageLoader.sharedLoader storageStatsWithCompletion:^(NSDictionary<NSString *,NSNumber *> *stats){
                typeof(self) self=weakSelf; if (!self || generation!=self.generation) return;
                self.sizes=@{@"app":@(app),@"data":@(docs+lib+temporary),@"artwork":stats[@"artworkDiskBytes"]?:@0,@"cache":@(cache+temporary),@"limit":stats[@"artworkDiskLimitBytes"]?:@0}; [self.tableView reloadData];
            }];
        });
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0?2:section==1?3:1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return @[@"On this iPad",@"Artwork cache",@""][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section==0) return @"File sizes inside MiniStream. App data includes the cache below.";
    if (section==1) return @"Posters and artwork are kept for up to 30 days. Videos are not cached.";
    return nil;
}
- (NSString *)bytes:(NSNumber *)value { return self.sizes?[NSByteCountFormatter stringFromByteCount:value.longLongValue countStyle:NSByteCountFormatterCountStyleFile]:@"Calculating…"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    MSSettingsCell *cell=[tableView dequeueReusableCellWithIdentifier:@"storage"]?:[[MSSettingsCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"storage"];
    cell.nameLabel.textColor=MSPrimaryColor(); cell.valueLabel.textColor=MSSecondaryColor(); cell.valueLabel.text=nil;
    if (path.section==0) { cell.nameLabel.text=path.row==0?@"Application":@"App data"; cell.valueLabel.text=[self bytes:self.sizes[path.row==0?@"app":@"data"]]; }
    else if (path.section==1) { cell.nameLabel.text=@[@"Artwork",@"Maximum size",@"Other temporary data"][path.row];
        unsigned long long cache=[self.sizes[@"cache"] unsignedLongLongValue], art=[self.sizes[@"artwork"] unsignedLongLongValue];
        cell.valueLabel.text=[self bytes:path.row==0?self.sizes[@"artwork"]:path.row==1?self.sizes[@"limit"]:@(cache>art?cache-art:0)];
    } else { cell.nameLabel.text=self.clearing?@"Clearing artwork…":@"Clear artwork cache"; cell.nameLabel.textColor=MSAccentColor(); }
    [cell position:path.row count:[self tableView:tableView numberOfRowsInSection:path.section] disclosure:NO];
    if (path.section==2) cell.accessibilityTraits=UIAccessibilityTraitButton;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if (path.section!=2 || self.clearing) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Clear artwork cache?" message:@"Posters will load again when needed. Saved titles, playback positions and connections stay." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear cache" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        typeof(self) self=weakSelf; if (!self) return; self.clearing=YES; ++self.generation; [self.tableView reloadData];
        [MSImageLoader.sharedLoader clearCacheWithCompletion:^{ typeof(self) self=weakSelf; self.clearing=NO; [self refreshStorage]; }];
    }]]; [self presentViewController:alert animated:YES completion:nil];
}
@end
