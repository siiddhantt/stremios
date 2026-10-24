#import "MSAddonsViewController.h"
#import "MSAddons.h"
#import "MSAddonImporter.h"
#import "MSHTTPClient.h"
#import "MSTheme.h"
#import <math.h>

@interface MSAddonsViewController ()
@property(nonatomic, strong) MSAddonStore *store;
@property(nonatomic, copy) NSArray<MSAddon *> *builtIns;
@property(nonatomic, copy) NSArray<MSAddon *> *custom;
@property(nonatomic, strong) id<MSCancellable> manifestRequest;
@property(nonatomic, strong) id<MSCancellable> importRequest;
@property(nonatomic, strong) UIBarButtonItem *addButton;
@property(nonatomic, strong) UILabel *noticeLabel;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL visible;
@property(nonatomic) BOOL importing;
@property(nonatomic,strong) MSAddon *editingAddon;
@end

@implementation MSAddonsViewController
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _store = MSAddonStore.sharedStore; _builtIns = @[]; _custom = @[];
        self.title = @"Add-ons"; self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }
    return self;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = MSBackgroundColor(); self.tableView.separatorColor = MSBackgroundColor();
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 70;
    self.addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addAddon)];
    self.addButton.accessibilityLabel = @"Add add-on"; self.navigationItem.rightBarButtonItem = self.addButton;
    self.navigationItem.leftItemsSupplementBackButton = YES;
    self.noticeLabel = MSLabel(UIFontTextStyleFootnote, MSSecondaryColor()); self.noticeLabel.textAlignment = NSTextAlignmentCenter;
    self.noticeLabel.numberOfLines = 0;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(addonsChanged:) name:MSAddonsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fontChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [self refreshEntries];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; self.visible = YES;
    [self.store reloadWithError:nil]; [self refreshEntries];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; self.visible = NO; [self cancelManifest]; }
- (void)inactive:(NSNotification *)notification { [self cancelManifest]; }
- (void)cancelManifest {
    self.generation++; [self.manifestRequest cancel]; self.manifestRequest = nil;
    [self.importRequest cancel]; self.importRequest = nil; self.importing = NO;
    self.loading = NO; self.addButton.enabled = YES; [self updateFooter];
    [self updateImportButton];
}
- (void)addonsChanged:(NSNotification *)notification { [self refreshEntries]; }
- (void)refreshEntries {
    NSMutableArray *builtIns = [NSMutableArray array]; NSMutableArray *custom = [NSMutableArray array];
    for (MSAddon *addon in self.store.addons) [(addon.builtIn ? builtIns : custom) addObject:addon];
    self.builtIns = builtIns; self.custom = custom; [self.tableView reloadData]; [self updateFooter]; [self updateImportButton];
}
- (void)updateImportButton {
    self.addButton.enabled = !self.loading && !self.importing;
    if ([MSAddonImporter hasPendingRetry] || self.importing) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:self.importing ? @"Importing…" : @"Retry Import" style:UIBarButtonItemStylePlain target:self action:@selector(retryImport)];
        self.navigationItem.leftBarButtonItem.enabled = !self.loading && !self.importing;
    } else self.navigationItem.leftBarButtonItem = nil;
}
- (void)retryImport {
    if (self.loading || self.importing || self.presentedViewController) return;
    self.importing = YES; [self updateImportButton]; [self updateFooter];
    __weak typeof(self) weakSelf = self;
    self.importRequest = [MSAddonImporter retryPendingConfigurationWithCompletion:^(NSUInteger added, NSError *error) {
        typeof(self) self = weakSelf; if (!self) return;
        self.importRequest = nil; self.importing = NO; [self refreshEntries];
        if (error) [self showError:error];
        else [self showMessage:added ? [NSString stringWithFormat:@"Imported %lu add-on%@.", (unsigned long)added, added == 1 ? @"" : @"s"] : @"Import complete. No new add-ons were needed."];
    }];
}
- (void)updateFooter {
    if (!self.isViewLoaded) return;
    if (self.importing) self.noticeLabel.text = @"Importing configured add-ons…";
    else if (self.loading) self.noticeLabel.text = @"Checking the add-on manifest…";
    else if (self.store.loadError) self.noticeLabel.text = self.store.loadError.localizedDescription;
    else self.noticeLabel.text = @"Tap a connection to update its configured link. Swipe left to remove it.";
    CGFloat width = MAX(self.tableView.bounds.size.width - 40, 100);
    CGSize size = [self.noticeLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width + 40, size.height + 32)];
    self.noticeLabel.frame = CGRectMake(20, 12, width, size.height); [footer addSubview:self.noticeLabel];
    self.tableView.tableFooterView = footer;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? self.builtIns.count : self.custom.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? @"Built-in" : @"Your add-ons"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return section == 1 && !self.custom.count ? @"Tap + to add a configured manifest address." : nil; }
- (MSAddon *)addonAtIndexPath:(NSIndexPath *)indexPath { return indexPath.section == 0 ? self.builtIns[indexPath.row] : self.custom[indexPath.row]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"addon"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"addon"];
        cell.backgroundColor = MSSurfaceColor(); cell.textLabel.textColor = MSPrimaryColor(); cell.detailTextLabel.textColor = MSSecondaryColor();
        cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
        cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    MSAddon *addon = [self addonAtIndexPath:indexPath];
    cell.textLabel.text = addon.name; cell.detailTextLabel.text = addon.manifestURL.host;
    cell.accessoryType = addon.builtIn ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.section == 1 && !self.loading && !self.importing; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 1) return;
    NSError *error = nil;
    if (![self.store removeAddon:[self addonAtIndexPath:indexPath] error:&error]) [self showError:error];
    [self refreshEntries];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if(path.section==1 && !self.loading && !self.importing){ self.editingAddon=[self addonAtIndexPath:path]; [self promptForAddon]; }
}
- (void)addAddon { self.editingAddon=nil; [self promptForAddon]; }
- (void)promptForAddon {
    if (self.loading || self.importing || self.presentedViewController) return;
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:self.editingAddon ? @"Update connection" : @"Add add-on" message:@"Paste its configured manifest link, including any service credentials. It is kept in protected app storage." preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://…/manifest.json"; field.keyboardType = UIKeyboardTypeURL;
        field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.spellCheckingType = UITextSpellCheckingTypeNo; field.smartQuotesType = UITextSmartQuotesTypeNo; field.smartDashesType = UITextSmartDashesTypeNo;
        field.secureTextEntry = YES; field.textContentType = @"";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.accessibilityLabel = @"Configured add-on manifest address";
    }];
    __weak UIAlertController *weakPrompt = prompt;
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { (void)action; weakPrompt.textFields.firstObject.text = @""; }]];
    __weak typeof(self) weakSelf = self;
    [prompt addAction:[UIAlertAction actionWithTitle:self.editingAddon ? @"Save" : @"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *input = weakPrompt.textFields.firstObject.text ?: @""; weakPrompt.textFields.firstObject.text = @"";
        typeof(self) self = weakSelf; if (!self) return;
        NSError *error = nil; NSURL *URL = [MSAddon manifestURLFromString:input error:&error];
        if (!URL) { dispatch_async(dispatch_get_main_queue(), ^{ [self showError:error]; }); return; }
        [self fetchManifest:URL];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}
- (void)fetchManifest:(NSURL *)URL {
    if (!self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.loading = YES; self.addButton.enabled = NO; [self updateFooter]; [self updateImportButton];
    NSUInteger generation = ++self.generation; __weak typeof(self) weakSelf = self;
    self.manifestRequest = [MSHTTPClient.sharedClient fetchJSONURL:URL completion:^(NSDictionary *manifest, NSError *networkError) {
        typeof(self) self = weakSelf;
        if (!self || !self.visible || generation != self.generation) return;
        self.manifestRequest = nil; self.loading = NO; self.addButton.enabled = YES;
        NSError *error = nil;
        if (!manifest || networkError) {
            // Network descriptions may contain the configured URL, so never display them.
            error = [NSError errorWithDomain:@"MiniStreamAddons" code:6 userInfo:@{NSLocalizedDescriptionKey:@"The add-on manifest could not be loaded. Check its address and your connection, then try again."}];
        } else if (!(self.editingAddon ? [self.store replaceAddon:self.editingAddon manifest:manifest URL:URL error:&error] : [self.store addManifest:manifest URL:URL error:&error])) {
            // The store returns only deliberate, URL-free validation/storage messages.
        }
        self.editingAddon=nil; [self refreshEntries]; if (error) [self showError:error];
    }];
}
- (void)showError:(NSError *)error {
    if (!self.visible || !error) return;
    [self showMessage:error.localizedDescription];
}
- (void)showMessage:(NSString *)message {
    if (!self.visible) return;
    if (self.presentedViewController) {
        __weak typeof(self) weakSelf = self;
        [self dismissViewControllerAnimated:NO completion:^{ [weakSelf showMessage:message]; }]; return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add-ons" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) ((UITableViewHeaderFooterView *)view).textLabel.textColor = MSSecondaryColor();
}
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) ((UITableViewHeaderFooterView *)view).textLabel.textColor = MSSecondaryColor();
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; if (fabs(self.tableView.tableFooterView.bounds.size.width - self.tableView.bounds.size.width) > 1) [self updateFooter]; }
- (void)fontChanged:(NSNotification *)notification { [self.tableView reloadData]; [self updateFooter]; }
- (void)dealloc { [self.manifestRequest cancel]; [self.importRequest cancel]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
