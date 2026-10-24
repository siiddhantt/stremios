#import "MSTorBoxSetupViewController.h"
#import "MSTorBoxClient.h"
#import "MSAddons.h"
#import "MSTheme.h"

@interface MSTorBoxSetupViewController ()
@property(nonatomic, strong) UITextField *keyField;
@property(nonatomic, strong) id<MSCancellable> request;
@property(nonatomic, copy) NSString *pendingKey;
@property(nonatomic, copy) NSString *statusText;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL loading, visible;
@end

@implementation MSTorBoxSetupViewController
- (instancetype)init { if ((self=[super initWithStyle:UITableViewStyleGrouped])) { self.title=@"Connect TorBox"; _statusText=@"Your key is checked directly with TorBox. You choose whether to share it with Torrentio in the next step."; } return self; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.tableView.backgroundColor=MSBackgroundColor(); self.tableView.separatorColor=MSBackgroundColor();
    self.tableView.rowHeight=UITableViewAutomaticDimension; self.tableView.estimatedRowHeight=60;
    self.keyField=[UITextField new]; self.keyField.translatesAutoresizingMaskIntoConstraints=NO;
    self.keyField.placeholder=@"TorBox API key"; self.keyField.secureTextEntry=YES; self.keyField.textContentType=@"";
    self.keyField.textColor=MSPrimaryColor(); self.keyField.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.keyField.adjustsFontForContentSizeCategory=YES;
    self.keyField.autocorrectionType=UITextAutocorrectionTypeNo; self.keyField.autocapitalizationType=UITextAutocapitalizationTypeNone;
    self.keyField.spellCheckingType=UITextSpellCheckingTypeNo; self.keyField.smartQuotesType=UITextSmartQuotesTypeNo; self.keyField.smartDashesType=UITextSmartDashesTypeNo;
    self.keyField.clearButtonMode=UITextFieldViewModeWhileEditing; self.keyField.accessibilityLabel=@"TorBox API key";
    [self.keyField.heightAnchor constraintGreaterThanOrEqualToConstant:32].active=YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; self.visible=YES; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; self.visible=NO; [self cancelSetup]; }
- (void)cancelSetup {
    self.generation++; [self.request cancel]; self.request=nil; self.pendingKey=nil; self.keyField.text=@"";
    self.loading=NO; self.keyField.enabled=YES; [self.tableView reloadData];
}
- (void)inactive:(NSNotification *)note {
    (void)note; [self cancelSetup];
    self.statusText=@"Setup paused. Paste your key again when you are ready.";
    if (self.presentedViewController) [self dismissViewControllerAnimated:NO completion:nil]; [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section==0 ? 1 : 2; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section==0 ? @"TorBox account" : nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; return section==0 ? @"Find your API key in your TorBox account settings. Treat it like a password." : self.statusText;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor=MSSurfaceColor(); cell.textLabel.textColor=MSAccentColor(); cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.adjustsFontForContentSizeCategory=YES; cell.textLabel.numberOfLines=0;
    if (path.section==0) {
        [self.keyField removeFromSuperview]; [cell.contentView addSubview:self.keyField];
        [NSLayoutConstraint activateConstraints:@[[self.keyField.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:20],[self.keyField.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-20],[self.keyField.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],[self.keyField.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12]]];
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text=path.row==0 ? (self.loading ? @"Connecting…" : @"Validate with TorBox") : @"Open TorBox account settings";
        cell.userInteractionEnabled=!self.loading; cell.textLabel.enabled=!self.loading; cell.accessibilityTraits=UIAccessibilityTraitButton;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if (path.section!=1 || self.loading) return;
    if (path.row==0) [self validateKey];
    else [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://torbox.app/settings"] options:@{} completionHandler:nil];
}
- (void)validateKey {
    if (!self.visible || self.loading || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || self.presentedViewController) return;
    NSError *error=nil; NSString *key=[MSTorBoxClient normalizedAPIKey:self.keyField.text ?: @"" error:&error];
    if (!key) { self.statusText=error.localizedDescription; [self.tableView reloadData]; return; }
    self.pendingKey=key; self.keyField.text=@""; [self.keyField resignFirstResponder]; self.keyField.enabled=NO; self.loading=YES;
    self.statusText=@"Checking your key with api.torbox.app…"; [self.tableView reloadData];
    NSUInteger generation=++self.generation; __weak typeof(self) weakSelf=self;
    self.request=[MSTorBoxClient validateAPIKey:key completion:^(NSError *failure) {
        typeof(self) self=weakSelf; if (!self || !self.visible || generation!=self.generation) return;
        self.request=nil; self.loading=NO; self.keyField.enabled=YES;
        if (failure) { self.pendingKey=nil; self.statusText=failure.localizedDescription; [self.tableView reloadData]; return; }
        self.statusText=@"TorBox accepted your key. Choose whether to connect Torrentio."; [self.tableView reloadData]; [self confirmTorrentio];
    }];
}
- (void)confirmTorrentio {
    if (!self.visible || !self.pendingKey.length || self.presentedViewController) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Connect Torrentio?" message:@"Torrentio (torrentio.strem.fun) is a separate service. Connecting sends it your API key, which permits access to your TorBox account. Playing a chosen source lets Torrentio obtain it through TorBox.\n\nThe configured link is kept in this app's protected storage. This setup hides uncached download links; availability still depends on your account and the connector." preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { typeof(self) self=weakSelf; self.pendingKey=nil; self.statusText=@"Nothing was added. Your key was not sent to Torrentio."; [self.tableView reloadData]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Connect Torrentio" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf connectTorrentio]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)connectTorrentio {
    if (!self.visible || self.loading || !self.pendingKey.length || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    NSString *key=self.pendingKey; self.pendingKey=nil; self.loading=YES; self.keyField.enabled=NO;
    self.statusText=@"Checking Torrentio's configured manifest…"; [self.tableView reloadData];
    NSUInteger generation=++self.generation; __weak typeof(self) weakSelf=self;
    self.request=[MSTorBoxClient fetchTorrentioManifestWithAPIKey:key completion:^(NSDictionary *manifest,NSURL *URL,NSError *error) {
        typeof(self) self=weakSelf; if (!self || !self.visible || generation!=self.generation) return;
        self.request=nil; self.loading=NO; self.keyField.enabled=YES;
        NSError *failure=error;
        if (!failure && ![MSAddonStore.sharedStore addManifest:manifest URL:URL error:&failure]) { /* Deliberate URL-free store error. */ }
        self.statusText=failure ? failure.localizedDescription : @"Torrentio is connected. Return to Discover, choose a title, then Sources.";
        [self.tableView reloadData];
    }];
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { (void)tableView;(void)section;if([view isKindOfClass:UITableViewHeaderFooterView.class])((UITableViewHeaderFooterView *)view).textLabel.textColor=MSSecondaryColor(); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { (void)tableView;(void)section;if([view isKindOfClass:UITableViewHeaderFooterView.class])((UITableViewHeaderFooterView *)view).textLabel.textColor=MSSecondaryColor(); }
- (void)dealloc { [self.request cancel]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
