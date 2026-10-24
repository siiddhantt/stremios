#import "MSPlaybackChromeView.h"
#import "MSTheme.h"
#import "MSPlayerControls.h"

@interface MSPlaybackChromeView ()
@property(nonatomic,weak) id actionTarget;
@property(nonatomic,strong) UIView *videoViewport, *videoView, *interactionView, *subtitleOverlay, *header, *footer, *statusPanel;
@property(nonatomic,strong) UILabel *titleLabel, *timeLabel, *statusLabel;
@property(nonatomic,strong) UIButton *doneButton, *playButton, *audioButton, *subtitleButton, *retryButton, *nextButton, *displayButton, *fullscreenButton, *backButton, *forwardButton;
@property(nonatomic,strong) UIActivityIndicatorView *statusSpinner;
@property(nonatomic,strong) UISlider *seekSlider;
@property(nonatomic,strong) NSLayoutConstraint *captionBottom, *captionTop, *statusBottom;
@end
@implementation MSPlaybackChromeView
- (UIButton *)action:(NSString *)title selector:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:title forState:UIControlStateNormal];
    button.tintColor = MSAccentColor(); button.titleLabel.font = MSFont(UIFontTextStyleBody,UIFontWeightSemibold); button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.contentEdgeInsets = UIEdgeInsetsMake(8,8,8,8); [button addTarget:self.actionTarget action:selector forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES; [button.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal]; [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal]; return button;
}
- (UIButton *)icon:(NSString *)name label:(NSString *)label selector:(SEL)selector {
    UIButton *button=[self action:@"" selector:selector];
    [button setImage:MSPlayerIcon(name) forState:UIControlStateNormal];button.accessibilityLabel=label;
    button.tintColor=UIColor.whiteColor;button.backgroundColor=[UIColor colorWithWhite:1 alpha:0.09];button.layer.cornerRadius=22;
    [button.widthAnchor constraintEqualToConstant:44].active=YES;[button.heightAnchor constraintEqualToConstant:44].active=YES;return button;
}
- (instancetype)initWithTitle:(NSString *)title target:(id<UIGestureRecognizerDelegate>)target {
    if((self=[super initWithFrame:CGRectZero])) {
    self.actionTarget=target;
    self.backgroundColor=UIColor.blackColor;
    self.videoViewport=[UIView new];self.videoViewport.backgroundColor=UIColor.blackColor;self.videoViewport.clipsToBounds=YES;
    self.videoView=[UIView new];self.videoView.backgroundColor=UIColor.blackColor;[self.videoViewport addSubview:self.videoView];
    // Decoder views may install their own gesture recognizers (VLC's DVD mouse
    // handler does). Keep rendering out of hit testing and own input in a sibling
    // surface, so renderer gestures can never win a tap or pinch from our UI.
    self.videoViewport.userInteractionEnabled=NO;self.videoView.userInteractionEnabled=NO;
    self.interactionView=[UIView new];self.interactionView.backgroundColor=UIColor.clearColor;
    self.interactionView.accessibilityIdentifier=@"player-interaction-surface";
    self.subtitleOverlay=[UIView new];self.subtitleOverlay.userInteractionEnabled=NO;
    self.header=[UIView new];self.footer=[UIView new];self.header.backgroundColor=[UIColor colorWithWhite:0.035 alpha:1];self.footer.backgroundColor=self.header.backgroundColor;
    UIButton *done=[self icon:@"close" label:@"Done" selector:@selector(closePlayer)];self.doneButton=done;done.accessibilityHint=@"Stop playback and save your place";
    self.audioButton=[self icon:@"audio" label:@"Choose audio track" selector:@selector(showAudio)];self.audioButton.enabled=NO;
    self.subtitleButton=[self icon:@"cc" label:@"Subtitles" selector:@selector(showSubtitles)];self.subtitleButton.enabled=NO;
    self.displayButton=[self icon:@"view" label:@"Picture size and zoom" selector:@selector(showDisplayOptions)];
    self.fullscreenButton=[self icon:@"fullscreen" label:@"Full screen" selector:@selector(enterFullscreen)];self.fullscreenButton.accessibilityHint=@"Hide controls. Tap the video to bring them back.";
    self.titleLabel=MSLabel(UIFontTextStyleHeadline,MSPrimaryColor());self.titleLabel.text=title;self.titleLabel.numberOfLines=1;self.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
    [self.titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];[self.titleLabel setContentHuggingPriority:UILayoutPriorityDefaultLow-1 forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *top=[[UIStackView alloc] initWithArrangedSubviews:@[done,self.titleLabel,self.displayButton,self.audioButton,self.subtitleButton,self.fullscreenButton]];top.spacing=12;top.alignment=UIStackViewAlignmentCenter;
    self.playButton=[self icon:@"pause" label:@"Pause" selector:@selector(togglePlayback)];self.playButton.backgroundColor=MSAccentColor();self.playButton.tintColor=UIColor.blackColor;self.playButton.enabled=NO;
    self.backButton=[self icon:@"back" label:@"Back 15 seconds" selector:@selector(skipBackward)];self.forwardButton=[self icon:@"forward" label:@"Forward 15 seconds" selector:@selector(skipForward)];self.backButton.enabled=NO;self.forwardButton.enabled=NO;
    self.timeLabel=MSLabel(UIFontTextStyleFootnote,MSPrimaryColor());self.timeLabel.textAlignment=NSTextAlignmentRight;self.timeLabel.numberOfLines=1;self.timeLabel.text=@"0:00";self.timeLabel.font=[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    UIStackView *bottomRow=[[UIStackView alloc] initWithArrangedSubviews:@[self.backButton,self.playButton,self.forwardButton,self.timeLabel]];bottomRow.spacing=12;bottomRow.alignment=UIStackViewAlignmentCenter;
    self.seekSlider=[UISlider new];self.seekSlider.minimumValue=0;self.seekSlider.maximumValue=1;self.seekSlider.enabled=NO;self.seekSlider.tintColor=MSAccentColor();self.seekSlider.maximumTrackTintColor=[UIColor colorWithWhite:1 alpha:0.2];self.seekSlider.accessibilityLabel=@"Playback position";
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(14,14),NO,0);[UIColor.whiteColor setFill];[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1,1,12,12)] fill];UIImage *thumb=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();[self.seekSlider setThumbImage:thumb forState:UIControlStateNormal];
    [self.seekSlider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [self.seekSlider addTarget:self.actionTarget action:@selector(seekBegan:) forControlEvents:UIControlEventTouchDown];
    [self.seekSlider addTarget:self.actionTarget action:@selector(seekChanged:) forControlEvents:UIControlEventValueChanged];
    [self.seekSlider addTarget:self.actionTarget action:@selector(seekEnded:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
    [self.seekSlider addTarget:self.actionTarget action:@selector(seekCancelled:) forControlEvents:UIControlEventTouchCancel];
    UITapGestureRecognizer *seekTap=[[UITapGestureRecognizer alloc] initWithTarget:self.actionTarget action:@selector(seekTapped:)];seekTap.cancelsTouchesInView=NO;[self.seekSlider addGestureRecognizer:seekTap];
    UIStackView *bottom=[[UIStackView alloc] initWithArrangedSubviews:@[self.seekSlider,bottomRow]];bottom.axis=UILayoutConstraintAxisVertical;bottom.spacing=0;
    self.statusPanel=[UIView new];self.statusPanel.backgroundColor=[UIColor colorWithWhite:0.08 alpha:0.96];self.statusPanel.layer.cornerRadius=22;self.statusPanel.clipsToBounds=YES;
    UIView *spinnerSlot=[UIView new];[spinnerSlot.widthAnchor constraintEqualToConstant:20].active=YES;[spinnerSlot.heightAnchor constraintEqualToConstant:20].active=YES;
    self.statusSpinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];self.statusSpinner.hidesWhenStopped=YES;self.statusSpinner.translatesAutoresizingMaskIntoConstraints=NO;[spinnerSlot addSubview:self.statusSpinner];
    [NSLayoutConstraint activateConstraints:@[[self.statusSpinner.centerXAnchor constraintEqualToAnchor:spinnerSlot.centerXAnchor],[self.statusSpinner.centerYAnchor constraintEqualToAnchor:spinnerSlot.centerYAnchor],[self.statusSpinner.widthAnchor constraintEqualToConstant:20],[self.statusSpinner.heightAnchor constraintEqualToConstant:20]]];
    [self.statusSpinner startAnimating];
    self.statusLabel=MSLabel(UIFontTextStyleFootnote,MSPrimaryColor());self.statusLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];self.statusLabel.numberOfLines=1;self.statusLabel.text=@"Loading…";[self.statusLabel setContentCompressionResistancePriority:999 forAxis:UILayoutConstraintAxisHorizontal];
    // Hiding the spinner must not remove its slot from the stack and move text.
    UIStackView *statusLine=[[UIStackView alloc] initWithArrangedSubviews:@[spinnerSlot,self.statusLabel]];statusLine.spacing=8;statusLine.alignment=UIStackViewAlignmentCenter;
    self.retryButton=MSButton(@"Retry",NO);self.retryButton.hidden=YES;[self.retryButton addTarget:self.actionTarget action:@selector(retryPlayback) forControlEvents:UIControlEventTouchUpInside];
    self.nextButton=MSButton(@"Next episode",NO);self.nextButton.hidden=YES;[self.nextButton addTarget:self.actionTarget action:@selector(playNextEpisode) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *status=[[UIStackView alloc] initWithArrangedSubviews:@[statusLine,self.retryButton,self.nextButton]];status.axis=UILayoutConstraintAxisVertical;status.spacing=8;
    for(UIView *view in @[self.videoViewport,self.interactionView,self.subtitleOverlay,self.header,self.footer,self.statusPanel]){view.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:view];}
    for(NSArray *pair in @[@[top,self.header],@[bottom,self.footer],@[status,self.statusPanel]]){UIView *child=pair[0],*parent=pair[1];child.translatesAutoresizingMaskIntoConstraints=NO;[parent addSubview:child];[NSLayoutConstraint activateConstraints:@[[child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:16],[child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-16],[child.topAnchor constraintEqualToAnchor:parent.safeAreaLayoutGuide.topAnchor constant:10],[child.bottomAnchor constraintEqualToAnchor:parent.safeAreaLayoutGuide.bottomAnchor constant:-10]]];}
    UILayoutGuide *safe=self.safeAreaLayoutGuide;
    self.statusBottom=[self.statusPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-124];
    self.captionBottom=[self.subtitleOverlay.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-100];self.captionTop=[self.subtitleOverlay.topAnchor constraintEqualToAnchor:safe.topAnchor constant:64];
    [NSLayoutConstraint activateConstraints:@[
        [self.videoViewport.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[self.videoViewport.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[self.videoViewport.topAnchor constraintEqualToAnchor:self.topAnchor],[self.videoViewport.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.interactionView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[self.interactionView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[self.interactionView.topAnchor constraintEqualToAnchor:self.topAnchor],[self.interactionView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[self.header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[self.header.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.footer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[self.footer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[self.footer.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.subtitleOverlay.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],[self.subtitleOverlay.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],self.captionTop,self.captionBottom,
        [self.statusPanel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],self.statusBottom,[self.statusPanel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:20],[self.statusPanel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],[self.statusPanel.widthAnchor constraintLessThanOrEqualToConstant:360]
    ]];
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self.actionTarget action:@selector(toggleControls)];tap.delegate=(id)self.actionTarget;[self.interactionView addGestureRecognizer:tap];
    UIPinchGestureRecognizer *pinch=[[UIPinchGestureRecognizer alloc] initWithTarget:self.actionTarget action:@selector(pinchedVideo:)];pinch.delegate=(id)self.actionTarget;[self.interactionView addGestureRecognizer:pinch];[tap requireGestureRecognizerToFail:pinch];
    }
    return self;
}
@end
