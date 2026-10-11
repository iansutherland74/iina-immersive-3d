// Stable C API around whisper.cpp. The Swift app dlopens libiina_whisper.dylib
// and never includes whisper.h, so a whisper.cpp upgrade stays inside this file.

#include "whisper.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static struct whisper_context * g_ctx = NULL;
static char g_error[512];
static volatile int g_abort = 0;
static volatile int g_epoch = 0;
static int g_segments = -1;

static bool iina_abort(void * userdata) {
  (void)userdata;
  return g_abort != 0;
}

static void set_error(const char * message) {
  snprintf(g_error, sizeof(g_error), "%s", message ? message : "unknown error");
}

__attribute__((visibility("default")))
void iina_whisper_set_abort(int flag) {
  if (flag) {
    g_epoch += 1;
    g_abort = 1;
  } else {
    g_abort = 0;
  }
}

__attribute__((visibility("default")))
int iina_whisper_last_segments(void) {
  return g_segments;
}

__attribute__((visibility("default")))
const char * iina_whisper_last_error(void) {
  return g_error;
}

__attribute__((visibility("default")))
const char * iina_whisper_backend(void) {
#if IINA_WHISPER_METAL && IINA_WHISPER_COREML
  return "metal+coreml";
#elif IINA_WHISPER_METAL
  return "metal";
#else
  return "cpu";
#endif
}

__attribute__((visibility("default")))
const char * iina_whisper_system_info(void) {
  const char * info = whisper_print_system_info();
  return info ? info : "";
}

__attribute__((visibility("default")))
void iina_whisper_unload(void) {
  if (g_ctx) {
    whisper_free(g_ctx);
    g_ctx = NULL;
  }
}

__attribute__((visibility("default")))
int iina_whisper_load(const char * path, int use_gpu) {
  if (!path || !path[0]) {
    set_error("missing model path");
    return 1;
  }
  iina_whisper_unload();
  g_abort = 0;
  struct whisper_context_params cparams = whisper_context_default_params();
  cparams.use_gpu = use_gpu ? true : false;
  g_ctx = whisper_init_from_file_with_params(path, cparams);
  if (!g_ctx && use_gpu) {
    cparams.use_gpu = false;
    g_ctx = whisper_init_from_file_with_params(path, cparams);
  }
  if (!g_ctx) {
    set_error("whisper_init_from_file_with_params failed");
    return 2;
  }
  g_error[0] = 0;
  return 0;
}

__attribute__((visibility("default")))
int iina_whisper_transcribe(
    const float * samples,
    int n_samples,
    const char * language,
    int translate,
    int beam,
    int n_threads,
    char ** out_text) {
  if (out_text) {
    *out_text = NULL;
  }
  if (!g_ctx) {
    set_error("model is not loaded");
    return 1;
  }
  if (!samples || n_samples <= 0 || !out_text) {
    set_error("empty audio");
    return 3;
  }

  enum whisper_sampling_strategy strategy = beam > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY;
  struct whisper_full_params params = whisper_full_default_params(strategy);
  params.n_threads = n_threads > 0 ? n_threads : 4;
  params.translate = translate ? true : false;
  params.no_context = true;
  params.single_segment = false;
  params.no_timestamps = false;
  params.print_special = false;
  params.print_progress = false;
  params.print_realtime = false;
  params.print_timestamps = false;
  params.suppress_blank = true;
  params.suppress_nst = true;
  params.temperature = 0.0f;
  params.initial_prompt = NULL;
  // Sung lyrics often score as non-speech or as low-probability tokens, so the
  // stock 0.6 / -1.0 cutoffs return an empty result for a music video. The
  // caller already drops near-silent chunks by RMS. "auto" still detects the
  // language and then transcribes; detect_language must stay false because
  // that flag returns before any words are decoded.
  params.no_speech_thold = 0.95f;
  params.logprob_thold = -1.5f;
  params.language = (language && language[0] && strcmp(language, "auto") != 0) ? language : "auto";
  params.detect_language = false;
  if (beam > 1) {
    params.beam_search.beam_size = beam;
  } else {
    params.greedy.best_of = 1;
  }
  params.abort_callback = iina_abort;
  params.abort_callback_user_data = NULL;

  g_segments = -1;
  int epoch = g_epoch;
  if (g_abort) {
    g_segments = 0;
    set_error("aborted");
    return 4;
  }

  int rc = whisper_full(g_ctx, params, samples, n_samples);
  int stopped = g_abort || g_epoch != epoch;
  int nseg = 0;
  if (rc == 0) {
    nseg = whisper_full_n_segments(g_ctx);
  }
  g_segments = nseg;
  // A new file can set the abort flag while this chunk is finishing. Keep the
  // text when segments were produced; the caller drops it if that file is gone.
  // An abort with no segments must not stick and cancel the next chunk.
  if (stopped && nseg <= 0) {
    set_error("aborted");
    return 4;
  }
  if (rc != 0) {
    snprintf(g_error, sizeof(g_error), "whisper_full returned %d", rc);
    return rc;
  }

  size_t cap = 1024;
  char * buf = (char *)malloc(cap);
  if (!buf) {
    set_error("out of memory");
    return 5;
  }
  buf[0] = 0;
  for (int i = 0; i < nseg; i++) {
    const char * seg = whisper_full_get_segment_text(g_ctx, i);
    if (!seg || !seg[0]) {
      continue;
    }
    long long t0 = (long long)whisper_full_get_segment_t0(g_ctx, i);
    long long t1 = (long long)whisper_full_get_segment_t1(g_ctx, i);
    if (t1 < t0) {
      t1 = t0;
    }
    char line[1400];
    size_t used = 0;
    int head = snprintf(line, sizeof(line), "%lld\t%lld\t", t0, t1);
    if (head < 0 || (size_t)head >= sizeof(line) - 2) {
      continue;
    }
    used = (size_t)head;
    for (const char * p = seg; *p && used + 2 < sizeof(line); p++) {
      char ch = *p;
      if (ch == '\n' || ch == '\r' || ch == '\t') {
        ch = ' ';
      }
      line[used++] = ch;
    }
    line[used++] = '\n';
    line[used] = 0;
    size_t have = strlen(buf);
    if (have + used + 1 > 8192) {
      break;
    }
    if (have + used + 1 > cap) {
      size_t next = cap * 2;
      while (next < have + used + 1) {
        next *= 2;
      }
      char * grown = (char *)realloc(buf, next);
      if (!grown) {
        free(buf);
        set_error("out of memory");
        return 5;
      }
      buf = grown;
      cap = next;
    }
    memcpy(buf + have, line, used + 1);
  }
  *out_text = buf;
  g_error[0] = 0;
  return 0;
}

__attribute__((visibility("default")))
void iina_whisper_free_text(char * text) {
  free(text);
}
