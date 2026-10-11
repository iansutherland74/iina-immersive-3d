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

static AudioStreamBasicDescription g_format;
static int g_format_ready;
static atomic_int g_logged_format;
static atomic_int g_expect_rate;
static atomic_int g_expect_channels;
static atomic_int g_selected;
static atomic_int g_slot_seq;
static os_log_t g_log;

enum { kSlots = 4 };

typedef struct TapSlot {
  int index;
  int in_use;
  int logged;
  atomic_int accept;
  AURenderCallback au_proc;
  void *au_refcon;
  AudioDeviceIOProc hal_proc;
  void *hal_client;
  AudioStreamBasicDescription format;
  int rate;
  int channels;
  int seq;
} TapSlot;

static TapSlot g_slots[kSlots];

static OSStatus (*g_real_set_property)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus (*g_real_create_proc)(AudioObjectID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *);

static void log_callback(const char *kind, int rate, int channels) {
  if (!g_log) {
    g_log = os_log_create("com.colliderli.iina", "LiveCaptions");
  }
  os_log(g_log, "mpv audio callback %{public}s %d Hz %d ch", kind, rate, channels);
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

static int rate_matches(int rate, int channels) {
  int expect_rate = atomic_load(&g_expect_rate);
  int expect_channels = atomic_load(&g_expect_channels);
  // An unknown player rate must not accept the first unit that appears.
  // The wrapper stays installed, and selection happens once the rate is known.
  if (expect_rate < 8000 || rate < 8000) {
    return 0;
  }
  int delta = rate - expect_rate;
  if (delta < 0) {
    delta = -delta;
  }
  if (delta > 1) {
    return 0;
  }
  if (expect_channels > 0 && channels > 0 && channels != expect_channels) {
    return 0;
  }
  return 1;
}

static TapSlot *claim_slot(void) {
  int selected = atomic_load(&g_selected);
  int seq = atomic_fetch_add(&g_slot_seq, 1) + 1;
  for (int i = 0; i < kSlots; i++) {
    if (!g_slots[i].in_use) {
      g_slots[i].index = i;
      g_slots[i].in_use = 1;
      g_slots[i].logged = 0;
      g_slots[i].seq = seq;
      atomic_store(&g_slots[i].accept, 0);
      return &g_slots[i];
    }
  }
  for (int i = 0; i < kSlots; i++) {
    if (selected != i + 1) {
      g_slots[i].index = i;
      g_slots[i].in_use = 1;
      g_slots[i].logged = 0;
      g_slots[i].seq = seq;
      g_slots[i].au_proc = NULL;
      g_slots[i].hal_proc = NULL;
      atomic_store(&g_slots[i].accept, 0);
      return &g_slots[i];
    }
  }
  return &g_slots[0];
}

static void select_matching(void) {
  int chosen = 0;
  int best_seq = -1;
  for (int i = 0; i < kSlots; i++) {
    if (!g_slots[i].in_use) {
      continue;
    }
    int ok = rate_matches(g_slots[i].rate, g_slots[i].channels);
    atomic_store(&g_slots[i].accept, ok);
    if (ok && g_slots[i].seq >= best_seq) {
      best_seq = g_slots[i].seq;
      chosen = i + 1;
    }
  }
  int previous = atomic_load(&g_selected);
  atomic_store(&g_selected, chosen);
  if (chosen) {
    TapSlot *slot = &g_slots[chosen - 1];
    g_format = slot->format;
    g_format_ready = slot->rate >= 8000;
    atomic_store(&g_rate, slot->rate);
    atomic_store(&g_channels, slot->channels);
    atomic_store(&g_attached, 1);
    atomic_store(&g_arm, 0);
    if (chosen != previous) {
      atomic_store(&g_mark, atomic_load(&g_write));
    }
  } else {
    atomic_store(&g_attached, 0);
    // Stay armed until the player's own unit is wrapped. A known rate that
    // matches nothing also re-arms, so a later output can still be wrapped.
    if (atomic_load(&g_arm) || atomic_load(&g_expect_rate) >= 8000) {
      atomic_store(&g_arm, 1);
    }
  }
}

static void log_ignored(TapSlot *slot) {
  if (!slot || slot->logged) {
    return;
  }
  slot->logged = 1;
  if (!g_log) {
    g_log = os_log_create("com.colliderli.iina", "LiveCaptions");
  }
  os_log(g_log, "ignored audio callback %{public}d Hz %{public}d ch; player expects %{public}d Hz %{public}d ch",
         slot->rate, slot->channels,
         atomic_load(&g_expect_rate), atomic_load(&g_expect_channels));
}

static OSStatus wrapped_au(void *refcon,
                           AudioUnitRenderActionFlags *flags,
                           const AudioTimeStamp *timestamp,
                           UInt32 bus,
                           UInt32 frames,
                           AudioBufferList *data) {
  TapSlot *slot = refcon;
  OSStatus status = noErr;
  if (slot && slot->au_proc) {
    status = slot->au_proc(slot->au_refcon, flags, timestamp, bus, frames, data);
  }
  if (status == noErr && slot && atomic_load(&slot->accept) && atomic_load(&g_selected) == slot->index + 1) {
    g_format = slot->format;
    g_format_ready = slot->rate >= 8000;
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
  TapSlot *slot = client;
  OSStatus status = noErr;
  if (slot && slot->hal_proc) {
    status = slot->hal_proc(device, now, input, input_time, output, output_time, slot->hal_client);
  }
  if (status == noErr && slot && atomic_load(&slot->accept) && atomic_load(&g_selected) == slot->index + 1) {
    g_format = slot->format;
    g_format_ready = slot->rate >= 8000;
    ingest(output, frame_count(output));
  }
  return status;
}

typedef OSStatus (*IINAUnitGetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *);
static IINAUnitGetProperty g_get_property;

static int read_unit_format(AudioUnit unit, AudioStreamBasicDescription *out) {
  if (!out) {
    return 0;
  }
  memset(out, 0, sizeof(*out));
  if (!g_get_property) {
    g_get_property = (IINAUnitGetProperty)dlsym(RTLD_NEXT, "AudioUnitGetProperty");
  }
  if (!g_get_property) {
    return 0;
  }
  AudioUnitScope scopes[2] = { kAudioUnitScope_Input, kAudioUnitScope_Output };
  for (int i = 0; i < 2; i++) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    UInt32 size = sizeof(format);
    if (g_get_property(unit, kAudioUnitProperty_StreamFormat, scopes[i], 0, &format, &size) == noErr &&
        format.mSampleRate >= 8000 &&
        format.mChannelsPerFrame >= 1 &&
        format.mChannelsPerFrame <= 16) {
      *out = format;
      return 1;
    }
  }
  return 0;
}

static void store_slot_format(TapSlot *slot, const AudioStreamBasicDescription *format, int ok) {
  if (!slot) {
    return;
  }
  if (!ok || !format) {
    memset(&slot->format, 0, sizeof(slot->format));
    slot->rate = 0;
    slot->channels = 0;
    return;
  }
  slot->format = *format;
  slot->rate = (int)format->mSampleRate;
  slot->channels = (int)format->mChannelsPerFrame;
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
    TapSlot *slot = claim_slot();
    slot->au_proc = incoming->inputProc;
    slot->au_refcon = incoming->inputProcRefCon;
    slot->hal_proc = NULL;
    AudioStreamBasicDescription format;
    store_slot_format(slot, &format, read_unit_format(unit, &format));
    AURenderCallbackStruct wrapped = incoming[0];
    wrapped.inputProc = wrapped_au;
    wrapped.inputProcRefCon = slot;
    OSStatus status = g_real_set_property(unit, property, scope, element, &wrapped, sizeof(wrapped));
    if (status == noErr) {
      if (rate_matches(slot->rate, slot->channels)) {
        log_callback("audiounit", slot->rate, slot->channels);
      } else if (atomic_load(&g_expect_rate) >= 8000) {
        log_ignored(slot);
      }
      select_matching();
    } else {
      slot->in_use = 0;
    }
    return status;
  }
  if (!g_real_set_property) {
    return kAudioUnitErr_InvalidParameter;
  }
  return g_real_set_property(unit, property, scope, element, data, size);
}

static int read_device_format(AudioObjectID device, AudioStreamBasicDescription *out) {
  if (!out) {
    return 0;
  }
  memset(out, 0, sizeof(*out));
  UInt32 size = sizeof(*out);
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
  if (get_data && get_data(device, &address, 0, NULL, &size, out) == noErr &&
      out->mSampleRate >= 8000 &&
      out->mChannelsPerFrame >= 1 &&
      out->mChannelsPerFrame <= 16) {
    return 1;
  }
  memset(out, 0, sizeof(*out));
  return 0;
}

static OSStatus iina_AudioDeviceCreateIOProcID(AudioObjectID device,
                                               AudioDeviceIOProc proc,
                                               void *client,
                                               AudioDeviceIOProcID *out_proc) {
  if (!g_real_create_proc) {
    g_real_create_proc = (OSStatus (*)(AudioObjectID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *))dlsym(RTLD_NEXT, "AudioDeviceCreateIOProcID");
  }
  if (atomic_load(&g_arm) && proc && g_real_create_proc) {
    TapSlot *slot = claim_slot();
    slot->hal_proc = proc;
    slot->hal_client = client;
    slot->au_proc = NULL;
    AudioStreamBasicDescription format;
    store_slot_format(slot, &format, read_device_format(device, &format));
    OSStatus status = g_real_create_proc(device, wrapped_hal, slot, out_proc);
    if (status == noErr) {
      if (rate_matches(slot->rate, slot->channels)) {
        log_callback("hal", slot->rate, slot->channels);
      } else if (atomic_load(&g_expect_rate) >= 8000) {
        log_ignored(slot);
      }
      select_matching();
    } else {
      slot->in_use = 0;
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

void iina_caption_tap_expect(int rate, int channels) {
  if (rate == atomic_load(&g_expect_rate) && channels == atomic_load(&g_expect_channels) && atomic_load(&g_selected) != 0) {
    return;
  }
  atomic_store(&g_expect_rate, rate);
  atomic_store(&g_expect_channels, channels);
  select_matching();
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
