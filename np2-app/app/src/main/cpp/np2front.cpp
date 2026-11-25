// libretro コア（NP2kai）を動かす最小の「枠」（フロントエンド）。
// 画面は ANativeWindow へ、音は AAudio へ、入力は JNI 経由で受け取る。
#include <jni.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <aaudio/AAudio.h>
#include <dlfcn.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "libretro.h"

#define TAG "np2front"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace {

// ---- コアの関数 ----
void *g_core = nullptr;
void (*p_set_environment)(retro_environment_t);
void (*p_set_video_refresh)(retro_video_refresh_t);
void (*p_set_audio_sample)(retro_audio_sample_t);
void (*p_set_audio_sample_batch)(retro_audio_sample_batch_t);
void (*p_set_input_poll)(retro_input_poll_t);
void (*p_set_input_state)(retro_input_state_t);
void (*p_init)(void);
void (*p_get_system_av_info)(struct retro_system_av_info *);
bool (*p_load_game)(const struct retro_game_info *);
void (*p_unload_game)(void);
void (*p_run)(void);
void (*p_reset)(void);
size_t (*p_serialize_size)(void);
bool (*p_serialize)(void *, size_t);
bool (*p_unserialize)(const void *, size_t);
std::mutex g_coreMu;  // p_run と状態の保存・読み込みが同時に動かないようにする

// ---- 状態 ----
std::string g_sys, g_save;
std::map<std::string, std::string> g_opts;  // コアの設定（既定値）
retro_pixel_format g_fmt = RETRO_PIXEL_FORMAT_0RGB1555;
retro_disk_control_callback g_disk;
bool g_hasDisk = false;

ANativeWindow *g_win = nullptr;
std::mutex g_winMu;
int g_winW = 0, g_winH = 0;

double g_fps = 56.4;
int g_rate = 44100;

std::atomic<bool> g_running{false};
std::atomic<bool> g_paused{false};
std::atomic<int> g_ff{1};  // 早送り倍率（1=通常, 99=最大）
std::atomic<bool> g_drawVideo{true};
std::atomic<bool> g_diskTurbo{false};  // FDDアクセス中は全力で回す
std::atomic<bool> g_lightDraw{false};  // 描画を2フレームに1回に間引く
volatile int *g_fddBusy = nullptr;     // コア内 fddmtr.busy（先頭メンバ）への参照
unsigned g_frameNo = 0;
std::atomic<bool> g_resetReq{false};
pthread_t g_thread;
bool g_threadStarted = false;

// ---- 入力 ----
std::atomic<int> g_joy{0};
std::atomic<uint8_t> g_keys[512];
std::atomic<int> g_mdx{0}, g_mdy{0};
std::atomic<int> g_mbtn{0};
int g_curdx = 0, g_curdy = 0;

// ---- 音 ----
const uint32_t RING = 1 << 15;  // フレーム数
int16_t g_ring[RING * 2];
std::atomic<uint32_t> g_wr{0}, g_rd{0};
AAudioStream *g_stream = nullptr;

double nowSec() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

// ---- コールバック ----
void RETRO_CALLCONV logCb(enum retro_log_level level, const char *fmt, ...) {
  int pr = ANDROID_LOG_INFO;
  switch (level) {
    case RETRO_LOG_DEBUG: pr = ANDROID_LOG_DEBUG; break;
    case RETRO_LOG_WARN: pr = ANDROID_LOG_WARN; break;
    case RETRO_LOG_ERROR: pr = ANDROID_LOG_ERROR; break;
    default: break;
  }
  va_list ap;
  va_start(ap, fmt);
  __android_log_vprint(pr, "np2core", fmt, ap);
  va_end(ap);
}

// "説明; 値1|値2|..." の先頭の値を既定値として覚える
void parseVariables(const struct retro_variable *v) {
  for (; v && v->key; v++) {
    if (!v->value) continue;
    const char *semi = strchr(v->value, ';');
    if (!semi) continue;
    semi++;
    while (*semi == ' ') semi++;
    std::string val(semi);
    size_t bar = val.find('|');
    if (bar != std::string::npos) val = val.substr(0, bar);
    if (!g_opts.count(v->key)) g_opts[v->key] = val;
  }
}

bool RETRO_CALLCONV envCb(unsigned cmd, void *data) {
  switch (cmd) {
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
      *(bool *)data = true;
      return true;
    case RETRO_ENVIRONMENT_SET_ROTATION:
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK:
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
      return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE: {
      const retro_message *m = (const retro_message *)data;
      LOGI("core message: %s", m && m->msg ? m->msg : "");
      return true;
    }
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
      *(const char **)data = g_sys.c_str();
      return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
      *(const char **)data = g_save.c_str();
      return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      retro_pixel_format f = *(retro_pixel_format *)data;
      if (f == RETRO_PIXEL_FORMAT_0RGB1555 || f == RETRO_PIXEL_FORMAT_XRGB8888 ||
          f == RETRO_PIXEL_FORMAT_RGB565) {
        g_fmt = f;
        return true;
      }
      return false;
    }
    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
      memcpy(&g_disk, data, sizeof(g_disk));
      g_hasDisk = true;
      return true;
    case RETRO_ENVIRONMENT_SET_VARIABLES:
      parseVariables((const struct retro_variable *)data);
      return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      retro_variable *v = (retro_variable *)data;
      auto it = g_opts.find(v->key ? v->key : "");
      if (it == g_opts.end()) return false;
      v->value = it->second.c_str();
      return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
      *(bool *)data = false;
      return true;
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
      *(unsigned *)data = 0;
      return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
      ((retro_log_callback *)data)->log = logCb;
      return true;
    default:
      return false;
  }
}

inline uint32_t px565(uint16_t p) {
  uint32_t r = (p >> 11) & 31, g = (p >> 5) & 63, b = p & 31;
  r = (r << 3) | (r >> 2);
  g = (g << 2) | (g >> 4);
  b = (b << 3) | (b >> 2);
  return 0xFF000000u | (b << 16) | (g << 8) | r;
}
inline uint32_t px1555(uint16_t p) {
  uint32_t r = (p >> 10) & 31, g = (p >> 5) & 31, b = p & 31;
  r = (r << 3) | (r >> 2);
  g = (g << 3) | (g >> 2);
  b = (b << 3) | (b >> 2);
  return 0xFF000000u | (b << 16) | (g << 8) | r;
}

void RETRO_CALLCONV videoCb(const void *data, unsigned w, unsigned h, size_t pitch) {
  if (!data || w == 0 || h == 0) return;
  if (!g_drawVideo.load(std::memory_order_relaxed)) return;  // 早送り中は間引く
  if (g_lightDraw.load(std::memory_order_relaxed) && (g_frameNo++ & 1)) return;
  std::lock_guard<std::mutex> lk(g_winMu);
  if (!g_win) return;
  if ((int)w != g_winW || (int)h != g_winH) {
    ANativeWindow_setBuffersGeometry(g_win, w, h, WINDOW_FORMAT_RGBA_8888);
    g_winW = w;
    g_winH = h;
  }
  ANativeWindow_Buffer b;
  if (ANativeWindow_lock(g_win, &b, nullptr) != 0) return;
  uint32_t *dst = (uint32_t *)b.bits;
  unsigned rows = h < (unsigned)b.height ? h : (unsigned)b.height;
  unsigned cols = w < (unsigned)b.width ? w : (unsigned)b.width;
  for (unsigned y = 0; y < rows; y++) {
    const uint8_t *src = (const uint8_t *)data + y * pitch;
    uint32_t *d = dst + (size_t)y * b.stride;
    if (g_fmt == RETRO_PIXEL_FORMAT_XRGB8888) {
      const uint32_t *s = (const uint32_t *)src;
      for (unsigned x = 0; x < cols; x++) {
        uint32_t p = s[x];
        d[x] = 0xFF000000u | ((p & 0xFF) << 16) | (p & 0xFF00) | ((p >> 16) & 0xFF);
      }
    } else if (g_fmt == RETRO_PIXEL_FORMAT_RGB565) {
      const uint16_t *s = (const uint16_t *)src;
      for (unsigned x = 0; x < cols; x++) d[x] = px565(s[x]);
    } else {
      const uint16_t *s = (const uint16_t *)src;
      for (unsigned x = 0; x < cols; x++) d[x] = px1555(s[x]);
    }
  }
  ANativeWindow_unlockAndPost(g_win);
}

size_t RETRO_CALLCONV audioBatchCb(const int16_t *d, size_t frames) {
  uint32_t wr = g_wr.load(std::memory_order_relaxed);
  uint32_t rd = g_rd.load(std::memory_order_acquire);
  uint32_t cap = g_rate / 6;  // 遅れが大きくなりすぎないように（約170ms）
  if (cap > RING) cap = RING;
  for (size_t i = 0; i < frames; i++) {
    if (wr - rd >= cap) break;
    g_ring[(wr & (RING - 1)) * 2] = d[i * 2];
    g_ring[(wr & (RING - 1)) * 2 + 1] = d[i * 2 + 1];
    wr++;
  }
  g_wr.store(wr, std::memory_order_release);
  return frames;
}

void RETRO_CALLCONV audioSampleCb(int16_t l, int16_t r) {
  int16_t s[2] = {l, r};
  audioBatchCb(s, 1);
}

void RETRO_CALLCONV pollCb() {
  g_curdx = g_mdx.exchange(0);
  g_curdy = g_mdy.exchange(0);
}

int16_t RETRO_CALLCONV stateCb(unsigned port, unsigned device, unsigned index, unsigned id) {
  if (port != 0) return 0;
  switch (device) {
    case RETRO_DEVICE_JOYPAD:
      if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)(g_joy.load() & 0xFFFF);
      return id < 16 ? (g_joy.load() >> id) & 1 : 0;
    case RETRO_DEVICE_KEYBOARD:
      return id < 512 ? g_keys[id].load() : 0;
    case RETRO_DEVICE_MOUSE:
      switch (id) {
        case RETRO_DEVICE_ID_MOUSE_X: return (int16_t)g_curdx;
        case RETRO_DEVICE_ID_MOUSE_Y: return (int16_t)g_curdy;
        case RETRO_DEVICE_ID_MOUSE_LEFT: return g_mbtn.load() & 1;
        case RETRO_DEVICE_ID_MOUSE_RIGHT: return (g_mbtn.load() >> 1) & 1;
        case RETRO_DEVICE_ID_MOUSE_MIDDLE: return (g_mbtn.load() >> 2) & 1;
        default: return 0;
      }
    default:
      return 0;
  }
}

// ---- 音の出力 ----
aaudio_data_callback_result_t aaCb(AAudioStream *, void *, void *out, int32_t n) {
  int16_t *o = (int16_t *)out;
  uint32_t rd = g_rd.load(std::memory_order_relaxed);
  uint32_t wr = g_wr.load(std::memory_order_acquire);
  for (int32_t i = 0; i < n; i++) {
    if (rd != wr) {
      o[i * 2] = g_ring[(rd & (RING - 1)) * 2];
      o[i * 2 + 1] = g_ring[(rd & (RING - 1)) * 2 + 1];
      rd++;
    } else {
      o[i * 2] = 0;
      o[i * 2 + 1] = 0;
    }
  }
  g_rd.store(rd, std::memory_order_release);
  return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

void startAudio() {
  AAudioStreamBuilder *b = nullptr;
  if (AAudio_createStreamBuilder(&b) != AAUDIO_OK) {
    LOGE("AAudio builder failed");
    return;
  }
  AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
  AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
  AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
  AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
  AAudioStreamBuilder_setChannelCount(b, 2);
  AAudioStreamBuilder_setSampleRate(b, g_rate);
  AAudioStreamBuilder_setDataCallback(b, aaCb, nullptr);
  aaudio_result_t r = AAudioStreamBuilder_openStream(b, &g_stream);
  AAudioStreamBuilder_delete(b);
  if (r != AAUDIO_OK) {
    LOGE("AAudio open failed: %s", AAudio_convertResultToText(r));
    g_stream = nullptr;
    return;
  }
  AAudioStream_requestStart(g_stream);
}

void stopAudio() {
  if (g_stream) {
    AAudioStream_requestStop(g_stream);
    AAudioStream_close(g_stream);
    g_stream = nullptr;
  }
}

// ---- 実行スレッド ----
void *emuMain(void *) {
  double next = nowSec();
  while (g_running.load()) {
    if (g_paused.load()) {
      usleep(30000);
      next = nowSec();
      continue;
    }
    const int ff = g_ff.load();
    const bool turbo = g_diskTurbo.load() && g_fddBusy && *g_fddBusy != 0;
    const int n = ff >= 99 ? 8 : (ff >= 2 ? ff : (turbo ? 8 : 1));
    for (int i = 0; i < n; i++) {
      g_drawVideo.store(i == n - 1, std::memory_order_relaxed);  // 描画は最後の1フレームだけ
      std::lock_guard<std::mutex> lk(g_coreMu);
      if (g_resetReq.exchange(false) && p_reset) p_reset();
      p_run();
    }
    g_drawVideo.store(true, std::memory_order_relaxed);
    if (ff >= 99 || (turbo && ff < 2)) {
      next = nowSec();
      continue;
    }
    next += n / g_fps;
    double now = nowSec();
    if (next > now) {
      usleep((useconds_t)((next - now) * 1e6));
    } else if (now - next > 0.2) {
      next = now;
    }
  }
  return nullptr;
}

std::string jstr(JNIEnv *env, jstring s) {
  if (!s) return "";
  const char *c = env->GetStringUTFChars(s, nullptr);
  std::string r(c ? c : "");
  if (c) env->ReleaseStringUTFChars(s, c);
  return r;
}

}  // namespace

extern "C" {

JNIEXPORT jboolean JNICALL Java_com_chako_np2_Native_nInit(JNIEnv *env, jclass, jstring core,
                                                           jstring sys, jstring save) {
  g_sys = jstr(env, sys);
  g_save = jstr(env, save);
  std::string path = jstr(env, core);
  g_core = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!g_core) {
    LOGE("dlopen failed: %s", dlerror());
    return JNI_FALSE;
  }
#define SYM(n)                                                    \
  *(void **)&p_##n = dlsym(g_core, "retro_" #n);                  \
  if (!p_##n) {                                                   \
    LOGE("symbol missing: retro_%s", #n);                         \
    return JNI_FALSE;                                             \
  }
  SYM(set_environment)
  SYM(set_video_refresh)
  SYM(set_audio_sample)
  SYM(set_audio_sample_batch)
  SYM(set_input_poll)
  SYM(set_input_state)
  SYM(init)
  SYM(get_system_av_info)
  SYM(load_game)
  SYM(unload_game)
  SYM(run)
  SYM(reset)
  SYM(serialize_size)
  SYM(serialize)
  SYM(unserialize)
#undef SYM
  g_fddBusy = (volatile int *)dlsym(g_core, "fddmtr");
  LOGI("fddmtr symbol: %s", g_fddBusy ? "found" : "missing (disk turbo disabled)");
  p_set_environment(envCb);
  p_init();
  p_set_video_refresh(videoCb);
  p_set_audio_sample(audioSampleCb);
  p_set_audio_sample_batch(audioBatchCb);
  p_set_input_poll(pollCb);
  p_set_input_state(stateCb);
  LOGI("core initialized");
  return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL Java_com_chako_np2_Native_nLoad(JNIEnv *env, jclass, jstring jpath) {
  if (!g_core) return JNI_FALSE;
  std::string path = jstr(env, jpath);
  retro_game_info gi;
  memset(&gi, 0, sizeof(gi));
  gi.path = path.c_str();
  if (!p_load_game(&gi)) {
    LOGE("retro_load_game failed: %s", path.c_str());
    return JNI_FALSE;
  }
  retro_system_av_info av;
  memset(&av, 0, sizeof(av));
  p_get_system_av_info(&av);
  if (av.timing.fps > 1.0) g_fps = av.timing.fps;
  if (av.timing.sample_rate > 8000.0) g_rate = (int)av.timing.sample_rate;
  LOGI("loaded: fps=%.2f rate=%d size=%ux%u", g_fps, g_rate, av.geometry.base_width,
       av.geometry.base_height);
  startAudio();
  return JNI_TRUE;
}

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nStart(JNIEnv *, jclass) {
  if (g_threadStarted || !g_core) return;
  g_running = true;
  g_paused = false;
  g_threadStarted = pthread_create(&g_thread, nullptr, emuMain, nullptr) == 0;
}

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nPause(JNIEnv *, jclass, jboolean p) {
  g_paused = p;
}

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nFastForward(JNIEnv *, jclass, jint f) {
  g_ff = f;
}

JNIEXPORT jboolean JNICALL Java_com_chako_np2_Native_nSaveState(JNIEnv *env, jclass, jstring jpath) {
  if (!g_core) return JNI_FALSE;
  std::string path = jstr(env, jpath);
  std::lock_guard<std::mutex> lk(g_coreMu);
  size_t n = p_serialize_size();
  if (n == 0) return JNI_FALSE;
  std::vector<unsigned char> buf(n);
  if (!p_serialize(buf.data(), n)) return JNI_FALSE;
  std::string tmp = path + ".tmp";
  FILE *f = fopen(tmp.c_str(), "wb");
  if (!f) return JNI_FALSE;
  bool ok = fwrite(buf.data(), 1, n, f) == n;
  ok = (fclose(f) == 0) && ok;
  if (!ok) {
    remove(tmp.c_str());
    return JNI_FALSE;
  }
  return rename(tmp.c_str(), path.c_str()) == 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL Java_com_chako_np2_Native_nLoadState(JNIEnv *env, jclass, jstring jpath) {
  if (!g_core) return JNI_FALSE;
  std::string path = jstr(env, jpath);
  FILE *f = fopen(path.c_str(), "rb");
  if (!f) return JNI_FALSE;
  std::vector<unsigned char> buf;
  unsigned char tmp[65536];
  size_t got;
  while ((got = fread(tmp, 1, sizeof(tmp), f)) > 0) buf.insert(buf.end(), tmp, tmp + got);
  fclose(f);
  if (buf.empty()) return JNI_FALSE;
  std::lock_guard<std::mutex> lk(g_coreMu);
  return p_unserialize(buf.data(), buf.size()) ? JNI_TRUE : JNI_FALSE;
}

// フロッピーの差し替え。path が空なら取り出すだけ。コア内の diskdrv_setfddex を直接呼ぶ
JNIEXPORT jboolean JNICALL Java_com_chako_np2_Native_nSetFdd(JNIEnv *env, jclass, jint drive, jstring jpath) {
  if (!g_core) return JNI_FALSE;
  typedef void (*SetFddFn)(unsigned char, const char *, unsigned int, int);
  SetFddFn fn = (SetFddFn)dlsym(g_core, "diskdrv_setfddex");
  if (!fn) { LOGE("symbol missing: diskdrv_setfddex"); return JNI_FALSE; }
  std::string path = jstr(env, jpath);
  std::lock_guard<std::mutex> lk(g_coreMu);
  fn((unsigned char)drive, path.empty() ? nullptr : path.c_str(), 0, 0);
  return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL Java_com_chako_np2_Native_nSetTurbo(JNIEnv *, jclass, jboolean disk, jboolean light) {
  g_diskTurbo = disk;
  g_lightDraw = light;
  return g_fddBusy != nullptr ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nReset(JNIEnv *, jclass) { g_resetReq = true; }

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nStop(JNIEnv *, jclass) {
  g_running = false;
  if (g_threadStarted) {
    pthread_join(g_thread, nullptr);
    g_threadStarted = false;
  }
  stopAudio();
  if (g_core && p_unload_game) p_unload_game();
}

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nSetSurface(JNIEnv *env, jclass, jobject surface) {
  std::lock_guard<std::mutex> lk(g_winMu);
  if (g_win) {
    ANativeWindow_release(g_win);
    g_win = nullptr;
  }
  g_winW = g_winH = 0;
  if (surface) g_win = ANativeWindow_fromSurface(env, surface);
}

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nKey(JNIEnv *, jclass, jint code, jboolean down) {
  if (code >= 0 && code < 512) g_keys[code] = down ? 1 : 0;
}

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nJoy(JNIEnv *, jclass, jint id, jboolean down) {
  if (id < 0 || id > 15) return;
  if (down) g_joy.fetch_or(1 << id);
  else g_joy.fetch_and(~(1 << id));
}

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nMouseMove(JNIEnv *, jclass, jint dx, jint dy) {
  g_mdx.fetch_add(dx);
  g_mdy.fetch_add(dy);
}

JNIEXPORT void JNICALL Java_com_chako_np2_Native_nMouseBtn(JNIEnv *, jclass, jint btn,
                                                           jboolean down) {
  if (btn < 0 || btn > 2) return;
  if (down) g_mbtn.fetch_or(1 << btn);
  else g_mbtn.fetch_and(~(1 << btn));
}

}  // extern "C"
