#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <math.h>
#include "jni.h"

JNIEXPORT void JNICALL
Java_org_lwjgl_sdl_SDL3GLContext_nativeSetDrawableSize(JNIEnv *env, jclass clazz,
                                                     jlong layerPtr, jint width, jint height) {
    (void)env; (void)clazz;
    if (layerPtr == 0 || width <= 0 || height <= 0) return;
    CAMetalLayer *layer = (__bridge CAMetalLayer *)(void *)(intptr_t)layerPtr;
    void (^apply)(void) = ^{
        UIView *view = [layer.delegate isKindOfClass:UIView.class] ? (UIView *)layer.delegate : nil;
        // Finish embedding before deriving pixels per point from the layer bounds.
        [view.superview layoutIfNeeded];
        CGRect bounds = layer.bounds;
        if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
        CGFloat scale = (CGFloat)width / bounds.size.width;
        CGSize want = CGSizeMake(width, height);
        if (fabs(layer.contentsScale - scale) < 0.0001 && CGSizeEqualToSize(layer.drawableSize, want)) return;
        // MoltenVK uses bounds * contentsScale for its surface extent. Setting
        // drawableSize alone is transient: SDL restores it on its next layout.
        view.contentScaleFactor = scale;
        layer.contentsScale = scale;
        layer.drawableSize = want;
        static int logged = 0;
        if (logged++ < 8) {
            NSLog(@"[SDL3 EMBED] GL geometry bounds=%.0fx%.0f scale=%.3f drawable=%dx%d",
                  bounds.size.width, bounds.size.height, scale, (int)width, (int)height);
        }
    };
    if ([NSThread isMainThread]) apply();
    else dispatch_sync(dispatch_get_main_queue(), apply);
}
