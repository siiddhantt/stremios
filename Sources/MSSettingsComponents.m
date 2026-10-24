#import "MSSettingsComponents.h"
#import "MSTheme.h"
@interface MSSettingsCell ()
@property(nonatomic,strong) UIView *card, *line;
@property(nonatomic,strong,readwrite) UILabel *nameLabel, *valueLabel;
@property(nonatomic,strong) UILabel *chevron;
@end
@implementation MSSettingsCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self=[super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier])) {
        self.backgroundColor=UIColor.clearColor; self.selectionStyle=UITableViewCellSelectionStyleNone;
        _card=[UIView new]; _card.translatesAutoresizingMaskIntoConstraints=NO; _card.backgroundColor=MSSurfaceColor(); _card.layer.cornerRadius=16;
        _nameLabel=MSLabel(UIFontTextStyleBody,MSPrimaryColor()); _valueLabel=MSLabel(UIFontTextStyleSubheadline,MSSecondaryColor()); _valueLabel.textAlignment=NSTextAlignmentRight;
        [_nameLabel setContentCompressionResistancePriority:751 forAxis:UILayoutConstraintAxisHorizontal];
        [_valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        _chevron=MSLabel(UIFontTextStyleBody,MSSecondaryColor()); _chevron.text=@"›"; _chevron.font=[UIFont systemFontOfSize:24 weight:UIFontWeightLight];
        [_chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *row=[[UIStackView alloc]initWithArrangedSubviews:@[_nameLabel,_valueLabel,_chevron]]; row.spacing=12; row.alignment=UIStackViewAlignmentCenter; row.translatesAutoresizingMaskIntoConstraints=NO;
        _line=[UIView new]; _line.translatesAutoresizingMaskIntoConstraints=NO; _line.backgroundColor=[UIColor colorWithWhite:1 alpha:0.055];
        [self.contentView addSubview:_card]; [_card addSubview:row]; [_card addSubview:_line];
        NSLayoutConstraint *height=[_card.heightAnchor constraintGreaterThanOrEqualToConstant:58]; height.priority=999;
        [NSLayoutConstraint activateConstraints:@[[_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],[_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],[_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],[_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],height,[row.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:18],[row.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],[row.topAnchor constraintEqualToAnchor:_card.topAnchor constant:15],[row.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-15],[_line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],[_line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],[_line.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],[_line.heightAnchor constraintEqualToConstant:1.0/UIScreen.mainScreen.scale]]];
        self.isAccessibilityElement=YES;
    } return self;
}
- (void)position:(NSInteger)row count:(NSInteger)count disclosure:(BOOL)disclosure {
    self.card.layer.maskedCorners=(row==0?(kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner):0)|(row==count-1?(kCALayerMinXMaxYCorner|kCALayerMaxXMaxYCorner):0);
    self.line.hidden=row==count-1; self.chevron.hidden=!disclosure; self.accessibilityTraits=disclosure?UIAccessibilityTraitButton:UIAccessibilityTraitNone;
    self.accessibilityLabel=self.nameLabel.text; self.accessibilityValue=self.valueLabel.text;
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated { [super setHighlighted:highlighted animated:animated]; self.card.backgroundColor=highlighted?[UIColor colorWithRed:0.15 green:0.16 blue:0.20 alpha:1]:MSSurfaceColor(); }
@end
@implementation MSSettingsSliderCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if((self=[super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier])) {
        self.backgroundColor=UIColor.clearColor;self.selectionStyle=UITableViewCellSelectionStyleNone;
        UIView *card=[UIView new];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=MSSurfaceColor();card.layer.cornerRadius=16;[self.contentView addSubview:card];
        _nameLabel=MSLabel(UIFontTextStyleBody,MSPrimaryColor());_valueLabel=MSLabel(UIFontTextStyleSubheadline,MSSecondaryColor());_valueLabel.textAlignment=NSTextAlignmentRight;
        UIStackView *labels=[[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel,_valueLabel]];labels.spacing=12;labels.distribution=UIStackViewDistributionFillEqually;
        _slider=[UISlider new];_slider.tintColor=MSAccentColor();[_slider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
        UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[labels,_slider]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=8;stack.translatesAutoresizingMaskIntoConstraints=NO;[card addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],[card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],[card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],[card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],[stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],[stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],[stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],[stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]]];
    }return self;
}
@end
@implementation MSSettingsTableController
- (instancetype)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.tableView.backgroundColor=MSBackgroundColor(); self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight=UITableViewAutomaticDimension; self.tableView.estimatedRowHeight=58;
    self.tableView.sectionHeaderHeight=UITableViewAutomaticDimension; self.tableView.estimatedSectionHeaderHeight=40;
    self.tableView.sectionFooterHeight=UITableViewAutomaticDimension; self.tableView.estimatedSectionFooterHeight=34;
    self.tableView.tableFooterView=[[UIView alloc]initWithFrame:CGRectMake(0,0,1,20)];
    self.tableView.cellLayoutMarginsFollowReadableWidth=NO;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) { UITableViewHeaderFooterView *header=(id)view; header.textLabel.textColor=MSSecondaryColor(); header.textLabel.font=MSFont(UIFontTextStyleFootnote,UIFontWeightMedium); header.textLabel.adjustsFontForContentSizeCategory=YES; }
}
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) { UITableViewHeaderFooterView *footer=(id)view; footer.textLabel.textColor=MSSecondaryColor(); footer.textLabel.font=MSFont(UIFontTextStyleFootnote,UIFontWeightRegular); footer.textLabel.adjustsFontForContentSizeCategory=YES; }
}
@end
