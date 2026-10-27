#include <mach/mach.h>
#include <notify.h>
#include <ptrauth.h>

#include "VCamImage.h"
#include "VCamSynthetic.h"
#include "VCamSourceScan.h"

// MARK: - synthetic source creation

// FigCaptureSourceCreateFromBacking signature (5 args):
//   (CFAllocatorRef allocator, FigCaptureSourceBacking *backing,
//    audit_token_t *token, int unused_x3, FigCaptureSource **outSource)
typedef int (*VCC_CreateFn)(CFAllocatorRef, id, void *, int, void **);

typedef int (*VCC_CreateVideoFn)(CFAllocatorRef, id, void *, int, id, id, id, void **);

static void *vcc_create_synthetic_source(void *create_fn, BOOL videoABI, id backing) {
  audit_token_t self_token;
  mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
  kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN,
                               (task_info_t)&self_token, &count);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  task_info(TASK_AUDIT_TOKEN) failed: %d", kr);
    return NULL;
  }

  void *outSource = NULL;
  int ret = videoABI
      ? ((VCC_CreateVideoFn)create_fn)(kCFAllocatorDefault, backing, &self_token,
                                     0, nil, nil, nil, &outSource)
      : ((VCC_CreateFn)create_fn)(kCFAllocatorDefault, backing, &self_token,
                                0, &outSource);
  vcc_log(@"  CreateFromBacking ret=0x%x outSource=%p", (unsigned)ret,
          outSource);
  return outSource;
}

// Walk the synthetic's PAC-signed vtable to call CopyProperty (vtable[6]) for
// confirmation of the contract methods. This is purely diagnostic; uses only
// dlsym-resolvable anchors (CMBaseObjectGetVTable) and standard PAC builtins.
static void vcc_probe_contract(void *source) {
  void *(*CMBaseObjectGetVTable)(void *) =
      (void *(*)(void *))vcc_dlsym_fn("CMBaseObjectGetVTable");
  if (!CMBaseObjectGetVTable) return;
  void *V = CMBaseObjectGetVTable(source);
  vcc_log(@"  CMBaseObjectGetVTable(synth) = %p", V);
  if (!V) return;

  // Auth the vtable pointer (data key A, address-blended discriminator).
  void **vtable_slot = (void **)((char *)V + 8);
  void *real_vtable_signed = *vtable_slot;
  uintptr_t vt_disc =
      __builtin_ptrauth_blend_discriminator(vtable_slot, 47377);
  void *real_vtable = __builtin_ptrauth_auth(real_vtable_signed,
                                              ptrauth_key_asda, vt_disc);
  vcc_log(@"  real_vtable @ %p", real_vtable);

  // Auth method6 (instruction key A) then resign for the C ABI call.
  void **method6_slot = (void **)((char *)real_vtable + 48);
  void *method6_signed = *method6_slot;
  uintptr_t m6_disc =
      __builtin_ptrauth_blend_discriminator(method6_slot, 38693);
  void *method6 = __builtin_ptrauth_auth_and_resign(
      method6_signed, ptrauth_key_asia, m6_disc,
      ptrauth_key_function_pointer, 0);
  vcc_log(@"  CopyProperty (vtable[6]) @ %p", method6);

  typedef int (*VCC_CopyPropFn)(void *src, CFStringRef key,
                                 CFAllocatorRef alloc, CFTypeRef *out);
  VCC_CopyPropFn copyProp = (VCC_CopyPropFn)method6;

  CFStringRef k_attrs = vcc_cfconst(
      "kFigCaptureSourceProperty_AttributesDictionary");
  CFStringRef k_fmts  = vcc_cfconst("kFigCaptureSourceProperty_Formats");

  CFTypeRef outAttrs = NULL;
  int e1 = copyProp(source, k_attrs, kCFAllocatorDefault, &outAttrs);
  vcc_log(@"  CopyProperty(AttributesDictionary) ret=%d out=%p (%@)",
          e1, outAttrs, outAttrs);
  if (outAttrs) CFRelease(outAttrs);

  CFTypeRef outFmts = NULL;
  int e2 = copyProp(source, k_fmts, kCFAllocatorDefault, &outFmts);
  vcc_log(@"  CopyProperty(Formats) ret=%d out=%p (count=%ld)",
          e2, outFmts,
          outFmts && CFGetTypeID(outFmts) == CFArrayGetTypeID()
              ? CFArrayGetCount(outFmts) : -1);
  if (outFmts) CFRelease(outFmts);
}

// MARK: - _sSourceList manipulation

void vcc_install_synthetic(void) {
  // iOS 27 has no source list to append to; the backing went into the
  // provider when the daemon first asked for it (VCamProviderSource.m).
  if (vcc_provider_publishes_sources()) {
    vcc_log(@"  source list: the backings provider publishes the camera here");
    return;
  }
  vcc_image_t img;
  int rc = vcc_image_resolve(&img, "FigCaptureSourceServerStart");
  if (rc != 0) {
    vcc_log(@"  image resolve failed rc=%d", rc);
    return;
  }
  vcc_log(@"  CMCapture mh=%p slide=0x%lx text=%p words=%zu nsyms=%u",
          img.mh, (unsigned long)img.slide, img.text, img.text_words,
          img.nsyms);

  // DSC strips per-image LC_SYMTAB names to "<redacted>" — symtab walking
  // by name doesn't work. Recover the two private function addresses via
  // a structural pattern scan of __text for the daemon's filter chain.
  uintptr_t si_fn_addr = 0, prewarm_fn_addr = 0;
  uintptr_t hit_pc =
      vcc_find_filter_chain(&img, &si_fn_addr, &prewarm_fn_addr);
  vcc_log(@"  filter-chain scan: pc=0x%lx si_fn=0x%lx prewarm_fn=0x%lx",
          (unsigned long)hit_pc, (unsigned long)si_fn_addr,
          (unsigned long)prewarm_fn_addr);

  // Patch the per-source ownership/prewarming filter that runs inside the
  // iteration loop of handleCopySourcesMessage. Without these patches,
  // every source is rejected unless its ClientBundleIdentifier property
  // matches the requesting client's signing-id AND PrewarmingEnabled is
  // YES — which is never true for our synthetic source nor for the daemon
  // bring-up source against a non-Camera.app client.
  uintptr_t per_source_pc = vcc_find_per_source_filter(&img);
  if (per_source_pc) {
    int ok = vcc_patch_two_nops(per_source_pc);
    vcc_log(@"  per-source NOP patch %s @ 0x%lx",
            ok ? "OK" : "FAILED", (unsigned long)per_source_pc);
  } else {
    vcc_log(@"  per-source filter not located — daemon will skip our source");
  }

  // Prefer an export when available; 27.0.1 strips this function from exports.
  // The structural fallback follows the saved client register instead.
  void *prewarm_export = dlsym(RTLD_DEFAULT,
      "FigCaptureGetSupportedPrewarmingBundleIdentifiers");
  if (prewarm_export) prewarm_fn_addr = (uintptr_t)ptrauth_strip(
      prewarm_export, ptrauth_key_function_pointer);
  if (prewarm_fn_addr) {

    typedef CFTypeRef (*PrewarmFn)(void);
    PrewarmFn pf = (PrewarmFn)ptrauth_sign_unauthenticated(
        (void *)prewarm_fn_addr, ptrauth_key_function_pointer, 0);
    CFTypeRef setv = pf();
    vcc_log(@"  prewarming allowlist set = %p (%@)",
            setv, (__bridge id)setv);

    // Patch the daemon's prewarming-bundle allowlist so EVERY XPC client
    // passes the `[set containsObject:clientSI]` gate in
    // _captureSourceServer_handleCopySourcesMessage. We don't mutate the
    // set's contents — we object_setClass it to a dynamically-built
    // subclass whose -containsObject: implementation always returns YES.
    // This is __DATA-clean (no __TEXT writes, no TXM concerns) and
    // limited to this single singleton instance.
    if (setv) {
      id theSet = (__bridge id)setv;
      Class origCls = object_getClass(theSet);
      Class allowCls = objc_allocateClassPair(
          origCls, "vcc_AlwaysAllowSet", 0);
      if (allowCls) {
        IMP yesImp = imp_implementationWithBlock(
            ^BOOL(__unused id self_, __unused id obj) { return YES; });
        Method orig = class_getInstanceMethod(origCls,
                                              @selector(containsObject:));
        const char *types = orig ? method_getTypeEncoding(orig) : "B@:@";
        class_addMethod(allowCls, @selector(containsObject:), yesImp, types);
        objc_registerClassPair(allowCls);
        object_setClass(theSet, allowCls);
        vcc_log(@"  swizzled set's class -> vcc_AlwaysAllowSet (orig=%s)",
                class_getName(origCls));
      } else {
        vcc_log(@"  objc_allocateClassPair returned nil (already registered?)");
      }
    }
  }


  // Force daemon's source-server init so `_sSourceList` is allocated.
  void *start_fn = vcc_dlsym_fn("FigCaptureSourceServerStart");
  if (start_fn) {
    ((void (*)(void))start_fn)();
    vcc_log(@"  called FigCaptureSourceServerStart()");
  }

  // Resolve _sSourceList structurally:
  //
  //   LC_SYMTAB → __captureSourceServer_initializeStatics_block_invoke
  //     (the dispatch_once init body — static text symbol, retained
  //      in the on-device DSC nlist even when static *data* symbols
  //      like `_sSourceList` itself are stripped)
  //     → BL CFArrayCreateMutable inside the block body
  //     → adrp+str x0, [Xn, #imm]  ← stores into _sSourceList
  //
  // Private symbols may be stripped. The fallback handles both an outlined
  // dispatch_once helper and the inline wrapper shipped in iOS 27.0.1.
  // The on-device nlist exports static text symbols with leading
  // underscores. Block-invoke names take one extra underscore vs the
  // outer C symbol — try the canonical first, plus a triple-_ variant
  // some clangs emit.
  static const char *kInitBlockNames[] = {
      "__captureSourceServer_initializeStatics_block_invoke",
      "___captureSourceServer_initializeStatics_block_invoke",
      NULL,
  };
  uintptr_t blockInvoke = 0;
  for (unsigned i = 0; kInitBlockNames[i]; i++) {
    blockInvoke = vcc_lookup_lc_symtab(&img, kInitBlockNames[i]);
    if (blockInvoke) {
      vcc_log(@"  init-statics block-invoke (%s) @ 0x%lx",
              kInitBlockNames[i], (unsigned long)blockInvoke);
      break;
    }
  }
  if (!blockInvoke) {
    void *start = dlsym(RTLD_DEFAULT, "FigCaptureSourceServerStart");
    const vcc_source_text_t text = {
        img.text, (uintptr_t)img.text, img.text_words};
    uintptr_t block = start ? vcc_source_init_block(&text,
        (uintptr_t)ptrauth_strip(start, ptrauth_key_function_pointer)) : 0;
    // Validate the complete block literal lies in this image's data before
    // dereferencing its invoke pointer. No fallback to an arbitrary global.
    for (unsigned i = 0; block && i < img.data_range_count; i++) {
      if (block < img.data_ranges[i].start ||
          block > img.data_ranges[i].end - 32) continue;
      uintptr_t invoke = (uintptr_t)ptrauth_strip(
          *(void **)(block + 16), ptrauth_key_function_pointer);
      if (invoke >= (uintptr_t)img.text &&
          invoke < (uintptr_t)(img.text + img.text_words) && !(invoke & 3)) {
        blockInvoke = invoke;
        vcc_log(@"  init block-invoke (dispatch_once block %p) @ %p",
                (void *)block, (void *)invoke);
      }
      break;
    }
  }
  uintptr_t sSourceListAddr = 0;
  if (blockInvoke) {
    uintptr_t globals[8] = {0};
    unsigned ng = vcc_collect_call_then_store_globals(blockInvoke,
                                                       /*maxInsns*/512,
                                                       /*lookahead*/12,
                                                       globals, 8);
    for (unsigned i = 0; i < ng; i++) {
      vcc_log(@"  init-statics global #%u: 0x%lx",
              i, (unsigned long)globals[i]);
    }
    // The init block initializes both `_sSourceListLock` (lock
    // handle) and `_sSourceList` (CFArray) in order. Walk the
    // discovered globals and pick the first one whose slot value
    // is actually a CFArray — that's the source list. The lock
    // entry has a void* mutex handle which malloc_zone validates
    // but isa fails the CFArray-class check.
    uintptr_t symLookup = vcc_lookup_lc_symtab(&img, "_sSourceList");
    if (symLookup) {
      vcc_log(@"  _sSourceList also in LC_SYMTAB at 0x%lx — using",
              (unsigned long)symLookup);
      sSourceListAddr = symLookup;
    } else {
      for (unsigned i = 0; i < ng; i++) {
        BOOL inData = NO;
        for (unsigned j = 0; j < img.data_range_count; j++) {
          if (globals[i] >= img.data_ranges[j].start &&
              globals[i] <= img.data_ranges[j].end - sizeof(uintptr_t)) {
            inData = YES;
            break;
          }
        }
        if (!inData) continue;
        if (vcc_slot_value_is_cfarray(globals[i])) {
          uintptr_t val = 0;
          if (globals[i]) val = *(uintptr_t *)globals[i];
          vcc_log(@"  _sSourceList chosen (init-store #%u, CFArray @ 0x%lx) at 0x%lx",
                  i, (unsigned long)val, (unsigned long)globals[i]);
          sSourceListAddr = globals[i];
          break;
        }
      }
      if (!sSourceListAddr) {
        vcc_log(@"  no init-store global slot held a CFArray; registration skipped");
      }
    }
  } else {
    vcc_log(@"  init-statics block-invoke lookup failed");
  }
  if (!sSourceListAddr) {
    vcc_log(@"  data global resolve failed: _sSourceList not located");
    return;
  }

  // For the lock, the call-anchor approach requires knowing which
  // mutex-create function the daemon uses (FigSimpleMutexCreate / Init
  // / etc. — name varies across iOS). Skip locking entirely: our
  // dispatch_after fires after FigCaptureSourceServerStart's
  // dispatch_once block has finished, and we're the only writer to
  // _sSourceList during this init window.
  CFMutableArrayRef *sSourceListSlot =
      (CFMutableArrayRef *)sSourceListAddr;
  vcc_log(@"  lock acquisition skipped (single-threaded init window)");
  vcc_log(@"  _sSourceList slot @ %p (list=%p)", sSourceListSlot,
          *sSourceListSlot);

  // Resolve the legacy export first, then the split video-source API.
  void *create_p = vcc_dlsym_fn("FigCaptureSourceCreateFromBacking");
  BOOL videoABI = NO;
  if (!create_p) {
    create_p = vcc_dlsym_fn("FigVideoCaptureSourceCreateFromBacking");
    videoABI = YES;
  }
  if (!create_p) {
    vcc_log(@"  abort: no supported source creation export");
    return;
  }
  // iOS 27 splits audio/video creation. Its caller passes optional backing
  // configuration objects in x4/x5, client context in x6, and output in x7.
  vcc_log(@"  source creation ABI: %@", videoABI ? @"video/8" : @"legacy/5");

  id backing = vcc_build_backing();
  if (!backing) return;
  void *source = vcc_create_synthetic_source(create_p, videoABI, backing);
  if (!source) {
    vcc_log(@"  create returned NULL — abort");
    return;
  }

  vcc_probe_contract(source);

  // Dump ALL existing sources' AttributesDictionary so we can mirror what
  // the daemon's stock (bring-up / hardware) sources use for keys like
  // DeviceType, SmartCameraSupported, Streams, Ports, etc.
  {
    CFMutableArrayRef listSnap = *sSourceListSlot;
    CFIndex cnt = listSnap ? CFArrayGetCount(listSnap) : 0;
    vcc_log(@"  --- existing sources (count=%ld) ---", (long)cnt);
    void *(*CMBaseObjectGetVTable)(void *) =
        (void *(*)(void *))vcc_dlsym_fn("CMBaseObjectGetVTable");
    for (CFIndex i = 0; i < cnt; i++) {
      void *s = (void *)CFArrayGetValueAtIndex(listSnap, i);
      vcc_log(@"    source[%ld] = %p", (long)i, s);
      if (!CMBaseObjectGetVTable) continue;
      void *V = CMBaseObjectGetVTable(s);
      if (!V) continue;
      void **vtable_slot = (void **)((char *)V + 8);
      void *real_vtable_signed = *vtable_slot;
      uintptr_t vt_disc =
          __builtin_ptrauth_blend_discriminator(vtable_slot, 47377);
      void *real_vtable = __builtin_ptrauth_auth(real_vtable_signed,
                                                  ptrauth_key_asda, vt_disc);
      if (!real_vtable) continue;
      void **method6_slot = (void **)((char *)real_vtable + 48);
      void *method6_signed = *method6_slot;
      uintptr_t m6_disc =
          __builtin_ptrauth_blend_discriminator(method6_slot, 38693);
      void *method6 = __builtin_ptrauth_auth_and_resign(
          method6_signed, ptrauth_key_asia, m6_disc,
          ptrauth_key_function_pointer, 0);
      typedef int (*CP)(void *, CFStringRef, CFAllocatorRef, CFTypeRef *);
      CP copyProp = (CP)method6;
      CFStringRef k_attrs = vcc_cfconst(
          "kFigCaptureSourceProperty_AttributesDictionary");
      CFTypeRef out = NULL;
      int e = copyProp(s, k_attrs, kCFAllocatorDefault, &out);
      vcc_log(@"      attrs ret=%d -> %@", e, (__bridge id)out);
      if (out) CFRelease(out);
    }
  }

  CFMutableArrayRef list = *sSourceListSlot;
  if (!list) {
    vcc_log(@"  _sSourceList is NULL (server init not yet allocated it) — abort");
    return;
  }
  CFIndex preCount = CFArrayGetCount(list);
  CFArrayAppendValue(list, source);
  CFIndex postCount = CFArrayGetCount(list);
  vcc_log(@"  appended source — list %ld -> %ld", (long)preCount,
          (long)postCount);

  CFStringRef notifNameCF = vcc_cfconst(
      "kFigCaptureSourceNotification_SourceInfoArrayChanged");
  if (notifNameCF) {
    char buf[256];
    if (CFStringGetCString(notifNameCF, buf, sizeof(buf),
                           kCFStringEncodingUTF8)) {
      uint32_t status = notify_post(buf);
      vcc_log(@"  notify_post(%s) -> %u", buf, status);
    } else {
      vcc_log(@"  CFStringGetCString failed for notif name");
    }
  } else {
    vcc_log(@"  notif name CFString constant missing");
  }
}
