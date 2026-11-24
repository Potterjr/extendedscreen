#include "video_decoder_plugin.h"

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wrl/client.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <execution>
#include <memory>
#include <mutex>
#include <numeric>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "annexb.h"

using Microsoft::WRL::ComPtr;

namespace {

// Posted to the top-level window so callbacks reach Dart on the platform
// thread (channel calls from any other thread are not allowed).
constexpr UINT kWmDecoderEvent = WM_APP + 0x51;

// About 100 ms of frames at the stream rate, never fewer than this
// (VideoDecoderPlugin.kt's MIN_QUEUED_FRAMES).
constexpr size_t kMinQueuedFrames = 6;

// Keyframe requests for dropped frames: at most this often, backing off to
// the max while the decoder takes nothing (VideoDecoderPlugin.kt).
constexpr int64_t kIdrMinIntervalMs = 750;
constexpr int64_t kIdrMaxIntervalMs = 8000;

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void Log(const std::string& line) {
  OutputDebugStringA(("[ExtendedScreen] decoder: " + line + "\n").c_str());
}

std::string HrText(const char* what, HRESULT hr) {
  char buf[96];
  snprintf(buf, sizeof(buf), "%s failed (0x%08lX)", what,
           static_cast<unsigned long>(hr));
  return buf;
}

int IntArg(const flutter::EncodableMap& m, const char* key, int fallback) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return fallback;
  if (auto v = std::get_if<int32_t>(&it->second)) return *v;
  if (auto v = std::get_if<int64_t>(&it->second)) return static_cast<int>(*v);
  return fallback;
}

std::string StringArg(const flutter::EncodableMap& m, const char* key,
                      const std::string& fallback) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return fallback;
  if (auto v = std::get_if<std::string>(&it->second)) return *v;
  return fallback;
}

// The decoded picture the texture shows: the worker fills the back buffer and
// publishes it; the raster thread copies the front one under the lock, which
// the pixel buffer's release callback lets go of.
class FrameStore {
 public:
  uint8_t* Back(size_t w, size_t h) {
    back_.resize(w * h * 4);
    back_w_ = w;
    back_h_ = h;
    return back_.data();
  }

  void Publish() {
    std::lock_guard<std::mutex> lock(mu_);
    front_.swap(back_);
    front_w_ = back_w_;
    front_h_ = back_h_;
  }

  const FlutterDesktopPixelBuffer* Lock() {
    mu_.lock();
    if (front_.empty()) {
      mu_.unlock();
      return nullptr;
    }
    pixels_.buffer = front_.data();
    pixels_.width = front_w_;
    pixels_.height = front_h_;
    pixels_.release_context = this;
    pixels_.release_callback = [](void* context) {
      static_cast<FrameStore*>(context)->mu_.unlock();
    };
    return &pixels_;
  }

 private:
  std::mutex mu_;
  std::vector<uint8_t> front_, back_;
  size_t front_w_ = 0, front_h_ = 0, back_w_ = 0, back_h_ = 0;
  FlutterDesktopPixelBuffer pixels_{};
};

// A texture and its store, kept alive until the engine has let the texture go.
struct TextureSlot {
  FrameStore store;
  std::unique_ptr<flutter::TextureVariant> texture;
  int64_t id = -1;
};

// NV12 (BT.709, video range, as the Mac encodes: ScreenCaptureKit's 420v) to
// RGBA, rows in parallel.
void Nv12ToRgba(const uint8_t* y_plane, const uint8_t* uv_plane, LONG pitch,
                size_t x0, size_t y0, size_t w, size_t h, uint8_t* out) {
  std::vector<size_t> pairs(h / 2);
  std::iota(pairs.begin(), pairs.end(), size_t{0});
  auto clamp = [](int v) -> uint8_t {
    return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
  };
  std::for_each(std::execution::par, pairs.begin(), pairs.end(), [&](size_t p) {
    const size_t sy = (y0 / 2) + p;
    const uint8_t* uv = uv_plane + sy * pitch + (x0 & ~size_t{1});
    for (size_t r = 0; r < 2; r++) {
      const size_t row = p * 2 + r;
      const uint8_t* yr = y_plane + (y0 + row) * pitch + x0;
      uint8_t* o = out + row * w * 4;
      for (size_t x = 0; x < w; x++) {
        const int c = 298 * (static_cast<int>(yr[x]) - 16);
        const int u = static_cast<int>(uv[(x & ~size_t{1})]) - 128;
        const int v = static_cast<int>(uv[(x & ~size_t{1}) + 1]) - 128;
        o[0] = clamp((c + 459 * v + 128) >> 8);
        o[1] = clamp((c - 55 * u - 136 * v + 128) >> 8);
        o[2] = clamp((c + 541 * u + 128) >> 8);
        o[3] = 255;
        o += 4;
      }
    }
  });
}

class VideoDecoderPlugin : public flutter::Plugin {
 public:
  explicit VideoDecoderPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), textures_(registrar->texture_registrar()) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(), "extended_screen/video_decoder",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      HandleMethod(call, std::move(result));
    });
    registrar->messenger()->SetMessageHandler(
        "extended_screen/nal_feed",
        [this](const uint8_t* message, size_t size,
               flutter::BinaryReply reply) {
          if (message != nullptr && size > 0) Feed(message, size);
          reply(nullptr, 0);
        });
    window_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
          return HandleWindowMessage(hwnd, message, wparam, lparam);
        });
  }

  ~VideoDecoderPlugin() override {
    Stop();
    registrar_->messenger()->SetMessageHandler("extended_screen/nal_feed",
                                               nullptr);
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }

 private:
  // ─── Platform thread ──────────────────────────────────────────────────────

  void HandleMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto& name = call.method_name();
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    flutter::EncodableMap empty;
    const auto& m = args ? *args : empty;
    if (name == "initialize") {
      const int fps = IntArg(m, "fps", 60);
      const bool hevc = StringArg(m, "codec", "h264") == "h265";
      fps_.store(fps > 0 ? fps : 60);
      if (slot_) {
        // As on Android: a configured decoder only takes the new rate; the
        // caller disposes first to change codec.
        result->Success(flutter::EncodableValue(slot_->id));
        return;
      }
      Start(IntArg(m, "width", 0), IntArg(m, "height", 0), hevc);
      result->Success(flutter::EncodableValue(slot_->id));
    } else if (name == "setRefreshRate") {
      const int fps = IntArg(m, "fps", fps_.load());
      if (fps > 0) fps_.store(fps);
      result->Success();
    } else if (name == "requestIdr") {
      channel_->InvokeMethod("onRequestIdr", nullptr);
      result->Success();
    } else if (name == "dispose") {
      Stop();
      result->Success();
    } else if (name == "getDropCount") {
      result->Success(flutter::EncodableValue(
          static_cast<int32_t>(dropped_.exchange(0))));
    } else if (name == "getMaxRefreshRate") {
      result->Success(flutter::EncodableValue(MaxRefreshRate()));
    } else {
      result->NotImplemented();
    }
  }

  int32_t MaxRefreshRate() {
    HWND view = registrar_->GetView() ? registrar_->GetView()->GetNativeWindow()
                                      : nullptr;
    HMONITOR monitor = MonitorFromWindow(view, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFOEXW info{};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor, &info)) return 60;
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    if (!EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode)) {
      return 60;
    }
    const DWORD hz = mode.dmDisplayFrequency;
    return (hz >= 24 && hz <= 500) ? static_cast<int32_t>(hz) : 60;
  }

  void Start(int width, int height, bool hevc) {
    hevc_ = hevc;
    hint_w_ = width;
    hint_h_ = height;
    slot_ = std::make_shared<TextureSlot>();
    TextureSlot* raw = slot_.get();
    slot_->texture = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture([raw](size_t, size_t) {
          return raw->store.Lock();
        }));
    slot_->id = textures_->RegisterTexture(slot_->texture.get());
    {
      std::lock_guard<std::mutex> lock(queue_mu_);
      queue_.clear();
      stop_ = false;
      awaiting_keyframe_ = true;
      idr_retry_ms_ = kIdrMinIntervalMs;
      last_idr_ms_ = 0;
    }
    worker_ = std::thread([this, slot = slot_] { Worker(slot); });
    Log(std::string("started ") + (hevc ? "h265" : "h264"));
  }

  void Stop() {
    {
      std::lock_guard<std::mutex> lock(queue_mu_);
      stop_ = true;
      queue_.clear();
    }
    queue_cv_.notify_all();
    if (worker_.joinable()) worker_.join();
    if (slot_) {
      // The slot outlives the engine's last use of the texture.
      auto slot = slot_;
      textures_->UnregisterTexture(slot->id, [slot]() {});
      slot_.reset();
    }
  }

  // An access unit from Dart. Waits for a keyframe when it must, and keeps
  // about 100 ms of frames; past that resumes from a keyframe instead of
  // dropping one from the middle of a GOP (VideoDecoderPlugin.kt feedNal and
  // dropForOverflow).
  void Feed(const uint8_t* data, size_t size) {
    std::unique_lock<std::mutex> lock(queue_mu_);
    if (!slot_ || stop_) return;
    const bool key = IsKeyframeAccessUnit(data, size, hevc_);
    if (decoder_failed_) {
      dropped_++;
      return;
    }
    if (awaiting_keyframe_) {
      if (!key) {
        dropped_++;
        RequestIdrThrottledLocked();
        return;
      }
      awaiting_keyframe_ = false;
    }
    std::vector<uint8_t> au(data, data + size);
    if (queue_.size() < QueueCap()) {
      queue_.push_back(std::move(au));
    } else if (key) {
      DropQueuedLocked(queue_.size());
      queue_.push_back(std::move(au));
    } else {
      const int newest = NewestQueuedKeyframeLocked();
      if (newest > 0) {
        DropQueuedLocked(static_cast<size_t>(newest));
        queue_.push_back(std::move(au));
      } else {
        DropQueuedLocked(queue_.size());
        dropped_++;  // the incoming frame
        awaiting_keyframe_ = true;
        RequestIdrThrottledLocked();
      }
    }
    lock.unlock();
    queue_cv_.notify_one();
  }

  size_t QueueCap() const {
    return std::max(kMinQueuedFrames, static_cast<size_t>(fps_.load() / 10));
  }

  int NewestQueuedKeyframeLocked() const {
    int newest = -1;
    for (size_t i = 0; i < queue_.size(); i++) {
      if (IsKeyframeAccessUnit(queue_[i].data(), queue_[i].size(), hevc_)) {
        newest = static_cast<int>(i);
      }
    }
    return newest;
  }

  void DropQueuedLocked(size_t count) {
    for (size_t i = 0; i < count && !queue_.empty(); i++) queue_.pop_front();
    dropped_ += static_cast<int>(count);
  }

  // A new or flushed decoder can only start at a keyframe: keep the queue
  // from its newest keyframe on, else drop it all and wait for the next one.
  void RestartInputFromKeyframeLocked() {
    const int newest = NewestQueuedKeyframeLocked();
    if (newest >= 0) {
      DropQueuedLocked(static_cast<size_t>(newest));
    } else {
      DropQueuedLocked(queue_.size());
      awaiting_keyframe_ = true;
    }
  }

  void RequestIdrLocked() {
    last_idr_ms_ = NowMs();
    taken_since_idr_ = false;
    PostEvent([this] { idr_pending_ = true; });
  }

  void RequestIdrThrottledLocked() {
    if (NowMs() - last_idr_ms_ < idr_retry_ms_) return;
    // A decoder that has taken nothing since the last request is stuck, and
    // a keyframe would only be queued and dropped again: back off.
    if (!taken_since_idr_) {
      idr_retry_ms_ = std::min(idr_retry_ms_ * 2, kIdrMaxIntervalMs);
    }
    RequestIdrLocked();
  }

  void PostCodecError(const std::string& error) {
    Log(error);
    PostEvent([this, error] {
      std::lock_guard<std::mutex> lock(events_mu_);
      errors_.push_back(error);
    });
  }

  // Sets the event state, then wakes the platform thread.
  template <typename F>
  void PostEvent(F set) {
    set();
    HWND view = registrar_->GetView() ? registrar_->GetView()->GetNativeWindow()
                                      : nullptr;
    HWND root = view ? GetAncestor(view, GA_ROOT) : nullptr;
    if (root) PostMessage(root, kWmDecoderEvent, 0, 0);
  }

  std::optional<LRESULT> HandleWindowMessage(HWND, UINT message, WPARAM,
                                             LPARAM) {
    if (message != kWmDecoderEvent) return std::nullopt;
    if (idr_pending_.exchange(false)) {
      channel_->InvokeMethod("onRequestIdr", nullptr);
    }
    std::deque<std::string> errors;
    {
      std::lock_guard<std::mutex> lock(events_mu_);
      errors.swap(errors_);
    }
    for (const auto& e : errors) {
      channel_->InvokeMethod(
          "onCodecError", std::make_unique<flutter::EncodableValue>(e));
    }
    return 0;
  }

  // ─── Worker thread ────────────────────────────────────────────────────────

  void Worker(std::shared_ptr<TextureSlot> slot) {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const HRESULT mf = MFStartup(MF_VERSION, MFSTARTUP_LITE);
    if (FAILED(mf)) {
      PostCodecError(HrText("MFStartup", mf));
    } else if (!CreateDecoder()) {
      std::lock_guard<std::mutex> lock(queue_mu_);
      decoder_failed_ = true;
      queue_.clear();
    } else {
      std::lock_guard<std::mutex> lock(queue_mu_);
      decoder_failed_ = false;
      RestartInputFromKeyframeLocked();
      RequestIdrLocked();
    }
    while (true) {
      std::vector<uint8_t> au;
      {
        std::unique_lock<std::mutex> lock(queue_mu_);
        queue_cv_.wait(lock, [this] { return stop_ || !queue_.empty(); });
        if (stop_) break;
        au = std::move(queue_.front());
        queue_.pop_front();
        taken_since_idr_ = true;
        idr_retry_ms_ = kIdrMinIntervalMs;
      }
      if (decoder_ && !Decode(au, slot.get())) {
        // The decoder lost its place in the stream: start again at a
        // keyframe, as a new codec would.
        decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        std::lock_guard<std::mutex> lock(queue_mu_);
        RestartInputFromKeyframeLocked();
        RequestIdrThrottledLocked();
      }
    }
    ReleaseDecoder();
    if (SUCCEEDED(mf)) MFShutdown();
    if (SUCCEEDED(co)) CoUninitialize();
  }

  bool CreateDecoder() {
    MFT_REGISTER_TYPE_INFO input = {MFMediaType_Video,
                                    hevc_ ? MFVideoFormat_HEVC
                                          : MFVideoFormat_H264};
    MFT_REGISTER_TYPE_INFO output = {MFMediaType_Video, MFVideoFormat_NV12};
    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_DECODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
            MFT_ENUM_FLAG_SORTANDFILTER,
        &input, &output, &activates, &count);
    if (FAILED(hr) || count == 0) {
      CoTaskMemFree(activates);
      // H.265 needs the HEVC Video Extensions from the Microsoft Store.
      PostCodecError(std::string("NO_DECODER ") + (hevc_ ? "h265" : "h264"));
      return false;
    }
    hr = activates[0]->ActivateObject(IID_PPV_ARGS(&decoder_));
    for (UINT32 i = 0; i < count; i++) activates[i]->Release();
    CoTaskMemFree(activates);
    if (FAILED(hr)) {
      PostCodecError(HrText("ActivateObject", hr));
      return false;
    }

    ComPtr<IMFAttributes> attributes;
    if (SUCCEEDED(decoder_->GetAttributes(&attributes)) && attributes) {
      attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
    }

    ComPtr<IMFMediaType> in_type;
    MFCreateMediaType(&in_type);
    in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    in_type->SetGUID(MF_MT_SUBTYPE,
                     hevc_ ? MFVideoFormat_HEVC : MFVideoFormat_H264);
    in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (hint_w_ > 0 && hint_h_ > 0) {
      MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE, hint_w_, hint_h_);
    }
    MFSetAttributeRatio(in_type.Get(), MF_MT_FRAME_RATE, fps_.load(), 1);
    hr = decoder_->SetInputType(0, in_type.Get(), 0);
    if (FAILED(hr)) {
      PostCodecError(HrText("SetInputType", hr));
      decoder_.Reset();
      return false;
    }
    if (!ConfigureOutput()) {
      PostCodecError("no NV12 output");
      decoder_.Reset();
      return false;
    }
    decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    Log("decoder made");
    return true;
  }

  void ReleaseDecoder() {
    if (!decoder_) return;
    decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    decoder_.Reset();
  }

  // Picks NV12 and reads the picture's size, stride and visible area (the
  // coded height is rounded up to 16 lines; the aperture says what to show).
  bool ConfigureOutput() {
    for (DWORD i = 0;; i++) {
      ComPtr<IMFMediaType> type;
      if (FAILED(decoder_->GetOutputAvailableType(0, i, &type))) return false;
      GUID subtype{};
      if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) ||
          subtype != MFVideoFormat_NV12) {
        continue;
      }
      if (FAILED(decoder_->SetOutputType(0, type.Get(), 0))) return false;
      UINT32 w = 0, h = 0;
      MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h);
      frame_w_ = w;
      frame_h_ = h;
      UINT32 stride = 0;
      stride_ = SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride))
                    ? static_cast<LONG>(stride)
                    : static_cast<LONG>(w);
      MFVideoArea area{};
      UINT32 got = 0;
      if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE,
                                  reinterpret_cast<UINT8*>(&area),
                                  sizeof(area), &got)) &&
          got == sizeof(area) && area.Area.cx > 0 && area.Area.cy > 0) {
        show_x_ = static_cast<UINT32>(area.OffsetX.value);
        show_y_ = static_cast<UINT32>(area.OffsetY.value);
        show_w_ = static_cast<UINT32>(area.Area.cx);
        show_h_ = static_cast<UINT32>(area.Area.cy);
      } else {
        show_x_ = show_y_ = 0;
        show_w_ = w;
        show_h_ = h;
      }
      if (w > 0) {
        Log("output " + std::to_string(w) + "x" + std::to_string(h) +
            " showing " + std::to_string(show_w_) + "x" +
            std::to_string(show_h_));
      }
      return true;
    }
  }

  bool Decode(const std::vector<uint8_t>& au, TextureSlot* slot) {
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(MFCreateMemoryBuffer(static_cast<DWORD>(au.size()), &buffer))) {
      return false;
    }
    BYTE* dst = nullptr;
    buffer->Lock(&dst, nullptr, nullptr);
    std::memcpy(dst, au.data(), au.size());
    buffer->Unlock();
    buffer->SetCurrentLength(static_cast<DWORD>(au.size()));
    ComPtr<IMFSample> sample;
    MFCreateSample(&sample);
    sample->AddBuffer(buffer.Get());
    const int fps = std::max(1, fps_.load());
    sample->SetSampleTime(sample_time_);
    sample->SetSampleDuration(10'000'000LL / fps);
    sample_time_ += 10'000'000LL / fps;

    HRESULT hr = decoder_->ProcessInput(0, sample.Get(), 0);
    if (hr == MF_E_NOTACCEPTING) {
      if (!DrainOutput(slot)) return false;
      hr = decoder_->ProcessInput(0, sample.Get(), 0);
    }
    if (FAILED(hr)) {
      Log(HrText("ProcessInput", hr));
      return false;
    }
    return DrainOutput(slot);
  }

  bool DrainOutput(TextureSlot* slot) {
    while (true) {
      MFT_OUTPUT_STREAM_INFO info{};
      if (FAILED(decoder_->GetOutputStreamInfo(0, &info))) return false;
      const bool provides =
          (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
                           MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
      ComPtr<IMFSample> own;
      if (!provides) {
        ComPtr<IMFMediaBuffer> buffer;
        const DWORD size = info.cbSize > 0 ? info.cbSize : 4;
        if (FAILED(MFCreateMemoryBuffer(size, &buffer))) return false;
        MFCreateSample(&own);
        own->AddBuffer(buffer.Get());
      }
      MFT_OUTPUT_DATA_BUFFER out{};
      out.dwStreamID = 0;
      out.pSample = own.Get();
      DWORD status = 0;
      const HRESULT hr = decoder_->ProcessOutput(0, 1, &out, &status);
      if (out.pEvents) out.pEvents->Release();
      if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
      if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        if (provides && out.pSample) out.pSample->Release();
        if (!ConfigureOutput()) return false;
        continue;
      }
      if (FAILED(hr)) {
        if (provides && out.pSample) out.pSample->Release();
        Log(HrText("ProcessOutput", hr));
        return false;
      }
      if (out.pSample) Show(out.pSample, slot);
      if (provides && out.pSample) out.pSample->Release();
    }
  }

  void Show(IMFSample* sample, TextureSlot* slot) {
    if (show_w_ < 2 || show_h_ < 2 || frame_h_ == 0) return;
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) return;
    const size_t w = show_w_ & ~1u, h = show_h_ & ~1u;
    ComPtr<IMF2DBuffer> two_d;
    BYTE* base = nullptr;
    LONG pitch = 0;
    bool locked_2d = false;
    if (SUCCEEDED(buffer.As(&two_d)) &&
        SUCCEEDED(two_d->Lock2D(&base, &pitch))) {
      locked_2d = true;
    } else {
      DWORD length = 0;
      if (FAILED(buffer->Lock(&base, nullptr, &length))) return;
      pitch = stride_;
      if (static_cast<size_t>(pitch) * frame_h_ * 3 / 2 > length) {
        buffer->Unlock();
        return;
      }
    }
    if (pitch > 0) {
      uint8_t* out = slot->store.Back(w, h);
      Nv12ToRgba(base, base + static_cast<size_t>(pitch) * frame_h_, pitch,
                 show_x_, show_y_, w, h, out);
    }
    if (locked_2d) {
      two_d->Unlock2D();
    } else {
      buffer->Unlock();
    }
    if (pitch <= 0) return;
    slot->store.Publish();
    textures_->MarkTextureFrameAvailable(slot->id);
  }

  flutter::PluginRegistrarWindows* registrar_;
  flutter::TextureRegistrar* textures_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  int window_proc_id_ = -1;

  std::shared_ptr<TextureSlot> slot_;
  std::thread worker_;
  std::atomic<int> fps_{60};
  std::atomic<int> dropped_{0};
  bool hevc_ = false;
  int hint_w_ = 0, hint_h_ = 0;

  // Queue state, under queue_mu_.
  std::mutex queue_mu_;
  std::condition_variable queue_cv_;
  std::deque<std::vector<uint8_t>> queue_;
  bool stop_ = false;
  bool awaiting_keyframe_ = true;
  bool decoder_failed_ = false;
  bool taken_since_idr_ = false;
  int64_t last_idr_ms_ = 0;
  int64_t idr_retry_ms_ = kIdrMinIntervalMs;

  // Events for the platform thread.
  std::atomic<bool> idr_pending_{false};
  std::mutex events_mu_;
  std::deque<std::string> errors_;

  // Worker thread only.
  ComPtr<IMFTransform> decoder_;
  UINT32 frame_w_ = 0, frame_h_ = 0;
  LONG stride_ = 0;
  UINT32 show_x_ = 0, show_y_ = 0, show_w_ = 0, show_h_ = 0;
  LONGLONG sample_time_ = 0;
};

}  // namespace

void VideoDecoderPluginRegister(flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<VideoDecoderPlugin>(registrar));
}
