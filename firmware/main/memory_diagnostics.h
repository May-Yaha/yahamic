#pragma once

#include "esp_heap_caps.h"
#include "esp_attr.h"
#include "esp_log.h"

namespace diagnostics {
// Failed allocations, including explicit internal-only ones. The hook may run with flash cache disabled
// (Wi-Fi IRAM allocators during NVS writes), so it only writes DRAM; heap() reports it.
// shortcut: unlocked counters can miss a concurrent increment; good enough for a diagnostic.
inline volatile uint32_t failed_allocs = 0, failed_size = 0, failed_caps = 0;
static IRAM_ATTR void on_failed_alloc(size_t size, uint32_t caps, const char*) {
  failed_allocs = failed_allocs + 1;
  failed_size = size;
  failed_caps = caps;
}
inline void heap(const char* phase) {
  constexpr uint32_t internal = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
  ESP_LOGI("heap", "%s internal free=%u largest=%u min=%u dma_largest=%u psram=%u",
           phase, unsigned(heap_caps_get_free_size(internal)),
           unsigned(heap_caps_get_largest_free_block(internal)),
           unsigned(heap_caps_get_minimum_free_size(internal)),
           unsigned(heap_caps_get_largest_free_block(MALLOC_CAP_DMA)),
           unsigned(heap_caps_get_free_size(MALLOC_CAP_SPIRAM)));
  if (failed_allocs)
    ESP_LOGW("heap", "alloc failed x%u, last size=%u caps=0x%x", unsigned(failed_allocs), unsigned(failed_size),
             unsigned(failed_caps));
}
inline void watch_failed_allocs() { heap_caps_register_failed_alloc_callback(on_failed_alloc); }
}  // namespace diagnostics
