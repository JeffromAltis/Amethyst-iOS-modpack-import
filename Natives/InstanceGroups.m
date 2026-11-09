#import "InstanceGroups.h"
#import "PLProfiles.h"
#import "utils.h"

NSString *const InstanceGroupProfileKey = @"amethystGroup";

@implementation InstanceGroups

+ (NSString *)trimmed:(NSString *)name {
    if (![name isKindOfClass:NSString.class]) return nil;
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length ? name : nil;
}

+ (NSString *)groupOfProfile:(NSDictionary *)profile {
    if (![profile isKindOfClass:NSDictionary.class]) return nil;
    return [self trimmed:profile[InstanceGroupProfileKey]];
}

+ (NSArray<NSString *> *)allGroupNames {
    NSMutableSet *names = [NSMutableSet new];
    for (NSDictionary *profile in PLProfiles.current.profiles.allValues) {
        NSString *group = [self groupOfProfile:profile];
        if (group) [names addObject:group];
    }
    return [names.allObjects sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

+ (NSArray<NSString *> *)instancesInGroup:(NSString *)group {
    NSMutableArray *names = [NSMutableArray new];
    [PLProfiles.current.profiles enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSDictionary *profile, BOOL *stop) {
        if ([[self groupOfProfile:profile] isEqualToString:group]) [names addObject:name];
    }];
    return names;
}

+ (BOOL)setGroup:(NSString *)group forInstances:(NSArray<NSString *> *)names {
    group = [self trimmed:group];
    NSMutableDictionary *previous = [NSMutableDictionary new];
    for (NSString *name in names) {
        NSMutableDictionary *profile = PLProfiles.current.profiles[name];
        if (![profile isKindOfClass:NSMutableDictionary.class]) continue;
        previous[name] = profile[InstanceGroupProfileKey] ?: NSNull.null;
        if (group) profile[InstanceGroupProfileKey] = group; else [profile removeObjectForKey:InstanceGroupProfileKey];
    }
    if (previous.count == 0) return NO;
    if (![PLProfiles.current save]) {
        [previous enumerateKeysAndObjectsUsingBlock:^(NSString *name, id old, BOOL *stop) {
            NSMutableDictionary *profile = PLProfiles.current.profiles[name];
            if (old == NSNull.null) [profile removeObjectForKey:InstanceGroupProfileKey];
            else profile[InstanceGroupProfileKey] = old;
        }];
        return NO;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:nil];
    return YES;
}

+ (void)promptForGroupNameFrom:(UIViewController *)presenter title:(NSString *)title initial:(NSString *)initial
    completion:(void (^)(NSString *name))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = localize(@"home.group.name", nil);
        field.text = initial;
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [self trimmed:weakAlert.textFields.firstObject.text];
        if (name) completion(name);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

+ (NSArray<UIMenuElement *> *)pickerMenuElementsWithCurrent:(NSString *)current presenter:(UIViewController *)presenter
    onPick:(void (^)(NSString *group))onPick {
    current = [self trimmed:current];
    NSMutableArray<UIMenuElement *> *choices = [NSMutableArray new];
    UIAction *none = [UIAction actionWithTitle:localize(@"home.group.none", nil) image:nil identifier:nil
        handler:^(UIAction *a) { onPick(nil); }];
    if (!current) none.state = UIMenuElementStateOn;
    [choices addObject:none];

    NSMutableArray<NSString *> *groups = [[self allGroupNames] mutableCopy];
    // A name picked but not used yet (New Instance window) still shows, checked
    if (current && ![groups containsObject:current]) [groups addObject:current];
    for (NSString *group in groups) {
        UIAction *action = [UIAction actionWithTitle:group image:[UIImage systemImageNamed:@"folder"] identifier:nil
            handler:^(UIAction *a) { onPick(group); }];
        if ([group isEqualToString:current]) action.state = UIMenuElementStateOn;
        [choices addObject:action];
    }

    __weak UIViewController *weakPresenter = presenter;
    UIAction *create = [UIAction actionWithTitle:localize(@"home.group.new", nil)
        image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil handler:^(UIAction *a) {
            UIViewController *strong = weakPresenter;
            if (!strong) return;
            [self promptForGroupNameFrom:strong title:localize(@"home.group.new", nil) initial:nil completion:onPick];
        }];
    return @[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:choices],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[create]],
    ];
}

@end
