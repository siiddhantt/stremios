#import "MSSettingsViewController.h"
#import "MSTheme.h"
#import "MSColorPickerViewController.h"
#import "MSColorPolicy.h"
#import "MSAddons.h"
#import "MSAddonsViewController.h"
#import "MSPlaybackPreferences.h"
#import "MSSubtitleSettingsViewController.h"
#import "MSLibraryStore.h"
#import "MSStorageViewController.h"
#import <math.h>

@implementation MSSettingsViewController
- (instancetype)initWithCatalog:(NSArray *)catalog {
    if ((self=[super init])) { self.title=@"Settings"; self.tabBarItem=[[UITabBarItem alloc]initWithTitle:self.title image:MSTabImage(@"settings") tag:2]; } return self;
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==1?4:section==3?2:1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return @[@"Connections",@"Playback",@"Appearance",@"Data",@""][section]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    MSSettingsCell *cell=[tableView dequeueReusableCellWithIdentifier:@"setting"]?:[[MSSettingsCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"setting"];
    cell.nameLabel.textColor=MSPrimaryColor(); cell.valueLabel.textColor=MSSecondaryColor(); cell.valueLabel.text=nil;
    MSPlaybackPreferences *p=MSPlaybackPreferences.sharedPreferences;
    if(path.section==0) { cell.nameLabel.text=@"Add-ons & connections"; cell.valueLabel.text=[NSString stringWithFormat:@"%lu",(unsigned long)MSAddonStore.sharedStore.addons.count]; }
    else if(path.section==1) {
        cell.nameLabel.text=@[@"Adaptive quality",@"Audio language",@"Subtitle language",@"Subtitle appearance"][path.row];
        if(path.row==0)cell.valueLabel.text=[p.playbackQuality isEqual:@"auto"]?@"Automatic":p.playbackQuality;
        if(path.row==1)cell.valueLabel.text=[self languageLabel:p.preferredAudioLanguage];
        if(path.row==2)cell.valueLabel.text=[self languageLabel:p.preferredSubtitleLanguage];
    } else if(path.section==2) { cell.nameLabel.text=@"Accent colour"; cell.valueLabel.text=MSSelectedAccentName(); cell.valueLabel.textColor=MSAccentColor(); }
    else if(path.section==3) {
        cell.nameLabel.text=path.row==0?@"Storage & artwork cache":@"Clear watch history";
        if(path.row==1)cell.nameLabel.textColor=[UIColor colorWithRed:1 green:0.55 blue:0.55 alpha:1];
    } else { cell.nameLabel.text=@"About & licenses"; cell.valueLabel.text=[NSString stringWithFormat:@"Build %@",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"?"]; }
    [cell position:path.row count:[self tableView:tableView numberOfRowsInSection:path.section] disclosure:!(path.section==3&&path.row==1)]; cell.accessibilityTraits=UIAccessibilityTraitButton; return cell;
}
- (NSString *)languageLabel:(NSString *)language { return @{@"system":@"System default",@"eng":@"English",@"hin":@"Hindi",@"none":@"Off"}[language]?:@"System default"; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if(path.section==0) { [self.navigationController pushViewController:[MSAddonsViewController new] animated:YES]; return; }
    if(path.section==1&&path.row==3) { [self.navigationController pushViewController:[MSSubtitleSettingsViewController new] animated:YES]; return; }
    if(path.section==1) { [self choosePreference:path]; return; }
    if(path.section==2) { MSColorPickerViewController *picker=[[MSColorPickerViewController alloc] initWithTitle:@"Accent colour" initialHex:MSSelectedAccentHex() purpose:MSColorPickerPurposeAccent completion:^(NSString *hex){NSString *preset=nil;for(NSString *name in MSAccentNames()){CGFloat r=0,g=0,b=0,a=0;[MSAccentColorForName(name) getRed:&r green:&g blue:&b alpha:&a];NSString *candidate=[NSString stringWithFormat:@"%02X%02X%02X",(unsigned)lround(r*255),(unsigned)lround(g*255),(unsigned)lround(b*255)];if([hex isEqual:candidate]){preset=name;break;}}if(preset)MSSelectAccent(preset);else MSSelectCustomAccentHex(hex);}];[self.navigationController pushViewController:picker animated:YES]; return; }
    if(path.section==3&&path.row==0) { [self.navigationController pushViewController:[MSStorageViewController new] animated:YES]; return; }
    if(path.section==3) {
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Clear watch history?" message:@"Remove playback positions and remembered sources and tracks. Saved titles stay in your Library." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Clear history" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[MSLibraryStore.sharedStore clearHistory];}]]; [self presentViewController:a animated:YES completion:nil]; return;
    }
    UIViewController *about=[UIViewController new]; about.title=@"About"; about.view.backgroundColor=MSBackgroundColor();
    UITextView *text=[UITextView new]; text.translatesAutoresizingMaskIntoConstraints=NO; text.backgroundColor=MSBackgroundColor(); text.textColor=MSSecondaryColor(); text.editable=NO; text.font=MSFont(UIFontTextStyleBody,UIFontWeightRegular); text.adjustsFontForContentSizeCategory=YES; text.textContainerInset=UIEdgeInsetsMake(24,24,24,24);
    NSURL *URL=[NSBundle.mainBundle URLForResource:@"ThirdPartyNotices" withExtension:@"txt"]; NSString *notices=URL?[NSString stringWithContentsOfURL:URL encoding:NSUTF8StringEncoding error:NULL]:@"";
    text.text=[NSString stringWithFormat:@"StremIOS\nAn independent native client.\n\nCatalogs, artwork, streams and subtitles come from your enabled add-ons. Connections stay in protected app storage. No Stremio account sync or analytics.\n\n%@",notices?:@""];
    [about.view addSubview:text]; [NSLayoutConstraint activateConstraints:@[[text.leadingAnchor constraintEqualToAnchor:about.view.leadingAnchor],[text.trailingAnchor constraintEqualToAnchor:about.view.trailingAnchor],[text.topAnchor constraintEqualToAnchor:about.view.safeAreaLayoutGuide.topAnchor],[text.bottomAnchor constraintEqualToAnchor:about.view.safeAreaLayoutGuide.bottomAnchor]]]; [self.navigationController pushViewController:about animated:YES];
}
- (void)choosePreference:(NSIndexPath *)path {
    MSPlaybackPreferences *p=MSPlaybackPreferences.sharedPreferences; NSString *key=path.row==0?@"playbackQuality":path.row==1?@"preferredAudioLanguage":@"preferredSubtitleLanguage";
    NSArray *values=path.row==0?@[@"auto",@"720p",@"1080p"]:path.row==1?@[@"system",@"eng",@"hin"]:@[@"system",@"eng",@"hin",@"none"];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:path.row==0?@"Adaptive quality":@"Preferred language" message:path.row==0?@"Prefers adaptive video up to this size. If none fits, the lowest available version is used. Fixed files keep their original quality.":@"Used when the chosen source has a matching track." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self)weakSelf=self;
    for(NSString *value in values) { NSString *label=path.row==0?([value isEqual:@"auto"]?@"Automatic":value):[self languageLabel:value]; if([[p valueForKey:key]isEqual:value])label=[@"✓ " stringByAppendingString:label];
        [a addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[p setValue:value forKey:key];[weakSelf.tableView reloadData];}]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; a.popoverPresentationController.sourceView=self.tableView; a.popoverPresentationController.sourceRect=[self.tableView rectForRowAtIndexPath:path]; [self presentViewController:a animated:YES completion:nil];
}
@end
