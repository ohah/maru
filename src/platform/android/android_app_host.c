// PoC 7(Android): **에뮬레이터 화면에** maru chrome 을 그린다.
//
// 앞 단계는 오프스크린 텍스처를 PPM 으로 뽑았다. 여기서는 `NativeActivity` + Vulkan
// swapchain 으로 진짜 창에 그린다 — iOS 시뮬레이터와 같은 조건이 되고, 남아 있던
// **present 페이싱**(스왑체인)도 이 경로에서 함께 확인된다.
//
// Java 코드는 0줄이다. NativeActivity 를 쓰면 매니페스트 선언만으로 네이티브 진입점이
// 잡히고, maru 의 "네이티브 최소" 정책과도 맞는다.
// `VK_USE_PLATFORM_ANDROID_KHR` 이 있어야 `vkCreateAndroidSurfaceKHR` 이 헤더에 노출된다 —
// 없으면 surface 생성 함수가 통째로 안 보인다.
// 선언은 `platform/mobile/mobile_host_abi.h` 가 단일 출처다 — 여기서 다시 적지 않는다.
#include "../mobile/mobile_host_abi.h"
#define VK_USE_PLATFORM_ANDROID_KHR
#include <android_native_app_glue.h>
#include <android/log.h>
#include <android/bitmap.h>
#include <android/choreographer.h>
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

#define PACE_WARMUP 20
#define PACE_SAMPLES 60

#define TAG "MaruChrome"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)



typedef struct { float rect_px[4]; float color[4]; float misc[4]; float cell[4]; } Push;

static struct {
    VkInstance inst;
    VkPhysicalDevice pd;
    VkDevice dev;
    VkQueue queue;
    uint32_t qf;
    VkSurfaceKHR surface;
    VkSwapchainKHR swap;
    VkFormat fmt;
    VkExtent2D extent;
    VkImageView *views;
    VkFramebuffer *fbs;
    uint32_t image_count;
    VkRenderPass rp;
    VkPipeline pipe;
    VkPipelineLayout layout;
    VkCommandPool pool;
    VkCommandBuffer *cbs;
    VkSemaphore acquire_sem, submit_sem;
    VkFence fence;
    VkImageView glyph_view, icon_view;
    VkImage glyph_image;   // 온디맨드 성장은 view 가 아니라 image 에 복사한다
    uint32_t glyph_w, glyph_h;
    VkDescriptorSet dset;
    uint32_t atlas_cols, atlas_rows;
    float scale;
    int inset_top, inset_bottom;
    int ready;
    int frames;
    double last_ms;
    double pace_ms[PACE_SAMPLES];
    int n_pace;
    int pace_done;
    // 페이싱 단계: 0=FIFO 자유 실행, 1=vsync 한 번 걸러(=30Hz 목표)
    int pace_phase;
    int64_t vsync_count;
} g;

// drawFrame 은 app 을 안 받는다 — 온디맨드 래스터가 JNI 를 쓰려면 필요해서 들고 있는다.
static struct android_app *g_app = NULL;
static void growAtlas(struct android_app *app);  // drawFrame 이 먼저라 선언이 필요하다
static uint8_t *g_glyph_px = NULL;
static uint32_t g_gw, g_gh;

// **기기에서 굽는다.** NDK 에는 폰트 래스터가 없지만(폰트 *탐색* API 인 `AFontMatcher` 뿐),
// JNI 로 `android.graphics.Paint`/`Canvas`/`Bitmap` 을 부르면 안드로이드 자체 폰트 스택으로
// 래스터할 수 있다 — iOS 의 CoreText 와 대응하는 자리다. 외부 라이브러리(FreeType 등) 없이
// 선다는 것이 이 함수가 확인하는 것이다.
//
// 좌표는 호스트 아틀라스와 같은 배치를 쓴다(행 r 의 baseline = r*CH + CH - 8) — 그래야
// 같은 셰이더가 두 아틀라스를 똑같이 샘플링한다.
static int rasterizeAtlasOnDevice(struct android_app *app, uint8_t **out, uint32_t *ow, uint32_t *oh) {
    // iOS 쪽과 같은 글자 집합.
    static const char *CHARS =
        "$ zig build test All 11 passed.git status --short"
        "M src/chrome/ui/tree.zigmaru 0.1.0 (arm64)zshvimlogswebdocsinfrascratch"
        "한글 터미널 세션 목록 설정 검색 알림";
    const uint32_t CW = 24, CH = 32, COLS = 16;

    // UTF-8 → BMP 코드포인트, 중복 제거.
    static uint16_t cps[256];
    uint32_t n = 0;
    for (const unsigned char *p = (const unsigned char *)CHARS; *p && n < 256;) {
        uint32_t cp;
        if (*p < 0x80) { cp = *p; p += 1; }
        else if ((*p & 0xE0) == 0xC0) { cp = ((*p & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
        else if ((*p & 0xF0) == 0xE0) { cp = ((*p & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
        else { p += 4; continue; }  // BMP 밖은 이 PoC 범위가 아니다
        int dup = 0;
        for (uint32_t i = 0; i < n; i++) if (cps[i] == cp) { dup = 1; break; }
        if (!dup) cps[n++] = (uint16_t)cp;
    }
    uint32_t rows = (n + COLS - 1) / COLS;
    uint32_t W = COLS * CW, H = rows * CH;

    JavaVM *vm = app->activity->vm;
    JNIEnv *env = NULL;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return 0;

    jclass bmCls = (*env)->FindClass(env, "android/graphics/Bitmap");
    jclass cfgCls = (*env)->FindClass(env, "android/graphics/Bitmap$Config");
    jobject cfg = (*env)->GetStaticObjectField(env, cfgCls,
        (*env)->GetStaticFieldID(env, cfgCls, "ALPHA_8", "Landroid/graphics/Bitmap$Config;"));
    jmethodID mCreate = (*env)->GetStaticMethodID(env, bmCls, "createBitmap",
        "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
    jobject bmp = (*env)->CallStaticObjectMethod(env, bmCls, mCreate, (jint)W, (jint)H, cfg);
    if (!bmp) { (*vm)->DetachCurrentThread(vm); return 0; }

    jclass cvCls = (*env)->FindClass(env, "android/graphics/Canvas");
    jobject canvas = (*env)->NewObject(env, cvCls,
        (*env)->GetMethodID(env, cvCls, "<init>", "(Landroid/graphics/Bitmap;)V"), bmp);
    jclass pCls = (*env)->FindClass(env, "android/graphics/Paint");
    jobject paint = (*env)->NewObject(env, pCls,
        (*env)->GetMethodID(env, pCls, "<init>", "(I)V"), (jint)1 /* ANTI_ALIAS_FLAG */);
    (*env)->CallVoidMethod(env, paint,
        (*env)->GetMethodID(env, pCls, "setTextSize", "(F)V"), (jfloat)22.0f);
    (*env)->CallVoidMethod(env, paint,
        (*env)->GetMethodID(env, pCls, "setColor", "(I)V"), (jint)0xFFFFFFFF);
    // **번들한 폰트를 쓴다.** maru 가 이미 `assets/fonts/` 에 OFL 폰트를 동봉하고 있고,
    // Jetendard 는 영문과 한글을 한 파일에 담아 폴백이 필요 없다 — iOS 와 **같은 파일**을
    // 읽으므로 글자 모양과 advance 가 플랫폼을 넘어 같아진다.
    jclass tfCls = (*env)->FindClass(env, "android/graphics/Typeface");
    jobject face = NULL;
    jstring fpath = (*env)->NewStringUTF(env, "/data/local/tmp/Jetendard-Regular.ttf");
    jmethodID mFromFile = (*env)->GetStaticMethodID(env, tfCls, "createFromFile",
        "(Ljava/lang/String;)Landroid/graphics/Typeface;");
    face = (*env)->CallStaticObjectMethod(env, tfCls, mFromFile, fpath);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); face = NULL; }
    if (!face) {  // 조용히 다른 글꼴이 되지 않게 남긴다
        LOGI("bundled_font_missing fallback=MONOSPACE");
        face = (*env)->GetStaticObjectField(env, tfCls,
            (*env)->GetStaticFieldID(env, tfCls, "MONOSPACE", "Landroid/graphics/Typeface;"));
    }
    (*env)->CallObjectMethod(env, paint,
        (*env)->GetMethodID(env, pCls, "setTypeface",
                            "(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;"), face);

    jmethodID mDraw = (*env)->GetMethodID(env, cvCls, "drawText",
        "(Ljava/lang/String;FFLandroid/graphics/Paint;)V");
    jmethodID mMeasure = (*env)->GetMethodID(env, pCls, "measureText", "(Ljava/lang/String;)F");

    maru_mobile_atlas_geometry(CW, CH);
    for (uint32_t i = 0; i < n; i++) {
        jstring s = (*env)->NewString(env, &cps[i], 1);
        uint32_t col = i % COLS, row = i / COLS;
        (*env)->CallVoidMethod(env, canvas, mDraw, s,
                               (jfloat)(col * CW + 1), (jfloat)(row * CH + CH - 8), paint);
        jfloat adv = (*env)->CallFloatMethod(env, paint, mMeasure, s);
        uint32_t advance = (uint32_t)(adv + 0.5f);
        if (advance == 0) advance = CW / 2;
        maru_mobile_atlas_add(cps[i], col, row, advance);
        (*env)->DeleteLocalRef(env, s);
    }

    void *pixels = NULL;
    AndroidBitmapInfo info;
    if (AndroidBitmap_getInfo(env, bmp, &info) != 0 ||
        AndroidBitmap_lockPixels(env, bmp, &pixels) != 0) {
        (*vm)->DetachCurrentThread(vm);
        return 0;
    }
    uint8_t *buf = malloc(W * H);
    for (uint32_t y = 0; y < H; y++)
        memcpy(buf + y * W, (uint8_t *)pixels + y * info.stride, W);
    AndroidBitmap_unlockPixels(env, bmp);
    (*vm)->DetachCurrentThread(vm);

    // 래스터 결과를 그대로 남긴다 — 두 플랫폼의 픽셀 차이를 재려면 원본이 필요하다.
    // 앱은 /data/local/tmp 에 못 쓴다(샌드박스) — 자기 내부 경로에 남기고 run-as 로 꺼낸다.
    char dump_path[512];
    snprintf(dump_path, sizeof dump_path, "%s/atlas_ondevice.gray",
             app->activity->internalDataPath ? app->activity->internalDataPath : "/data/local/tmp");
    FILE *df = fopen(dump_path, "wb");
    if (df) { fwrite(buf, 1, W * H, df); fclose(df); LOGI("atlas_dump=%s", dump_path); }

    *out = buf; *ow = W; *oh = H;
    g.atlas_cols = COLS;
    g.atlas_rows = rows;
    LOGI("atlas_ondevice=%ux%u glyphs=%u source=android.graphics.Paint", W, H, n);
    return 1;
}

// 아틀라스는 APK 의 asset 이 아니라 /data/local/tmp 에서 읽는다 — PoC 라 push 로 넣는다.
static void loadAtlas(void) {
    FILE *f = fopen("/data/local/tmp/atlas.idx", "r");
    if (!f) { LOGI("atlas_missing"); return; }
    uint32_t cw, ch, n;
    if (fscanf(f, "%u %u %u %u %u", &g_gw, &g_gh, &cw, &ch, &n) != 5) { fclose(f); return; }
    g.atlas_cols = g_gw / cw;
    g.atlas_rows = g_gh / ch;
    maru_mobile_atlas_geometry(cw, ch);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t cp, col, row, adv;
        if (fscanf(f, "%u %u %u %u", &cp, &col, &row, &adv) != 4) break;
        maru_mobile_atlas_add(cp, col, row, adv);
    }
    fclose(f);
    FILE *gf = fopen("/data/local/tmp/atlas.gray", "rb");
    if (!gf) return;
    g_glyph_px = malloc(g_gw * g_gh);
    if (fread(g_glyph_px, 1, g_gw * g_gh, gf) != (size_t)(g_gw * g_gh)) { free(g_glyph_px); g_glyph_px = NULL; }
    fclose(gf);
    LOGI("atlas %ux%u cols=%u rows=%u", g_gw, g_gh, g.atlas_cols, g.atlas_rows);
}

static VkShaderModule loadSpv(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { LOGI("spv_missing=%s", path); return VK_NULL_HANDLE; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *buf = malloc(n);
    if (fread(buf, 1, n, f) != (size_t)n) { fclose(f); free(buf); return VK_NULL_HANDLE; }
    fclose(f);
    VkShaderModuleCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                   .codeSize = n, .pCode = buf};
    VkShaderModule m = VK_NULL_HANDLE;
    vkCreateShaderModule(g.dev, &ci, NULL, &m);
    free(buf);
    return m;
}

static int uploadTexture(const uint8_t *pixels, uint32_t w, uint32_t h, uint32_t bpp,
                         VkFormat fmt, VkImageView *outView, VkImage *outImage) {
    VkImageCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                            .format = fmt, .extent = {w, h, 1}, .mipLevels = 1, .arrayLayers = 1,
                            .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                            .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    VkImage img;
    if (vkCreateImage(g.dev, &ci, NULL, &img) != VK_SUCCESS) return 0;
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(g.dev, img, &mr);
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(g.pd, &mp);
    uint32_t mt = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((mr.memoryTypeBits & (1u << i)) &&
            (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { mt = i; break; }
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                .allocationSize = mr.size, .memoryTypeIndex = mt};
    VkDeviceMemory mem;
    if (vkAllocateMemory(g.dev, &mai, NULL, &mem) != VK_SUCCESS) return 0;
    vkBindImageMemory(g.dev, img, mem, 0);

    VkDeviceSize bytes = (VkDeviceSize)w * h * bpp;
    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = bytes,
                              .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
    VkBuffer stage;
    if (vkCreateBuffer(g.dev, &bci, NULL, &stage) != VK_SUCCESS) return 0;
    VkMemoryRequirements bmr; vkGetBufferMemoryRequirements(g.dev, stage, &bmr);
    uint32_t bmt = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        int want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((bmr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) { bmt = i; break; }
    }
    VkMemoryAllocateInfo bmai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 .allocationSize = bmr.size, .memoryTypeIndex = bmt};
    VkDeviceMemory bmem;
    if (vkAllocateMemory(g.dev, &bmai, NULL, &bmem) != VK_SUCCESS) return 0;
    vkBindBufferMemory(g.dev, stage, bmem, 0);
    void *map = NULL;
    vkMapMemory(g.dev, bmem, 0, VK_WHOLE_SIZE, 0, &map);
    memcpy(map, pixels, bytes);
    vkUnmapMemory(g.dev, bmem);

    VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                        .commandPool = g.pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                        .commandBufferCount = 1};
    VkCommandBuffer cb;
    vkAllocateCommandBuffers(g.dev, &cbai, &cb);
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                   .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    vkBeginCommandBuffer(cb, &bi);
    VkImageMemoryBarrier tb = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                               .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                               .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                               .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                               .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
                               .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
                               .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 1, &tb);
    VkBufferImageCopy region = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                .imageExtent = {w, h, 1}};
    vkCmdCopyBufferToImage(cb, stage, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    tb.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    tb.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    tb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    tb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                         0, 0, NULL, 0, NULL, 1, &tb);
    vkEndCommandBuffer(cb);
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    vkQueueSubmit(g.queue, 1, &si, VK_NULL_HANDLE);
    vkQueueWaitIdle(g.queue);

    VkImageViewCreateInfo ivci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
                                  .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = fmt,
                                  .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    if (outImage) *outImage = img;
    return vkCreateImageView(g.dev, &ivci, NULL, outView) == VK_SUCCESS;
}

static int initVulkan(ANativeWindow *win) {
    const char *iexts[] = {"VK_KHR_surface", "VK_KHR_android_surface"};
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                             .pApplicationName = "maru-chrome", .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
                                .enabledExtensionCount = 2, .ppEnabledExtensionNames = iexts};
    if (vkCreateInstance(&ici, NULL, &g.inst) != VK_SUCCESS) { LOGI("instance_fail"); return 0; }

    VkAndroidSurfaceCreateInfoKHR sci = {.sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR,
                                         .window = win};
    if (vkCreateAndroidSurfaceKHR(g.inst, &sci, NULL, &g.surface) != VK_SUCCESS) { LOGI("surface_fail"); return 0; }

    uint32_t pn = 0;
    vkEnumeratePhysicalDevices(g.inst, &pn, NULL);
    VkPhysicalDevice *pds = calloc(pn, sizeof(*pds));
    vkEnumeratePhysicalDevices(g.inst, &pn, pds);
    g.pd = pds[0];
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(g.pd, &props);
    LOGI("device=%s", props.deviceName);

    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(g.pd, &qn, NULL);
    VkQueueFamilyProperties *qs = calloc(qn, sizeof(*qs));
    vkGetPhysicalDeviceQueueFamilyProperties(g.pd, &qn, qs);
    for (uint32_t i = 0; i < qn; i++) {
        VkBool32 present = 0;
        vkGetPhysicalDeviceSurfaceSupportKHR(g.pd, i, g.surface, &present);
        if ((qs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) { g.qf = i; break; }
    }
    float prio = 1;
    const char *dexts[] = {"VK_KHR_swapchain"};
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                   .queueFamilyIndex = g.qf, .queueCount = 1, .pQueuePriorities = &prio};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
                              .enabledExtensionCount = 1, .ppEnabledExtensionNames = dexts};
    if (vkCreateDevice(g.pd, &dci, NULL, &g.dev) != VK_SUCCESS) { LOGI("device_fail"); return 0; }
    vkGetDeviceQueue(g.dev, g.qf, 0, &g.queue);

    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(g.pd, g.surface, &caps);
    g.extent = caps.currentExtent;
    uint32_t fn = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(g.pd, g.surface, &fn, NULL);
    VkSurfaceFormatKHR *fmts = calloc(fn, sizeof(*fmts));
    vkGetPhysicalDeviceSurfaceFormatsKHR(g.pd, g.surface, &fn, fmts);
    g.fmt = fmts[0].format;
    VkColorSpaceKHR cspace = fmts[0].colorSpace;

    // **present 페이싱**: FIFO 는 vsync 에 맞춘 프레젠트다(항상 지원 보장). 이것이 남아 있던
    // 여섯 번째 항목이고, 스왑체인이 있어야 판정할 수 있다.
    VkSwapchainCreateInfoKHR scci = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
                                     .surface = g.surface,
                                     .minImageCount = caps.minImageCount < 3 ? caps.minImageCount + 1 : caps.minImageCount,
                                     .imageFormat = g.fmt, .imageColorSpace = cspace,
                                     .imageExtent = g.extent, .imageArrayLayers = 1,
                                     .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                                     .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
                                     .preTransform = caps.currentTransform,
                                     .compositeAlpha = VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
                                     .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE};
    if (vkCreateSwapchainKHR(g.dev, &scci, NULL, &g.swap) != VK_SUCCESS) {
        scci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        if (vkCreateSwapchainKHR(g.dev, &scci, NULL, &g.swap) != VK_SUCCESS) { LOGI("swapchain_fail"); return 0; }
    }
    LOGI("swapchain %ux%u fifo", g.extent.width, g.extent.height);

    vkGetSwapchainImagesKHR(g.dev, g.swap, &g.image_count, NULL);
    VkImage *imgs = calloc(g.image_count, sizeof(*imgs));
    vkGetSwapchainImagesKHR(g.dev, g.swap, &g.image_count, imgs);
    g.views = calloc(g.image_count, sizeof(VkImageView));
    for (uint32_t i = 0; i < g.image_count; i++) {
        VkImageViewCreateInfo ivci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = imgs[i],
                                      .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = g.fmt,
                                      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
        vkCreateImageView(g.dev, &ivci, NULL, &g.views[i]);
    }

    VkAttachmentDescription att = {.format = g.fmt, .samples = VK_SAMPLE_COUNT_1_BIT,
                                   .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                                   .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                   .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                                   .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                                   .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR};
    VkAttachmentReference ar = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sp = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                               .colorAttachmentCount = 1, .pColorAttachments = &ar};
    VkRenderPassCreateInfo rpci = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
                                   .attachmentCount = 1, .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sp};
    vkCreateRenderPass(g.dev, &rpci, NULL, &g.rp);

    g.fbs = calloc(g.image_count, sizeof(VkFramebuffer));
    for (uint32_t i = 0; i < g.image_count; i++) {
        VkFramebufferCreateInfo fbci = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = g.rp,
                                        .attachmentCount = 1, .pAttachments = &g.views[i],
                                        .width = g.extent.width, .height = g.extent.height, .layers = 1};
        vkCreateFramebuffer(g.dev, &fbci, NULL, &g.fbs[i]);
    }

    VkCommandPoolCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                    .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                                    .queueFamilyIndex = g.qf};
    vkCreateCommandPool(g.dev, &cpci, NULL, &g.pool);
    g.cbs = calloc(g.image_count, sizeof(VkCommandBuffer));
    VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                        .commandPool = g.pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                        .commandBufferCount = g.image_count};
    vkAllocateCommandBuffers(g.dev, &cbai, g.cbs);

    // 텍스처: 글리프(호스트 아틀라스) + 아이콘(Zig 가 만든 coverage)
    if (g_glyph_px) {
        uploadTexture(g_glyph_px, g_gw, g_gh, 1, VK_FORMAT_R8_UNORM, &g.glyph_view, &g.glyph_image);
        g.glyph_w = g_gw; g.glyph_h = g_gh;
    }
    uint32_t filled = maru_mobile_icon_build();
    uint32_t slot = maru_mobile_icon_slot_px(), cnt = maru_mobile_icon_count();
    uploadTexture(maru_mobile_icon_atlas(), slot, slot * cnt, 4, VK_FORMAT_R8G8B8A8_UNORM, &g.icon_view, NULL);
    LOGI("icons filled=%u/%u", filled, cnt);

    VkSamplerCreateInfo sampci = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                                  .magFilter = VK_FILTER_LINEAR, .minFilter = VK_FILTER_LINEAR};
    VkSampler samp; vkCreateSampler(g.dev, &sampci, NULL, &samp);
    VkDescriptorSetLayoutBinding binds[2] = {
        {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT},
        {.binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT}};
    VkDescriptorSetLayoutCreateInfo dslci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                             .bindingCount = 2, .pBindings = binds};
    VkDescriptorSetLayout dsl; vkCreateDescriptorSetLayout(g.dev, &dslci, NULL, &dsl);
    VkDescriptorPoolSize dps = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2};
    VkDescriptorPoolCreateInfo dpci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                                       .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &dps};
    VkDescriptorPool dpool; vkCreateDescriptorPool(g.dev, &dpci, NULL, &dpool);
    VkDescriptorSetAllocateInfo dsai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                                        .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl};
    vkAllocateDescriptorSets(g.dev, &dsai, &g.dset);
    VkDescriptorImageInfo dii[2] = {
        {samp, g.glyph_view ? g.glyph_view : g.icon_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
        {samp, g.icon_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL}};
    VkWriteDescriptorSet wds[2] = {
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = g.dset, .dstBinding = 0,
         .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii[0]},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = g.dset, .dstBinding = 1,
         .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii[1]}};
    vkUpdateDescriptorSets(g.dev, 2, wds, 0, NULL);

    VkPushConstantRange pcr = {VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(Push)};
    VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                                       .setLayoutCount = 1, .pSetLayouts = &dsl,
                                       .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr};
    vkCreatePipelineLayout(g.dev, &plci, NULL, &g.layout);

    VkShaderModule vs = loadSpv("/data/local/tmp/chrome.vert.spv");
    VkShaderModule fs = loadSpv("/data/local/tmp/chrome.frag.spv");
    if (!vs || !fs) return 0;
    VkPipelineShaderStageCreateInfo st[2] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main"}};
    VkPipelineVertexInputStateCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo ia = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                                                 .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP};
    VkPipelineViewportStateCreateInfo vp = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                                            .viewportCount = 1, .scissorCount = 1};
    VkPipelineRasterizationStateCreateInfo rs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                                                 .polygonMode = VK_POLYGON_MODE_FILL,
                                                 .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1};
    VkPipelineMultisampleStateCreateInfo ms = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                                               .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
    VkPipelineColorBlendAttachmentState ba = {.blendEnable = VK_TRUE,
                                              .srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA,
                                              .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                                              .colorBlendOp = VK_BLEND_OP_ADD,
                                              .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
                                              .dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO,
                                              .alphaBlendOp = VK_BLEND_OP_ADD, .colorWriteMask = 0xF};
    VkPipelineColorBlendStateCreateInfo cbs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                                               .attachmentCount = 1, .pAttachments = &ba};
    VkDynamicState dyn[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo ds = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
                                           .dynamicStateCount = 2, .pDynamicStates = dyn};
    VkGraphicsPipelineCreateInfo gp = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                                       .stageCount = 2, .pStages = st, .pVertexInputState = &vi,
                                       .pInputAssemblyState = &ia, .pViewportState = &vp,
                                       .pRasterizationState = &rs, .pMultisampleState = &ms,
                                       .pColorBlendState = &cbs, .pDynamicState = &ds,
                                       .layout = g.layout, .renderPass = g.rp};
    if (vkCreateGraphicsPipelines(g.dev, VK_NULL_HANDLE, 1, &gp, NULL, &g.pipe) != VK_SUCCESS) {
        LOGI("pipeline_fail"); return 0;
    }

    VkSemaphoreCreateInfo semci = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    vkCreateSemaphore(g.dev, &semci, NULL, &g.acquire_sem);
    vkCreateSemaphore(g.dev, &semci, NULL, &g.submit_sem);
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    vkCreateFence(g.dev, &fci, NULL, &g.fence);
    g.ready = 1;
    return 1;
}

static void drawFrame(void) {
    if (!g.ready) return;
    uint32_t idx = 0;
    if (vkAcquireNextImageKHR(g.dev, g.swap, UINT64_MAX, g.acquire_sem, VK_NULL_HANDLE, &idx) != VK_SUCCESS) return;

    // **레이아웃은 Zig chrome 이 한다.** 플랫폼은 쓸 수 있는 크기만 넘기고 quad 를 받는다.
    //
    // 스케일을 상수로 박으면 안 된다 — 기기 density 를 써야 iOS 의 논리 좌표와 같은
    // 밀도가 된다(420dpi = 2.625배 → 411x914 로 iOS 402x874 와 거의 같다. 2.0 으로
    // 박았을 때는 540x1200 이 되어 레이아웃이 화면 위쪽만 채웠다).
    float scale = g.scale;
    // 상태바·제스처바를 뺀 영역만 준다 — iOS 의 safeAreaInsets 와 같은 자리다.
    unsigned int lw = (unsigned int)(g.extent.width / scale);
    unsigned int lh = (unsigned int)((g.extent.height - g.inset_top - g.inset_bottom) / scale);
    unsigned int n = maru_mobile_build(lw, lh);
    // build 가 못 그린 글자를 그 슬롯에만 구워 넣는다 — 다음 프레임에 보인다.
    if (g_app) growAtlas(g_app);
    const MaruQuad *quads = maru_mobile_quads();
    if (g.frames == 0) LOGI("quads=%u err=%s logical=%ux%u", n, maru_mobile_last_error(), lw, lh);

    VkCommandBuffer cb = g.cbs[idx];
    vkResetCommandBuffer(cb, 0);
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                   .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    vkBeginCommandBuffer(cb, &bi);
    VkClearValue cv = {.color = {{0.05f, 0.05f, 0.06f, 1.0f}}};
    VkRenderPassBeginInfo rbi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = g.rp,
                                 .framebuffer = g.fbs[idx], .renderArea = {{0, 0}, g.extent},
                                 .clearValueCount = 1, .pClearValues = &cv};
    vkCmdBeginRenderPass(cb, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport vpt = {0, 0, (float)g.extent.width, (float)g.extent.height, 0, 1};
    vkCmdSetViewport(cb, 0, 1, &vpt);
    VkRect2D sc = {{0, 0}, g.extent};
    vkCmdSetScissor(cb, 0, 1, &sc);
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, g.pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, g.layout, 0, 1, &g.dset, 0, NULL);
    for (unsigned int i = 0; i < n; i++) {
        const MaruQuad *q = &quads[i];
        float cols = (q->kind == 2) ? 1.0f : (float)g.atlas_cols;
        float rows = (q->kind == 2) ? (float)maru_mobile_icon_count() : (float)g.atlas_rows;
        float oy = (float)g.inset_top;
        Push p = {{q->x * scale, q->y * scale + oy, (q->x + q->w) * scale, (q->y + q->h) * scale + oy},
                  {q->r, q->g, q->b, q->a},
                  {q->radius * scale, (float)g.extent.width, (float)g.extent.height, (float)q->kind},
                  {(float)q->cell_x, (float)q->cell_y, cols, rows}};
        vkCmdPushConstants(cb, g.layout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, sizeof p, &p);
        vkCmdDraw(cb, 4, 1, 0, 0);
    }
    vkCmdEndRenderPass(cb);
    vkEndCommandBuffer(cb);

    VkPipelineStageFlags wait = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1,
                       .pWaitSemaphores = &g.acquire_sem, .pWaitDstStageMask = &wait,
                       .commandBufferCount = 1, .pCommandBuffers = &cb,
                       .signalSemaphoreCount = 1, .pSignalSemaphores = &g.submit_sem};
    vkQueueSubmit(g.queue, 1, &si, g.fence);
    VkPresentInfoKHR pi = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1,
                           .pWaitSemaphores = &g.submit_sem, .swapchainCount = 1,
                           .pSwapchains = &g.swap, .pImageIndices = &idx};
    vkQueuePresentKHR(g.queue, &pi);
    vkWaitForFences(g.dev, 1, &g.fence, VK_TRUE, UINT64_MAX);
    vkResetFences(g.dev, 1, &g.fence);

    // **present 페이싱은 재서 판정한다.** FIFO 모드를 골랐다는 사실은 근거가 못 된다 —
    // 실제 프레젠트 간격의 중앙값을 봐야 vsync 에 물렸는지 알 수 있다. iOS 쪽도 같은
    // 기준(표시 클럭 간격의 중앙값)으로 판정한다.
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
    if (g.frames >= PACE_WARMUP && g.last_ms > 0 && g.n_pace < PACE_SAMPLES)
        g.pace_ms[g.n_pace++] = now - g.last_ms;
    g.last_ms = now;
    if (g.n_pace == PACE_SAMPLES) {
        for (int i = 1; i < PACE_SAMPLES; i++) {
            double k = g.pace_ms[i]; int j = i - 1;
            while (j >= 0 && g.pace_ms[j] > k) { g.pace_ms[j + 1] = g.pace_ms[j]; j--; }
            g.pace_ms[j + 1] = k;
        }
        double med = g.pace_ms[PACE_SAMPLES / 2];
        if (g.pace_phase == 0) {
            LOGI("MARU_PACE fifo_median_ms=%.2f n=%d", med, PACE_SAMPLES);
            // 다음 단계: **하위 주기**. Vulkan 에는 "30Hz 모드"가 없어 앱이 직접 맞춘다 —
            // AChoreographer 로 vsync 를 받아 한 번 걸러 present 한다.
            g.pace_phase = 1;
            g.n_pace = 0;
            g.last_ms = 0;
        } else if (!g.pace_done) {
            g.pace_done = 1;
            int paced = (med >= 25.0 && med <= 42.0);
            LOGI("MARU_PACE half_rate_median_ms=%.2f n=%d target=33.33 verdict=%s",
                 med, PACE_SAMPLES, paced ? "PASS" : "FAIL");
        }
    }
    g.frames++;
}

// 상태바·제스처바 밑으로 UI 가 깔리지 않게 **실제 inset** 을 받아 온다. NDK 에는 inset
// API 가 없어서 JNI 로 `View.getRootWindowInsets()` 를 부른다 — iOS 의 `safeAreaInsets`
// 와 같은 자리다. 값을 못 얻으면 0 으로 두고 진행한다(그리기를 막을 이유는 없다).
static void queryInsets(struct android_app *app, int *top, int *bottom) {
    *top = 0; *bottom = 0;
    JavaVM *vm = app->activity->vm;
    JNIEnv *env = NULL;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return;
    jobject act = app->activity->clazz;
    jclass actCls = (*env)->GetObjectClass(env, act);
    jmethodID mWin = (*env)->GetMethodID(env, actCls, "getWindow", "()Landroid/view/Window;");
    jobject win = (*env)->CallObjectMethod(env, act, mWin);
    jclass winCls = (*env)->GetObjectClass(env, win);
    jmethodID mDecor = (*env)->GetMethodID(env, winCls, "getDecorView", "()Landroid/view/View;");
    jobject decor = (*env)->CallObjectMethod(env, win, mDecor);
    jclass viewCls = (*env)->GetObjectClass(env, decor);
    jmethodID mRoot = (*env)->GetMethodID(env, viewCls, "getRootWindowInsets", "()Landroid/view/WindowInsets;");
    jobject ins = (*env)->CallObjectMethod(env, decor, mRoot);
    if (!ins) { (*vm)->DetachCurrentThread(vm); return; }
    jclass typeCls = (*env)->FindClass(env, "android/view/WindowInsets$Type");
    jmethodID mBars = (*env)->GetStaticMethodID(env, typeCls, "systemBars", "()I");
    jint mask = (*env)->CallStaticIntMethod(env, typeCls, mBars);
    jclass insCls = (*env)->GetObjectClass(env, ins);
    jmethodID mGet = (*env)->GetMethodID(env, insCls, "getInsets", "(I)Landroid/graphics/Insets;");
    jobject box = (*env)->CallObjectMethod(env, ins, mGet, mask);
    if (box) {
        jclass boxCls = (*env)->GetObjectClass(env, box);
        *top = (*env)->GetIntField(env, box, (*env)->GetFieldID(env, boxCls, "top", "I"));
        *bottom = (*env)->GetIntField(env, box, (*env)->GetFieldID(env, boxCls, "bottom", "I"));
    }
    (*vm)->DetachCurrentThread(vm);
}

// **입력**: NativeActivity 가 받은 키를 바이트로 바꿔 코어에 먹인다.
//
// NDK 는 keycode 만 주고 문자 매핑은 Java `KeyCharacterMap` 에 있다. PoC 는 그 왕복을
// 하지 않고 ASCII 구간만 표로 옮긴다 — 확인하려는 것은 "OS 키 이벤트가 코어까지 닿는가"
// 이지 자판 배열 전체가 아니다. 실제 제품은 KeyCharacterMap(또는 IME)을 거쳐야 한다.
static char keycodeToAscii(int32_t kc, int32_t meta) {
    if (kc >= AKEYCODE_A && kc <= AKEYCODE_Z) {
        char base = (char)('a' + (kc - AKEYCODE_A));
        int shift = (meta & (AMETA_SHIFT_ON | AMETA_SHIFT_LEFT_ON | AMETA_SHIFT_RIGHT_ON)) != 0;
        return shift ? (char)(base - 32) : base;
    }
    if (kc >= AKEYCODE_0 && kc <= AKEYCODE_9) return (char)('0' + (kc - AKEYCODE_0));
    switch (kc) {
        case AKEYCODE_SPACE: return ' ';
        case AKEYCODE_ENTER: return '\r';
        case AKEYCODE_PERIOD: return '.';
        case AKEYCODE_MINUS: return '-';
        case AKEYCODE_SLASH: return '/';
        default: return 0;
    }
}

static int32_t onInputEvent(struct android_app *app, AInputEvent *ev) {
    (void)app;
    // **터치**: 누른 지점을 셀 좌표로 바꿔 조회한다. iOS `touchesBegan:` 과 같은 자리이고,
    // 좌표계 환산도 같다 — 물리 px 를 density 로 나누고 상태바 inset 을 뺀 **논리 좌표**로
    // 되돌려야 셀이 안 어긋난다(그 값은 렌더가 쓴 것과 같은 변수에서 나온다).
    if (AInputEvent_getType(ev) == AINPUT_EVENT_TYPE_MOTION) {
        int32_t action = AMotionEvent_getAction(ev) & AMOTION_EVENT_ACTION_MASK;
        if (action != AMOTION_EVENT_ACTION_DOWN) return 0;
        float px = AMotionEvent_getX(ev, 0), py = AMotionEvent_getY(ev, 0);
        float lx = px / g.scale;
        float ly = (py - (float)g.inset_top) / g.scale;
        unsigned int cell = maru_mobile_hit_cell(lx, ly);
        LOGI("MARU_TOUCH pt=(%.0f,%.0f) logical=(%.0f,%.0f) cell=(%u,%u)",
             px, py, lx, ly, cell >> 16, cell & 0xFFFF);
        return 1;
    }
    if (AInputEvent_getType(ev) != AINPUT_EVENT_TYPE_KEY) return 0;
    if (AKeyEvent_getAction(ev) != AKEY_EVENT_ACTION_DOWN) return 0;
    char c = keycodeToAscii(AKeyEvent_getKeyCode(ev), AKeyEvent_getMetaState(ev));
    if (!c) return 0;
    unsigned int total = maru_mobile_input(&c, 1);
    LOGI("MARU_INPUT keycode=%d byte=0x%02x total=%u",
         AKeyEvent_getKeyCode(ev), (unsigned char)c, total);
    return 1;
}

// **생명주기**: 홈으로 나가면 창이 죽는다(APP_CMD_TERM_WINDOW). 그때 스왑체인을 그대로
// 들고 있으면 죽은 surface 로 present 하게 된다 — 되돌아왔을 때 다시 세워야 한다.
// iOS 는 UIKit 이 레이어를 살려 두지만 Android 는 창 자체가 사라져서 이 처리가 필수다.
static void teardownVulkan(void) {
    if (!g.dev) return;
    vkDeviceWaitIdle(g.dev);
    for (uint32_t i = 0; i < g.image_count; i++) {
        if (g.fbs) vkDestroyFramebuffer(g.dev, g.fbs[i], NULL);
        if (g.views) vkDestroyImageView(g.dev, g.views[i], NULL);
    }
    free(g.fbs); free(g.views); free(g.cbs);
    g.fbs = NULL; g.views = NULL; g.cbs = NULL;
    if (g.swap) vkDestroySwapchainKHR(g.dev, g.swap, NULL);
    vkDestroyDevice(g.dev, NULL);
    if (g.surface) vkDestroySurfaceKHR(g.inst, g.surface, NULL);
    if (g.inst) vkDestroyInstance(g.inst, NULL);
    // 페이싱 계측과 화면 설정은 살린다 — 재개 후에도 같은 상태로 이어져야 한다.
    float scale = g.scale;
    int it = g.inset_top, ib = g.inset_bottom;
    uint32_t ac = g.atlas_cols, ar = g.atlas_rows;
    memset(&g, 0, sizeof g);
    g.scale = scale; g.inset_top = it; g.inset_bottom = ib;
    g.atlas_cols = ac; g.atlas_rows = ar;
    LOGI("MARU_LIFECYCLE window_destroyed vulkan_torn_down");
}

// 한 글자를 셀 크기 버퍼에 굽는다. 아틀라스를 처음 만들 때와 **같은 폰트·같은 배치**를
// 써야 새로 넣은 글리프가 기존 것과 어긋나지 않는다(baseline = CH-8).
static int rasterizeOneGlyph(struct android_app *app, uint32_t cp, uint8_t *out,
                             uint32_t CW, uint32_t CH, uint32_t *advance) {
    JavaVM *vm = app->activity->vm;
    JNIEnv *env = NULL;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return 0;
    int ok = 0;
    jclass bmCls = (*env)->FindClass(env, "android/graphics/Bitmap");
    jclass cfgCls = (*env)->FindClass(env, "android/graphics/Bitmap$Config");
    jobject cfg = (*env)->GetStaticObjectField(env, cfgCls,
        (*env)->GetStaticFieldID(env, cfgCls, "ALPHA_8", "Landroid/graphics/Bitmap$Config;"));
    jobject bmp = (*env)->CallStaticObjectMethod(env, bmCls,
        (*env)->GetStaticMethodID(env, bmCls, "createBitmap",
            "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;"),
        (jint)CW, (jint)CH, cfg);
    if (bmp) {
        jclass cvCls = (*env)->FindClass(env, "android/graphics/Canvas");
        jobject canvas = (*env)->NewObject(env, cvCls,
            (*env)->GetMethodID(env, cvCls, "<init>", "(Landroid/graphics/Bitmap;)V"), bmp);
        jclass pCls = (*env)->FindClass(env, "android/graphics/Paint");
        jobject paint = (*env)->NewObject(env, pCls,
            (*env)->GetMethodID(env, pCls, "<init>", "(I)V"), (jint)1);
        (*env)->CallVoidMethod(env, paint,
            (*env)->GetMethodID(env, pCls, "setTextSize", "(F)V"), (jfloat)22.0f);
        (*env)->CallVoidMethod(env, paint,
            (*env)->GetMethodID(env, pCls, "setColor", "(I)V"), (jint)0xFFFFFFFF);
        jclass tfCls = (*env)->FindClass(env, "android/graphics/Typeface");
        jobject face = (*env)->CallStaticObjectMethod(env, tfCls,
            (*env)->GetStaticMethodID(env, tfCls, "createFromFile",
                "(Ljava/lang/String;)Landroid/graphics/Typeface;"),
            (*env)->NewStringUTF(env, "/data/local/tmp/Jetendard-Regular.ttf"));
        if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); face = NULL; }
        if (face) (*env)->CallObjectMethod(env, paint,
            (*env)->GetMethodID(env, pCls, "setTypeface",
                "(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;"), face);
        jchar unit = (jchar)cp;
        jstring s = (*env)->NewString(env, &unit, 1);
        (*env)->CallVoidMethod(env, canvas,
            (*env)->GetMethodID(env, cvCls, "drawText", "(Ljava/lang/String;FFLandroid/graphics/Paint;)V"),
            s, (jfloat)1.0f, (jfloat)(CH - 8), paint);
        jfloat adv = (*env)->CallFloatMethod(env, paint,
            (*env)->GetMethodID(env, pCls, "measureText", "(Ljava/lang/String;)F"), s);
        *advance = (uint32_t)(adv + 0.5f);
        if (*advance == 0) *advance = CW / 2;
        void *pixels = NULL;
        AndroidBitmapInfo info;
        if (AndroidBitmap_getInfo(env, bmp, &info) == 0 &&
            AndroidBitmap_lockPixels(env, bmp, &pixels) == 0) {
            for (uint32_t y = 0; y < CH; y++)
                memcpy(out + y * CW, (uint8_t *)pixels + y * info.stride, CW);
            AndroidBitmap_unlockPixels(env, bmp);
            ok = 1;
        }
        (*env)->DeleteLocalRef(env, s);
    }
    (*vm)->DetachCurrentThread(vm);
    return ok;
}

// **아틀라스를 키운다.** 텍스처를 다시 만들지 않고 그 셀 자리에만 복사한다 —
// 아틀라스 부분 업데이트(여섯 기능 4번)를 그대로 쓴다. iOS `replaceRegion:` 과 같은 자리다.
static void growAtlas(struct android_app *app) {
    unsigned int n = maru_mobile_missing_count();
    if (n == 0 || !g.glyph_image || !g.dev) return;
    const uint32_t CW = 24, CH = 32;
    uint8_t cell[24 * 32];
    unsigned int added = 0;
    for (unsigned int i = 0; i < n; i++) {
        unsigned int cp = maru_mobile_missing_cp(i);
        if (cp == 0 || cp > 0xFFFF) continue;
        unsigned int slot = maru_mobile_next_slot(g.atlas_cols);
        uint32_t col = slot >> 16, row = slot & 0xFFFF;
        if (row >= g.atlas_rows) break;  // 꽉 찼다 — 축출은 이 PoC 범위 밖이다
        memset(cell, 0, sizeof cell);
        uint32_t advance = CW / 2;
        if (!rasterizeOneGlyph(app, cp, cell, CW, CH, &advance)) continue;

        // staging 버퍼 → 이미지의 그 사각형만 복사.
        VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                                  .size = sizeof cell, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
        VkBuffer stage;
        if (vkCreateBuffer(g.dev, &bci, NULL, &stage) != VK_SUCCESS) continue;
        VkMemoryRequirements mr; vkGetBufferMemoryRequirements(g.dev, stage, &mr);
        VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(g.pd, &mp);
        uint32_t mt = UINT32_MAX;
        for (uint32_t k = 0; k < mp.memoryTypeCount; k++) {
            int want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
            if ((mr.memoryTypeBits & (1u << k)) && (mp.memoryTypes[k].propertyFlags & want) == want) { mt = k; break; }
        }
        VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                    .allocationSize = mr.size, .memoryTypeIndex = mt};
        VkDeviceMemory mem;
        if (vkAllocateMemory(g.dev, &mai, NULL, &mem) != VK_SUCCESS) { vkDestroyBuffer(g.dev, stage, NULL); continue; }
        vkBindBufferMemory(g.dev, stage, mem, 0);
        void *map = NULL;
        vkMapMemory(g.dev, mem, 0, VK_WHOLE_SIZE, 0, &map);
        memcpy(map, cell, sizeof cell);
        vkUnmapMemory(g.dev, mem);

        VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                            .commandPool = g.pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                            .commandBufferCount = 1};
        VkCommandBuffer cb;
        vkAllocateCommandBuffers(g.dev, &cbai, &cb);
        VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                       .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
        vkBeginCommandBuffer(cb, &bi);
        // 이미 셰이더가 읽는 레이아웃이라 transfer 로 내렸다가 되돌린다.
        VkImageMemoryBarrier tb = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                                   .oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                   .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                   .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                   .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                   .image = g.glyph_image,
                                   .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
                                   .srcAccessMask = VK_ACCESS_SHADER_READ_BIT,
                                   .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT};
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, NULL, 0, NULL, 1, &tb);
        VkBufferImageCopy region = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                    .imageOffset = {(int32_t)(col * CW), (int32_t)(row * CH), 0},
                                    .imageExtent = {CW, CH, 1}};
        vkCmdCopyBufferToImage(cb, stage, g.glyph_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        tb.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        tb.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        tb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        tb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             0, 0, NULL, 0, NULL, 1, &tb);
        vkEndCommandBuffer(cb);
        VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
        vkQueueSubmit(g.queue, 1, &si, VK_NULL_HANDLE);
        vkQueueWaitIdle(g.queue);
        vkFreeCommandBuffers(g.dev, g.pool, 1, &cb);
        vkDestroyBuffer(g.dev, stage, NULL);
        vkFreeMemory(g.dev, mem, NULL);

        maru_mobile_atlas_add(cp, col, row, advance);
        added++;
    }
    maru_mobile_missing_clear();
    if (added) LOGI("MARU_ATLAS grew=%u", added);
}

static void onAppCmd(struct android_app *app, int32_t cmd) {
    if (cmd == APP_CMD_TERM_WINDOW) {
        teardownVulkan();
        return;
    }
    if (cmd == APP_CMD_INIT_WINDOW && app->window && g.ready) return;  // 이미 서 있으면 그대로
    if (cmd == APP_CMD_INIT_WINDOW && app->window) {
        int32_t dpi = AConfiguration_getDensity(app->config);
        g.scale = (dpi > 0 && dpi != ACONFIGURATION_DENSITY_ANY &&
                   dpi != ACONFIGURATION_DENSITY_NONE) ? (float)dpi / 160.0f : 2.0f;
        queryInsets(app, &g.inset_top, &g.inset_bottom);
        LOGI("density=%d scale=%.3f inset top=%d bottom=%d", dpi, g.scale, g.inset_top, g.inset_bottom);
        // 기기 래스터가 서면 push 한 호스트 아틀라스는 아예 안 읽는다.
        if (!g_glyph_px && !rasterizeAtlasOnDevice(app, &g_glyph_px, &g_gw, &g_gh)) loadAtlas();
        if (initVulkan(app->window)) LOGI("MARU_LIFECYCLE vulkan_ready frames_reset");
    }
}

// vsync 마다 불린다. **한 번 걸러** 그려서 30Hz 를 만든다 — Vulkan present mode 에는
// 하위 주기 선택지가 없으므로(FIFO/MAILBOX/IMMEDIATE 는 전부 "언제"지 "얼마나 자주"가
// 아니다) 주기는 앱이 정한다. iOS 의 `preferredFrameRateRange` 에 대응하는 자리다.
static void frameCallback(int64_t frame_time_ns, void *data) {
    (void)frame_time_ns;
    g.vsync_count++;
    if ((g.vsync_count & 1) == 0) drawFrame();
    AChoreographer_postFrameCallback64(AChoreographer_getInstance(), frameCallback, data);
}

void android_main(struct android_app *app) {
    g_app = app;
    app->onAppCmd = onAppCmd;
    app->onInputEvent = onInputEvent;
    int chor_started = 0;
    while (1) {
        int events;
        struct android_poll_source *source;
        while (ALooper_pollOnce(g.ready ? 0 : -1, NULL, &events, (void **)&source) >= 0) {
            if (source) source->process(app, source);
            if (app->destroyRequested) return;
        }
        if (g.pace_phase == 1) {
            // 이 단계부터는 루프가 직접 그리지 않는다 — vsync 콜백이 주기를 쥔다.
            if (!chor_started) {
                chor_started = 1;
                AChoreographer_postFrameCallback64(AChoreographer_getInstance(), frameCallback, app);
            }
            continue;
        }
        drawFrame();
    }
}
