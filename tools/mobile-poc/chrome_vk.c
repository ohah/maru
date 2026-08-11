// PoC 6(Android): **maru 의 실제 chrome 컴포넌트**가 낸 draw-list 를 Vulkan 으로 그린다.
//
// iOS 쪽 chrome_app.m 과 같은 draw-list 를 받아 같은 그림을 내는지 본다 — 그게
// "L3 chrome 이 배치하고 L4 platform 은 그리기만 한다"는 계약의 증거다.
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 900
#define H 560
#define VK(x, m) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("VULKAN %s=%d\n", m, r_); return 1; } } while (0)

typedef struct {
    float x, y, w, h;
    float r, g, b, a;
    float radius;
    unsigned int is_text;
} CQuad;

extern unsigned int maru_chrome_build(unsigned int width, unsigned int height);
extern const CQuad *maru_chrome_quads(void);
extern const char *maru_chrome_last_error(void);

typedef struct { float rect_px[4]; float color[4]; float misc[4]; } Push;

static VkShaderModule loadSpv(VkDevice dev, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("spv_missing=%s\n", path); return VK_NULL_HANDLE; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *buf = malloc(n);
    if (fread(buf, 1, n, f) != (size_t)n) { fclose(f); free(buf); return VK_NULL_HANDLE; }
    fclose(f);
    VkShaderModuleCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                   .codeSize = n, .pCode = buf};
    VkShaderModule m = VK_NULL_HANDLE;
    vkCreateShaderModule(dev, &ci, NULL, &m);
    free(buf);
    return m;
}

int main(void) {
    unsigned int n = maru_chrome_build(W, H);
    printf("MARU_CHROME quads=%u err=%s\n", n, maru_chrome_last_error());
    if (n == 0) return 1;
    const CQuad *quads = maru_chrome_quads();

    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                             .pApplicationName = "maru-chrome", .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance inst; VK(vkCreateInstance(&ici, NULL, &inst), "instance");
    uint32_t pn = 0; vkEnumeratePhysicalDevices(inst, &pn, NULL);
    VkPhysicalDevice *pds = calloc(pn, sizeof(*pds));
    vkEnumeratePhysicalDevices(inst, &pn, pds);
    VkPhysicalDevice pd = pds[0];
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
    printf("VULKAN device=%s\n", props.deviceName);

    uint32_t qn = 0, qf = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, NULL);
    VkQueueFamilyProperties *qs = calloc(qn, sizeof(*qs));
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, qs);
    for (uint32_t i = 0; i < qn; i++) if (qs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { qf = i; break; }
    float prio = 1;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                   .queueFamilyIndex = qf, .queueCount = 1, .pQueuePriorities = &prio};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
    VkDevice dev; VK(vkCreateDevice(pd, &dci, NULL, &dev), "device");
    VkQueue queue; vkGetDeviceQueue(dev, qf, 0, &queue);

    VkImageCreateInfo imgci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                               .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {W, H, 1},
                               .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
                               .tiling = VK_IMAGE_TILING_LINEAR,
                               .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                               .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    VkImage image; VK(vkCreateImage(dev, &imgci, NULL, &image), "image");
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, image, &mr);
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    uint32_t mt = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        int want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((mr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) { mt = i; break; }
    }
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                .allocationSize = mr.size, .memoryTypeIndex = mt};
    VkDeviceMemory mem; VK(vkAllocateMemory(dev, &mai, NULL, &mem), "memory");
    vkBindImageMemory(dev, image, mem, 0);
    VkImageViewCreateInfo ivci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
                                  .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
                                  .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkImageView view; VK(vkCreateImageView(dev, &ivci, NULL, &view), "view");

    VkAttachmentDescription att = {.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
                                   .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                                   .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                   .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                                   .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                                   .finalLayout = VK_IMAGE_LAYOUT_GENERAL};
    VkAttachmentReference ar = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sp = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                               .colorAttachmentCount = 1, .pColorAttachments = &ar};
    VkRenderPassCreateInfo rpci = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
                                   .attachmentCount = 1, .pAttachments = &att,
                                   .subpassCount = 1, .pSubpasses = &sp};
    VkRenderPass rp; VK(vkCreateRenderPass(dev, &rpci, NULL, &rp), "render_pass");
    VkFramebufferCreateInfo fbci = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp,
                                    .attachmentCount = 1, .pAttachments = &view,
                                    .width = W, .height = H, .layers = 1};
    VkFramebuffer fb; VK(vkCreateFramebuffer(dev, &fbci, NULL, &fb), "framebuffer");

    const char *dir = getenv("SPV_DIR"); if (!dir) dir = "/data/local/tmp";
    char vpath[256], fpath[256];
    snprintf(vpath, sizeof vpath, "%s/chrome.vert.spv", dir);
    snprintf(fpath, sizeof fpath, "%s/chrome.frag.spv", dir);
    VkShaderModule vs = loadSpv(dev, vpath), fs = loadSpv(dev, fpath);
    if (!vs || !fs) return 1;

    VkPushConstantRange pcr = {VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(Push)};
    VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                                       .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr};
    VkPipelineLayout layout; VK(vkCreatePipelineLayout(dev, &plci, NULL, &layout), "layout");

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
                                              .alphaBlendOp = VK_BLEND_OP_ADD,
                                              .colorWriteMask = 0xF};
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
                                       .layout = layout, .renderPass = rp};
    VkPipeline pipe; VK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp, NULL, &pipe), "pipeline");

    VkCommandPoolCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = qf};
    VkCommandPool pool; VK(vkCreateCommandPool(dev, &cpci, NULL, &pool), "pool");
    VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                        .commandBufferCount = 1};
    VkCommandBuffer cb; VK(vkAllocateCommandBuffers(dev, &cbai, &cb), "cmd");

    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                   .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    vkBeginCommandBuffer(cb, &bi);
    VkClearValue cv = {.color = {{0.05f, 0.05f, 0.06f, 1.0f}}};
    VkRenderPassBeginInfo rbi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp,
                                 .framebuffer = fb, .renderArea = {{0, 0}, {W, H}},
                                 .clearValueCount = 1, .pClearValues = &cv};
    vkCmdBeginRenderPass(cb, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport vpt = {0, 0, W, H, 0, 1};
    vkCmdSetViewport(cb, 0, 1, &vpt);
    VkRect2D sc = {{0, 0}, {W, H}};
    vkCmdSetScissor(cb, 0, 1, &sc);
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);

    // **chrome 이 준 op 을 그대로 그린다.** 플랫폼은 배치를 모른다.
    for (unsigned int i = 0; i < n; i++) {
        const CQuad *q = &quads[i];
        Push p = {{q->x, q->y, q->x + q->w, q->y + q->h},
                  {q->r, q->g, q->b, q->a},
                  {q->radius, (float)W, (float)H, (float)q->is_text}};
        vkCmdPushConstants(cb, layout, pcr.stageFlags, 0, sizeof p, &p);
        vkCmdDraw(cb, 4, 1, 0, 0);
    }
    vkCmdEndRenderPass(cb);
    vkEndCommandBuffer(cb);
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE);
    vkQueueWaitIdle(queue);

    VkImageSubresource sr = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0};
    VkSubresourceLayout lay; vkGetImageSubresourceLayout(dev, image, &sr, &lay);
    uint8_t *data = NULL;
    VK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&data), "map");
    data += lay.offset;

    const char *out = "/data/local/tmp/maru-chrome-android.ppm";
    FILE *f = fopen(out, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", W, H);
        for (int y = 0; y < H; y++) {
            uint8_t *row = data + y * lay.rowPitch;
            for (int x = 0; x < W; x++) fwrite(row + x * 4, 1, 3, f);
        }
        fclose(f);
        printf("PPM SAVED path=%s\n", out);
    }
    int lit = 0;
    for (int y = 0; y < H; y++) {
        uint8_t *row = data + y * lay.rowPitch;
        for (int x = 0; x < W; x++)
            if (row[x * 4] > 30 || row[x * 4 + 1] > 30 || row[x * 4 + 2] > 30) lit++;
    }
    printf("PIXEL lit=%d/%d (%.1f%%)\nMARU_CHROME_ANDROID %s\n",
           lit, W * H, 100.0 * lit / (W * H), lit > 1000 ? "PASS" : "FAIL");
    return lit > 1000 ? 0 : 1;
}
