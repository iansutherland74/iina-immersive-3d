/*
 *  IINACaptureAudio.c
 *  IINA Capture Audio
 *
 *  Copyright (C) 2026 the IINA Immersive 3D contributors.
 *  Licensed under the GNU General Public License, version 3.
 *
 *  A CoreAudio HAL AudioServerPlugIn. One device, "IINA Capture Audio",
 *  stereo float at 48 kHz. Output clients write a ring. Input clients read
 *  that ring. The clock is the host clock, the same shape as BlackHole
 *  (Existential Audio, 2019, GPLv3). ReadInput runs before WriteMix, so a
 *  read at the write head returns the last completed buffer instead of
 *  silence. The loopback reader's own output is ignored. This file is our
 *  own driver.
 *
 *  The device is static. CreateDevice is refused. It can be the default
 *  output so a browser plays into it, and it cannot be the default input
 *  so it does not replace the microphone.
 */

#include "loopback.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>

/* coreaudiod on macOS 13.7 uses the AudioServerPlugIn from the 13.3 SDK.
   These sizes and offsets were measured there and are unchanged in the
   26.5 and 27.0 SDKs. A newer SDK that moves this layout must not ship. */
_Static_assert(sizeof(AudioServerPlugInDriverInterface) == 184,
               "AudioServerPlugIn vtable does not match macOS 13.7");
_Static_assert(offsetof(AudioServerPlugInDriverInterface, QueryInterface) == sizeof(void *),
               "driver vtable does not start with the macOS 13.7 IUnknown slot");
_Static_assert(sizeof(AudioServerPlugInIOCycleInfo) == 224,
               "AudioServerPlugInIOCycleInfo does not match macOS 13.7");
_Static_assert(offsetof(AudioServerPlugInIOCycleInfo, mOutputTime) == 144,
               "mOutputTime moved; macOS 13.7 coreaudiod would be misread");
_Static_assert(offsetof(AudioServerPlugInIOCycleInfo, mDeviceHostTicksPerFrame) == 216,
               "IO cycle tail does not match macOS 13.7");
_Static_assert(sizeof(AudioServerPlugInClientInfo) == 24,
               "AudioServerPlugInClientInfo does not match macOS 13.7");

#define kDevice_UID "IINACaptureAudio_UID"
#define kDevice_ModelUID "IINACaptureAudio_ModelUID"
#define kBox_UID "IINACaptureAudio_BoxUID"
#define kDevice_Name "IINA Capture Audio"
#define kDevice_SampleRate 48000.0

/* These selectors moved out of the headers AudioServerPlugIn.h includes.
   The four-character codes are the ones Core Audio still sends. */
#ifndef kAudioObjectSystemObject
#define kAudioObjectSystemObject 0
#endif
#ifndef kAudioDevicePropertyDeviceIsRunningSomewhere
#define kAudioDevicePropertyDeviceIsRunningSomewhere 'gone'
#endif
#ifndef kAudioDevicePropertyBufferFrameSize
#define kAudioDevicePropertyBufferFrameSize 'fsiz'
#endif
#ifndef kAudioDevicePropertyBufferFrameSizeRange
#define kAudioDevicePropertyBufferFrameSizeRange 'fsz#'
#endif
#ifndef kAudioDevicePropertyUsesVariableBufferFrameSizes
#define kAudioDevicePropertyUsesVariableBufferFrameSizes 'vfsz'
#endif
#ifndef kAudioDevicePropertyStreamConfiguration
#define kAudioDevicePropertyStreamConfiguration 'slay'
#endif

enum {
  kObjectID_PlugIn = kAudioObjectPlugInObject,
  kObjectID_Box = 2,
  kObjectID_Device = 3,
  kObjectID_Stream_Input = 4,
  kObjectID_Stream_Output = 5,
  kObjectID_Volume_Output = 6
};

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;
static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static IINALoopback gLoop;
static UInt32 gIOCount = 0;
static Float64 gTicksPerFrame = 0;
static IINAClock gClock;
static UInt32 gReaderClient = 0;
static bool gReaderKnown = false;
static Float32 gVolume = 1.0f;

static bool isDriver(AudioServerPlugInDriverRef driver) {
  return driver == gDriverRef;
}

static OSStatus writeUInt32(UInt32 value, UInt32 inSize, UInt32 *outSize, void *out) {
  if (inSize < sizeof(UInt32) || out == NULL || outSize == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }
  *((UInt32 *)out) = value;
  *outSize = sizeof(UInt32);
  return noErr;
}

static OSStatus writeFloat32(Float32 value, UInt32 inSize, UInt32 *outSize, void *out) {
  if (inSize < sizeof(Float32) || out == NULL || outSize == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }
  *((Float32 *)out) = value;
  *outSize = sizeof(Float32);
  return noErr;
}

static OSStatus writeFloat64(Float64 value, UInt32 inSize, UInt32 *outSize, void *out) {
  if (inSize < sizeof(Float64) || out == NULL || outSize == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }
  *((Float64 *)out) = value;
  *outSize = sizeof(Float64);
  return noErr;
}

static OSStatus writeID(AudioObjectID value, UInt32 inSize, UInt32 *outSize, void *out) {
  return writeUInt32(value, inSize, outSize, out);
}

static OSStatus writeString(const char *value, UInt32 inSize, UInt32 *outSize, void *out) {
  CFStringRef string;
  if (inSize < sizeof(CFStringRef) || out == NULL || outSize == NULL || value == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }
  string = CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);
  if (string == NULL) {
    return kAudioHardwareUnspecifiedError;
  }
  *((CFStringRef *)out) = string;
  *outSize = sizeof(CFStringRef);
  return noErr;
}

static OSStatus writeBlock(const void *value, UInt32 bytes, UInt32 inSize, UInt32 *outSize, void *out) {
  if (inSize < bytes || out == NULL || outSize == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }
  memcpy(out, value, bytes);
  *outSize = bytes;
  return noErr;
}

static AudioStreamBasicDescription streamFormat(void) {
  AudioStreamBasicDescription format;
  memset(&format, 0, sizeof(format));
  format.mSampleRate = kDevice_SampleRate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
  format.mBytesPerPacket = IINA_RING_CHANNELS * sizeof(Float32);
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = IINA_RING_CHANNELS * sizeof(Float32);
  format.mChannelsPerFrame = IINA_RING_CHANNELS;
  format.mBitsPerChannel = 32;
  return format;
}

static AudioBufferList stereoBuffers(void) {
  AudioBufferList list;
  memset(&list, 0, sizeof(list));
  list.mNumberBuffers = 1;
  list.mBuffers[0].mNumberChannels = IINA_RING_CHANNELS;
  list.mBuffers[0].mDataByteSize = 0;
  list.mBuffers[0].mData = NULL;
  return list;
}

static bool sameUUID(REFIID uuid, CFUUIDRef reference) {
  CFUUIDBytes expected = CFUUIDGetUUIDBytes(reference);
  return memcmp(&uuid, &expected, sizeof(expected)) == 0;
}

static HRESULT IINA_QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface) {
  CFUUIDRef unknownUUID = CFUUIDGetConstantUUIDWithBytes(NULL, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);
  if (outInterface == NULL) {
    return E_NOINTERFACE;
  }
  if (sameUUID(uuid, kAudioServerPlugInDriverInterfaceUUID) || sameUUID(uuid, unknownUUID)) {
    *outInterface = driver;
    return S_OK;
  }
  *outInterface = NULL;
  return E_NOINTERFACE;
}

static ULONG IINA_AddRef(void *driver) {
  (void)driver;
  return 1;
}

static ULONG IINA_Release(void *driver) {
  (void)driver;
  return 1;
}

static OSStatus IINA_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
  struct mach_timebase_info info;
  if (!isDriver(driver)) {
    return kAudioHardwareBadObjectError;
  }
  gHost = host;
  (void)gHost;
  mach_timebase_info(&info);
  if (info.numer == 0) {
    info.numer = 1;
  }
  gTicksPerFrame = ((Float64)info.denom / (Float64)info.numer) * 1000000000.0 / kDevice_SampleRate;
  return noErr;
}

static OSStatus IINA_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo *clientInfo, AudioObjectID *outDeviceObjectID) {
  (void)description;
  (void)clientInfo;
  (void)outDeviceObjectID;
  if (!isDriver(driver)) {
    return kAudioHardwareBadObjectError;
  }
  return kAudioHardwareUnsupportedOperationError;
}

static OSStatus IINA_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID) {
  (void)deviceObjectID;
  if (!isDriver(driver)) {
    return kAudioHardwareBadObjectError;
  }
  return kAudioHardwareUnsupportedOperationError;
}

static OSStatus IINA_AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo *clientInfo) {
  (void)clientInfo;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device) {
    return kAudioHardwareBadObjectError;
  }
  return noErr;
}

static OSStatus IINA_RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo *clientInfo) {
  (void)clientInfo;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device) {
    return kAudioHardwareBadObjectError;
  }
  return noErr;
}

static OSStatus IINA_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void *changeInfo) {
  (void)changeAction;
  (void)changeInfo;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device) {
    return kAudioHardwareBadObjectError;
  }
  return noErr;
}

static OSStatus IINA_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void *changeInfo) {
  (void)changeAction;
  (void)changeInfo;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device) {
    return kAudioHardwareBadObjectError;
  }
  return noErr;
}

static bool selectorKnown(AudioObjectID objectID, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
  switch (objectID) {
    case kObjectID_PlugIn:
      return selector == kAudioObjectPropertyBaseClass || selector == kAudioObjectPropertyClass || selector == kAudioObjectPropertyOwner ||
        selector == kAudioObjectPropertyManufacturer || selector == kAudioObjectPropertyOwnedObjects || selector == kAudioPlugInPropertyBoxList ||
        selector == kAudioPlugInPropertyDeviceList || selector == kAudioPlugInPropertyTranslateUIDToDevice || selector == kAudioPlugInPropertyResourceBundle;
    case kObjectID_Box:
      return selector == kAudioObjectPropertyBaseClass || selector == kAudioObjectPropertyClass || selector == kAudioObjectPropertyOwner ||
        selector == kAudioObjectPropertyName || selector == kAudioObjectPropertyManufacturer || selector == kAudioObjectPropertyOwnedObjects ||
        selector == kAudioBoxPropertyBoxUID || selector == kAudioDevicePropertyTransportType || selector == kAudioBoxPropertyHasAudio ||
        selector == kAudioBoxPropertyHasVideo || selector == kAudioBoxPropertyHasMIDI || selector == kAudioBoxPropertyIsProtected ||
        selector == kAudioBoxPropertyAcquired || selector == kAudioBoxPropertyAcquisitionFailed || selector == kAudioBoxPropertyDeviceList;
    case kObjectID_Device:
      return selector == kAudioObjectPropertyBaseClass || selector == kAudioObjectPropertyClass || selector == kAudioObjectPropertyOwner ||
        selector == kAudioObjectPropertyName || selector == kAudioObjectPropertyManufacturer || selector == kAudioObjectPropertyOwnedObjects ||
        selector == kAudioObjectPropertyControlList || selector == kAudioDevicePropertyDeviceUID || selector == kAudioDevicePropertyModelUID ||
        selector == kAudioDevicePropertyTransportType || selector == kAudioDevicePropertyRelatedDevices || selector == kAudioDevicePropertyClockDomain ||
        selector == kAudioDevicePropertyDeviceIsAlive || selector == kAudioDevicePropertyDeviceIsRunning || selector == kAudioDevicePropertyDeviceIsRunningSomewhere ||
        selector == kAudioDevicePropertyDeviceCanBeDefaultDevice || selector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice ||
        selector == kAudioDevicePropertyLatency || selector == kAudioDevicePropertyStreams || selector == kAudioDevicePropertySafetyOffset ||
        selector == kAudioDevicePropertyNominalSampleRate || selector == kAudioDevicePropertyAvailableNominalSampleRates ||
        selector == kAudioDevicePropertyIsHidden || selector == kAudioDevicePropertyPreferredChannelsForStereo ||
        selector == kAudioDevicePropertyPreferredChannelLayout || selector == kAudioDevicePropertyZeroTimeStampPeriod ||
        selector == kAudioDevicePropertyBufferFrameSize || selector == kAudioDevicePropertyBufferFrameSizeRange ||
        selector == kAudioDevicePropertyUsesVariableBufferFrameSizes || selector == kAudioDevicePropertyStreamConfiguration;
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
      return selector == kAudioObjectPropertyBaseClass || selector == kAudioObjectPropertyClass || selector == kAudioObjectPropertyOwner ||
        selector == kAudioStreamPropertyDirection || selector == kAudioStreamPropertyTerminalType || selector == kAudioStreamPropertyStartingChannel ||
        selector == kAudioStreamPropertyLatency || selector == kAudioStreamPropertyVirtualFormat || selector == kAudioStreamPropertyPhysicalFormat ||
        selector == kAudioStreamPropertyAvailableVirtualFormats || selector == kAudioStreamPropertyAvailablePhysicalFormats ||
        selector == kAudioStreamPropertyIsActive;
    case kObjectID_Volume_Output:
      (void)scope;
      return selector == kAudioObjectPropertyBaseClass || selector == kAudioObjectPropertyClass || selector == kAudioObjectPropertyOwner ||
        selector == kAudioObjectPropertyOwnedObjects || selector == kAudioControlPropertyScope || selector == kAudioControlPropertyElement ||
        selector == kAudioLevelControlPropertyScalarValue || selector == kAudioLevelControlPropertyDecibelValue ||
        selector == kAudioLevelControlPropertyDecibelRange;
    default:
      return false;
  }
}

static Boolean IINA_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress *address) {
  (void)clientPID;
  if (!isDriver(driver) || address == NULL) {
    return false;
  }
  return selectorKnown(objectID, address->mSelector, address->mScope);
}

static OSStatus IINA_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress *address, Boolean *outIsSettable) {
  (void)clientPID;
  if (!isDriver(driver) || address == NULL || outIsSettable == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!selectorKnown(objectID, address->mSelector, address->mScope)) {
    return kAudioHardwareUnknownPropertyError;
  }
  *outIsSettable = (objectID == kObjectID_Volume_Output &&
      (address->mSelector == kAudioLevelControlPropertyScalarValue || address->mSelector == kAudioLevelControlPropertyDecibelValue)) ||
    (objectID == kObjectID_Device && address->mSelector == kAudioDevicePropertyNominalSampleRate);
  return noErr;
}

static UInt32 propertySize(AudioObjectID objectID, const AudioObjectPropertyAddress *address) {
  switch (address->mSelector) {
    case kAudioObjectPropertyOwnedObjects:
      if (objectID == kObjectID_PlugIn || objectID == kObjectID_Box) {
        return sizeof(AudioObjectID);
      }
      if (objectID == kObjectID_Device) {
        if (address->mScope == kAudioObjectPropertyScopeInput) {
          return sizeof(AudioObjectID);
        }
        if (address->mScope == kAudioObjectPropertyScopeOutput) {
          return sizeof(AudioObjectID) * 2;
        }
        return sizeof(AudioObjectID) * 3;
      }
      return 0;
    case kAudioObjectPropertyControlList:
      if (address->mScope == kAudioObjectPropertyScopeInput) {
        return 0;
      }
      return sizeof(AudioObjectID);
    case kAudioPlugInPropertyBoxList:
    case kAudioPlugInPropertyDeviceList:
    case kAudioBoxPropertyDeviceList:
    case kAudioDevicePropertyRelatedDevices:
      return sizeof(AudioObjectID);
    case kAudioDevicePropertyStreams:
      if (address->mScope == kAudioObjectPropertyScopeInput || address->mScope == kAudioObjectPropertyScopeOutput) {
        return sizeof(AudioObjectID);
      }
      return sizeof(AudioObjectID) * 2;
    case kAudioDevicePropertyPreferredChannelsForStereo:
      return sizeof(UInt32) * 2;
    case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioLevelControlPropertyDecibelRange:
    case kAudioDevicePropertyBufferFrameSizeRange:
      return sizeof(AudioValueRange);
    case kAudioDevicePropertyPreferredChannelLayout:
      return (UInt32)sizeof(AudioChannelLayout);
    case kAudioDevicePropertyStreamConfiguration:
      return (UInt32)sizeof(AudioBufferList);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
    case kAudioDevicePropertyNominalSampleRate:
      return address->mSelector == kAudioDevicePropertyNominalSampleRate ? sizeof(Float64) : (UInt32)sizeof(AudioStreamBasicDescription);
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
      return (UInt32)sizeof(AudioStreamRangedDescription);
    case kAudioPlugInPropertyTranslateUIDToDevice:
      return sizeof(AudioObjectID);
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kAudioBoxPropertyBoxUID:
    case kAudioPlugInPropertyResourceBundle:
      return sizeof(CFStringRef);
    default:
      return sizeof(UInt32);
  }
}

static OSStatus IINA_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 *outDataSize) {
  (void)clientPID;
  (void)qualifierSize;
  (void)qualifier;
  if (!isDriver(driver) || address == NULL || outDataSize == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!selectorKnown(objectID, address->mSelector, address->mScope)) {
    return kAudioHardwareUnknownPropertyError;
  }
  *outDataSize = propertySize(objectID, address);
  return noErr;
}

static OSStatus getPlugInProperty(const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inSize, UInt32 *outSize, void *out) {
  AudioObjectID owned = kObjectID_Box;
  AudioObjectID device = kObjectID_Device;
  switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
      return writeID(kAudioObjectClassID, inSize, outSize, out);
    case kAudioObjectPropertyClass:
      return writeID(kAudioPlugInClassID, inSize, outSize, out);
    case kAudioObjectPropertyOwner:
      return writeID(kAudioObjectSystemObject, inSize, outSize, out);
    case kAudioObjectPropertyManufacturer:
      return writeString("IINA", inSize, outSize, out);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyBoxList:
      return writeBlock(&owned, sizeof(owned), inSize, outSize, out);
    case kAudioPlugInPropertyDeviceList:
      return writeBlock(&device, sizeof(device), inSize, outSize, out);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
      CFStringRef uid;
      AudioObjectID found = kAudioObjectUnknown;
      if (qualifierSize < sizeof(CFStringRef) || qualifier == NULL) {
        return kAudioHardwareBadPropertySizeError;
      }
      uid = *((CFStringRef *)qualifier);
      if (uid != NULL && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo) {
        found = kObjectID_Device;
      }
      return writeID(found, inSize, outSize, out);
    }
    case kAudioPlugInPropertyResourceBundle:
      return writeString("", inSize, outSize, out);
    default:
      return kAudioHardwareUnknownPropertyError;
  }
}

static OSStatus getBoxProperty(const AudioObjectPropertyAddress *address, UInt32 inSize, UInt32 *outSize, void *out) {
  AudioObjectID device = kObjectID_Device;
  switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
      return writeID(kAudioObjectClassID, inSize, outSize, out);
    case kAudioObjectPropertyClass:
      return writeID(kAudioBoxClassID, inSize, outSize, out);
    case kAudioObjectPropertyOwner:
      return writeID(kObjectID_PlugIn, inSize, outSize, out);
    case kAudioObjectPropertyName:
      return writeString(kDevice_Name, inSize, outSize, out);
    case kAudioObjectPropertyManufacturer:
      return writeString("IINA", inSize, outSize, out);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioBoxPropertyDeviceList:
      return writeBlock(&device, sizeof(device), inSize, outSize, out);
    case kAudioBoxPropertyBoxUID:
      return writeString(kBox_UID, inSize, outSize, out);
    case kAudioDevicePropertyTransportType:
      return writeUInt32(kAudioDeviceTransportTypeVirtual, inSize, outSize, out);
    case kAudioBoxPropertyHasAudio:
    case kAudioBoxPropertyAcquired:
      return writeUInt32(1, inSize, outSize, out);
    case kAudioBoxPropertyHasVideo:
    case kAudioBoxPropertyHasMIDI:
    case kAudioBoxPropertyIsProtected:
    case kAudioBoxPropertyAcquisitionFailed:
      return writeUInt32(0, inSize, outSize, out);
    default:
      return kAudioHardwareUnknownPropertyError;
  }
}

static bool outputScope(AudioObjectPropertyScope scope) {
  return scope == kAudioObjectPropertyScopeOutput || scope == kAudioObjectPropertyScopeGlobal;
}

static OSStatus getDeviceProperty(const AudioObjectPropertyAddress *address, UInt32 inSize, UInt32 *outSize, void *out) {
  switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
      return writeID(kAudioObjectClassID, inSize, outSize, out);
    case kAudioObjectPropertyClass:
      return writeID(kAudioDeviceClassID, inSize, outSize, out);
    case kAudioObjectPropertyOwner:
      return writeID(kObjectID_Box, inSize, outSize, out);
    case kAudioObjectPropertyName:
      return writeString(kDevice_Name, inSize, outSize, out);
    case kAudioObjectPropertyManufacturer:
      return writeString("IINA", inSize, outSize, out);
    case kAudioObjectPropertyOwnedObjects: {
      AudioObjectID globalIDs[3] = {kObjectID_Stream_Input, kObjectID_Stream_Output, kObjectID_Volume_Output};
      AudioObjectID outputIDs[2] = {kObjectID_Stream_Output, kObjectID_Volume_Output};
      AudioObjectID inputID = kObjectID_Stream_Input;
      if (address->mScope == kAudioObjectPropertyScopeInput) {
        return writeBlock(&inputID, sizeof(inputID), inSize, outSize, out);
      }
      if (address->mScope == kAudioObjectPropertyScopeOutput) {
        return writeBlock(outputIDs, sizeof(outputIDs), inSize, outSize, out);
      }
      return writeBlock(globalIDs, sizeof(globalIDs), inSize, outSize, out);
    }
    case kAudioObjectPropertyControlList: {
      AudioObjectID volume = kObjectID_Volume_Output;
      if (address->mScope == kAudioObjectPropertyScopeInput) {
        *outSize = 0;
        return noErr;
      }
      return writeBlock(&volume, sizeof(volume), inSize, outSize, out);
    }
    case kAudioDevicePropertyDeviceUID:
      return writeString(kDevice_UID, inSize, outSize, out);
    case kAudioDevicePropertyModelUID:
      return writeString(kDevice_ModelUID, inSize, outSize, out);
    case kAudioDevicePropertyTransportType:
      return writeUInt32(kAudioDeviceTransportTypeVirtual, inSize, outSize, out);
    case kAudioDevicePropertyRelatedDevices: {
      AudioObjectID self = kObjectID_Device;
      return writeBlock(&self, sizeof(self), inSize, outSize, out);
    }
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyIsHidden:
      return writeUInt32(0, inSize, outSize, out);
    case kAudioDevicePropertyDeviceIsAlive:
      return writeUInt32(1, inSize, outSize, out);
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceIsRunningSomewhere:
      pthread_mutex_lock(&gMutex);
      {
        UInt32 running = gIOCount > 0 ? 1 : 0;
        pthread_mutex_unlock(&gMutex);
        return writeUInt32(running, inSize, outSize, out);
      }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
      return writeUInt32(address->mScope == kAudioObjectPropertyScopeInput ? 0 : 1, inSize, outSize, out);
    case kAudioDevicePropertyStreams: {
      AudioObjectID both[2] = {kObjectID_Stream_Output, kObjectID_Stream_Input};
      AudioObjectID one = address->mScope == kAudioObjectPropertyScopeInput ? kObjectID_Stream_Input : kObjectID_Stream_Output;
      if (address->mScope == kAudioObjectPropertyScopeInput || address->mScope == kAudioObjectPropertyScopeOutput) {
        return writeBlock(&one, sizeof(one), inSize, outSize, out);
      }
      return writeBlock(both, sizeof(both), inSize, outSize, out);
    }
    case kAudioDevicePropertyNominalSampleRate:
      return writeFloat64(kDevice_SampleRate, inSize, outSize, out);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
      AudioValueRange range = {kDevice_SampleRate, kDevice_SampleRate};
      return writeBlock(&range, sizeof(range), inSize, outSize, out);
    }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
      UInt32 channels[2] = {1, 2};
      return writeBlock(channels, sizeof(channels), inSize, outSize, out);
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
      AudioChannelLayout layout;
      memset(&layout, 0, sizeof(layout));
      layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
      return writeBlock(&layout, sizeof(layout), inSize, outSize, out);
    }
    case kAudioDevicePropertyZeroTimeStampPeriod:
      return writeUInt32(IINA_RING_FRAMES, inSize, outSize, out);
    case kAudioDevicePropertyBufferFrameSize:
      return writeUInt32(512, inSize, outSize, out);
    case kAudioDevicePropertyBufferFrameSizeRange: {
      AudioValueRange range = {128, 2048};
      return writeBlock(&range, sizeof(range), inSize, outSize, out);
    }
    case kAudioDevicePropertyUsesVariableBufferFrameSizes:
      return writeUInt32(1, inSize, outSize, out);
    case kAudioDevicePropertyStreamConfiguration: {
      AudioBufferList list = stereoBuffers();
      (void)outputScope(address->mScope);
      return writeBlock(&list, sizeof(list), inSize, outSize, out);
    }
    default:
      return kAudioHardwareUnknownPropertyError;
  }
}

static OSStatus getStreamProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *address, UInt32 inSize, UInt32 *outSize, void *out) {
  AudioStreamBasicDescription format = streamFormat();
  switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
      return writeID(kAudioObjectClassID, inSize, outSize, out);
    case kAudioObjectPropertyClass:
      return writeID(kAudioStreamClassID, inSize, outSize, out);
    case kAudioObjectPropertyOwner:
      return writeID(kObjectID_Device, inSize, outSize, out);
    case kAudioStreamPropertyDirection:
      return writeUInt32(objectID == kObjectID_Stream_Input ? 1 : 0, inSize, outSize, out);
    case kAudioStreamPropertyTerminalType:
      return writeUInt32(objectID == kObjectID_Stream_Input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker, inSize, outSize, out);
    case kAudioStreamPropertyStartingChannel:
      return writeUInt32(1, inSize, outSize, out);
    case kAudioStreamPropertyLatency:
      return writeUInt32(0, inSize, outSize, out);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
      return writeBlock(&format, sizeof(format), inSize, outSize, out);
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
      AudioStreamRangedDescription ranged;
      memset(&ranged, 0, sizeof(ranged));
      ranged.mFormat = format;
      ranged.mSampleRateRange.mMinimum = kDevice_SampleRate;
      ranged.mSampleRateRange.mMaximum = kDevice_SampleRate;
      return writeBlock(&ranged, sizeof(ranged), inSize, outSize, out);
    }
    case kAudioStreamPropertyIsActive:
      return writeUInt32(1, inSize, outSize, out);
    default:
      return kAudioHardwareUnknownPropertyError;
  }
}

static OSStatus getVolumeProperty(const AudioObjectPropertyAddress *address, UInt32 inSize, UInt32 *outSize, void *out) {
  switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
      return writeID(kAudioLevelControlClassID, inSize, outSize, out);
    case kAudioObjectPropertyClass:
      return writeID(kAudioVolumeControlClassID, inSize, outSize, out);
    case kAudioObjectPropertyOwner:
      return writeID(kObjectID_Device, inSize, outSize, out);
    case kAudioObjectPropertyOwnedObjects:
      *outSize = 0;
      return noErr;
    case kAudioControlPropertyScope:
      return writeUInt32(kAudioObjectPropertyScopeOutput, inSize, outSize, out);
    case kAudioControlPropertyElement:
      return writeUInt32(kAudioObjectPropertyElementMain, inSize, outSize, out);
    case kAudioLevelControlPropertyScalarValue:
      pthread_mutex_lock(&gMutex);
      {
        Float32 volume = gVolume;
        pthread_mutex_unlock(&gMutex);
        return writeFloat32(volume, inSize, outSize, out);
      }
    case kAudioLevelControlPropertyDecibelValue:
      pthread_mutex_lock(&gMutex);
      {
        Float32 volume = gVolume;
        pthread_mutex_unlock(&gMutex);
        if (volume <= 0.0001f) {
          return writeFloat32(-96.0f, inSize, outSize, out);
        }
        return writeFloat32(20.0f * log10f(volume), inSize, outSize, out);
      }
    case kAudioLevelControlPropertyDecibelRange: {
      AudioValueRange range = {-96.0, 0.0};
      return writeBlock(&range, sizeof(range), inSize, outSize, out);
    }
    default:
      return kAudioHardwareUnknownPropertyError;
  }
}

static OSStatus IINA_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
  (void)clientPID;
  if (!isDriver(driver) || address == NULL || outDataSize == NULL || outData == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!selectorKnown(objectID, address->mSelector, address->mScope)) {
    return kAudioHardwareUnknownPropertyError;
  }
  switch (objectID) {
    case kObjectID_PlugIn:
      return getPlugInProperty(address, qualifierSize, qualifier, inDataSize, outDataSize, outData);
    case kObjectID_Box:
      return getBoxProperty(address, inDataSize, outDataSize, outData);
    case kObjectID_Device:
      return getDeviceProperty(address, inDataSize, outDataSize, outData);
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
      return getStreamProperty(objectID, address, inDataSize, outDataSize, outData);
    case kObjectID_Volume_Output:
      return getVolumeProperty(address, inDataSize, outDataSize, outData);
    default:
      return kAudioHardwareBadObjectError;
  }
}

/* The MacOSX26 SDK dropped the change-list out-parameters. On arm64 the
   older coreaudiod still passes them; this callee simply ignores the extras. */
static OSStatus IINA_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inDataSize, const void *inData) {
  (void)clientPID;
  (void)qualifierSize;
  (void)qualifier;
  if (!isDriver(driver) || address == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!selectorKnown(objectID, address->mSelector, address->mScope)) {
    return kAudioHardwareUnknownPropertyError;
  }
  if (objectID == kObjectID_Device && address->mSelector == kAudioDevicePropertyNominalSampleRate) {
    Float64 rate;
    if (inDataSize != sizeof(Float64) || inData == NULL) {
      return kAudioHardwareBadPropertySizeError;
    }
    rate = *((const Float64 *)inData);
    if (rate != kDevice_SampleRate) {
      return kAudioHardwareIllegalOperationError;
    }
    return noErr;
  }
  if (objectID == kObjectID_Volume_Output && address->mSelector == kAudioLevelControlPropertyScalarValue) {
    Float32 volume;
    if (inDataSize != sizeof(Float32) || inData == NULL) {
      return kAudioHardwareBadPropertySizeError;
    }
    volume = *((const Float32 *)inData);
    if (volume < 0.0f) {
      volume = 0.0f;
    }
    if (volume > 1.0f) {
      volume = 1.0f;
    }
    pthread_mutex_lock(&gMutex);
    gVolume = volume;
    pthread_mutex_unlock(&gMutex);
    return noErr;
  }
  if (objectID == kObjectID_Volume_Output && address->mSelector == kAudioLevelControlPropertyDecibelValue) {
    Float32 decibels;
    Float32 volume;
    if (inDataSize != sizeof(Float32) || inData == NULL) {
      return kAudioHardwareBadPropertySizeError;
    }
    decibels = *((const Float32 *)inData);
    if (decibels <= -96.0f) {
      volume = 0.0f;
    } else {
      volume = powf(10.0f, decibels / 20.0f);
    }
    if (volume > 1.0f) {
      volume = 1.0f;
    }
    pthread_mutex_lock(&gMutex);
    gVolume = volume;
    pthread_mutex_unlock(&gMutex);
    return noErr;
  }
  return kAudioHardwareUnknownPropertyError;
}

static OSStatus IINA_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
  (void)clientID;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device) {
    return kAudioHardwareBadObjectError;
  }
  pthread_mutex_lock(&gMutex);
  if (gIOCount == 0) {
    IINALoopback_Reset(&gLoop);
    IINAClock_Reset(&gClock, gTicksPerFrame, IINA_RING_FRAMES, (double)mach_absolute_time());
    gReaderKnown = false;
    gReaderClient = 0;
  }
  gIOCount += 1;
  pthread_mutex_unlock(&gMutex);
  return noErr;
}

static OSStatus IINA_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
  (void)clientID;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device) {
    return kAudioHardwareBadObjectError;
  }
  pthread_mutex_lock(&gMutex);
  if (gIOCount == 0) {
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareIllegalOperationError;
  }
  gIOCount -= 1;
  pthread_mutex_unlock(&gMutex);
  return noErr;
}

static OSStatus IINA_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
  double now;
  double sample;
  double host;
  (void)clientID;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device || outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
    return kAudioHardwareBadObjectError;
  }
  pthread_mutex_lock(&gMutex);
  now = (double)mach_absolute_time();
  if (gClock.anchorHost == 0 || gClock.periodFrames == 0) {
    IINAClock_Reset(&gClock, gTicksPerFrame > 0 ? gTicksPerFrame : 1, IINA_RING_FRAMES, now);
  }
  IINAClock_Read(&gClock, now, &sample, &host);
  *outSampleTime = sample;
  *outHostTime = (UInt64)host;
  *outSeed = 1;
  pthread_mutex_unlock(&gMutex);
  return noErr;
}

static OSStatus IINA_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
  bool willDo = false;
  (void)clientID;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device) {
    return kAudioHardwareBadObjectError;
  }
  if (operationID == kAudioServerPlugInIOOperationReadInput || operationID == kAudioServerPlugInIOOperationWriteMix) {
    willDo = true;
  }
  if (outWillDo != NULL) {
    *outWillDo = willDo;
  }
  if (outWillDoInPlace != NULL) {
    *outWillDoInPlace = true;
  }
  return noErr;
}

static OSStatus IINA_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo) {
  (void)clientID;
  (void)operationID;
  (void)ioBufferFrameSize;
  (void)ioCycleInfo;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device) {
    return kAudioHardwareBadObjectError;
  }
  return noErr;
}

static OSStatus IINA_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
  Float64 sampleTime;
  Float32 volume;
  int writer;
  (void)streamObjectID;
  (void)ioSecondaryBuffer;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device || ioCycleInfo == NULL) {
    return kAudioHardwareBadObjectError;
  }
  if (ioBufferFrameSize == 0 || ioMainBuffer == NULL) {
    return noErr;
  }
  pthread_mutex_lock(&gMutex);
  if (operationID == kAudioServerPlugInIOOperationReadInput) {
    gReaderClient = clientID;
    gReaderKnown = true;
    sampleTime = ioCycleInfo->mInputTime.mSampleTime;
    volume = gVolume;
    IINALoopback_Read(&gLoop, sampleTime, ioMainBuffer, ioBufferFrameSize);
    if (volume < 0.999f) {
      Float32 *samples = ioMainBuffer;
      UInt32 count = ioBufferFrameSize * IINA_RING_CHANNELS;
      UInt32 index;
      for (index = 0; index < count; index++) {
        samples[index] *= volume;
      }
    }
  } else if (operationID == kAudioServerPlugInIOOperationWriteMix) {
    sampleTime = ioCycleInfo->mOutputTime.mSampleTime;
    writer = (gReaderKnown && clientID == gReaderClient) ? IINA_LOOPBACK_READER : IINA_LOOPBACK_SOURCE;
    IINALoopback_Write(&gLoop, sampleTime, ioMainBuffer, ioBufferFrameSize, writer);
  }
  pthread_mutex_unlock(&gMutex);
  return noErr;
}

static OSStatus IINA_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo) {
  (void)clientID;
  (void)operationID;
  (void)ioBufferFrameSize;
  (void)ioCycleInfo;
  if (!isDriver(driver) || deviceObjectID != kObjectID_Device) {
    return kAudioHardwareBadObjectError;
  }
  return noErr;
}

__attribute__((constructor))
static void IINA_InstallInterface(void) {
  AudioServerPlugInDriverInterface interface = {
    NULL,
    IINA_QueryInterface,
    IINA_AddRef,
    IINA_Release,
    IINA_Initialize,
    IINA_CreateDevice,
    IINA_DestroyDevice,
    IINA_AddDeviceClient,
    IINA_RemoveDeviceClient,
    IINA_PerformDeviceConfigurationChange,
    IINA_AbortDeviceConfigurationChange,
    IINA_HasProperty,
    IINA_IsPropertySettable,
    IINA_GetPropertyDataSize,
    IINA_GetPropertyData,
    IINA_SetPropertyData,
    IINA_StartIO,
    IINA_StopIO,
    IINA_GetZeroTimeStamp,
    IINA_WillDoIOOperation,
    IINA_BeginIOOperation,
    IINA_DoIOOperation,
    IINA_EndIOOperation
  };
  gInterface = interface;
}

__attribute__((visibility("default")))
void *IINACaptureAudio_Create(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
  (void)allocator;
  if (typeUUID != NULL && CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
    return gDriverRef;
  }
  return NULL;
}
