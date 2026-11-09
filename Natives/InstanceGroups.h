#import <UIKit/UIKit.h>

/// User-made instance groups, like Prism Launcher's. Each instance's group is stored in its launcher profile
/// under InstanceGroupProfileKey; a missing or empty value means "no group". A group exists while at least one
/// instance is in it.
extern NSString *const InstanceGroupProfileKey;

@interface InstanceGroups : NSObject

/// The trimmed group name, or nil when the profile has no group
+ (NSString *)groupOfProfile:(NSDictionary *)profile;

/// Every group name in use, sorted the way Finder sorts names
+ (NSArray<NSString *> *)allGroupNames;

+ (NSArray<NSString *> *)instancesInGroup:(NSString *)group;

/// Sets (nil or empty: clears) the group of the given instances and saves. Rolls back and returns NO if saving fails.
/// Posts PLProfilesDidChangeNotification on success.
+ (BOOL)setGroup:(NSString *)group forInstances:(NSArray<NSString *> *)names;

/// Asks for a group name; completion only runs with a trimmed, non-empty name
+ (void)promptForGroupNameFrom:(UIViewController *)presenter title:(NSString *)title initial:(NSString *)initial
    completion:(void (^)(NSString *name))completion;

/// Menu items to pick a group: "No Group", every existing group (the current one checked) and "New Group…".
/// onPick gets the chosen name, or nil for "No Group".
+ (NSArray<UIMenuElement *> *)pickerMenuElementsWithCurrent:(NSString *)current presenter:(UIViewController *)presenter
    onPick:(void (^)(NSString *group))onPick;

@end
