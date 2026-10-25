#import "MSSubtitleSettingsViewController.h"
#import "MSPlaybackPreferences.h"
#import "MSColorPickerViewController.h"
#import "MSTheme.h"
#import <math.h>
@interface MSSubtitleShadowCell : UITableViewCell
@property(nonatomic,strong) UISwitch *shadowSwitch;
@end
@implementation MSSubtitleShadowCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if((self=[super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier])){
        self.backgroundColor=UIColor.clearColor;self.selectionStyle=UITableViewCellSelectionStyleNone;
        UIView *card=[UIView new];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=MSSurfaceColor();card.layer.cornerRadius=16;[self.contentView addSubview:card];
        UILabel *label=MSLabel(UIFontTextStyleBody,MSPrimaryColor());label.text=@"Shadow";
        _shadowSwitch=[UISwitch new];_shadowSwitch.onTintColor=MSAccentColor();_shadowSwitch.accessibilityLabel=@"Subtitle shadow";
        [_shadowSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];[_shadowSwitch setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        // iOS 12 reports a 49pt intrinsic switch width but draws a fixed 51pt
        // control. Reserve its measured frame so the visible edge stays aligned.
        CGSize fitted=[_shadowSwitch sizeThatFits:CGSizeZero];CGSize switchSize=CGSizeMake(MAX(51,MAX(fitted.width,_shadowSwitch.bounds.size.width)),MAX(31,MAX(fitted.height,_shadowSwitch.bounds.size.height)));
        UIView *switchHost=[[UIView alloc]initWithFrame:(CGRect){CGPointZero,switchSize}];switchHost.translatesAutoresizingMaskIntoConstraints=NO;_shadowSwitch.frame=switchHost.bounds;[switchHost addSubview:_shadowSwitch];
        [NSLayoutConstraint activateConstraints:@[[switchHost.widthAnchor constraintEqualToConstant:switchSize.width],[switchHost.heightAnchor constraintEqualToConstant:switchSize.height]]];
        UIStackView *row=[[UIStackView alloc]initWithArrangedSubviews:@[label,switchHost]];row.translatesAutoresizingMaskIntoConstraints=NO;row.alignment=UIStackViewAlignmentCenter;row.spacing=16;[card addSubview:row];
        [NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],[card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],[card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],[card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],[row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],[row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],[row.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],[row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14]]];
    }return self;
}
@end
@interface MSSubtitleSettingsViewController ()
@property(nonatomic,strong) MSPlaybackPreferences *preferences;
@property(nonatomic,strong) UILabel *preview;
@property(nonatomic,weak) UILabel *sizeLabel,*offsetLabel;
@end
@implementation MSSubtitleSettingsViewController
- (instancetype)init { return [self initWithPreferences:MSPlaybackPreferences.sharedPreferences]; }
- (instancetype)initWithPreferences:(MSPlaybackPreferences *)preferences { if((self=[super init]))_preferences=preferences;return self; }
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Subtitle appearance";
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,600,168)];
    UIView *card=[UIView new];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=UIColor.blackColor;card.layer.cornerRadius=16;[header addSubview:card];
    self.preview=[UILabel new];self.preview.translatesAutoresizingMaskIntoConstraints=NO;self.preview.text=@"♪ A small window into a bigger world. ♫";self.preview.numberOfLines=2;self.preview.textAlignment=NSTextAlignmentCenter;self.preview.layer.cornerRadius=8;self.preview.clipsToBounds=YES;[card addSubview:self.preview];
    [NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],[card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],[card.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],[card.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12],[self.preview.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],[self.preview.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],[self.preview.centerYAnchor constraintEqualToAnchor:card.centerYAnchor]]];
    self.tableView.tableHeaderView=header;[self updatePreview];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];[self updatePreview];[self.tableView reloadData]; }
- (void)updatePreview {
    MSPlaybackPreferences *p=self.preferences;self.preview.font=MSSubtitleFont(p);self.preview.textColor=MSColorFromHex(p.effectiveSubtitleColorHex);
    BOOL shadow=p.subtitleShadowEnabled;self.preview.backgroundColor=[p.style isEqual:@"white-shadow"]?UIColor.clearColor:[UIColor colorWithWhite:0 alpha:0.8];self.preview.shadowColor=shadow?UIColor.blackColor:nil;self.preview.shadowOffset=shadow?CGSizeMake(1,2):CGSizeZero;
    self.sizeLabel.text=[NSString stringWithFormat:@"%.0f pt",p.subtitleFontSize];
    self.offsetLabel.text=[self offsetDescription];
}
- (NSString *)offsetDescription {
    NSInteger percent=(NSInteger)lround(self.preferences.subtitleVerticalOffset*100);
    return percent==0?@"Default (0%)":[NSString stringWithFormat:@"%ld%% %@",(long)labs(percent),percent>0?@"higher":@"lower"];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView;return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView;return section==1||section==2?3:1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView;return @[@"Text size",@"Text",@"Presentation",@""][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView;if(section==1)return @"The preview uses your font, weight and colour. Arial, serif and monospace use the nearest available weight.";if(section==2)return @"0% is the default position. Move left to lower captions or right to raise them. Add-on captions update immediately. Plain-text VideoLAN font, size, colour and weight update while playing; reopen for shadow or position changes. HLS, styled and image captions may keep their own appearance.";return nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if(path.section==0){MSSettingsSliderCell *cell=[tableView dequeueReusableCellWithIdentifier:@"subtitle-size"]?:[[MSSettingsSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"subtitle-size"];cell.nameLabel.text=@"Size";self.sizeLabel=cell.valueLabel;cell.slider.minimumValue=14;cell.slider.maximumValue=40;cell.slider.value=self.preferences.subtitleFontSize;cell.slider.accessibilityLabel=@"Subtitle text size";cell.slider.accessibilityValue=[NSString stringWithFormat:@"%.0f points",self.preferences.subtitleFontSize];[cell.slider removeTarget:self action:@selector(sizeChanged:) forControlEvents:UIControlEventValueChanged];[cell.slider addTarget:self action:@selector(sizeChanged:) forControlEvents:UIControlEventValueChanged];[self updatePreview];return cell;}
    if(path.section==2&&path.row==1){MSSettingsSliderCell *cell=[tableView dequeueReusableCellWithIdentifier:@"subtitle-offset"]?:[[MSSettingsSliderCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"subtitle-offset"];cell.nameLabel.text=@"Vertical position";self.offsetLabel=cell.valueLabel;cell.valueLabel.text=[self offsetDescription];cell.slider.minimumValue=-0.05;cell.slider.maximumValue=0.50;cell.slider.value=self.preferences.subtitleVerticalOffset;cell.slider.accessibilityLabel=@"Subtitle vertical position";cell.slider.accessibilityValue=[self offsetDescription];cell.slider.accessibilityHint=@"Negative values lower captions. Positive values raise them.";[cell.slider removeTarget:self action:@selector(offsetChanged:) forControlEvents:UIControlEventValueChanged];[cell.slider addTarget:self action:@selector(offsetChanged:) forControlEvents:UIControlEventValueChanged];return cell;}
    if(path.section==2&&path.row==2){MSSubtitleShadowCell *cell=[tableView dequeueReusableCellWithIdentifier:@"subtitle-shadow"]?:[[MSSubtitleShadowCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"subtitle-shadow"];cell.shadowSwitch.on=self.preferences.subtitleShadowEnabled;[cell.shadowSwitch removeTarget:self action:@selector(shadowChanged:) forControlEvents:UIControlEventValueChanged];[cell.shadowSwitch addTarget:self action:@selector(shadowChanged:) forControlEvents:UIControlEventValueChanged];return cell;}
    MSSettingsCell *cell=[tableView dequeueReusableCellWithIdentifier:@"subtitle-choice"]?:[[MSSettingsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"subtitle-choice"];cell.nameLabel.textColor=MSPrimaryColor();cell.valueLabel.textColor=MSSecondaryColor();cell.valueLabel.text=nil;
    if(path.section==1){cell.nameLabel.text=@[@"Font",@"Weight",@"Colour"][path.row];if(path.row==0)cell.valueLabel.text=@{@"system":@"System",@"arial":@"Arial",@"serif":@"Serif",@"monospace":@"Monospace"}[self.preferences.fontFamily];if(path.row==1)cell.valueLabel.text=self.preferences.subtitleFontWeight.capitalizedString;if(path.row==2){cell.valueLabel.text=[@"●  #" stringByAppendingString:self.preferences.effectiveSubtitleColorHex];cell.valueLabel.textColor=MSColorFromHex(self.preferences.effectiveSubtitleColorHex);}}
    else if(path.section==2){cell.nameLabel.text=@"Preset & background";cell.valueLabel.text=[self.preferences.style isEqual:@"white-shadow"]?@"Clear background":[self.preferences.style isEqual:@"yellow-dark"]&&!self.preferences.subtitleColorHex.length?@"Yellow on dark":@"Dark background";}
    else cell.nameLabel.text=@"Reset subtitle appearance";
    [cell position:path.row count:path.section==2?1:[self tableView:tableView numberOfRowsInSection:path.section] disclosure:path.section!=3];cell.accessibilityTraits=UIAccessibilityTraitButton;return cell;
}
- (void)sizeChanged:(UISlider *)slider { self.preferences.subtitleFontSize=round(slider.value);slider.accessibilityValue=[NSString stringWithFormat:@"%.0f points",self.preferences.subtitleFontSize];[self updatePreview]; }
- (void)offsetChanged:(UISlider *)slider { self.preferences.subtitleVerticalOffset=round(slider.value*100)/100;slider.value=self.preferences.subtitleVerticalOffset;slider.accessibilityValue=[self offsetDescription];[self updatePreview]; }
- (void)shadowChanged:(UISwitch *)control { self.preferences.subtitleShadowEnabled=control.on;[self updatePreview]; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(path.section==0||(path.section==2&&path.row>0))return;
    if(path.section==3){[self.preferences resetSubtitleAppearance];[self updatePreview];[tableView reloadData];return;}
    if(path.section==1&&path.row==2){__weak typeof(self)weakSelf=self;MSColorPickerViewController *picker=[[MSColorPickerViewController alloc] initWithTitle:@"Subtitle colour" initialHex:self.preferences.effectiveSubtitleColorHex purpose:MSColorPickerPurposeSubtitle completion:^(NSString *hex){typeof(self)self=weakSelf;if(!self)return;self.preferences.subtitleColorHex=hex;[self updatePreview];[self.tableView reloadData];}];[self.navigationController pushViewController:picker animated:YES];return;}
    NSString *key=nil,*title=nil;NSArray *values=nil,*titles=nil;
    if(path.section==1&&path.row==0){key=@"fontFamily";title=@"Subtitle font";values=@[@"system",@"arial",@"serif",@"monospace"];titles=@[@"System",@"Arial",@"Serif",@"Monospace"];}
    else if(path.section==1){key=@"subtitleFontWeight";title=@"Font weight";values=@[@"regular",@"medium",@"semibold",@"bold"];titles=@[@"Regular",@"Medium",@"Semibold",@"Bold"];}
    else{key=@"style";title=@"Subtitle preset";values=@[@"white-dark",@"yellow-dark",@"white-shadow"];titles=@[@"White on dark",@"Yellow on dark",@"White on clear"];}
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:title message:[key isEqual:@"style"]?@"A preset also resets the text colour. You can choose a custom colour afterwards.":nil preferredStyle:UIAlertControllerStyleActionSheet];__weak typeof(self)weakSelf=self;
    for(NSUInteger i=0;i<values.count;i++){NSString *value=values[i],*label=titles[i];if([[self.preferences valueForKey:key] isEqual:value])label=[@"✓ " stringByAppendingString:label];[sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;typeof(self)self=weakSelf;if(!self)return;if([key isEqual:@"style"])self.preferences.subtitleShadowEnabled=self.preferences.subtitleShadowEnabled;[self.preferences setValue:value forKey:key];if([key isEqual:@"style"])self.preferences.subtitleColorHex=@"";[self updatePreview];[self.tableView reloadData];}]];}
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];sheet.popoverPresentationController.sourceView=tableView;sheet.popoverPresentationController.sourceRect=[tableView rectForRowAtIndexPath:path];[self presentViewController:sheet animated:YES completion:nil];
}
@end
