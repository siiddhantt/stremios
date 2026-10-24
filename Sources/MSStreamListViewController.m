#import "MSStreamListViewController.h"
#import "MSCatalogClient.h"
#import "MSCatalogDetailViewController.h"
#import "MSHTTPClient.h"
#import "MSAddons.h"
#import "MSAddonsViewController.h"
#import "MSStream.h"
#import "MSMedia.h"
#import "MSLibraryStore.h"
#import "MSTheme.h"
#import "MSPlaybackRouting.h"
#import "MSPlaybackSourceResolver.h"
#import <math.h>
static NSString *const MSProviderFilterKey = @"MiniStream.sourceFilter.provider";
static NSString *const MSResolutionFilterKey = @"MiniStream.sourceFilter.resolution";
static NSString *const MSCompatibleFilterKey = @"MiniStream.sourceFilter.compatible";
// UISwitch's iOS 12 alignment rect is narrower than its native frame. Hosting
// that frame keeps the visible right edge aligned without altering the control.
@interface MSNativeSwitchHost : UIView
@property(nonatomic,strong) UISwitch *toggle;
- (instancetype)initWithToggle:(UISwitch *)toggle;
@end
@implementation MSNativeSwitchHost
- (instancetype)initWithToggle:(UISwitch *)toggle {
    if ((self = [super initWithFrame:CGRectZero])) {
        _toggle = toggle; toggle.translatesAutoresizingMaskIntoConstraints = YES; [self addSubview:toggle];
        [self setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    } return self;
}
- (CGSize)intrinsicContentSize { CGSize size = [self.toggle sizeThatFits:CGSizeZero]; return CGSizeMake(size.width,MAX(44,size.height)); }
- (void)layoutSubviews { [super layoutSubviews]; CGSize size = [self.toggle sizeThatFits:CGSizeZero]; self.toggle.frame = CGRectMake(self.bounds.size.width-size.width,(self.bounds.size.height-size.height)/2,size.width,size.height); }
@end
@interface MSStreamCell : UITableViewCell
@property(nonatomic,strong) UIView *card;
@property(nonatomic,strong) UILabel *nameLabel, *sourceLabel;
@end
@implementation MSStreamCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        self.backgroundColor = UIColor.clearColor; self.selectionStyle = UITableViewCellSelectionStyleNone;
        _card = [UIView new]; _card.backgroundColor = MSSurfaceColor(); _card.layer.cornerRadius = 12; _card.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:_card];
        _nameLabel = MSLabel(UIFontTextStyleHeadline,MSPrimaryColor()); _nameLabel.numberOfLines = 2;
        _sourceLabel = MSLabel(UIFontTextStyleSubheadline,MSSecondaryColor()); _sourceLabel.numberOfLines = 4;
        UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel,_sourceLabel]]; text.axis = UILayoutConstraintAxisVertical; text.spacing = 6; text.translatesAutoresizingMaskIntoConstraints = NO; [_card addSubview:text];
        UILabel *chevron = MSLabel(UIFontTextStyleTitle2,MSSecondaryColor()); chevron.text = @"›"; chevron.isAccessibilityElement = NO; chevron.translatesAutoresizingMaskIntoConstraints = NO; [_card addSubview:chevron];
        [NSLayoutConstraint activateConstraints:@[
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20], [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20], [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor], [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
            [text.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:16], [text.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-12], [text.topAnchor constraintEqualToAnchor:_card.topAnchor constant:14], [text.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-14],
            [chevron.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-16], [chevron.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor], [chevron.widthAnchor constraintEqualToConstant:12]
        ]]; self.isAccessibilityElement = YES; self.accessibilityTraits = UIAccessibilityTraitButton;
    } return self;
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated { [super setHighlighted:highlighted animated:animated]; self.card.alpha = highlighted ? 0.7 : 1; }
@end
@interface MSStreamListViewController ()
@property(nonatomic,strong) MSMetadata *metadata;
@property(nonatomic,strong) MSEpisode *episode;
@property(nonatomic,strong) NSMutableArray<MSStream *> *streams;
@property(nonatomic,copy) NSArray<MSStream *> *filteredStreams;
@property(nonatomic,strong) NSMutableArray<id<MSCancellable>> *requests;
@property(nonatomic) NSUInteger generation, pending, failures, nextAddon, activeRequests;
@property(nonatomic,copy) NSArray<MSAddon *> *addons;
@property(nonatomic,strong) UIView *header;
@property(nonatomic,strong) UILabel *heading, *message;
@property(nonatomic,strong) UIButton *providerButton, *resolutionButton, *clearButton;
@property(nonatomic,strong) UISwitch *compatibleSwitch;
@property(nonatomic,strong) UILabel *compatibilityLabel;
@property(nonatomic,strong) UIStackView *filterBar, *compatibilityRow;
@property(nonatomic,strong) NSLayoutConstraint *compatibilityWidth;
@property(nonatomic,copy) NSString *providerFilter, *resolutionFilter, *preferredBingeGroup, *preferredProvider;
@property(nonatomic) BOOL visible, loaded, needsReload, openingSource;
@property(nonatomic) NSUInteger playbackGeneration;
@property(nonatomic,strong) id<MSCancellable> playbackRequest;
@property(nonatomic,strong) UIBarButtonItem *sourceNavigationItem;
@property(nonatomic) BOOL exactResumePending, appeared, openingExactResume;
@property(nonatomic,copy) NSString *exactResumeFingerprint, *exactResumeVideoID, *resumeNotice;
@end
@implementation MSStreamListViewController
- (instancetype)initWithMetadata:(MSMetadata *)metadata episode:(MSEpisode *)episode {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _metadata = metadata; _episode = episode; _streams = [NSMutableArray array]; _filteredStreams = @[]; _requests = [NSMutableArray array]; self.title = @"Sources";
        [NSUserDefaults.standardUserDefaults registerDefaults:@{MSCompatibleFilterKey:@YES}];
        id provider = [NSUserDefaults.standardUserDefaults objectForKey:MSProviderFilterKey], resolution = [NSUserDefaults.standardUserDefaults objectForKey:MSResolutionFilterKey];
        _providerFilter = [provider isKindOfClass:NSString.class] && [provider length] <= 200 ? provider : @"";
        _resolutionFilter = [resolution isKindOfClass:NSString.class] && [@[@"2160p",@"1440p",@"1080p",@"720p",@"576p",@"480p",@"360p",@"unreported"] containsObject:resolution] ? resolution : @"";
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.tableView.backgroundColor = MSBackgroundColor(); self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 140;
    self.header = [[UIView alloc] initWithFrame:CGRectMake(0,0,320,1)];
    self.heading = MSLabel(UIFontTextStyleTitle2,MSPrimaryColor()); self.heading.accessibilityTraits |= UIAccessibilityTraitHeader;
    self.message = MSLabel(UIFontTextStyleFootnote,MSSecondaryColor());
    self.providerButton = MSButton(@"All providers ▾",NO); [self.providerButton addTarget:self action:@selector(chooseProvider) forControlEvents:UIControlEventTouchUpInside];
    self.resolutionButton = MSButton(@"Any resolution ▾",NO); [self.resolutionButton addTarget:self action:@selector(chooseResolution) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *filters = [[UIStackView alloc] initWithArrangedSubviews:@[self.providerButton,self.resolutionButton]]; filters.spacing = 12; filters.distribution = UIStackViewDistributionFillEqually;
    self.compatibilityLabel = MSLabel(UIFontTextStyleSubheadline,MSPrimaryColor()); self.compatibilityLabel.text = @"Hide unsupported";
    self.compatibleSwitch = [UISwitch new]; self.compatibleSwitch.onTintColor = MSAccentColor(); self.compatibleSwitch.on = [NSUserDefaults.standardUserDefaults boolForKey:MSCompatibleFilterKey]; self.compatibleSwitch.accessibilityLabel = @"Hide unsupported sources";
    [self.compatibleSwitch addTarget:self action:@selector(filtersChanged) forControlEvents:UIControlEventValueChanged];
    [self.compatibleSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.compatibleSwitch setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    MSNativeSwitchHost *switchHost = [[MSNativeSwitchHost alloc] initWithToggle:self.compatibleSwitch];
    self.compatibilityRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.compatibilityLabel,switchHost]]; self.compatibilityRow.alignment = UIStackViewAlignmentCenter; self.compatibilityRow.spacing = 12;
    NSLayoutConstraint *switchHeight = [self.compatibilityRow.heightAnchor constraintGreaterThanOrEqualToConstant:44]; switchHeight.priority = 999; switchHeight.active = YES;
    self.compatibilityWidth = [self.compatibilityRow.widthAnchor constraintEqualToConstant:200];
    self.filterBar = [[UIStackView alloc] initWithArrangedSubviews:@[filters,self.compatibilityRow]]; self.filterBar.spacing = 16; self.filterBar.alignment = UIStackViewAlignmentCenter;
    self.clearButton = [UIButton buttonWithType:UIButtonTypeSystem]; [self.clearButton setTitle:@"Clear filters" forState:UIControlStateNormal]; self.clearButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; self.clearButton.titleLabel.adjustsFontForContentSizeCategory = YES; self.clearButton.contentEdgeInsets = UIEdgeInsetsMake(8,10,8,10); self.clearButton.accessibilityLabel = @"Clear filters and show all sources";
    [self.clearButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.clearButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.clearButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.clearButton addTarget:self action:@selector(clearFilters) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *status = [[UIStackView alloc] initWithArrangedSubviews:@[self.message,self.clearButton]]; status.spacing = 12; status.alignment = UIStackViewAlignmentCenter;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.heading,self.filterBar,status]]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = NO; [self.header addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:self.header.topAnchor constant:20],[stack.bottomAnchor constraintEqualToAnchor:self.header.bottomAnchor constant:-20],[stack.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor constant:20],[stack.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor constant:-20]]];
    self.tableView.tableHeaderView = self.header; self.tableView.tableFooterView = [UIView new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Add-ons" style:UIBarButtonItemStylePlain target:self action:@selector(openAddons)];
    self.refreshControl = [UIRefreshControl new]; self.refreshControl.tintColor = MSAccentColor(); [self.refreshControl addTarget:self action:@selector(loadSources) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(addonsChanged:) name:MSAddonsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(active:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fontChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [self applyFilters];
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; self.visible = YES; self.appeared = NO; if (self.exactResumePending) [self reloadSourcesForExactResume:YES]; else if (!self.loaded || self.needsReload) [self loadSources]; else [self applyFilters]; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; self.appeared = YES; [self completeExactResumeIfReady]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; self.visible = NO; self.appeared = NO; [self cancelPlaybackOpening]; if (self.pending) { self.needsReload = YES; [self cancelRequests]; } }
- (void)inactive:(NSNotification *)note { [self cancelPlaybackOpening]; if (self.pending) { self.needsReload = YES; [self cancelRequests]; } }
- (void)active:(NSNotification *)note { if (self.visible && (!self.loaded || self.needsReload)) [self loadSources]; }
- (void)addonsChanged:(NSNotification *)note { self.needsReload = YES; if (self.visible) [self loadSources]; }
- (void)openAddons { [self.navigationController pushViewController:[MSAddonsViewController new] animated:YES]; }
- (NSString *)videoIdentifier { return self.episode.identifier ?: self.metadata.identifier; }
- (void)requestResumeFromLastSource {
    if (self.openingSource || self.presentedViewController) return;
    self.exactResumePending = YES; self.exactResumeFingerprint = [self.savedFingerprint copy]; self.exactResumeVideoID = [self.videoIdentifier copy]; self.resumeNotice = nil; self.needsReload = YES;
    if (self.visible && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self reloadSourcesForExactResume:YES];
}
- (void)cancelRequests { self.generation++; for (id<MSCancellable> request in self.requests) [request cancel]; [self.requests removeAllObjects]; self.pending = 0; self.activeRequests = 0; [self.refreshControl endRefreshing]; }
- (void)loadSources { [self reloadSourcesForExactResume:NO]; }
- (void)reloadSourcesForExactResume:(BOOL)preserveIntent {
    if (!self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { self.needsReload = YES; [self.refreshControl endRefreshing]; return; }
    BOOL exact = preserveIntent && self.exactResumePending;
    NSString *fingerprint = exact ? self.exactResumeFingerprint : nil, *videoID = exact ? self.exactResumeVideoID : nil;
    [self cancelPlaybackOpening]; [self cancelRequests]; [self.streams removeAllObjects]; self.failures = 0; self.loaded = NO; self.needsReload = NO;
    self.exactResumePending = exact; self.exactResumeFingerprint = fingerprint; self.exactResumeVideoID = videoID; self.resumeNotice = nil;
    NSMutableArray *addons = [NSMutableArray array];
    for (MSAddon *addon in MSAddonStore.sharedStore.addons) if ([addon supportsResource:@"stream" type:self.metadata.type identifier:self.videoIdentifier]) [addons addObject:addon];
    self.addons = addons; self.nextAddon = 0; self.pending = addons.count;
    if (!addons.count) { self.loaded = YES; [self.refreshControl endRefreshing]; }
    if (exact) [self showPlaybackCancel];
    [self applyFilters]; [self startNextRequests]; [self completeExactResumeIfReady];
}
- (void)startNextRequests {
    NSUInteger generation = self.generation; __weak typeof(self) weakSelf = self;
    while (self.visible && self.activeRequests < 2 && self.nextAddon < self.addons.count) {
        MSAddon *addon = self.addons[self.nextAddon++]; self.activeRequests++;
        NSURL *URL = [addon resourceURL:@"stream" type:self.metadata.type identifier:self.videoIdentifier extras:nil];
        id<MSCancellable> request = [MSHTTPClient.sharedClient fetchJSONURL:URL completion:^(NSDictionary *data,NSError *error) {
            typeof(self) self = weakSelf; if (!self || generation != self.generation) return;
            self.pending--; self.activeRequests--; if (error || ![data[@"streams"] isKindOfClass:NSArray.class]) self.failures++;
            NSArray *rows = [data[@"streams"] isKindOfClass:NSArray.class] ? data[@"streams"] : @[];
            NSUInteger perAddon = 0;
            for (id raw in rows) { if (self.streams.count >= 500 || perAddon++ >= 100) break; MSStream *stream = [MSStream streamWithDictionary:raw addonName:addon.name addonIdentifier:addon.identifier]; if (stream) [self.streams addObject:stream]; }
            if (!self.pending) { self.loaded = YES; [self.refreshControl endRefreshing]; [self.requests removeAllObjects]; }
            [self applyFilters]; [self startNextRequests]; [self completeExactResumeIfReady];
        }]; [self.requests addObject:request];
    }
}
- (NSString *)savedFingerprint { return [MSLibraryStore.sharedStore recordForIdentifier:self.videoIdentifier][@"sourceFingerprint"] ?: @""; }
- (void)completeExactResumeIfReady {
    if (!self.exactResumePending || !self.loaded || self.pending || !self.appeared || !self.visible || !self.viewIfLoaded.window ||
        (self.navigationController && self.navigationController.topViewController != self) || self.presentedViewController || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSString *fingerprint = self.exactResumeFingerprint;
    BOOL sameContent = [self.exactResumeVideoID isEqual:self.videoIdentifier];
    self.exactResumePending = NO; self.exactResumeFingerprint = nil; self.exactResumeVideoID = nil;
    // Search the complete fresh list. Browsing filters must not silently change
    // which file an explicit Resume refers to, or be changed by that Resume.
    NSMutableArray<MSStream *> *matches = [NSMutableArray array];
    if (sameContent && fingerprint.length) for (MSStream *stream in self.streams) if ([stream.sourceFingerprint isEqual:fingerprint]) [matches addObject:stream];
    MSStream *match = matches.count == 1 ? matches.firstObject : nil;
    [self finishPlaybackOpening];
    if (!sameContent || !fingerprint.length) self.resumeNotice = @"Choose a source to resume this video.";
    else if (matches.count > 1) self.resumeNotice = @"More than one source matches the previous file. Choose a source.";
    else if (!match || !match.canAttemptPlayback) self.resumeNotice = @"Previous source is no longer available. Choose another source.";
    else if (!match.filename.length || [match.filename containsString:@"[private link]"]) self.resumeNotice = @"The previous file cannot be identified reliably. Choose a source to resume.";
    else { [self playStream:match resume:YES exactResume:YES]; return; }
    [self applyFilters];
}
- (BOOL)isPreferred:(MSStream *)stream { return self.preferredBingeGroup.length && [stream.providerIdentifier isEqualToString:self.preferredProvider] && [stream.bingeGroup isEqualToString:self.preferredBingeGroup]; }
- (void)applyFilters {
    NSMutableArray *rows = [NSMutableArray array]; NSString *saved = self.savedFingerprint;
    for (MSStream *stream in self.streams) if ([stream matchesProvider:self.providerFilter resolution:self.resolutionFilter compatibleOnly:self.compatibleSwitch.on]) [rows addObject:stream];
    // Preserve each add-on's ordering except a known prior source / next-episode group.
    NSMutableArray *preferred = [NSMutableArray array], *remaining = [NSMutableArray array];
    for (MSStream *stream in rows) { if ((saved.length && [stream.sourceFingerprint isEqualToString:saved]) || [self isPreferred:stream]) [preferred addObject:stream]; else [remaining addObject:stream]; }
    [preferred addObjectsFromArray:remaining]; self.filteredStreams = preferred;
    self.heading.text = self.episode ? [NSString stringWithFormat:@"%@ · S%ld E%ld",self.metadata.title,(long)self.episode.season,(long)self.episode.episode] : self.metadata.title;
    NSString *providerTitle = @"All providers";
    if (self.providerFilter.length) { providerTitle = @"Selected provider"; for (MSAddon *addon in MSAddonStore.sharedStore.addons) if ([addon.identifier isEqualToString:self.providerFilter]) { providerTitle = addon.name; break; } }
    [self.providerButton setTitle:[providerTitle stringByAppendingString:@" ▾"] forState:UIControlStateNormal];
    [self.resolutionButton setTitle:[NSString stringWithFormat:@"%@ ▾",self.resolutionFilter.length ? ([self.resolutionFilter isEqualToString:@"unreported"] ? @"Unreported" : self.resolutionFilter) : @"Any resolution"] forState:UIControlStateNormal];
    if (self.openingSource) self.message.text = @"Opening video…";
    else if (self.exactResumePending) self.message.text = @"Finding the previous source…";
    else if (self.resumeNotice.length) self.message.text = self.resumeNotice;
    else if (self.pending) self.message.text = [NSString stringWithFormat:@"%lu sources shown · Loading…",(unsigned long)self.filteredStreams.count];
    else if (!self.addons.count) self.message.text = @"Add a configured stream add-on to see sources.";
    else if (!self.streams.count) self.message.text = self.failures ? @"Sources unavailable. Pull down to retry." : @"No sources for this title.";
    else if (!self.filteredStreams.count) self.message.text = @"No sources match these filters.";
    else self.message.text = [NSString stringWithFormat:@"%lu of %lu sources%@%@",(unsigned long)self.filteredStreams.count,(unsigned long)self.streams.count,self.failures ? @" · Some add-ons unavailable" : @"",self.streams.count >= 500 ? @" · List capped at 500" : @""];
    self.clearButton.hidden = !(self.providerFilter.length || self.resolutionFilter.length || (self.streams.count && !self.filteredStreams.count && self.compatibleSwitch.on));
    [self sizeHeader]; [self.tableView reloadData];
}
- (void)filtersChanged {
    [NSUserDefaults.standardUserDefaults setObject:self.providerFilter ?: @"" forKey:MSProviderFilterKey];
    [NSUserDefaults.standardUserDefaults setObject:self.resolutionFilter ?: @"" forKey:MSResolutionFilterKey];
    [NSUserDefaults.standardUserDefaults setBool:self.compatibleSwitch.on forKey:MSCompatibleFilterKey]; [self applyFilters];
}
- (void)clearFilters { self.providerFilter = @""; self.resolutionFilter = @""; self.compatibleSwitch.on = NO; [self filtersChanged]; }
- (void)chooseProvider {
    if (self.presentedViewController) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Provider" message:nil preferredStyle:UIAlertControllerStyleActionSheet]; __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"All providers" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { weakSelf.providerFilter = @""; [weakSelf filtersChanged]; }]];
    NSMutableSet *seen = [NSMutableSet set];
    for (MSAddon *addon in self.addons) if (![seen containsObject:addon.identifier]) { [seen addObject:addon.identifier]; [sheet addAction:[UIAlertAction actionWithTitle:addon.name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { weakSelf.providerFilter = addon.identifier; [weakSelf filtersChanged]; }]]; }
    [self presentFilter:sheet sender:self.providerButton];
}
- (void)chooseResolution {
    if (self.presentedViewController) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Reported resolution" message:nil preferredStyle:UIAlertControllerStyleActionSheet]; __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Any resolution" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { weakSelf.resolutionFilter = @""; [weakSelf filtersChanged]; }]];
    NSMutableSet *available = [NSMutableSet set]; for (MSStream *stream in self.streams) [available addObject:stream.reportedResolution.length ? stream.reportedResolution : @"unreported"];
    for (NSString *resolution in @[@"2160p",@"1440p",@"1080p",@"720p",@"576p",@"480p",@"360p",@"unreported"]) if ([available containsObject:resolution]) [sheet addAction:[UIAlertAction actionWithTitle:[resolution isEqualToString:@"unreported"] ? @"Unreported" : resolution style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { weakSelf.resolutionFilter = resolution; [weakSelf filtersChanged]; }]];
    [self presentFilter:sheet sender:self.resolutionButton];
}
- (void)presentFilter:(UIAlertController *)sheet sender:(UIView *)sender { [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; sheet.popoverPresentationController.sourceView = sender; sheet.popoverPresentationController.sourceRect = sender.bounds; [self presentViewController:sheet animated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.filteredStreams.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    MSStreamCell *cell = [tableView dequeueReusableCellWithIdentifier:@"stream"] ?: [[MSStreamCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"stream"];
    MSStream *stream = self.filteredStreams[path.row]; cell.nameLabel.text = stream.name;
    NSString *match = [stream.sourceFingerprint isEqualToString:self.savedFingerprint] ? @"Previously played · " : [self isPreferred:stream] ? @"Same release group · " : @"";
    cell.sourceLabel.text = [NSString stringWithFormat:@"%@%@ · %@\n%@%@",match,stream.reportedResolution.length ? stream.reportedResolution : @"Resolution unreported",stream.codecLabel,stream.canAttemptPlayback ? @"" : @"Unsupported · ",stream.detail];
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@. %@",cell.nameLabel.text,cell.sourceLabel.text]; cell.accessibilityHint = stream.canAttemptPlayback ? @"Review and choose Play" : stream.compatibility; return cell;
}
- (NSDictionary *)libraryMetadata {
    NSMutableDictionary *record = [@{@"metadataID":self.metadata.identifier,@"type":self.metadata.type,@"title":self.metadata.title,@"releaseInfo":self.metadata.releaseInfo ?: @""} mutableCopy];
    if (self.metadata.posterURL) record[@"posterURL"] = self.metadata.posterURL.absoluteString;
    if (self.episode) { record[@"episodeTitle"] = self.episode.title; record[@"season"] = @(self.episode.season); record[@"episode"] = @(self.episode.episode); }
    return record;
}
- (void)finishPlaybackOpening {
    self.playbackRequest = nil; self.openingSource = NO; self.openingExactResume = NO;
    self.tableView.userInteractionEnabled = YES;
    if (self.sourceNavigationItem) self.navigationItem.rightBarButtonItem = self.sourceNavigationItem;
    self.sourceNavigationItem = nil; [self applyFilters];
}
- (void)showPlaybackCancel {
    if (!self.sourceNavigationItem) self.sourceNavigationItem = self.navigationItem.rightBarButtonItem;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelPlaybackOpening)];
    self.tableView.userInteractionEnabled = NO;
}
- (void)cancelPlaybackOpening {
    BOOL cancelledResume = self.exactResumePending || self.openingExactResume;
    if (self.exactResumePending && self.pending) { [self cancelRequests]; self.loaded = YES; self.needsReload = NO; }
    self.exactResumePending = NO; self.exactResumeFingerprint = nil; self.exactResumeVideoID = nil;
    self.playbackGeneration++; [self.playbackRequest cancel];
    if (cancelledResume) self.resumeNotice = @"Resume cancelled. Choose a source.";
    if (self.openingSource || self.sourceNavigationItem) [self finishPlaybackOpening];
}
- (void)playStream:(MSStream *)stream resume:(BOOL)resume { [self playStream:stream resume:resume exactResume:NO]; }
- (void)playStream:(MSStream *)stream resume:(BOOL)resume exactResume:(BOOL)exactResume {
    if (!stream.canAttemptPlayback || self.presentedViewController || self.openingSource || !self.viewIfLoaded.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.openingSource = YES; self.openingExactResume = exactResume; self.resumeNotice = nil; NSUInteger generation = ++self.playbackGeneration;
    [self showPlaybackCancel]; [self applyFilters];
    __weak typeof(self) weakSelf = self;
    // Only the explicitly selected source is inspected. Catalog/list loading
    // must never resolve, prebuffer or download unselected playback URLs.
    self.playbackRequest = [MSPlaybackSourceResolver.sharedResolver resolveURL:stream.URL completion:^(MSResolvedPlaybackSource *resolved, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || generation != self.playbackGeneration || !self.openingSource) return;
        [self finishPlaybackOpening];
        if (!self.viewIfLoaded.window || (self.navigationController && self.navigationController.topViewController != self) || self.presentedViewController || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        if (!resolved || error) {
            if (exactResume) { self.resumeNotice = @"Previous source is no longer available. Choose another source."; [self applyFilters]; }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn’t open video" message:error.localizedDescription ?: @"This source is unavailable. Choose another source or try again." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            __weak UIAlertController *weakAlert = alert;
            [alert addAction:[UIAlertAction actionWithTitle:@"Try Again" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [weakSelf playStream:stream resume:resume afterAlert:weakAlert]; }]];
            [self presentViewController:alert animated:YES completion:nil]; return;
        }
        [self presentStream:stream resolved:resolved resume:resume];
    }];
}
- (void)presentStream:(MSStream *)stream resolved:(MSResolvedPlaybackSource *)resolved resume:(BOOL)resume {
    NSString *title = self.episode ? [NSString stringWithFormat:@"%@ · S%ld E%ld",self.metadata.title,(long)self.episode.season,(long)self.episode.episode] : self.metadata.title;
    MSMedia *media = [MSMedia mediaWithIdentifier:self.videoIdentifier title:title type:self.metadata.type streamURL:resolved.URL format:stream.name subtitleExtras:stream.subtitleExtras];
    media.streamSubtitles = stream.providedSubtitles; media.libraryMetadata = self.libraryMetadata; media.sourceFingerprint = stream.sourceFingerprint;
    [MSLibraryStore.sharedStore registerMetadata:media.libraryMetadata forVideoIdentifier:self.videoIdentifier];
    UIViewController<MSPlaybackControlling> *player = MSMakePlaybackController(media,resolved.container,resume);
    NSString *nextTitle = nil; dispatch_block_t nextHandler = nil;
    NSUInteger episodeIndex = self.episode ? [self.metadata.episodes indexOfObjectIdenticalTo:self.episode] : NSNotFound;
    if (episodeIndex != NSNotFound && episodeIndex + 1 < self.metadata.episodes.count) {
        MSEpisode *next = self.metadata.episodes[episodeIndex+1]; nextTitle = [NSString stringWithFormat:@"S%ld E%ld · %@",(long)next.season,(long)next.episode,next.title];
        __weak typeof(self) weakSelf = self;
        nextHandler = ^{
            typeof(self) self = weakSelf; if (!self) return;
            self.episode = next; self.preferredProvider = stream.providerIdentifier; self.preferredBingeGroup = stream.bingeGroup;
            // Select lists only. The next video's resolver still needs another explicit Play.
            self.providerFilter = stream.providerIdentifier; self.resolutionFilter = stream.reportedResolution; [self filtersChanged];
            for (UIViewController *controller in self.navigationController.viewControllers) if ([controller isKindOfClass:MSCatalogDetailViewController.class]) ((MSCatalogDetailViewController *)controller).preferredVideoIdentifier = next.identifier;
            self.needsReload = YES; [self loadSources];
        };
    }
    player.nextEpisodeTitle = nextTitle; player.nextEpisodeHandler = nextHandler;
    [self presentViewController:player animated:YES completion:nil];
}
- (void)playStream:(MSStream *)stream resume:(BOOL)resume afterAlert:(UIAlertController *)alert {
    __weak typeof(self) weakSelf = self;
    void (^presentPlayer)(void) = ^{
        typeof(self) self = weakSelf;
        // A dismissed action can outlive navigation away from this source list.
        if (!self || !self.viewIfLoaded.window || (self.navigationController && self.navigationController.topViewController != self)) return;
        [self playStream:stream resume:resume];
    };
    // UIKit automatically dismisses an action's alert. A second dismiss call
    // after that transition has finished need not invoke its completion block.
    if (!alert || !alert.presentingViewController || self.presentedViewController != alert) { presentPlayer(); return; }
    id<UIViewControllerTransitionCoordinator> transition = alert.transitionCoordinator;
    if (alert.isBeingDismissed && transition) {
        BOOL registered = [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if (!context.isCancelled) {
                // UIKit completes presentation relationships after its transition.
                dispatch_async(dispatch_get_main_queue(), presentPlayer);
            }
        }];
        if (registered) return;
    }
    // The action arrived before implicit dismissal. Own this dismissal's
    // completion instead of asking an unrelated presenter to dismiss again.
    [alert dismissViewControllerAnimated:YES completion:presentPlayer];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if ((NSUInteger)path.row >= self.filteredStreams.count || self.presentedViewController || self.openingSource || self.exactResumePending) return; MSStream *stream = self.filteredStreams[path.row];
    NSString *format = [NSString stringWithFormat:@"%@ · %@",stream.reportedResolution.length ? stream.reportedResolution : @"Resolution unreported",stream.codecLabel];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:stream.name message:[NSString stringWithFormat:@"%@\n\n%@\n\n%@",format,stream.detail,stream.compatibility] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (stream.canAttemptPlayback) {
        NSDictionary *record = [MSLibraryStore.sharedStore recordForIdentifier:self.videoIdentifier]; NSTimeInterval position = [record[@"duration"] doubleValue] > 0 ? [MSLibraryStore.sharedStore resumeFor:self.videoIdentifier duration:[record[@"duration"] doubleValue]] : [record[@"position"] doubleValue];
        __weak typeof(self) weakSelf = self;
        __weak UIAlertController *weakAlert = alert;
        void (^play)(BOOL) = ^(BOOL resume) { [weakSelf playStream:stream resume:resume afterAlert:weakAlert]; };
        [alert addAction:[UIAlertAction actionWithTitle:position > 0 ? [NSString stringWithFormat:@"Resume · %@",MSTimeDescription(position)] : @"Play" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { play(YES); }]];
        if (position > 0) [alert addAction:[UIAlertAction actionWithTitle:@"Play from beginning" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { play(NO); }]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)sizeHeader {
    CGFloat width = self.tableView.bounds.size.width; if (!self.header || width <= 0) return;
    BOOL stacked = width < 620 || UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    self.filterBar.axis = stacked ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.filterBar.alignment = stacked ? UIStackViewAlignmentFill : UIStackViewAlignmentCenter;
    self.compatibilityWidth.active = !stacked;
    CGFloat switchWidth = MAX(self.compatibleSwitch.intrinsicContentSize.width, [self.compatibleSwitch sizeThatFits:CGSizeZero].width);
    switchWidth = MAX(switchWidth,self.compatibleSwitch.bounds.size.width);
    self.compatibilityWidth.constant = self.compatibilityLabel.intrinsicContentSize.width + 12 + switchWidth;
    self.header.frame = CGRectMake(0,0,width,self.header.frame.size.height);
    CGFloat height = [self.header systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (fabs(height-self.header.frame.size.height) > 0.01) { self.header.frame = CGRectMake(0,0,width,height); self.tableView.tableHeaderView = self.header; }
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self sizeHeader]; }
- (void)fontChanged:(NSNotification *)note { [self sizeHeader]; [self.tableView reloadData]; }
- (void)dealloc { [self.playbackRequest cancel]; [NSNotificationCenter.defaultCenter removeObserver:self]; for (id<MSCancellable> request in self.requests) [request cancel]; }
@end
