#import "LauncherPillLabel.h"
#import "LauncherPreferences.h"
#import "LauncherRendererPickerViewController.h"
#import "LauncherTheme.h"
#import "utils.h"

typedef NS_ENUM(NSInteger, MinecraftEra) { MinecraftEraUnknown, MinecraftEraLegacy, MinecraftEraModern };

/// 1.17 and newer (core-profile OpenGL, 26.x...) versus 1.16 and older (fixed-function OpenGL). Snapshots and
/// aliases like "latest-release" are unknown: nothing is hidden for them.
static MinecraftEra EraOfVersionId(NSString *versionId) {
    if (versionId.length == 0) return MinecraftEraUnknown;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?<![0-9.])([0-9]+)\\.([0-9]+)(?:\\.[0-9]+)?(?![0-9])" options:0 error:nil];
    __block MinecraftEra era = MinecraftEraUnknown;
    [re enumerateMatchesInString:versionId options:0 range:NSMakeRange(0, versionId.length)
                      usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        NSInteger major = [[versionId substringWithRange:[match rangeAtIndex:1]] integerValue];
        NSInteger minor = [[versionId substringWithRange:[match rangeAtIndex:2]] integerValue];
        if (major == 1 && minor <= 40) {
            era = minor >= 17 ? MinecraftEraModern : MinecraftEraLegacy;
            *stop = YES;
        } else if (major >= 26) {
            era = MinecraftEraModern;
            *stop = YES;
        }
    }];
    return era;
}

// Renderer descriptions. `group`: 1 = suits new versions, 2 = suits old versions, 3 = neither in particular
static NSArray<NSDictionary *> *Candidates(void) {
    return @[
        @{@"key": @RENDERER_NAME_MOBILEGL, @"title": @"renderer.picker.mobilegl.title", @"sub": @"renderer.picker.mobilegl.sub",
          @"detail": @"MobileGL (Vulkan)", @"group": @1},
        @{@"key": @RENDERER_NAME_MOBILEGLUES, @"title": @"renderer.picker.mobileglues.title", @"sub": @"renderer.picker.mobileglues.sub",
          @"detail": @"preference.title.renderer.debug.mg", @"group": @1, @"tag": @"experimental"},
        @{@"key": @RENDERER_NAME_GL4ES, @"title": @"renderer.picker.gl4es.title", @"sub": @"renderer.picker.gl4es.sub",
          @"detail": @"preference.title.renderer.debug.gl4es", @"group": @2},
        @{@"key": @RENDERER_NAME_MTL_ANGLE, @"title": @"renderer.picker.angle.title", @"sub": @"renderer.picker.angle.sub",
          @"detail": @"preference.title.renderer.debug.angle", @"group": @3},
        @{@"key": @RENDERER_NAME_VK_ZINK, @"title": @"renderer.picker.zink.title", @"sub": @"renderer.picker.zink.sub",
          @"detail": @"preference.title.renderer.debug.zink", @"group": @3},
    ];
}

static NSDictionary *AutoEntry(void) {
    return @{@"key": @"auto", @"title": @"renderer.picker.auto.title", @"sub": @"renderer.picker.auto.sub", @"tag": @"recommended"};
}

static NSDictionary *DefaultEntry(void) {
    return @{@"key": @"(default)", @"title": @"renderer.picker.default.title", @"sub": @"renderer.picker.default.sub"};
}

NSString *rendererDisplayName(NSString *key) {
    if (key.length == 0 || [key isEqualToString:@"(default)"]) return localize(@"renderer.picker.default.title", nil);
    if ([key isEqualToString:@"auto"]) return localize(@"renderer.picker.auto.title", nil);
    for (NSDictionary *entry in Candidates()) {
        if ([entry[@"key"] isEqualToString:key]) return localize(entry[@"title"], nil);
    }
    return key;
}

PrefPickerOpener RendererPickerOpener(NSString *(^versionProvider)(void), BOOL includeDefault) {
    return ^(UIViewController *host, NSString *current, PrefPickerDone done) {
        LauncherRendererPickerViewController *picker = [[LauncherRendererPickerViewController alloc]
            initWithSelectedKey:current versionId:(versionProvider ? versionProvider() : nil) includeDefault:includeDefault done:done];
        [host.navigationController pushViewController:picker animated:YES];
    };
}

#pragma mark Cell

@interface RendererPickerCell : UITableViewCell
@property(nonatomic) UILabel *titleLabel, *subtitleLabel;
@property(nonatomic) LauncherPillLabel *tagPill;
@property(nonatomic) UIStackView *titleRow;
- (void)setTitle:(NSString *)title subtitle:(NSString *)subtitle tag:(NSString *)tag;
@end

@implementation RendererPickerCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    self.backgroundColor = LauncherTheme.rowBackground;
    self.titleLabel = [UILabel new];
    self.titleLabel.font = LauncherTheme.rowTitleFont;
    self.titleLabel.textColor = UIColor.labelColor;
    self.subtitleLabel = [UILabel new];
    self.subtitleLabel.font = LauncherTheme.subtitleFont;
    self.subtitleLabel.textColor = UIColor.secondaryLabelColor;
    self.subtitleLabel.numberOfLines = 0;
    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.titleRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, spacer]];
    self.titleRow.spacing = 10;
    self.titleRow.alignment = UIStackViewAlignmentCenter;
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleRow, self.subtitleLabel]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 4;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [column.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
        [column.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
        [column.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
    ]];
    return self;
}

- (void)setTitle:(NSString *)title subtitle:(NSString *)subtitle tag:(NSString *)tag {
    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;
    self.subtitleLabel.hidden = subtitle.length == 0;
    [self.tagPill removeFromSuperview];
    self.tagPill = nil;
    if (tag) {
        BOOL recommended = [tag isEqualToString:@"recommended"];
        self.tagPill = [LauncherPillLabel pillWithText:localize(recommended ? @"renderer.picker.tag.recommended" : @"renderer.picker.tag.experimental", nil)
                                             color:recommended ? UIColor.systemGreenColor : UIColor.systemOrangeColor];
        [self.titleRow insertArrangedSubview:self.tagPill atIndex:1];
    }
}

@end

#pragma mark Picker

@interface LauncherRendererPickerViewController ()
@property(nonatomic) NSString *selectedKey, *versionId;
@property(nonatomic) BOOL includeDefault, expanded;
@property(nonatomic, copy) PrefPickerDone done;
/// Each section: @{header, entries, footer, technical (BOOL), more (BOOL)}
@property(nonatomic) NSArray<NSDictionary *> *sections;
@property(nonatomic) NSArray<NSDictionary *> *hiddenEntries;
@end

@implementation LauncherRendererPickerViewController

- (instancetype)initWithSelectedKey:(NSString *)key versionId:(NSString *)versionId includeDefault:(BOOL)includeDefault done:(PrefPickerDone)done {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = localize(@"preference.title.renderer", nil);
    self.selectedKey = key.length > 0 ? key : (includeDefault ? @"(default)" : @"auto");
    self.versionId = versionId;
    self.includeDefault = includeDefault;
    self.done = done;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = LauncherTheme.panelBackground;
    [self.tableView registerClass:RendererPickerCell.class forCellReuseIdentifier:@"renderer"];
    if (self.versionId.length > 0) {
        self.navigationItem.prompt = [NSString stringWithFormat:localize(@"renderer.picker.for_version", nil), self.versionId];
    }
    [self rebuildSections];
}

- (void)rebuildSections {
    MinecraftEra era = EraOfVersionId(self.versionId);
    NSMutableArray<NSDictionary *> *shown = [NSMutableArray new], *hidden = [NSMutableArray new];
    for (NSDictionary *entry in Candidates()) {
        NSInteger group = [entry[@"group"] integerValue];
        BOOL suits = era == MinecraftEraUnknown || (era == MinecraftEraModern && group == 1) || (era == MinecraftEraLegacy && group == 2);
        // Never hide the renderer that is currently chosen
        if (suits || [entry[@"key"] isEqualToString:self.selectedKey]) [shown addObject:entry]; else [hidden addObject:entry];
    }
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray new];
    NSMutableArray *recommended = [NSMutableArray new];
    if (self.includeDefault) [recommended addObject:DefaultEntry()];
    [recommended addObject:AutoEntry()];
    [sections addObject:@{@"header": @"renderer.picker.section.recommended", @"entries": recommended}];
    NSArray *titles = @[@"", @"renderer.picker.section.modern", @"renderer.picker.section.legacy", @"renderer.picker.section.other"];
    for (NSInteger group = 1; group <= 3; group++) {
        NSMutableArray *entries = [NSMutableArray new];
        for (NSDictionary *entry in shown) if ([entry[@"group"] integerValue] == group) [entries addObject:entry];
        if (entries.count > 0) [sections addObject:@{@"header": titles[group], @"entries": entries}];
    }
    self.hiddenEntries = hidden;
    if (hidden.count > 0) {
        if (self.expanded) {
            [sections addObject:@{@"header": @"renderer.picker.section.all", @"entries": hidden, @"technical": @YES}];
        } else {
            NSString *footer = [NSString stringWithFormat:localize(@"renderer.picker.hidden_footer", nil), (long)hidden.count];
            [sections addObject:@{@"header": @"renderer.picker.section.more", @"more": @YES, @"entries": @[@{}], @"footer": footer}];
        }
    }
    self.sections = sections;
}

#pragma mark UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"entries"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return localize(self.sections[section][@"header"], nil).uppercaseString;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.sections[section][@"footer"];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    UITableViewHeaderFooterView *header = (id)view;
    header.textLabel.font = LauncherTheme.headerFont;
    header.textLabel.textColor = UIColor.secondaryLabelColor;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *section = self.sections[indexPath.section];
    RendererPickerCell *cell = [tableView dequeueReusableCellWithIdentifier:@"renderer" forIndexPath:indexPath];
    if ([section[@"more"] boolValue]) {
        [cell setTitle:localize(@"renderer.picker.show_all", nil) subtitle:nil tag:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    NSDictionary *entry = section[@"entries"][indexPath.row];
    BOOL technical = [section[@"technical"] boolValue];
    // The expanded list keeps the old technical name (OpenGL version etc.) as the grey line
    NSString *subtitle = technical ? localize(entry[@"detail"], nil) : localize(entry[@"sub"], nil);
    [cell setTitle:localize(entry[@"title"], nil) subtitle:subtitle tag:entry[@"tag"]];
    BOOL selected = [entry[@"key"] isEqualToString:self.selectedKey];
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor colorWithRed:0xb5/255.0 green:0x7b/255.0 blue:0xde/255.0 alpha:1];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *section = self.sections[indexPath.section];
    if ([section[@"more"] boolValue]) {
        self.expanded = YES;
        [self rebuildSections];
        [tableView reloadData];
        return;
    }
    NSString *key = section[@"entries"][indexPath.row][@"key"];
    if (self.done) self.done(key);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
