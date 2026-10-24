#import "MSCatalogDetailViewController.h"
#import "MSImageLoader.h"
#import "MSLibraryStore.h"
#import "MSTheme.h"
#import "MSPlayerControls.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// Sample a tiny bitmap only when artwork changes. A restrained dark tint keeps
// the backdrop continuous through the page without blur or per-frame work.
static UIColor *MSBackdropColor(UIImage *image) {
    CGImageRef source = image.CGImage; if (!source) return MSBackgroundColor();
    unsigned char pixels[8*8*4] = {0}; CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels,8,8,8,8*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space); if (!context) return MSBackgroundColor();
    CGContextDrawImage(context,CGRectMake(0,0,8,8),source); CGContextRelease(context);
    double red=0,green=0,blue=0,weight=0;
    for (NSUInteger i=0;i<64;i++) { double alpha=pixels[i*4+3]/255.0; red+=pixels[i*4]/255.0; green+=pixels[i*4+1]/255.0; blue+=pixels[i*4+2]/255.0; weight+=alpha; }
    if (weight<1) return MSBackgroundColor();
    red/=weight; green/=weight; blue/=weight;
    double peak=MAX(red,MAX(green,blue)); double scale=peak>0.001 ? 0.065/peak : 0;
    return [UIColor colorWithRed:0.025+red*scale green:0.025+green*scale blue:0.025+blue*scale alpha:1];
}

@interface MSCatalogHeroView : UIView
@property(nonatomic,strong) UIImageView *artwork;
@property(nonatomic,strong) CAGradientLayer *gradient;
- (void)setBackdropColor:(UIColor *)color;
- (void)positionFadeForTitleY:(CGFloat)titleY bodyY:(CGFloat)bodyY;
@end
@implementation MSCatalogHeroView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = MSBackgroundColor(); self.clipsToBounds = YES;
        _artwork = [UIImageView new]; _artwork.contentMode = UIViewContentModeScaleAspectFit;
        _artwork.clipsToBounds = YES; _artwork.isAccessibilityElement = NO; [self addSubview:_artwork];
        _gradient = [CAGradientLayer layer]; [self.layer addSublayer:_gradient];
        [self setBackdropColor:MSBackgroundColor()];
    }
    return self;
}
- (void)setBackdropColor:(UIColor *)color {
    self.backgroundColor=color;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.gradient.colors=@[(__bridge id)[color colorWithAlphaComponent:0.03].CGColor,(__bridge id)[color colorWithAlphaComponent:0.12].CGColor,(__bridge id)[color colorWithAlphaComponent:0.88].CGColor,(__bridge id)color.CGColor];
    self.gradient.locations=@[@0,@0.36,@0.83,@1]; [CATransaction commit];
}
- (void)layoutSubviews { [super layoutSubviews]; self.artwork.frame=self.bounds; [CATransaction begin]; [CATransaction setDisableActions:YES]; self.gradient.frame=self.bounds; [CATransaction commit]; }
- (void)positionFadeForTitleY:(CGFloat)titleY bodyY:(CGFloat)bodyY {
    CGFloat height=MAX(1,self.bounds.size.height);
    CGFloat readable=MIN(0.83,MAX(0.4,titleY/height-0.02));
    CGFloat solid=MIN(1,MAX(readable+0.08,bodyY/height));
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.gradient.locations=@[@0,@(MAX(0.12,readable-0.28)),@(readable),@(solid)];
    [CATransaction commit];
}
@end

@interface MSCatalogDetailViewController ()
@property(nonatomic,strong) MSMetadata *metadata;
@property(nonatomic,strong) MSCatalogClient *client;
@property(nonatomic,copy) MSVideoSelection selection;
@property(nonatomic,strong) id<MSCancellable> metadataRequest, posterRequest, logoRequest;
@property(nonatomic,strong) UIView *header;
@property(nonatomic,strong) UIView *loadingView;
@property(nonatomic,strong) UIActivityIndicatorView *loadingSpinner;
@property(nonatomic,strong) NSTimer *revealDeadline, *spinnerDelay;
@property(nonatomic,strong) MSCatalogHeroView *hero;
@property(nonatomic,strong) UILabel *titleLabel, *infoLabel, *summaryLabel, *statusLabel, *episodeLabel;
@property(nonatomic,strong) UIView *logoContainer;
@property(nonatomic,strong) UIImageView *logoView;
@property(nonatomic,strong) NSLayoutConstraint *logoHeight;
@property(nonatomic,strong) UIButton *playButton, *retryButton, *seasonButton, *previousButton, *nextButton, *artworkRetryButton, *summaryButton;
@property(nonatomic,strong) UIStackView *episodeControls;
@property(nonatomic,strong) UIStackView *body, *heroText;
@property(nonatomic,strong) UIColor *backdropColor;
@property(nonatomic,readwrite) BOOL resumeRequested;
@property(nonatomic,copy) NSArray<NSNumber *> *seasons;
@property(nonatomic,copy) NSArray<MSEpisode *> *episodes;
@property(nonatomic,strong) NSNumber *selectedSeason;
@property(nonatomic,strong) MSEpisode *selectedEpisode;
@property(nonatomic,strong) NSURL *displayedArtworkURL;
@property(nonatomic,strong) NSURL *displayedLogoURL, *failedLogoURL;
@property(nonatomic) NSUInteger generation, posterGeneration, logoGeneration;
@property(nonatomic) BOOL loaded, loading, failed, visible, artworkFailed, triedArtworkFallback, sizingHeader, summaryExpanded;
@property(nonatomic) BOOL contentRevealed;
@property(nonatomic,strong) UIButton *backNavigationButton,*saveNavigationButton;
@property(nonatomic,weak) UINavigationBar *styledNavigationBar;
@property(nonatomic,strong) UIImage *priorNavigationBackground,*priorCompactNavigationBackground,*priorNavigationShadow;
@property(nonatomic,strong) UIColor *priorNavigationBarTint,*priorNavigationBackgroundColor;
@property(nonatomic) BOOL navigationStyleCaptured,priorNavigationTranslucent;
@end

@implementation MSCatalogDetailViewController
- (instancetype)initWithMetadata:(MSMetadata *)metadata catalogClient:(MSCatalogClient *)client videoSelection:(MSVideoSelection)selection {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _metadata = metadata; _client = client; _selection = [selection copy]; _episodes = @[]; _seasons = @[];
        self.title = metadata.title; self.navigationItem.title = @""; self.navigationItem.hidesBackButton = YES; self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }
    return self;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)setPreferredVideoIdentifier:(NSString *)identifier {
    _preferredVideoIdentifier = [identifier copy];
    if (self.loaded) for (MSEpisode *episode in self.metadata.episodes) if ([episode.identifier isEqualToString:identifier]) { [self focusEpisode:episode]; break; }
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout=UIRectEdgeAll;self.extendedLayoutIncludesOpaqueBars=YES;
    self.tableView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.backNavigationButton=[self navigationButtonWithIcon:@"nav-back" label:@"Back" action:@selector(goBack)];
    self.saveNavigationButton=[self navigationButtonWithIcon:@"save" label:@"Save to favorites" action:@selector(toggleFavorite)];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]initWithCustomView:self.backNavigationButton];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithCustomView:self.saveNavigationButton];
    if(@available(iOS 13.0,*)){UINavigationBarAppearance *appearance=[UINavigationBarAppearance new];[appearance configureWithTransparentBackground];self.navigationItem.standardAppearance=appearance;self.navigationItem.compactAppearance=appearance;self.navigationItem.scrollEdgeAppearance=appearance;if(@available(iOS 15.0,*))self.navigationItem.compactScrollEdgeAppearance=appearance;}

    self.tableView.backgroundColor = MSBackgroundColor(); self.tableView.separatorColor = MSSurfaceColor();
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 72; self.tableView.separatorInset = UIEdgeInsetsMake(0,20,0,20); self.tableView.cellLayoutMarginsFollowReadableWidth = YES; self.tableView.tableFooterView = [UIView new];
    self.header = [[UIView alloc] initWithFrame:CGRectMake(0,0,self.tableView.bounds.size.width,1)];
    self.hero = [MSCatalogHeroView new]; [self.header addSubview:self.hero];
    self.titleLabel = MSLabel(UIFontTextStyleTitle1, MSPrimaryColor()); self.titleLabel.accessibilityTraits |= UIAccessibilityTraitHeader;
    self.infoLabel = MSLabel(UIFontTextStyleSubheadline, MSSecondaryColor());
    self.logoContainer = [UIView new]; self.logoContainer.hidden = YES;
    self.logoContainer.isAccessibilityElement = YES; self.logoContainer.accessibilityTraits = UIAccessibilityTraitHeader;
    self.logoView = [UIImageView new]; self.logoView.contentMode = UIViewContentModeScaleAspectFit;
    self.logoView.isAccessibilityElement = NO; [self.logoContainer addSubview:self.logoView];
    self.logoHeight = [self.logoContainer.heightAnchor constraintEqualToConstant:64]; self.logoHeight.priority = 999; self.logoHeight.active = YES;
    self.heroText=[[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel,self.logoContainer,self.infoLabel]];
    self.heroText.axis=UILayoutConstraintAxisVertical; self.heroText.spacing=8; [self.header addSubview:self.heroText];
    self.playButton = MSButton(@"Play",YES); [self.playButton addTarget:self action:@selector(playSelected) forControlEvents:UIControlEventTouchUpInside]; self.playButton.accessibilityHint = @"Choose a playback source";
    self.episodeLabel = MSLabel(UIFontTextStyleHeadline,MSPrimaryColor());
    self.previousButton = MSButton(@"Previous",NO); [self.previousButton addTarget:self action:@selector(previousEpisode) forControlEvents:UIControlEventTouchUpInside];
    self.nextButton = MSButton(@"Next episode",NO); [self.nextButton addTarget:self action:@selector(nextEpisode) forControlEvents:UIControlEventTouchUpInside];
    self.episodeControls = [[UIStackView alloc] initWithArrangedSubviews:@[self.previousButton,self.nextButton]]; self.episodeControls.spacing = 12; self.episodeControls.distribution = UIStackViewDistributionFillEqually;
    self.summaryLabel = MSLabel(UIFontTextStyleBody,MSSecondaryColor()); self.summaryLabel.numberOfLines = 2;
    self.summaryLabel.lineBreakMode=NSLineBreakByTruncatingTail;
    self.summaryButton=[UIButton buttonWithType:UIButtonTypeSystem]; self.summaryButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeft;
    self.summaryButton.titleLabel.font=MSFont(UIFontTextStyleFootnote,UIFontWeightSemibold); self.summaryButton.titleLabel.adjustsFontForContentSizeCategory=YES;
    self.summaryButton.tintColor=MSAccentColor(); [self.summaryButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [self.summaryButton addTarget:self action:@selector(toggleSummary) forControlEvents:UIControlEventTouchUpInside];
    self.statusLabel = MSLabel(UIFontTextStyleFootnote,MSSecondaryColor());
    self.retryButton = MSButton(@"Retry details",NO); [self.retryButton addTarget:self action:@selector(loadDetails) forControlEvents:UIControlEventTouchUpInside];
    self.artworkRetryButton = MSButton(@"Retry artwork",NO); [self.artworkRetryButton addTarget:self action:@selector(retryArtwork) forControlEvents:UIControlEventTouchUpInside];
    self.seasonButton = MSButton(@"Choose season",NO); [self.seasonButton addTarget:self action:@selector(chooseSeason) forControlEvents:UIControlEventTouchUpInside];
    self.body = [[UIStackView alloc] initWithArrangedSubviews:@[self.episodeLabel,self.playButton,self.summaryLabel,self.summaryButton,self.episodeControls,self.statusLabel,self.retryButton,self.artworkRetryButton,self.seasonButton]];
    self.body.axis = UILayoutConstraintAxisVertical; self.body.spacing = 12;
    [self.header addSubview:self.body];
    // The table header owns its outer frames. The inner stack lays out Dynamic
    // Type content at a measured width, avoiding a fixed-height hero/title trade.
    self.tableView.tableHeaderView = self.header;
    self.header.hidden = YES; self.header.accessibilityElementsHidden = YES;
    self.tableView.scrollEnabled = NO;
    self.loadingView = [UIView new]; self.loadingView.backgroundColor = MSBackgroundColor();
    self.loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.loadingSpinner.hidesWhenStopped = YES; self.loadingSpinner.isAccessibilityElement = YES;
    self.loadingSpinner.accessibilityLabel = @"Loading title";
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingView addSubview:self.loadingSpinner];
    [NSLayoutConstraint activateConstraints:@[[self.loadingSpinner.centerXAnchor constraintEqualToAnchor:self.loadingView.centerXAnchor], [self.loadingSpinner.centerYAnchor constraintEqualToAnchor:self.loadingView.centerYAnchor]]];
    self.tableView.backgroundView = self.loadingView;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fontChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(active:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(libraryChanged:) name:MSLibraryDidChangeNotification object:nil];
    [self renderMetadata];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; self.visible = YES; [self applyArtworkNavigationStyle]; [self beginInitialReveal]; [self renderMetadata]; if (self.loaded) { [self loadPoster]; [self loadLogo]; [self revealIfReady]; } else if (!self.failed) [self loadDetails]; }
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];self.visible=NO;[self cancelRequests];[self restoreNavigationStyle];
    id<UIViewControllerTransitionCoordinator> transition=self.transitionCoordinator;
    if(transition){__weak typeof(self) weakSelf=self;[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){typeof(self) self=weakSelf;if(!self)return;if(context.isCancelled&&self.navigationController.topViewController==self)[self applyArtworkNavigationStyle];else if(!context.isCancelled)self.navigationStyleCaptured=NO;}];}
    else self.navigationStyleCaptured=NO;
}
- (UIButton *)navigationButtonWithIcon:(NSString *)icon label:(NSString *)label action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.frame=CGRectMake(0,0,44,44);button.layer.cornerRadius=22;
    button.backgroundColor=[UIColor colorWithRed:17.0/255 green:18.0/255 blue:23.0/255 alpha:0.88];button.tintColor=MSPrimaryColor();
    [button setImage:MSPlayerIcon(icon) forState:UIControlStateNormal];button.accessibilityLabel=label;
    [button.widthAnchor constraintEqualToConstant:44].active=YES;[button.heightAnchor constraintEqualToConstant:44].active=YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)applyArtworkNavigationStyle {
    UINavigationBar *bar=self.navigationController.navigationBar;if(!bar)return;
    if(!self.navigationStyleCaptured){self.styledNavigationBar=bar;self.priorNavigationBackground=[bar backgroundImageForBarMetrics:UIBarMetricsDefault];self.priorCompactNavigationBackground=[bar backgroundImageForBarMetrics:UIBarMetricsCompact];self.priorNavigationShadow=bar.shadowImage;self.priorNavigationBarTint=bar.barTintColor;self.priorNavigationBackgroundColor=bar.backgroundColor;self.priorNavigationTranslucent=bar.translucent;self.navigationStyleCaptured=YES;}
    UIImage *clear=[UIImage new];[bar setBackgroundImage:clear forBarMetrics:UIBarMetricsDefault];[bar setBackgroundImage:clear forBarMetrics:UIBarMetricsCompact];bar.shadowImage=clear;bar.barTintColor=UIColor.clearColor;bar.backgroundColor=UIColor.clearColor;bar.translucent=YES;
    self.backNavigationButton.enabled=self.navigationController.viewControllers.count>1||self.navigationController.presentingViewController!=nil;
}
- (void)restoreNavigationStyle {
    UINavigationBar *bar=self.styledNavigationBar;if(!self.navigationStyleCaptured||!bar)return;
    [bar setBackgroundImage:self.priorNavigationBackground forBarMetrics:UIBarMetricsDefault];[bar setBackgroundImage:self.priorCompactNavigationBackground forBarMetrics:UIBarMetricsCompact];bar.shadowImage=self.priorNavigationShadow;bar.barTintColor=self.priorNavigationBarTint;bar.backgroundColor=self.priorNavigationBackgroundColor;bar.translucent=self.priorNavigationTranslucent;
}
- (void)goBack {
    if(self.navigationController.transitionCoordinator)return;
    if(self.navigationController.viewControllers.count>1)[self.navigationController popViewControllerAnimated:YES];
    else if(self.navigationController.presentingViewController)[self.navigationController dismissViewControllerAnimated:YES completion:nil];
}
- (void)inactive:(NSNotification *)notification { [self cancelRequests]; }
- (void)active:(NSNotification *)notification { if (self.visible) { [self beginInitialReveal]; if (self.loaded) { [self loadPoster]; [self loadLogo]; [self revealIfReady]; } else if (!self.failed) [self loadDetails]; } }
- (void)cancelRequests {
    self.generation++; self.posterGeneration++; [self.metadataRequest cancel]; self.metadataRequest = nil; self.loading = NO; [self.posterRequest cancel]; self.posterRequest = nil;
    self.logoGeneration++; [self.logoRequest cancel]; self.logoRequest = nil;
    [self.revealDeadline invalidate]; self.revealDeadline = nil;
    [self.spinnerDelay invalidate]; self.spinnerDelay = nil; [self.loadingSpinner stopAnimating];
}
- (void)beginInitialReveal {
    if (self.contentRevealed || self.revealDeadline || !self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.header.hidden = YES; self.header.accessibilityElementsHidden = YES;
    self.tableView.scrollEnabled = NO; self.tableView.backgroundView = self.loadingView;
    __weak typeof(self) weakSelf = self;
    // Cached metadata/artwork can settle before a spinner ever becomes visible.
    self.spinnerDelay = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:NO block:^(NSTimer *timer) {
        (void)timer; typeof(self) self = weakSelf; self.spinnerDelay = nil;
        if (self.visible && !self.contentRevealed) [self.loadingSpinner startAnimating];
    }];
    self.revealDeadline = [NSTimer scheduledTimerWithTimeInterval:4 repeats:NO block:^(NSTimer *timer) {
        (void)timer; [weakSelf initialRevealExpired];
    }];
}
- (void)revealIfReady {
    if (self.contentRevealed || !self.visible || (!self.loaded && !self.failed)) return;
    BOOL artworkSettled = (!self.metadata.backgroundURL && !self.metadata.posterURL) || self.hero.artwork.image || self.artworkFailed;
    BOOL logoSettled = !self.metadata.logoURL || UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ||
        (self.logoView.image && [self.displayedLogoURL isEqual:self.metadata.logoURL]) || [self.failedLogoURL isEqual:self.metadata.logoURL];
    if (self.failed || (artworkSettled && logoSettled)) [self completeInitialReveal];
}
- (void)initialRevealExpired {
    if (self.contentRevealed || !self.visible) return;
    // Freeze the fallback chosen at the deadline. Late callbacks cannot swap a
    // visible title to a logo or change the backdrop after the one-shot reveal.
    [self cancelRequests];
    if (!self.loaded) self.failed = YES;
    if ((self.metadata.backgroundURL || self.metadata.posterURL) && !self.hero.artwork.image) self.artworkFailed = YES;
    if (self.metadata.logoURL && !self.logoView.image) self.failedLogoURL = self.metadata.logoURL;
    [self completeInitialReveal];
}
- (void)completeInitialReveal {
    if (self.contentRevealed) return;
    self.contentRevealed = YES;
    [self.revealDeadline invalidate]; self.revealDeadline = nil;
    [self.spinnerDelay invalidate]; self.spinnerDelay = nil; [self.loadingSpinner stopAnimating];
    [UIView performWithoutAnimation:^{
        [self renderMetadata]; [self.tableView reloadData]; [self.tableView layoutIfNeeded];
        self.tableView.backgroundView = nil; self.header.hidden = NO;
        self.header.accessibilityElementsHidden = NO; self.tableView.scrollEnabled = YES;
    }];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,self.logoContainer.hidden ? self.titleLabel : self.logoContainer);
}
- (NSDictionary *)libraryMetadataForEpisode:(MSEpisode *)episode {
    NSMutableDictionary *record = [@{@"metadataID":self.metadata.identifier,@"type":self.metadata.type,@"title":self.metadata.title,@"releaseInfo":self.metadata.releaseInfo ?: @""} mutableCopy];
    if (self.metadata.posterURL) record[@"posterURL"] = self.metadata.posterURL.absoluteString;
    if (self.metadata.originConnectionIdentifier) record[@"originConnectionIdentifier"] = self.metadata.originConnectionIdentifier;
    if (episode) { record[@"episodeTitle"] = episode.title; record[@"season"] = @(episode.season); record[@"episode"] = @(episode.episode); }
    return record;
}
- (void)loadDetails {
    if (self.loading || !self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (self.failed && self.contentRevealed) { self.contentRevealed = NO; self.artworkFailed = NO; self.failedLogoURL = nil; [self beginInitialReveal]; }
    self.loading = YES; self.failed = NO; [self renderMetadata];
    NSUInteger generation = ++self.generation; __weak typeof(self) weakSelf = self;
    self.metadataRequest = [self.client loadMetadataType:self.metadata.type identifier:self.metadata.identifier preferredConnectionIdentifier:self.metadata.originConnectionIdentifier completion:^(MSMetadata *metadata,NSError *error) {
        typeof(self) self = weakSelf; if (!self || !self.visible || self.generation != generation) return;
        self.loading = NO; self.metadataRequest = nil;
        if (!metadata || error) { self.failed = YES; [self renderMetadata]; [self revealIfReady]; return; }
        self.metadata = metadata; self.loaded = YES;
        self.posterGeneration++; [self.posterRequest cancel]; self.posterRequest = nil;
        self.logoGeneration++; [self.logoRequest cancel]; self.logoRequest = nil;
        self.artworkFailed = NO; self.triedArtworkFallback = NO;
        [self arrangeEpisodes];
        [MSLibraryStore.sharedStore registerMetadata:[self libraryMetadataForEpisode:nil] forVideoIdentifier:metadata.identifier];
        // Associate older exact-ID progress only; do not persist every unplayed episode.
        for (MSEpisode *episode in metadata.episodes) if ([MSLibraryStore.sharedStore recordForIdentifier:episode.identifier]) [MSLibraryStore.sharedStore registerMetadata:[self libraryMetadataForEpisode:episode] forVideoIdentifier:episode.identifier];
        [self renderMetadata]; [self loadPoster]; [self loadLogo]; [self.tableView reloadData]; [self revealIfReady];
    }];
}
- (void)retryArtwork { self.artworkFailed = NO; self.triedArtworkFallback = NO; self.displayedArtworkURL = nil; [self loadPoster]; [self renderMetadata]; }
- (void)loadPoster {
    NSURL *preferred = self.metadata.backgroundURL ?: self.metadata.posterURL;
    NSURL *alternate = [preferred isEqual:self.metadata.posterURL] ? self.metadata.backgroundURL : self.metadata.posterURL;
    NSURL *URL = self.triedArtworkFallback ? alternate : preferred;
    if (self.posterRequest || !URL || !self.visible || (self.hero.artwork.image && [self.displayedArtworkURL isEqual:URL]) || self.artworkFailed) return;
    NSUInteger generation = ++self.posterGeneration; __weak typeof(self) weakSelf = self;
    self.posterRequest = [MSImageLoader.sharedLoader loadURL:URL maxPixelSize:1024 completion:^(UIImage *image,NSError *error) {
        typeof(self) self = weakSelf; if (!self || !self.visible || self.posterGeneration != generation) return;
        self.posterRequest = nil;
        if (image) {
            self.hero.artwork.image=image; self.displayedArtworkURL=URL; self.artworkFailed=NO;
            self.backdropColor=MSBackdropColor(image); [self.hero setBackdropColor:self.backdropColor]; self.tableView.backgroundColor=self.backdropColor;
            [self.tableView reloadData];
        }
        else if (!self.triedArtworkFallback && alternate && ![URL isEqual:alternate]) { self.triedArtworkFallback = YES; [self loadPoster]; }
        else self.artworkFailed = YES;
        [self renderMetadata]; [self revealIfReady];
    }];
}
- (void)loadLogo {
    NSURL *URL = self.metadata.logoURL;
    if (!URL || self.logoRequest || !self.visible || UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        [self.failedLogoURL isEqual:URL] || (self.logoView.image && [self.displayedLogoURL isEqual:URL])) return;
    NSUInteger generation = ++self.logoGeneration; __weak typeof(self) weakSelf = self;
    // Share the existing cancellable, byte-limited and disk-cached artwork path.
    // Failure settles the initial reveal with text; no optional-art error panel.
    self.logoRequest = [MSImageLoader.sharedLoader loadURL:URL maxPixelSize:840 completion:^(UIImage *image,NSError *error) {
        typeof(self) self = weakSelf; if (!self || !self.visible || self.logoGeneration != generation || ![self.metadata.logoURL isEqual:URL]) return;
        self.logoRequest = nil;
        if (image.size.width > 0 && image.size.height > 0) { self.logoView.image = image; self.displayedLogoURL = URL; self.failedLogoURL = nil; }
        else self.failedLogoURL = URL;
        [self sizeHeader]; [self revealIfReady];
    }];
}
- (NSString *)currentVideoIdentifier {
    if (self.selectedEpisode) return self.selectedEpisode.identifier;
    if ([self.metadata.type isEqualToString:@"movie"] && self.preferredVideoIdentifier.length) {
        NSDictionary *saved = [MSLibraryStore.sharedStore recordForIdentifier:self.preferredVideoIdentifier];
        if ([saved[@"metadataID"] isEqual:self.metadata.identifier] && [saved[@"type"] isEqual:@"movie"] && [saved[@"position"] doubleValue] > 0)
            return self.preferredVideoIdentifier;
    }
    return self.metadata.defaultVideoIdentifier;
}
- (NSTimeInterval)resumePosition {
    NSDictionary *record = [MSLibraryStore.sharedStore recordForIdentifier:self.currentVideoIdentifier];
    return [record[@"duration"] doubleValue] > 0 ? [MSLibraryStore.sharedStore resumeFor:self.currentVideoIdentifier duration:[record[@"duration"] doubleValue]] : [record[@"position"] doubleValue];
}
- (void)renderMetadata {
    if (!self.isViewLoaded) return;
    self.titleLabel.text = self.metadata.title;
    self.logoContainer.accessibilityLabel = self.metadata.title;
    if (![self.displayedLogoURL isEqual:self.metadata.logoURL]) { self.logoView.image = nil; self.displayedLogoURL = nil; }
    NSMutableArray *parts = [NSMutableArray array];
    if (self.metadata.releaseInfo.length) [parts addObject:self.metadata.releaseInfo];
    if (self.metadata.runtime.length) [parts addObject:self.metadata.runtime];
    if (self.metadata.genres.count) [parts addObject:[[self.metadata.genres subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)2,self.metadata.genres.count))] componentsJoinedByString:@", "]];
    if (self.metadata.imdbRating.length) [parts addObject:[NSString stringWithFormat:@"IMDb %@ / 10",self.metadata.imdbRating]];
    self.infoLabel.text = [parts componentsJoinedByString:@" · "]; self.infoLabel.hidden = !parts.count;
    self.infoLabel.accessibilityLabel = self.metadata.imdbRating.length ? [self.infoLabel.text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"IMDb %@ / 10",self.metadata.imdbRating] withString:[NSString stringWithFormat:@"IMDb rating, %@ out of 10",self.metadata.imdbRating]] : self.infoLabel.text;
    self.summaryLabel.text = self.metadata.summary; self.summaryLabel.hidden = !self.metadata.summary.length;
    BOOL series = [self.metadata.type isEqualToString:@"series"];
    self.playButton.hidden = !self.selection; self.playButton.enabled = self.loaded && (!series || self.selectedEpisode); self.playButton.alpha = self.playButton.enabled ? 1 : 0.5;
    NSTimeInterval position = self.resumePosition;
    [self.playButton setTitle:position > 0 ? [NSString stringWithFormat:@"Resume · %@",MSTimeDescription(position)] : (series ? @"Play episode" : @"Play") forState:UIControlStateNormal];
    self.episodeLabel.hidden = !self.selectedEpisode;
    self.episodeLabel.text = self.selectedEpisode ? [NSString stringWithFormat:@"S%ld E%ld · %@",(long)self.selectedEpisode.season,(long)self.selectedEpisode.episode,self.selectedEpisode.title] : nil;
    self.episodeControls.hidden = !self.selectedEpisode;
    NSUInteger index = [self.metadata.episodes indexOfObjectIdenticalTo:self.selectedEpisode];
    self.previousButton.enabled = index != NSNotFound && index > 0; self.nextButton.enabled = index != NSNotFound && index + 1 < self.metadata.episodes.count;
    self.previousButton.alpha = self.previousButton.enabled ? 1 : 0.4; self.nextButton.alpha = self.nextButton.enabled ? 1 : 0.4;
    self.retryButton.hidden = !self.failed; self.artworkRetryButton.hidden = !self.artworkFailed;
    self.statusLabel.text = self.loading ? @"Loading details…" : self.failed ? @"Details unavailable. Try again." : self.loaded && series && !self.seasons.count ? @"No episodes available." : @"";
    self.statusLabel.hidden = !self.statusLabel.text.length; self.seasonButton.hidden = !self.seasons.count;
    if (self.selectedSeason) [self.seasonButton setTitle:[NSString stringWithFormat:@"%@ ▾",[self nameForSeason:self.selectedSeason]] forState:UIControlStateNormal];
    BOOL saved=[MSLibraryStore.sharedStore isFavorite:self.metadata.identifier];
    [self.saveNavigationButton setImage:MSPlayerIcon(saved?@"saved":@"save") forState:UIControlStateNormal];
    self.saveNavigationButton.accessibilityLabel=saved?@"Remove from favorites":@"Save to favorites";
    self.saveNavigationButton.accessibilityValue=saved?@"Saved":@"Not saved";
    self.saveNavigationButton.accessibilityTraits=UIAccessibilityTraitButton|(saved?UIAccessibilityTraitSelected:0);
    self.saveNavigationButton.enabled=self.metadata.identifier.length>0;
    [self sizeHeader];
}
- (void)toggleSummary {
    if (self.summaryButton.hidden) return;
    self.summaryExpanded=!self.summaryExpanded;
    [UIView performWithoutAnimation:^{
        [self sizeHeader]; [self.tableView layoutIfNeeded];
        if (!self.summaryExpanded) {
            CGFloat top=-self.tableView.adjustedContentInset.top;
            CGFloat bottom=MAX(top,self.tableView.contentSize.height-self.tableView.bounds.size.height+self.tableView.adjustedContentInset.bottom);
            CGPoint offset=self.tableView.contentOffset; offset.y=MIN(bottom,MAX(top,offset.y));
            [self.tableView setContentOffset:offset animated:NO];
        }
    }];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,self.summaryButton);
}
- (NSString *)nameForSeason:(NSNumber *)season { return season.integerValue == 0 ? @"Specials" : [NSString stringWithFormat:@"Season %ld",(long)season.integerValue]; }
- (void)arrangeEpisodes {
    NSMutableSet *seasons = [NSMutableSet set]; for (MSEpisode *episode in self.metadata.episodes) [seasons addObject:@(episode.season)];
    self.seasons = [[seasons allObjects] sortedArrayUsingSelector:@selector(compare:)];
    if (!self.selectedEpisode) {
        NSString *wanted = self.preferredVideoIdentifier;
        if (!wanted.length) for (NSDictionary *record in MSLibraryStore.sharedStore.continueWatchingRecords) if ([record[@"metadataID"] isEqualToString:self.metadata.identifier]) { wanted = record[@"videoID"]; break; }
        for (MSEpisode *episode in self.metadata.episodes) if ([episode.identifier isEqualToString:wanted]) { self.selectedEpisode = episode; break; }
        if (!self.selectedEpisode) { for (MSEpisode *episode in self.metadata.episodes) if (episode.season > 0) { self.selectedEpisode = episode; break; } }
        if (!self.selectedEpisode) self.selectedEpisode = self.metadata.episodes.firstObject;
        self.selectedSeason = self.selectedEpisode ? @(self.selectedEpisode.season) : self.seasons.firstObject;
    }
    NSMutableArray *episodes = [NSMutableArray array]; for (MSEpisode *episode in self.metadata.episodes) if (episode.season == self.selectedSeason.integerValue) [episodes addObject:episode]; self.episodes = episodes;
}
- (void)focusEpisode:(MSEpisode *)episode {
    if (!episode) return; self.selectedEpisode = episode; self.selectedSeason = @(episode.season); _preferredVideoIdentifier = [episode.identifier copy];
    [self arrangeEpisodes]; [self renderMetadata]; [self.tableView reloadData];
}
- (void)chooseSeason {
    if (!self.seasons.count || self.presentedViewController) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Season" message:nil preferredStyle:UIAlertControllerStyleActionSheet]; __weak typeof(self) weakSelf = self;
    for (NSNumber *season in self.seasons) [sheet addAction:[UIAlertAction actionWithTitle:[self nameForSeason:season] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) self = weakSelf; if (!self) return;
        self.selectedSeason = season; [self arrangeEpisodes]; self.selectedEpisode = self.episodes.firstObject; [self renderMetadata]; [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.seasonButton; sheet.popoverPresentationController.sourceRect = self.seasonButton.bounds; [self presentViewController:sheet animated:YES completion:nil];
}
- (void)previousEpisode { NSUInteger index = [self.metadata.episodes indexOfObjectIdenticalTo:self.selectedEpisode]; if (index != NSNotFound && index > 0) [self focusEpisode:self.metadata.episodes[index-1]]; }
- (void)nextEpisode { NSUInteger index = [self.metadata.episodes indexOfObjectIdenticalTo:self.selectedEpisode]; if (index != NSNotFound && index+1 < self.metadata.episodes.count) [self focusEpisode:self.metadata.episodes[index+1]]; }
- (void)selectVideoResuming:(BOOL)resume {
    if (!self.loaded || !self.selection || ([self.metadata.type isEqualToString:@"series"] && !self.selectedEpisode)) return;
    self.resumeRequested = resume && self.resumePosition > 0;
    self.selection(self.metadata,self.selectedEpisode);
}
- (void)playSelected { [self selectVideoResuming:self.resumePosition > 0]; }
- (void)toggleFavorite { [MSLibraryStore.sharedStore registerMetadata:[self libraryMetadataForEpisode:nil] forVideoIdentifier:self.metadata.identifier]; [MSLibraryStore.sharedStore toggleFavorite:self.metadata.identifier]; }
- (void)libraryChanged:(NSNotification *)notification { if (self.visible) { [self renderMetadata]; [self.tableView reloadData]; } }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.contentRevealed ? self.episodes.count : 0; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"episode"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"episode"];
    MSEpisode *episode = self.episodes[path.row]; BOOL selected = [episode.identifier isEqualToString:self.selectedEpisode.identifier];
    cell.backgroundColor = selected ? MSSurfaceColor() : (self.backdropColor ?: MSBackgroundColor()); cell.textLabel.textColor = selected ? MSAccentColor() : MSPrimaryColor(); cell.detailTextLabel.textColor = MSSecondaryColor();
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@",(long)episode.episode,episode.title];
    NSDictionary *record = [MSLibraryStore.sharedStore recordForIdentifier:episode.identifier]; NSTimeInterval position = [record[@"duration"] doubleValue] > 0 ? [MSLibraryStore.sharedStore resumeFor:episode.identifier duration:[record[@"duration"] doubleValue]] : [record[@"position"] doubleValue];
    cell.detailTextLabel.text = position > 0 ? [NSString stringWithFormat:@"Resume at %@",MSTimeDescription(position)] : (episode.released.length >= 10 ? [episode.released substringToIndex:10] : episode.released);
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone; cell.tintColor = MSAccentColor(); cell.accessibilityHint = @"Select episode and choose a playback source"; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path { [tableView deselectRowAtIndexPath:path animated:NO]; if ((NSUInteger)path.row < self.episodes.count) { [self focusEpisode:self.episodes[path.row]]; [self selectVideoResuming:NO]; } }
- (void)sizeHeader {
    if (!self.header || self.sizingHeader || self.tableView.bounds.size.width <= 0) return;
    self.sizingHeader = YES;
    CGFloat width = self.tableView.bounds.size.width;
    CGFloat margin=width>=900 ? 32 : 20;
    CGFloat contentWidth=MIN(840,MAX(1,width-2*margin));
    CGFloat left=(width-contentWidth)/2;
    BOOL largeText=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    BOOL showsLogo=self.logoView.image!=nil && !largeText;
    self.logoContainer.hidden=!showsLogo; self.titleLabel.hidden=showsLogo;
    if (showsLogo) {
        CGSize imageSize=self.logoView.image.size;
        CGFloat scale=MIN(MIN(contentWidth,420)/imageSize.width,(width>=900 ? 64 : 72)/imageSize.height);
        CGSize size=CGSizeMake(imageSize.width*scale,imageSize.height*scale);
        self.logoHeight.constant=size.height;
        self.logoView.frame=CGRectMake(0,0,size.width,size.height);
    }
    CGRect fullSummary=[(self.summaryLabel.text ?: @"") boundingRectWithSize:CGSizeMake(contentWidth,CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName:self.summaryLabel.font} context:nil];
    CGFloat twoLines=ceil(self.summaryLabel.font.lineHeight*2);
    CGFloat collapsedSummaryHeight=MIN(twoLines,ceil(fullSummary.size.height));
    BOOL summaryOverflows=!self.summaryLabel.hidden && ceil(fullSummary.size.height)>twoLines+0.5;
    self.summaryLabel.numberOfLines=self.summaryExpanded ? 0 : 2;
    self.summaryLabel.lineBreakMode=self.summaryExpanded ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    self.summaryButton.hidden=!summaryOverflows;
    [self.summaryButton setTitle:self.summaryExpanded ? @"Show less" : @"Show more" forState:UIControlStateNormal];
    self.summaryButton.accessibilityHint=self.summaryExpanded ? @"Collapse the description to two lines" : @"Read the complete description";
    CGSize titleSize=[self.heroText systemLayoutSizeFittingSize:CGSizeMake(contentWidth,UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGSize bodySize=[self.body systemLayoutSizeFittingSize:CGSizeMake(contentWidth,UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    // Budget only the primary action and collapsed synopsis. Expanding text
    // grows down the page instead of moving the title or playback control.
    CGFloat previewHeight=0; UIView *previous=nil;
    for (UIView *view in @[self.episodeLabel,self.playButton,self.summaryLabel,self.summaryButton]) {
        if (view.hidden) continue;
        if (previous) previewHeight+=self.body.spacing;
        CGSize size=[view systemLayoutSizeFittingSize:CGSizeMake(contentWidth,UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
        previewHeight+=view==self.summaryLabel ? collapsedSummaryHeight : size.height; previous=view;
    }
    // Failed initial loading must not leave an empty cinematic-height canvas
    // above the recovery controls. Real artwork keeps the approved layout.
    BOOL hasArtwork=(self.metadata.backgroundURL || self.metadata.posterURL) &&
        !((self.failed || self.artworkFailed) && !self.hero.artwork.image);
    self.hero.hidden=!hasArtwork;
    UIImage *image=self.hero.artwork.image;
    CGFloat ratio=image.size.width>0 && image.size.height>0 ? image.size.width/image.size.height : 16.0/9.0;
    // A landscape backdrop keeps its full width and natural aspect ratio.
    // Portrait fallback art is fitted within the same immersive canvas; it
    // never turns into a side card or stretches to fill a landscape frame.
    CGFloat artHeight=hasArtwork ? MIN(720,MAX(180,width/MAX(0.1,ratio))) : 0;
    if (ratio<1.1) artHeight=MIN(480,MAX(320,self.tableView.bounds.size.height*0.5));
    CGFloat minimumTitleY=MAX(24,self.tableView.safeAreaInsets.top+20);
    CGFloat titleY=hasArtwork ? artHeight+12 : minimumTitleY;
    if (hasArtwork && !largeText) {
        CGFloat available=self.tableView.bounds.size.height-self.tableView.adjustedContentInset.top-self.tableView.adjustedContentInset.bottom;
        CGFloat raised=artHeight-titleSize.height-(width>=900 ? 84 : 60);
        CGFloat fitsPreview=available-32-titleSize.height-12-previewHeight;
        titleY=MAX(minimumTitleY,MIN(raised,fitsPreview));
    }
    self.hero.frame=CGRectMake(0,0,width,artHeight);
    self.heroText.frame=CGRectMake(left,titleY,contentWidth,titleSize.height);
    CGFloat bodyY=CGRectGetMaxY(self.heroText.frame)+12;
    self.body.frame=CGRectMake(left,bodyY,contentWidth,bodySize.height);
    [self.hero positionFadeForTitleY:titleY bodyY:bodyY];
    CGFloat height=MAX(artHeight,CGRectGetMaxY(self.body.frame))+28;
    if (fabs(self.header.frame.size.width-width)>0.01 || fabs(self.header.frame.size.height-height)>0.01) {
        self.header.frame=CGRectMake(0,0,width,height); self.tableView.tableHeaderView=self.header;
    }
    [self.hero setNeedsLayout]; [self.heroText setNeedsLayout]; [self.body setNeedsLayout];
    self.sizingHeader=NO;
}
- (void)updateArtworkInsets {
    UIEdgeInsets inset=UIEdgeInsetsMake(0,0,self.tableView.safeAreaInsets.bottom,0);
    if(!UIEdgeInsetsEqualToEdgeInsets(self.tableView.contentInset,inset))self.tableView.contentInset=inset;
    self.tableView.scrollIndicatorInsets=UIEdgeInsetsMake(self.tableView.safeAreaInsets.top,0,inset.bottom,0);
}
- (void)viewSafeAreaInsetsDidChange { [super viewSafeAreaInsetsDidChange];[self updateArtworkInsets];[self sizeHeader]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews];[self updateArtworkInsets];[self sizeHeader]; }
- (void)fontChanged:(NSNotification *)notification { [self renderMetadata]; [self.tableView reloadData]; }
- (void)dealloc { [self.revealDeadline invalidate]; [self.spinnerDelay invalidate]; [self.metadataRequest cancel]; [self.posterRequest cancel]; [self.logoRequest cancel]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
