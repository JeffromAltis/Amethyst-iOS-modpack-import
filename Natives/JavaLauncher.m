#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "utils.h"

#import "installer/modpack/LWJGL3ifyUtils.h"
#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "MinecraftOptionUtils.h"
#import "MinecraftResourceUtils.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"

#define fm NSFileManager.defaultManager

extern char **environ;

BOOL validateVirtualMemorySpace(size_t size) {
    size <<= 20; // convert to MB
    void *map = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    // check if process successfully maps and unmaps a contiguous range
    if(map == MAP_FAILED || munmap(map, size) != 0)
        return NO;
    return YES;
}

void init_loadDefaultEnv() {
    /* Define default env */

    // Silent Caciocavallo NPE error in locating Android-only lib
    setenv("LD_LIBRARY_PATH", "", 1);

    // Ignore mipmap for performance(?) seems does not affect iOS
    //setenv("LIBGL_MIPMAP", "3", 1);

    // Disable overloaded functions hack for Minecraft 1.17+
    setenv("LIBGL_NOINTOVLHACK", "1", 1);

    // Fix white color on banner and sheep, since GL4ES 1.1.5
    setenv("LIBGL_NORMALIZE", "1", 1);

    // Override OpenGL version to 4.1 for Zink
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);

    // Runs JVM in a separate thread
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (![line containsString:@"="]) {
            NSLog(@"[JavaLauncher] Warning: skipped empty value custom env variable: %@", line);
            continue;
        }
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@", line);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    // Make the separator happy
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    NSLog(@"[JavaLauncher] Reading custom JVM flags");
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                NSLog(@"[JavaLauncher] Ignored JVM flag: -%@", jvmarg);
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;

        ++*argc;
        argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String;

        NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
    }
}

// Builds the game classpath the same way Tools.generateLaunchClassPath does on the Java side.
// Used when the version replaces the system class loader (lwjgl3ify's RetroFuturaBootstrap):
// that loader reads java.class.path when the JVM starts, so the game libraries must be on -cp
// instead of being added afterwards through PojavClassLoader.
static NSString *GameClasspathForVersion(NSDictionary *version) {
    NSString *gameDir = @(getenv("GAME_DIR"));
    NSString *libDir = [gameDir stringByAppendingPathComponent:@"libraries"];
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet new];
    for (NSDictionary *library in version[@"libraries"]) {
        if (![library isKindOfClass:NSDictionary.class] || [library[@"skip"] boolValue]) continue;
        id artifact = library[@"downloads"][@"artifact"];
        NSString *rel = [artifact isKindOfClass:NSDictionary.class] ? artifact[@"path"] : nil;
        if (![rel isKindOfClass:NSString.class] || rel.length == 0) {
            rel = [library[@"name"] isKindOfClass:NSString.class] ?
                [MinecraftResourceUtils pathForLibraryName:library[@"name"]] : nil;
        }
        if (rel.length == 0) continue;
        // The client jar is listed with a "../versions/..." path; standardize it
        NSString *full = [libDir stringByAppendingPathComponent:rel].stringByStandardizingPath;
        if ([fm fileExistsAtPath:full]) {
            [paths addObject:full];
        } else {
            NSLog(@"[JavaLauncher] Classpath: ignored missing %@", full);
        }
    }
    NSLog(@"[JavaLauncher] Put %lu game libraries on the startup classpath", (unsigned long)paths.count);
    return [paths.array componentsJoinedByString:@":"];
}

/// Whether the version's libraries include LWJGL's SDL binding. Such a game (Minecraft 26.x) opens its window through
/// SDL3 and draws with OpenGL 3.3 core.
static BOOL VersionUsesLWJGLSDL(NSDictionary *version) {
    for (NSDictionary *library in version[@"libraries"]) {
        NSString *name = [library isKindOfClass:NSDictionary.class] ? library[@"name"] : nil;
        if ([name isKindOfClass:NSString.class] && [name hasPrefix:@"org.lwjgl:lwjgl-sdl:"]) {
            return YES;
        }
    }
    return NO;
}

/// Whether the instance's mods folder has a jar whose file name contains `name` (case-insensitive).
static BOOL InstanceHasModNamed(NSString *gameDir, NSString *name) {
    NSArray<NSString *> *mods = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[gameDir stringByAppendingPathComponent:@"mods"] error:nil];
    for (NSString *mod in mods) {
        if ([mod.pathExtension.lowercaseString isEqualToString:@"jar"] &&
            [mod rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    init_loadDefaultEnv();
    init_loadCustomEnv();

    DeviceGetJITFlags(YES); // refresh JIT flags right after loading env
    BOOL requiresTXMWorkaround = DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM);
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    if (requiresTXMWorkaround) {
        static void *result;
        if(!result) result = JIT26CreateRegionLegacy(getpagesize());
        if ((uint32_t)result != 0x690000E0) {
            munmap(result, getpagesize());
            // we can't continue since legacy script only allows calling breakpoint once
            NSString *inBundleScriptPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
            NSString *lcAppInfoPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSMutableDictionary *lcAppInfo = [NSMutableDictionary dictionaryWithContentsOfFile:lcAppInfoPath];
            if(lcAppInfo) {
                // if this is inside LiveContainer, we assign script ourselves and prompt user to restart Amethyst
                lcAppInfo[@"jitLaunchScriptJs"] = [[NSData dataWithContentsOfFile:inBundleScriptPath] base64EncodedStringWithOptions:0];
                if([lcAppInfo writeToFile:lcAppInfoPath atomically:YES]) {
                    showDialog(localize(@"Error", nil), @"Amethyst was launched with a legacy script. We have updated the script to Universal, please restart LiveContainer to continue.");
                    [PLLogOutputView handleExitCode:1];
                    return 1;
                }
            }
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("AME_HOME")] error:nil];
            showDialog(localize(@"Error", nil), @"Support for legacy script has been removed. Please switch to Universal JIT script. To import it, long-press on Amethyst when enabling JIT in StikDebug and tap \"Assign Script\", then go to Amethyst's Documents directory and pick it. (on sideloaded StikDebug, the builtin script is named Amethyst-MeloNX.js)");
            [PLLogOutputView handleExitCode:1];
            return 1;
        }
        JIT26SendJITScript([NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"]]);
        JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);
        // make sure we don't get stuck in EXC_BAD_ACCESS
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    }
    if (!requiresTXMWorkaround || jit26AlwaysAttached) {
        if (jit26AlwaysAttached) {
            // Only allow StikDebug to catch our breakpoints to prevent any stutters
            task_set_exception_ports(mach_task_self(), EXC_MASK_ALL & ~EXC_MASK_BREAKPOINT, 0,
                EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        }
        // Activate Library Validation bypass for external runtime and dylibs (JNA, etc)
        init_bypassDyldLibValidation();
    } else {
        NSLog(@"[DyldLVBypass] Hook disabled! Loading unsigned dylib will cause code signature error.");
    }

    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;
    NSCAssert(launchTarget, @"Unexpected nil launchTarget");
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        // Get preferred Java version from current profile
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
            } else {
                NSDebugLog(@"[PLProfiles] Applying javaVersion");
                minVersion = preferredJavaVersion;
            }
        }
        if (minVersion <= 8) {
            defaultJRETag = @"1_16_5_older";
        } else {
            defaultJRETag = @"1_17_newer";
        }

        // Setup gameDir
        gameDir = [PLProfiles absolutePathForGameDir:[PLProfiles resolveKeyForCurrentProfile:@"gameDir"]];
        // Mod settings that can't work on iOS, fixed in the exact folder the game runs in
        [LWJGL3ifyUtils applyRequiredConfigToGameDirectory:gameDir];
        // Setup RENDERER
        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        if (InstanceHasModNamed(gameDir, @"angelica")) {
            if (InstanceHasModNamed(gameDir, @"lwjgl3ify")) {
                // Angelica 2 on lwjgl3ify (GT New Horizons 2.9+) draws through its own core-profile
                // pipeline and needs OpenGL 3.3
                if ([renderer isEqualToString:@"auto"]) {
                    NSLog(@"[JavaLauncher] Angelica on lwjgl3ify found, using MobileGlues");
                    renderer = @ RENDERER_NAME_MOBILEGLUES;
                }
            } else if ([renderer isEqualToString:@"auto"] || [renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES]) {
                // Angelica 1 on LWJGL 2 (GT New Horizons 2.8 and older, Java 8) still renders with the
                // fixed-function pipeline (glMatrixMode, glColor, client arrays...). MobileGlues only
                // implements core-profile GL and stubs those calls out, so only gl4es can draw it; its
                // own shaders are GLSL 1.10/1.20
                NSLog(@"[JavaLauncher] Angelica on LWJGL 2 found, using gl4es (MobileGlues has no fixed-function pipeline)");
                renderer = @ RENDERER_NAME_GL4ES;
            }
        }
        if ([renderer isEqualToString:@"auto"] && VersionUsesLWJGLSDL(launchTarget)
            && ![MinecraftResourceUtils versionRequestsCustomSystemClassLoader:launchTarget]) {
            // An SDL game looks up its GL functions when it loads the GL library, before any window exists, so
            // the renderer has to be right from the start: the bridge only switches "auto" to MobileGlues when
            // the context is created, which is too late. (lwjgl3ify versions are handled above, and some of
            // them need gl4es's fixed-function pipeline.)
            NSLog(@"[JavaLauncher] Version uses LWJGL SDL (OpenGL 3.3 core), using MobileGlues");
            renderer = @ RENDERER_NAME_MOBILEGLUES;
        }
        NSLog(@"[JavaLauncher] RENDERER is set to %@\n", renderer);
        setenv("RENDERER", renderer.UTF8String, 1);
        if (isMobileGLRenderer(renderer.UTF8String)) {
            setenv("MOBILEGL_BACKEND_TYPE", "DirectVulkan", 1);
            // MoltenVK's argument-buffer alias fixup throws while compiling GTNH's
            // font shader. Use supported discrete bindings until that driver path
            // is corrected. Preserve an explicit custom environment override.
            setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0", 0);
            NSLog(@"[JavaLauncher] MobileGL MoltenVK argument buffers: %s",
                  getenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"));
        }
        if ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES]) {
            NSString *mgDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/mobileglues"];
            [fm createDirectoryAtPath:mgDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("MG_DIR_PATH", mgDir.UTF8String, 1);
        }
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("GAME_DIR"));
        launchJar = YES;
    }
    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("AME_HOME"))]) {
        // Copy libawt_xawt.dylib
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm removeItemAtPath:dest error:nil];
        [fm copyItemAtPath:source toPath:dest error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Copy libawt_xawt.dylib failed: %@", error.localizedDescription);
        }
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    if (!launchJar) {
        // The instance dashboard stores a per-instance allocation, which wins over the global setting
        int instanceMem = [PLProfiles.current.selectedProfile[@"allocatedMemory"] intValue];
        if (instanceMem > 0) {
            allocmem = instanceMem;
        }
    }
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);
    if (!validateVirtualMemorySpace(allocmem)) {
        UIKit_returnToSplitView();
        if (getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit")) {
            showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Lower memory allocation and try again.");
        } else {
            showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Increased Memory Limit entitlement is missing, please add it via GetMoreRam app.");
        }
        return 1;
    }

    // Setup options.txt
    [MinecraftOptionUtils setupOptionsAtGameDir:gameDir];

    // Java resolves relative paths (new File("config/...")) against the process cwd, not
    // -Duser.dir, so make the native cwd the game directory as Android does before launch.
    // Otherwise mods such as BetterLoadingScreen read configs from the instance root instead.
    NSError *gameDirError;
    if (![fm createDirectoryAtPath:gameDir withIntermediateDirectories:YES attributes:nil error:&gameDirError]) {
        NSLog(@"[JavaLauncher] Could not create game directory %@: %@", gameDir, gameDirError.localizedDescription);
    }
    if (chdir(gameDir.fileSystemRepresentation) != 0) {
        NSLog(@"[JavaLauncher] chdir to %@ failed: %s", gameDir, strerror(errno));
    } else {
        NSLog(@"[JavaLauncher] Working directory set to %@", gameDir);
    }

    BOOL useLWJGL34 = !launchJar && (VersionUsesLWJGLSDL(launchTarget) ||
        InstanceHasModNamed(gameDir, @"lwjgl3ify"));
    NSString *lwjglSubfolder = useLWJGL34 ? @"lwjgl34" : @"lwjgl33";
    NSString *frameworksPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSString *nativePath = useLWJGL34 ? [frameworksPath stringByAppendingPathComponent:@"lwjgl34"] : frameworksPath;
    int margc = -1;
    const char *margv[1000];

    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;
    margv[++margc] = "-XstartOnFirstThread";
    BOOL customSystemClassLoader = !launchJar && [MinecraftResourceUtils versionRequestsCustomSystemClassLoader:launchTarget];
    if (customSystemClassLoader) {
        // The version's own -Djava.system.class.loader arrives with its JVM arguments below
        NSLog(@"[JavaLauncher] Version brings its own system class loader");
    } else if (!launchJar) {
        margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    }
    margv[++margc] = "-Xms128M";
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@:%@", nativePath, frameworksPath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.librarypath=%@", nativePath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Damethyst.resolutionScale=%.3f", getPrefFloat(@"video.resolution") / 100.0].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("AME_HOME")].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond].UTF8String;
    margv[++margc] = "-Dorg.lwjgl.glfw.checkThread0=false";
    margv[++margc] = "-Dorg.lwjgl.system.allocator=system";
    margv[++margc] = "-Damethyst.noUpcalls=true";
    //margv[++margc] = "-Dorg.lwjgl.util.NoChecks=true";
    margv[++margc] = "-Dlog4j2.formatMsgNoLookups=true";
    // TEMPORARY: Minecraft 26.x has no log4j configuration here, so only errors reach the log. Show info and warnings
    // to see why a graphics backend is rejected. Remove once Vulkan works.
    margv[++margc] = "-Dorg.apache.logging.log4j.level=INFO";

    // Preset OpenGL libname
    const char *glLibName = getenv("RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) {
            // workaround only applies to 1.20.2+
            glLibName = RENDERER_NAME_MTL_ANGLE;
        }
        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%s", glLibName].UTF8String;
    }

    // Minecraft 26+ loads LWJGL's SPIRV-Cross and shaderc bindings. The iOS builds of those libraries ship under
    // other file names than LWJGL looks for, so point it at them.
    margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.spvc.libname=%@/libspirv-cross.dylib", frameworksPath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.shaderc.libname=%@/libshaderc.dylib", nativePath].UTF8String;
    // LWJGL's VK class would look for libvulkan; on iOS Vulkan is MoltenVK
    margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.vulkan.libname=%@/libMoltenVK.dylib", frameworksPath].UTF8String;

    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", librariesPath].UTF8String;
    if(getPrefBool(@"general.cosmetica")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath].UTF8String;
    }

    // Workaround random stack guard allocation crashes
    margv[++margc] = "-XX:+UnlockExperimentalVMOptions";
    margv[++margc] = "-XX:+DisablePrimordialThreadGuardPages";

    // On iOS 26, use mirror mapped JIT by default
    if (@available(iOS 26.0, *)) {
        margv[++margc] = "-XX:+MirrorMappedCodeCache";
    }

    // Disable Forge 1.16.x early progress window
    margv[++margc] = "-Dfml.earlyprogresswindow=false";

    // Load java
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // java 8
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // java 11+
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];
    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);

    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[Init] JLI lib = NULL: %s", error);
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @(error));
        return 1;
    }

    // Setup Caciocavallo
    // lwjgl3ify (RetroFuturaBootstrap profiles) requires headless AWT on macOS-like platforms, which
    // LWJGL considers iOS to be; RFB only enforces it itself when os.name contains "mac"
    margv[++margc] = customSystemClassLoader ? "-Djava.awt.headless=true" : "-Djava.awt.headless=false";
    margv[++margc] = "-Dcacio.font.fontmanager=sun.awt.X11FontManager";
    margv[++margc] = "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler";
    margv[++margc] = [NSString stringWithFormat:@"-Dcacio.managed.screensize=%dx%d", width, height].UTF8String;
    margv[++margc] = "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel";
    if (isJava8) {
        // Setup Caciocavallo
        margv[++margc] = "-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment";
    } else {
        // Required by Cosmetica to inject DNS
        margv[++margc] = "--add-opens=java.base/java.net=ALL-UNNAMED";

        // Setup Caciocavallo
        margv[++margc] = "-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment";

        // Required by Caciocavallo17 to access internal API
        margv[++margc] = "--add-exports=java.desktop/java.awt=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.font=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.base/sun.security.action=ALL-UNNAMED";
        // Used by the patchjna agent's Controlify compatibility patch (ControlifyCompatTransformer)
        margv[++margc] = "--add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.base/java.util=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/java.awt=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/sun.font=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED";

        // TODO: workaround, will be removed once the startup part works without PLaunchApp
        margv[++margc] = "--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED";
    }

    // Add Caciocavallo bootclasspath
    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", isJava8 ? "p" : "a"];
    NSString *cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo%s", NSBundle.mainBundle.bundlePath, isJava8 ? "" : "17"];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        if ([file hasSuffix:@".jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    margv[++margc] = cacio_classpath.UTF8String;

    // FIXME: the JVM arg is deprecated; and it is currently broken for Java 25
    if (!getenv("JVM_KEEP_UseCompressedClassPointers") || !getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        margv[++margc] = "-XX:-UseCompressedClassPointers";
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        for (NSString *arg in launchTarget[@"arguments"][@"jvm_processed"]) {
            margv[++margc] = arg.UTF8String;
        }
    }

    // Controlify (controller mod) prefers SDL3 and falls back to GLFW when SDL fails
    // to load. Its SDL bindings can't run on iOS (JNA direct mapping faults on TXM
    // devices and freezes the game), and the desktop library it ships is useless here,
    // so point it at a path that fails cleanly. Gamepad passthrough then serves it
    // through GLFW. Placed before custom JVM flags so a profile can still override it.
    margv[++margc] = "-Dcontrolify.debug.sdl_natives_override=/dev/null/libSDL3.dylib";

    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    NSString *classpath = [NSString stringWithFormat:@"%@/*:%@/%@/*", librariesPath, librariesPath, lwjglSubfolder];
    if (launchJar) {
        classpath = [classpath stringByAppendingFormat:@":%@", launchTarget];
    } else if (customSystemClassLoader) {
        NSString *gameClasspath = GameClasspathForVersion(launchTarget);
        if (gameClasspath.length > 0) {
            classpath = [classpath stringByAppendingFormat:@":%@", gameClasspath];
        }
    }
    margv[++margc] = "-cp";
    margv[++margc] = classpath.UTF8String;
    margv[++margc] = "net.kdt.pojavlaunch.PojavLauncher";

    if (launchJar) {
        margv[++margc] = "-jar";
    } else {
        margv[++margc] = username.UTF8String;
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        margv[++margc] = [launchTarget[@"id"] UTF8String];
    } else {
        margv[++margc] = [launchTarget UTF8String];
    }
    //margv[++margc] = "ghidra.GhidraRun";

    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");

    if (NULL == pJLI_Launch) {
        NSLog(@"[Init] JLI_Launch = NULL");
        return -2;
    }

    NSLog(@"[Init] Calling JLI_Launch");

    // Cr4shed known issue: exit after crash dump,
    // reset signal handler so that JVM can catch them
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Free split VC
    tmpRootVC = nil;

    return pJLI_Launch(++margc, margv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   // These values are ignored in Java 17, so keep it anyways
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
}
