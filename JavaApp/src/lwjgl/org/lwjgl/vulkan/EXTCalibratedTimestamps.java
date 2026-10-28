/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 * Based on the LWJGL 3.3.3 binding of VK_EXT_calibrated_timestamps. Minecraft 26.x is compiled against LWJGL
 * 3.4, where VkCalibratedTimestampInfoEXT is a subclass of VkCalibratedTimestampInfoKHR and the function takes
 * the KHR buffer type, so overloads for that type are added (see lwjgl-vulkan-overlay.jar). The 3.4 class itself
 * cannot be used: it needs function pointers that 3.3.3's VKCapabilitiesDevice and VKCapabilitiesInstance lack.
 */
package org.lwjgl.vulkan;

import javax.annotation.*;

import java.nio.*;

import org.lwjgl.system.*;

import static org.lwjgl.system.Checks.*;
import static org.lwjgl.system.JNI.*;
import static org.lwjgl.system.MemoryUtil.*;

public class EXTCalibratedTimestamps {

    public static final int VK_EXT_CALIBRATED_TIMESTAMPS_SPEC_VERSION = 2;

    public static final String VK_EXT_CALIBRATED_TIMESTAMPS_EXTENSION_NAME = "VK_EXT_calibrated_timestamps";

    public static final int VK_STRUCTURE_TYPE_CALIBRATED_TIMESTAMP_INFO_EXT = 1000184000;

    public static final int
        VK_TIME_DOMAIN_DEVICE_EXT                    = 0,
        VK_TIME_DOMAIN_CLOCK_MONOTONIC_EXT           = 1,
        VK_TIME_DOMAIN_CLOCK_MONOTONIC_RAW_EXT       = 2,
        VK_TIME_DOMAIN_QUERY_PERFORMANCE_COUNTER_EXT = 3;

    protected EXTCalibratedTimestamps() {
        throw new UnsupportedOperationException();
    }

    // --- [ vkGetPhysicalDeviceCalibrateableTimeDomainsEXT ] ---

    public static int nvkGetPhysicalDeviceCalibrateableTimeDomainsEXT(VkPhysicalDevice physicalDevice, long pTimeDomainCount, long pTimeDomains) {
        long __functionAddress = physicalDevice.getCapabilities().vkGetPhysicalDeviceCalibrateableTimeDomainsEXT;
        if (CHECKS) {
            check(__functionAddress);
        }
        return callPPPI(physicalDevice.address(), pTimeDomainCount, pTimeDomains, __functionAddress);
    }

    @NativeType("VkResult")
    public static int vkGetPhysicalDeviceCalibrateableTimeDomainsEXT(VkPhysicalDevice physicalDevice, @Nullable @NativeType("uint32_t *") IntBuffer pTimeDomainCount, @Nullable @NativeType("VkTimeDomainKHR *") IntBuffer pTimeDomains) {
        if (CHECKS) {
            check(pTimeDomainCount, 1);
            checkSafe(pTimeDomains, pTimeDomainCount.get(pTimeDomainCount.position()));
        }
        return nvkGetPhysicalDeviceCalibrateableTimeDomainsEXT(physicalDevice, memAddress(pTimeDomainCount), memAddressSafe(pTimeDomains));
    }

    @NativeType("VkResult")
    public static int vkGetPhysicalDeviceCalibrateableTimeDomainsEXT(VkPhysicalDevice physicalDevice, @Nullable @NativeType("uint32_t *") int[] pTimeDomainCount, @Nullable @NativeType("VkTimeDomainKHR *") int[] pTimeDomains) {
        long __functionAddress = physicalDevice.getCapabilities().vkGetPhysicalDeviceCalibrateableTimeDomainsEXT;
        if (CHECKS) {
            check(__functionAddress);
            check(pTimeDomainCount, 1);
            checkSafe(pTimeDomains, pTimeDomainCount[0]);
        }
        return callPPPI(physicalDevice.address(), pTimeDomainCount, pTimeDomains, __functionAddress);
    }

    // --- [ vkGetCalibratedTimestampsEXT ] ---

    public static int nvkGetCalibratedTimestampsEXT(VkDevice device, int timestampCount, long pTimestampInfos, long pTimestamps, long pMaxDeviation) {
        long __functionAddress = device.getCapabilities().vkGetCalibratedTimestampsEXT;
        if (CHECKS) {
            check(__functionAddress);
        }
        return callPPPPI(device.address(), timestampCount, pTimestampInfos, pTimestamps, pMaxDeviation, __functionAddress);
    }

    @NativeType("VkResult")
    public static int vkGetCalibratedTimestampsEXT(VkDevice device, @NativeType("VkCalibratedTimestampInfoKHR const *") VkCalibratedTimestampInfoEXT.Buffer pTimestampInfos, @NativeType("uint64_t *") LongBuffer pTimestamps, @NativeType("uint64_t *") LongBuffer pMaxDeviation) {
        if (CHECKS) {
            check(pTimestamps, pTimestampInfos.remaining());
            check(pMaxDeviation, 1);
        }
        return nvkGetCalibratedTimestampsEXT(device, pTimestampInfos.remaining(), pTimestampInfos.address(), memAddress(pTimestamps), memAddress(pMaxDeviation));
    }

    /** What the LWJGL 3.4 version takes, and what Minecraft 26.x is compiled against. */
    @NativeType("VkResult")
    public static int vkGetCalibratedTimestampsEXT(VkDevice device, @NativeType("VkCalibratedTimestampInfoKHR const *") VkCalibratedTimestampInfoKHR.Buffer pTimestampInfos, @NativeType("uint64_t *") LongBuffer pTimestamps, @NativeType("uint64_t *") LongBuffer pMaxDeviation) {
        if (CHECKS) {
            check(pTimestamps, pTimestampInfos.remaining());
            check(pMaxDeviation, 1);
        }
        return nvkGetCalibratedTimestampsEXT(device, pTimestampInfos.remaining(), pTimestampInfos.address(), memAddress(pTimestamps), memAddress(pMaxDeviation));
    }

    @NativeType("VkResult")
    public static int vkGetCalibratedTimestampsEXT(VkDevice device, @NativeType("VkCalibratedTimestampInfoKHR const *") VkCalibratedTimestampInfoEXT.Buffer pTimestampInfos, @NativeType("uint64_t *") long[] pTimestamps, @NativeType("uint64_t *") long[] pMaxDeviation) {
        long __functionAddress = device.getCapabilities().vkGetCalibratedTimestampsEXT;
        if (CHECKS) {
            check(__functionAddress);
            check(pTimestamps, pTimestampInfos.remaining());
            check(pMaxDeviation, 1);
        }
        return callPPPPI(device.address(), pTimestampInfos.remaining(), pTimestampInfos.address(), pTimestamps, pMaxDeviation, __functionAddress);
    }

    @NativeType("VkResult")
    public static int vkGetCalibratedTimestampsEXT(VkDevice device, @NativeType("VkCalibratedTimestampInfoKHR const *") VkCalibratedTimestampInfoKHR.Buffer pTimestampInfos, @NativeType("uint64_t *") long[] pTimestamps, @NativeType("uint64_t *") long[] pMaxDeviation) {
        long __functionAddress = device.getCapabilities().vkGetCalibratedTimestampsEXT;
        if (CHECKS) {
            check(__functionAddress);
            check(pTimestamps, pTimestampInfos.remaining());
            check(pMaxDeviation, 1);
        }
        return callPPPPI(device.address(), pTimestampInfos.remaining(), pTimestampInfos.address(), pTimestamps, pMaxDeviation, __functionAddress);
    }

}
