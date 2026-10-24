#import "MSPlayerControls.h"
#import "MSTheme.h"
#import "MSVideoGeometry.h"

// Official Tabler artwork, rasterized offline at each device scale. The embedded
// bytes avoid runtime SVG/font dependencies and resource-copy omissions.
#import "../Resources/PlayerIcons/GeneratedIcons.h"
#include <string.h>

UIImage *MSPlayerIcon(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0) return nil;
    static NSCache<NSString *, UIImage *> *icons;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ icons = [NSCache new]; icons.countLimit = 30; });
    NSInteger scale = MAX(1, MIN(3, (NSInteger)ceil(UIScreen.mainScreen.scale)));
    NSString *key = [NSString stringWithFormat:@"%@-%ld", name, (long)scale];
    UIImage *cached = [icons objectForKey:key];
    if (cached) return cached;
    const char *requested = name.UTF8String;
    for (size_t index = 0; index < MSPlayerIconAssetCount; index++) {
        const MSPlayerIconAsset *asset = &MSPlayerIconAssets[index];
        if (strcmp(requested, asset->name) != 0) continue;
        NSData *data = [NSData dataWithBytesNoCopy:(void *)asset->bytes[scale - 1]
                                           length:asset->lengths[scale - 1] freeWhenDone:NO];
        UIImage *image = [[UIImage imageWithData:data scale:scale]
                         imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if (image) [icons setObject:image forKey:key];
        return image;
    }
    return nil;
}

@interface MSVideoOptionsViewController ()
@property(nonatomic,copy) NSString *mode;
@property(nonatomic) CGFloat zoom;
@property(nonatomic,copy) void (^change)(NSString *,CGFloat);
@property(nonatomic,strong) UISegmentedControl *sizing,*ratios;
@property(nonatomic,strong) UISlider *zoomSlider;
@property(nonatomic,strong) UILabel *zoomLabel;
@end
@implementation MSVideoOptionsViewController
- (instancetype)initWithMode:(NSString *)mode zoom:(CGFloat)zoom change:(void (^)(NSString *,CGFloat))change {
    if((self=[super init])) { _mode=[mode copy];_zoom=MSVideoBoundedZoom(zoom);_change=[change copy];self.preferredContentSize=CGSizeMake(360,304);self.modalPresentationStyle=UIModalPresentationPopover; }return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=MSSurfaceColor();
    UILabel *title=MSLabel(UIFontTextStyleHeadline,MSPrimaryColor());title.text=@"Picture";
    self.sizing=[[UISegmentedControl alloc] initWithItems:@[@"Fit",@"Fill",@"Stretch"]];
    self.ratios=[[UISegmentedControl alloc] initWithItems:@[@"16:9",@"4:3",@"1:1",@"2.35:1"]];
    for(UISegmentedControl *control in @[self.sizing,self.ratios]) { control.tintColor=MSAccentColor();[control setTitleTextAttributes:@{NSForegroundColorAttributeName:MSPrimaryColor()} forState:UIControlStateNormal];[control setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.blackColor} forState:UIControlStateSelected];[control.heightAnchor constraintEqualToConstant:40].active=YES;[control addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged]; }
    self.sizing.accessibilityLabel=@"Picture sizing";self.ratios.accessibilityLabel=@"Picture aspect ratio";
    self.zoomLabel=MSLabel(UIFontTextStyleSubheadline,MSPrimaryColor());
    self.zoomSlider=[UISlider new];self.zoomSlider.minimumValue=1;self.zoomSlider.maximumValue=3;self.zoomSlider.value=self.zoom;self.zoomSlider.tintColor=MSAccentColor();self.zoomSlider.accessibilityLabel=@"Video zoom";
    [self.zoomSlider.heightAnchor constraintEqualToConstant:44].active=YES;[self.zoomSlider addTarget:self action:@selector(zoomChanged:) forControlEvents:UIControlEventValueChanged];
    UIButton *reset=MSButton(@"Reset picture",NO);[reset addTarget:self action:@selector(resetPicture) forControlEvents:UIControlEventTouchUpInside];
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:scroll];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,self.sizing,self.ratios,self.zoomLabel,self.zoomSlider,reset]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],[stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],[stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32]]];[self refresh];
}
- (void)refresh {
    NSUInteger index=[@[@"fit",@"fill",@"stretch"] indexOfObject:self.mode];self.sizing.selectedSegmentIndex=index==NSNotFound?UISegmentedControlNoSegment:(NSInteger)index;
    index=[@[@"16:9",@"4:3",@"1:1",@"2.35:1"] indexOfObject:self.mode];self.ratios.selectedSegmentIndex=index==NSNotFound?UISegmentedControlNoSegment:(NSInteger)index;
    self.zoomSlider.value=self.zoom;self.zoomLabel.text=[NSString stringWithFormat:@"Zoom  %.2f×",self.zoom];self.zoomSlider.accessibilityValue=[NSString stringWithFormat:@"%.2f times",self.zoom];
}
- (void)modeChanged:(UISegmentedControl *)sender { NSArray *modes=sender==self.sizing?@[@"fit",@"fill",@"stretch"]:@[@"16:9",@"4:3",@"1:1",@"2.35:1"];if(sender.selectedSegmentIndex<0)return;self.mode=modes[sender.selectedSegmentIndex];self.zoom=1;[self changed]; }
- (void)zoomChanged:(UISlider *)sender { self.zoom=MSVideoBoundedZoom(sender.value);[self changed]; }
- (void)resetPicture { self.mode=@"fit";self.zoom=1;[self changed]; }
- (void)changed { [self refresh];if(self.change)self.change(self.mode,self.zoom); }
@end
