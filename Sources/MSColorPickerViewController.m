#import "MSColorPickerViewController.h"
#import "MSColorPolicy.h"
#import "MSTheme.h"
#import <math.h>
@interface MSColorPickerViewController ()<UITextFieldDelegate>
@property(nonatomic) MSColorPickerPurpose purpose;
@property(nonatomic,copy) void (^completion)(NSString *);
@property(nonatomic,copy) NSString *rawHex;
@property(nonatomic,copy,readwrite) NSString *selectedHex;
@property(nonatomic,strong) UILabel *previewLabel,*explanation;
@property(nonatomic,strong) UIButton *previewButton;
@property(nonatomic,strong) UITextField *hexField;
@property(nonatomic,strong) NSArray<UISlider *> *sliders;
@property(nonatomic,strong) NSArray<UILabel *> *channelLabels;
@property(nonatomic,strong) NSArray<UIButton *> *swatches;
@property(nonatomic,strong) UIScrollView *scroll;
@property(nonatomic) BOOL applied;
@end
@implementation MSColorPickerViewController
- (instancetype)initWithTitle:(NSString *)title initialHex:(NSString *)hex purpose:(MSColorPickerPurpose)purpose completion:(void (^)(NSString *))completion {
    if ((self=[super init])) { self.title=title; _purpose=purpose; _rawHex=MSNormalizedColorHex(hex); if (!_rawHex.length) _rawHex=@"FFFFFF"; _completion=[completion copy]; _selectedHex=purpose==MSColorPickerPurposeAccent?MSReadableAccentHex(_rawHex):MSReadableSubtitleHex(_rawHex); }
    return self;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=MSBackgroundColor(); self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Apply" style:UIBarButtonItemStyleDone target:self action:@selector(applyColor)];
    UIScrollView *scroll=[UIScrollView new]; self.scroll=scroll; scroll.translatesAutoresizingMaskIntoConstraints=NO; scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag; [self.view addSubview:scroll];
    UIStackView *stack=[UIStackView new]; stack.axis=UILayoutConstraintAxisVertical; stack.spacing=20; stack.translatesAutoresizingMaskIntoConstraints=NO; [scroll addSubview:stack];
    NSLayoutConstraint *width=[stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]; width.priority=999;
    [NSLayoutConstraint activateConstraints:@[[scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],[stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],[stack.trailingAnchor constraintLessThanOrEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],[stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],width,[stack.widthAnchor constraintLessThanOrEqualToConstant:600]]];
    UIView *preview=[UIView new]; preview.backgroundColor=UIColor.blackColor; preview.layer.cornerRadius=16;
    self.previewLabel=MSLabel(UIFontTextStyleTitle3,MSPrimaryColor()); self.previewLabel.textAlignment=NSTextAlignmentCenter; self.previewLabel.text=self.purpose==MSColorPickerPurposeAccent?@"A colour that feels like you":@"♪ A small window into a bigger world. ♫";
    self.previewButton=MSButton(@"Play",YES); self.previewButton.userInteractionEnabled=NO; self.previewButton.isAccessibilityElement=NO;
    UIStackView *previewStack=[[UIStackView alloc] initWithArrangedSubviews:self.purpose==MSColorPickerPurposeAccent?@[self.previewLabel,self.previewButton]:@[self.previewLabel]]; previewStack.axis=UILayoutConstraintAxisVertical; previewStack.spacing=18; previewStack.translatesAutoresizingMaskIntoConstraints=NO; [preview addSubview:previewStack];
    [NSLayoutConstraint activateConstraints:@[[previewStack.leadingAnchor constraintEqualToAnchor:preview.leadingAnchor constant:20],[previewStack.trailingAnchor constraintEqualToAnchor:preview.trailingAnchor constant:-20],[previewStack.topAnchor constraintEqualToAnchor:preview.topAnchor constant:24],[previewStack.bottomAnchor constraintEqualToAnchor:preview.bottomAnchor constant:-24],[preview.heightAnchor constraintGreaterThanOrEqualToConstant:112]]]; [stack addArrangedSubview:preview];
    [stack addArrangedSubview:MSLabel(UIFontTextStyleHeadline,MSPrimaryColor())]; ((UILabel *)stack.arrangedSubviews.lastObject).text=@"Palette";
    NSArray *colors=@[@"FFFFFF",@"B6AFFF",@"84BFFF",@"7FD8B6",@"F4A8C6",@"EFC779",@"FFE859",@"FF9E8F",@"97E9E5",@"B2D98A",@"D6B4FC",@"B8C4D1"];
    NSArray *names=@[@"White",@"Violet",@"Blue",@"Mint",@"Rose",@"Amber",@"Yellow",@"Coral",@"Aqua",@"Lime",@"Lilac",@"Silver"];
    NSMutableArray *buttons=[NSMutableArray array];
    for(NSUInteger row=0;row<3;row++){UIStackView *line=[UIStackView new];line.spacing=12;line.distribution=UIStackViewDistributionFillEqually;
        for(NSUInteger column=0;column<4;column++){NSUInteger index=row*4+column;UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];button.backgroundColor=MSColorFromHex(colors[index]);button.accessibilityLabel=names[index];button.accessibilityValue=[@"#" stringByAppendingString:colors[index]];button.accessibilityIdentifier=colors[index];button.tag=index;button.layer.cornerRadius=12;button.layer.borderWidth=2;[button setTitleColor:UIColor.blackColor forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:21 weight:UIFontWeightBold];[button.heightAnchor constraintGreaterThanOrEqualToConstant:48].active=YES;[button addTarget:self action:@selector(paletteSelected:) forControlEvents:UIControlEventTouchUpInside];[line addArrangedSubview:button];[buttons addObject:button];}
        [stack addArrangedSubview:line];
    }self.swatches=buttons;
    UILabel *custom=MSLabel(UIFontTextStyleHeadline,MSPrimaryColor());custom.text=@"Custom colour";[stack addArrangedSubview:custom];
    NSMutableArray *sliders=[NSMutableArray array],*labels=[NSMutableArray array];
    for(NSUInteger channel=0;channel<3;channel++){UILabel *label=MSLabel(UIFontTextStyleSubheadline,MSSecondaryColor());UISlider *slider=[UISlider new];slider.minimumValue=0;slider.maximumValue=255;slider.tag=channel;slider.accessibilityLabel=@[@"Red",@"Green",@"Blue"][channel];slider.tintColor=MSAccentColor();[slider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;[slider addTarget:self action:@selector(channelChanged:) forControlEvents:UIControlEventValueChanged];UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[label,slider]];row.axis=UILayoutConstraintAxisVertical;row.spacing=0;[stack addArrangedSubview:row];[sliders addObject:slider];[labels addObject:label];}self.sliders=sliders;self.channelLabels=labels;
    self.hexField=[UITextField new];self.hexField.borderStyle=UITextBorderStyleRoundedRect;self.hexField.backgroundColor=MSSurfaceColor();self.hexField.textColor=MSPrimaryColor();self.hexField.tintColor=MSAccentColor();self.hexField.font=[UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightRegular];self.hexField.autocapitalizationType=UITextAutocapitalizationTypeAllCharacters;self.hexField.autocorrectionType=UITextAutocorrectionTypeNo;self.hexField.spellCheckingType=UITextSpellCheckingTypeNo;self.hexField.keyboardType=UIKeyboardTypeASCIICapable;self.hexField.returnKeyType=UIReturnKeyDone;self.hexField.delegate=self;self.hexField.accessibilityLabel=@"Hex colour, six hexadecimal digits";self.hexField.placeholder=@"#RRGGBB";[self.hexField.heightAnchor constraintGreaterThanOrEqualToConstant:48].active=YES;[self.hexField addTarget:self action:@selector(hexChanged:) forControlEvents:UIControlEventEditingChanged];[stack addArrangedSubview:self.hexField];
    self.explanation=MSLabel(UIFontTextStyleFootnote,MSSecondaryColor());[stack addArrangedSubview:self.explanation];[self refreshControls:YES];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
}
- (void)refreshControls:(BOOL)updateText {
    self.selectedHex=self.purpose==MSColorPickerPurposeAccent?MSReadableAccentHex(self.rawHex):MSReadableSubtitleHex(self.rawHex);UIColor *color=MSColorFromHex(self.selectedHex);
    self.previewLabel.textColor=color;self.previewButton.backgroundColor=color;uint32_t rgb=MSColorRGB(self.rawHex);
    for(NSUInteger i=0;i<3;i++){NSUInteger value=(rgb>>(16-8*i))&255;self.sliders[i].value=value;self.sliders[i].accessibilityValue=[NSString stringWithFormat:@"%lu",(unsigned long)value];self.channelLabels[i].text=[NSString stringWithFormat:@"%@ · %lu",@[@"Red",@"Green",@"Blue"][i],(unsigned long)value];}
    if(updateText)self.hexField.text=[@"#" stringByAppendingString:self.rawHex];
    for(UIButton *button in self.swatches){BOOL selected=[button.accessibilityIdentifier isEqual:self.rawHex];[button setTitle:selected?@"✓":@"" forState:UIControlStateNormal];button.layer.borderColor=(selected?UIColor.whiteColor:UIColor.clearColor).CGColor;button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0);}
    BOOL adjusted=![self.rawHex isEqual:self.selectedHex];self.explanation.text=adjusted?[NSString stringWithFormat:@"Adjusted to #%@ for readable contrast on dark backgrounds. Tap Apply to save.",self.selectedHex]:@"Choose a palette colour or adjust RGB / hex. Very dark choices brighten for readable contrast. Apply saves; Back discards.";self.navigationItem.rightBarButtonItem.enabled=YES;
}
- (void)paletteSelected:(UIButton *)button { [self.view endEditing:YES];self.rawHex=button.accessibilityIdentifier;[self refreshControls:YES]; }
- (void)channelChanged:(UISlider *)slider { (void)slider;self.rawHex=[NSString stringWithFormat:@"%02X%02X%02X",(unsigned)lround(self.sliders[0].value),(unsigned)lround(self.sliders[1].value),(unsigned)lround(self.sliders[2].value)];[self refreshControls:YES]; }
- (void)hexChanged:(UITextField *)field { NSString *valid=MSNormalizedColorHex(field.text);if(!valid.length){self.navigationItem.rightBarButtonItem.enabled=NO;self.explanation.text=@"Enter six hex digits, for example B6AFFF.";return;}self.rawHex=valid;[self refreshControls:NO]; }
- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)replacement { if(range.location>field.text.length||NSMaxRange(range)>field.text.length)return NO;NSString *next=[field.text stringByReplacingCharactersInRange:range withString:replacement];if(next.length>7)return NO;for(NSUInteger i=0;i<next.length;i++){unichar c=[next characterAtIndex:i];if(i==0&&c=='#')continue;if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F')))return NO;}return YES; }
- (BOOL)textFieldShouldReturn:(UITextField *)field { [field resignFirstResponder];return YES; }
- (void)keyboardChanged:(NSNotification *)notification {
    CGRect keyboard=[self.view convertRect:[notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    CGRect overlap=CGRectIntersection(self.scroll.frame,keyboard);CGFloat inset=CGRectIsNull(overlap)?0:overlap.size.height;
    self.scroll.contentInset=UIEdgeInsetsMake(0,0,inset,0);self.scroll.scrollIndicatorInsets=self.scroll.contentInset;
    if(self.hexField.isFirstResponder)[self.scroll scrollRectToVisible:CGRectInset([self.hexField convertRect:self.hexField.bounds toView:self.scroll],0,-16) animated:NO];
}
- (void)applyColor { if(self.applied||!self.navigationItem.rightBarButtonItem.enabled||!MSNormalizedColorHex(self.rawHex).length)return;self.applied=YES;[self.view endEditing:YES];if(self.completion)self.completion(self.selectedHex);self.completion=nil;[self.navigationController popViewControllerAnimated:YES]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
