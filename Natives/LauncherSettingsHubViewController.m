#import "HostManagerBridge.h"
#import "LauncherMenuViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherSettingsHubViewController.h"
#import "LauncherTheme.h"
#import "UIKit+hook.h"

#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NSString *(^HubSummary)(void);

// Category entries are plain dictionaries:
//   title    localization key of the category name
//   icon     SF Symbol
//   summary  optional HubSummary block, evaluated every time the page appears
//   keys     preference keys shown on the category page, or
//   exclude  keys NOT shown (the page gets every other row, so no preference can get lost), or
//   children entries of a nested hub
static NSArray<NSString *> *HubKeysGeneral(void) { return @[@"check_sha", @"cosmetica", @"appicon", @"hidden_sidebar"]; }
static NSArray<NSString *> *HubKeysGraphics(void) { return @[@"renderer", @"resolution", @"max_framerate", @"performance_hud", @"fullscreen_airplay"]; }
static NSArray<NSString *> *HubKeysAudio(void) { return @[@"silence_other_audio", @"silence_with_switch", @"allow_microphone"]; }
static NSArray<NSString *> *HubKeysController(void) { return @[@"default_gamepad_ctrl", @"gamepad_passthrough", @"hardware_hide"]; }
static NSArray<NSString *> *HubKeysTouch(void) { return @[@"recording_hide", @"gesture_hotbar", @"disable_haptics", @"slideable_hotbar", @"press_duration", @"button_scale"]; }
static NSArray<NSString *> *HubKeysMouse(void) { return @[@"gesture_mouse", @"mouse_scale", @"mouse_speed", @"virtmouse_enable"]; }
static NSArray<NSString *> *HubKeysGyroscope(void) { return @[@"gyroscope_enable", @"gyroscope_invert_x_axis", @"gyroscope_sensitivity"]; }
static NSArray<NSString *> *HubKeysJava(void) { return @[@"manage_runtime", @"java_args", @"env_variables", @"auto_ram", @"allocated_memory"]; }

static NSArray<NSString *> *HubKeysClaimed(void) {
    NSMutableArray *all = [NSMutableArray new];
    for (NSArray *keys in @[HubKeysGeneral(), HubKeysGraphics(), HubKeysAudio(), HubKeysController(), HubKeysTouch(),
                            HubKeysMouse(), HubKeysGyroscope(), HubKeysJava()]) {
        [all addObjectsFromArray:keys];
    }
    return all;
}

static NSString *HubRendererName(void) {
    NSString *key = getPrefObject(@"video.renderer");
    NSArray *keys = getRendererKeys(YES), *names = getRendererNames(YES);
    NSUInteger index = key ? [keys indexOfObject:key] : NSNotFound;
    if (index == NSNotFound || index >= names.count) return localize(@"preference.hub.value.auto", nil);
    return names[index];
}

static NSString *HubOnOff(BOOL on) {
    return localize(on ? @"preference.hub.value.on" : @"preference.hub.value.off", nil);
}

@interface LauncherSettingsHubViewController ()
@property(nonatomic) NSArray<NSDictionary *> *entries;
@end

@implementation LauncherSettingsHubViewController

+ (NSArray<NSDictionary *> *)controlEntries {
    return @[
        @{@"title": @"preference.hub.controller", @"icon": @"gamecontroller", @"keys": HubKeysController(),
          @"summary": ^NSString *{
              return [NSString stringWithFormat:@"%@ %@", localize(@"preference.title.gamepad_passthrough", nil),
                      HubOnOff(getPrefBool(@"control.gamepad_passthrough")).lowercaseString];
          }},
        @{@"title": @"preference.hub.touch", @"icon": @"hand.tap", @"keys": HubKeysTouch(),
          @"summary": ^NSString *{
              return [NSString stringWithFormat:@"%@ %ld%%", localize(@"preference.hub.button_scale", nil),
                      (long)getPrefInt(@"control.button_scale")];
          }},
        @{@"title": @"preference.hub.mouse", @"icon": @"cursorarrow", @"keys": HubKeysMouse(),
          @"summary": ^NSString *{
              return [NSString stringWithFormat:@"%@ %@", localize(@"preference.title.virtmouse_enable", nil),
                      HubOnOff(getPrefBool(@"control.virtmouse_enable")).lowercaseString];
          }},
        @{@"title": @"preference.hub.gyroscope", @"icon": @"gyroscope", @"keys": HubKeysGyroscope(),
          @"summary": ^NSString *{ return HubOnOff(getPrefBool(@"control.gyroscope_enable")); }},
    ];
}

+ (NSArray<NSDictionary *> *)topLevelEntries {
    return @[
        @{@"title": @"preference.hub.general", @"icon": @"gearshape", @"keys": HubKeysGeneral(),
          @"summary": ^NSString *{ return localize(@"preference.hub.summary.general", nil); }},
        @{@"title": @"preference.hub.graphics", @"icon": @"video", @"keys": HubKeysGraphics(),
          @"summary": ^NSString *{
              return [NSString stringWithFormat:@"%@ · %ld%%", HubRendererName(), (long)getPrefInt(@"video.resolution")];
          }},
        @{@"title": @"preference.hub.audio", @"icon": @"speaker.wave.2", @"keys": HubKeysAudio(),
          @"summary": ^NSString *{ return localize(@"preference.hub.summary.audio", nil); }},
        @{@"title": @"preference.hub.controls", @"icon": @"gamecontroller", @"children": [self controlEntries],
          @"summary": ^NSString *{ return localize(@"preference.hub.summary.controls", nil); }},
        @{@"title": @"preference.hub.java", @"icon": @"cube", @"keys": HubKeysJava(),
          @"summary": ^NSString *{
              if (getPrefBool(@"java.auto_ram")) return localize(@"preference.hub.summary.java_auto", nil);
              return [NSString stringWithFormat:@"%ld MB", (long)getPrefInt(@"java.allocated_memory")];
          }},
        @{@"title": @"preference.hub.advanced", @"icon": @"wrench.and.screwdriver", @"exclude": HubKeysClaimed(),
          @"summary": ^NSString *{ return localize(@"preference.hub.summary.advanced", nil); }},
    ];
}

- (instancetype)init {
    self = [self initWithTitle:localize(@"Settings", nil) entries:[LauncherSettingsHubViewController topLevelEntries]];
    return self;
}

- (instancetype)initWithTitle:(NSString *)title entries:(NSArray<NSDictionary *> *)entries {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = title;
    self.entries = entries;
    return self;
}

- (NSString *)imageName {
    return @"MenuSettings";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = LauncherTheme.panelBackground;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Only the first page of the navigation stack carries the account button, like the other launcher pages
    if (self.navigationController && self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.rightBarButtonItems = @[[sidebarViewController drawAccountButton]];
    }
    // Summaries show live values: refresh them after returning from a category page
    [self.tableView reloadData];
}

#pragma mark UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    // The build information used to be the footer of the general section
    if (self.navigationController.viewControllers.firstObject != self) return nil;
    return [NSString stringWithFormat:@"Angel Aura Amethyst %@-%s (%s/%s)\n%@ on %@ (%s)\nPID: %d",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
        CONFIG_TYPE, CONFIG_BRANCH, CONFIG_COMMIT,
        UIDevice.currentDevice.completeOSVersion, [HostManager GetModelName], getenv("AME_DETECTEDINST"), getpid()];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"hubCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    }
    NSDictionary *entry = self.entries[indexPath.row];
    cell.backgroundColor = LauncherTheme.rowBackground;
    cell.textLabel.text = localize(entry[@"title"], nil);
    cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    HubSummary summary = entry[@"summary"];
    cell.detailTextLabel.text = summary ? summary() : nil;
    cell.imageView.image = [UIImage systemImageNamed:entry[@"icon"]];
    cell.imageView.tintColor = UIColor.secondaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = self.entries[indexPath.row];
    NSString *title = localize(entry[@"title"], nil);
    UIViewController *page;
    if (entry[@"children"]) {
        page = [[LauncherSettingsHubViewController alloc] initWithTitle:title entries:entry[@"children"]];
    } else {
        page = [[LauncherPreferencesViewController alloc] initWithTitle:title keys:entry[@"keys"] excluding:entry[@"exclude"]];
    }
    [self.navigationController pushViewController:page animated:YES];
}

@end
