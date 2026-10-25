#import "MSTheme.h"
#import "MSColorPolicy.h"
#import "MSPlaybackPreferences.h"
#import <math.h>

UIColor *MSBackgroundColor(void) { return [UIColor colorWithRed:17.0/255 green:18.0/255 blue:23.0/255 alpha:1]; }
UIColor *MSSurfaceColor(void) { return [UIColor colorWithRed:26.0/255 green:28.0/255 blue:36.0/255 alpha:1]; }
UIColor *MSPrimaryColor(void) { return [UIColor colorWithRed:243.0/255 green:244.0/255 blue:247.0/255 alpha:1]; }
UIColor *MSSecondaryColor(void) { return [UIColor colorWithRed:180.0/255 green:184.0/255 blue:199.0/255 alpha:1]; }
NSString *const MSThemeDidChangeNotification = @"MSThemeDidChange";
NSArray<NSString *> *MSAccentNames(void) { return @[@"Violet", @"Blue", @"Mint", @"Rose", @"Amber"]; }
NSString *MSSelectedAccentName(void) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:@"MiniStream.appearance.accent"];
    if ([value isEqual:@"Custom"] && MSNormalizedColorHex([NSUserDefaults.standardUserDefaults objectForKey:@"MiniStream.appearance.customAccent"]).length) return @"Custom";
    return [MSAccentNames() containsObject:value] ? value : @"Violet";
}
UIColor *MSAccentColorForName(NSString *name) {
    if ([name isEqual:@"Custom"]) return MSColorFromHex(MSReadableAccentHex([NSUserDefaults.standardUserDefaults objectForKey:@"MiniStream.appearance.customAccent"]));
    NSDictionary *palette = @{@"Violet":@[@182,@175,@255], @"Blue":@[@132,@191,@255], @"Mint":@[@127,@216,@182], @"Rose":@[@244,@168,@198], @"Amber":@[@239,@199,@121]};
    NSArray *rgb = palette[name] ?: palette[@"Violet"];
    return [UIColor colorWithRed:[rgb[0] doubleValue]/255 green:[rgb[1] doubleValue]/255 blue:[rgb[2] doubleValue]/255 alpha:1];
}
UIColor *MSAccentColor(void) { return MSAccentColorForName(MSSelectedAccentName()); }
UIColor *MSColorFromHex(NSString *hex) { uint32_t rgb=MSColorRGB(MSNormalizedColorHex(hex).length?hex:@"FFFFFF"); return [UIColor colorWithRed:((rgb>>16)&255)/255.0 green:((rgb>>8)&255)/255.0 blue:(rgb&255)/255.0 alpha:1]; }
NSString *MSSelectedAccentHex(void) { CGFloat r=0,g=0,b=0,a=0; [MSAccentColor() getRed:&r green:&g blue:&b alpha:&a]; return [NSString stringWithFormat:@"%02X%02X%02X",(unsigned)lround(r*255),(unsigned)lround(g*255),(unsigned)lround(b*255)]; }
UIFont *MSSubtitleFont(MSPlaybackPreferences *preferences) {
    NSDictionary *weights=@{@"regular":@(UIFontWeightRegular),@"medium":@(UIFontWeightMedium),@"semibold":@(UIFontWeightSemibold),@"bold":@(UIFontWeightBold)};
    CGFloat weight=[weights[preferences.subtitleFontWeight] doubleValue]; BOOL bold=weight>=UIFontWeightSemibold;
    NSString *name=nil;
    if ([preferences.fontFamily isEqual:@"arial"]) name=bold?@"Arial-BoldMT":@"ArialMT";
    if ([preferences.fontFamily isEqual:@"serif"]) name=bold?@"Georgia-Bold":@"Georgia";
    if ([preferences.fontFamily isEqual:@"monospace"]) name=bold?@"Menlo-Bold":@"Menlo-Regular";
    return (name?[UIFont fontWithName:name size:preferences.subtitleFontSize]:nil) ?: [UIFont systemFontOfSize:preferences.subtitleFontSize weight:weight];
}
static BOOL MSSameColor(UIColor *a, UIColor *b) {
    CGFloat ar,ag,ab,aa,br,bg,bb,ba;
    return a && b && [a getRed:&ar green:&ag blue:&ab alpha:&aa] && [b getRed:&br green:&bg blue:&bb alpha:&ba] && fabs(ar-br)<0.002 && fabs(ag-bg)<0.002 && fabs(ab-bb)<0.002 && fabs(aa-ba)<0.002;
}
static void MSRefreshAccent(UIView *view, UIColor *old, UIColor *color, NSMutableSet *visited) {
    if (!view || [visited containsObject:view]) return; [visited addObject:view];
    if (MSSameColor(view.backgroundColor,old)) view.backgroundColor=color;
    if (MSSameColor(view.tintColor,old)) view.tintColor=color;
    if ([view isKindOfClass:UINavigationBar.class] || [view isKindOfClass:UITabBar.class] || [view isKindOfClass:UISegmentedControl.class] || [view isKindOfClass:UISlider.class]) view.tintColor=color;
    if ([view isKindOfClass:UILabel.class] && MSSameColor(((UILabel *)view).textColor,old)) ((UILabel *)view).textColor=color;
    if ([view isKindOfClass:UISwitch.class]) ((UISwitch *)view).onTintColor=color;
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button=(UIButton *)view;
        if (MSSameColor([button titleColorForState:UIControlStateNormal],old)) [button setTitleColor:color forState:UIControlStateNormal];
    }
    for (UIView *child in view.subviews) MSRefreshAccent(child,old,color,visited);
}
static void MSRefreshControllerAccent(UIViewController *controller, UIColor *old, UIColor *color, NSMutableSet *visited) {
    MSRefreshAccent(controller.viewIfLoaded,old,color,visited);
    for (UIViewController *child in controller.childViewControllers) MSRefreshControllerAccent(child,old,color,visited);
    if (controller.presentedViewController) MSRefreshControllerAccent(controller.presentedViewController,old,color,visited);
}
static void MSApplyAccentChange(UIColor *old) {
    UIColor *color=MSAccentColor();
    // A one-off view update when a colour is selected; no timers or draw effects.
    NSMutableSet *visited=[NSMutableSet set];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        MSRefreshAccent(window,old,color,visited); MSRefreshControllerAccent(window.rootViewController,old,color,visited); window.tintColor=color;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:MSThemeDidChangeNotification object:nil];
}
void MSSelectAccent(NSString *name) {
    if (![MSAccentNames() containsObject:name] || [name isEqual:MSSelectedAccentName()]) return;
    UIColor *old=MSAccentColor(); [NSUserDefaults.standardUserDefaults setObject:name forKey:@"MiniStream.appearance.accent"]; MSApplyAccentChange(old);
}
void MSSelectCustomAccentHex(NSString *hex) {
    if (!MSNormalizedColorHex(hex).length) return;
    NSString *safe=MSReadableAccentHex(hex); if ([MSSelectedAccentName() isEqual:@"Custom"] && [MSSelectedAccentHex() isEqual:safe]) return;
    UIColor *old=MSAccentColor(); [NSUserDefaults.standardUserDefaults setObject:safe forKey:@"MiniStream.appearance.customAccent"]; [NSUserDefaults.standardUserDefaults setObject:@"Custom" forKey:@"MiniStream.appearance.accent"]; MSApplyAccentChange(old);
}
UIFont *MSFont(UIFontTextStyle style, UIFontWeight weight) {
    NSDictionary *sizes=@{UIFontTextStyleLargeTitle:@34,UIFontTextStyleTitle1:@28,UIFontTextStyleTitle2:@22,UIFontTextStyleTitle3:@20,UIFontTextStyleHeadline:@17,UIFontTextStyleBody:@17,UIFontTextStyleCallout:@16,UIFontTextStyleSubheadline:@15,UIFontTextStyleFootnote:@13,UIFontTextStyleCaption1:@12,UIFontTextStyleCaption2:@11};
    UIFont *base=[UIFont systemFontOfSize:[sizes[style]?:@17 doubleValue] weight:weight];
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:base];
}

UILabel *MSLabel(UIFontTextStyle style, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    BOOL heading=[style isEqual:UIFontTextStyleHeadline] || [style isEqual:UIFontTextStyleTitle1] || [style isEqual:UIFontTextStyleTitle2] || [style isEqual:UIFontTextStyleTitle3];
    label.font = MSFont(style, heading ? UIFontWeightSemibold : UIFontWeightRegular);
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

UIButton *MSButton(NSString *title, BOOL primary) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:primary ? MSBackgroundColor() : MSPrimaryColor() forState:UIControlStateNormal];
    button.backgroundColor = primary ? MSAccentColor() : MSSurfaceColor();
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 0;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.layer.cornerRadius = 12;
    button.contentEdgeInsets = UIEdgeInsetsMake(14, 20, 14, 20);
    NSLayoutConstraint *minimumHeight = [button.heightAnchor constraintGreaterThanOrEqualToConstant:50];
    minimumHeight.priority = 999; // Allow UIStackView to collapse hidden arranged buttons.
    minimumHeight.active = YES;
    return button;
}

void MSApplyNavigationStyle(UINavigationController *controller) {
    UINavigationBar *bar = controller.navigationBar;
    bar.barStyle = UIBarStyleBlack;
    bar.translucent = NO;
    bar.barTintColor = MSBackgroundColor();
    bar.tintColor = MSAccentColor();
    bar.titleTextAttributes = @{NSForegroundColorAttributeName:MSPrimaryColor()};
    bar.prefersLargeTitles = YES;
    bar.largeTitleTextAttributes = @{NSForegroundColorAttributeName:MSPrimaryColor()};
}

UIImage *MSTabImage(NSString *name) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(28, 28), NO, 0);
    [[UIColor blackColor] setStroke];
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = 1.8;
    path.lineJoinStyle = kCGLineJoinRound;
    if ([name isEqualToString:@"browse"]) {
        for (NSInteger row = 0; row < 2; row++) {
            for (NSInteger col = 0; col < 2; col++) {
                [path appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4 + col * 12, 4 + row * 12, 8, 8) cornerRadius:2]];
            }
        }
    } else if ([name isEqualToString:@"library"]) {
        [path moveToPoint:CGPointMake(7, 3)]; [path addLineToPoint:CGPointMake(21, 3)];
        [path addLineToPoint:CGPointMake(21, 25)]; [path addLineToPoint:CGPointMake(14, 20)];
        [path addLineToPoint:CGPointMake(7, 25)]; [path closePath];
    } else {
        for (NSInteger row = 0; row < 3; row++) {
            CGFloat y = 6 + row * 8;
            [path moveToPoint:CGPointMake(3, y)]; [path addLineToPoint:CGPointMake(25, y)];
        }
    }
    [path stroke];
    if ([name isEqualToString:@"settings"]) {
        [MSBackgroundColor() setFill];
        for (NSInteger row = 0; row < 3; row++) {
            UIBezierPath *knob = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(row == 1 ? 16 : 7, 3 + row * 8, 6, 6)];
            [knob fill]; [[UIColor blackColor] setStroke]; knob.lineWidth = 1.8; [knob stroke];
        }
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

UIImage *MSDemoArtwork(void) {
    static UIImage *artwork;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize size = CGSizeMake(360, 480);
        UIGraphicsBeginImageContextWithOptions(size, YES, 1);
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(__bridge id)[UIColor colorWithRed:0.20 green:0.26 blue:0.31 alpha:1].CGColor,
                            (__bridge id)[UIColor colorWithRed:0.10 green:0.13 blue:0.19 alpha:1].CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(context, gradient, CGPointZero, CGPointMake(360, 480), 0);
        CGGradientRelease(gradient); CGColorSpaceRelease(space);
        [[UIColor colorWithRed:0.66 green:0.76 blue:0.70 alpha:0.16] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(20, 30, 320, 320)] fill];
        [[UIColor colorWithRed:0.80 green:0.88 blue:0.82 alpha:0.88] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(128, 109, 34, 125) cornerRadius:17] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(183, 90, 34, 145) cornerRadius:17] fill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(101, 189, 148, 124)] fill];
        NSDictionary *tag = @{NSFontAttributeName:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold], NSForegroundColorAttributeName:MSSecondaryColor(), NSKernAttributeName:@2};
        [@"BLENDER OPEN MOVIE" drawAtPoint:CGPointMake(28, 365) withAttributes:tag];
        NSDictionary *title = @{NSFontAttributeName:[UIFont systemFontOfSize:31 weight:UIFontWeightBold], NSForegroundColorAttributeName:MSPrimaryColor()};
        [@"Big Buck Bunny" drawInRect:CGRectMake(26, 394, 310, 80) withAttributes:title];
        artwork = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return artwork;
}

NSString *MSTimeDescription(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0) return @"0:00";
    NSInteger whole = (NSInteger)floor(seconds);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(whole / 60), (long)(whole % 60)];
}
