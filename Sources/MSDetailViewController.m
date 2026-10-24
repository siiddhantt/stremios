#import "MSDetailViewController.h"
#import "MSPlaybackRouting.h"
#import "MSMedia.h"
#import "MSTheme.h"
#import "MSLibraryStore.h"

@interface MSDetailViewController ()
@property (nonatomic, strong) MSMedia *media;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *favoriteButton;
@property (nonatomic, strong) UIButton *restartButton;
@end

@implementation MSDetailViewController
- (instancetype)initWithMedia:(MSMedia *)media {
    if ((self = [super init])) { _media = media; self.title = media.title; self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever; }
    return self;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = MSBackgroundColor();
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIImageView *artwork = [[UIImageView alloc] initWithImage:MSDemoArtwork()];
    artwork.contentMode = UIViewContentModeScaleAspectFit; artwork.backgroundColor = MSSurfaceColor();
    artwork.layer.cornerRadius = 14; artwork.clipsToBounds = YES;
    artwork.isAccessibilityElement = NO;
    [artwork.heightAnchor constraintEqualToConstant:260].active = YES;
    UILabel *title = MSLabel(UIFontTextStyleTitle1, MSPrimaryColor()); title.text = self.media.title;
    title.accessibilityTraits |= UIAccessibilityTraitHeader;
    UILabel *metadata = MSLabel(UIFontTextStyleSubheadline, MSSecondaryColor());
    metadata.text = [NSString stringWithFormat:@"%ld · 11 min · %@", (long)self.media.year, self.media.format];
    self.playButton = MSButton(@"Play", YES);
    [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
    self.favoriteButton = MSButton(@"Save to Library", NO);
    [self.favoriteButton addTarget:self action:@selector(toggleFavorite) forControlEvents:UIControlEventTouchUpInside];
    self.restartButton = MSButton(@"Start from beginning", NO);
    [self.restartButton addTarget:self action:@selector(restart) forControlEvents:UIControlEventTouchUpInside];
    UILabel *summary = MSLabel(UIFontTextStyleBody, MSPrimaryColor()); summary.text = self.media.summary;
    UILabel *credits = MSLabel(UIFontTextStyleFootnote, MSSecondaryColor()); credits.text = self.media.attribution;
    UILabel *network = MSLabel(UIFontTextStyleFootnote, MSSecondaryColor());
    network.text = @"Video streams from the video-dev test service when you tap Play. Your favorites and playback position stay on this iPad.";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[artwork, title, metadata, self.playButton, self.favoriteButton, self.restartButton, summary, credits, network]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    NSLayoutConstraint *width = [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]; width.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:640], width
    ]];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refreshButtons]; }
- (void)refreshButtons {
    BOOL favorite = [MSLibraryStore.sharedStore isFavorite:self.media.identifier];
    [self.favoriteButton setTitle:favorite ? @"Remove from Library" : @"Save to Library" forState:UIControlStateNormal];
    double resume = [MSLibraryStore.sharedStore resumeFor:self.media.identifier duration:self.media.duration];
    [self.playButton setTitle:resume > 0 ? [NSString stringWithFormat:@"Resume from %@", MSTimeDescription(resume)] : @"Play" forState:UIControlStateNormal];
    self.restartButton.hidden = resume <= 0;
}
- (void)toggleFavorite { [MSLibraryStore.sharedStore toggleFavorite:self.media.identifier]; [self refreshButtons]; }
- (void)play { [self showPlayerResuming:YES]; }
- (void)restart { [self showPlayerResuming:NO]; }
- (void)showPlayerResuming:(BOOL)resume {
    if (self.presentedViewController) return;
    NSString *container=[self.media.streamURL.pathExtension.lowercaseString isEqualToString:@"m3u8"] ? @"hls" : @"other";
    UIViewController<MSPlaybackControlling> *player = MSMakePlaybackController(self.media,container,resume);
    [self presentViewController:player animated:YES completion:nil];
}
@end
