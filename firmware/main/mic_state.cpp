#include "mic_state.h"

#include <mutex>

#include "audio.h"
#include "cloud.h"
#include "uplink.h"

namespace mic {
namespace {
std::mutex lock;
}

void set_muted(bool muted) {
  std::lock_guard<std::mutex> guard(lock);
  cloud::pause(!muted);
  audio::set_muted(muted);
  uplink::set_muted(muted);
}

void toggle() {
  std::lock_guard<std::mutex> guard(lock);
  const bool muted = !uplink::muted();
  cloud::pause(!muted);
  audio::set_muted(muted);
  uplink::set_muted(muted);
}

}  // namespace mic
