// Android host (L4). NativeActivity 창·생명주기·터치 + Vulkan 백엔드 + JNI Paint 래스터.
//
// **플랫폼은 배치를 모른다** — Zig 가 낸 quad 를 그리기만 한다(L3 chrome 이 배치,
// L4 platform 이 그리기). IME 만 Java shim(`MaruActivity.java`)이 받는다: NDK 에는
// `InputConnection` 에 해당하는 것이 없어 한글 조합을 받을 수 없다.
// 계약은 docs/mobile-platform.md 가 단일 출처다.
// 선언은 `platform/mobile/mobile_host_abi.h` 가 단일 출처다 — 여기서 다시 적지 않는다.
#include "../mobile/mobile_host_abi.h"
#define VK_USE_PLATFORM_ANDROID_KHR
#include <android_native_app_glue.h>
#include <android/log.h>
#include <android/bitmap.h>
#include <android/asset_manager.h>
#include <sys/system_properties.h>
#include <jni.h>
#include <android/choreographer.h>
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <pthread.h>

// **입력과 렌더가 다른 스레드다.** IME 는 Java UI 스레드에서 `InputConnection` 으로 오고
// (실측 tid 14832), 그리는 쪽은 NativeActivity 가 만든 스레드다(tid 14850). 브리지의
// `TerminalCore`·preedit·오류 문자열을 그 둘이 동기화 없이 만지고 있었다.
//
// **자물쇠는 여기가 갖는다.** 브리지는 OS 를 모르는 자리이고(docs/mobile-platform.md §3),
// 스레드가 둘이라는 사실은 이 플랫폼의 것이다. iOS 는 UIKit 이 둘 다 main 에서 부르므로
// 이 문제가 없다 — 대칭이 아니라 사정이 다른 것이고, 그 차이를 여기 적어 둔다.
static pthread_mutex_t g_bridge_lock = PTHREAD_MUTEX_INITIALIZER;

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
    VkImage glyph_image, icon_image;   // 온디맨드 성장은 view 가 아니라 image 에 복사한다
    VkDeviceMemory glyph_mem, icon_mem;
    VkSampler sampler;
    VkDescriptorSetLayout dsl;
    VkDescriptorPool dpool;
    uint32_t glyph_w, glyph_h;
    // 창이 리사이즈되면 스왑체인을 다시 만들어야 한다. 안 그러면 화면이 영구히 언다.
    int needs_recreate;

    VkDescriptorSet dset;
    VkBuffer quad_buf;        // draw-list 를 통째로 올리는 자리
    VkDeviceMemory quad_mem;
    void *quad_map;           // persistent map — 프레임마다 memcpy 만 한다
    unsigned int quad_cap;
    uint32_t atlas_cols, atlas_rows;
    float scale;
    int inset_top, inset_bottom;
    int ready;
    int frames;
    double last_ms;
    double pace_ms[PACE_SAMPLES];
    int n_pace;
    int pace_done;
    int64_t vsync_count;
} g;

// drawFrame 은 app 을 안 받는다 — 온디맨드 래스터가 JNI 를 쓰려면 필요해서 들고 있는다.
// **`g` 밖에 둔다.** teardown 이 `g` 를 memset 하므로 안에 두면 재개할 때마다 새 체인을
// 걸고, 이미 떠 있던 체인은 스스로 다시 등록하며 살아남는다 — 왕복할수록 체인이 늘어
// **프레임 주기가 배로 빨라진다**(실측: 3회 왕복에 33.4ms → 16.7ms).
// 체인은 앱 수명 동안 하나면 된다. 창이 없을 때는 drawFrame 이 알아서 쉰다.
static int g_chor_started = 0;
static struct android_app *g_app = NULL;
static void growAtlas(struct android_app *app);  // drawFrame 이 먼저라 선언이 필요하다
static void recreateVulkan(struct android_app *app);
static void frameCallback(int64_t frame_time_ns, void *data);  // onAppCmd 가 먼저라 선언이 필요하다
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
    static const char *CHARS = MARU_ATLAS_PREBAKE;   // 집합은 공용 헤더가 소유한다
    const uint32_t CW = MARU_ATLAS_CELL_W, CH = MARU_ATLAS_CELL_H, COLS = maru_mobile_atlas_cols();

    // UTF-8 → BMP 코드포인트, 중복 제거.
    static uint16_t cps[256];
    uint32_t n = 0;
    for (const unsigned char *p = (const unsigned char *)CHARS; *p && n < 256;) {
        uint32_t cp;
        if (*p < 0x80) { cp = *p; p += 1; }
        else if ((*p & 0xE0) == 0xC0) { cp = ((*p & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
        else if ((*p & 0xF0) == 0xE0) { cp = ((*p & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
        else { p += 4; continue; }  // BMP 밖은 아직 안 다룬다
        int dup = 0;
        for (uint32_t i = 0; i < n; i++) if (cps[i] == cp) { dup = 1; break; }
        if (!dup) cps[n++] = (uint16_t)cp;
    }
    // 미리 굽는 글자 수가 아니라 **고정 행 수**로 잡는다 — 남는 슬롯이 온디맨드
    // 성장의 상한이 되기 때문이다.
    uint32_t W = COLS * CW, H = maru_mobile_atlas_rows() * CH;

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
        (*env)->GetMethodID(env, pCls, "setTextSize", "(F)V"), (jfloat)MARU_ATLAS_TEXT_PX);
    (*env)->CallVoidMethod(env, paint,
        (*env)->GetMethodID(env, pCls, "setColor", "(I)V"), (jint)0xFFFFFFFF);
    // **번들한 폰트를 쓴다.** maru 가 이미 `assets/fonts/` 에 OFL 폰트를 동봉하고 있고,
    // Jetendard 는 영문과 한글을 한 파일에 담아 폴백이 필요 없다 — iOS 와 **같은 파일**을
    // 읽으므로 글자 모양과 advance 가 플랫폼을 넘어 같아진다.
    jclass tfCls = (*env)->FindClass(env, "android/graphics/Typeface");
    // **APK asset 에서 읽는다**(위 셰이더와 같은 이유 — /data/local/tmp 는 개발 스크립트 자리다).
    jobject face = NULL;
    jclass actCls2 = (*env)->GetObjectClass(env, app->activity->clazz);
    jobject assets = (*env)->CallObjectMethod(env, app->activity->clazz,
        (*env)->GetMethodID(env, actCls2, "getAssets", "()Landroid/content/res/AssetManager;"));
    jmethodID mFromAsset = (*env)->GetStaticMethodID(env, tfCls, "createFromAsset",
        "(Landroid/content/res/AssetManager;Ljava/lang/String;)Landroid/graphics/Typeface;");
    face = (*env)->CallStaticObjectMethod(env, tfCls, mFromAsset, assets,
        (*env)->NewStringUTF(env, "Jetendard-Regular.ttf"));
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
    // 래스터 결과를 남긴다 — 하네스(`atlas_diff.py`)가 `run-as` 로 꺼내 픽셀을 대조한다.
    // 앱은 /data/local/tmp 에 못 쓴다(샌드박스)라 자기 내부 경로에 둔다.
    // **요청할 때만 쓴다**(`setprop debug.maru.atlas_dump 1` — 셸은 `debug.*` 만 설정할 수 있다) — 제품이 매 실행마다 384KB 를 남길
    // 이유가 없다.
    char want[PROP_VALUE_MAX] = {0};
    if (__system_property_get("debug.maru.atlas_dump", want) > 0 && want[0] == '1') {
        char dump_path[512];
        snprintf(dump_path, sizeof dump_path, "%s/atlas_ondevice.gray",
                 app->activity->internalDataPath ? app->activity->internalDataPath : "/data/local/tmp");
        FILE *df = fopen(dump_path, "wb");
        if (df) { fwrite(buf, 1, W * H, df); fclose(df); LOGI("atlas_dump=%s", dump_path); }
    }

    *out = buf; *ow = W; *oh = H;
    g.atlas_cols = COLS;
    g.atlas_rows = maru_mobile_atlas_rows();
    LOGI("atlas_ondevice=%ux%u glyphs=%u source=android.graphics.Paint", W, H, n);
    return 1;
}

// **APK asset 에서 읽는다.** 예전에는 `/data/local/tmp` 였는데 그건 개발 스크립트가 넣어
// 주는 자리라, `adb push` 를 안 한 기기에 설치하면 셰이더가 없어 초기화가 실패하고 화면이
// **검은 채로** 남았다(로그 한 줄 말고는 단서도 없다).
static VkShaderModule loadSpv(const char *name) {
    AAssetManager *am = g_app ? g_app->activity->assetManager : NULL;
    AAsset *a = am ? AAssetManager_open(am, name, AASSET_MODE_BUFFER) : NULL;
    if (!a) { LOGI("spv_missing=%s", name); return VK_NULL_HANDLE; }
    off_t n = AAsset_getLength(a);
    uint32_t *buf = malloc((size_t)n);
    memcpy(buf, AAsset_getBuffer(a), (size_t)n);
    AAsset_close(a);
    VkShaderModuleCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                   .codeSize = n, .pCode = buf};
    VkShaderModule m = VK_NULL_HANDLE;
    vkCreateShaderModule(g.dev, &ci, NULL, &m);
    free(buf);
    return m;
}

static int uploadTexture(const uint8_t *pixels, uint32_t w, uint32_t h, uint32_t bpp,
                         VkFormat fmt, VkImageView *outView, VkImage *outImage,
                         VkDeviceMemory *outMem) {
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
    // 실패해도 **device 의 자식을 남기지 않는다.** 남기면 나중에 device 를 파괴할 때
    // 드라이버가 죽는다(아래 staging 주석의 실측과 같은 종류).
    VkDeviceMemory mem;
    if (vkAllocateMemory(g.dev, &mai, NULL, &mem) != VK_SUCCESS) {
        vkDestroyImage(g.dev, img, NULL);
        return 0;
    }
    vkBindImageMemory(g.dev, img, mem, 0);

    VkDeviceSize bytes = (VkDeviceSize)w * h * bpp;
    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = bytes,
                              .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
    VkBuffer stage;
    if (vkCreateBuffer(g.dev, &bci, NULL, &stage) != VK_SUCCESS) {
        vkDestroyImage(g.dev, img, NULL);
        vkFreeMemory(g.dev, mem, NULL);
        return 0;
    }
    VkMemoryRequirements bmr; vkGetBufferMemoryRequirements(g.dev, stage, &bmr);
    uint32_t bmt = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        int want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((bmr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) { bmt = i; break; }
    }
    VkMemoryAllocateInfo bmai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 .allocationSize = bmr.size, .memoryTypeIndex = bmt};
    VkDeviceMemory bmem;
    if (vkAllocateMemory(g.dev, &bmai, NULL, &bmem) != VK_SUCCESS) {
        vkDestroyBuffer(g.dev, stage, NULL);
        vkDestroyImage(g.dev, img, NULL);
        vkFreeMemory(g.dev, mem, NULL);
        return 0;
    }
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

    // **staging 을 여기서 지운다.** 안 지우면 device 의 자식으로 남고, 창이 바뀔 때
    // `teardownVulkan` 이 자식이 살아 있는 device 를 파괴한다 — 정의되지 않은 동작이다.
    // 실측: 창 크기를 아홉 번 바꿨더니 `vkDestroyDevice` 안에서 SIGSEGV 로 앱이 죽었다
    // (툼스톤 #01 `on_vkDestroyDevice_pre`, 드라이버의 device-memory 등록부).
    vkFreeCommandBuffers(g.dev, g.pool, 1, &cb);
    vkDestroyBuffer(g.dev, stage, NULL);
    vkFreeMemory(g.dev, bmem, NULL);

    VkImageViewCreateInfo ivci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
                                  .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = fmt,
                                  .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    if (outImage) *outImage = img;
    if (outMem) *outMem = mem;
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
        uploadTexture(g_glyph_px, g_gw, g_gh, 1, VK_FORMAT_R8_UNORM, &g.glyph_view, &g.glyph_image, &g.glyph_mem);
        g.glyph_w = g_gw; g.glyph_h = g_gh;
    }
    uint32_t filled = maru_mobile_icon_build();
    uint32_t slot = maru_mobile_icon_slot_px(), cnt = maru_mobile_icon_count();
    uploadTexture(maru_mobile_icon_atlas(), slot, slot * cnt, 4, VK_FORMAT_R8G8B8A8_UNORM,
                  &g.icon_view, &g.icon_image, &g.icon_mem);
    LOGI("icons filled=%u/%u", filled, cnt);

    VkSamplerCreateInfo sampci = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                                  .magFilter = VK_FILTER_LINEAR, .minFilter = VK_FILTER_LINEAR};
    VkSampler samp; vkCreateSampler(g.dev, &sampci, NULL, &samp);
    g.sampler = samp;
    VkDescriptorSetLayoutBinding binds[3] = {
        {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT},
        {.binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT},
        // binding 2 = draw-list. vertex 가 gl_InstanceIndex 로 읽는다.
        {.binding = 2, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_VERTEX_BIT}};
    VkDescriptorSetLayoutCreateInfo dslci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                             .bindingCount = 3, .pBindings = binds};
    VkDescriptorSetLayout dsl; vkCreateDescriptorSetLayout(g.dev, &dslci, NULL, &dsl);
    g.dsl = dsl;
    VkDescriptorPoolSize dps[2] = {{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2},
                                   {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1}};
    VkDescriptorPoolCreateInfo dpci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                                       .maxSets = 1, .poolSizeCount = 2, .pPoolSizes = dps};
    VkDescriptorPool dpool; vkCreateDescriptorPool(g.dev, &dpci, NULL, &dpool);
    g.dpool = dpool;
    VkDescriptorSetAllocateInfo dsai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                                        .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl};
    vkAllocateDescriptorSets(g.dev, &dsai, &g.dset);
    VkDescriptorImageInfo dii[2] = {
        {samp, g.glyph_view ? g.glyph_view : g.icon_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
        {samp, g.icon_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL}};
    // draw-list 버퍼: 프레임마다 새로 만들지 않고 한 번 잡아 persistent map 한다.
    // **크기는 코어가 답한다.** 4096 을 손으로 적어 뒀을 때는 그보다 많이 오면 `drawn` 이
    // 조용히 잘라 화면 아래가 사라졌다 — 게다가 iOS 는 늘리고 있어 둘이 달랐다.
    g.quad_cap = maru_mobile_max_quads();
    VkBufferCreateInfo qbci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                               .size = (VkDeviceSize)g.quad_cap * sizeof(Push),
                               .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT};
    vkCreateBuffer(g.dev, &qbci, NULL, &g.quad_buf);
    VkMemoryRequirements qmr; vkGetBufferMemoryRequirements(g.dev, g.quad_buf, &qmr);
    VkPhysicalDeviceMemoryProperties qmp; vkGetPhysicalDeviceMemoryProperties(g.pd, &qmp);
    uint32_t qmt = UINT32_MAX;
    for (uint32_t i = 0; i < qmp.memoryTypeCount; i++) {
        int want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((qmr.memoryTypeBits & (1u << i)) && (qmp.memoryTypes[i].propertyFlags & want) == want) { qmt = i; break; }
    }
    VkMemoryAllocateInfo qmai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 .allocationSize = qmr.size, .memoryTypeIndex = qmt};
    vkAllocateMemory(g.dev, &qmai, NULL, &g.quad_mem);
    vkBindBufferMemory(g.dev, g.quad_buf, g.quad_mem, 0);
    vkMapMemory(g.dev, g.quad_mem, 0, VK_WHOLE_SIZE, 0, &g.quad_map);
    VkDescriptorBufferInfo qdbi = {.buffer = g.quad_buf, .offset = 0, .range = VK_WHOLE_SIZE};

    VkWriteDescriptorSet wds[3] = {
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = g.dset, .dstBinding = 0,
         .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii[0]},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = g.dset, .dstBinding = 1,
         .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii[1]},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = g.dset, .dstBinding = 2,
         .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &qdbi}};
    vkUpdateDescriptorSets(g.dev, 3, wds, 0, NULL);

    // push constant 는 없앴다 — quad 마다 다른 값을 한 번의 draw call 에 실을 수 없다.
    VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                                       .setLayoutCount = 1, .pSetLayouts = &dsl};
    vkCreatePipelineLayout(g.dev, &plci, NULL, &g.layout);

    VkShaderModule vs = loadSpv("chrome.vert.spv");
    VkShaderModule fs = loadSpv("chrome.frag.spv");
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
    // **창 크기를 직접 본다.** 드라이버가 OUT_OF_DATE 를 안 알려 주는 경우가 있다(실측:
    // 이 에뮬레이터는 리사이즈 뒤에도 계속 VK_SUCCESS 를 돌려주고, SurfaceFlinger 가 낡은
    // 버퍼를 늘려 화면만 맞아 보인다 — 실제로는 잘못된 해상도로 그리고 있다).
    if (g_app && g_app->window) {
        uint32_t w = (uint32_t)ANativeWindow_getWidth(g_app->window);
        uint32_t h = (uint32_t)ANativeWindow_getHeight(g_app->window);
        if (w && h && (w != g.extent.width || h != g.extent.height)) {
            g.needs_recreate = 1;
            return;
        }
    }

    uint32_t idx = 0;
    VkResult acq = vkAcquireNextImageKHR(g.dev, g.swap, UINT64_MAX, g.acquire_sem, VK_NULL_HANDLE, &idx);
    if (acq == VK_ERROR_OUT_OF_DATE_KHR || acq == VK_SUBOPTIMAL_KHR) {
        // 창이 리사이즈됐다. 다시 안 만들면 **화면이 영구히 언다** — `adjustResize` 와 자동
        // 키보드가 첫 프레임에 이걸 일으키므로 실기기에서는 켜자마자 멈춘다.
        g.needs_recreate = 1;
        return;
    }
    if (acq != VK_SUCCESS) return;

    // **레이아웃은 Zig chrome 이 한다.** 플랫폼은 쓸 수 있는 크기만 넘기고 quad 를 받는다.
    //
    // 스케일을 상수로 박으면 안 된다 — 기기 density 를 써야 iOS 의 논리 좌표와 같은
    // 밀도가 된다(420dpi = 2.625배 → 411x914 로 iOS 402x874 와 거의 같다. 2.0 으로
    // 박았을 때는 540x1200 이 되어 레이아웃이 화면 위쪽만 채웠다).
    float scale = g.scale;
    // 상태바·제스처바를 뺀 영역만 준다 — iOS 의 safeAreaInsets 와 같은 자리다.
    unsigned int lw = (unsigned int)(g.extent.width / scale);
    unsigned int lh = (unsigned int)((g.extent.height - g.inset_top - g.inset_bottom) / scale);
    // **입력 스레드와 겹치는 구간만 막는다.** IME 가 `maru_mobile_input` 으로 코어에 쓰는
    // 것과 여기서 격자를 읽는 것이 겹치면 셀을 반쯤 쓴 상태로 읽는다. 오류 문자열도 두
    // 스레드가 만지므로 같이 넣는다.
    //
    // **아틀라스 성장은 밖에 둔다.** 굽기는 글자마다 `vkQueueWaitIdle` 로 GPU 를 기다리는데,
    // 그 동안 자물쇠를 쥐고 있으면 **타이핑이 GPU 를 기다리게 된다**. 성장이 만지는 등록부·
    // 미스 목록은 입력 스레드가 안 건드리므로 밖에 둬도 된다.
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int n = maru_mobile_build(lw, lh);
    if (g.frames == 0) LOGI("quads=%u err=%s logical=%ux%u", n, maru_mobile_last_error(), lw, lh);
    // **오류는 바뀔 때 알린다.** frames==0 에서만 읽으면 그 뒤에 생긴 실패는 기록만 되고
    // 아무도 안 본다 — 계약 §5 가 약속한 것이 안 지켜진다.
    {
        static char last_err[64];
        const char *err = maru_mobile_last_error();
        if (err[0]) {
            if (strcmp(err, last_err) != 0) {
                snprintf(last_err, sizeof last_err, "%s", err);
                LOGI("MARU_CHROME error=%s", err);
            }
            maru_mobile_clear_error();  // 읽은 쪽이 비운다 — 다음 실패가 가려지지 않게
        }
    }
    pthread_mutex_unlock(&g_bridge_lock);

    // build 가 못 그린 글자를 그 슬롯에만 구워 넣는다 — 다음 프레임에 보인다.
    if (g_app) growAtlas(g_app);
    const MaruQuad *quads = maru_mobile_quads();

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
    // **draw call 한 번.** 목록을 버퍼에 채우고 인스턴스로 그린다 — quad 마다 부르면
    // 80x40 터미널이 3200 call 이 되고, 모바일 타일 기반 GPU 는 거기에 특히 민감하다.
    // 버퍼를 `maru_mobile_max_quads()` 만큼 잡았으므로 잘릴 일이 없다 — 잘린다면 그건
    // 계약이 깨진 것이라 조용히 넘기지 않고 남긴다.
    unsigned int drawn = n;
    if (drawn > g.quad_cap) {
        drawn = g.quad_cap;
        static int logged_drift;  // 매 프레임 도배하지 않는다 — 한 번이면 안다
        if (!logged_drift) { logged_drift = 1; LOGI("MARU_CHROME error=quad_cap_drift n=%u cap=%u", n, g.quad_cap); }
    }
    Push *dst = (Push *)g.quad_map;
    for (unsigned int i = 0; i < drawn; i++) {
        const MaruQuad *q = &quads[i];
        float cols = (q->kind == 2) ? 1.0f : (float)g.atlas_cols;
        float rows = (q->kind == 2) ? (float)maru_mobile_icon_count() : (float)g.atlas_rows;
        float oy = (float)g.inset_top;
        Push p = {{q->x * scale, q->y * scale + oy, (q->x + q->w) * scale, (q->y + q->h) * scale + oy},
                  {q->r, q->g, q->b, q->a},
                  {q->radius * scale, (float)g.extent.width, (float)g.extent.height, (float)q->kind},
                  {(float)q->cell_x, (float)q->cell_y, cols, rows}};
        dst[i] = p;
    }
    vkCmdDraw(cb, 4, drawn, 0, 0);
    if (g.frames == 0) LOGI("MARU_DRAW calls=1 instances=%u", drawn);
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
    VkResult pres = vkQueuePresentKHR(g.queue, &pi);
    if (pres == VK_ERROR_OUT_OF_DATE_KHR || pres == VK_SUBOPTIMAL_KHR) g.needs_recreate = 1;
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
        if (!g.pace_done) {
            g.pace_done = 1;
            // **계측은 동작을 바꾸지 않는다.** 예전에는 여기서 앱을 30Hz 로 전환해, 측정의
            // 부산물이 제품 동작이 됐다(그리고 iOS 엔 그 전환이 없어 두 플랫폼이 달랐다).
            double med = g.pace_ms[PACE_SAMPLES / 2];
            int paced = (med >= 25.0 && med <= 42.0);
            LOGI("MARU_PACE median_ms=%.2f n=%d target=33.33 verdict=%s",
                 med, PACE_SAMPLES, paced ? "PASS" : "FAIL");
        }
    }
    g.frames++;
}

// 상태바·제스처바 밑으로 UI 가 깔리지 않게 **실제 inset** 을 받아 온다. NDK 에는 inset
// API 가 없어서 JNI 로 `View.getRootWindowInsets()` 를 부른다 — iOS 의 `safeAreaInsets`
// 와 같은 자리다. 값을 못 얻으면 0 으로 두고 진행한다(그리기를 막을 이유는 없다).
static void queryInsets(struct android_app *app, int *top, int *bottom) {
    // **실패하면 이전 값을 지킨다.** 예전에는 먼저 0 으로 밀어 버려, 조회가 실패하면 UI 가
    // 조용히 상태바 밑으로 들어갔다 — 화면만 이상하고 이유는 안 보인다.
    int got_top = 0, got_bottom = 0, ok = 0;
    JavaVM *vm = app->activity->vm;
    JNIEnv *env = NULL;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) { LOGI("insets_attach_failed"); return; }
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
    if (!ins) { LOGI("insets_unavailable"); (*vm)->DetachCurrentThread(vm); return; }
    jclass typeCls = (*env)->FindClass(env, "android/view/WindowInsets$Type");
    jmethodID mBars = (*env)->GetStaticMethodID(env, typeCls, "systemBars", "()I");
    jint mask = (*env)->CallStaticIntMethod(env, typeCls, mBars);
    jclass insCls = (*env)->GetObjectClass(env, ins);
    jmethodID mGet = (*env)->GetMethodID(env, insCls, "getInsets", "(I)Landroid/graphics/Insets;");
    jobject box = (*env)->CallObjectMethod(env, ins, mGet, mask);
    if (box) {
        jclass boxCls = (*env)->GetObjectClass(env, box);
        got_top = (*env)->GetIntField(env, box, (*env)->GetFieldID(env, boxCls, "top", "I"));
        got_bottom = (*env)->GetIntField(env, box, (*env)->GetFieldID(env, boxCls, "bottom", "I"));
        ok = 1;
    }
    (*vm)->DetachCurrentThread(vm);
    if (ok) { *top = got_top; *bottom = got_bottom; } else LOGI("insets_read_failed");
}

// **입력**: 문자는 IME 가 만든다. `MaruActivity.java` 가 `InputConnection` 으로 받아
// 여기로 넘긴다 — keycode→ASCII 표를 손으로 짜면 한글을 못 만든다(그게 shim 을 둔 이유다).
//
// 조합 중 문자열은 **셸로 보내지 않는다**. 화면에만 흐리게 그릴 겉치레라서, 코어의 입력
// 경로가 아니라 별도 상태로 둔다(docs/mobile-platform.md §1).
JNIEXPORT void JNICALL
Java_dev_maru_MaruActivity_nativeComposing(JNIEnv *env, jclass cls, jstring text) {
    (void)cls;
    const char *s = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL;
    unsigned int n = s ? (unsigned int)strlen(s) : 0;
    // **UI 스레드다.** 렌더 스레드가 브리지를 읽는 동안 끼어들면 안 된다(파일 위 주석).
    pthread_mutex_lock(&g_bridge_lock);
    maru_mobile_set_preedit(s ? s : "", n);
    pthread_mutex_unlock(&g_bridge_lock);
    if (s) (*env)->ReleaseStringUTFChars(env, text, s);
}

JNIEXPORT void JNICALL
Java_dev_maru_MaruActivity_nativeCommit(JNIEnv *env, jclass cls, jstring text) {
    (void)cls;
    if (!text) return;
    const char *s = (*env)->GetStringUTFChars(env, text, NULL);
    if (s) {
        pthread_mutex_lock(&g_bridge_lock);
        unsigned int total = maru_mobile_input(s, strlen(s));
        pthread_mutex_unlock(&g_bridge_lock);
        LOGI("MARU_INPUT commit=\"%s\" total=%u", s, total);
        (*env)->ReleaseStringUTFChars(env, text, s);
    }
}

// IME 가 문자로 주지 않는 키만 여기로 온다(백스페이스·엔터 등).
JNIEXPORT void JNICALL
Java_dev_maru_MaruActivity_nativeKey(JNIEnv *env, jclass cls, jint key_code) {
    (void)env; (void)cls;
    char c = 0;
    switch (key_code) {
        case AKEYCODE_ENTER: c = '\r'; break;
        case AKEYCODE_DEL:   c = 0x7F; break;
        case AKEYCODE_TAB:   c = '\t'; break;
        case AKEYCODE_ESCAPE: c = 0x1B; break;
        default: return;
    }
    pthread_mutex_lock(&g_bridge_lock);
    maru_mobile_input(&c, 1);
    pthread_mutex_unlock(&g_bridge_lock);
}

// 창이 서면 키보드를 올린다 — 터미널은 켜지면 바로 입력을 받는다.
static void showKeyboard(struct android_app *app) {
    JavaVM *vm = app->activity->vm;
    JNIEnv *env = NULL;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return;
    jclass cls = (*env)->GetObjectClass(env, app->activity->clazz);
    jmethodID m = (*env)->GetMethodID(env, cls, "showKeyboard", "()V");
    if (m) (*env)->CallVoidMethod(env, app->activity->clazz, m);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*vm)->DetachCurrentThread(vm);
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
    // 키는 여기서 안 본다 — 소프트 키보드 문자는 `MaruActivity` 의 InputConnection 이 준다.
    return 0;
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

    // **device 의 자식을 남기지 않는다.** 예전에는 스왑체인만 지우고 나머지를 살려 둔 채
    // device 를 파괴해, 재개할 때마다 draw-list 버퍼(호스트 가시·매핑 상태)와 텍스처가
    // 통째로 샜다.
    if (g.quad_map) { vkUnmapMemory(g.dev, g.quad_mem); g.quad_map = NULL; }
    if (g.quad_buf) vkDestroyBuffer(g.dev, g.quad_buf, NULL);
    if (g.quad_mem) vkFreeMemory(g.dev, g.quad_mem, NULL);
    if (g.pipe) vkDestroyPipeline(g.dev, g.pipe, NULL);
    if (g.layout) vkDestroyPipelineLayout(g.dev, g.layout, NULL);
    if (g.dpool) vkDestroyDescriptorPool(g.dev, g.dpool, NULL);
    if (g.dsl) vkDestroyDescriptorSetLayout(g.dev, g.dsl, NULL);
    if (g.sampler) vkDestroySampler(g.dev, g.sampler, NULL);
    if (g.glyph_view) vkDestroyImageView(g.dev, g.glyph_view, NULL);
    if (g.glyph_image) vkDestroyImage(g.dev, g.glyph_image, NULL);
    if (g.glyph_mem) vkFreeMemory(g.dev, g.glyph_mem, NULL);
    if (g.icon_view) vkDestroyImageView(g.dev, g.icon_view, NULL);
    if (g.icon_image) vkDestroyImage(g.dev, g.icon_image, NULL);
    if (g.icon_mem) vkFreeMemory(g.dev, g.icon_mem, NULL);
    if (g.rp) vkDestroyRenderPass(g.dev, g.rp, NULL);
    if (g.acquire_sem) vkDestroySemaphore(g.dev, g.acquire_sem, NULL);
    if (g.submit_sem) vkDestroySemaphore(g.dev, g.submit_sem, NULL);
    if (g.fence) vkDestroyFence(g.dev, g.fence, NULL);
    if (g.pool) vkDestroyCommandPool(g.dev, g.pool, NULL);
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
/// 한 배치 동안 재사용하는 래스터 도구. **글자마다 만들면 비싸다** — 특히
/// `Typeface.createFromAsset` 은 폰트 파일을 여는 일이라 한글을 타이핑하는 내내 그 비용을
/// 치르게 된다. 한 번 붙이고 한 벌 만들어 `drawText` 만 반복한다.
typedef struct {
    JNIEnv *env;
    jobject bmp, canvas, paint;
    jmethodID draw, measure;
    int ok;
} GlyphBaker;

static int bakerOpen(struct android_app *app, GlyphBaker *b, uint32_t CW, uint32_t CH) {
    memset(b, 0, sizeof *b);
    JavaVM *vm = app->activity->vm;
    if ((*vm)->AttachCurrentThread(vm, &b->env, NULL) != 0) return 0;
    JNIEnv *env = b->env;
    jclass bmCls = (*env)->FindClass(env, "android/graphics/Bitmap");
    jclass cfgCls = (*env)->FindClass(env, "android/graphics/Bitmap$Config");
    jobject cfg = (*env)->GetStaticObjectField(env, cfgCls,
        (*env)->GetStaticFieldID(env, cfgCls, "ALPHA_8", "Landroid/graphics/Bitmap$Config;"));
    b->bmp = (*env)->CallStaticObjectMethod(env, bmCls,
        (*env)->GetStaticMethodID(env, bmCls, "createBitmap",
            "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;"),
        (jint)CW, (jint)CH, cfg);
    if (!b->bmp) return 0;
    jclass cvCls = (*env)->FindClass(env, "android/graphics/Canvas");
    b->canvas = (*env)->NewObject(env, cvCls,
        (*env)->GetMethodID(env, cvCls, "<init>", "(Landroid/graphics/Bitmap;)V"), b->bmp);
    jclass pCls = (*env)->FindClass(env, "android/graphics/Paint");
    b->paint = (*env)->NewObject(env, pCls,
        (*env)->GetMethodID(env, pCls, "<init>", "(I)V"), (jint)1);
    (*env)->CallVoidMethod(env, b->paint,
        (*env)->GetMethodID(env, pCls, "setTextSize", "(F)V"), (jfloat)MARU_ATLAS_TEXT_PX);
    (*env)->CallVoidMethod(env, b->paint,
        (*env)->GetMethodID(env, pCls, "setColor", "(I)V"), (jint)0xFFFFFFFF);

    // asset 에서 읽는다 — `/data/local/tmp` 는 개발 스크립트 자리라 실제 앱에는 없다.
    jclass tfCls = (*env)->FindClass(env, "android/graphics/Typeface");
    jclass actCls = (*env)->GetObjectClass(env, app->activity->clazz);
    jobject assets = (*env)->CallObjectMethod(env, app->activity->clazz,
        (*env)->GetMethodID(env, actCls, "getAssets", "()Landroid/content/res/AssetManager;"));
    jobject face = (*env)->CallStaticObjectMethod(env, tfCls,
        (*env)->GetStaticMethodID(env, tfCls, "createFromAsset",
            "(Landroid/content/res/AssetManager;Ljava/lang/String;)Landroid/graphics/Typeface;"),
        assets, (*env)->NewStringUTF(env, "Jetendard-Regular.ttf"));
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); face = NULL; }
    if (face) (*env)->CallObjectMethod(env, b->paint,
        (*env)->GetMethodID(env, pCls, "setTypeface",
            "(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;"), face);
    else LOGI("bundled_font_missing fallback=default");

    b->draw = (*env)->GetMethodID(env, cvCls, "drawText",
        "(Ljava/lang/String;FFLandroid/graphics/Paint;)V");
    b->measure = (*env)->GetMethodID(env, pCls, "measureText", "(Ljava/lang/String;)F");
    b->ok = 1;
    return 1;
}

static void bakerClose(struct android_app *app, GlyphBaker *b) {
    if (!b->env) return;
    JavaVM *vm = app->activity->vm;
    (*vm)->DetachCurrentThread(vm);
    b->env = NULL;
}

/// 한 글자를 셀 크기 버퍼에 굽는다. 아틀라스를 처음 만들 때와 **같은 폰트·같은 배치**를
/// 써야 새로 넣은 글리프가 기존 것과 어긋나지 않는다(baseline = CH-8).
static int bakeGlyph(GlyphBaker *b, uint32_t cp, uint8_t *out,
                     uint32_t CW, uint32_t CH, uint32_t *advance) {
    if (!b->ok) return 0;
    JNIEnv *env = b->env;
    // **셀을 비우고 그린다.** `Canvas.drawColor(0)` 은 SRC_OVER 라 투명색을 덮어도 아무것도
    // 안 지운다 — 그렇게 짰다가 앞 글자 잉크가 남아 글자가 겹쳐 나왔다(화면으로 잡았다).
    // `Bitmap.eraseColor` 가 실제로 지우는 쪽이다.
    jclass bmCls2 = (*env)->GetObjectClass(env, b->bmp);
    (*env)->CallVoidMethod(env, b->bmp,
        (*env)->GetMethodID(env, bmCls2, "eraseColor", "(I)V"), (jint)0);

    jchar unit = (jchar)cp;
    jstring s = (*env)->NewString(env, &unit, 1);
    (*env)->CallVoidMethod(env, b->canvas, b->draw, s, (jfloat)1.0f, (jfloat)(CH - 8), b->paint);
    jfloat adv = (*env)->CallFloatMethod(env, b->paint, b->measure, s);
    *advance = (uint32_t)(adv + 0.5f);
    if (*advance == 0) *advance = CW / 2;

    void *pixels = NULL;
    AndroidBitmapInfo info;
    int ok = 0;
    if (AndroidBitmap_getInfo(env, b->bmp, &info) == 0 &&
        AndroidBitmap_lockPixels(env, b->bmp, &pixels) == 0) {
        for (uint32_t y = 0; y < CH; y++)
            memcpy(out + y * CW, (uint8_t *)pixels + y * info.stride, CW);
        AndroidBitmap_unlockPixels(env, b->bmp);
        ok = 1;
    }
    (*env)->DeleteLocalRef(env, s);
    return ok;
}

// **아틀라스를 키운다.** 텍스처를 다시 만들지 않고 그 셀 자리에만 복사한다 —
// 아틀라스 부분 업데이트(여섯 기능 4번)를 그대로 쓴다. iOS `replaceRegion:` 과 같은 자리다.
static void growAtlas(struct android_app *app) {
    unsigned int n = maru_mobile_missing_count();
    if (n == 0 || !g.glyph_image || !g.dev) return;
    // **뒤에서부터 훑는다.** `maru_mobile_atlas_add` 가 미스 목록에서 그 항목을 지우면서
    // **마지막 항목을 그 자리로** 당겨 오므로, 앞으로 진행하면 당겨진 것을 건너뛴다(실측).
    // 뒤에서부터 가면 지워지는 자리가 항상 훑은 뒤쪽이라 앞쪽이 흔들리지 않는다 —
    // 목록 크기를 host 가 따로 알 필요도 없어진다(그 상수를 양쪽에 두면 또 어긋난다).
    const uint32_t CW = MARU_ATLAS_CELL_W, CH = MARU_ATLAS_CELL_H;
    uint8_t cell[MARU_ATLAS_CELL_W * MARU_ATLAS_CELL_H];
    unsigned int added = 0;
    GlyphBaker baker;
    if (!bakerOpen(app, &baker, CW, CH)) { maru_mobile_missing_clear(); return; }
    for (int i = (int)n - 1; i >= 0; i--) {
        unsigned int cp = maru_mobile_missing_cp((unsigned int)i);
        if (cp == 0 || cp > 0xFFFF) continue;
        unsigned int slot = maru_mobile_next_slot(g.atlas_cols);
        // 등록부가 꽉 차면 sentinel 이 온다. 옛 코드는 같은 자리를 계속 받아 **매 프레임
        // 다시 굽고** 있었다 — 화면에는 안 나오면서 CPU·GPU 만 먹는다.
        if (slot == 0xFFFFFFFF) break;  // 축출 정책은 아직 없다(계약 §4)
        uint32_t col = slot >> 16, row = slot & 0xFFFF;
        memset(cell, 0, sizeof cell);
        uint32_t advance = CW / 2;
        if (!bakeGlyph(&baker, cp, cell, CW, CH, &advance)) continue;

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

        // **원본 버퍼에도 넣는다.** 창이 죽었다 살아나면 이 버퍼로 텍스처를 다시 올리는데,
        // GPU 이미지에만 넣으면 그때 성장분이 통째로 사라진다. 등록부는 그대로라 코어는
        // "있다" 고 믿고 다시 굽지도 않아 영영 빈칸이 된다(실측 경로).
        if (g_glyph_px && (row + 1) * CH <= g_gh) {
            for (uint32_t y = 0; y < CH; y++)
                memcpy(g_glyph_px + (row * CH + y) * g_gw + col * CW, cell + y * CW, CW);
        }
        maru_mobile_atlas_add(cp, col, row, advance);
        added++;
    }
    bakerClose(app, &baker);
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
        // 기기에서 굽는다. 실패하면 글리프 없이 뜨는 편이 낫다 — 예전 폴백은 개발
        // 스크립트가 push 한 파일에 기대는 것이라 실제 앱에는 그 파일이 없었다.
        if (!g_glyph_px && !rasterizeAtlasOnDevice(app, &g_glyph_px, &g_gw, &g_gh))
            LOGI("atlas_raster_failed");
        if (initVulkan(app->window)) LOGI("MARU_LIFECYCLE vulkan_ready frames_reset");
        // **처음부터 vsync 콜백이 주기를 쥔다**(30Hz). 여기서 등록하는 이유는
        // 메인 루프가 `pollOnce(-1)` 로 막혀 있어 거기서는 등록에 도달할 수
        // 없기 때문이다(그렇게 짰다가 아무것도 안 그려졌다).
        if (!g_chor_started) {
            g_chor_started = 1;
            AChoreographer_postFrameCallback64(AChoreographer_getInstance(), frameCallback, app);
        }
        showKeyboard(app);
    }
}

// vsync 마다 불린다. **한 번 걸러** 그려서 30Hz 를 만든다 — Vulkan present mode 에는
// 하위 주기 선택지가 없으므로(FIFO/MAILBOX/IMMEDIATE 는 전부 "언제"지 "얼마나 자주"가
// 아니다) 주기는 앱이 정한다. iOS 의 `preferredFrameRateRange` 에 대응하는 자리다.
static void frameCallback(int64_t frame_time_ns, void *data) {
    (void)frame_time_ns;
    g.vsync_count++;
    // **30Hz(comfort).** 터미널은 매 vsync 마다 새로 그릴 것이 없고, 모바일은 배터리·발열이
    // 사용자에게 보인다. 데스크톱 maru 의 present 정책과 같은 값이다.
    if ((g.vsync_count & 1) == 0) drawFrame();
    // **여기서도 재생성을 봐야 한다.** 이 단계에서는 메인 루프가 pollOnce(-1) 로 막혀 있어
    // 리사이즈 신호를 받아 줄 사람이 없다 — 그러면 화면이 그대로 언다.
    if (g.needs_recreate && data) {
        g.needs_recreate = 0;
        recreateVulkan((struct android_app *)data);
    }
    AChoreographer_postFrameCallback64(AChoreographer_getInstance(), frameCallback, data);
}

// 창 크기가 바뀌면 통째로 다시 세운다. 스왑체인만 갈아 끼우는 것보다 무겁지만 드물게
// 일어나고, teardown 이 자식을 전부 지우므로 새는 것이 없다.
static void recreateVulkan(struct android_app *app) {
    if (!app->window) return;
    teardownVulkan();
    // **inset 도 다시 읽는다.** 창이 커지거나 줄면 상태바·제스처바 영역도 달라지는데,
    // 예전에는 창 생성 때 한 번만 읽어 그 뒤로 옛 값을 썼다 — iOS 는 매 프레임 읽는다.
    queryInsets(app, &g.inset_top, &g.inset_bottom);
    if (initVulkan(app->window)) LOGI("MARU_LIFECYCLE vulkan_recreated");
}

void android_main(struct android_app *app) {
    // **새 네이티브 스레드는 체인이 없다.** 액티비티가 파괴·재생성되면 `android_main` 이 다시
    // 도는데, 프로세스가 살아 있으면 이 static 이 1 로 남아 콜백을 다시 안 걸어 **화면이 영영
    // 안 그려진다**. 이전 스레드의 looper 는 이미 죽어 그 체인도 함께 사라졌으므로 여기서
    // 0 으로 되돌리는 것이 맞다.
    //
    // 이 에뮬레이터에서는 액티비티가 죽을 때 프로세스도 죽어 재현되지 않았지만(실측: PID 가
    // 바뀐다), 시스템이 프로세스를 살려 두는 경우가 있어 한 줄로 그 부류를 없앤다.
    g_chor_started = 0;
    g_app = app;
    app->onAppCmd = onAppCmd;
    app->onInputEvent = onInputEvent;
    while (1) {
        int events;
        struct android_poll_source *source;
        // 그리는 것은 choreographer 가 한다 — 여기서는 **막고** 이벤트만 기다린다.
        // 0 을 주면 아무것도 안 막아 CPU 한 코어를 계속 문다(폰이 뜨겁고 배터리가 준다).
        while (ALooper_pollOnce(-1, NULL, &events, (void **)&source) >= 0) {
            if (source) source->process(app, source);
            if (app->destroyRequested) return;
        }
        if (g.needs_recreate) { g.needs_recreate = 0; recreateVulkan(app); }
    }
}
