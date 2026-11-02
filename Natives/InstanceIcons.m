#import "InstanceIcons.h"
#import <ImageIO/ImageIO.h>
#import "UIImageView+AFNetworking.h"

static NSString *const kBuiltInFolder = @"InstanceIcons";
/// Icons are stored at most this many pixels on the longest side.
static const CGFloat kMaxIconPixels = 512;
/// Source images larger than this are refused instead of decoded (a 16384x16384 bitmap alone would be about 1 GB).
static const double kMaxSourceMegapixels = 100;
/// Encoded image data handed over in memory (a drop without a file) is refused above this size.
static const NSUInteger kMaxSourceBytes = 64 * 1024 * 1024;

@implementation InstanceIcons

#pragma mark - Keys

+ (NSString *)builtInDirectory {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:kBuiltInFolder];
}

+ (NSString *)customIconsDirectory {
    const char *home = getenv("AME_HOME");
    NSString *base = home ? @(home) : NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"icons"];
}

/// One character policy for validating AND for building keys, so the two can never disagree.
+ (NSCharacterSet *)invalidKeyCharacters {
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSCharacterSet characterSetWithCharactersInString:@"/\\:"].mutableCopy;
        // Includes invisible "format" characters such as the zero-width joiner used inside some emoji
        [set formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
        invalid = set;
    });
    return invalid;
}

+ (BOOL)isKeyReference:(NSString *)iconString {
    if (![iconString isKindOfClass:NSString.class] || iconString.length == 0 || iconString.length > 120) return NO;
    if ([iconString hasPrefix:@"."]) return NO;
    return [iconString rangeOfCharacterFromSet:[self invalidKeyCharacters]].location == NSNotFound;
}

+ (NSArray<NSString *> *)keysInDirectory:(NSString *)directory {
    NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    NSMutableArray<NSString *> *keys = [NSMutableArray new];
    for (NSString *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
        NSString *key = file.stringByDeletingPathExtension;
        if ([self isKeyReference:key]) [keys addObject:key];
    }
    return [keys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

+ (NSArray<NSString *> *)builtInKeys {
    // Shipped with the app, so it can't change while it runs
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = [self keysInDirectory:[self builtInDirectory]]; });
    return keys;
}

/// iOS file systems ignore case ("Grass.png" and "grass.png" are the same file), so keys are compared lowercased.
+ (NSSet<NSString *> *)lowercasedBuiltInKeys {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *lowered = [NSMutableSet new];
        for (NSString *key in [self builtInKeys]) [lowered addObject:key.lowercaseString];
        set = lowered;
    });
    return set;
}

+ (BOOL)isBuiltInKey:(NSString *)key {
    return [key isKindOfClass:NSString.class] && [[self lowercasedBuiltInKeys] containsObject:key.lowercaseString];
}

+ (NSArray<NSString *> *)customKeys {
    NSMutableArray<NSString *> *keys = [NSMutableArray new];
    for (NSString *key in [self keysInDirectory:[self customIconsDirectory]]) {
        // A built-in icon always wins over a custom file with the same name
        if (![self isBuiltInKey:key]) [keys addObject:key];
    }
    return keys;
}

+ (BOOL)isModpackKey:(NSString *)key {
    for (NSString *prefix in @[@"curseforge_", @"modrinth_", @"ftb_", @"technic_", @"atl_"]) {
        if ([key.lowercaseString hasPrefix:prefix]) return ![self isBuiltInKey:key];
    }
    return NO;
}

#pragma mark - Decoding (bounded)

/// Decodes an image source at no more than maxPixel on its longest side, without ever decoding the full-size bitmap.
/// nil if it isn't an image the system can read, or if it is absurdly large. Consumes the source.
+ (UIImage *)downsampledImageFromSource:(CGImageSourceRef)source maxPixel:(CGFloat)maxPixel {
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double width = [properties[(id)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(id)kCGImagePropertyPixelHeight] doubleValue];
    if (!(width >= 1) || !(height >= 1) || width * height > kMaxSourceMegapixels * 1000000.0) {
        CFRelease(source);
        return nil;
    }
    // Never ask for more pixels than the image has: this only ever shrinks
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceShouldCacheImmediately: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(MIN(maxPixel, MAX(width, height))),
    };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cgImage) return nil;
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

+ (UIImage *)downsampledImageAtURL:(NSURL *)url maxPixel:(CGFloat)maxPixel {
    NSDictionary *sourceOptions = @{(id)kCGImageSourceShouldCache: @NO};
    return [self downsampledImageFromSource:CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)sourceOptions)
                                   maxPixel:maxPixel];
}

+ (UIImage *)downsampledImageFromData:(NSData *)data maxPixel:(CGFloat)maxPixel {
    if (data.length == 0 || data.length > kMaxSourceBytes) return nil;
    NSDictionary *sourceOptions = @{(id)kCGImageSourceShouldCache: @NO};
    return [self downsampledImageFromSource:CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)sourceOptions)
                                   maxPixel:maxPixel];
}

#pragma mark - Loading

+ (NSCache<NSString *, UIImage *> *)cache {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        // Decoded 512 px icons are about 1 MB each, and the game runs in this same process: keep the cache small
        cache.totalCostLimit = 24 * 1024 * 1024;
    });
    return cache;
}

+ (UIImage *)imageForKey:(NSString *)key {
    if (![self isKeyReference:key]) return nil;
    NSString *file = [key stringByAppendingPathExtension:@"png"];
    NSString *path = [[self builtInDirectory] stringByAppendingPathComponent:file];
    BOOL builtIn = [NSFileManager.defaultManager fileExistsAtPath:path];
    if (!builtIn) path = [[self customIconsDirectory] stringByAppendingPathComponent:file];
    NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    if (!modified) return nil;
    // The modification date is part of the cache key, so a replaced file is never served stale
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%.3f", path, modified.timeIntervalSince1970];
    UIImage *image = [[self cache] objectForKey:cacheKey];
    if (!image) {
        // Shipped icons are small and trusted; a file the user added (or dropped in by hand) is decoded with a bound
        image = builtIn ? [UIImage imageWithContentsOfFile:path]
                        : [self downsampledImageAtURL:[NSURL fileURLWithPath:path] maxPixel:kMaxIconPixels];
        if (image) {
            NSUInteger cost = (NSUInteger)(image.size.width * image.scale * image.size.height * image.scale * 4);
            [[self cache] setObject:image forKey:cacheKey cost:cost];
        }
    }
    return image;
}

+ (void)setIconString:(NSString *)iconString onImageView:(UIImageView *)view placeholder:(UIImage *)placeholder {
    [view cancelImageDownloadTask];
    if ([self isKeyReference:iconString]) {
        view.image = [self imageForKey:iconString] ?: placeholder;
        return;
    }
    NSURL *url = [iconString isKindOfClass:NSString.class] && iconString.length > 0 ? [NSURL URLWithString:iconString] : nil;
    if (!url) {
        view.image = placeholder;
        return;
    }
    [view setImageWithURL:url placeholderImage:placeholder];
}

#pragma mark - Adding and removing

+ (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:@"InstanceIcons" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Whether a key is taken, in either icon folder. Asks the file system too, because it ignores case.
+ (BOOL)keyIsTaken:(NSString *)key {
    if ([[self lowercasedBuiltInKeys] containsObject:key.lowercaseString]) return YES;
    NSString *file = [key stringByAppendingPathExtension:@"png"];
    NSFileManager *fm = NSFileManager.defaultManager;
    return [fm fileExistsAtPath:[[self builtInDirectory] stringByAppendingPathComponent:file]]
        || [fm fileExistsAtPath:[[self customIconsDirectory] stringByAppendingPathComponent:file]];
}

/// A valid, unused key built from a suggested name. Call with the import lock held.
+ (NSString *)availableKeyForName:(NSString *)name {
    NSString *clean = [[name componentsSeparatedByCharactersInSet:[self invalidKeyCharacters]] componentsJoinedByString:@"-"];
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([clean hasPrefix:@"."]) clean = [clean substringFromIndex:1];
    if (clean.length > 60) {
        // Cut on a character boundary, never through an emoji or other multi-part character
        NSRange safe = [clean rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 60)];
        clean = [clean substringWithRange:safe];
    }
    // A key is limited to 120 UTF-16 units, and the suffix below needs room. A character sequence that stretched the
    // cut far past 60 (dozens of combining marks) simply falls back to a plain name.
    if (clean.length > 100 || ![self isKeyReference:clean]) clean = @"icon";
    NSString *key = clean;
    NSUInteger suffix = 2;
    while ([self keyIsTaken:key]) {
        key = [NSString stringWithFormat:@"%@ %lu", clean, (unsigned long)suffix++];
    }
    return key;
}

+ (NSString *)importImageAtURL:(NSURL *)url error:(NSError **)error {
    return [self importImageAtURL:url suggestedName:url.lastPathComponent.stringByDeletingPathExtension error:error];
}

+ (NSString *)importImageAtURL:(NSURL *)url suggestedName:(NSString *)name error:(NSError **)error {
    UIImage *image = [self downsampledImageAtURL:url maxPixel:kMaxIconPixels];
    if (!image) {
        if (error) *error = [self errorWithMessage:@"This file is not an image the app can read, or it is too large."];
        return nil;
    }
    NSData *png = UIImagePNGRepresentation(image);
    return [self storePNGData:png suggestedName:name error:error];
}

+ (NSString *)importImageData:(NSData *)data suggestedName:(NSString *)name error:(NSError **)error {
    UIImage *image = [self downsampledImageFromData:data maxPixel:kMaxIconPixels];
    if (!image) {
        if (error) *error = [self errorWithMessage:@"This is not an image the app can read, or it is too large."];
        return nil;
    }
    return [self storePNGData:UIImagePNGRepresentation(image) suggestedName:name error:error];
}

/// Picks a free key and writes the file as ONE step. Imports can run on several threads at once (a drop with many
/// images), and without this lock two of them could be given the same key and overwrite each other.
+ (NSString *)storePNGData:(NSData *)png suggestedName:(NSString *)name error:(NSError **)error {
    if (png.length == 0) {
        if (error) *error = [self errorWithMessage:@"The image could not be converted to PNG."];
        return nil;
    }
    static NSObject *importLock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ importLock = [NSObject new]; });
    @synchronized (importLock) {
        NSString *directory = [self customIconsDirectory];
        NSError *directoryError;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            if (error) *error = directoryError;
            return nil;
        }
        NSString *key = [self availableKeyForName:name ?: @""];
        NSString *path = [[directory stringByAppendingPathComponent:key] stringByAppendingPathExtension:@"png"];
        NSError *writeError;
        if (![png writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
            if (error) *error = writeError;
            return nil;
        }
        return key;
    }
}

+ (BOOL)removeCustomKey:(NSString *)key {
    if (![self isKeyReference:key] || [self isBuiltInKey:key]) return NO;
    NSString *path = [[[self customIconsDirectory] stringByAppendingPathComponent:key] stringByAppendingPathExtension:@"png"];
    return [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

@end
