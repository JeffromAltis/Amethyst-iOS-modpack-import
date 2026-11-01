#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherProfileEditorViewController.h"
#import "MinecraftResourceUtils.h"
#import "PickTextField.h"
#import "PLProfiles.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface LauncherProfileEditorViewController()<UIPickerViewDataSource, UIPickerViewDelegate>
@property(nonatomic) NSString* oldName;

@property(nonatomic) NSArray<NSDictionary *> *versionList;
@property(nonatomic) PickTextField* versionTextField;
@property(nonatomic) UISegmentedControl* versionTypeControl;
@property(nonatomic) UIPickerView* versionPickerView;
@property(nonatomic) UIToolbar* versionPickerToolbar;
@property(nonatomic) NSInteger versionSelectedAt;
@end

@implementation LauncherProfileEditorViewController

- (void)viewDidLoad {
    // Setup navigation bar & appearance
    self.title = localize(@"Edit profile", nil);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = YES;
    self.prefSectionsVisible = YES;

    // Setup preference getter and setter
    __weak LauncherProfileEditorViewController *weakSelf = self;
    self.getPreference = ^id(NSString *section, NSString *key){
        NSString *value = weakSelf.profile[key];
        if (value.length > 0 || ![weakSelf isPickFieldAtSection:section key:key]) {
            return value;
        } else {
            return @"(default)";
        }
    };
    self.setPreference = ^(NSString *section, NSString *key, NSString *value){
        if ([value isEqualToString:@"(default)"] && [weakSelf isPickFieldAtSection:section key:key]) {
            [weakSelf.profile removeObjectForKey:key];
        } else if (value) {
            weakSelf.profile[key] = value;
        }
    };

    // Obtain all the lists
    self.oldName = self.getPreference(nil, @"name");
    if ([self.oldName length] == 0) {
        self.setPreference(nil, @"name", @"New Profile");
    }
    NSArray *rendererKeys = getRendererKeys(YES);
    NSArray *rendererList = getRendererNames(YES);
    NSArray *touchControlList = [self listFilesAtPath:[NSString stringWithFormat:@"%s/controlmap", getenv("AME_HOME")]];
    NSArray *gamepadControlList = [self listFilesAtPath:[NSString stringWithFormat:@"%s/controlmap/gamepads", getenv("AME_HOME")]];
    NSMutableArray *javaList = [getPrefObject(@"java.java_homes") allKeys].mutableCopy ?: [NSMutableArray new];
    [javaList removeObject:@"0"];
    [javaList sortUsingSelector:@selector(compare:)];
    [javaList insertObject:@"(default)" atIndex:0];

    // Setup version picker
    [self setupVersionPicker];
    id typeVersionPicker = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item){
        self.typeTextField(cell, section, key, item);
        PickTextField *textField = (id)cell.accessoryView;
        weakSelf.versionTextField = textField;
        textField.inputAccessoryView = weakSelf.versionPickerToolbar;
        textField.inputView = weakSelf.versionPickerView;
        // Auto pick version type
        if (self.versionList) return;
        if ([MinecraftResourceUtils findVersion:textField.text inList:localVersionList]) {
            self.versionTypeControl.selectedSegmentIndex = 0;
        } else {
            NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:textField.text inList:remoteVersionList];
            if (selected) {
                NSArray *types = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"];
                NSString *type = selected[@"type"];
                self.versionTypeControl.selectedSegmentIndex = [types indexOfObject:type];
            } else {
                // Version not found
                self.versionTypeControl.selectedSegmentIndex = 0;
            }
        }
        self.versionSelectedAt = -1;
        [self changeVersionType:nil];
    };

    self.prefContents = @[
        @[
            // General settings
            @{@"key": @"name",
              @"icon": @"tag",
              @"title": @"preference.profile.title.name",
              @"type": self.typeTextField,
              @"placeholder": self.oldName
            },
            @{@"key": @"lastVersionId",
              @"icon": @"archivebox",
              @"title": @"preference.profile.title.version",
              @"type": typeVersionPicker,
              @"placeholder": self.getPreference(nil, @"lastVersionId"),
              @"customClass": PickTextField.class
            },
            @{@"key": @"gameDir",
              @"icon": @"folder",
              @"title": @"preference.title.game_directory",
              @"type": self.typeTextField,
              @"placeholder": @"./instances/<instance name>"
            },
            // Video and renderer settings
            @{@"key": @"renderer",
              @"icon": @"cpu",
              @"type": self.typePickField,
              @"pickKeys": rendererKeys,
              @"pickList": rendererList
            },
            // Control settings
            @{@"key": @"defaultTouchCtrl",
              @"icon": @"hand.tap",
              @"title": @"preference.profile.title.default_touch_control",
              @"type": self.typePickField,
              @"pickKeys": touchControlList,
              @"pickList": touchControlList
            },
            @{@"key": @"defaultGamepadCtrl",
              @"icon": @"gamecontroller",
              @"title": @"preference.profile.title.default_gamepad_control",
              @"type": self.typePickField,
              @"pickKeys": gamepadControlList,
              @"pickList": gamepadControlList
            },
            @{@"key": @"gamepadPassthrough",
              @"icon": @"arrow.right.circle",
              @"title": @"preference.profile.title.gamepad_passthrough",
              @"type": self.typePickField,
              @"pickKeys": @[@"(default)", @"true", @"false"],
              @"pickList": @[
                  @"(default)",
                  localize(@"preference.profile.gamepad_passthrough.on", nil),
                  localize(@"preference.profile.gamepad_passthrough.off", nil)
              ]
            },
            // Java tweaks
            @{@"key": @"javaVersion",
              @"icon": @"cube",
              @"title": @"preference.manage_runtime.header.default",
              @"type": self.typePickField,
              @"pickKeys": javaList,
              @"pickList": javaList
            },
            @{@"key": @"javaArgs",
              @"icon": @"slider.vertical.3",
              @"title": @"preference.title.java_args",
              @"type": self.typeTextField,
              @"placeholder": @"(default)"
            }
        ]
    ];

    [super viewDidLoad];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionDone {
    if (self.oldName.length > 0 && !PLProfiles.current.profiles[self.oldName]) {
        showDialog(localize(@"Error", nil), @"This profile was removed while it was being edited. Close the editor and select an existing instance.");
        return;
    }
    // We might be saving without ending editing, so make sure textFieldDidEndEditing is always called
    UITextField *currentTextField = [self performSelector:@selector(_firstResponder)];
    if ([currentTextField isKindOfClass:UITextField.class] && [currentTextField isDescendantOfView:self.tableView]) {
        [self textFieldDidEndEditing:currentTextField];
    }

    if ([self.profile[@"name"] length] == 0 && self.oldName.length > 0) {
        // Return to its old name
        self.profile[@"name"] = self.oldName;
    }

    NSMutableDictionary *previousProfiles = PLProfiles.current.profiles.mutableCopy;
    NSString *previousSelection = PLProfiles.current.selectedProfileName;
    if ([self.oldName isEqualToString:self.profile[@"name"]]) {
        // Not a rename, directly create/replace
        PLProfiles.current.profiles[self.oldName] = self.profile;
    } else if (!PLProfiles.current.profiles[self.profile[@"name"]]) {
        // A rename, remove then re-add to update its key name
        if (self.oldName.length > 0) {
            [PLProfiles.current.profiles removeObjectForKey:self.oldName];
        }
        PLProfiles.current.profiles[self.profile[@"name"]] = self.profile;
        // Update selected name
        if ([PLProfiles.current.selectedProfileName isEqualToString:self.oldName]) {
            PLProfiles.current.profileDict[@"selectedProfile"] = self.profile[@"name"];
        }
    } else {
        // Cancel rename since a profile with the same name already exists
        showDialog(localize(@"Error", nil), localize(@"profile.error.name_exists", nil));
        // Skip dismissing this view controller
        return;
    }

    if (![PLProfiles.current save]) {
        PLProfiles.current.profileDict[@"profiles"] = previousProfiles;
        PLProfiles.current.profileDict[@"selectedProfile"] = previousSelection;
        return;
    }
    BOOL isNewProfile = self.oldName.length == 0;
    UIViewController *presenter = self.presentingViewController;
    [self actionClose];

    UISplitViewController *split = [presenter isKindOfClass:UISplitViewController.class] ? (id)presenter : nil;
    if (split) {
        // Refresh whatever is on screen (instance list or dashboard)
        UINavigationController *navVC = (id)split.viewControllers[1];
        [navVC.viewControllers[0] viewWillAppear:NO];
        if (isNewProfile) {
            // A new profile is a new instance: take the user to its dashboard
            UINavigationController *sidebarNav = (id)split.viewControllers[0];
            LauncherMenuViewController *sidebar = (id)sidebarNav.viewControllers[0];
            if ([sidebar respondsToSelector:@selector(openDashboardForProfile:)]) {
                [sidebar openDashboardForProfile:self.profile[@"name"]];
            }
        }
    }
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
}

- (BOOL)isPickFieldAtSection:(NSString *)section key:(NSString *)key {
    NSDictionary *pref = [self.prefContents[0] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(key == %@)", key]].firstObject;
    return pref[@"type"] == self.typePickField;
}

- (NSArray *)listFilesAtPath:(NSString *)path {
    NSMutableArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil].mutableCopy ?: [NSMutableArray new];
    for (int i = 0; i < files.count;) {
        if ([files[i] hasSuffix:@".json"]) {
            i++;
        } else {
            [files removeObjectAtIndex:i];
        }
    }
    [files insertObject:@"(default)" atIndex:0];
    return files;
}

#pragma mark Version picker

- (void)setupVersionPicker {
    self.versionPickerView = [[UIPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;
    self.versionPickerToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 390, 44.0)];
    self.versionTypeControl = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"Installed", nil),
        localize(@"Releases", nil),
        localize(@"Snapshot", nil),
        localize(@"Old-beta", nil),
        localize(@"Old-alpha", nil)
    ]];
    self.versionTypeControl.frame = CGRectMake(0, 0, 390, 44.0);
    self.versionTypeControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.versionTypeControl addTarget:self action:@selector(changeVersionType:) forControlEvents:UIControlEventValueChanged];
    // here we go some random private apis I found
    [[self.versionTypeControl _uiktest_labelsWithState:0] makeObjectsPerformSelector:@selector(setNumberOfLines:) withObject:nil];
    [self.versionPickerToolbar addSubview:self.versionTypeControl];
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (self.versionList.count == 0) {
        self.versionTextField.text = @"";
        return;
    }
    self.versionSelectedAt = row;
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)thePickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return self.versionList.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    if (self.versionList.count <= row) return nil;
    NSObject *object = self.versionList[row];
    if ([object isKindOfClass:[NSString class]]) {
        return (NSString*) object;
    } else {
        return [object valueForKey:@"id"];
    }
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

- (void)changeVersionType:(UISegmentedControl *)sender {
    NSArray *newVersionList = self.versionList;
    if (sender || !self.versionList) {
        if (self.versionTypeControl.selectedSegmentIndex == 0) {
            // installed
            newVersionList = localVersionList;
        } else {
            NSString *type = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"][self.versionTypeControl.selectedSegmentIndex];
            newVersionList = [remoteVersionList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(type == %@)", type]];
        }
    }

    if (newVersionList.count == 0) {
        self.versionSelectedAt = -1;
    } else if (self.versionSelectedAt == -1) {
        NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:self.versionTextField.text inList:newVersionList];
        NSUInteger index = selected ? [newVersionList indexOfObject:selected] : NSNotFound;
        self.versionSelectedAt = index == NSNotFound ? -1 : (NSInteger)index;
    } else {
        // Find the most matching version for this type
        NSObject *lastSelected = nil; 
        if (self.versionList.count > self.versionSelectedAt) {
            lastSelected = self.versionList[self.versionSelectedAt];
        }
        if (lastSelected != nil) {
            NSObject *nearest = [MinecraftResourceUtils findNearestVersion:lastSelected expectedType:self.versionTypeControl.selectedSegmentIndex];
            if (nearest != nil) {
                NSUInteger index = [newVersionList indexOfObject:(id)nearest];
                if (index != NSNotFound) self.versionSelectedAt = (NSInteger)index;
            }
        }
        lastSelected = nil;
        // Get back the currently selected in case none matching version found
        self.versionSelectedAt = MIN(MAX(self.versionSelectedAt, 0), (NSInteger)newVersionList.count - 1);
    }

    self.versionList = newVersionList;
    [self.versionPickerView reloadAllComponents];
    if (self.versionSelectedAt != -1) {
        [self.versionPickerView selectRow:self.versionSelectedAt inComponent:0 animated:NO];
        [self pickerView:self.versionPickerView didSelectRow:self.versionSelectedAt inComponent:0];
    }
}

@end
