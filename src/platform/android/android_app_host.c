// Android host (L4). NativeActivity 창·생명주기·터치 + Vulkan 백엔드 + JNI Paint 래스터.
//
// **플랫폼은 배치를 모른다** — Zig 가 낸 quad 를 그리기만 한다(L3 chrome 이 배치,
// L4 platform 이 그리기). IME 만 Java shim(`MaruActivity.java`)이 받는다: NDK 에는
// `InputConnection` 에 해당하는 것이 없어 한글 조합을 받을 수 없다.
// 계약은 docs/mobile-platform.md 가 단일 출처다.
// 선언은 `platform/mobile/mobile_host_abi.h` 가 단일 출처다 — 여기서 다시 적지 않는다.
#include "../mobile/mobile_host_abi.h"
#include "../mobile_host/ssh_pump.h"

#include <errno.h>
#include <sys/random.h>
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

// 표본 수·워밍업은 **ABI 헤더가 소유한다**(`MARU_FRAME_PACE_*`) — 두 host 가 같은 방식으로
// 재야 두 수를 나란히 놓을 수 있다.

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
    VkImageView glyph_view, icon_view, color_view;
    VkImage glyph_image, icon_image, color_image;   // 온디맨드 성장은 view 가 아니라 image 에 복사한다
    // color_* 는 이모지 전용 RGBA 아틀라스다 — 글자 아틀라스는 커버리지(R8)라 컬러를 못 담는다.
    VkDeviceMemory glyph_mem, icon_mem, color_mem;
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
    // **좌우도 든다.** 곡면(waterfall) 화면은 유리가 옆으로 말려 그 띠의 글자가 휘어 보이고,
    // 가로 모드에서는 노치가 옆으로 간다 — 둘 다 `left`/`right` 로 온다. iOS 는 이미
    // `safeAreaInsets` 로 넷을 다 쓰고 있었고 여기만 위·아래만 읽고 있었다.
    int inset_top, inset_bottom, inset_left, inset_right;
    // **아래 셋은 로그 전용이다** — 제스처의 뜻도 관성도 코어가 든다(§3.1). iOS 에는 없다:
    // 이 플랫폼만 입력을 스크립트로 넣을 수 있어(`adb shell input`) 기기 판정이 여기서 돌고,
    // "손가락은 갔는데 화면은 안 흘렀다" 를 한 줄로 보이려면 손가락 쪽 값이 필요하다.
    float touch_last_y;   // 직전 MOVE 의 논리 y — 누적의 기준
    float touch_total_dy; // 이번 제스처에 손가락이 간 거리(화면이 흐른 양이 아니다)
    unsigned int ptr_id;  // 본문 제스처를 소유한 손가락 id
    int has_ptr_id;       // 소유자가 있나(0 이면 본문 제스처가 없다)
    int keyboard_px;      // 소프트 키보드가 덮는 높이(backing px) — Java `ImeInsets` 가 채운다
    int ready;
    int frames;
    double last_ms;
    double pace_ms[MARU_FRAME_PACE_SAMPLES];
    int n_pace;
    int pace_done;
    int64_t last_vsync_ns;  // 직전 vsync 시각 — 패널 주기를 여기서 잰다(하드코딩하지 않는다)
    int64_t last_draw_ns;   // 마지막으로 그린 vsync 시각. 목표 주기를 재는 기준
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
// 정의는 아래고 프레임 경로가 먼저 부른다 — 선언이 없으면 implicit declaration 이다.
static void drainConfigWrite(struct android_app *app);
static void syncInputKind(void);
static void raiseKeyboardIfAsked(void);
static void hideKeyboardIfAsked(void);
static void disconnectIfAsked(void);
static void startSshIfAsked(void);
static void dispatchKey(int32_t key_code, int32_t meta, int unicode);
static void publishPublicKey(struct android_app *app);
static void drainPassword(void);
static void driveControlChannel(void);

/// 단조 시계(ms). **시한을 재는 것은 host 의 일이다** — 코어에는 시계가 없다.
static unsigned long long nowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000ull + (unsigned long long)(ts.tv_nsec / 1000000);
}

static void drainHostKeyDecision(void);
static void frameCallback(int64_t frame_time_ns, void *data);  // onAppCmd 가 먼저라 선언이 필요하다
static uint8_t *g_glyph_px = NULL;
// **컬러 아틀라스도 원본을 들고 있는다**(글자 아틀라스의 `g_glyph_px` 와 같은 이유·같은 격자).
// 창이 부서지면 텍스처가 사라지는데 브리지의 컬러 등록부는 살아남는다 — 미스로도 안 올라와
// 다시 굽지 않으므로, 원본이 없으면 재개 뒤 **이모지가 영영 안 보인다**(실측: 홈으로 나갔다
// 돌아오니 이모지만 사라지고 한글·ASCII 는 멀쩡했다).
static uint8_t *g_color_px = NULL;
static jclass g_activity_cls = NULL; // MaruActivity — 네이티브 스레드에서 FindClass 가 안 된다
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
        (*env)->GetMethodID(env, pCls, "setTextSize", "(F)V"), (jfloat)maru_mobile_atlas_text_px());
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
        unsigned int one = cps[i]; // 미리 굽는 집합은 전부 단일 코드포인트(ASCII·박스)다
        maru_mobile_atlas_add(&one, 1, 0, col, row, advance);
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
    // 이모지 전용 RGBA 아틀라스. 글자 아틀라스와 **같은 격자**라 슬롯 좌표 규칙을 공유한다.
    // 처음에는 빈 픽셀로 서고 미스가 생길 때마다 그 칸만 채운다(글자 아틀라스와 같은 성장 경로).
    // 그 원본을 **들고 있는다** — 여기서 free 하면 창이 부서졌다 설 때 성장분이 통째로 사라지고,
    // 등록부는 그대로라 다시 굽지도 않아 이모지가 영영 빈칸이 된다(`g_color_px` 주석).
    if (g_gw && g_gh) {
        if (!g_color_px) g_color_px = calloc((size_t)g_gw * g_gh * 4, 1);
        if (g_color_px)
            uploadTexture(g_color_px, g_gw, g_gh, 4, VK_FORMAT_R8G8B8A8_UNORM,
                          &g.color_view, &g.color_image, &g.color_mem);
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
    VkDescriptorSetLayoutBinding binds[4] = {
        {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT},
        {.binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT},
        // binding 2 = draw-list. vertex 가 gl_InstanceIndex 로 읽는다.
        {.binding = 2, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_VERTEX_BIT},
        // binding 3 = 이모지 컬러 아틀라스(계약 §이모지 — 커버리지와 다른 텍스처).
        {.binding = 3, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT}};
    VkDescriptorSetLayoutCreateInfo dslci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                             .bindingCount = 4, .pBindings = binds};
    VkDescriptorSetLayout dsl; vkCreateDescriptorSetLayout(g.dev, &dslci, NULL, &dsl);
    g.dsl = dsl;
    VkDescriptorPoolSize dps[2] = {{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 3},
                                   {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1}};
    VkDescriptorPoolCreateInfo dpci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                                       .maxSets = 1, .poolSizeCount = 2, .pPoolSizes = dps};
    VkDescriptorPool dpool; vkCreateDescriptorPool(g.dev, &dpci, NULL, &dpool);
    g.dpool = dpool;
    VkDescriptorSetAllocateInfo dsai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                                        .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl};
    vkAllocateDescriptorSets(g.dev, &dsai, &g.dset);
    VkDescriptorImageInfo dii[3] = {
        {samp, g.glyph_view ? g.glyph_view : g.icon_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
        {samp, g.icon_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
        // 컬러 아틀라스가 아직 없으면 아이콘 뷰로 채운다 — 바인딩이 비면 검증 계층이 막는다.
        {samp, g.color_view ? g.color_view : g.icon_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL}};
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

    // **넷을 다 쓴다.** 레이아웃·풀만 늘리고 쓰기를 3 으로 두면 셰이더가 **한 번도 안 쓴
    // 디스크립터**를 샘플링해 UB 가 된다 — 에뮬레이터에서 VkDevice 는 만들어지는데 그 뒤로
    // 화면이 영영 안 나오고 그래픽 스택이 통째로 막혔다(실측).
    VkWriteDescriptorSet wds[4] = {
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = g.dset, .dstBinding = 0,
         .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii[0]},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = g.dset, .dstBinding = 1,
         .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii[1]},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = g.dset, .dstBinding = 2,
         .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &qdbi},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = g.dset, .dstBinding = 3,
         .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii[2]}};
    vkUpdateDescriptorSets(g.dev, 4, wds, 0, NULL);

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
    // 손을 뗀 뒤 남은 관성을 **경과한 시간만큼** 흘리고 감쇠시킨다(iOS `stepFling` 과 같은 값).
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
    // **좌우도 뺀다.** 안 빼면 곡면 화면에서 **본문 양끝 글자가 모서리에 말리고**, 가로
    // 모드에서는 노치 밑에 깔린다. 홀펀치·평면 기기에서는 이 값이 0 이라 아무 차이가 없어
    // **안 드러난 채 오래 잠복하는** 자리다.
    // **잰 값을 그대로 준다.** 하단 inset·키보드 겹침 보정과 하한은 코어가 한다
    // (`maru_mobile_available_logical`) — 예전에는 그 규칙이 여기와 iOS 의 ObjC 에 **각자**
    // 적혀 있었고, Java 의 `ImeInsets` 가 한 번 더 접고 있었다. 셋을 하나로 모았다.
    unsigned int lw = 0, lh = 0;
    maru_mobile_available_logical((unsigned int)g.extent.width, (unsigned int)g.extent.height,
                                  (unsigned int)g.inset_top, (unsigned int)g.inset_bottom,
                                  (unsigned int)g.inset_left, (unsigned int)g.inset_right,
                                  (unsigned int)g.keyboard_px,
                                  (unsigned int)(scale * 1000.0f + 0.5f), &lw, &lh);
    // **입력 스레드와 겹치는 구간만 막는다.** IME 가 `maru_mobile_input` 으로 코어에 쓰는
    // 것과 여기서 격자를 읽는 것이 겹치면 셀을 반쯤 쓴 상태로 읽는다. 오류 문자열도 두
    // 스레드가 만지므로 같이 넣는다.
    //
    // **아틀라스 성장은 밖에 둔다.** 굽기는 글자마다 `vkQueueWaitIdle` 로 GPU 를 기다리는데,
    // 그 동안 자물쇠를 쥐고 있으면 **타이핑이 GPU 를 기다리게 된다**. 성장이 만지는 등록부·
    // 미스 목록은 입력 스레드가 안 건드리므로 밖에 둬도 된다.
    pthread_mutex_lock(&g_bridge_lock);
    struct timespec fts;
    clock_gettime(CLOCK_MONOTONIC, &fts);
    unsigned int n = maru_mobile_build(lw, lh,
        (unsigned long long)fts.tv_sec * 1000ULL + (unsigned long long)(fts.tv_nsec / 1000000));
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
    // **친 것을 원격으로 보낸다.** 브리지가 인코딩해 모아 둔 것을 가져가 펌프에 넘긴다.
    // 셸이 뜨기 전에는 **안 가져간다** — 가져가면 우리 손에서 사라지는데 펌프는 아직 못 보내
    // 그 글자가 통째로 없어진다(브리지에 두면 type-ahead 로 남는다).
    if (maru_ssh_pump_is_running() && maru_ssh_pump_state() == MARU_SSH_STATE_READY) {
        static unsigned char input_buf[4096];
        unsigned long got = maru_mobile_take_input(input_buf, sizeof input_buf);
        if (got > 0) {
            unsigned long sent = maru_ssh_pump_write(input_buf, got);
            if (sent != got) LOGI("MARU_SSH input_partial sent=%lu of=%lu", sent, got);
        }
    }

    // **격자가 바뀌면 원격에 알린다.** 키보드가 오르내리면 보이는 행 수가 바뀌는데(그때 코어가
    // 격자를 다시 잡는다), 안 알리면 원격은 처음 크기를 믿고 그린다 — `less`·`vim` 이 화면
    // 절반에만 그리거나 줄이 어긋난다. 값은 코어에게 묻는다(host 가 따로 세면 갈린다).
    {
        static unsigned int last_cols, last_rows;
        unsigned int cols = maru_mobile_term_cols();
        unsigned int rows = maru_mobile_term_rows();
        if (cols && rows && (cols != last_cols || rows != last_rows)) {
            if (last_cols && maru_ssh_pump_is_running()) {
                maru_ssh_pump_resize(cols, rows);
                LOGI("MARU_SSH resize cols=%u rows=%u", cols, rows);
            }
            last_cols = cols;
            last_rows = rows;
        }
    }
    pthread_mutex_unlock(&g_bridge_lock);

    // build 가 못 그린 글자를 그 슬롯에만 구워 넣는다 — 다음 프레임에 보인다.
    if (g_app) growAtlas(g_app);
    // **저장 요청은 프레임마다 본다.** 값이 바뀐 그 프레임에만 실제 쓰기가 난다(가져가면
    // 요청이 사라진다) — 어느 화면에서 바뀌었든 한 자리에서 처리된다.
    if (g_app) drainConfigWrite(g_app);
    syncInputKind(); // 입력 대상이 바뀌면 키보드도 바꾼다
    raiseKeyboardIfAsked();
    hideKeyboardIfAsked();
    disconnectIfAsked();
    startSshIfAsked(); // 붙어 달라는 요청이 있으면 여기서 시작한다
    drainPassword(); // 사용자가 친 비밀번호를 펌프로 넘긴다
    drainHostKeyDecision(); // 지문 승인·거절도 같은 자리에서 나른다
    driveControlChannel(); // 목록 화면이 원하면 컨트롤 채널을 열고 요청을 나른다
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
    // **버퍼가 자랐으면 다음 프레임에 맞춘다.** 코어의 quad 버퍼는 격자가 커질 때만 자라고
    // (셀 속성이 붙어 한 칸이 최대 6 quad 를 낸다) 그 순간 우리 GPU 버퍼는 아직 작다.
    //
    // **여기서 return 하면 안 된다** — 이미 스왑체인 이미지를 acquire 했고 세마포어가 뜬
    // 상태라, 제출 없이 빠져나가면 다음 acquire 가 같은 세마포어를 다시 기다린다. 그래서
    // 이 한 프레임만 잘라 그리고 자원을 다시 세운다(다음 프레임부터 온전하다).
    unsigned int drawn = n;
    if (drawn > g.quad_cap) {
        drawn = g.quad_cap;
        LOGI("MARU_LIFECYCLE quad_cap_grew n=%u cap=%u", n, g.quad_cap);
        g.needs_recreate = 1;
    }
    Push *dst = (Push *)g.quad_map;
    for (unsigned int i = 0; i < drawn; i++) {
        const MaruQuad *q = &quads[i];
        // kind=3 은 슬롯의 **왼쪽 절반**이다(슬롯 하나가 양폭 상자다). 셰이더를 안 고치고
        // 열과 나누는 수를 함께 2배로 줘서 낸다 — 셰이더에는 kind=1 로 넘긴다.
        // kind 4·5 는 **컬러 아틀라스**(다른 텍스처)다. 5 는 그 왼쪽 절반이라 3 과 같은 배수
        // 규칙을 쓰고, 셰이더에는 3(=컬러)으로 넘긴다 — 텍스처만 다르고 좌표 규칙은 같다.
        int half = (q->kind == 3 || q->kind == 5);
        int is_color = (q->kind == 4 || q->kind == 5);
        float cols = (q->kind == 2) ? 1.0f : (float)g.atlas_cols * (half ? 2.0f : 1.0f);
        float rows = (q->kind == 2) ? (float)maru_mobile_icon_count() : (float)g.atlas_rows;
        float cx = (float)q->cell_x * (half ? 2.0f : 1.0f);
        float qkind = is_color ? 3.0f : (half ? 1.0f : (float)q->kind);
        float oy = (float)g.inset_top;
        // **가로도 밀어 준다.** 폭만 줄이고 원점을 안 옮기면 그림이 왼쪽 띠에 걸린 채로 좁아진다.
        float ox = (float)g.inset_left;
        Push p = {{q->x * scale + ox, q->y * scale + oy, (q->x + q->w) * scale + ox, (q->y + q->h) * scale + oy},
                  {q->r, q->g, q->b, q->a},
                  {q->radius * scale, (float)g.extent.width, (float)g.extent.height, qkind},
                  {cx, (float)q->cell_y, cols, rows}};
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
    if (g.frames >= MARU_FRAME_PACE_WARMUP && g.last_ms > 0 && g.n_pace < MARU_FRAME_PACE_SAMPLES)
        g.pace_ms[g.n_pace++] = now - g.last_ms;
    g.last_ms = now;
    if (g.n_pace == MARU_FRAME_PACE_SAMPLES) {
        for (int i = 1; i < MARU_FRAME_PACE_SAMPLES; i++) {
            double k = g.pace_ms[i]; int j = i - 1;
            while (j >= 0 && g.pace_ms[j] > k) { g.pace_ms[j + 1] = g.pace_ms[j]; j--; }
            g.pace_ms[j + 1] = k;
        }
        if (!g.pace_done) {
            g.pace_done = 1;
            // **계측은 동작을 바꾸지 않는다.** 예전에는 여기서 앱을 30Hz 로 전환해, 측정의
            // 부산물이 제품 동작이 됐다(그리고 iOS 엔 그 전환이 없어 두 플랫폼이 달랐다).
            double med = g.pace_ms[MARU_FRAME_PACE_SAMPLES / 2];
            int paced = (med >= MARU_FRAME_PACE_MIN_MS && med <= MARU_FRAME_PACE_MAX_MS);
            LOGI("MARU_PACE median_ms=%.2f n=%d target=%.2f verdict=%s",
                 med, MARU_FRAME_PACE_SAMPLES, MARU_FRAME_TARGET_MS, paced ? "PASS" : "FAIL");
        }
    }
    g.frames++;
}

// 상태바·제스처바 밑으로 UI 가 깔리지 않게 **실제 inset** 을 받아 온다. NDK 에는 inset
// API 가 없어서 JNI 로 `View.getRootWindowInsets()` 를 부른다 — iOS 의 `safeAreaInsets`
// 와 같은 자리다. 값을 못 얻으면 0 으로 두고 진행한다(그리기를 막을 이유는 없다).
static void queryInsets(struct android_app *app, int *top, int *bottom, int *left, int *right) {
    // **실패하면 이전 값을 지킨다.** 예전에는 먼저 0 으로 밀어 버려, 조회가 실패하면 UI 가
    // 조용히 상태바 밑으로 들어갔다 — 화면만 이상하고 이유는 안 보인다.
    int got_top = 0, got_bottom = 0, got_left = 0, got_right = 0, ok = 0;
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
    // **컷아웃도 함께 묻는다.** `systemBars()` 만 물으면 카메라 홀이 있는 기기에서 짧게 나온다 —
    // 이 에뮬레이터는 홀이 **y=64..130**(`cutoutSpec={M 507,64 a 33,33 ...}`)인데 systemBars 는
    // **63** 을 돌려준다. 그 값만 쓰면 **본문 첫 줄들이 카메라 구멍 뒤에 깔린다** — 화면 가운데
    // 글자가 이유 없이 안 보이는 자리가 된다.
    jclass typeCls = (*env)->FindClass(env, "android/view/WindowInsets$Type");
    jmethodID mBars = (*env)->GetStaticMethodID(env, typeCls, "systemBars", "()I");
    jmethodID mCut = (*env)->GetStaticMethodID(env, typeCls, "displayCutout", "()I");
    jint mask = (*env)->CallStaticIntMethod(env, typeCls, mBars);
    if (mCut) mask |= (*env)->CallStaticIntMethod(env, typeCls, mCut);
    jclass insCls = (*env)->GetObjectClass(env, ins);
    jmethodID mGet = (*env)->GetMethodID(env, insCls, "getInsets", "(I)Landroid/graphics/Insets;");
    jobject box = (*env)->CallObjectMethod(env, ins, mGet, mask);
    if (box) {
        jclass boxCls = (*env)->GetObjectClass(env, box);
        got_top = (*env)->GetIntField(env, box, (*env)->GetFieldID(env, boxCls, "top", "I"));
        got_bottom = (*env)->GetIntField(env, box, (*env)->GetFieldID(env, boxCls, "bottom", "I"));
        got_left = (*env)->GetIntField(env, box, (*env)->GetFieldID(env, boxCls, "left", "I"));
        got_right = (*env)->GetIntField(env, box, (*env)->GetFieldID(env, boxCls, "right", "I"));
        ok = 1;
    }
    (*vm)->DetachCurrentThread(vm);
    if (ok) {
        *top = got_top;
        // **하단 0 은 값이 아니라 가림의 표시다.** 소프트 키보드가 떠 있는 프레임에서는
        // 시스템이 `systemBars().bottom` 을 0 으로 보고한다 — 키보드가 navigation bar 를
        // 덮고 있어 바가 화면을 차지하지 않는다고 보기 때문이다. 그 0 을 저장하면 키보드를
        // 내린 뒤에도 남아 **보조 키바가 3버튼 위에 겹친다**(기기 실측: 키보드가 뜬 채
        // inset 재조회가 겹친 뒤 `bottom=135` 가 `bottom=0` 으로 바뀌었다).
        //
        // 키보드가 덮는 높이는 `keyboard_px` 가 따로 들고 있으므로 여기서 겹쳐 뺄 일이 없다.
        if (got_bottom > 0) *bottom = got_bottom;
        *left = got_left;
        *right = got_right;
    } else LOGI("insets_read_failed");
}

// **입력**: 문자는 IME 가 만든다. `MaruActivity.java` 가 `InputConnection` 으로 받아
// 여기로 넘긴다 — keycode→ASCII 표를 손으로 짜면 한글을 못 만든다(그게 shim 을 둔 이유다).
//
// 조합 중 문자열은 **셸로 보내지 않는다**. 화면에만 흐리게 그릴 겉치레라서, 코어의 입력
// 경로가 아니라 별도 상태로 둔다(docs/mobile-platform.md §1).
// **JNI 는 진짜 UTF-8 을 안 준다.** `GetStringUTFChars` 는 modified UTF-8(CESU-8)이라
// U+1F600 이 F0 9F 98 80 이 아니라 서러게이트 쌍 6바이트(ED A0 BD ED B8 80)로 온다. 그대로
// 코어에 넣으면 VT 파서가 write **전체**를 거부해 — 이모지만이 아니라 같이 친 글자까지 —
// 사라진다(사용자에겐 "이모지를 눌렀는데 아무 일도 안 일어난다"). UTF-16 을 직접 받아
// 서러게이트 쌍을 합쳐 4바이트로 낸다. 돌려주는 값은 쓴 바이트 수.
static size_t utf16ToUtf8(const jchar *u, jsize n, char *out, size_t cap) {
    size_t o = 0;
    for (jsize i = 0; i < n; i++) {
        unsigned int cp = u[i];
        // 상위 서러게이트 + 하위 서러게이트 = BMP 밖 한 글자.
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < n && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (u[i + 1] - 0xDC00);
            i++;
        } else if (cp >= 0xD800 && cp <= 0xDFFF) {
            // 짝 없는 서러게이트. **조용히 흘리지 않는다** — 넣으면 코어가 커밋 전체를 버린다.
            LOGI("MARU_INPUT lone_surrogate=%04X", cp);
            continue;
        }
        size_t need = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
        if (o + need > cap) {
            // **조용히 자르지 않는다.** 여기서 그냥 멈추면 사용자가 붙여넣은 긴 글이 소리
            // 없이 짧아진다 — 브리지의 `copy_truncated` 와 같은 규율이다.
            LOGI("MARU_INPUT truncated_at=%zu utf16_left=%d", o, (int)(n - i));
            break;
        }
        if (need == 1) {
            out[o++] = (char)cp;
        } else if (need == 2) {
            out[o++] = (char)(0xC0 | (cp >> 6));
            out[o++] = (char)(0x80 | (cp & 0x3F));
        } else if (need == 3) {
            out[o++] = (char)(0xE0 | (cp >> 12));
            out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (char)(0x80 | (cp & 0x3F));
        } else {
            out[o++] = (char)(0xF0 | (cp >> 18));
            out[o++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (char)(0x80 | (cp & 0x3F));
        }
    }
    return o;
}

// **UTF-8 → UTF-16.** 클립보드로 나가는 쪽이다(`utf16ToUtf8` 의 반대). BMP 밖 글자는
// 서러게이트 쌍으로 되돌린다 — Java 문자열이 그 표현이기 때문이다.
static jsize utf8ToUtf16(const char *s, size_t n, jchar *out, jsize cap) {
    jsize o = 0;
    size_t i = 0;
    while (i < n && o < cap) {
        unsigned char c = (unsigned char)s[i];
        unsigned int cp;
        size_t take;
        if (c < 0x80) { cp = c; take = 1; }
        else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; take = 2; }
        else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; take = 3; }
        else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; take = 4; }
        else { i++; continue; } // 이어지는 바이트로 시작 — 브리지가 경계에서 자르므로 안 온다
        if (i + take > n) break;
        for (size_t k = 1; k < take; k++) cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3F);
        i += take;
        if (cp < 0x10000) {
            out[o++] = (jchar)cp;
        } else {
            if (o + 2 > cap) break;
            cp -= 0x10000;
            out[o++] = (jchar)(0xD800 + (cp >> 10));
            out[o++] = (jchar)(0xDC00 + (cp & 0x3FF));
        }
    }
    return o;
}

JNIEXPORT void JNICALL
Java_dev_maru_MaruActivity_nativeComposing(JNIEnv *env, jclass cls, jstring text) {
    (void)cls;
    static char buf[512];
    size_t n = 0;
    if (text) {
        const jchar *u = (*env)->GetStringChars(env, text, NULL);
        if (u) {
            n = utf16ToUtf8(u, (*env)->GetStringLength(env, text), buf, sizeof buf);
            (*env)->ReleaseStringChars(env, text, u);
        }
    }
    // **UI 스레드다.** 렌더 스레드가 브리지를 읽는 동안 끼어들면 안 된다(파일 위 주석).
    pthread_mutex_lock(&g_bridge_lock);
    maru_mobile_set_preedit(buf, (unsigned int)n);
    pthread_mutex_unlock(&g_bridge_lock);
}

// ── SSH 세션(S9-3) ──────────────────────────────────────────────────────────
//
// **소켓 루프는 여기 없다.** 두 host 가 함께 쓰는 `ssh_pump.c` 가 든다 — 이 파일이 하는 일은
// 자물쇠와 화면 훅을 채워 주는 것뿐이다(docs/mobile-platform.md §3.0).

static void ssh_lock(void *ctx) {
    (void)ctx;
    pthread_mutex_lock(&g_bridge_lock);
}

static void ssh_unlock(void *ctx) {
    (void)ctx;
    pthread_mutex_unlock(&g_bridge_lock);
}

/// 원격 출력을 화면에 넣는다. **자물쇠는 펌프가 이미 잡았다**(위 훅) — 여기서 또 잡으면 죽는다.
static void ssh_screen(void *ctx, const unsigned char *bytes, unsigned long len) {
    (void)ctx;
    maru_mobile_term_write(bytes, len);
}

// **컨트롤 채널의 ndjson**(S10d-3). 화면 훅과 **다른 자리**로 온다 — 합치면 파서가 사람 화면을
// 읽게 된다(계약 §4a).
static void ssh_control(void *ctx, const unsigned char *bytes, unsigned long len) {
    (void)ctx;
    maru_mobile_control_feed(bytes, len);
}

static unsigned long ssh_take_response(void *ctx, unsigned char *out, unsigned long cap) {
    (void)ctx;
    return maru_mobile_take_response(out, cap);
}

/// OS 난수. **키 씨앗과 세션 난수가 여기서 나온다** — 브리지는 OS 를 못 부른다.
static int getEntropy(unsigned char *out, unsigned long len) {
    unsigned long off = 0;
    while (off < len) {
        long n = getrandom(out + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        off += (unsigned long)n;
    }
    return 0;
}

/// 서비스 클래스. **세션이 끝났다고 알릴 자리**라 들고 있는다.
static jclass g_ssh_service_cls;

static void ssh_state(void *ctx, unsigned int state) {
    (void)ctx;
    // **상태를 로그로 남긴다.** 기기에서 "안 붙는다" 를 볼 때 어디까지 갔는지가 첫 단서다.
    LOGI("MARU_SSH state=%u error=%s", state, maru_ssh_pump_error());
    // **입력 목적지를 세션과 함께 옮긴다.** 안 옮기면 사용자가 친 글자가 화면에 한 번 찍히고
    // 원격에는 영영 안 간다(실측). 세션이 끝나면 로컬로 되돌린다 — 안 되돌리면 그 뒤 입력이
    // 아무 데도 안 가고 조용히 쌓인다.
    pthread_mutex_lock(&g_bridge_lock);
    maru_mobile_set_input_sink(state == MARU_SSH_STATE_CLOSED ? 0 : 1);
    // **상태와 실패 이름을 화면에 알린다.** 이름 → 사람 말은 브리지가 한다(host 마다 적으면 갈린다).
    {
        const char *err = maru_ssh_pump_error();
        maru_mobile_set_ssh_status(state, (const unsigned char *)err, err ? strlen(err) : 0);
    }
    // **비밀번호를 물어야 하면 화면을 연다** — 그 자리에서 펌프가 기다리고 있다. 벗어나면 끈다:
    // 세션이 끝났는데 화면만 남으면 사용자는 안 가는 곳에 계속 친다.
    maru_mobile_set_password_prompt(state == MARU_SSH_STATE_PASSWORD_NEEDED ? 1 : 0);
    // **처음 보는 서버면 지문을 물어야 한다.** 지문이 이미 있으면 펌프가 그 자리에서 판정하고
    // 이 상태를 스쳐 지나가므로, 그때는 화면이 안 뜬다(`fp` 를 넘겨도 펌프가 먼저 끝낸다).
    if (state == MARU_SSH_STATE_HOST_KEY_DECISION) {
        const char *fp = maru_ssh_pump_host_key_fingerprint();
        if (fp && fp[0]) maru_mobile_set_host_key_prompt((const unsigned char *)fp, strlen(fp));
    } else {
        maru_mobile_set_host_key_prompt((const unsigned char *)"", 0);
    }
    pthread_mutex_unlock(&g_bridge_lock);
    if (state != MARU_SSH_STATE_CLOSED) return;
    // **끝났으면 서비스를 내린다.** 안 내리면 알림이 "유지 중" 인 채로 남아, 끊긴 것을 알리는
    // 대신 붙어 있다고 거짓말한다.
    if (!g_ssh_service_cls || !g_app) return;
    JNIEnv *env = NULL;
    JavaVM *vm = g_app->activity->vm;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return;
    jmethodID m = (*env)->GetStaticMethodID(env, g_ssh_service_cls, "onSessionEnded", "()V");
    if (m) (*env)->CallStaticVoidMethod(env, g_ssh_service_cls, m);
    (*vm)->DetachCurrentThread(vm);
    LOGI("MARU_SSH service_stopped");
}

/// 접속 정보를 든다. **문자열은 우리가 소유한다** — 펌프는 `start` 가 도는 동안 이 포인터를 본다.
static char g_ssh_host[256];
static char g_ssh_user[128];
static char g_ssh_fingerprint[128];
static unsigned char g_ssh_secret[MARU_SSH_SECRET_KEY_BYTES];

/// **키를 만든다**(계약 §3.4 — 키는 앱이 만든다). 씨앗은 OS 난수이고, 나온 64바이트를 Java 가
/// 받아 Keystore 로 봉인한다. 공개키 한 줄은 여기서 로그·파일로 낸다 — 화면에 보여 주는 자리
/// (S9c-4)가 아직 없어서인데, **공개키라 밖에 나가도 되는 값**이다.
JNIEXPORT jbyteArray JNICALL
Java_dev_maru_MaruKeyStore_nativeGenerateKey(JNIEnv *env, jclass cls) {
    (void)cls;
    unsigned char seed[MARU_SSH_ENTROPY_BYTES];
    if (getEntropy(seed, sizeof seed) != 0) {
        LOGI("MARU_SSH entropy_failed");
        return NULL;
    }
    unsigned char secret[MARU_SSH_SECRET_KEY_BYTES];
    unsigned char line[256];
    int rc = maru_mobile_ssh_generate_key(seed, secret, line, sizeof line);
    memset(seed, 0, sizeof seed);
    if (rc != MARU_SSH_OK) {
        LOGI("MARU_SSH generate_failed=%s", maru_mobile_ssh_last_load_error());
        return NULL;
    }
    LOGI("MARU_SSH generated_public_key %s", (const char *)line);
    if (g_app && g_app->activity && g_app->activity->internalDataPath) {
        char path[1024];
        snprintf(path, sizeof path, "%s/id_ed25519.pub", g_app->activity->internalDataPath);
        FILE *f = fopen(path, "wb");
        if (f) {
            fprintf(f, "%s\n", (const char *)line);
            fclose(f);
        }
    }
    jbyteArray out = (*env)->NewByteArray(env, MARU_SSH_SECRET_KEY_BYTES);
    if (out) (*env)->SetByteArrayRegion(env, out, 0, MARU_SSH_SECRET_KEY_BYTES, (const jbyte *)secret);
    memset(secret, 0, sizeof secret);
    return out;
}

JNIEXPORT void JNICALL
Java_dev_maru_MaruSshService_nativeSshStart(JNIEnv *env, jclass cls, jstring host, jint port,
                                            jstring user, jbyteArray sealed_secret, jstring fingerprint) {
    if (!host || !user || !sealed_secret || !fingerprint) {
        LOGI("MARU_SSH start_missing_args");
        return;
    }
    // **이미 돌고 있으면 아무것도 안 건드린다.** 먼저 덮어쓰고 나중에 거절하면, 도는 세션이
    // 보고 있는 값이 그 사이 바뀐다.
    //
    // 판정은 **`is_running` 으로 한다 — 상태가 아니다.** 끝난 세션도 `CLOSED` 를 들고 있어야
    // host 가 알림을 내릴 수 있어서, 상태로 재면 한 번 끊긴 뒤로 **재접속이 영영 막힌다**.
    if (maru_ssh_pump_is_running()) {
        LOGI("MARU_SSH already_running state=%u", maru_ssh_pump_state());
        return;
    }
    if (!g_ssh_service_cls) g_ssh_service_cls = (*env)->NewGlobalRef(env, cls);
    const char *h = (*env)->GetStringUTFChars(env, host, NULL);
    snprintf(g_ssh_host, sizeof g_ssh_host, "%s", h ? h : "");
    if (h) (*env)->ReleaseStringUTFChars(env, host, h);
    const char *u = (*env)->GetStringUTFChars(env, user, NULL);
    snprintf(g_ssh_user, sizeof g_ssh_user, "%s", u ? u : "");
    if (u) (*env)->ReleaseStringUTFChars(env, user, u);
    const char *f = (*env)->GetStringUTFChars(env, fingerprint, NULL);
    snprintf(g_ssh_fingerprint, sizeof g_ssh_fingerprint, "%s", f ? f : "");
    if (f) (*env)->ReleaseStringUTFChars(env, fingerprint, f);

    // **키는 Keystore 가 봉인해 둔 것이다**(Java 쪽 `MaruKeyStore`). 여기서는 그 64바이트를
    // 받아 쓰고, 받은 배열은 Java 가 곧바로 지운다 — 파일에서 읽는 경로는 없앴다.
    if ((*env)->GetArrayLength(env, sealed_secret) != MARU_SSH_SECRET_KEY_BYTES) {
        LOGI("MARU_SSH key_bad_length");
        return;
    }
    (*env)->GetByteArrayRegion(env, sealed_secret, 0, MARU_SSH_SECRET_KEY_BYTES, (jbyte *)g_ssh_secret);

    MaruSshPumpConfig cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.host = g_ssh_host;
    cfg.port = (unsigned short)port;
    cfg.user = g_ssh_user;
    cfg.secret = g_ssh_secret;
    // **격자 크기는 코어가 안다.** host 가 따로 세면 두 값이 갈린다.
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int cols = maru_mobile_term_cols();
    unsigned int rows = maru_mobile_term_rows();
    pthread_mutex_unlock(&g_bridge_lock);
    cfg.cols = cols ? cols : 80;
    cfg.rows = rows ? rows : 24;
    cfg.expect_fingerprint = g_ssh_fingerprint;

    MaruSshPumpHooks hooks;
    memset(&hooks, 0, sizeof hooks);
    hooks.lock = ssh_lock;
    hooks.unlock = ssh_unlock;
    hooks.screen = ssh_screen;
    hooks.take_response = ssh_take_response;
    hooks.state_changed = ssh_state;
    // **훅이 없으면 채널을 못 연다**(펌프가 거절한다) — 받을 사람이 없으면 코어가 배압으로
    // 멈추고 터미널까지 함께 멎기 때문이다.
    hooks.control = ssh_control;

    // **새 연결이면 컨트롤 축도 처음부터**(계약 §4a — iOS 와 같은 자리). 안 그러면 끊겼다 다시
    // 붙었을 때 죽은 세션 목록이 살아 있는 것처럼 남는다.
    maru_mobile_control_reset();

    int rc = maru_ssh_pump_start(&cfg, &hooks);
    // 푼 키는 펌프가 복사해 갔다 — 여기 사본은 지운다.
    memset(g_ssh_secret, 0, sizeof g_ssh_secret);
    LOGI("MARU_SSH start host=%s port=%d user=%s rc=%d", g_ssh_host, (int)port, g_ssh_user, rc);
}

JNIEXPORT void JNICALL
Java_dev_maru_MaruSshService_nativeSshStop(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    maru_ssh_pump_stop();
    LOGI("MARU_SSH stopped error=%s", maru_ssh_pump_error());
}

JNIEXPORT void JNICALL
Java_dev_maru_MaruActivity_nativeCommit(JNIEnv *env, jclass cls, jstring text) {
    (void)cls;
    if (!text) return;
    const jchar *u = (*env)->GetStringChars(env, text, NULL);
    if (u) {
        static char buf[4096];
        jsize ulen = (*env)->GetStringLength(env, text);
        size_t n = utf16ToUtf8(u, ulen, buf, sizeof buf);
        (*env)->ReleaseStringChars(env, text, u);
        pthread_mutex_lock(&g_bridge_lock);
        unsigned int total = maru_mobile_input(buf, n);
        pthread_mutex_unlock(&g_bridge_lock);
        LOGI("MARU_INPUT commit_bytes=%zu utf16=%d total=%u", n, (int)ulen, total);
    }
}

// IME 가 문자로 주지 않는 키만 여기로 온다(백스페이스·엔터 등).
JNIEXPORT void JNICALL
Java_dev_maru_MaruActivity_nativeLongPressMs(JNIEnv *env, jclass cls, jint ms) {
    // **여기서 클래스를 잡아 둔다.** 네이티브 스레드에서 `FindClass` 로 앱 클래스를 찾으면
    // 시스템 클래스로더를 보게 돼 **조용히 못 찾는다**(복사가 그 자리에서 말없이 죽었다).
    // Java 에서 들어온 호출은 올바른 클래스로더 위에 있으므로 그때 전역 참조로 붙든다.
    if (!g_activity_cls) g_activity_cls = (jclass)(*env)->NewGlobalRef(env, cls);
    // **OS 가 정한 값을 그대로 넘긴다.** 사용자가 접근성 설정으로 바꿀 수 있는 값이라
    // 코어가 박아 두면 그 설정을 무시하게 된다.
    pthread_mutex_lock(&g_bridge_lock);
    maru_mobile_set_long_press_ms((unsigned int)ms);
    unsigned int got = maru_mobile_long_press_ms();
    pthread_mutex_unlock(&g_bridge_lock);
    LOGI("MARU_INPUT long_press_ms=%u (sent %d)", got, ms);
}

/// 소프트 키보드가 덮는 높이(px). 레이아웃 가용 높이에서 뺀다.
///
/// **`adjustResize` 로는 안 된다** — targetSdk 35(Android 15)부터 edge-to-edge 가 강제되어
/// 그 값이 무시된다. 안 빼면 키보드가 화면 절반을 덮는데 레이아웃은 그대로라 하단(보조 키바·
/// 상태바)이 통째로 가려진다. iOS 는 같은 일을 `UIKeyboardWillChangeFrame` 으로 한다.
JNIEXPORT void JNICALL
Java_dev_maru_MaruActivity_nativeKeyboardHeight(JNIEnv *env, jclass cls, jint px) {
    (void)env;
    (void)cls;
    if (g.keyboard_px == (int)px) return;
    const int was = g.keyboard_px;
    g.keyboard_px = (int)px;
    LOGI("MARU_KEYBOARD height=%d", (int)px);
    // **사라졌으면 코어에 알린다.** 판단은 코어가 한다(§3) — host 는 "없어졌다" 는 사실만 넘긴다.
    if (was > 0 && px == 0) {
        pthread_mutex_lock(&g_bridge_lock);
        maru_mobile_keyboard_hidden();
        pthread_mutex_unlock(&g_bridge_lock);
    }
}

/// 하단 시스템 바가 차지하는 높이(px). Java `ImeInsets` 가 inset 이 바뀔 때마다 넘긴다.
///
/// **`queryInsets` 만으로는 부족하다** — 그것은 창이 생기거나 크기가 바뀔 때만 도는데,
/// 3버튼/제스처 전환처럼 창 크기가 안 변하면서 바 높이만 바뀌는 경우를 놓친다. 리스너는
/// 시스템이 값을 갱신할 때마다 불리므로 이쪽이 최신이다.
JNIEXPORT void JNICALL
Java_dev_maru_MaruActivity_nativeBottomInset(JNIEnv *env, jclass cls, jint px) {
    (void)env;
    (void)cls;
    // 0 은 키보드에 가려진 프레임의 보고다 — 위 `queryInsets` 와 같은 이유로 안 받는다.
    if (px <= 0) return;
    if (g.inset_bottom == (int)px) return;
    g.inset_bottom = (int)px;
    LOGI("MARU_INSET bottom=%d", (int)px);
}

/// 밀린 화면을 하나 뺀다(하드웨어 뒤로가기). 1=뺐다, 0=뺄 것이 없어 host 가 알아서 한다.
JNIEXPORT jint JNICALL
Java_dev_maru_MaruActivity_nativePopScreen(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int popped = maru_mobile_pop_screen();
    pthread_mutex_unlock(&g_bridge_lock);
    return (jint)popped;
}

JNIEXPORT jint JNICALL
Java_dev_maru_MaruActivity_nativeInputKind(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int k = maru_mobile_input_kind();
    pthread_mutex_unlock(&g_bridge_lock);
    return (jint)k;
}

/// **눌러 둔 보조 키바 수정자.** IME shim 이 조합을 건너뛸지 판정하는 데 쓴다 — `Ctrl+B` 는
/// 조합할 글자가 아니라 **지금 나가야 하는 시퀀스**다(아래 `setComposingText` 주석).
JNIEXPORT jint JNICALL
Java_dev_maru_MaruActivity_nativeArmedMods(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int m = maru_mobile_armed_mods();
    pthread_mutex_unlock(&g_bridge_lock);
    return (jint)m;
}

/// 입력 종류가 바뀌면 **이미 떠 있는 키보드를 갈아 끼운다**. `inputType` 만 바꾸면 다음에 열 때나
/// 반영된다 — 사용자는 숫자 칸을 눌렀는데 글자 키보드를 계속 본다.
/// 키보드를 올려 달라는 요청을 실행한다. Java 쪽 `showKeyboard` 가 `showSoftInput` 을 부른다.
static void raiseKeyboardIfAsked(void) {
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int want = maru_mobile_take_keyboard_raise();
    pthread_mutex_unlock(&g_bridge_lock);
    if (!want || !g_activity_cls || !g_app) return;
    JNIEnv *env = NULL;
    JavaVM *vm = g_app->activity->vm;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return;
    jmethodID m = (*env)->GetStaticMethodID(env, g_activity_cls, "raiseKeyboard", "()V");
    if (m) (*env)->CallStaticVoidMethod(env, g_activity_cls, m);
    (*vm)->DetachCurrentThread(vm);
    LOGI("MARU_INPUT keyboard_raised");
}

/// 키보드를 내려 달라는 요청을 실행한다(올리는 쪽과 대칭).
static void hideKeyboardIfAsked(void) {
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int want = maru_mobile_take_keyboard_hide();
    pthread_mutex_unlock(&g_bridge_lock);
    if (!want || !g_activity_cls || !g_app) return;
    JNIEnv *env = NULL;
    JavaVM *vm = g_app->activity->vm;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return;
    jmethodID m = (*env)->GetStaticMethodID(env, g_activity_cls, "hideKeyboard", "()V");
    if (m) (*env)->CallStaticVoidMethod(env, g_activity_cls, m);
    (*vm)->DetachCurrentThread(vm);
    LOGI("MARU_INPUT keyboard_hidden");
}

/// 끊어 달라는 요청을 실행한다. **펌프만 세운다** — 화면은 상태가 바뀌는 것을 보고 저절로
/// 따라가므로 여기서 화면을 밀지 않는다(두 곳이 같은 일을 하면 어긋난다).
static void disconnectIfAsked(void) {
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int want = maru_mobile_take_disconnect();
    pthread_mutex_unlock(&g_bridge_lock);
    if (!want) return;
    if (!maru_ssh_pump_is_running()) return; // 이미 끊겼다 — 부를 것이 없다
    LOGI("MARU_SSH disconnect_requested");
    maru_ssh_pump_stop();
}

/// **붙어 달라는 요청을 실행한다.** 어느 서버인지는 브리지가 말하고(config 가 단일 출처,
/// docs/mobile-config.md §4.3) 여기서는 소켓을 드는 자리를 만들 뿐이다 — 포그라운드 서비스가
/// 배경에서도 세션을 살려 둔다(§3.0).
///
/// **파일을 여기서 다시 읽지 않는다.** 예전에는 `ssh.conf` 를 이 host 가 직접 파싱했는데,
/// 그러면 같은 사실이 두 자리에 살아 화면이 고른 것과 갈린다.
static void startSshIfAsked(void) {
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int req = maru_mobile_take_server_connect();
    unsigned char host[256], user[MARU_SSH_MAX_USER], fp[128];
    unsigned long host_len = 0, user_len = 0, fp_len = 0;
    unsigned int port = 0;
    if (req) {
        unsigned int idx = req - 1;
        host_len = maru_mobile_server_field(idx, MARU_SERVER_HOST, host, sizeof host);
        user_len = maru_mobile_server_field(idx, MARU_SERVER_USER, user, sizeof user);
        fp_len = maru_mobile_server_field(idx, MARU_SERVER_FINGERPRINT, fp, sizeof fp);
        port = maru_mobile_server_port(idx);
    }
    pthread_mutex_unlock(&g_bridge_lock);
    if (!req) return;
    // **비어 있으면 안 붙는다.** 브리지가 온전한 줄만 요청하지만, 버퍼가 모자라도 0 이 오므로
    // (자르지 않는 계약) 여기서도 본다 — 반쪽 주소로 붙으면 실패가 오타처럼 보인다.
    //
    // **지문은 빼고 본다.** 처음 붙는 서버는 지문이 없는 것이 정상이고(그때 화면이 묻는다),
    // 여기서 필수로 보면 그 서버에는 영영 못 붙는다 — 같은 규칙을 브리지와 여기 두 곳에서
    // 세다가 실제로 그렇게 갈렸다.
    if (!host_len || !user_len || !port) {
        LOGI("MARU_SSH connect_incomplete index=%u", req - 1);
        return;
    }
    if (!g_activity_cls || !g_app) return;
    JNIEnv *env = NULL;
    JavaVM *vm = g_app->activity->vm;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return;
    jmethodID m = (*env)->GetStaticMethodID(env, g_activity_cls, "startSsh",
                                            "(Ljava/lang/String;ILjava/lang/String;Ljava/lang/String;)V");
    if (m) {
        // 길이로 오므로 0 을 붙여 넘긴다(ABI 는 끝에 0 을 안 붙인다).
        host[host_len] = 0;
        user[user_len] = 0;
        fp[fp_len] = 0;
        jstring jhost = (*env)->NewStringUTF(env, (const char *)host);
        jstring juser = (*env)->NewStringUTF(env, (const char *)user);
        jstring jfp = (*env)->NewStringUTF(env, (const char *)fp);
        (*env)->CallStaticVoidMethod(env, g_activity_cls, m, jhost, (jint)port, juser, jfp);
        (*env)->DeleteLocalRef(env, jhost);
        (*env)->DeleteLocalRef(env, juser);
        (*env)->DeleteLocalRef(env, jfp);
        LOGI("MARU_SSH connect_requested index=%u port=%u", req - 1, port);
    }
    (*vm)->DetachCurrentThread(vm);
}

static void syncInputKind(void) {
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int k = maru_mobile_input_kind();
    pthread_mutex_unlock(&g_bridge_lock);
    static unsigned int last = 0xFFFFFFFF;
    if (k == last) return;
    last = k;
    if (!g_activity_cls || !g_app) return;
    JNIEnv *env = NULL;
    JavaVM *vm = g_app->activity->vm;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return;
    jmethodID m = (*env)->GetStaticMethodID(env, g_activity_cls, "restartInput", "()V");
    if (m) (*env)->CallStaticVoidMethod(env, g_activity_cls, m);
    (*vm)->DetachCurrentThread(vm);
    LOGI("MARU_INPUT kind=%u keyboard_restarted", k);
}

JNIEXPORT void JNICALL
Java_dev_maru_MaruActivity_nativeKey(JNIEnv *env, jclass cls, jint key_code, jint meta,
                                     jint unicode) {
    (void)env; (void)cls;
    dispatchKey(key_code, meta, unicode);
}

/// 키 하나를 브리지로 보낸다. **두 경로가 여기로 모인다** — Java 의 InputConnection
/// (`nativeKey`)과 네이티브 입력 큐(`onInputEvent`). 각자 표를 들면 어느 한쪽에서만 되는
/// 키가 생긴다.
static void dispatchKey(int32_t key_code, int32_t meta, int unicode) {
    // Android meta 비트 → 우리 표. Meta(⌘) 는 안드로이드에서 META_META_ON 이다.
    // **표를 스위치보다 먼저 만든다** — 이름 붙은 키가 아닐 때 수정자를 봐야 하기 때문이다.
    unsigned int mods = 0;
    if (meta & AMETA_SHIFT_ON) mods |= MARU_MOD_SHIFT;
    if (meta & AMETA_CTRL_ON)  mods |= MARU_MOD_CTRL;
    if (meta & AMETA_ALT_ON)   mods |= MARU_MOD_ALT;
    if (meta & AMETA_META_ON)  mods |= MARU_MOD_CMD;
    // **바이트를 손으로 적지 않는다.** 키를 그대로 넘기면 코어의 `encodeKey` 가 DECCKM(커서키
    // 모드)·수정자·kitty 프로토콜을 반영해 만든다 — 예전에는 여기서 `\r`·`0x7F` 를 적어 넣어
    // 화살표도 Ctrl 조합도 아예 없었다.
    unsigned int id;
    switch (key_code) {
        case AKEYCODE_ENTER:        id = MARU_KEY_ENTER; break;
        case AKEYCODE_DEL:          id = MARU_KEY_BACKSPACE; break;
        case AKEYCODE_FORWARD_DEL:  id = MARU_KEY_DELETE; break;
        case AKEYCODE_TAB:          id = MARU_KEY_TAB; break;
        case AKEYCODE_ESCAPE:       id = MARU_KEY_ESCAPE; break;
        case AKEYCODE_DPAD_UP:      id = MARU_KEY_UP; break;
        case AKEYCODE_DPAD_DOWN:    id = MARU_KEY_DOWN; break;
        case AKEYCODE_DPAD_LEFT:    id = MARU_KEY_LEFT; break;
        case AKEYCODE_DPAD_RIGHT:   id = MARU_KEY_RIGHT; break;
        case AKEYCODE_MOVE_HOME:    id = MARU_KEY_HOME; break;
        case AKEYCODE_MOVE_END:     id = MARU_KEY_END; break;
        case AKEYCODE_INSERT:       id = MARU_KEY_INSERT; break;
        case AKEYCODE_PAGE_UP:      id = MARU_KEY_PAGE_UP; break;
        case AKEYCODE_PAGE_DOWN:    id = MARU_KEY_PAGE_DOWN; break;
        default:
            if (key_code >= AKEYCODE_F1 && key_code <= AKEYCODE_F12) {
                id = MARU_KEY_F(key_code - AKEYCODE_F1 + 1);
                break;
            }
            // **수정자가 붙은 문자는 여기서 코어에 태운다.** IME 는 Ctrl+C 를 `commitText` 로
            // 주지 않으므로(그건 글자가 아니다) 이 자리가 없으면 **조용히 사라진다** — 블루투스
            // 키보드를 붙인 태블릿·크롬북에서 Ctrl+C 로 프로세스를 못 멈췄다. iOS 는 같은 키를
            // `charactersIgnoringModifiers` 로 태우고 있었다(대칭이 빠져 있었다).
            // **설정 칸을 편집 중이면 맨 글자도 받는다.** 소프트 키보드는 글자를 `commitText`
            // 로 주지만 하드웨어 키보드는 키 이벤트로 준다 — 그 자리에서 버리면 블루투스
            // 키보드로는 설정값을 못 친다(에뮬레이터의 `input text` 도 같은 경로다).
            // **숫자 칸만 보면 안 된다**(kind==1): 색 같은 글자 칸(kind==2)도 같은 목적지다.
            if (unicode > 0 && !(mods & (MARU_MOD_CTRL | MARU_MOD_ALT | MARU_MOD_CMD))) {
                pthread_mutex_lock(&g_bridge_lock);
                unsigned int kind = maru_mobile_input_kind();
                if (kind != 0) {
                    // **UTF-8 로 적는다** — ASCII 만 넣으면 글자 칸에서 한글·기호가 사라진다.
                    unsigned char utf8[4];
                    unsigned int c = (unsigned int)unicode;
                    int n = 0;
                    if (c < 0x80) { utf8[n++] = (unsigned char)c; }
                    else if (c < 0x800) {
                        utf8[n++] = (unsigned char)(0xC0 | (c >> 6));
                        utf8[n++] = (unsigned char)(0x80 | (c & 0x3F));
                    } else if (c < 0x10000) {
                        utf8[n++] = (unsigned char)(0xE0 | (c >> 12));
                        utf8[n++] = (unsigned char)(0x80 | ((c >> 6) & 0x3F));
                        utf8[n++] = (unsigned char)(0x80 | (c & 0x3F));
                    } else if (c <= 0x10FFFF) {
                        utf8[n++] = (unsigned char)(0xF0 | (c >> 18));
                        utf8[n++] = (unsigned char)(0x80 | ((c >> 12) & 0x3F));
                        utf8[n++] = (unsigned char)(0x80 | ((c >> 6) & 0x3F));
                        utf8[n++] = (unsigned char)(0x80 | (c & 0x3F));
                    }
                    if (n) maru_mobile_input(utf8, (unsigned long)n);
                }
                pthread_mutex_unlock(&g_bridge_lock);
                if (kind != 0) return;
            }
            if ((mods & (MARU_MOD_CTRL | MARU_MOD_ALT | MARU_MOD_CMD)) && unicode > 0) {
                pthread_mutex_lock(&g_bridge_lock);
                unsigned int total = maru_mobile_key(MARU_KEY_CHAR, (unsigned int)unicode, mods);
                pthread_mutex_unlock(&g_bridge_lock);
                LOGI("MARU_INPUT key=char mods=%u total=%u", mods, total);
                return;
            }
            return;
    }

    pthread_mutex_lock(&g_bridge_lock);
    maru_mobile_key(id, 0, mods);
    pthread_mutex_unlock(&g_bridge_lock);
}

// 창이 서면 키보드를 올린다 — 터미널은 켜지면 바로 입력을 받는다.
/// 코어가 꺼내 놓은 복사 텍스트를 시스템 클립보드에 넣는다.
/// **꺼내는 것은 코어, 쓰는 것만 플랫폼**이다(§3 — 브리지엔 OS 호출이 없다).
/// 꺼낼 것이 없으면 아무것도 안 한다(키바를 밀기만 했을 때가 그렇다).
static void drainClipboard(struct android_app *app) {
    static char copy_buf[8192];
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int cn = maru_mobile_take_copy((unsigned char *)copy_buf, sizeof copy_buf);
    unsigned int armed = maru_mobile_armed_mods();
    pthread_mutex_unlock(&g_bridge_lock);
    LOGI("MARU_KEYBAR armed=%u copy=%u", armed, cn);
    if (cn == 0) return;
    copy_buf[cn < sizeof copy_buf ? cn : sizeof copy_buf - 1] = 0;
    JNIEnv *env = NULL;
    JavaVM *vm = app->activity->vm;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0 || !env) return;
    if (g_activity_cls) {
        jmethodID mid = (*env)->GetStaticMethodID(env, g_activity_cls, "setClipboard",
                                                  "(Ljava/lang/String;)V");
        if (mid) {
            // **UTF-16 으로 직접 만든다.** `NewStringUTF` 는 modified UTF-8 을 기대하므로
            // 이모지(4바이트 UTF-8)를 주면 **정의되지 않은 동작**이다 — CheckJNI 를 켠 빌드
            // (이 하네스가 설치하는 디버그 APK)에서는 abort 한다. 결과를 검사하는 가지를
            // 두는 대신 **변환을 우리가 해서 실패할 자리를 없앤다**(입력 쪽과 대칭이다).
            static jchar u16[8192];
            // **길이는 `cn` 이다 — `strlen` 이 아니다.** 터미널 화면에서 뽑은 바이트에 NUL 이
            // 섞이면 `strlen` 이 거기서 멈춰 뒤가 조용히 잘린다(경계 절단을 고쳐 놓고 여기서
            // 다시 자르면 의미가 없다).
            jsize ulen = utf8ToUtf16(copy_buf, cn, u16, 8192);
            jstring s = (*env)->NewString(env, u16, ulen);
            (*env)->CallStaticVoidMethod(env, g_activity_cls, mid, s);
            (*env)->DeleteLocalRef(env, s);
        } else {
            LOGI("MARU_COPY no_method");
        }
    } else {
        LOGI("MARU_COPY no_class");
    }
    (*vm)->DetachCurrentThread(vm);
}

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
    // **터치**: 누른 지점을 셀 좌표로 바꿔 조회한다. iOS `touchesBegan:` 과 같은 자리이고,
    // 좌표계 환산도 같다 — 물리 px 를 density 로 나누고 상태바 inset 을 뺀 **논리 좌표**로
    // 되돌려야 셀이 안 어긋난다(그 값은 렌더가 쓴 것과 같은 변수에서 나온다).
    if (AInputEvent_getType(ev) == AINPUT_EVENT_TYPE_MOTION) {
        int32_t raw = AMotionEvent_getAction(ev);
        int32_t action = raw & AMOTION_EVENT_ACTION_MASK;
        // **어느 손가락의 사건인가.** `ACTION_POINTER_DOWN`/`_UP` 은 이 인덱스가 가리키는
        // 손가락 하나의 것이고, `ACTION_MOVE` 는 **닿아 있는 전부**의 것이다.
        int32_t aidx = (raw & AMOTION_EVENT_ACTION_POINTER_INDEX_MASK) >> AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
        size_t pcount = AMotionEvent_getPointerCount(ev);
        int64_t ev_ms = AMotionEvent_getEventTime(ev) / 1000000;

        // **어디로 갈지는 코어가 정한다**(계약 §3.1) — host 는 좌표와 손가락 id 만 나른다.
        // 전에는 여기서 chrome·키바·본문을 차례로 물어보고 그 답을 `chrome_active`·
        // `keybar_active` 로 들고 있었는데, **같은 사실을 두 층이 들다** 보니 정리도 두 곳에서
        // 해야 했고 한쪽을 빠뜨려 "복귀 후 첫 손짓이 통째로 삼켜지는" 결함이 났다(R).
        if (action == AMOTION_EVENT_ACTION_DOWN) {
            float dlx = (AMotionEvent_getX(ev, 0) - (float)g.inset_left) / g.scale;
            float dly = (AMotionEvent_getY(ev, 0) - (float)g.inset_top) / g.scale;
            unsigned int did = (unsigned int)AMotionEvent_getPointerId(ev, 0);
            g.touch_last_y = dly;
            g.touch_total_dy = 0;
            g.ptr_id = did;
            g.has_ptr_id = 1;
            pthread_mutex_lock(&g_bridge_lock);
            maru_mobile_pointer(0, did, dlx, dly, (unsigned long long)ev_ms);
            pthread_mutex_unlock(&g_bridge_lock);
            unsigned int cell = maru_mobile_hit_cell(dlx, dly);
            LOGI("MARU_TOUCH pt=(%.0f,%.0f) logical=(%.0f,%.0f) cell=(%u,%u)",
                 AMotionEvent_getX(ev, 0), AMotionEvent_getY(ev, 0), dlx, dly, cell >> 16, cell & 0xFFFF);
            return 1;
        }

        // **마우스 휠·트랙패드.** 손가락과 달리 `down`/`up` 이 없고 델타가 곧 이벤트다 —
        // 그래서 포인터 경로가 아니라 전용 진입점으로 보낸다. 줄 환산은 코어가 한다(§3.1):
        // `AXIS_VSCROLL` 은 **노치**라 `precise=0` 이고, 트랙패드의 픽셀 델타는 이 축으로
        // 안 온다(Android 는 그것도 노치로 준다).
        if (action == AMOTION_EVENT_ACTION_SCROLL) {
            float vs = AMotionEvent_getAxisValue(ev, AMOTION_EVENT_AXIS_VSCROLL, 0);
            float hs = AMotionEvent_getAxisValue(ev, AMOTION_EVENT_AXIS_HSCROLL, 0);
            float lx = (AMotionEvent_getX(ev, 0) - (float)g.inset_left) / g.scale;
            float ly = (AMotionEvent_getY(ev, 0) - (float)g.inset_top) / g.scale;
            pthread_mutex_lock(&g_bridge_lock);
            maru_mobile_wheel(vs, hs, 0, lx, ly);
            pthread_mutex_unlock(&g_bridge_lock);
            LOGI("MARU_WHEEL vscroll=%.2f hscroll=%.2f view_offset=%u", vs, hs, maru_mobile_view_offset());
            return 1;
        }

        // **취소는 손가락을 안 가린다**(계약 §3.1) — 목적지 하나에 한 번만 보낸다.
        if (action == AMOTION_EVENT_ACTION_CANCEL) {
            pthread_mutex_lock(&g_bridge_lock);
            maru_mobile_pointer(3, 0, 0, 0, (unsigned long long)ev_ms);
            pthread_mutex_unlock(&g_bridge_lock);
            g.has_ptr_id = 0;
            return 1;
        }

        if (action == AMOTION_EVENT_ACTION_MOVE) {
            // **닿아 있는 손가락 전부를 보낸다.** 소유자만 보내면 나머지의 기준이 낡아, 그
            // 손가락이 이어받는 순간 옛 자리에서 델타가 나와 화면이 점프한다(T1 이 없앤 그 병).
            for (size_t i = 0; i < pcount; i++) {
                unsigned int id = (unsigned int)AMotionEvent_getPointerId(ev, i);
                float lx = (AMotionEvent_getX(ev, i) - (float)g.inset_left) / g.scale;
                float ly = (AMotionEvent_getY(ev, i) - (float)g.inset_top) / g.scale;
                pthread_mutex_lock(&g_bridge_lock);
                maru_mobile_pointer(1, id, lx, ly, (unsigned long long)ev_ms);
                pthread_mutex_unlock(&g_bridge_lock);
                // **관성은 코어가 든다.** 전에는 여기서 속도를 쟀고, 그러려면 "이 제스처가
                // 본문 것인가" 를 알아야 했다(`keybar_active`). 그 지식이 R2 로 사라졌는데
                // 재는 것만 남겨 두니 **키바를 비스듬히 튕겨도 본문이 흘렀다** — 목적지를
                // 아는 쪽이 잰다(§3.1). 여기 남은 것은 로그용 누적 이동량뿐이다.
                if (g.has_ptr_id && id == g.ptr_id) {
                    g.touch_total_dy += ly - g.touch_last_y;
                    g.touch_last_y = ly;
                }
            }
            return 1;
        }

        if (action == AMOTION_EVENT_ACTION_POINTER_DOWN || action == AMOTION_EVENT_ACTION_POINTER_UP ||
            action == AMOTION_EVENT_ACTION_UP) {
            unsigned int id = (unsigned int)AMotionEvent_getPointerId(ev, aidx);
            float lx = (AMotionEvent_getX(ev, aidx) - (float)g.inset_left) / g.scale;
            float ly = (AMotionEvent_getY(ev, aidx) - (float)g.inset_top) / g.scale;
            unsigned int ph = (action == AMOTION_EVENT_ACTION_POINTER_DOWN) ? 0 : 2;
                pthread_mutex_lock(&g_bridge_lock);
                maru_mobile_pointer(ph, id, lx, ly, (unsigned long long)ev_ms);
                pthread_mutex_unlock(&g_bridge_lock);

            // **본문 소유자가 떼지면 남은 손가락이 이어받는다** — 로그용 누적의 기준을 다시
            // 잡는다. 관성의 인수인계(속도 버리기)는 코어가 한다.
            if (ph == 2 && g.has_ptr_id && id == g.ptr_id) {
                g.has_ptr_id = 0;
                for (size_t i = 0; i < pcount; i++) {
                    if ((int32_t)i == aidx) continue; // 방금 떼진 손가락
                    g.ptr_id = (unsigned int)AMotionEvent_getPointerId(ev, i);
                    g.has_ptr_id = 1;
                    g.touch_last_y = (AMotionEvent_getY(ev, i) - (float)g.inset_top) / g.scale;
                    break;
                }
            }

            if (action == AMOTION_EVENT_ACTION_UP) {
                // **복사는 늘 시도한다.** 목적지를 host 가 더는 모르므로 "키바가 끝났을 때만"
                // 이라고 못 적는다 — `take_copy` 는 꺼낼 것이 없으면 0 을 돌려주므로 그냥 묻는다.
                // host 의 판단이 또 하나 줄었다.
                drainClipboard(app);
                unsigned int vo = maru_mobile_view_offset();
                unsigned int has_sel = maru_mobile_has_selection();
                // **`finger_dy` 는 손가락이 간 거리이지 화면이 흐른 양이 아니다.** 둘을 나란히
                // 두는 것이 요점이다 — 키바로 간 손짓은 `finger_dy` 가 크면서 `view_offset` 이
                // 그대로여야 한다(그 둘이 같이 움직인 것이 R2 가 만든 회귀였다). 이름을 `dy` 로
                // 두면 "본문이 그만큼 흘렀다" 로 읽힌다.
                LOGI("MARU_SCROLL finger_dy=%.1f view_offset=%u sel=%u", g.touch_total_dy, vo, has_sel);
                g.has_ptr_id = 0;
            }
            return 1;
        }
        return 0;
    }
    // **키도 여기로 온다 — 늘 InputConnection 을 지나지는 않는다.** 숫자 키보드
    // (`TYPE_CLASS_NUMBER`)는 숫자를 `commitText` 가 아니라 **키 이벤트**로 보내고, 그것은
    // 이 네이티브 큐로 들어온다. 여기서 버리면 **포트 칸에 숫자를 못 친다**(기기에서 그 상태로
    // 막혔다 — 칸은 편집 중인데 아무것도 안 써졌다). 하드웨어 키보드도 같은 길이다.
    //
    // 처리는 **Java 쪽과 같은 함수**로 보낸다(`nativeKey` 가 하는 일을 그대로 부른다) —
    // 두 경로가 각자 표를 들면 어느 하나에서만 되는 키가 생긴다.
    if (AInputEvent_getType(ev) == AINPUT_EVENT_TYPE_KEY) {
        if (AKeyEvent_getAction(ev) != AKEY_EVENT_ACTION_DOWN) return 0;
        int32_t code = AKeyEvent_getKeyCode(ev);
        // **뒤로가기는 안 가로챈다** — 화면 스택을 Java 가 든다(`onBackPressed`).
        if (code == AKEYCODE_BACK) return 0;
        int32_t meta = AKeyEvent_getMetaState(ev);
        // 유니코드는 이 API 로 못 얻는다(`getUnicodeChar` 는 Java `KeyEvent` 것이다).
        // **숫자·기호는 키 코드에서 바로 나온다** — 그 둘이 이 경로로 오는 전부다.
        int unicode = 0;
        if (code >= AKEYCODE_0 && code <= AKEYCODE_9) unicode = '0' + (code - AKEYCODE_0);
        else if (code == AKEYCODE_PERIOD) unicode = '.';
        else if (code == AKEYCODE_COMMA) unicode = ',';
        else if (code == AKEYCODE_MINUS) unicode = '-';
        else if (code == AKEYCODE_PLUS) unicode = '+';
        else if (code == AKEYCODE_SPACE) unicode = ' ';
        dispatchKey(code, meta, unicode);
        return 1;
    }
    return 0;
}

/// **사용자가 친 비밀번호를 펌프로 넘긴다.** 화면(브리지)이 받아 두고 여기서 가져간다 —
/// 브리지엔 소켓이 없고 펌프엔 화면이 없다. 넘긴 뒤 **자기 사본을 지운다**(계약 §3.4).
/// 컨트롤 축을 프레임마다 굴린다(S10d-3).
///
/// **여는 시점은 코어가 정한다** — 화면이 목록 자리에 왔을 때만 1 이 된다(계약 §4a: 채널을 여는
/// 것은 그 서버에서 명령을 하나 실행하는 일이라 감사 로그에 남는다).
static void driveControlChannel(void) {
    if (!maru_ssh_pump_is_running()) return;

    // **셸이 뜬 뒤에만 연다.** 예전 가드는 `is_running` 뿐이었는데 그것은 `pthread_create` 직후
    // 참이라 READY 와 무관하다 — 목록 화면이 nav 스택의 뿌리라 접속 중에 거기 있으면 요청이 곧바로
    // 서고, 그때 열기가 `not_running`/`NotReady` 로 지고 **요청은 take-once 라 사라졌다**. 그러면
    // 셸이 떠도 목록은 영영 "받는 중" 이었다(기기 실측). 상태로 가르면 준비 전에는 아예 안 가져가
    // 요청이 남고, READY 가 된 프레임에 한 번 연다 — 자동 재시도가 아니라 **제 시점에 한 번**이라
    // 계약(§4a: 재시도는 사용자가 그 화면에 다시 올 때다)과도 맞다.
    // **열 수 있을 때만 집는다.** 이 요청은 take-once 가 아니다(계약 §4a) — 채널이 아직 안
    // 닫혔는데 가져가면 그 뜻이 사라져 축이 영영 안 선다. 닫힘이 확인된 다음 tick 에 연다.
    /* **정책은 코어가 정한다.** 닫기/열기의 «순서»·「열 수 있는가」 가드·`NOT_READY` 분류·
       두 마감이 전부 정책이라 Zig 로 올렸다(`maru_mobile_control_tick`). 예전에는 그 넷이 이
       함수 안에 있어 ⑴ 두 플랫폼이 갈릴 수 있었고 ⑵ **헤드리스로 잴 수가 없었다** — 실제로
       iOS 쪽 순서가 뒤집혀 「열고 그 자리에서 닫기」를 무한히 되풀이했다(실기 2026-09-04).
       여기 남는 것은 **네이티브뿐**이다: 펌프 호출과 로그. */
    unsigned long long control_now_ms = (unsigned long long)nowMs();
    int control_action = maru_mobile_control_tick(
        maru_ssh_pump_state() == MARU_SSH_STATE_READY ? 1 : 0,
        maru_ssh_pump_control_state(), control_now_ms);
    if (control_action == MARU_MOBILE_CONTROL_ACTION_CLOSE) {
        /* **닫기 결과를 읽는다**(iOS 와 같은 자리) — 실패가 조용하면 원격 명령이 고아로 남아
           그 뒤 모든 열기가 막힌다(실기 2026-09-04). */
        int close_rc = maru_ssh_pump_close_control();
        if (close_rc != 0)
            LOGI("MARU_CONTROL close failed rc=%d: %s", close_rc, maru_ssh_pump_control_error());
    } else if (control_action == MARU_MOBILE_CONTROL_ACTION_OPEN) {
        /* **명령은 코어가 만든다** — 그 서버 설정의 `maru-path` 를 쓰고, 셸이 쪼개지 못하게
           인용까지 해서 준다(계약 §4a). host 가 문자열을 조립하면 두 플랫폼이 갈린다. */
        char cmd[512];
        unsigned long cmd_len = maru_mobile_control_command((unsigned char *)cmd, sizeof cmd);
        int open_rc = cmd_len == 0
                          ? -1
                          : maru_ssh_pump_open_control(cmd, (unsigned int)cmd_len);
        /* **왜 졌는지를 갈라 찍는다**(iOS 와 같은 자리) — 마감을 넘긴 것과 딱딱한 실패는
           사용자가 볼 자리가 다르다. */
        int open_verdict = maru_mobile_control_note_open(open_rc, control_now_ms);
        if (open_verdict == 1)
            LOGI("MARU_CONTROL open gave up (not ready for 5s): %s", maru_ssh_pump_control_error());
        else if (open_verdict != 0)
            LOGI("MARU_CONTROL open failed rc=%d: %s", open_rc, maru_ssh_pump_control_error());
    }

    /* **명령이 그냥 끝났으면 시한을 기다리지 않는다.** 답할 것이 이미 죽었고, 종료 코드는
       사용자가 고칠 자리를 가른다(계약 §4a: 127 이면 그 기계에 `maru` 가 없다).
       **세션이 살아 있을 때만 그렇게 읽는다** — 연결이 죽으면 채널도 함께 죽는데, 그것은 명령이
       실패한 것이 아니라 명령이 서 있던 바닥이 사라진 것이다. */
    unsigned int control_exit = 0;
    if (maru_mobile_control_awaiting_reply() && maru_ssh_pump_state() == MARU_SSH_STATE_READY &&
        maru_ssh_pump_control_exit_status(&control_exit) == 0) {
        maru_mobile_control_note_exit_at(control_exit);
    }

    unsigned char req[512];
    unsigned long n = maru_mobile_take_control_request(req, sizeof req);
    if (n > 0) maru_ssh_pump_write_control(req, n);
}

static void drainPassword(void) {
    unsigned char pw[256];
    pthread_mutex_lock(&g_bridge_lock);
    unsigned long n = maru_mobile_take_password(pw, sizeof pw);
    pthread_mutex_unlock(&g_bridge_lock);
    if (n == 0) return;
    maru_ssh_pump_password((const char *)pw, (unsigned int)n);
    memset(pw, 0, sizeof pw);
    LOGI("MARU_SSH password_supplied bytes=%lu", n);
}

/// **지문 승인·거절을 펌프로 넘긴다**(비밀번호와 같은 자리·같은 규율).
static void drainHostKeyDecision(void) {
    pthread_mutex_lock(&g_bridge_lock);
    unsigned int d = maru_mobile_take_host_key_decision();
    pthread_mutex_unlock(&g_bridge_lock);
    if (d == 0) return;
    maru_ssh_pump_accept_host_key(d == 1);
    LOGI("MARU_SSH host_key_%s", d == 1 ? "accepted" : "rejected");
}

/// **이 기기의 공개키 한 줄을 브리지에 알린다**(화면이 그것을 보여 주고 복사한다 — S9c-4).
///
/// **접속 전에 있어야 한다.** 사용자는 그 줄을 서버 `authorized_keys` 에 붙여야 처음 붙을 수
/// 있는데, 예전에는 키를 **접속할 때**(서비스가 뜰 때) 처음 열었다 — 그러면 붙기 전에는 볼 수
/// 없어서 순서가 거꾸로다.
///
/// 파일(`id_ed25519.pub`)이 있으면 그것을 읽는다 — **개인키를 안 연다**. 없으면 그때만 Keystore
/// 에서 풀어 한 줄을 만들고 파일로 남긴다(다음부터는 안 연다). 공개키라 파일에 있어도 된다.
static void publishPublicKey(struct android_app *app) {
    if (!app || !app->activity || !app->activity->internalDataPath) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/id_ed25519.pub", app->activity->internalDataPath);

    unsigned char line[256];
    FILE *f = fopen(path, "rb");
    if (f) {
        size_t n = fread(line, 1, sizeof line - 1, f);
        fclose(f);
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) n--; // 개행은 값이 아니다
        if (n > 0) {
            pthread_mutex_lock(&g_bridge_lock);
            maru_mobile_set_public_key(line, (unsigned long)n);
            pthread_mutex_unlock(&g_bridge_lock);
            LOGI("MARU_SSH public_key_from_file bytes=%zu", n);
            return;
        }
    }

    // 파일이 없다 — Keystore 를 열어 한 줄을 만들고 남긴다(그 뒤로는 위 경로만 탄다).
    JNIEnv *env = NULL;
    JavaVM *vm = app->activity->vm;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != 0) return;
    jclass cls = (*env)->FindClass(env, "dev/maru/MaruKeyStore");
    jmethodID m = cls ? (*env)->GetStaticMethodID(env, cls, "loadOrCreate",
                                                  "(Landroid/content/Context;)[B") : NULL;
    jbyteArray arr = m ? (jbyteArray)(*env)->CallStaticObjectMethod(env, cls, m, app->activity->clazz) : NULL;
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (arr && (*env)->GetArrayLength(env, arr) == MARU_SSH_SECRET_KEY_BYTES) {
        unsigned char secret[MARU_SSH_SECRET_KEY_BYTES];
        (*env)->GetByteArrayRegion(env, arr, 0, MARU_SSH_SECRET_KEY_BYTES, (jbyte *)secret);
        int rc = maru_mobile_ssh_public_key_line(secret, line, sizeof line);
        memset(secret, 0, sizeof secret); // 개인키 사본은 바로 지운다
        if (rc == MARU_SSH_OK) {
            size_t n = strlen((const char *)line);
            pthread_mutex_lock(&g_bridge_lock);
            maru_mobile_set_public_key(line, (unsigned long)n);
            pthread_mutex_unlock(&g_bridge_lock);
            FILE *w = fopen(path, "wb");
            if (w) {
                fprintf(w, "%s\n", (const char *)line);
                fclose(w);
            }
            LOGI("MARU_SSH public_key_from_keystore bytes=%zu", n);
        } else {
            LOGI("MARU_SSH public_key_failed=%s", maru_mobile_ssh_last_load_error());
        }
    } else {
        LOGI("MARU_SSH public_key_absent");
    }
    (*vm)->DetachCurrentThread(vm);
}

/// config 파일을 읽어 브리지에 넘긴다. **자리는 앱 전용 내부 저장소**(`filesDir/config` —
/// docs/mobile-config.md §2). 없으면 아무것도 안 한다 — 기본값으로 도는 것이 정상 상태다.
/// 브리지가 세운 저장 요청을 파일에 쓴다. **가져가는 것은 한 번뿐**이라 매 프레임 불러도
/// 실제 쓰기는 값이 바뀐 그 프레임에만 난다(클립보드와 같은 규율).
///
/// **임시 파일에 쓰고 rename 한다.** 그대로 덮어쓰다 죽으면 config 가 반만 남는데, 그러면
/// 다음 실행에서 설정이 통째로 날아간 것처럼 보인다.
static void drainConfigWrite(struct android_app *app) {
    static unsigned char buf[MARU_CONFIG_MAX_BYTES];
    pthread_mutex_lock(&g_bridge_lock);
    unsigned long n = maru_mobile_take_config_write(buf, sizeof buf);
    pthread_mutex_unlock(&g_bridge_lock);
    if (n == 0) return;
    const char *dir = app->activity->internalDataPath;
    if (!dir) { LOGI("MARU_CONFIG write_no_data_path"); return; }
    char tmp[512], path[512];
    snprintf(tmp, sizeof tmp, "%s/config.tmp", dir);
    snprintf(path, sizeof path, "%s/config", dir);
    FILE *f = fopen(tmp, "wb");
    if (!f) { LOGI("MARU_CONFIG write_open_failed path=%s", tmp); return; }
    size_t w = fwrite(buf, 1, (size_t)n, f);
    int closed = fclose(f);
    if (w != (size_t)n || closed != 0) { LOGI("MARU_CONFIG write_failed bytes=%zu/%lu", w, n); return; }
    if (rename(tmp, path) != 0) { LOGI("MARU_CONFIG rename_failed path=%s", path); return; }
    LOGI("MARU_CONFIG wrote bytes=%lu path=%s", n, path);
}

static void loadConfigFile(struct android_app *app) {
    const char *dir = app->activity->internalDataPath;
    if (!dir) { LOGI("MARU_CONFIG no_data_path"); return; }
    char path[512];
    snprintf(path, sizeof path, "%s/config", dir);
    FILE *f = fopen(path, "rb");
    if (!f) { LOGI("MARU_CONFIG absent path=%s", path); return; }
    // **크기를 먼저 재고 필요한 만큼만 잡는다.** 상한만 한 정적 버퍼를 두면 설정 파일이 몇 줄
    // 뿐인 기기에서도 그 크기를 이고 간다 — 폰에서는 그 값이 크다. 넘치면 자른 앞부분을 쓰지
    // 않고 기본값으로 간다(반만 적용된 설정은 무엇이 먹었는지 알 수 없다).
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    if (size < 0) { fclose(f); LOGI("MARU_CONFIG size_failed path=%s", path); return; }
    if ((unsigned long)size > MARU_CONFIG_MAX_BYTES) {
        fclose(f);
        LOGI("MARU_CONFIG too_large bytes=%ld limit=%u path=%s", size, MARU_CONFIG_MAX_BYTES, path);
        return;
    }
    rewind(f);
    char *buf = (char *)malloc((size_t)size);
    if (!buf) { fclose(f); LOGI("MARU_CONFIG alloc_failed bytes=%ld", size); return; }
    size_t n = fread(buf, 1, (size_t)size, f);
    fclose(f);
    pthread_mutex_lock(&g_bridge_lock);
    maru_mobile_load_config((const unsigned char *)buf, n);
    pthread_mutex_unlock(&g_bridge_lock);
    free(buf);
    LOGI("MARU_CONFIG loaded bytes=%zu path=%s", n, path);
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
    if (g.color_view) vkDestroyImageView(g.dev, g.color_view, NULL);
    if (g.color_image) vkDestroyImage(g.dev, g.color_image, NULL);
    if (g.icon_mem) vkFreeMemory(g.dev, g.icon_mem, NULL);
    if (g.color_mem) vkFreeMemory(g.dev, g.color_mem, NULL);
    if (g.rp) vkDestroyRenderPass(g.dev, g.rp, NULL);
    if (g.acquire_sem) vkDestroySemaphore(g.dev, g.acquire_sem, NULL);
    if (g.submit_sem) vkDestroySemaphore(g.dev, g.submit_sem, NULL);
    if (g.fence) vkDestroyFence(g.dev, g.fence, NULL);
    if (g.pool) vkDestroyCommandPool(g.dev, g.pool, NULL);
    vkDestroyDevice(g.dev, NULL);
    if (g.surface) vkDestroySurfaceKHR(g.inst, g.surface, NULL);
    if (g.inst) vkDestroyInstance(g.inst, NULL);
    // **화면 설정만 살린다** — 밀도·inset·아틀라스 격자는 창이 부서져도 같은 값이다.
    // 페이싱 계측(`pace_ms`·`n_pace`·`last_ms`)과 주기 기준(`last_draw_ns`)은 **일부러
    // 지운다**: 창이 부서졌다 서는 사이의 공백이 표본에 섞이면 중앙값이 거짓말을 하고,
    // 주기 기준이 남으면 재개 첫 프레임이 옛 시각과 비교돼 한 프레임을 건너뛴다.
    float scale = g.scale;
    int it = g.inset_top, ib = g.inset_bottom, il = g.inset_left, ir = g.inset_right;
    uint32_t ac = g.atlas_cols, ar = g.atlas_rows;
    memset(&g, 0, sizeof g);
    g.scale = scale; g.inset_top = it; g.inset_bottom = ib; g.inset_left = il; g.inset_right = ir;
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
    /// 스타일 비트(0=보통·1=굵게·2=기울임·3=굵은기울임)로 바로 찾는다 — SGR 1/3 은 **다른
    /// 글리프**라 폰트 파일이 따로 있어야 한다(가짜 굵게는 자간이 어긋난다).
    jobject faces[4];
    jmethodID draw, measure, set_typeface;
    int ok;
    jobject cbmp, ccanvas;   // 이모지(컬러) 전용 ARGB 비트맵
} GlyphBaker;

/// asset 에서 폰트 하나를 읽는다. 없으면 NULL — 부르는 쪽이 보통 판으로 되돌린다.
static jobject loadFace(JNIEnv *env, jclass tfCls, jmethodID mFromAsset, jobject assets, const char *name) {
    jobject f = (*env)->CallStaticObjectMethod(env, tfCls, mFromAsset, assets,
                                               (*env)->NewStringUTF(env, name));
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NULL; }
    return f;
}

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
    // **이모지는 ARGB 로 굽는다.** ALPHA_8 에 그리면 색이 사라져 실루엣이 된다(계약 §이모지).
    jobject cfg8888 = (*env)->GetStaticObjectField(env, cfgCls,
        (*env)->GetStaticFieldID(env, cfgCls, "ARGB_8888", "Landroid/graphics/Bitmap$Config;"));
    b->cbmp = (*env)->CallStaticObjectMethod(env, bmCls,
        (*env)->GetStaticMethodID(env, bmCls, "createBitmap",
            "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;"),
        (jint)CW, (jint)CH, cfg8888);
    if (b->cbmp)
        b->ccanvas = (*env)->NewObject(env, cvCls,
            (*env)->GetMethodID(env, cvCls, "<init>", "(Landroid/graphics/Bitmap;)V"), b->cbmp);
    jclass pCls = (*env)->FindClass(env, "android/graphics/Paint");
    b->paint = (*env)->NewObject(env, pCls,
        (*env)->GetMethodID(env, pCls, "<init>", "(I)V"), (jint)1);
    (*env)->CallVoidMethod(env, b->paint,
        (*env)->GetMethodID(env, pCls, "setTextSize", "(F)V"), (jfloat)maru_mobile_atlas_text_px());
    (*env)->CallVoidMethod(env, b->paint,
        (*env)->GetMethodID(env, pCls, "setColor", "(I)V"), (jint)0xFFFFFFFF);

    // asset 에서 읽는다 — `/data/local/tmp` 는 개발 스크립트 자리라 실제 앱에는 없다.
    // **네 가지를 다 연다**(보통·굵게·기울임·굵은기울임). 배열 인덱스가 곧 스타일 비트다.
    jclass tfCls = (*env)->FindClass(env, "android/graphics/Typeface");
    jclass actCls = (*env)->GetObjectClass(env, app->activity->clazz);
    jobject assets = (*env)->CallObjectMethod(env, app->activity->clazz,
        (*env)->GetMethodID(env, actCls, "getAssets", "()Landroid/content/res/AssetManager;"));
    jmethodID mFromAsset = (*env)->GetStaticMethodID(env, tfCls, "createFromAsset",
        "(Landroid/content/res/AssetManager;Ljava/lang/String;)Landroid/graphics/Typeface;");
    static const char *kFace[4] = {
        "Jetendard-Regular.ttf", "Jetendard-Bold.ttf",
        "Jetendard-Italic.ttf", "Jetendard-BoldItalic.ttf",
    };
    for (int s = 0; s < 4; s++) {
        b->faces[s] = loadFace(env, tfCls, mFromAsset, assets, kFace[s]);
        // 그 판이 없으면 보통 판으로 되돌린다 — 조용히 시스템 글꼴이 되지 않게.
        if (!b->faces[s]) { LOGI("bundled_font_missing style=%d", s); b->faces[s] = b->faces[0]; }
    }

    b->set_typeface = (*env)->GetMethodID(env, pCls, "setTypeface",
        "(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;");
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
/// 코드포인트 **열**을 UTF-16 으로 편다. 반환값은 채운 unit 수.
///
/// 열째로 그려야 결합이 일어난다 — `❤`+VS16 을 따로 그리면 하트와 보이지 않는 선택자가 각각
/// 그려질 뿐 컬러 하트가 안 된다. BMP 밖 코드포인트는 서러게이트 쌍으로 편다.
static jsize clusterToUtf16(const unsigned int *cps, unsigned int n, jchar *units, jsize cap) {
    jsize k = 0;
    for (unsigned int i = 0; i < n && k + 2 <= cap; i++) {
        unsigned int cp = cps[i];
        if (cp > 0x10FFFF) continue;
        if (cp > 0xFFFF) {
            unsigned int v = cp - 0x10000;
            units[k++] = (jchar)(0xD800 + (v >> 10));
            units[k++] = (jchar)(0xDC00 + (v & 0x3FF));
        } else {
            units[k++] = (jchar)cp;
        }
    }
    return k;
}

static int bakeGlyph(GlyphBaker *b, const unsigned int *cps, unsigned int ncp, uint32_t style,
                     uint8_t *out, uint32_t CW, uint32_t CH, uint32_t *advance) {
    if (!b->ok) return 0;
    JNIEnv *env = b->env;
    // 스타일에 맞는 폰트로 갈아 끼운다. advance 도 이 폰트에서 나와야 자간이 안 어긋난다.
    (*env)->CallObjectMethod(env, b->paint, b->set_typeface, b->faces[style & 3]);
    // **셀을 비우고 그린다.** `Canvas.drawColor(0)` 은 SRC_OVER 라 투명색을 덮어도 아무것도
    // 안 지운다 — 그렇게 짰다가 앞 글자 잉크가 남아 글자가 겹쳐 나왔다(화면으로 잡았다).
    // `Bitmap.eraseColor` 가 실제로 지우는 쪽이다.
    jclass bmCls2 = (*env)->GetObjectClass(env, b->bmp);
    (*env)->CallVoidMethod(env, b->bmp,
        (*env)->GetMethodID(env, bmCls2, "eraseColor", "(I)V"), (jint)0);

    // **열을 통째로 그린다.** BMP 밖 글자(수학 기호·CJK 확장)는 서러게이트 쌍이 되고, 클러스터는
    // 문자열 하나가 되어 Android 가 결합을 처리한다.
    jchar units[MARU_MAX_CLUSTER * 2];
    jsize unit_n = clusterToUtf16(cps, ncp, units, (jsize)(sizeof units / sizeof units[0]));
    if (unit_n == 0) return 0;
    jstring s = (*env)->NewString(env, units, unit_n);
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

/// 이모지 한 글자를 **컬러 아틀라스**에 굽는다(iOS `bakeColorGlyph:` 와 짝).
///
/// ① 코드포인트 **열**을 문자열 하나로 그려야 결합이 일어난다 — `❤`+VS16 을 따로 그리면 컬러
/// 하트가 안 된다. BMP 밖은 서러게이트 쌍이다. ② 이모지 폰트는 Android 가 알아서 폴백한다
/// (`Canvas.drawText`). ③ ARGB 비트맵에 그려야 색이 남는다.
static int bakeColorGlyph(GlyphBaker *b, const unsigned int *cps, unsigned int ncp,
                          unsigned int style, uint8_t *out, uint32_t CW, uint32_t CH) {
    JNIEnv *env = b->env;
    if (!b->cbmp || !b->ccanvas) return 0;
    (*env)->CallObjectMethod(env, b->paint, b->set_typeface, b->faces[style & 3]);
    jclass bmCls = (*env)->GetObjectClass(env, b->cbmp);
    (*env)->CallVoidMethod(env, b->cbmp,
        (*env)->GetMethodID(env, bmCls, "eraseColor", "(I)V"), (jint)0);

    jchar units[MARU_MAX_CLUSTER * 2];
    jsize unit_n = clusterToUtf16(cps, ncp, units, (jsize)(sizeof units / sizeof units[0]));
    if (unit_n == 0) return 0;
    jstring s = (*env)->NewString(env, units, unit_n);
    (*env)->CallVoidMethod(env, b->ccanvas, b->draw, s, (jfloat)1.0f, (jfloat)(CH - 8), b->paint);

    void *pixels = NULL;
    AndroidBitmapInfo info;
    int ok = 0;
    if (AndroidBitmap_getInfo(env, b->cbmp, &info) == 0 &&
        AndroidBitmap_lockPixels(env, b->cbmp, &pixels) == 0) {
        for (uint32_t y = 0; y < CH; y++)
            memcpy(out + (size_t)y * CW * 4, (uint8_t *)pixels + (size_t)y * info.stride, (size_t)CW * 4);
        AndroidBitmap_unlockPixels(env, b->cbmp);
        ok = 1;
    }
    (*env)->DeleteLocalRef(env, s);
    return ok;
}

/// 아틀라스 한 칸을 GPU 이미지에 올린다. 글자(R8)와 이모지(RGBA) 가 **같은 경로**를 쓴다 —
/// 두 벌로 두면 배리어·정리 중 한쪽만 고쳐져 조용히 어긋난다.
static int uploadSlot(VkImage target, uint32_t col, uint32_t row,
                      const void *src, uint32_t bytes, uint32_t cw, uint32_t ch) {
    if (!target || !g.dev) return 0;
    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                              .size = bytes, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
    VkBuffer stage;
    if (vkCreateBuffer(g.dev, &bci, NULL, &stage) != VK_SUCCESS) return 0;
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
    if (vkAllocateMemory(g.dev, &mai, NULL, &mem) != VK_SUCCESS) { vkDestroyBuffer(g.dev, stage, NULL); return 0; }
    vkBindBufferMemory(g.dev, stage, mem, 0);
    void *map = NULL;
    vkMapMemory(g.dev, mem, 0, VK_WHOLE_SIZE, 0, &map);
    memcpy(map, src, bytes);
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
                               .image = target,
                               .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
                               .srcAccessMask = VK_ACCESS_SHADER_READ_BIT,
                               .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 1, &tb);
    VkBufferImageCopy region = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                .imageOffset = {(int32_t)(col * cw), (int32_t)(row * ch), 0},
                                .imageExtent = {cw, ch, 1}};
    vkCmdCopyBufferToImage(cb, stage, target, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
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
    return 1;
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
        // **열을 통째로 읽는다.** base 만 읽으면 `❤` 와 `❤️` 가 같아 보여 VS16 결합이 단색이 된다.
        unsigned int cps[MARU_MAX_CLUSTER];
        unsigned int ncp = maru_mobile_missing_len((unsigned int)i);
        if (ncp > MARU_MAX_CLUSTER) ncp = MARU_MAX_CLUSTER;
        for (unsigned int j = 0; j < ncp; j++) cps[j] = maru_mobile_missing_cp_at((unsigned int)i, j);
        unsigned int style = maru_mobile_missing_style((unsigned int)i);
        if (ncp == 0 || cps[0] == 0 || cps[0] > 0x10FFFF) continue;
        // **컬러 글리프는 다른 아틀라스로 간다**(커버리지에 구우면 실루엣).
        if (maru_mobile_missing_is_color((unsigned int)i)) {
            unsigned int cslot = maru_mobile_next_color_slot(g.atlas_cols);
            if (cslot == 0xFFFFFFFF) continue;   // 버릴 자리도 없다(전부 이번 프레임 것)
            uint32_t ccol = cslot >> 16, crow = cslot & 0xFFFF;
            uint8_t *rgba = calloc((size_t)CW * CH * 4, 1);
            if (!rgba) continue;
            if (bakeColorGlyph(&baker, cps, ncp, style, rgba, CW, CH) &&
                uploadSlot(g.color_image, ccol, crow, rgba, (uint32_t)(CW * CH * 4), CW, CH)) {
                // **원본에도 넣는다** — 글자 아틀라스와 같은 이유다(아래 `g_glyph_px` 주석).
                if (g_color_px && (crow + 1) * CH <= g_gh) {
                    for (uint32_t y = 0; y < CH; y++)
                        memcpy(g_color_px + ((size_t)(crow * CH + y) * g_gw + ccol * CW) * 4,
                               rgba + (size_t)y * CW * 4, (size_t)CW * 4);
                }
                maru_mobile_color_atlas_add(cps, ncp, style, ccol, crow, CW); // 이모지는 2셀 = 슬롯 전체
                added++;
            }
            free(rgba);
            continue;
        }
        unsigned int slot = maru_mobile_next_slot(g.atlas_cols);
        // 꽉 차면 브리지가 **가장 안 쓰인 자리를 재사용하라고** 내준다(축출). 여기서 빈 자리와
        // 재사용 자리를 가릴 필요가 없다 — 아래 `memset` + 슬롯 전체 `uploadSlot` 이 옛 글리프를
        // 완전히 덮으므로 잔상이 안 남는다(원본 버퍼 `g_glyph_px` 도 같은 사각형을 덮는다).
        // sentinel 은 **이번 프레임에 그려진 것만 남아 버릴 것이 없다**는 뜻이라 이번 프레임은 포기한다.
        if (slot == 0xFFFFFFFF) break;
        uint32_t col = slot >> 16, row = slot & 0xFFFF;
        memset(cell, 0, sizeof cell);
        uint32_t advance = CW / 2;
        // **합성이 먼저다**(renderer 계약). 박스·블록·브라유는 폰트로 구우면 셀에 안 맞아
        // 끊긴다 — 합성은 셀을 가장자리까지 채운다. 0 이면 합성 대상이 아니라 폰트로 간다.
        // 합성 대상(박스·블록·브라유)은 전부 단일 코드포인트라 base 만 넘긴다.
        if (maru_mobile_synthesize(cps[0], cell, CW) == 0) {
            if (!bakeGlyph(&baker, cps, ncp, style, cell, CW, CH, &advance)) continue;
        }

        // staging 버퍼 → 이미지의 그 사각형만 복사(글자·이모지 공용 경로).
        if (!uploadSlot(g.glyph_image, col, row, cell, (uint32_t)sizeof cell, CW, CH)) continue;

        // **원본 버퍼에도 넣는다.** 창이 죽었다 살아나면 이 버퍼로 텍스처를 다시 올리는데,
        // GPU 이미지에만 넣으면 그때 성장분이 통째로 사라진다. 등록부는 그대로라 코어는
        // "있다" 고 믿고 다시 굽지도 않아 영영 빈칸이 된다(실측 경로).
        if (g_glyph_px && (row + 1) * CH <= g_gh) {
            for (uint32_t y = 0; y < CH; y++)
                memcpy(g_glyph_px + (row * CH + y) * g_gw + col * CW, cell + y * CW, CW);
        }
        maru_mobile_atlas_add(cps, ncp, style, col, row, advance);
        added++;
    }
    bakerClose(app, &baker);
    maru_mobile_missing_clear();
    if (added) LOGI("MARU_ATLAS grew=%u", added);
}

static void onAppCmd(struct android_app *app, int32_t cmd) {
    // **포커스를 코어에 알린다**(DEC 1004 — vim 의 FocusGained/Lost). 모바일은 배경↔복귀가
    // 데스크톱보다 훨씬 잦다. 코어를 만지므로 입력 스레드와 같은 자물쇠를 쓴다.
    if (cmd == APP_CMD_GAINED_FOCUS || cmd == APP_CMD_LOST_FOCUS) {
        pthread_mutex_lock(&g_bridge_lock);
        maru_mobile_report_focus(cmd == APP_CMD_GAINED_FOCUS);
        // 누르고 있던 손가락을 정리한다 — 이 OS 는 취소를 보내 주지만(실측) 그것에
        // 기대지 않는다. 두 플랫폼이 같은 자리에서 같은 정리를 한다.
        // **취소 하나면 끝난다.** 목적지도 관성도 코어가 드므로, 전에 여기서 따로 거두던
        // 미끄러짐 상태가 host 에 없다.
        if (cmd == APP_CMD_LOST_FOCUS) maru_mobile_pointer(3, 0, 0, 0, 0);
        pthread_mutex_unlock(&g_bridge_lock);
        return;
    }
    if (cmd == APP_CMD_TERM_WINDOW) {
        teardownVulkan();
        return;
    }
    if (cmd == APP_CMD_INIT_WINDOW && app->window && g.ready) return;  // 이미 서 있으면 그대로
    if (cmd == APP_CMD_INIT_WINDOW && app->window) {
        loadConfigFile(app); // 첫 프레임부터 그 색으로 그린다
        publishPublicKey(app); // 접속 **전에** 보여 줘야 서버에 붙일 수 있다
        int32_t dpi = AConfiguration_getDensity(app->config);
        g.scale = (dpi > 0 && dpi != ACONFIGURATION_DENSITY_ANY &&
                   dpi != ACONFIGURATION_DENSITY_NONE) ? (float)dpi / 160.0f : 2.0f;
        queryInsets(app, &g.inset_top, &g.inset_bottom, &g.inset_left, &g.inset_right);
        LOGI("density=%d scale=%.3f inset top=%d bottom=%d left=%d right=%d", dpi, g.scale,
             g.inset_top, g.inset_bottom, g.inset_left, g.inset_right);
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

// vsync 마다 불린다. Vulkan present mode 에는 하위 주기 선택지가 없으므로
// (FIFO/MAILBOX/IMMEDIATE 는 전부 "언제"지 "얼마나 자주"가 아니다) **주기는 앱이 정한다** —
// iOS 의 `preferredFrameRateRange` 에 대응하는 자리다.
//
// **경과 시간으로 정한다. vsync 를 세지 않는다.** 전에는 "한 번 걸러" 그렸는데, 그건 30Hz 가
// 아니라 **패널 주사율의 절반**이다 — 90Hz 폰에서 45, 120Hz 에서 60 이 나온다. comfort 값을
// 배터리·발열 때문에 골라 놓고 고주사율 기기에서 두 배로 그리고 있었다(에뮬레이터가 60Hz 라
// 안 드러났다). `MARU_PACE` 의 PASS 창(`MARU_FRAME_PACE_MIN_MS`~`MAX_MS`)도 120Hz 에서는
// 16.7ms 로 떨어져 실패한다 — 숫자는 헤더가 소유하므로 여기 다시 적지 않는다.
static void frameCallback(int64_t frame_time_ns, void *data) {
    // **30Hz(comfort).** 터미널은 매 vsync 마다 새로 그릴 것이 없고, 모바일은 배터리·발열이
    // 사용자에게 보인다. iOS 도 같은 값이다(`preferredFrameRateRange`). 데스크톱은 60 이라
    // **다르다** — 데스크톱은 hover/scroll 지연을 우선하고 전력 여유가 있다.
    const int64_t target_ns = MARU_FRAME_TARGET_NS; // 값은 ABI 헤더가 소유한다
    // 패널 주기를 재서 문턱을 반 주기 당긴다. 정확히 `target_ns` 를 요구하면 vsync 지터로
    // 한 주기를 통째로 놓쳐 **실효 주기가 절반으로 떨어졌다 돌아오는** 널뛰기가 된다.
    const int64_t vsync_dt = (g.last_vsync_ns != 0) ? frame_time_ns - g.last_vsync_ns : 0;
    g.last_vsync_ns = frame_time_ns;
    // **동률이면 한 번 더 기다린다**(`>` 지 `>=` 가 아니다). 목표가 패널 주기의 딱 1.5배인
    // 45Hz 에서 `>=` 면 매 vsync 를 그려 **45Hz 가 된다** — 페이싱이 통째로 사라지는, 이
    // 커밋이 고치려는 바로 그 상태다. `>` 면 22.5Hz 로 목표엔 못 미치지만 comfort 방향이다
    // (45Hz 패널은 45 나 22.5 뿐이라 30 이 애초에 없다).
    if (g.last_draw_ns == 0 || frame_time_ns - g.last_draw_ns > target_ns - vsync_dt / 2) {
        g.last_draw_ns = frame_time_ns;
        drawFrame();
    }
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
    queryInsets(app, &g.inset_top, &g.inset_bottom, &g.inset_left, &g.inset_right);
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
