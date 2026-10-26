#pragma once

#import <Foundation/Foundation.h>

/*
 * Gamepad -> keyboard/mouse mapping files (controlmap/gamepads/*.json).
 *
 * Mirrors Android Amethyst's GamepadMap: every controller input, including the
 * four directions of the movement stick, can send up to four keys at once and
 * physical buttons can be toggleable. There is one list for in-game (mouse
 * grabbed) and one for menus.
 *
 * File format (version 2, a superset of version 1):
 *   { "version": 2,
 *     "mGameMappingList": [ { "name": "named_a", "gamepad_button": 0,
 *                             "keycodes": [32, 0, 0, 0], "toggleable": false,
 *                             "keycode": 32 }, ... ],
 *     "mMenuMappingList": [ ... ] }
 * "keycode" mirrors keycodes[0] so older builds can still read the file.
 * Keycodes are GLFW keys, 0 (unspecified) or the SPECIALBTN_* mouse/scroll values.
 */

#define GAMEPAD_MAP_KEYCODE_COUNT 4

// Pseudo gamepad_button ids for the directions of the movement stick
#define GAMEPAD_DIRECTION_FORWARD  1000
#define GAMEPAD_DIRECTION_RIGHT    1001
#define GAMEPAD_DIRECTION_LEFT     1002
#define GAMEPAD_DIRECTION_BACKWARD 1003

/// Every mappable input, in the order Android's remapper lists them. Each item:
/// name (NSString), button (NSNumber gamepad_button id), icon (image name),
/// label (localization key), direction (NSNumber BOOL).
NSArray<NSDictionary *> *GamepadMap_catalog(void);

/// Image name for a catalog entry's icon. Stick direction icons depend on the
/// mode, as on Android: the left stick moves in game, the right stick in menus.
NSString *GamepadMap_iconName(NSDictionary *catalogEntry, BOOL inGame);

/// Bring a parsed mapping dictionary up to the current format in place: one
/// entry per catalog item in catalog order, four keycodes each, defaults for
/// anything missing.
void GamepadMap_normalize(NSMutableDictionary *map);

/// Parse and normalize a mapping file. Returns nil if the file can't be read.
NSMutableDictionary *GamepadMap_loadFile(NSString *path);

/// Write a mapping file (keeps "keycode" in sync with keycodes[0]).
BOOL GamepadMap_saveFile(NSMutableDictionary *map, NSString *path, NSError **error);

/// Keycodes the key picker offers, as parallel name/value arrays: the special
/// mouse/scroll actions first (Android order), then keyboard keys.
void GamepadMap_pickerKeycodes(NSMutableArray<NSString *> *names, NSMutableArray<NSNumber *> *values);

/// Display name for one keycode ("UNSPECIFIED", "MOUSE_LEFT", "SPACE", ...).
NSString *GamepadMap_keycodeName(int keycode);

/// "SPACE + LEFT_SHIFT" style summary of an entry's keycodes.
NSString *GamepadMap_summary(NSDictionary *entry);
