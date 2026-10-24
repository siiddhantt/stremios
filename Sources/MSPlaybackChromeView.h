#import <UIKit/UIKit.h>

/// Shared player surface and controls. Engine lifecycle remains in its controller.
@interface MSPlaybackChromeView : UIView
@property(nonatomic,strong,readonly) UIView *videoViewport, *videoView, *interactionView, *subtitleOverlay, *header, *footer, *statusPanel;
@property(nonatomic,strong,readonly) UILabel *titleLabel, *timeLabel, *statusLabel;
@property(nonatomic,strong,readonly) UIButton *doneButton, *playButton, *audioButton, *subtitleButton, *retryButton, *nextButton, *displayButton, *fullscreenButton, *backButton, *forwardButton;
@property(nonatomic,strong,readonly) UIActivityIndicatorView *statusSpinner;
@property(nonatomic,strong,readonly) UISlider *seekSlider;
@property(nonatomic,strong,readonly) NSLayoutConstraint *captionBottom, *captionTop, *statusBottom;
- (instancetype)initWithTitle:(NSString *)title target:(id<UIGestureRecognizerDelegate>)target;
@end
