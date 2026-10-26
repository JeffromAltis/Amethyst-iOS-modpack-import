/*
 * Controller key binder, ported from Android Amethyst's GamepadMapperFragment /
 * GamepadMapperAdapter: one row per controller input with Android's icons, up
 * to four keys per input, toggleable buttons, separate in-menu and in-game
 * mappings, live highlighting of the button being pressed, and "hold Select
 * to exit". Changes are saved to the current mapping file as they're made.
 */

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#import "input/GamepadMap.h"
#import "FileListViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPrefContCfgViewController.h"
#import "PickTextField.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#include "glfw_keycodes.h"

#define MODE_MENU 0
#define MODE_GAME 1
#define EXIT_HOLD_SECONDS 0.4
#define STICK_DEADZONE 0.3

static NSString *mapperString(NSString *key) {
    return localize([@"controller_mapper." stringByAppendingString:key], nil);
}

#pragma mark - Row cell

@interface GamepadMapperCell : UITableViewCell
@property(nonatomic) UIImageView *buttonIcon;
@property(nonatomic) UILabel *keycodeLabel;
@property(nonatomic) UIImageView *expandIndicator;
@property(nonatomic) UIStackView *expandedView;
@property(nonatomic) NSArray<PickTextField *> *keyFields;
@property(nonatomic) UIView *toggleRow;
@property(nonatomic) UISwitch *toggleSwitch;
@property(nonatomic) BOOL expanded;
@end

@implementation GamepadMapperCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    self.buttonIcon = [[UIImageView alloc] init];
    self.buttonIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.buttonIcon.isAccessibilityElement = YES;
    [self.buttonIcon.widthAnchor constraintEqualToConstant:52].active = YES;
    [self.buttonIcon.heightAnchor constraintEqualToConstant:52].active = YES;

    self.keycodeLabel = [[UILabel alloc] init];
    self.keycodeLabel.numberOfLines = 2;
    self.keycodeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.keycodeLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    [self.keycodeLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    self.expandIndicator = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"SpinnerArrow"]];
    self.expandIndicator.contentMode = UIViewContentModeScaleAspectFit;
    self.expandIndicator.tintColor = UIColor.secondaryLabelColor;
    self.expandIndicator.accessibilityLabel = mapperString(@"expand_entry");
    [self.expandIndicator.widthAnchor constraintEqualToConstant:20].active = YES;
    [self.expandIndicator.heightAnchor constraintEqualToConstant:20].active = YES;

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.buttonIcon, self.keycodeLabel, self.expandIndicator]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.spacing = 16;

    // Expanded part: two rows of "[key] + [key]" and the toggle switch
    NSMutableArray *fields = [NSMutableArray array];
    NSMutableArray *keyRows = [NSMutableArray array];
    for (int row = 0; row < 2; row++) {
        PickTextField *first = [self makeKeyField];
        PickTextField *second = [self makeKeyField];
        UILabel *plus = [[UILabel alloc] init];
        plus.text = @"+"; // A single "plus" sign does not need translation
        plus.textColor = UIColor.labelColor;
        [plus setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *keyRow = [[UIStackView alloc] initWithArrangedSubviews:@[first, plus, second]];
        keyRow.axis = UILayoutConstraintAxisHorizontal;
        keyRow.alignment = UIStackViewAlignmentCenter;
        keyRow.spacing = 12;
        [first.widthAnchor constraintEqualToAnchor:second.widthAnchor].active = YES;
        [fields addObjectsFromArray:@[first, second]];
        [keyRows addObject:keyRow];
    }
    self.keyFields = fields;

    UILabel *toggleLabel = [[UILabel alloc] init];
    toggleLabel.text = mapperString(@"toggleable");
    self.toggleSwitch = [[UISwitch alloc] init];
    UIStackView *toggleRow = [[UIStackView alloc] initWithArrangedSubviews:@[toggleLabel, self.toggleSwitch]];
    toggleRow.axis = UILayoutConstraintAxisHorizontal;
    toggleRow.alignment = UIStackViewAlignmentCenter;
    self.toggleRow = toggleRow;

    self.expandedView = [[UIStackView alloc] initWithArrangedSubviews:@[keyRows[0], keyRows[1], toggleRow]];
    self.expandedView.axis = UILayoutConstraintAxisVertical;
    self.expandedView.spacing = 10;
    self.expandedView.hidden = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, self.expandedView]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 10;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:content];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [content.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
    ]];

    [self setExpanded:NO];
    return self;
}

- (PickTextField *)makeKeyField {
    PickTextField *field = [[PickTextField alloc] init];
    field.textAlignment = NSTextAlignmentCenter;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.adjustsFontSizeToFitWidth = YES;
    field.minimumFontSize = 10;
    field.tintColor = UIColor.clearColor; // no caret, the picker does the editing
    field.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    [field.heightAnchor constraintEqualToConstant:44].active = YES;
    return field;
}

- (void)setExpanded:(BOOL)expanded {
    _expanded = expanded;
    self.expandedView.hidden = !expanded;
    // Same as Android: arrow points down when collapsed, up when expanded
    self.expandIndicator.transform = expanded ? CGAffineTransformIdentity : CGAffineTransformMakeRotation(M_PI);
}

- (void)setPressed:(BOOL)pressed {
    // Android highlights with 0x2000FF00
    self.contentView.backgroundColor = pressed ? [UIColor colorWithRed:0 green:1 blue:0 alpha:0x20/255.0] : UIColor.clearColor;
}

@end

#pragma mark - Mapper

@interface LauncherPrefContCfgViewController ()<UITextFieldDelegate, UIPickerViewDataSource, UIPickerViewDelegate, UIPopoverPresentationControllerDelegate>
@property(nonatomic) NSMutableDictionary *currentMappings;
@property(nonatomic) NSMutableArray<NSString *> *keyNames;
@property(nonatomic) NSMutableArray<NSNumber *> *keyValues;
@property(nonatomic) UIPickerView *keyPicker;
@property(nonatomic) PickTextField *activeField;
@property(nonatomic) UISegmentedControl *modeControl;
@property(nonatomic) NSMutableSet<NSNumber *> *expandedRows;
@property(nonatomic) NSMutableSet<NSNumber *> *pressedRows;
@property(nonatomic) NSMutableArray<GCController *> *listenedControllers;
@property(nonatomic) id connectObserver;
@property(nonatomic) NSTimer *exitTimer;
@end

@implementation LauncherPrefContCfgViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"preference.title.default_gamepad_ctrl", nil);

    self.keyNames = [NSMutableArray array];
    self.keyValues = [NSMutableArray array];
    GamepadMap_pickerKeycodes(self.keyNames, self.keyValues);
    self.expandedRows = [NSMutableSet set];
    self.pressedRows = [NSMutableSet set];
    self.listenedControllers = [NSMutableArray array];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.tableHeaderView = [self makeHeaderView];

    self.keyPicker = [[UIPickerView alloc] init];
    self.keyPicker.delegate = self;
    self.keyPicker.dataSource = self;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:mapperString(@"save_as") style:UIBarButtonItemStylePlain target:self action:@selector(actionSaveAs)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    [self loadMappings];
}

- (UIView *)makeHeaderView {
    // "Hold [Select] to exit" on one side, the operating mode on the other, like Android
    UILabel *holdLabel = [[UILabel alloc] init];
    holdLabel.text = mapperString(@"exit_part1");
    UIImageView *selectIcon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Gamepad_button_select"]];
    selectIcon.accessibilityLabel = mapperString(@"controller_button_select");
    [selectIcon.widthAnchor constraintEqualToConstant:30].active = YES;
    [selectIcon.heightAnchor constraintEqualToConstant:30].active = YES;
    UILabel *exitLabel = [[UILabel alloc] init];
    exitLabel.text = mapperString(@"exit_part2");
    UIStackView *exitHint = [[UIStackView alloc] initWithArrangedSubviews:@[holdLabel, selectIcon, exitLabel]];
    exitHint.alignment = UIStackViewAlignmentCenter;
    exitHint.spacing = 6;

    UILabel *modeLabel = [[UILabel alloc] init];
    modeLabel.text = mapperString(@"operating_mode");
    modeLabel.textAlignment = NSTextAlignmentCenter;
    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[mapperString(@"mode_menus"), mapperString(@"mode_ingame")]];
    self.modeControl.selectedSegmentIndex = MODE_MENU;
    [self.modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    UIStackView *mode = [[UIStackView alloc] initWithArrangedSubviews:@[modeLabel, self.modeControl]];
    mode.axis = UILayoutConstraintAxisVertical;
    mode.alignment = UIStackViewAlignmentCenter;
    mode.spacing = 6;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[exitHint, mode]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.distribution = UIStackViewDistributionEqualCentering;
    header.alignment = UIStackViewAlignmentCenter;
    header.layoutMarginsRelativeArrangement = YES;
    header.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12, 20, 4, 20);
    header.frame = CGRectMake(0, 0, 320, 84);
    return header;
}

- (NSString *)currentFilePath {
    return [NSString stringWithFormat:@"%s/controlmap/gamepads/%@", getenv("AME_HOME"), getPrefObject(@"control.default_gamepad_ctrl")];
}

- (void)loadMappings {
    self.currentMappings = GamepadMap_loadFile(self.currentFilePath);
    if (!self.currentMappings) {
        self.currentMappings = [NSMutableDictionary dictionary];
        GamepadMap_normalize(self.currentMappings);
    }
    [self.expandedRows removeAllObjects];
    [self.tableView reloadData];
}

- (void)saveMappings {
    NSError *error;
    if (!GamepadMap_saveFile(self.currentMappings, self.currentFilePath, &error)) {
        showDialog(localize(@"custom_controls.control_menu.save.error.write", nil), error.localizedDescription);
    }
}

- (BOOL)inGame {
    return self.modeControl.selectedSegmentIndex == MODE_GAME;
}

- (NSMutableArray *)currentList {
    return self.currentMappings[self.inGame ? @"mGameMappingList" : @"mMenuMappingList"];
}

- (void)modeChanged {
    [self.view endEditing:YES];
    [self.pressedRows removeAllObjects];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : GamepadMap_catalog().count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? mapperString(@"section.file") : mapperString(@"section.bindings");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? mapperString(@"section.bindings.footer") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"file"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"file"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.textLabel.text = localize(@"controller_configurator.title.current", nil);
        cell.detailTextLabel.text = getPrefObject(@"control.default_gamepad_ctrl");
        return cell;
    }

    GamepadMapperCell *cell = [tableView dequeueReusableCellWithIdentifier:@"mapping"];
    if (!cell) {
        cell = [[GamepadMapperCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"mapping"];
        for (PickTextField *field in cell.keyFields) {
            field.delegate = self;
            field.inputView = self.keyPicker;
            [field setupDoneButtonWithTarget:self action:@selector(closeKeyPicker)];
        }
        [cell.toggleSwitch addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    }

    NSDictionary *catalogEntry = GamepadMap_catalog()[indexPath.row];
    NSDictionary *entry = self.currentList[indexPath.row];
    cell.buttonIcon.image = [UIImage imageNamed:GamepadMap_iconName(catalogEntry, self.inGame)];
    cell.buttonIcon.accessibilityLabel = mapperString(catalogEntry[@"label"]);
    cell.keycodeLabel.text = GamepadMap_summary(entry);
    for (int i = 0; i < GAMEPAD_MAP_KEYCODE_COUNT; i++) {
        PickTextField *field = cell.keyFields[i];
        field.tag = indexPath.row * GAMEPAD_MAP_KEYCODE_COUNT + i;
        field.text = GamepadMap_keycodeName([entry[@"keycodes"][i] intValue]);
    }
    // Stick directions aren't physical buttons, so they can't toggle (as on Android)
    BOOL physical = ![catalogEntry[@"direction"] boolValue];
    cell.toggleRow.hidden = !physical;
    cell.toggleSwitch.on = physical && [entry[@"toggleable"] boolValue];
    cell.toggleSwitch.tag = indexPath.row;
    cell.expanded = [self.expandedRows containsObject:@(indexPath.row)];
    [cell setPressed:[self.pressedRows containsObject:@(indexPath.row)]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.section == 0) {
        [self actionLoad];
        return;
    }
    NSNumber *row = @(indexPath.row);
    BOOL expand = ![self.expandedRows containsObject:row];
    if (expand) [self.expandedRows addObject:row];
    else [self.expandedRows removeObject:row];

    GamepadMapperCell *cell = (id)[tableView cellForRowAtIndexPath:indexPath];
    [tableView beginUpdates];
    cell.expanded = expand;
    [tableView endUpdates];
}

#pragma mark Editing

- (void)toggleChanged:(UISwitch *)sender {
    self.currentList[sender.tag][@"toggleable"] = @(sender.on);
    [self saveMappings];
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    self.activeField = (PickTextField *)textField;
    NSInteger row = textField.tag / GAMEPAD_MAP_KEYCODE_COUNT;
    NSInteger slot = textField.tag % GAMEPAD_MAP_KEYCODE_COUNT;
    NSUInteger index = [self.keyValues indexOfObject:self.currentList[row][@"keycodes"][slot]];
    [self.keyPicker reloadAllComponents];
    [self.keyPicker selectRow:(index == NSNotFound ? 0 : index) inComponent:0 animated:NO];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    self.activeField = nil;
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    return NO; // picker only
}

- (void)closeKeyPicker {
    [self.activeField endEditing:YES];
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return self.keyNames.count;
}

- (UIView *)pickerView:(UIPickerView *)pickerView viewForRow:(NSInteger)row forComponent:(NSInteger)component reusingView:(UIView *)view {
    UILabel *label = (UILabel *)view ?: [UILabel new];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = self.keyNames[row];
    return label;
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    PickTextField *field = self.activeField;
    if (!field) return;
    NSInteger entryRow = field.tag / GAMEPAD_MAP_KEYCODE_COUNT;
    NSInteger slot = field.tag % GAMEPAD_MAP_KEYCODE_COUNT;
    NSMutableDictionary *entry = self.currentList[entryRow];
    NSMutableArray *keycodes = [entry[@"keycodes"] mutableCopy];
    keycodes[slot] = self.keyValues[row];
    entry[@"keycodes"] = keycodes;
    field.text = self.keyNames[row];

    GamepadMapperCell *cell = (id)[self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:entryRow inSection:1]];
    cell.keycodeLabel.text = GamepadMap_summary(entry);
    [self saveMappings];
}

#pragma mark Live controller feedback

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    for (GCController *controller in GCController.controllers) {
        [self listenToController:controller];
    }
    __weak __typeof__(self) weakSelf = self;
    self.connectObserver = [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        [weakSelf listenToController:note.object];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self.connectObserver];
    self.connectObserver = nil;
    for (GCController *controller in self.listenedControllers) {
        controller.extendedGamepad.valueChangedHandler = nil;
    }
    [self.listenedControllers removeAllObjects];
    [self.exitTimer invalidate];
    self.exitTimer = nil;
}

- (void)listenToController:(GCController *)controller {
    if (!controller.extendedGamepad || [self.listenedControllers containsObject:controller]) return;
    [self.listenedControllers addObject:controller];
    __weak __typeof__(self) weakSelf = self;
    controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        [weakSelf gamepadChanged:gamepad];
    };
}

static BOOL isPressed(GCControllerButtonInput *button) {
    return button != nil && button.isPressed;
}

- (void)gamepadChanged:(GCExtendedGamepad *)gamepad {
    // Directions come from the stick that moves in the shown mode
    GCControllerDirectionPad *stick = self.inGame ? gamepad.leftThumbstick : gamepad.rightThumbstick;
    float x = stick.xAxis.value, y = stick.yAxis.value;
    BOOL deflected = x * x + y * y >= STICK_DEADZONE * STICK_DEADZONE;
    // Same 8-way split as the in-game translation
    float degree = atan2f(y, x) * (180.0 / M_PI);
    if (degree < 0) degree += 360;
    int direction = deflected ? (int)((degree + 22.5) / 45.0) % 8 : -1;

    NSDictionary<NSNumber *, NSNumber *> *states = @{
        @(GLFW_GAMEPAD_BUTTON_A): @(isPressed(gamepad.buttonA)),
        @(GLFW_GAMEPAD_BUTTON_B): @(isPressed(gamepad.buttonB)),
        @(GLFW_GAMEPAD_BUTTON_X): @(isPressed(gamepad.buttonX)),
        @(GLFW_GAMEPAD_BUTTON_Y): @(isPressed(gamepad.buttonY)),
        @(GLFW_GAMEPAD_BUTTON_START): @(isPressed(gamepad.buttonMenu)),
        @(GLFW_GAMEPAD_BUTTON_BACK): @(isPressed(gamepad.buttonOptions)),
        @(GLFW_GAMEPAD_BUTTON_RIGHT_TRIGGER): @(isPressed(gamepad.rightTrigger)),
        @(GLFW_GAMEPAD_BUTTON_LEFT_TRIGGER): @(isPressed(gamepad.leftTrigger)),
        @(GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER): @(isPressed(gamepad.rightShoulder)),
        @(GLFW_GAMEPAD_BUTTON_LEFT_BUMPER): @(isPressed(gamepad.leftShoulder)),
        @(GLFW_GAMEPAD_BUTTON_RIGHT_THUMB): @(isPressed(gamepad.rightThumbstickButton)),
        @(GLFW_GAMEPAD_BUTTON_LEFT_THUMB): @(isPressed(gamepad.leftThumbstickButton)),
        @(GLFW_GAMEPAD_BUTTON_DPAD_UP): @(isPressed(gamepad.dpad.up)),
        @(GLFW_GAMEPAD_BUTTON_DPAD_DOWN): @(isPressed(gamepad.dpad.down)),
        @(GLFW_GAMEPAD_BUTTON_DPAD_RIGHT): @(isPressed(gamepad.dpad.right)),
        @(GLFW_GAMEPAD_BUTTON_DPAD_LEFT): @(isPressed(gamepad.dpad.left)),
        @(GAMEPAD_DIRECTION_FORWARD): @(direction >= 1 && direction <= 3),
        @(GAMEPAD_DIRECTION_LEFT): @(direction >= 3 && direction <= 5),
        @(GAMEPAD_DIRECTION_BACKWARD): @(direction >= 5 && direction <= 7),
        @(GAMEPAD_DIRECTION_RIGHT): @(direction == 7 || direction == 0 || direction == 1),
    };

    NSArray *catalog = GamepadMap_catalog();
    for (NSUInteger row = 0; row < catalog.count; row++) {
        BOOL pressed = [states[catalog[row][@"button"]] boolValue];
        if (pressed == [self.pressedRows containsObject:@(row)]) continue;
        if (pressed) [self.pressedRows addObject:@(row)];
        else [self.pressedRows removeObject:@(row)];
        GamepadMapperCell *cell = (id)[self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:1]];
        [cell setPressed:pressed];
    }

    // Hold Select to exit, like Android
    BOOL selectHeld = isPressed(gamepad.buttonOptions);
    if (selectHeld && !self.exitTimer) {
        __weak __typeof__(self) weakSelf = self;
        self.exitTimer = [NSTimer scheduledTimerWithTimeInterval:EXIT_HOLD_SECONDS repeats:NO block:^(NSTimer *timer) {
            [weakSelf actionClose];
        }];
    } else if (!selectHeld && self.exitTimer) {
        [self.exitTimer invalidate];
        self.exitTimer = nil;
    }
}

#pragma mark File actions

- (void)actionLoad {
    FileListViewController *vc = [[FileListViewController alloc] init];
    vc.listPath = [NSString stringWithFormat:@"%s/controlmap/gamepads", getenv("AME_HOME")];
    __weak __typeof__(self) weakSelf = self;
    vc.whenItemSelected = ^(NSString *name) {
        setPrefObject(@"control.default_gamepad_ctrl", [NSString stringWithFormat:@"%@.json", name]);
        [weakSelf loadMappings];
    };
    vc.modalPresentationStyle = UIModalPresentationPopover;
    vc.preferredContentSize = CGSizeMake(350, 250);
    UIPopoverPresentationController *popover = vc.popoverPresentationController;
    popover.sourceView = self.tableView;
    popover.sourceRect = [self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    popover.delegate = self;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)actionSaveAs {
    UIAlertController *controller = [UIAlertController alertControllerWithTitle:mapperString(@"save_as") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [controller addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Name";
        textField.text = [getPrefObject(@"control.default_gamepad_ctrl") stringByDeletingPathExtension];
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = controller.textFields[0].text;
        if (name.length == 0) return;
        setPrefObject(@"control.default_gamepad_ctrl", [name stringByAppendingPathExtension:@"json"]);
        [self saveMappings];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
    }]];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)actionClose {
    [self.view endEditing:YES];
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

@end
