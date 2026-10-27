#include "VCamSourceScan.h"

static int64_t sext(uint64_t value, unsigned bits) {
  uint64_t sign = 1ull << (bits - 1);
  return (int64_t)((value ^ sign) - sign);
}

static const uint32_t *word(const vcc_source_text_t *text, uintptr_t pc) {
  if (pc < text->address || (pc & 3)) return NULL;
  size_t index = (pc - text->address) / 4;
  return index < text->count ? text->words + index : NULL;
}

static uintptr_t branch(uintptr_t pc, uint32_t w) {
  return pc + sext(w & 0x03ffffffu, 26) * 4;
}

uintptr_t vcc_source_init_block(const vcc_source_text_t *text, uintptr_t entry) {
  uintptr_t result = 0;
  for (unsigned i = 0; i < 256; i++) {
    uintptr_t pc = entry + i * 4;
    const uint32_t *a = word(text, pc), *b = word(text, pc + 4);
    if (!a || !b) break;
    // cmn Xn, #1; b.ne cold-wrapper
    if ((*a & 0xffc0001fu) != 0xb100001fu || ((*a >> 10) & 0xfff) != 1 ||
        (*b & 0xff00001fu) != 0x54000001u) continue;
    uintptr_t wrapper = pc + 4 + sext((*b >> 5) & 0x7ffff, 19) * 4;
    const uint32_t *first = word(text, wrapper);
    if (!first) continue;
    // 26.x calls an outlined helper. 27.x starts with the dispatch_once
    // argument setup itself; treating its first ADRP as BL lost the block.
    if ((*first & 0xfc000000u) == 0x94000000u)
      wrapper = branch(wrapper, *first);
    for (unsigned j = 0; j < 16; j++) {
      uintptr_t addPC = wrapper + j * 4;
      const uint32_t *add = word(text, addPC);
      if (!add) break;
      if ((*add & 0xffc003ffu) != 0x91000021u) continue; // add x1,x1,#imm
      for (unsigned k = 1; k <= 4 && k <= j; k++) {
        uintptr_t pagePC = addPC - k * 4;
        const uint32_t *page = word(text, pagePC);
        if (!page || (*page & 0x9f00001fu) != 0x90000001u) continue;
        uint64_t imm = (((uint64_t)(*page >> 5) & 0x7ffff) << 2) | ((*page >> 29) & 3);
        uintptr_t block = (pagePC & ~(uintptr_t)0xfff) + sext(imm, 21) * 4096 +
                          ((*add >> 10) & 0xfff);
        if (result && result != block) return 0;
        result = block;
        break;
      }
    }
  }
  return result;
}

uintptr_t vcc_source_ownership_filter(const vcc_source_text_t *text) {
  uintptr_t result = 0;
  for (size_t i = 1; i + 5 < text->count; i++) {
    const uint32_t *p = text->words + i;
    if ((p[-1] & 0xfc000000u) != 0x94000000u) continue;
    // Preserve the boolValue return in any callee-saved register.
    if ((p[0] & 0xffffffe0u) != 0xaa0003e0u) continue;
    unsigned saved = p[0] & 31;
    if (saved < 19 || saved > 28) continue;
    if ((p[1] & 0xffc003ffu) != 0xf94003e2u) continue; // ldr x2,[sp,#imm]
    if ((p[2] & 0xffe0ffffu) != 0xaa0003e0u) continue; // mov x0,Xclient
    unsigned client = (p[2] >> 16) & 31;
    if (client < 19 || client > 28 || client == saved) continue;
    if ((p[3] & 0xfc000000u) != 0x94000000u ||
        (p[4] & 0xff00001fu) != 0x34000000u ||
        (p[5] & 0xff00001fu) != (0x34000000u | saved)) continue;
    uintptr_t pc = text->address + (i + 4) * 4;
    uintptr_t skip = pc + sext((p[4] >> 5) & 0x7ffff, 19) * 4;
    if (skip != pc + 4 + sext((p[5] >> 5) & 0x7ffff, 19) * 4 ||
        skip <= pc + 4 || !word(text, skip)) continue;
    if (result && result != pc) return 0;
    result = pc;
  }
  return result;
}

uintptr_t vcc_source_prewarm_chain(const vcc_source_text_t *text,
                                    uintptr_t *signing_id, uintptr_t *prewarm) {
  *signing_id = *prewarm = 0;
  uintptr_t result = 0, si = 0, pw = 0;
  for (size_t i = 0; i + 7 < text->count; i++) {
    const uint32_t *p = text->words + i;
    if ((p[0] & 0xfc000000u) != 0x94000000u ||
        (p[1] & 0xfc000000u) != 0x94000000u ||
        (p[2] & 0xffffffe0u) != 0xaa0003e0u ||
        (p[3] & 0xfc000000u) != 0x94000000u) continue;
    unsigned client = p[2] & 31;
    if (client < 19 || client > 28 ||
        (p[4] & 0xff00001fu) != (0xb4000000u | client) ||
        p[5] != (0xaa0003e2u | (client << 16)) ||
        (p[6] & 0xfc000000u) != 0x94000000u ||
        (p[7] & 0xff00001fu) != 0x34000000u) continue;
    uintptr_t pc = text->address + i * 4;
    uintptr_t skip = pc + 16 + sext((p[4] >> 5) & 0x7ffff, 19) * 4;
    if (skip != pc + 28 + sext((p[7] >> 5) & 0x7ffff, 19) * 4 ||
        skip <= pc + 28 || !word(text, skip)) continue;
    if (result) return 0;
    result = pc;
    si = branch(pc, p[0]);
    pw = branch(pc + 12, p[3]);
    if (!word(text, si) || !word(text, pw)) return 0;
  }
  *signing_id = si;
  *prewarm = pw;
  return result;
}
