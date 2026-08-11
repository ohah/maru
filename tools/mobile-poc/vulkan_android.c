// Android: Zig 코어 실행 + Vulkan 오프스크린 렌더.
//
// **셰이더 없이 그린다.** 렌더 패스 안의 `vkCmdClearAttachments` 는 rect 를 받으므로
// SPIR-V 툴체인 없이도 셀 격자를 낼 수 있다. 여기서 보려는 것은 "Android GPU 가
// 실제로 픽셀을 쓰는가"이지 파이프라인 완성도가 아니다.
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern unsigned int maru_poc_smoke(void);

#define W 480
#define H 240
#define CHECK(x, msg) do { VkResult _r = (x); if (_r != VK_SUCCESS) { printf("VULKAN %s=%d\n", msg, _r); return 2; } } while (0)

int main(void) {
    unsigned int rc = maru_poc_smoke();
    printf("ZIG_CORE rc=%u\n", rc);
    if (rc != 0) return 1;

    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                             .pApplicationName = "maru-poc", .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance inst;
    CHECK(vkCreateInstance(&ici, NULL, &inst), "create_instance");

    uint32_t n = 0;
    vkEnumeratePhysicalDevices(inst, &n, NULL);
    if (!n) { printf("VULKAN no_physical_device\n"); return 2; }
    VkPhysicalDevice *pds = calloc(n, sizeof(*pds));
    vkEnumeratePhysicalDevices(inst, &n, pds);
    VkPhysicalDevice pd = pds[0];
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    printf("VULKAN device=%s\n", props.deviceName);

    uint32_t qn = 0, qfam = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, NULL);
    VkQueueFamilyProperties *qs = calloc(qn, sizeof(*qs));
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, qs);
    for (uint32_t i = 0; i < qn; i++)
        if (qs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { qfam = i; break; }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                   .queueFamilyIndex = qfam, .queueCount = 1, .pQueuePriorities = &prio};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
    VkDevice dev;
    CHECK(vkCreateDevice(pd, &dci, NULL, &dev), "create_device");
    VkQueue queue;
    vkGetDeviceQueue(dev, qfam, 0, &queue);

    // LINEAR 타일링 + HOST_VISIBLE 로 만들어 렌더 결과를 그대로 map 해 읽는다.
    VkImageCreateInfo imgci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {W, H, 1}, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_LINEAR,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    VkImage image;
    CHECK(vkCreateImage(dev, &imgci, NULL, &image), "create_image");

    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(dev, image, &mr);
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    uint32_t mtype = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        int want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((mr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) { mtype = i; break; }
    }
    if (mtype == UINT32_MAX) { printf("VULKAN no_host_visible_memory\n"); return 2; }
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                .allocationSize = mr.size, .memoryTypeIndex = mtype};
    VkDeviceMemory mem;
    CHECK(vkAllocateMemory(dev, &mai, NULL, &mem), "alloc_memory");
    CHECK(vkBindImageMemory(dev, image, mem, 0), "bind_image");

    VkImageViewCreateInfo ivci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkImageView view;
    CHECK(vkCreateImageView(dev, &ivci, NULL, &view), "create_view");

    VkAttachmentDescription att = {
        .format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_GENERAL};
    VkAttachmentReference ref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                                .colorAttachmentCount = 1, .pColorAttachments = &ref};
    VkRenderPassCreateInfo rpci = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
                                   .attachmentCount = 1, .pAttachments = &att,
                                   .subpassCount = 1, .pSubpasses = &sub};
    VkRenderPass rp;
    CHECK(vkCreateRenderPass(dev, &rpci, NULL, &rp), "create_render_pass");

    VkFramebufferCreateInfo fbci = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                                    .renderPass = rp, .attachmentCount = 1, .pAttachments = &view,
                                    .width = W, .height = H, .layers = 1};
    VkFramebuffer fb;
    CHECK(vkCreateFramebuffer(dev, &fbci, NULL, &fb), "create_framebuffer");

    VkCommandPoolCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = qfam};
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool), "create_pool");
    VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                        .commandBufferCount = 1};
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(dev, &cbai, &cb), "alloc_cmd");

    VkCommandBufferBeginInfo cbbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                     .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    vkBeginCommandBuffer(cb, &cbbi);
    VkClearValue bg = {.color = {{0.07f, 0.07f, 0.09f, 1.0f}}};
    VkRenderPassBeginInfo rpbi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                                  .renderPass = rp, .framebuffer = fb,
                                  .renderArea = {{0, 0}, {W, H}}, .clearValueCount = 1, .pClearValues = &bg};
    vkCmdBeginRenderPass(cb, &rpbi, VK_SUBPASS_CONTENTS_INLINE);

    // 셀 격자 — iOS Metal PoC 와 같은 모양을 낸다(같은 판정을 하려고).
    const int COLS = 20, ROWS = 6;
    float palette[6][3] = {
        {0.86f, 0.20f, 0.18f}, {0.20f, 0.72f, 0.35f}, {0.90f, 0.68f, 0.18f},
        {0.25f, 0.52f, 0.90f}, {0.70f, 0.35f, 0.85f}, {0.25f, 0.75f, 0.80f}};
    for (int r = 0; r < ROWS; r++) {
        for (int c = 0; c < COLS; c++) {
            float fade = 0.35f + 0.65f * ((float)c / COLS);
            VkClearAttachment ca = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0};
            ca.clearValue.color.float32[0] = palette[r][0] * fade;
            ca.clearValue.color.float32[1] = palette[r][1] * fade;
            ca.clearValue.color.float32[2] = palette[r][2] * fade;
            ca.clearValue.color.float32[3] = 1.0f;
            int x = c * (W / COLS) + 1, y = r * (H / ROWS) + 1;
            VkClearRect cr = {.rect = {{x, y}, {(uint32_t)(W / COLS - 2), (uint32_t)(H / ROWS - 2)}},
                              .baseArrayLayer = 0, .layerCount = 1};
            vkCmdClearAttachments(cb, 1, &ca, 1, &cr);
        }
    }
    vkCmdEndRenderPass(cb);
    vkEndCommandBuffer(cb);

    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE), "submit");
    vkQueueWaitIdle(queue);

    // 결과를 읽어 판정하고 PPM 으로 남긴다(Android 에 PNG 인코더가 없어 호스트에서 변환).
    VkImageSubresource sr = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0};
    VkSubresourceLayout layout;
    vkGetImageSubresourceLayout(dev, image, &sr, &layout);
    uint8_t *data = NULL;
    CHECK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&data), "map");
    data += layout.offset;

    int lit = 0;
    for (int y = 0; y < H; y++) {
        uint8_t *row = data + y * layout.rowPitch;
        for (int x = 0; x < W; x++)
            if (row[x * 4] > 20 || row[x * 4 + 1] > 20 || row[x * 4 + 2] > 20) lit++;
    }
    printf("PIXEL lit=%d/%d (%.1f%%)\n", lit, W * H, 100.0 * lit / (W * H));

    const char *out = "/data/local/tmp/maru-android-poc.ppm";
    FILE *f = fopen(out, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", W, H);
        for (int y = 0; y < H; y++) {
            uint8_t *row = data + y * layout.rowPitch;
            for (int x = 0; x < W; x++) fwrite(row + x * 4, 1, 3, f);
        }
        fclose(f);
        printf("PPM SAVED path=%s\n", out);
    }
    printf("POC_ANDROID %s\n", lit > W * H / 4 ? "PASS" : "FAIL");
    return lit > W * H / 4 ? 0 : 5;
}
