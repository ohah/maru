// PoC 5(Android): maru 가 Metal 에서 쓰는 **여섯 기능**이 Vulkan 에서도 되는가.
//
// iOS 쪽 features_ios.m 과 같은 여섯 항목을 같은 방식(픽셀 판정)으로 본다.
// 이게 이식 난이도를 정하는 관문이다 — 화면이 뜨는 것과 지금 쓰는 렌더 기법이
// 그대로 되는 것은 다르다.
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 256
#define H 64
#define VK(x, m) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("  %s=%d\n", m, r_); return 1; } } while (0)

typedef struct { float rect[4]; float color[4]; float opacity; float pad[3]; } Push;

static int passed, failed;
static void report(const char *n, int ok, const char *d) {
    printf("  %-28s %s   %s\n", n, ok ? "PASS" : "FAIL", d ? d : "");
    if (ok) passed++; else failed++;
}

static VkShaderModule loadSpv(VkDevice dev, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("  spv_missing=%s\n", path); return VK_NULL_HANDLE; }
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

static VkDevice dev;
static VkQueue queue;
static VkRenderPass rp;
static VkFramebuffer fb;
static VkCommandBuffer cb;
static VkCommandPool pool;
static VkImage image;
static VkDeviceMemory mem;
static VkPipelineLayout layout, layoutTex;
static VkSubresourceLayout imgLayout;
static uint8_t *mapped;

static uint8_t *at(int x, int y) { return mapped + imgLayout.offset + (size_t)y * imgLayout.rowPitch + x * 4; }

static void beginPass(void) {
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                   .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    vkResetCommandBuffer(cb, 0);
    vkBeginCommandBuffer(cb, &bi);
    VkClearValue cv = {.color = {{0, 0, 0, 1}}};
    VkRenderPassBeginInfo rbi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                                 .renderPass = rp, .framebuffer = fb,
                                 .renderArea = {{0, 0}, {W, H}}, .clearValueCount = 1, .pClearValues = &cv};
    vkCmdBeginRenderPass(cb, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport vp = {0, 0, W, H, 0, 1};
    vkCmdSetViewport(cb, 0, 1, &vp);
    VkRect2D sc = {{0, 0}, {W, H}};
    vkCmdSetScissor(cb, 0, 1, &sc);
}
static void endPassAndWait(void) {
    vkCmdEndRenderPass(cb);
    vkEndCommandBuffer(cb);
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE);
    vkQueueWaitIdle(queue);
}

int main(void) {
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                             .pApplicationName = "maru-features", .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance inst;
    VK(vkCreateInstance(&ici, NULL, &inst), "create_instance");
    uint32_t n = 0;
    vkEnumeratePhysicalDevices(inst, &n, NULL);
    VkPhysicalDevice *pds = calloc(n, sizeof(*pds));
    vkEnumeratePhysicalDevices(inst, &n, pds);
    VkPhysicalDevice pd = pds[0];
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    printf("Android Vulkan — 여섯 기능  (device=%s)\n", props.deviceName);

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
    VK(vkCreateDevice(pd, &dci, NULL, &dev), "create_device");
    vkGetDeviceQueue(dev, qf, 0, &queue);

    VkImageCreateInfo imgci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                               .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {W, H, 1},
                               .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
                               .tiling = VK_IMAGE_TILING_LINEAR,
                               .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                               .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    VK(vkCreateImage(dev, &imgci, NULL, &image), "create_image");
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, image, &mr);
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    uint32_t mt = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        int want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((mr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) { mt = i; break; }
    }
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                .allocationSize = mr.size, .memoryTypeIndex = mt};
    VK(vkAllocateMemory(dev, &mai, NULL, &mem), "alloc");
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
                                   .attachmentCount = 1, .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sp};
    VK(vkCreateRenderPass(dev, &rpci, NULL, &rp), "render_pass");
    VkFramebufferCreateInfo fbci = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp,
                                    .attachmentCount = 1, .pAttachments = &view, .width = W, .height = H, .layers = 1};
    VK(vkCreateFramebuffer(dev, &fbci, NULL, &fb), "framebuffer");

    VkCommandPoolCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                    .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = qf};
    VK(vkCreateCommandPool(dev, &cpci, NULL, &pool), "pool");
    VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                        .commandBufferCount = 1};
    VK(vkAllocateCommandBuffers(dev, &cbai, &cb), "cmd");

    const char *dir = getenv("SPV_DIR");
    if (!dir) dir = "/data/local/tmp";
    char p1[256], p2[256], p3[256];
    snprintf(p1, sizeof p1, "%s/quad.vert.spv", dir);
    snprintf(p2, sizeof p2, "%s/solid.frag.spv", dir);
    snprintf(p3, sizeof p3, "%s/tex.frag.spv", dir);
    VkShaderModule vs = loadSpv(dev, p1), fsSolid = loadSpv(dev, p2), fsTex = loadSpv(dev, p3);
    if (!vs || !fsSolid) { printf("  shader_load_failed\n"); return 1; }

    VkPushConstantRange pcr = {VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(Push)};
    VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                                       .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr};
    VK(vkCreatePipelineLayout(dev, &plci, NULL, &layout), "layout");

    // 파이프라인 세 벌: blend 없음 / premultiplied / straight
    VkPipeline pipes[3];
    for (int mode = 0; mode < 3; mode++) {
        VkPipelineShaderStageCreateInfo st[2] = {
            {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
             .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main"},
            {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
             .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fsSolid, .pName = "main"}};
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
        VkPipelineColorBlendAttachmentState ba = {.colorWriteMask = 0xF};
        if (mode > 0) {
            ba.blendEnable = VK_TRUE;
            ba.srcColorBlendFactor = (mode == 1) ? VK_BLEND_FACTOR_ONE : VK_BLEND_FACTOR_SRC_ALPHA;
            ba.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
            ba.colorBlendOp = VK_BLEND_OP_ADD;
            ba.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
            ba.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
            ba.alphaBlendOp = VK_BLEND_OP_ADD;
        }
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
        VK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp, NULL, &pipes[mode]), "pipeline");
    }

    VK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&mapped), "map");
    VkImageSubresource sr = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0};
    vkGetImageSubresourceLayout(dev, image, &sr, &imgLayout);

    // ── 1. per-cell clip: vkCmdSetScissor 를 draw 사이에 바꿀 수 있는가
    {
        beginPass();
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipes[0]);
        Push p = {{-1, -1, 1, 1}, {1, 0, 0, 1}, 1.0f, {0}};
        VkRect2D s1 = {{0, 0}, {W / 2, H}};
        vkCmdSetScissor(cb, 0, 1, &s1);
        vkCmdPushConstants(cb, layout, pcr.stageFlags, 0, sizeof p, &p);
        vkCmdDraw(cb, 4, 1, 0, 0);
        p.color[0] = 0; p.color[2] = 1;
        VkRect2D s2 = {{W / 2, 0}, {W / 2, H}};
        vkCmdSetScissor(cb, 0, 1, &s2);
        vkCmdPushConstants(cb, layout, pcr.stageFlags, 0, sizeof p, &p);
        vkCmdDraw(cb, 4, 1, 0, 0);
        endPassAndWait();
        uint8_t *l = at(W / 4, H / 2), *r = at(3 * W / 4, H / 2);
        char d[96]; snprintf(d, sizeof d, "left R=%d B=%d · right R=%d B=%d", l[0], l[2], r[0], r[2]);
        report("1. per-cell clip", l[0] > 200 && l[2] < 50 && r[2] > 200 && r[0] < 50, d);
    }

    // ── 2. blink opacity uniform: push constant 를 draw 마다 바꿀 수 있는가
    {
        beginPass();
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipes[0]);
        for (int i = 0; i < 4; i++) {
            float x0 = -1.0f + 0.5f * i;
            Push p = {{x0, -1, x0 + 0.5f, 1}, {1, 1, 1, 1}, 0.25f * (i + 1), {0}};
            vkCmdPushConstants(cb, layout, pcr.stageFlags, 0, sizeof p, &p);
            vkCmdDraw(cb, 4, 1, 0, 0);
        }
        endPassAndWait();
        int v[4];
        for (int i = 0; i < 4; i++) v[i] = at(W / 8 + i * W / 4, H / 2)[1];
        char d[96]; snprintf(d, sizeof d, "G=%d,%d,%d,%d (단조 증가여야)", v[0], v[1], v[2], v[3]);
        report("2. blink opacity uniform", v[0] < v[1] && v[1] < v[2] && v[2] < v[3], d);
    }

    // ── 3. per-draw blend: 같은 패스에서 파이프라인을 바꿀 수 있는가
    {
        beginPass();
        Push p = {{-1, -1, 0, 1}, {1, 1, 1, 1}, 0.5f, {0}};
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipes[1]);   // premultiplied
        vkCmdPushConstants(cb, layout, pcr.stageFlags, 0, sizeof p, &p);
        vkCmdDraw(cb, 4, 1, 0, 0);
        p.rect[0] = 0; p.rect[2] = 1;
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipes[2]);   // straight
        vkCmdPushConstants(cb, layout, pcr.stageFlags, 0, sizeof p, &p);
        vkCmdDraw(cb, 4, 1, 0, 0);
        endPassAndWait();
        int pre = at(W / 4, H / 2)[1], str = at(3 * W / 4, H / 2)[1];
        char d[96]; snprintf(d, sizeof d, "premul G=%d vs straight G=%d (달라야)", pre, str);
        report("3. per-draw blend", pre != str, d);
    }

    // ── 4. 아틀라스 부분 업데이트: vkCmdCopyBufferToImage 의 region 으로 일부만 갱신되는가
    if (fsTex) {
        const uint32_t AW = 16;
        VkImageCreateInfo aci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                                 .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {AW, AW, 1},
                                 .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
                                 .tiling = VK_IMAGE_TILING_OPTIMAL,
                                 .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                                 .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
        VkImage atlas; VK(vkCreateImage(dev, &aci, NULL, &atlas), "atlas_image");
        VkMemoryRequirements amr; vkGetImageMemoryRequirements(dev, atlas, &amr);
        uint32_t amt = UINT32_MAX;
        for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
            if ((amr.memoryTypeBits & (1u << i)) &&
                (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { amt = i; break; }
        VkMemoryAllocateInfo amai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                     .allocationSize = amr.size, .memoryTypeIndex = amt};
        VkDeviceMemory amem; VK(vkAllocateMemory(dev, &amai, NULL, &amem), "atlas_mem");
        vkBindImageMemory(dev, atlas, amem, 0);

        // 스테이징 버퍼: 전체(녹색) + 패치(빨강)를 한 버퍼에
        VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                                  .size = AW * AW * 4 + 64,
                                  .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                  .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
        VkBuffer stage; VK(vkCreateBuffer(dev, &bci, NULL, &stage), "stage_buf");
        VkMemoryRequirements bmr; vkGetBufferMemoryRequirements(dev, stage, &bmr);
        uint32_t bmt = UINT32_MAX;
        for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
            int want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
            if ((bmr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) { bmt = i; break; }
        }
        VkMemoryAllocateInfo bmai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                     .allocationSize = bmr.size, .memoryTypeIndex = bmt};
        VkDeviceMemory bmem; VK(vkAllocateMemory(dev, &bmai, NULL, &bmem), "stage_mem");
        vkBindBufferMemory(dev, stage, bmem, 0);
        uint8_t *sp = NULL;
        vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&sp);
        memset(sp, 0, AW * AW * 4 + 64);
        for (uint32_t i = 0; i < AW * AW; i++) sp[i * 4 + 1] = 255;
        for (int i = 0; i < 16; i++) sp[AW * AW * 4 + i * 4 + 0] = 255;
        vkUnmapMemory(dev, bmem);

        VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                       .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
        vkResetCommandBuffer(cb, 0);
        vkBeginCommandBuffer(cb, &bi);
        VkImageMemoryBarrier tb = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                                   .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                                   .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                   .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                   .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = atlas,
                                   .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
                                   .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT};
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, NULL, 0, NULL, 1, &tb);
        VkBufferImageCopy full = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                  .imageExtent = {AW, AW, 1}};
        vkCmdCopyBufferToImage(cb, stage, atlas, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &full);
        // **부분 갱신** — 왼쪽 위 4×4 만(글리프 하나를 아틀라스에 넣는 것과 같다)
        VkBufferImageCopy patch = {.bufferOffset = AW * AW * 4,
                                   .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                   .imageOffset = {0, 0, 0}, .imageExtent = {4, 4, 1}};
        vkCmdCopyBufferToImage(cb, stage, atlas, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &patch);
        tb.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        tb.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        tb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        tb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             0, 0, NULL, 0, NULL, 1, &tb);
        vkEndCommandBuffer(cb);
        VkSubmitInfo si2 = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
        vkQueueSubmit(queue, 1, &si2, VK_NULL_HANDLE);
        vkQueueWaitIdle(queue);

        VkImageViewCreateInfo avci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = atlas,
                                      .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
                                      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
        VkImageView aview; VK(vkCreateImageView(dev, &avci, NULL, &aview), "atlas_view");
        VkSamplerCreateInfo sci = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                                   .magFilter = VK_FILTER_NEAREST, .minFilter = VK_FILTER_NEAREST};
        VkSampler samp; VK(vkCreateSampler(dev, &sci, NULL, &samp), "sampler");

        VkDescriptorSetLayoutBinding dslb = {.binding = 0,
                                             .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                                             .descriptorCount = 1,
                                             .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT};
        VkDescriptorSetLayoutCreateInfo dslci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                                 .bindingCount = 1, .pBindings = &dslb};
        VkDescriptorSetLayout dsl; VK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl), "dsl");
        VkDescriptorPoolSize dps = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1};
        VkDescriptorPoolCreateInfo dpci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                                           .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &dps};
        VkDescriptorPool dpool; VK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool), "dpool");
        VkDescriptorSetAllocateInfo dsai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                                            .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl};
        VkDescriptorSet dset; VK(vkAllocateDescriptorSets(dev, &dsai, &dset), "dset");
        VkDescriptorImageInfo dii = {samp, aview, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
        VkWriteDescriptorSet wds = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = dset,
                                    .dstBinding = 0, .descriptorCount = 1,
                                    .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                                    .pImageInfo = &dii};
        vkUpdateDescriptorSets(dev, 1, &wds, 0, NULL);

        VkPipelineLayoutCreateInfo tplci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                                            .setLayoutCount = 1, .pSetLayouts = &dsl,
                                            .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr};
        VK(vkCreatePipelineLayout(dev, &tplci, NULL, &layoutTex), "tex_layout");

        VkPipelineShaderStageCreateInfo st[2] = {
            {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
             .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main"},
            {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
             .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fsTex, .pName = "main"}};
        VkPipelineVertexInputStateCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        VkPipelineInputAssemblyStateCreateInfo ia = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                                                     .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP};
        VkPipelineViewportStateCreateInfo vps = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                                                 .viewportCount = 1, .scissorCount = 1};
        VkPipelineRasterizationStateCreateInfo rs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                                                     .polygonMode = VK_POLYGON_MODE_FILL,
                                                     .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1};
        VkPipelineMultisampleStateCreateInfo ms = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                                                   .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
        VkPipelineColorBlendAttachmentState ba = {.colorWriteMask = 0xF};
        VkPipelineColorBlendStateCreateInfo cbs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                                                   .attachmentCount = 1, .pAttachments = &ba};
        VkDynamicState dyn[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
        VkPipelineDynamicStateCreateInfo dsc = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
                                                .dynamicStateCount = 2, .pDynamicStates = dyn};
        VkGraphicsPipelineCreateInfo gp = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                                           .stageCount = 2, .pStages = st, .pVertexInputState = &vi,
                                           .pInputAssemblyState = &ia, .pViewportState = &vps,
                                           .pRasterizationState = &rs, .pMultisampleState = &ms,
                                           .pColorBlendState = &cbs, .pDynamicState = &dsc,
                                           .layout = layoutTex, .renderPass = rp};
        VkPipeline pTex; VK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp, NULL, &pTex), "tex_pipeline");

        beginPass();
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pTex);
        vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, layoutTex, 0, 1, &dset, 0, NULL);
        Push p = {{-1, -1, 1, 1}, {1, 1, 1, 1}, 1.0f, {0}};
        vkCmdPushConstants(cb, layoutTex, pcr.stageFlags, 0, sizeof p, &p);
        vkCmdDraw(cb, 4, 1, 0, 0);
        endPassAndWait();
        uint8_t *tl = at(W / 16, H / 16), *br = at(W * 3 / 4, H * 3 / 4);
        char d[96]; snprintf(d, sizeof d, "patch R=%d · base G=%d", tl[0], br[1]);
        report("4. 아틀라스 부분 업데이트", tl[0] > 200 && br[1] > 200, d);
    } else {
        report("4. 아틀라스 부분 업데이트", 0, "tex.frag.spv 없음");
    }

    // ── 5. 자연폭 quad: push constant 의 rect 로 폭을 제각각 준다
    {
        beginPass();
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipes[0]);
        float widths[4] = {0.2f, 0.5f, 0.3f, 0.8f};
        float x = -1.0f;
        for (int i = 0; i < 4; i++) {
            Push p = {{x, -1, x + widths[i], 1}, {1, 1, 1, 1}, 1.0f, {0}};
            vkCmdPushConstants(cb, layout, pcr.stageFlags, 0, sizeof p, &p);
            vkCmdDraw(cb, 4, 1, 0, 0);
            x += widths[i] + 0.1f;
        }
        endPassAndWait();
        int runlen[8] = {0}, nrun = 0, prev = 0, cur = 0;
        for (int xx = 0; xx < W && nrun < 8; xx++) {
            int lit = at(xx, H / 2)[1] > 128;
            if (lit != prev) { if (prev && cur) runlen[nrun++] = cur; cur = 0; prev = lit; }
            if (lit) cur++;
        }
        if (prev && cur && nrun < 8) runlen[nrun++] = cur;
        int distinct = 0;
        for (int i = 0; i < nrun; i++) {
            int dup = 0;
            for (int j = 0; j < i; j++) if (runlen[j] == runlen[i]) dup = 1;
            if (!dup) distinct++;
        }
        char d[96]; snprintf(d, sizeof d, "흰 구간 폭 %d,%d,%d,%d px · 서로 다른 값 %d개",
                             runlen[0], runlen[1], runlen[2], runlen[3], distinct);
        report("5. 자연폭 quad", nrun >= 4 && distinct >= 3, d);
    }

    // ── 6. present 페이싱: 스왑체인이 없으면 판정 불가. 다만 지원 모드는 열거할 수 있다.
    report("6. present 페이싱", 0, "스왑체인 필요 — 오프스크린 범위 밖");

    printf("\n결과: %d PASS / %d FAIL\n", passed, failed);
    return 0;
}
