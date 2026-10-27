#include "VCamSourceScan.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static const uintptr_t base = 0x100000000ull;
static uint32_t words[512];
static vcc_source_text_t text = {words, 0x100000000ull, 512};

static uint32_t relative(uint32_t op, unsigned from, unsigned to, unsigned bits) {
  uint32_t mask = (1u << bits) - 1;
  return op | (((to - from) & mask) << (bits == 19 ? 5 : 0));
}

static void init_fixture(int outlined) {
  memset(words, 0, sizeof words);
  words[0] = 0xb100051f; // cmn x8,#1
  words[1] = relative(0x54000001, 1, 32, 19); // b.ne wrapper
  unsigned helper = outlined ? 64 : 32;
  if (outlined) words[32] = relative(0x94000000, 32, helper, 26);
  words[helper] = 0x90000000; // adrp x0,page (once token)
  words[helper + 1] = 0x91004000; // add x0,x0,#16
  words[helper + 2] = 0x90000001; // adrp x1,page (block)
  words[helper + 3] = 0x91058021; // add x1,x1,#0x160
  words[helper + 4] = 0x94000000; // bl dispatch_once
}

static void filter_fixture(unsigned index, unsigned saved, unsigned client) {
  words[index] = 0x94000000; // bl boolValue
  words[index + 1] = 0xaa0003e0 | saved; // mov Xsaved,x0
  words[index + 2] = 0xf9412fe2; // ldr x2,[sp,#0x258] (24A446)
  words[index + 3] = 0xaa0003e0 | (client << 16); // mov x0,Xclient
  words[index + 4] = 0x94000000; // bl isEqualToString:
  words[index + 5] = relative(0x34000000, index + 5, index + 20, 19);
  words[index + 6] = relative(0x34000000 | saved, index + 6, index + 20, 19);
}

int main(void) {
  init_fixture(0);
  assert(vcc_source_init_block(&text, base) == base + 0x160);
  init_fixture(1);
  assert(vcc_source_init_block(&text, base) == base + 0x160);
  assert(!vcc_source_init_block(&text, base - 4));
  words[67] = 0x91058042; // x2 is not dispatch_once's block argument
  assert(!vcc_source_init_block(&text, base));
  memset(words, 0, sizeof words);
  assert(!vcc_source_init_block(&text, base));
  for (unsigned saved = 19; saved <= 28; saved++) {
    memset(words, 0, sizeof words);
    filter_fixture(0, saved, saved == 20 ? 22 : 20);
    assert(vcc_source_ownership_filter(&text) == base + 20);
  }
  // iOS 26 used x25/x22; iOS 27.0.1 uses x28/x20.
  memset(words, 0, sizeof words);
  filter_fixture(0, 28, 20);
  words[6] += 1u << 5; // branch to a different skip block
  assert(!vcc_source_ownership_filter(&text));
  filter_fixture(0, 28, 20);
  words[6] ^= 1; // test a different bool register
  assert(!vcc_source_ownership_filter(&text));
  filter_fixture(0, 28, 20);
  filter_fixture(40, 25, 22);
  assert(!vcc_source_ownership_filter(&text)); // ambiguity must not patch
  vcc_source_text_t truncated = {words, base, 6};
  assert(!vcc_source_ownership_filter(&truncated));
  uintptr_t si = 0, pw = 0;
  for (unsigned client = 19; client <= 28; client++) {
    memset(words, 0, sizeof words);
    words[0] = relative(0x94000000, 0, 40, 26);
    words[1] = relative(0x94000000, 1, 50, 26);
    words[2] = 0xaa0003e0 | client;
    words[3] = relative(0x94000000, 3, 60, 26);
    words[4] = relative(0xb4000000 | client, 4, 80, 19);
    words[5] = 0xaa0003e2 | (client << 16);
    words[6] = relative(0x94000000, 6, 70, 26);
    words[7] = relative(0x34000000, 7, 80, 19);
    assert(vcc_source_prewarm_chain(&text, &si, &pw) == base);
    assert(si == base + 160 && pw == base + 240);
  }
  words[5] ^= 1u << 16;
  assert(!vcc_source_prewarm_chain(&text, &si, &pw));
  assert(!si && !pw);
  words[5] ^= 1u << 16;
  memcpy(words + 100, words, 8 * sizeof(uint32_t));
  assert(!vcc_source_prewarm_chain(&text, &si, &pw));
  assert(!si && !pw);
  puts("VCam source scans passed: inline/outlined once, register allocation, bounds and ambiguity");
}
