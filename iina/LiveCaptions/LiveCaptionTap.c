//
//  LiveCaptionTap.c
//  iina
//
//  libmpv does not hand decoded PCM to the host. On macOS it plays through
//  Core Audio, and the render callback is the buffer it just decoded. This
//  file wraps that callback. No second connection is opened.

#include "LiveCaptionTap.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/AudioHardware.h>
#include <dlfcn.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

enum { kRing = 192000 * 12 };

static float g_ring[kRing];
static atomic_llong g_write;
static atomic_llong g_mark;
static atomic_int g_enabled;
static atomic_int g_arm;
static atomic_int g_attached;
static atomic_int g_rate;
static atomic_int g_channels;
static atomic_uintptr_t g_au_proc;
static atomic_uintptr_t g_hal_proc;

static AudioStreamBasicDescription g_format;
static int g_format_ready;
static atomic_int g_logged_format;
static os_log_t g_log;

static OSStatus (*g_real_set_property)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus (*g_real_create_proc)(AudioObjectID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *);

static void remember_format(const AudioStreamBasicDescription *format) {
  if (!format || format->mSampleRate < 8000 || format->mSampleRate > 192000) {
    return;
  }
  if (format->mChannelsPerFrame < 1 || format->mChannelsPerFrame > 16) {
    return;
  }
  g_format = *format;
  g_format_ready = 1;
  atomic_store(&g_rate, (int)format->mSampleRate);
  atomic_store(&g_channels, (int)format->mChannelsPerFrame);
}

static void log_callback(const char *kind) {
  if (!g_log) {
    g_log = os_log_create("com.colliderli.iina", "LiveCaptions");
  }
  os_log(g_log, "mpv audio callback %{public}s %d Hz %d ch",
         kind,
         atomic_load(&g_rate),
         atomic_load(&g_channels));
}

static void push_frames(const float *mono, int count) {
  if (!mono || count <= 0) {
    return;
  }
  long long pos = atomic_load_explicit(&g_write, memory_order_relaxed);
  for (int i = 0; i < count; i++) {
    g_ring[(pos + i) % kRing] = mono[i];
  }
  atomic_store_explicit(&g_write, pos + count, memory_order_release);
}

static float sample_as_float(const void *data, int index, int is_float) {
  if (is_float) {
    return ((const float *)data)[index];
  }
  return (float)((const int16_t *)data)[index] / 32768.0f;
}

static UInt32 frame_count(const AudioBufferList *list) {
  if (!list || list->mNumberBuffers == 0 || list->mBuffers[0].mDataByteSize == 0) {
    return 0;
  }
  int channels = g_format_ready && g_format.mChannelsPerFrame > 0 ? (int)g_format.mChannelsPerFrame : 1;
  int bits = g_format_ready && g_format.mBitsPerChannel > 0 ? (int)g_format.mBitsPerChannel : 32;
  int sample_bytes = bits / 8;
  if (sample_bytes <= 0) {
    sample_bytes = 4;
  }
  int non_interleaved = g_format_ready && (g_format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  int stride = non_interleaved ? sample_bytes : sample_bytes * channels;
  if (stride <= 0) {
    return 0;
  }
  return list->mBuffers[0].mDataByteSize / (UInt32)stride;
}

static void ingest(const AudioBufferList *list, UInt32 frames) {
  if (!atomic_load(&g_enabled) || !list || frames == 0) {
    return;
  }
  int channels = g_format_ready ? (int)g_format.mChannelsPerFrame : 0;
  int is_float = 1;
  int non_interleaved = 0;
  if (g_format_ready) {
    int float32 = (g_format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && g_format.mBitsPerChannel == 32;
    int pcm16 = (g_format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
                (g_format.mFormatFlags & kAudioFormatFlagIsFloat) == 0 &&
                g_format.mBitsPerChannel == 16;
    if (g_format.mFormatID != kAudioFormatLinearPCM || (!float32 && !pcm16)) {
      if (atomic_exchange(&g_logged_format, 1) == 0) {
        if (!g_log) {
          g_log = os_log_create("com.colliderli.iina", "LiveCaptions");
        }
        os_log(g_log, "mpv audio format not PCM float32/s16 flags %u bits %u",
               g_format.mFormatFlags, g_format.mBitsPerChannel);
      }
      return;
    }
    is_float = float32;
    non_interleaved = (g_format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  }
  const AudioBuffer *buffers = list->mBuffers;
  UInt32 buffer_count = list->mNumberBuffers;
  if (buffer_count == 0 || !buffers[0].mData) {
    return;
  }
  if (channels <= 0) {
    channels = non_interleaved ? (int)buffer_count : 1;
    UInt32 bytes = buffers[0].mDataByteSize;
    if (frames > 0 && bytes >= frames * (UInt32)channels * sizeof(float)) {
      is_float = 1;
    } else if (frames > 0 && bytes >= frames * (UInt32)channels * sizeof(int16_t)) {
      is_float = 0;
    } else {
      return;
    }
  }
  if (channels > 16) {
    channels = 16;
  }
  UInt32 done = 0;
  while (done < frames) {
  UInt32 limit = frames - done;
  if (limit > 2048) {
    limit = 2048;
  }
  float mono[2048];
  if (non_interleaved || (buffer_count > 1 && channels == (int)buffer_count)) {
    int used = 0;
    for (UInt32 i = 0; i < limit; i++) {
      mono[i] = 0;
    }
    for (UInt32 b = 0; b < buffer_count && used < channels; b++) {
      if (!buffers[b].mData) {
        continue;
      }
      for (UInt32 i = 0; i < limit; i++) {
        mono[i] += sample_as_float(buffers[b].mData, (int)(done + i), is_float);
      }
      used += 1;
    }
    if (used <= 0) {
      return;
    }
    if (used > 1) {
      float scale = 1.0f / (float)used;
      for (UInt32 i = 0; i < limit; i++) {
        mono[i] *= scale;
      }
    }
  } else {
    const void *data = buffers[0].mData;
    for (UInt32 i = 0; i < limit; i++) {
      float sum = 0;
      for (int channel = 0; channel < channels; channel++) {
        sum += sample_as_float(data, (int)(done + i) * channels + channel, is_float);
      }
      mono[i] = sum / (float)channels;
    }
  }
  push_frames(mono, (int)limit);
  done += limit;
  }
}

static OSStatus wrapped_au(void *refcon,
                           AudioUnitRenderActionFlags *flags,
                           const AudioTimeStamp *timestamp,
                           UInt32 bus,
                           UInt32 frames,
                           AudioBufferList *data) {
  AURenderCallback original = (AURenderCallback)atomic_load(&g_au_proc);
  OSStatus status = noErr;
  if (original) {
    status = original(refcon, flags, timestamp, bus, frames, data);
  }
  if (status == noErr) {
    ingest(data, frames);
  }
  return status;
}

static OSStatus wrapped_hal(AudioObjectID device,
                            const AudioTimeStamp *now,
                            const AudioBufferList *input,
                            const AudioTimeStamp *input_time,
                            AudioBufferList *output,
                            const AudioTimeStamp *output_time,
                            void *client) {
  AudioDeviceIOProc original = (AudioDeviceIOProc)atomic_load(&g_hal_proc);
  OSStatus status = noErr;
  if (original) {
    status = original(device, now, input, input_time, output, output_time, client);
  }
  if (status == noErr) {
    ingest(output, frame_count(output));
  }
  return status;
}

typedef OSStatus (*IINAUnitGetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *);
static IINAUnitGetProperty g_get_property;

static void note_unit_format(AudioUnit unit) {
  if (!g_get_property) {
    g_get_property = (IINAUnitGetProperty)dlsym(RTLD_NEXT, "AudioUnitGetProperty");
  }
  if (!g_get_property) {
    return;
  }
  AudioUnitScope scopes[2] = { kAudioUnitScope_Input, kAudioUnitScope_Output };
  for (int i = 0; i < 2; i++) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    UInt32 size = sizeof(format);
    if (g_get_property(unit, kAudioUnitProperty_StreamFormat, scopes[i], 0, &format, &size) == noErr &&
        format.mSampleRate >= 8000) {
      remember_format(&format);
      return;
    }
  }
}

static OSStatus iina_AudioUnitSetProperty(AudioUnit unit,
                                          AudioUnitPropertyID property,
                                          AudioUnitScope scope,
                                          AudioUnitElement element,
                                          const void *data,
                                          UInt32 size) {
  if (!g_real_set_property) {
    g_real_set_property = (OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32))dlsym(RTLD_NEXT, "AudioUnitSetProperty");
  }
  if (property == kAudioUnitProperty_SetRenderCallback &&
      data &&
      size >= sizeof(AURenderCallbackStruct) &&
      atomic_load(&g_arm) &&
      g_real_set_property) {
    const AURenderCallbackStruct *incoming = data;
    atomic_store(&g_au_proc, (uintptr_t)incoming->inputProc);
    note_unit_format(unit);
    AURenderCallbackStruct wrapped = incoming[0];
    wrapped.inputProc = wrapped_au;
    OSStatus status = g_real_set_property(unit, property, scope, element, &wrapped, sizeof(wrapped));
    if (status == noErr) {
      atomic_store(&g_mark, atomic_load(&g_write));
      atomic_store(&g_attached, 1);
      atomic_store(&g_arm, 0);
      log_callback("audiounit");
    }
    return status;
  }
  if (!g_real_set_property) {
    return kAudioUnitErr_InvalidParameter;
  }
  return g_real_set_property(unit, property, scope, element, data, size);
}

static void note_device_format(AudioObjectID device) {
  AudioStreamBasicDescription format;
  memset(&format, 0, sizeof(format));
  UInt32 size = sizeof(format);
  AudioObjectPropertyAddress address = {
    kAudioDevicePropertyStreamFormat,
    kAudioObjectPropertyScopeOutput,
#if defined(kAudioObjectPropertyElementMain)
    kAudioObjectPropertyElementMain
#else
    kAudioObjectPropertyElementMaster
#endif
  };
  OSStatus (*get_data)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *) =
      (OSStatus (*)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *))dlsym(RTLD_NEXT, "AudioObjectGetPropertyData");
  if (get_data && get_data(device, &address, 0, NULL, &size, &format) == noErr) {
    remember_format(&format);
  }
}

static OSStatus iina_AudioDeviceCreateIOProcID(AudioObjectID device,
                                               AudioDeviceIOProc proc,
                                               void *client,
                                               AudioDeviceIOProcID *out_proc) {
  if (!g_real_create_proc) {
    g_real_create_proc = (OSStatus (*)(AudioObjectID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *))dlsym(RTLD_NEXT, "AudioDeviceCreateIOProcID");
  }
  if (atomic_load(&g_arm) && proc && g_real_create_proc) {
    atomic_store(&g_hal_proc, (uintptr_t)proc);
    note_device_format(device);
    OSStatus status = g_real_create_proc(device, wrapped_hal, client, out_proc);
    if (status == noErr) {
      atomic_store(&g_mark, atomic_load(&g_write));
      atomic_store(&g_attached, 1);
      atomic_store(&g_arm, 0);
      log_callback("hal");
    }
    return status;
  }
  if (!g_real_create_proc) {
    return kAudioHardwareUnspecifiedError;
  }
  return g_real_create_proc(device, proc, client, out_proc);
}

typedef struct IINAInterpose {
  const void *replacement;
  const void *original;
} IINAInterpose;

__attribute__((used)) static const IINAInterpose kInterpose[]
__attribute__((section("__DATA,__interpose"))) = {
  { (const void *)iina_AudioUnitSetProperty, (const void *)AudioUnitSetProperty },
  { (const void *)iina_AudioDeviceCreateIOProcID, (const void *)AudioDeviceCreateIOProcID }
};

__attribute__((constructor, used))
static void iina_caption_tap_keep_interpose(void) {
  (void)kInterpose;
}

void iina_caption_tap_set_enabled(int enabled) {
  atomic_store(&g_enabled, enabled ? 1 : 0);
}

void iina_caption_tap_arm(void) {
  atomic_store(&g_arm, 1);
}

void iina_caption_tap_disarm(void) {
  atomic_store(&g_arm, 0);
}

void iina_caption_tap_mark(void) {
  atomic_store(&g_mark, atomic_load(&g_write));
}

int iina_caption_tap_attached(void) {
  return atomic_load(&g_attached);
}

int iina_caption_tap_rate(void) {
  return atomic_load(&g_rate);
}

int iina_caption_tap_channels(void) {
  return atomic_load(&g_channels);
}

int iina_caption_tap_copy(float *dst, int max_frames) {
  if (!dst || max_frames <= 0) {
    return 0;
  }
  long long end = atomic_load_explicit(&g_write, memory_order_acquire);
  long long start = atomic_load(&g_mark);
  if (end <= start) {
    return 0;
  }
  if (end - start > max_frames) {
    start = end - max_frames;
  }
  if (end - start > kRing) {
    start = end - kRing;
  }
  if (start < 0) {
    start = 0;
  }
  int count = (int)(end - start);
  for (int i = 0; i < count; i++) {
    dst[i] = g_ring[(start + i) % kRing];
  }
  return count;
}
