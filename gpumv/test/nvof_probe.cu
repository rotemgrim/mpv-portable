// Checks for NVIDIA's optical-flow hardware (NVOFA) through the driver's
// nvofapi64.dll, prints its capabilities and times flow estimation at 1080p
// and 4K for each speed level. Build with nvof_probe.cmd.

#include <cuda.h>
#include <cuda_runtime.h>
#include <windows.h>

#include <chrono>
#include <cstdio>
#include <vector>

#include "nvOpticalFlowCuda.h"

typedef NV_OF_STATUS(NVOFAPI* PFNCREATEINSTANCE)(uint32_t, NV_OF_CUDA_API_FUNCTION_LIST*);

#define OF(x)                                                                    \
    do {                                                                         \
        NV_OF_STATUS s_ = (x);                                                   \
        if (s_ != NV_OF_SUCCESS) {                                               \
            printf("%s failed: status %d\n", #x, (int)s_);                       \
            return false;                                                        \
        }                                                                        \
    } while (0)

static NV_OF_CUDA_API_FUNCTION_LIST api;

static bool caps(CUcontext ctx) {
    NvOFHandle h = nullptr;
    OF(api.nvCreateOpticalFlowCuda(ctx, &h));
    const struct { NV_OF_CAPS id; const char* name; } list[] = {
        {NV_OF_CAPS_SUPPORTED_OUTPUT_GRID_SIZES, "output grid sizes"},
        {NV_OF_CAPS_SUPPORTED_HINT_GRID_SIZES, "hint grid sizes"},
        {NV_OF_CAPS_SUPPORT_HINT_WITH_OF_MODE, "external hints"},
        {NV_OF_CAPS_WIDTH_MIN, "min width"}, {NV_OF_CAPS_HEIGHT_MIN, "min height"},
        {NV_OF_CAPS_WIDTH_MAX, "max width"}, {NV_OF_CAPS_HEIGHT_MAX, "max height"},
        {NV_OF_CAPS_SUPPORT_ROI, "regions of interest"},
    };
    for (auto& c : list) {
        uint32_t n = 0;
        if (api.nvOFGetCaps(h, c.id, nullptr, &n) != NV_OF_SUCCESS || !n) continue;
        std::vector<uint32_t> v(n);
        api.nvOFGetCaps(h, c.id, v.data(), &n);
        printf("  %-20s", c.name);
        for (auto x : v) printf(" %u", x);
        printf("\n");
    }
    api.nvOFDestroy(h);
    return true;
}

static bool bench(CUcontext ctx, uint32_t w, uint32_t hgt, NV_OF_PERF_LEVEL perf, const char* label) {
    NvOFHandle h = nullptr;
    OF(api.nvCreateOpticalFlowCuda(ctx, &h));
    NV_OF_INIT_PARAMS init = {};
    init.width = w;
    init.height = hgt;
    init.outGridSize = NV_OF_OUTPUT_VECTOR_GRID_SIZE_4;
    init.mode = NV_OF_MODE_OPTICALFLOW;
    init.perfLevel = perf;
    OF(api.nvOFInit(h, &init));

    NV_OF_BUFFER_DESCRIPTOR in = {w, hgt, NV_OF_BUFFER_USAGE_INPUT, NV_OF_BUFFER_FORMAT_GRAYSCALE8};
    NV_OF_BUFFER_DESCRIPTOR out = {(w + 3) / 4, (hgt + 3) / 4, NV_OF_BUFFER_USAGE_OUTPUT, NV_OF_BUFFER_FORMAT_SHORT2};
    NvOFGPUBufferHandle a, b, o;
    OF(api.nvOFCreateGPUBufferCuda(h, &in, NV_OF_CUDA_BUFFER_TYPE_CUDEVICEPTR, &a));
    OF(api.nvOFCreateGPUBufferCuda(h, &in, NV_OF_CUDA_BUFFER_TYPE_CUDEVICEPTR, &b));
    OF(api.nvOFCreateGPUBufferCuda(h, &out, NV_OF_CUDA_BUFFER_TYPE_CUDEVICEPTR, &o));

    // Two frames: a texture, and the same texture shifted 7 px right, 3 px down
    NV_OF_CUDA_BUFFER_STRIDE_INFO stride = {};
    OF(api.nvOFGPUBufferGetStrideInfo(a, &stride));
    const uint32_t pitch = stride.strideInfo[0].strideXInBytes;
    std::vector<uint8_t> fa((size_t)pitch * hgt), fb((size_t)pitch * hgt);
    for (uint32_t y = 0; y < hgt; y++)
        for (uint32_t x = 0; x < w; x++) {
            auto tex = [](int px, int py) { return (uint8_t)((px * 37 ^ py * 91) + ((px / 8 + py / 8) & 1) * 60); };
            fa[(size_t)y * pitch + x] = tex(x, y);
            fb[(size_t)y * pitch + x] = tex((int)x - 7, (int)y - 3);
        }
    cudaMemcpy((void*)api.nvOFGPUBufferGetCUdeviceptr(a), fa.data(), fa.size(), cudaMemcpyHostToDevice);
    cudaMemcpy((void*)api.nvOFGPUBufferGetCUdeviceptr(b), fb.data(), fb.size(), cudaMemcpyHostToDevice);

    NV_OF_EXECUTE_INPUT_PARAMS ein = {};
    ein.inputFrame = a;
    ein.referenceFrame = b;
    NV_OF_EXECUTE_OUTPUT_PARAMS eout = {};
    eout.outputBuffer = o;
    OF(api.nvOFExecute(h, &ein, &eout));  // warm-up
    cudaDeviceSynchronize();
    const int runs = 60;
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < runs; i++) OF(api.nvOFExecute(h, &ein, &eout));
    cudaDeviceSynchronize();
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / runs;

    // Check a vector in the middle: flow from a to b, in 1/32 pixel units
    NV_OF_CUDA_BUFFER_STRIDE_INFO ostride = {};
    api.nvOFGPUBufferGetStrideInfo(o, &ostride);
    std::vector<uint8_t> ov((size_t)ostride.strideInfo[0].strideXInBytes * out.height);
    cudaMemcpy(ov.data(), (void*)api.nvOFGPUBufferGetCUdeviceptr(o), ov.size(), cudaMemcpyDeviceToHost);
    auto* v = (NV_OF_FLOW_VECTOR*)(ov.data() + (size_t)ostride.strideInfo[0].strideXInBytes * (out.height / 2)) +
              out.width / 2;
    printf("  %-5s %-6s %6.2f ms per frame pair (%5.0f pairs/s), centre vector %.2f, %.2f px (expected 7, 3)\n",
           label, perf == NV_OF_PERF_LEVEL_FAST ? "fast" : perf == NV_OF_PERF_LEVEL_MEDIUM ? "medium" : "slow", ms,
           1000.0 / ms, v->flowx / 32.0, v->flowy / 32.0);

    api.nvOFDestroyGPUBufferCuda(a);
    api.nvOFDestroyGPUBufferCuda(b);
    api.nvOFDestroyGPUBufferCuda(o);
    api.nvOFDestroy(h);
    return true;
}

int main() {
    HMODULE lib = LoadLibraryA("nvofapi64.dll");
    if (!lib) {
        printf("nvofapi64.dll not found: no NVIDIA optical flow driver support\n");
        return 1;
    }
    auto create = (PFNCREATEINSTANCE)GetProcAddress(lib, "NvOFAPICreateInstanceCuda");
    if (!create || create(NV_OF_API_VERSION, &api) != NV_OF_SUCCESS) {
        printf("NvOFAPICreateInstanceCuda failed\n");
        return 1;
    }
    cudaFree(0);
    CUcontext ctx = nullptr;
    cuCtxGetCurrent(&ctx);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("%s, optical flow API %d.%d\n", prop.name, NV_OF_API_MAJOR_VERSION, NV_OF_API_MINOR_VERSION);
    if (!caps(ctx)) {
        printf("No optical-flow session: the hardware isn't available on this GPU\n");
        return 1;
    }
    for (auto perf : {NV_OF_PERF_LEVEL_FAST, NV_OF_PERF_LEVEL_MEDIUM, NV_OF_PERF_LEVEL_SLOW}) {
        bench(ctx, 1920, 1080, perf, "1080p");
        bench(ctx, 3840, 2160, perf, "4K");
    }
    return 0;
}
