#import "GamepadMap.h"
#import "../customcontrols/CustomControlsUtils.h"
#import "../utils.h"

#include "../glfw_keycodes.h"

static NSDictionary *catalogItem(NSString *name, int button, NSString *icon, NSString *label, BOOL direction) {
    return @{@"name": name, @"button": @(button), @"icon": icon, @"label": label, @"direction": @(direction)};
}

NSArray<NSDictionary *> *GamepadMap_catalog(void) {
    static NSArray *catalog;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Same order and icons as Android's GamepadMapperAdapter
        catalog = @[
            catalogItem(@"named_a", GLFW_GAMEPAD_BUTTON_A, @"Gamepad_button_a", @"controller_button_a", NO),
            catalogItem(@"named_b", GLFW_GAMEPAD_BUTTON_B, @"Gamepad_button_b", @"controller_button_b", NO),
            catalogItem(@"named_x", GLFW_GAMEPAD_BUTTON_X, @"Gamepad_button_x", @"controller_button_x", NO),
            catalogItem(@"named_y", GLFW_GAMEPAD_BUTTON_Y, @"Gamepad_button_y", @"controller_button_y", NO),
            catalogItem(@"named_start", GLFW_GAMEPAD_BUTTON_START, @"Gamepad_button_start", @"controller_button_start", NO),
            catalogItem(@"named_back", GLFW_GAMEPAD_BUTTON_BACK, @"Gamepad_button_select", @"controller_button_select", NO),
            catalogItem(@"trigger_right", GLFW_GAMEPAD_BUTTON_RIGHT_TRIGGER, @"Gamepad_trigger_right", @"controller_button_trigger_right", NO),
            catalogItem(@"trigger_left", GLFW_GAMEPAD_BUTTON_LEFT_TRIGGER, @"Gamepad_trigger_left", @"controller_button_trigger_left", NO),
            catalogItem(@"bumper_right", GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER, @"Gamepad_shoulder_right", @"controller_button_shoulder_right", NO),
            catalogItem(@"bumper_left", GLFW_GAMEPAD_BUTTON_LEFT_BUMPER, @"Gamepad_shoulder_left", @"controller_button_shoulder_left", NO),
            catalogItem(@"direction_forward", GAMEPAD_DIRECTION_FORWARD, @"Gamepad_stick_right", @"controller_direction_forward", YES),
            catalogItem(@"direction_right", GAMEPAD_DIRECTION_RIGHT, @"Gamepad_stick_right", @"controller_direction_right", YES),
            catalogItem(@"direction_left", GAMEPAD_DIRECTION_LEFT, @"Gamepad_stick_right", @"controller_direction_left", YES),
            catalogItem(@"direction_backward", GAMEPAD_DIRECTION_BACKWARD, @"Gamepad_stick_right", @"controller_direction_backward", YES),
            catalogItem(@"thumb_right", GLFW_GAMEPAD_BUTTON_RIGHT_THUMB, @"Gamepad_stick_right_click", @"controller_stick_press_r", NO),
            catalogItem(@"thumb_left", GLFW_GAMEPAD_BUTTON_LEFT_THUMB, @"Gamepad_stick_left_click", @"controller_stick_press_l", NO),
            catalogItem(@"dpad_up", GLFW_GAMEPAD_BUTTON_DPAD_UP, @"Gamepad_dpad_up", @"controller_dpad_up", NO),
            catalogItem(@"dpad_down", GLFW_GAMEPAD_BUTTON_DPAD_DOWN, @"Gamepad_dpad_down", @"controller_dpad_down", NO),
            catalogItem(@"dpad_right", GLFW_GAMEPAD_BUTTON_DPAD_RIGHT, @"Gamepad_dpad_right", @"controller_dpad_right", NO),
            catalogItem(@"dpad_left", GLFW_GAMEPAD_BUTTON_DPAD_LEFT, @"Gamepad_dpad_left", @"controller_dpad_left", NO),
        ];
    });
    return catalog;
}

NSString *GamepadMap_iconName(NSDictionary *catalogEntry, BOOL inGame) {
    if ([catalogEntry[@"direction"] boolValue]) {
        return inGame ? @"Gamepad_stick_left" : @"Gamepad_stick_right";
    }
    return catalogEntry[@"icon"];
}

#pragma mark - Normalization

static NSArray<NSNumber *> *keycodes4(int a, int b, int c, int d) {
    return @[@(a), @(b), @(c), @(d)];
}

/// Android's defaults for the stick directions, which version 1 files lack
static NSArray<NSNumber *> *defaultDirectionKeycodes(int button, BOOL inGame) {
    if (inGame) {
        switch (button) {
            case GAMEPAD_DIRECTION_FORWARD:  return keycodes4(GLFW_KEY_W, 0, 0, 0);
            case GAMEPAD_DIRECTION_BACKWARD: return keycodes4(GLFW_KEY_S, 0, 0, 0);
            case GAMEPAD_DIRECTION_RIGHT:    return keycodes4(GLFW_KEY_D, 0, 0, 0);
            case GAMEPAD_DIRECTION_LEFT:     return keycodes4(GLFW_KEY_A, 0, 0, 0);
        }
    } else {
        // Scroll lists four lines per flick of the stick
        switch (button) {
            case GAMEPAD_DIRECTION_FORWARD:
                return keycodes4(SPECIALBTN_SCROLLUP, SPECIALBTN_SCROLLUP, SPECIALBTN_SCROLLUP, SPECIALBTN_SCROLLUP);
            case GAMEPAD_DIRECTION_BACKWARD:
                return keycodes4(SPECIALBTN_SCROLLDOWN, SPECIALBTN_SCROLLDOWN, SPECIALBTN_SCROLLDOWN, SPECIALBTN_SCROLLDOWN);
        }
    }
    return keycodes4(0, 0, 0, 0);
}

static NSMutableDictionary *findEntry(NSArray *list, NSDictionary *catalogEntry) {
    for (id entry in list) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"gamepad_button"] isEqual:catalogEntry[@"button"]] ||
            [entry[@"name"] isEqual:catalogEntry[@"name"]]) {
            return [entry mutableCopy];
        }
    }
    return nil;
}

static NSMutableArray *normalizeList(NSArray *list, BOOL inGame) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *catalogEntry in GamepadMap_catalog()) {
        int button = [catalogEntry[@"button"] intValue];
        BOOL direction = [catalogEntry[@"direction"] boolValue];
        NSMutableDictionary *entry = findEntry(list, catalogEntry);
        NSMutableArray *keycodes = [NSMutableArray array];
        BOOL toggleable = NO;

        if (!entry) {
            entry = [NSMutableDictionary dictionary];
            [keycodes addObjectsFromArray:direction ? defaultDirectionKeycodes(button, inGame) : keycodes4(0, 0, 0, 0)];
        } else if ([entry[@"keycodes"] isKindOfClass:NSArray.class]) {
            for (id keycode in entry[@"keycodes"]) {
                if (keycodes.count == GAMEPAD_MAP_KEYCODE_COUNT) break;
                [keycodes addObject:@([keycode intValue])];
            }
            toggleable = [entry[@"toggleable"] boolValue];
        } else {
            // Version 1: a single keycode. -LEFT_SHIFT was the old "toggle sneak" hack.
            int keycode = [entry[@"keycode"] intValue];
            if (keycode == -GLFW_KEY_LEFT_SHIFT) {
                keycode = GLFW_KEY_LEFT_SHIFT;
                toggleable = YES;
            }
            [keycodes addObject:@(keycode)];
        }
        while (keycodes.count < GAMEPAD_MAP_KEYCODE_COUNT) {
            [keycodes addObject:@0];
        }

        entry[@"name"] = catalogEntry[@"name"];
        entry[@"gamepad_button"] = catalogEntry[@"button"];
        entry[@"keycodes"] = keycodes;
        entry[@"keycode"] = keycodes[0];
        if (direction) {
            [entry removeObjectForKey:@"toggleable"];
        } else {
            entry[@"toggleable"] = @(toggleable);
        }
        [result addObject:entry];
    }
    return result;
}

void GamepadMap_normalize(NSMutableDictionary *map) {
    map[@"version"] = @2;
    map[@"mGameMappingList"] = normalizeList(map[@"mGameMappingList"], YES);
    map[@"mMenuMappingList"] = normalizeList(map[@"mMenuMappingList"], NO);
}

NSMutableDictionary *GamepadMap_loadFile(NSString *path) {
    NSMutableDictionary *map = parseJSONFromFile(path);
    if (!map || map[@"NSErrorObject"]) {
        return nil;
    }
    GamepadMap_normalize(map);
    return map;
}

BOOL GamepadMap_saveFile(NSMutableDictionary *map, NSString *path, NSError **error) {
    for (NSString *listKey in @[@"mGameMappingList", @"mMenuMappingList"]) {
        for (NSMutableDictionary *entry in map[listKey]) {
            entry[@"keycode"] = entry[@"keycodes"][0];
        }
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:map options:NSJSONWritingPrettyPrinted error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

#pragma mark - Key names

static NSDictionary<NSNumber *, NSString *> *specialNames(void) {
    return @{
        @0: @"UNSPECIFIED",
        @(SPECIALBTN_MOUSESEC): @"MOUSE_RIGHT",
        @(SPECIALBTN_MOUSEMID): @"MOUSE_MIDDLE",
        @(SPECIALBTN_MOUSEPRI): @"MOUSE_LEFT",
        @(SPECIALBTN_SCROLLUP): @"SCROLL_UP",
        @(SPECIALBTN_SCROLLDOWN): @"SCROLL_DOWN",
    };
}

void GamepadMap_pickerKeycodes(NSMutableArray<NSString *> *names, NSMutableArray<NSNumber *> *values) {
    // Special actions in the same order as Android's picker
    NSDictionary *specials = specialNames();
    for (NSNumber *value in @[@0, @(SPECIALBTN_MOUSESEC), @(SPECIALBTN_MOUSEMID), @(SPECIALBTN_MOUSEPRI),
                              @(SPECIALBTN_SCROLLUP), @(SPECIALBTN_SCROLLDOWN)]) {
        [names addObject:specials[value]];
        [values addObject:value];
    }

    // Then every keyboard key the custom controls editor knows
    NSMutableArray *keyNames = [NSMutableArray array], *keyValues = [NSMutableArray array];
    initKeycodeTable(keyNames, keyValues);
    for (NSUInteger i = 0; i < keyNames.count; i++) {
        int value = [keyValues[i] intValue];
        if (value <= 0) continue; // SPECIALBTN_* and NONE are covered above
        [names addObject:keyNames[i]];
        [values addObject:keyValues[i]];
    }
}

NSString *GamepadMap_keycodeName(int keycode) {
    static NSMutableArray *names, *values;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSMutableArray array];
        values = [NSMutableArray array];
        GamepadMap_pickerKeycodes(names, values);
    });
    NSUInteger index = [values indexOfObject:@(keycode)];
    if (index == NSNotFound) {
        return [NSString stringWithFormat:@"KEY_%d", keycode];
    }
    return names[index];
}

NSString *GamepadMap_summary(NSDictionary *entry) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSNumber *keycode in entry[@"keycodes"]) {
        if (keycode.intValue == 0) continue;
        [parts addObject:GamepadMap_keycodeName(keycode.intValue)];
    }
    if (parts.count == 0) {
        return GamepadMap_keycodeName(0);
    }
    return [parts componentsJoinedByString:@" + "];
}
