#import <UIKit/UIKit.h>

/// Instance icons. A profile's "icon" string is one of:
///  - an icon KEY ("grass", "my pack"): a built-in icon (Natives/resources/InstanceIcons/<key>.png, from Prism Launcher)
///    or an icon the user added (Documents/icons/<key>.png);
///  - a URL or "data:" string: what modpack installs store (loaded over the network / decoded as before).
/// A key never contains "/", "\" or ":" and never starts with ".", so no URL can be mistaken for a key and a key can
/// never point outside the icon folders.
@interface InstanceIcons : NSObject

/// Folder for icons the user added (created on demand): Documents/icons
+ (NSString *)customIconsDirectory;

/// YES when the string is a valid icon key (and not a URL, a data: string or a path).
+ (BOOL)isKeyReference:(NSString *)iconString;

/// Keys, sorted the way Finder sorts names. Built-in = shipped with the app; custom = in the icons folder.
+ (NSArray<NSString *> *)builtInKeys;
+ (NSArray<NSString *> *)customKeys;
+ (BOOL)isBuiltInKey:(NSString *)key;
/// Custom icons that were saved from a modpack store (names start with modrinth_, curseforge_, ftb_, technic_, atl_),
/// the same rule Prism uses for its "Modpacks" category.
+ (BOOL)isModpackKey:(NSString *)key;

/// The icon for a key, or nil if there is none.
+ (UIImage *)imageForKey:(NSString *)key;

/// Shows a profile's icon string on an image view: keys are loaded locally, everything else goes through the usual
/// URL loading. The placeholder is shown when there is no usable icon.
+ (void)setIconString:(NSString *)iconString onImageView:(UIImageView *)view placeholder:(UIImage *)placeholder;

/// Adds an image file to the icons folder (decoded at no more than 512 px on its longest side, saved as PNG; files over
/// 100 megapixels are refused). Safe to call from several threads at once.
/// Returns the new key, or nil with an error. Names never replace an existing icon, ignoring case (the file system does): "name 2", "name 3", ...
+ (NSString *)importImageAtURL:(NSURL *)url error:(NSError **)error;
+ (NSString *)importImageAtURL:(NSURL *)url suggestedName:(NSString *)name error:(NSError **)error;
/// The same for an image's encoded bytes (a drop that has no file). Refused above 64 MB.
+ (NSString *)importImageData:(NSData *)data suggestedName:(NSString *)name error:(NSError **)error;

/// Deletes a custom icon. Built-in icons can't be removed (returns NO).
+ (BOOL)removeCustomKey:(NSString *)key;

@end
