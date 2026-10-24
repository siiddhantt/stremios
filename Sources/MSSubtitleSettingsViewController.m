#import "MSSubtitleSettingsViewController.h"
#import "MSPlaybackPreferences.h"
#import "MSColorPickerViewController.h"
#import "MSTheme.h"
#import <math.h>
@interface MSSubtitleSettingsViewController ()
@property(nonatomic,strong) MSPlaybackPreferences *preferences;
@property(nonatomic,strong) UILabel *preview;
@property(nonatomic,weak) UILabel *sizeLabel;
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
    BOOL shadow=[p.style isEqual:@"white-shadow"];self.preview.backgroundColor=shadow?UIColor.clearColor:[UIColor colorWithWhite:0 alpha:0.8];self.preview.shadowColor=shadow?UIColor.blackColor:nil;self.preview.shadowOffset=shadow?CGSizeMake(1,2):CGSizeZero;
    self.sizeLabel.text=[NSString stringWithFormat:@"%.0f pt",p.subtitleFontSize];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView;return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView;return section==1?3:section==2?2:1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView;return @[@"Text size",@"Text",@"Presentation",@""][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView;if(section==1)return @"The preview uses your chosen font, weight and colour. Serif and monospace use the nearest available font weight.";if(section==2)return @"Add-on subtitles update immediately. Reopen video for VideoLAN text changes. HLS, styled or image captions may keep their own appearance.";return nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if(path.section==0){MSSettingsSliderCell *cell=[tableView dequeueReusableCellWithIdentifier:@"subtitle-size"]?:[[MSSettingsSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"subtitle-size"];cell.nameLabel.text=@"Size";self.sizeLabel=cell.valueLabel;cell.slider.minimumValue=14;cell.slider.maximumValue=40;cell.slider.value=self.preferences.subtitleFontSize;cell.slider.accessibilityLabel=@"Subtitle text size";cell.slider.accessibilityValue=[NSString stringWithFormat:@"%.0f points",self.preferences.subtitleFontSize];[cell.slider removeTarget:self action:@selector(sizeChanged:) forControlEvents:UIControlEventValueChanged];[cell.slider addTarget:self action:@selector(sizeChanged:) forControlEvents:UIControlEventValueChanged];[self updatePreview];return cell;}
    MSSettingsCell *cell=[tableView dequeueReusableCellWithIdentifier:@"subtitle-choice"]?:[[MSSettingsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"subtitle-choice"];cell.nameLabel.textColor=MSPrimaryColor();cell.valueLabel.textColor=MSSecondaryColor();cell.valueLabel.text=nil;
    if(path.section==1){cell.nameLabel.text=@[@"Font",@"Weight",@"Colour"][path.row];if(path.row==0)cell.valueLabel.text=@{@"system":@"System",@"serif":@"Serif",@"monospace":@"Monospace"}[self.preferences.fontFamily];if(path.row==1)cell.valueLabel.text=self.preferences.subtitleFontWeight.capitalizedString;if(path.row==2){cell.valueLabel.text=[@"●  #" stringByAppendingString:self.preferences.effectiveSubtitleColorHex];cell.valueLabel.textColor=MSColorFromHex(self.preferences.effectiveSubtitleColorHex);}}
    else if(path.section==2){cell.nameLabel.text=path.row==0?@"Preset & background":@"Location";cell.valueLabel.text=path.row==0?([self.preferences.style isEqual:@"white-shadow"]?@"Shadow":[self.preferences.style isEqual:@"yellow-dark"]&&!self.preferences.subtitleColorHex.length?@"Yellow on dark":@"Dark background"):self.preferences.position.capitalizedString;}
    else cell.nameLabel.text=@"Reset subtitle appearance";
    [cell position:path.row count:[self tableView:tableView numberOfRowsInSection:path.section] disclosure:path.section!=3];cell.accessibilityTraits=UIAccessibilityTraitButton;return cell;
}
- (void)sizeChanged:(UISlider *)slider { self.preferences.subtitleFontSize=round(slider.value);slider.accessibilityValue=[NSString stringWithFormat:@"%.0f points",self.preferences.subtitleFontSize];[self updatePreview]; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(path.section==0)return;
    if(path.section==3){[self.preferences resetSubtitleAppearance];[self updatePreview];[tableView reloadData];return;}
    if(path.section==1&&path.row==2){__weak typeof(self)weakSelf=self;MSColorPickerViewController *picker=[[MSColorPickerViewController alloc] initWithTitle:@"Subtitle colour" initialHex:self.preferences.effectiveSubtitleColorHex purpose:MSColorPickerPurposeSubtitle completion:^(NSString *hex){typeof(self)self=weakSelf;if(!self)return;self.preferences.subtitleColorHex=hex;[self updatePreview];[self.tableView reloadData];}];[self.navigationController pushViewController:picker animated:YES];return;}
    NSString *key=nil,*title=nil;NSArray *values=nil,*titles=nil;
    if(path.section==1&&path.row==0){key=@"fontFamily";title=@"Subtitle font";values=@[@"system",@"serif",@"monospace"];titles=@[@"System",@"Serif",@"Monospace"];}
    else if(path.section==1){key=@"subtitleFontWeight";title=@"Font weight";values=@[@"regular",@"medium",@"semibold",@"bold"];titles=@[@"Regular",@"Medium",@"Semibold",@"Bold"];}
    else if(path.row==0){key=@"style";title=@"Subtitle preset";values=@[@"white-dark",@"yellow-dark",@"white-shadow"];titles=@[@"White on dark",@"Yellow on dark",@"White with shadow"];}
    else{key=@"position";title=@"Subtitle location";values=@[@"bottom",@"middle",@"top"];titles=@[@"Bottom",@"Middle",@"Top"];}
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:title message:[key isEqual:@"style"]?@"A preset also resets the text colour. You can choose a custom colour afterwards.":nil preferredStyle:UIAlertControllerStyleActionSheet];__weak typeof(self)weakSelf=self;
    for(NSUInteger i=0;i<values.count;i++){NSString *value=values[i],*label=titles[i];if([[self.preferences valueForKey:key] isEqual:value])label=[@"✓ " stringByAppendingString:label];[sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;typeof(self)self=weakSelf;if(!self)return;[self.preferences setValue:value forKey:key];if([key isEqual:@"style"])self.preferences.subtitleColorHex=@"";[self updatePreview];[self.tableView reloadData];}]];}
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];sheet.popoverPresentationController.sourceView=tableView;sheet.popoverPresentationController.sourceRect=[tableView rectForRowAtIndexPath:path];[self presentViewController:sheet animated:YES completion:nil];
}
@end
