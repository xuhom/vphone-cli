#ifndef VCAM_SOURCE_SCAN_H
#define VCAM_SOURCE_SCAN_H
#include <stddef.h>
#include <stdint.h>

// Read-only instruction scans shared by the guest and offline host tests.
// Addresses refer to the original image, independently of the words' storage.
typedef struct {
  const uint32_t *words;
  uintptr_t address;
  size_t count;
} vcc_source_text_t;

// Returns the dispatch_once block constant, not its invoke pointer. Both an
// outlined cold helper (26.x) and an inline dispatch_once wrapper (27.x) work.
uintptr_t vcc_source_init_block(const vcc_source_text_t *text, uintptr_t entry);

// Returns the ownership/prewarm CBZ pair, requiring matching saved registers
// and a shared forward skip target. Ambiguous matches fail closed.
uintptr_t vcc_source_ownership_filter(const vcc_source_text_t *text);
uintptr_t vcc_source_prewarm_chain(const vcc_source_text_t *text,
                                    uintptr_t *signing_id, uintptr_t *prewarm);
#endif
