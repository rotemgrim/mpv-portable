// gpumv: GPU motion-compensated frame interpolation for VapourSynth.
//
// Aims for the output of MVTools' Super/Analyse/BlockFPS|FlowFPS chain, with
// everything (pyramid, motion search, rendering) running on the GPU via CUDA.
//
// Per source pair (A = frame i, B = frame i+1):
//   1. Luma pyramid, 2x box downscale per level, optionally from a lightly
//      blurred copy so grain and noise don't steer the vectors (the output
//      is still rendered from the original frames).
//   2. Hierarchical block matching in both directions (A->B forward,
//      B->A backward). The coarsest level does an exhaustive search; finer
//      levels try the upscaled parent vector, its neighbours and zero, then
//      refine locally. Cost = mean SAD + lambda * |v - parent| (coherence,
//      the job MVTools' truemotion does). With lambdaflat set, lambda grows
//      towards it in flat blocks, where any vector matches about as well
//      (flat colour in animation, sky, walls) and only coherence picks the
//      right one; textured blocks keep the plain lambda.
//   3. Optional 3x3 vector median and an occlusion mask per direction: blocks
//      whose best match is still poor, or where vectors converge.
//   4. Letterbox bars: rows and columns from the edges that stay dark in both
//      frames. Everything below treats the bar edge as the frame edge, and
//      the bars themselves are passed through.
//   5. Fades: the brightness ratio of the two frames (around black) is
//      applied to one side before any matching, so vectors and the scene
//      change test keep working through fades.
//   6. Scene change: the thscd1/thscd2 block count, or the pair's mean match
//      error spiking against the neighbouring pairs (catches dark cuts the
//      fixed thresholds miss). Cuts show the nearest real frame.
// Motion source (nvof): instead of the block search, NVIDIA's optical-flow
// hardware (NVOFA, Turing and later) can supply the vectors, one per 4x4
// pixels in both directions; everything after the search stays the same.
// Held frames (dedup=1, for animation drawn on twos or threes): runs of up
// to holdmax identical frames are treated as one drawing, and the motion to
// the next drawing is spread over the whole run, the held copies included.
// Longer runs are a still shot and stay as they are.
// Per output frame at time t in (0, 1):
//   modes 0 (block) and 1 (flow): pixel p = (1-t)*A(p - t*vF) + t*B(p - (1-t)*vB)
//   with block or per-pixel interpolated vectors, MVTools style.
//   mode 2 (adaptive): every 8x8 tile picks, from the nearby forward and
//   backward vectors, the one whose path through p lines A and B up best.
//   Pixels then choose between the four surrounding tile vectors, so object
//   edges are not smeared. Each side is weighted down where the other frame
//   cannot see the content (occlusion), and where no vector fits at all the
//   result fades to a plain frame blend (artifact masking).

#define NOMINMAX
#include <windows.h>

#include <cuda.h>
#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <map>
#include <mutex>
#include <stdexcept>
#include <string>

#include "VSHelper4.h"
#include "nvOpticalFlowCuda.h"
#include "VapourSynth4.h"

#define CK(x)                                                                                 \
    do {                                                                                      \
        cudaError_t e_ = (x);                                                                 \
        if (e_ != cudaSuccess)                                                                \
            throw std::runtime_error(std::string(#x) + ": " + cudaGetErrorString(e_));       \
    } while (0)

static constexpr int kMaxLevels = 8;
static constexpr int kSlots = 10;  // uploaded source frames kept on the GPU (held-frame window and a spare)
static constexpr int kPairs = 4;   // motion fields kept on the GPU (previous, current, next and a spare)
static constexpr int kTile = 8;   // adaptive mode vector tile, in luma pixels
static constexpr int kMaxSplit = 2;
static constexpr int kGlobalRadius = 32;  // most camera motion search range at the coarsest level
static constexpr int kBarsHold = 12;  // frame pairs new letterbox bars must hold before they are used

struct Params {
    int mode = 2;        // 0 block (BlockFPS-like), 1 flow (FlowFPS-like), 2 adaptive
    int blksize = 16;    // 8, 16 or 32
    int pel = 1;         // 1 integer, 2 half-pel refinement at full resolution
    int radius = 4;      // exhaustive search radius at the coarsest level
    int refine = 2;      // local refinement radius at finer levels
    float lambda = 0.1f;
    float lambdaflat = 0.f;  // coherence in flat blocks (0 = same as lambda everywhere)
    float texref = 4.f;      // block texture (8-bit mean deviation) halfway between the two
    int smooth = 1;      // 3x3 median on the full-resolution vectors
    int split = 0;       // times a badly matched block is split in four and searched again
    int thsad = 250;     // SAD of an 8x8 block (8-bit) above which a block is split
    int gmv = 1;         // try the frame's global (camera) motion as a candidate
    int temporal = 1;    // try the block's vector from the previous frame pair
    int blend = 0;       // scene change: blend (1) or show the nearest frame (0)
    int thscd1 = 400;    // SAD of an 8x8 block (8-bit) above which it changed
    int thscd2 = 130;    // changed blocks, out of 255, for a scene change
    float scratio = 3.f; // pair error this many times its neighbours' = scene change (0 = off)
    float ml = 100.f;    // occlusion mask scale, lower = stricter
    float mask = 0.5f;   // adaptive mode artifact masking strength (0 = off)
    float occsad = 2.f;  // scale of the match error that counts as occluded (0 = vector convergence only)
    int bars = 1;        // detect letterbox bars and keep them out of the interpolation
    int fades = 1;       // compensate brightness changes between frames when matching
    float strength = 1.f; // 1 = even motion; lower keeps real frames on screen longer (film look)
    int dedup = 1;       // spread motion over held frames (animation on twos/threes)
    int holdmax = 3;     // longest run of identical frames that counts as one held drawing
    float dupth = 0.4f;  // mean difference (8-bit, quarter resolution) below which two frames are identical
    int prefilter = 0;   // blur radius (0-2) of the copy used for matching, against grain (no gain measured)
    float statics = 0.f; // adaptive mode: extra rule keeping unchanged pixels still (0 = off; adaptive already keeps subtitles intact)
    float barsth = 24.f; // brightest pixel (8-bit) a bar row or column may have
    int nvof = 0;        // motion from NVIDIA's optical-flow hardware: 0 off, 1 fast, 2 medium, 3 slow (best)
    int device = 0;
};

struct FrameInfo {
    int scene = 0;
    float score = 0.f;  // mean per-pixel match error of the pair, 8-bit units
    int area[4] = {};   // active picture x0, y0, x1, y1 (luma)
    float gain = 1.f;   // brightness ratio B / A used for fade compensation
    int held = 1;       // source frames the motion was spread over (1 = no held frames)
    int nvof = 0;       // vectors came from the optical-flow hardware
    int copied = 0;     // the output is a source frame as is
};

// ---------------------------------------------------------------------------
// Kernels

template <typename T>
__global__ void to_float(const T* __restrict__ src, int w, int h, int spitch, float* __restrict__ dst,
                         int dpitch, float scale) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x < w && y < h) dst[y * dpitch + x] = src[y * spitch + x] * scale;
}

// Binomial blur (radius 1: 1 2 1, radius 2: 1 4 6 4 1) for the matching copy
__global__ void blur(const float* __restrict__ src, float* __restrict__ dst, int w, int h, int pitch, int radius) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;
    const float k1[3] = {1.f, 2.f, 1.f}, k2[5] = {1.f, 4.f, 6.f, 4.f, 1.f};
    const float* k = radius == 1 ? k1 : k2;
    float sum = 0.f, wsum = 0.f;
    for (int dy = -radius; dy <= radius; dy++)
        for (int dx = -radius; dx <= radius; dx++) {
            int sx = min(max(x + dx, 0), w - 1), sy = min(max(y + dy, 0), h - 1);
            float wt = k[dx + radius] * k[dy + radius];
            sum += wt * src[sy * pitch + sx];
            wsum += wt;
        }
    dst[y * pitch + x] = sum / wsum;
}

__global__ void downscale2(const float* __restrict__ src, int sw, int sh, int spitch, float* __restrict__ dst,
                           int dw, int dh, int dpitch) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= dw || y >= dh) return;
    int x0 = min(2 * x, sw - 1), x1 = min(2 * x + 1, sw - 1);
    int y0 = min(2 * y, sh - 1), y1 = min(2 * y + 1, sh - 1);
    dst[y * dpitch + x] =
        0.25f * (src[y0 * spitch + x0] + src[y0 * spitch + x1] + src[y1 * spitch + x0] + src[y1 * spitch + x1]);
}

// Active picture, end exclusive. Letterbox bars lie outside it, and sampling
// never crosses its edge.
struct Area {
    int x0, y0, x1, y1;
};

// Brightness of the current frame mapped onto the reference: v * gain + offset
struct Gain {
    float gain, offset;
};

__device__ __forceinline__ float apply(const Gain& g, float v) { return v * g.gain + g.offset; }

__device__ __forceinline__ bool inside(const Area& a, int x, int y) {
    return x >= a.x0 && x < a.x1 && y >= a.y0 && y < a.y1;
}

__device__ __forceinline__ float bilinear(const float* __restrict__ p, int pitch, const Area& ar, float x, float y) {
    x = fminf(fmaxf(x, (float)ar.x0), (float)(ar.x1 - 1));
    y = fminf(fmaxf(y, (float)ar.y0), (float)(ar.y1 - 1));
    int x0 = (int)x, y0 = (int)y;
    int x1 = min(x0 + 1, ar.x1 - 1), y1 = min(y0 + 1, ar.y1 - 1);
    float fx = x - x0, fy = y - y0;
    float a = p[y0 * pitch + x0], b = p[y0 * pitch + x1];
    float c = p[y1 * pitch + x0], d = p[y1 * pitch + x1];
    return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy;
}

// Optical-flow hardware input: 8-bit luma, brightness mapped onto the other frame
__global__ void to_u8(const float* __restrict__ src, int w, int h, int pitch, Gain gain, uint8_t* __restrict__ dst,
                      int dpitch) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x < w && y < h) dst[y * dpitch + x] = (uint8_t)min(max((int)lrintf(apply(gain, src[y * pitch + x])), 0), 255);
}

// Optical-flow hardware output (S10.5 fixed point per 4x4) to a vector field
__global__ void flow_to_field(const NV_OF_FLOW_VECTOR* __restrict__ flow, int fpitch, int nbx, int nby,
                              float2* __restrict__ out) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= nbx || y >= nby) return;
    NV_OF_FLOW_VECTOR f = flow[y * fpitch + x];
    out[y * nbx + x] = make_float2(f.flowx / 32.f, f.flowy / 32.f);
}

// Mean match error of each block along its vector, for occlusion and scene tests
__global__ void block_sad(const float* __restrict__ cur, const float* __restrict__ ref, int pitch, Area ar,
                          const float2* __restrict__ v, int nbx, int nby, int bs, Gain gain, float* __restrict__ sad) {
    int bx = blockIdx.x * blockDim.x + threadIdx.x, by = blockIdx.y * blockDim.y + threadIdx.y;
    if (bx >= nbx || by >= nby) return;
    float2 m = v[by * nbx + bx];
    float s = 0.f;
    int n = 0;
    for (int y = by * bs; y < by * bs + bs; y++)
        for (int x = bx * bs; x < bx * bs + bs; x++) {
            if (!inside(ar, x, y)) continue;
            s += fabsf(apply(gain, cur[y * pitch + x]) - bilinear(ref, pitch, ar, x + m.x, y + m.y));
            n++;
        }
    sad[by * nbx + bx] = n ? s / n : 0.f;
}

// Brightest pixel of each row (one block per row) and each column
__global__ void row_max(const float* __restrict__ p, int w, int pitch, float* __restrict__ out) {
    __shared__ float m[256];
    float v = 0.f;
    for (int x = threadIdx.x; x < w; x += blockDim.x) v = fmaxf(v, p[blockIdx.x * pitch + x]);
    m[threadIdx.x] = v;
    __syncthreads();
    for (int o = blockDim.x / 2; o > 0; o >>= 1) {
        if (threadIdx.x < o) m[threadIdx.x] = fmaxf(m[threadIdx.x], m[threadIdx.x + o]);
        __syncthreads();
    }
    if (threadIdx.x == 0) out[blockIdx.x] = m[0];
}

__global__ void col_max(const float* __restrict__ p, int w, int h, int pitch, float* __restrict__ out) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    if (x >= w) return;
    float v = 0.f;
    for (int y = 0; y < h; y++) v = fmaxf(v, p[y * pitch + x]);
    out[x] = v;
}

__device__ __forceinline__ float warp_sum(float v) {
    for (int o = 16; o > 0; o >>= 1) v += __shfl_xor_sync(0xffffffffu, v, o);
    return v;
}

// Sum of absolute differences of two images, for the held-frame test
__global__ void frame_diff(const float* __restrict__ a, const float* __restrict__ b, int n, float* __restrict__ sum) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float d = i < n ? fabsf(a[i] - b[i]) : 0.f;
    d = warp_sum(d);
    if ((threadIdx.x & 31) == 0) atomicAdd(sum, d);
}

__device__ __forceinline__ float smoothstep(float lo, float hi, float x) {
    float t = fminf(fmaxf((x - lo) / (hi - lo), 0.f), 1.f);
    return t * t * (3.f - 2.f * t);
}

// One warp per block. Every lane evaluates the same candidates, so all lanes
// agree on the best vector without extra communication.
//
// Used for both kinds of refinement:
//   pyramid level: parent is the coarser level, pscale = 2
//   block split:   parent is the same frame in blocks twice the size, pscale = 1;
//                  blocks whose parent already matched well (parent_sad <= gate)
//                  just inherit its vector
// Candidates besides the parent and its neighbours: zero, the frame's global
// (camera) motion and the vector the block had in the previous frame pair.
template <int BS>
__global__ void motion_search(const float* __restrict__ cur, const float* __restrict__ ref, Area ar,
                              int pitch, int nbx, int nby, const float2* __restrict__ parent,
                              const float* __restrict__ parent_sad, int pnbx, int pnby, float pscale, float gate,
                              const float2* __restrict__ prior, float2 global, int use_global, int radius,
                              int refine, float lambda, float lambdaflat, float texref, int halfpel, Gain gain,
                              float2* __restrict__ outv,
                              float* __restrict__ outsad) {
    constexpr int NP = BS * BS / 32;
    const int lane = threadIdx.x;
    const int bi = blockIdx.x * blockDim.y + threadIdx.y;
    if (bi >= nbx * nby) return;
    const int bx = bi % nbx, by = bi / nbx;
    const int x0 = bx * BS, y0 = by * BS;

    float c[NP];
    int px[NP], py[NP];
    bool in[NP];
    float valid = 0.f;
#pragma unroll
    for (int k = 0; k < NP; k++) {
        int idx = lane + 32 * k;
        px[k] = x0 + idx % BS;
        py[k] = y0 + idx / BS;
        in[k] = inside(ar, px[k], py[k]);
        c[k] = in[k] ? apply(gain, cur[py[k] * pitch + px[k]]) : 0.f;
        valid += in[k] ? 1.f : 0.f;
    }
    const float inv_n = 1.f / fmaxf(warp_sum(valid), 1.f);

    // Texture of the block: mean absolute deviation from its mean
    float lam = lambda;
    if (lambdaflat > lambda) {
        float sum = 0.f;
#pragma unroll
        for (int k = 0; k < NP; k++) sum += in[k] ? c[k] : 0.f;
        const float mean = warp_sum(sum) * inv_n;
        float dev = 0.f;
#pragma unroll
        for (int k = 0; k < NP; k++) dev += in[k] ? fabsf(c[k] - mean) : 0.f;
        dev = warp_sum(dev) * inv_n;
        lam = lambda + (lambdaflat - lambda) * texref / (texref + dev);
    }

    auto sad_int = [&](int vx, int vy) {
        float s = 0.f;
#pragma unroll
        for (int k = 0; k < NP; k++) {
            if (!in[k]) continue;
            int rx = min(max(px[k] + vx, ar.x0), ar.x1 - 1), ry = min(max(py[k] + vy, ar.y0), ar.y1 - 1);
            s += fabsf(c[k] - ref[ry * pitch + rx]);
        }
        return warp_sum(s) * inv_n;
    };
    auto sad_frac = [&](float vx, float vy) {
        float s = 0.f;
#pragma unroll
        for (int k = 0; k < NP; k++) {
            if (!in[k]) continue;
            s += fabsf(c[k] - bilinear(ref, pitch, ar, px[k] + vx, py[k] + vy));
        }
        return warp_sum(s) * inv_n;
    };

    float2 pred = make_float2(0.f, 0.f);
    int qx = 0, qy = 0;
    if (parent) {
        qx = min(bx / 2, pnbx - 1);
        qy = min(by / 2, pnby - 1);
        float2 pv = parent[qy * pnbx + qx];
        pred = make_float2(pscale * pv.x, pscale * pv.y);
        if (parent_sad && parent_sad[qy * pnbx + qx] <= gate) {
            // Matched well as part of the bigger block: keep its vector
            if (lane == 0) outv[bi] = pred;
            float s = sad_frac(pred.x, pred.y);
            if (lane == 0) outsad[bi] = s;
            return;
        }
    }
    auto penalty = [&](float vx, float vy) { return lam * (fabsf(vx - pred.x) + fabsf(vy - pred.y)); };

    int best_x = 0, best_y = 0;
    float best_sad = sad_int(0, 0);
    float best_cost = best_sad + penalty(0.f, 0.f);
    auto try_int = [&](int vx, int vy) {
        float s = sad_int(vx, vy);
        float cost = s + penalty((float)vx, (float)vy);
        if (cost < best_cost) {
            best_cost = cost;
            best_sad = s;
            best_x = vx;
            best_y = vy;
        }
    };

    int r = radius;
    if (parent) {
        const int ox[5] = {0, -1, 1, 0, 0}, oy[5] = {0, 0, 0, -1, 1};
#pragma unroll
        for (int k = 0; k < 5; k++) {
            int nx = min(max(qx + ox[k], 0), pnbx - 1), ny = min(max(qy + oy[k], 0), pnby - 1);
            float2 v = parent[ny * pnbx + nx];
            try_int((int)lrintf(pscale * v.x), (int)lrintf(pscale * v.y));
        }
        r = refine;
    }
    if (use_global) try_int((int)lrintf(global.x), (int)lrintf(global.y));
    if (prior) {
        float2 v = prior[bi];
        try_int((int)lrintf(v.x), (int)lrintf(v.y));
    }
    const int cx = best_x, cy = best_y;
    for (int dy = -r; dy <= r; dy++)
        for (int dx = -r; dx <= r; dx++)
            if (dx || dy) try_int(cx + dx, cy + dy);

    float fx = (float)best_x, fy = (float)best_y;
    if (halfpel) {
        const float hx[8] = {-.5f, 0.f, .5f, -.5f, .5f, -.5f, 0.f, .5f};
        const float hy[8] = {-.5f, -.5f, -.5f, 0.f, 0.f, .5f, .5f, .5f};
        const float bxi = fx, byi = fy;
#pragma unroll
        for (int k = 0; k < 8; k++) {
            float vx = bxi + hx[k], vy = byi + hy[k];
            float s = sad_frac(vx, vy);
            float cost = s + penalty(vx, vy);
            if (cost < best_cost) {
                best_cost = cost;
                best_sad = s;
                fx = vx;
                fy = vy;
            }
        }
    }

    if (lane == 0) {
        outv[bi] = make_float2(fx, fy);
        if (outsad) outsad[bi] = best_sad;
    }
}

// Camera motion: one block per whole-frame shift (dx, dy) at the coarsest
// level, cost = mean absolute difference over the overlap (infinite if the
// overlap is under half the area)
__global__ void global_search(const float* __restrict__ cur, const float* __restrict__ ref, int pitch, Area ar,
                              int radius, Gain gain, float* __restrict__ cost) {
    const int side = 2 * radius + 1;
    const int dx = (int)(blockIdx.x % side) - radius, dy = (int)(blockIdx.x / side) - radius;
    const int x0 = max(ar.x0, ar.x0 - dx), x1 = min(ar.x1, ar.x1 - dx);
    const int y0 = max(ar.y0, ar.y0 - dy), y1 = min(ar.y1, ar.y1 - dy);
    const int ow = x1 - x0, oh = y1 - y0;
    __shared__ float sum[256];
    float s = 0.f;
    if (ow > 0 && oh > 0)
        for (int i = threadIdx.x; i < ow * oh; i += blockDim.x) {
            int x = x0 + i % ow, y = y0 + i / ow;
            s += fabsf(apply(gain, cur[y * pitch + x]) - ref[(y + dy) * pitch + x + dx]);
        }
    sum[threadIdx.x] = s;
    __syncthreads();
    for (int o = blockDim.x / 2; o > 0; o >>= 1) {
        if (threadIdx.x < o) sum[threadIdx.x] += sum[threadIdx.x + o];
        __syncthreads();
    }
    if (threadIdx.x == 0) {
        const int area = (ar.x1 - ar.x0) * (ar.y1 - ar.y0);
        cost[blockIdx.x] = (ow > 0 && oh > 0 && 2 * ow * oh >= area) ? sum[0] / (ow * oh) : 1e30f;
    }
}

__device__ __forceinline__ void sort9(float* v) {
    for (int i = 1; i < 9; i++) {
        float x = v[i];
        int j = i - 1;
        while (j >= 0 && v[j] > x) {
            v[j + 1] = v[j];
            j--;
        }
        v[j + 1] = x;
    }
}

__global__ void median3x3(const float2* __restrict__ src, float2* __restrict__ dst, int nbx, int nby) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= nbx || y >= nby) return;
    float vx[9], vy[9];
    int k = 0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            float2 v = src[min(max(y + dy, 0), nby - 1) * nbx + min(max(x + dx, 0), nbx - 1)];
            vx[k] = v.x;
            vy[k] = v.y;
            k++;
        }
    sort9(vx);
    sort9(vy);
    dst[y * nbx + x] = make_float2(vx[4], vy[4]);
}

// Content of this frame that has no counterpart in the other one: its best
// match is still poor, or neighbouring vectors converge on it (being covered).
__global__ void occlusion(const float2* __restrict__ v, const float* __restrict__ sad, float* __restrict__ occ,
                          int nbx, int nby, float inv_scale, float occsad) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= nbx || y >= nby) return;
    float2 l = v[y * nbx + max(x - 1, 0)], r = v[y * nbx + min(x + 1, nbx - 1)];
    float2 u = v[max(y - 1, 0) * nbx + x], d = v[min(y + 1, nby - 1) * nbx + x];
    float compress = fmaxf(l.x - r.x, 0.f) + fmaxf(u.y - d.y, 0.f);
    float bad_match = occsad > 0.f ? smoothstep(8.f * occsad, 24.f * occsad, sad[y * nbx + x]) : 0.f;
    occ[y * nbx + x] = fmaxf(fminf(compress * inv_scale, 1.f), bad_match);
}

// Over the blocks inside the active area: stats[0] = blocks over the scene
// change threshold, stats[1] = sum of mean SADs, stats[2] = block count
__global__ void scene_stats(const float* __restrict__ sad, int n, int nbx, int bs, Area la, float th,
                            float* __restrict__ stats) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float over = 0.f, sum = 0.f, active = 0.f;
    if (i < n && inside(la, (i % nbx) * bs + bs / 2, (i / nbx) * bs + bs / 2)) {
        over = sad[i] > th ? 1.f : 0.f;
        sum = sad[i];
        active = 1.f;
    }
    over = warp_sum(over);
    sum = warp_sum(sum);
    active = warp_sum(active);
    if ((threadIdx.x & 31) == 0) {
        atomicAdd(&stats[0], over);
        atomicAdd(&stats[1], sum);
        atomicAdd(&stats[2], active);
    }
}

struct FieldView {
    const float2* v;
    const float* occ;
    int nbx, nby, bs;
};

__device__ __forceinline__ void field_at(const FieldView& f, float lx, float ly, int flow, float2& v, float& occ) {
    if (!flow) {
        int bx = min(max((int)(lx / f.bs), 0), f.nbx - 1), by = min(max((int)(ly / f.bs), 0), f.nby - 1);
        v = f.v[by * f.nbx + bx];
        occ = f.occ[by * f.nbx + bx];
        return;
    }
    float gx = fminf(fmaxf(lx / f.bs - 0.5f, 0.f), (float)(f.nbx - 1));
    float gy = fminf(fmaxf(ly / f.bs - 0.5f, 0.f), (float)(f.nby - 1));
    int x0 = (int)gx, y0 = (int)gy;
    int x1 = min(x0 + 1, f.nbx - 1), y1 = min(y0 + 1, f.nby - 1);
    float ax = gx - x0, ay = gy - y0;
    float w00 = (1 - ax) * (1 - ay), w10 = ax * (1 - ay), w01 = (1 - ax) * ay, w11 = ax * ay;
    float2 a = f.v[y0 * f.nbx + x0], b = f.v[y0 * f.nbx + x1], c = f.v[y1 * f.nbx + x0], d = f.v[y1 * f.nbx + x1];
    v = make_float2(a.x * w00 + b.x * w10 + c.x * w01 + d.x * w11, a.y * w00 + b.y * w10 + c.y * w01 + d.y * w11);
    occ = f.occ[y0 * f.nbx + x0] * w00 + f.occ[y0 * f.nbx + x1] * w10 + f.occ[y1 * f.nbx + x0] * w01 +
          f.occ[y1 * f.nbx + x1] * w11;
}

__device__ __forceinline__ float occ_at(const FieldView& f, float lx, float ly) {
    float2 v;
    float o;
    field_at(f, lx, ly, 1, v, o);
    return o;
}

template <typename T>
__device__ __forceinline__ void store(T* out, int idx, float r, float scale, int maxv) {
    out[idx] = (T)min(max((int)lrintf(r * scale), 0), maxv);
}

// Scene change: the nearest real frame, or a cross-fade when blend is on
__device__ __forceinline__ float scene_pixel(const float* A, const float* B, int i, float t, int blend) {
    float a = A[i], b = B[i];
    return blend ? a + (b - a) * t : (t < 0.5f ? a : b);
}

template <typename T>
__global__ void render(const float* __restrict__ A, const float* __restrict__ B, int w, int h, int pitch, Area pa,
                       int ssx, int ssy, FieldView fwd, FieldView bwd, int flow, float t, int scene, int blend,
                       T* __restrict__ out, int opitch, float scale, int maxv) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;
    if (scene || !inside(pa, x, y)) {
        store(out, y * opitch + x, scene_pixel(A, B, y * pitch + x, t, scene ? blend : 1), scale, maxv);
        return;
    }
    // Position in luma coordinates, where the vectors live
    float lx = (x + 0.5f) * (1 << ssx) - 0.5f, ly = (y + 0.5f) * (1 << ssy) - 0.5f;
    // The fields live on the source frames' grids; look the vector up where the
    // pixel came from, not where it lands (one fixed-point step)
    float2 vf, vb;
    float of, ob;
    field_at(fwd, lx, ly, flow, vf, of);
    field_at(bwd, lx, ly, flow, vb, ob);
    field_at(fwd, lx - t * vf.x, ly - t * vf.y, flow, vf, of);
    field_at(bwd, lx - (1.f - t) * vb.x, ly - (1.f - t) * vb.y, flow, vb, ob);
    float sx = 1.f / (1 << ssx), sy = 1.f / (1 << ssy);
    float a = bilinear(A, pitch, pa, x - t * vf.x * sx, y - t * vf.y * sy);
    float b = bilinear(B, pitch, pa, x - (1.f - t) * vb.x * sx, y - (1.f - t) * vb.y * sy);
    // Content uncovered in B is missing from A, and vice versa
    float wa = (1.f - t) * (1.f - ob), wb = t * (1.f - of);
    float s = wa + wb;
    if (s < 1e-3f) {
        wa = 1.f - t;
        wb = t;
        s = 1.f;
    }
    store(out, y * opitch + x, (a * wa + b * wb) / s, scale, maxv);
}

// Adaptive mode, step 1: one warp per 8x8 tile of the output frame. A vector v
// (forward motion, A to B) fits a tile at time t if A(x - t*v) matches
// B(x + (1-t)*v) across it.
__global__ void select_vectors(const float* __restrict__ A, const float* __restrict__ B, int pitch, Area la,
                               Gain gain, FieldView fwd, FieldView bwd, float t, int ntx, int nty, float2* __restrict__ tv,
                               float* __restrict__ tcost) {
    const int lane = threadIdx.x;
    const int ti = blockIdx.x * blockDim.y + threadIdx.y;
    if (ti >= ntx * nty) return;
    const int tx = ti % ntx, ty = ti / ntx;
    const float cx = tx * kTile + kTile * 0.5f, cy = ty * kTile + kTile * 0.5f;

    float2 cand[22];
    int nc = 0;
    const int bx = min((int)(cx / fwd.bs), fwd.nbx - 1), by = min((int)(cy / fwd.bs), fwd.nby - 1);
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            int qx = min(max(bx + dx, 0), fwd.nbx - 1), qy = min(max(by + dy, 0), fwd.nby - 1);
            cand[nc++] = fwd.v[qy * fwd.nbx + qx];
            float2 b = bwd.v[qy * bwd.nbx + qx];
            cand[nc++] = make_float2(-b.x, -b.y);
        }
    // The vectors of the content that actually passes through this tile at time t
    float2 vf, vb;
    float o;
    field_at(fwd, cx, cy, 1, vf, o);
    field_at(fwd, cx - t * vf.x, cy - t * vf.y, 1, vf, o);
    field_at(bwd, cx, cy, 1, vb, o);
    field_at(bwd, cx - (1.f - t) * vb.x, cy - (1.f - t) * vb.y, 1, vb, o);
    cand[nc++] = vf;
    cand[nc++] = make_float2(-vb.x, -vb.y);
    cand[nc++] = make_float2(0.f, 0.f);
    const float2 ref = vf;

    float px[2], py[2];
    for (int k = 0; k < 2; k++) {
        int p = lane + 32 * k;
        px[k] = fminf(fmaxf(tx * kTile + p % kTile, (float)la.x0), (float)(la.x1 - 1));
        py[k] = fminf(fmaxf(ty * kTile + p / kTile, (float)la.y0), (float)(la.y1 - 1));
    }
    float best = 1e30f, best_raw = 0.f;
    float2 bestv = ref;
    for (int c = 0; c < nc; c++) {
        float2 v = cand[c];
        float s = 0.f;
        for (int k = 0; k < 2; k++)
            s += fabsf(apply(gain, bilinear(A, pitch, la, px[k] - t * v.x, py[k] - t * v.y)) -
                       bilinear(B, pitch, la, px[k] + (1.f - t) * v.x, py[k] + (1.f - t) * v.y));
        s = warp_sum(s) * (1.f / (kTile * kTile));
        // Slight preference for the smooth field, so flat areas don't pick noise
        float cost = s + 0.02f * (fabsf(v.x - ref.x) + fabsf(v.y - ref.y));
        if (cost < best) {
            best = cost;
            best_raw = s;
            bestv = v;
        }
    }
    if (lane == 0) {
        tv[ti] = bestv;
        tcost[ti] = best_raw;
    }
}

// Adaptive mode, step 2: per pixel, the best of the four surrounding tile
// vectors, so the vector changes at the object edge instead of being blended
// across it.
template <typename T>
__global__ void render_adaptive(const float* __restrict__ A, const float* __restrict__ B, int w, int h, int pitch,
                                Area pa, int ssx, int ssy, const float* __restrict__ AY, const float* __restrict__ BY,
                                int lw, int lh, Area la, Gain gain, const float2* __restrict__ tv, const float* __restrict__ tcost, int ntx,
                                int nty, FieldView fwd, FieldView bwd, float t, int scene, int blend, float mask,
                                float keep_static, T* __restrict__ out, int opitch, float scale, int maxv) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;
    if (scene || !inside(pa, x, y)) {
        store(out, y * opitch + x, scene_pixel(A, B, y * pitch + x, t, scene ? blend : 1), scale, maxv);
        return;
    }
    const float lx = (x + 0.5f) * (1 << ssx) - 0.5f, ly = (y + 0.5f) * (1 << ssy) - 0.5f;
    float gx = fminf(fmaxf(lx / kTile - 0.5f, 0.f), (float)(ntx - 1));
    float gy = fminf(fmaxf(ly / kTile - 0.5f, 0.f), (float)(nty - 1));
    int x0 = (int)gx, y0 = (int)gy;
    int x1 = min(x0 + 1, ntx - 1), y1 = min(y0 + 1, nty - 1);
    float ax = gx - x0, ay = gy - y0;
    const int idx[4] = {y0 * ntx + x0, y0 * ntx + x1, y1 * ntx + x0, y1 * ntx + x1};
    const float wt[4] = {(1 - ax) * (1 - ay), ax * (1 - ay), (1 - ax) * ay, ax * ay};

    // Symmetric match on a small cross around the pixel, in luma
    const float ox[5] = {0.f, -1.f, 1.f, 0.f, 0.f}, oy[5] = {0.f, 0.f, 0.f, -1.f, 1.f};
    float best = 1e30f, best_diff = 0.f, tile_cost = 0.f;
    float2 v = tv[idx[0]];
    for (int k = 0; k < 4; k++) {
        float2 c = tv[idx[k]];
        float s = 0.f;
        for (int j = 0; j < 5; j++) {
            float qx = lx + ox[j], qy = ly + oy[j];
            s += fabsf(apply(gain, bilinear(AY, lw, la, qx - t * c.x, qy - t * c.y)) -
                       bilinear(BY, lw, la, qx + (1.f - t) * c.x, qy + (1.f - t) * c.y));
        }
        // Distance to the tile centre breaks ties, keeping the field smooth
        float cost = s * 0.2f + 2.f * (1.f - wt[k]);
        if (cost < best) {
            best = cost;
            best_diff = s * 0.2f;
            v = c;
        }
        tile_cost += wt[k] * tcost[idx[k]];
    }
    // Static overlays (burned-in subtitles, logos): a pixel identical in both
    // frames at the same spot stays put when every moving vector tears it.
    // Where moving vectors fit too (flat or still areas) they keep priority.
    if (keep_static > 0.f && best_diff > keep_static) {
        float s = 0.f;
        for (int j = 0; j < 5; j++)
            s += fabsf(apply(gain, bilinear(AY, lw, la, lx + ox[j], ly + oy[j])) -
                       bilinear(BY, lw, la, lx + ox[j], ly + oy[j]));
        if (s * 0.2f * 3.f < best_diff) v = make_float2(0.f, 0.f);
    }

    const float sx = 1.f / (1 << ssx), sy = 1.f / (1 << ssy);
    float a = bilinear(A, pitch, pa, x - t * v.x * sx, y - t * v.y * sy);
    float b = bilinear(B, pitch, pa, x + (1.f - t) * v.x * sx, y + (1.f - t) * v.y * sy);
    // Content only A can see (poor forward match or being covered) can't come
    // from B, and the other way round
    float occ_a = occ_at(fwd, lx - t * v.x, ly - t * v.y);
    float occ_b = occ_at(bwd, lx + (1.f - t) * v.x, ly + (1.f - t) * v.y);
    float wa = (1.f - t) * (1.f - occ_b), wb = t * (1.f - occ_a);
    float s = wa + wb;
    if (s < 1e-3f) {
        wa = 1.f - t;
        wb = t;
        s = 1.f;
    }
    float r = (a * wa + b * wb) / s;
    // Artifact masking: where no vector explains the motion and it isn't an
    // occlusion, a plain blend looks better than a torn compensation
    if (mask > 0.f) {
        float bad = smoothstep(6.f, 20.f, tile_cost) * (1.f - fmaxf(occ_a, occ_b)) * fminf(mask, 1.f);
        int i = y * pitch + x;
        float st = A[i] + (B[i] - A[i]) * t;
        r += (st - r) * bad;
    }
    store(out, y * opitch + x, r, scale, maxv);
}

// ---------------------------------------------------------------------------
// Engine: GPU state for one filter instance

static dim3 grid2d(int w, int h, dim3 blk) { return dim3((w + blk.x - 1) / blk.x, (h + blk.y - 1) / blk.y); }

class Engine {
public:
    Engine(const VSVideoInfo* vi, const Params& p) : p_(p) {
        CK(cudaSetDevice(p.device));
        CK(cudaStreamCreateWithFlags(&stream_, cudaStreamNonBlocking));
        const VSVideoFormat& f = vi->format;
        bytes_ = f.bytesPerSample;
        bits_ = f.bitsPerSample;
        planes_ = f.numPlanes;
        for (int i = 0; i < planes_; i++) {
            pw_[i] = i ? vi->width >> f.subSamplingW : vi->width;
            ph_[i] = i ? vi->height >> f.subSamplingH : vi->height;
        }
        ssx_ = f.subSamplingW;
        ssy_ = f.subSamplingH;

        // Levels: keep at least 2x2 blocks at the coarsest one
        levels_ = 1;
        while (levels_ < kMaxLevels && (pw_[0] >> levels_) >= 2 * p.blksize && (ph_[0] >> levels_) >= 2 * p.blksize)
            levels_++;
        for (int l = 0; l < levels_; l++) {
            lw_[l] = std::max(pw_[0] >> l, 1);
            lh_[l] = std::max(ph_[0] >> l, 1);
            nbx_[l] = (lw_[l] + p.blksize - 1) / p.blksize;
            nby_[l] = (lh_[l] + p.blksize - 1) / p.blksize;
        }
        // Block splitting halves the block size each time, down to 8
        splits_ = 0;
        while (splits_ < std::min(p.split, kMaxSplit) && (p.blksize >> (splits_ + 1)) >= 8) splits_++;
        for (int k = 0; k < splits_; k++) {
            sbs_[k] = p.blksize >> (k + 1);
            snbx_[k] = (pw_[0] + sbs_[k] - 1) / sbs_[k];
            snby_[k] = (ph_[0] + sbs_[k] - 1) / sbs_[k];
        }
        fbs_ = splits_ ? sbs_[splits_ - 1] : p.blksize;
        fnbx_ = splits_ ? snbx_[splits_ - 1] : nbx_[0];
        fnby_ = splits_ ? snby_[splits_ - 1] : nby_[0];
        // Optical-flow hardware, if asked for and available: its 4x4 vectors become the final grid
        nvof_ = p.nvof && init_nvof();
        if (nvof_) {
            fbs_ = 4;
            fnbx_ = (pw_[0] + 3) / 4;
            fnby_ = (ph_[0] + 3) / 4;
        }
        ntx_ = (pw_[0] + kTile - 1) / kTile;
        nty_ = (ph_[0] + kTile - 1) / kTile;

        // Planes are packed back to back in the transfer buffers. Pageable
        // VapourSynth frames copy at a few GB/s; staging them through pinned
        // memory lets each frame cross the bus in one fast transfer.
        for (int i = 0; i < planes_; i++) {
            off_[i] = total_;
            total_ += (size_t)pw_[i] * ph_[i] * bytes_;
        }
        CK(cudaMalloc(&raw_, total_));
        CK(cudaMalloc(&out_, total_));
        CK(cudaHostAlloc(&host_in_, total_, cudaHostAllocDefault));
        CK(cudaHostAlloc(&host_out_, total_, cudaHostAllocDefault));
        for (auto& s : slots_) {
            for (int i = 0; i < planes_; i++) CK(cudaMalloc(&s.plane[i], sizeof(float) * pw_[i] * ph_[i]));
            if (p.prefilter)
                CK(cudaMalloc(&s.pyr[0], sizeof(float) * pw_[0] * ph_[0]));
            else
                s.pyr[0] = s.plane[0];
            for (int l = 1; l < levels_; l++) CK(cudaMalloc(&s.pyr[l], sizeof(float) * lw_[l] * lh_[l]));
            CK(cudaMalloc(&s.rmax, sizeof(float) * ph_[0]));
            CK(cudaMalloc(&s.cmax, sizeof(float) * pw_[0]));
            CK(cudaHostAlloc(&s.host_rmax, sizeof(float) * ph_[0], cudaHostAllocDefault));
            CK(cudaHostAlloc(&s.host_cmax, sizeof(float) * pw_[0], cudaHostAllocDefault));
            CK(cudaHostAlloc(&s.host_top, sizeof(float) * lw_[levels_ - 1] * lh_[levels_ - 1], cudaHostAllocDefault));
        }
        const size_t nb0 = (size_t)nbx_[0] * nby_[0];
        const size_t nbf = (size_t)fnbx_ * fnby_;
        for (auto& q : pairs_) {
            for (int d = 0; d < 2; d++) {
                for (int l = 0; l < levels_; l++) CK(cudaMalloc(&q.v[d][l], sizeof(float2) * nbx_[l] * nby_[l]));
                CK(cudaMalloc(&q.sad0[d], sizeof(float) * nb0));
                for (int k = 0; k < splits_; k++) {
                    CK(cudaMalloc(&q.fine[d][k], sizeof(float2) * snbx_[k] * snby_[k]));
                    CK(cudaMalloc(&q.finesad[d][k], sizeof(float) * snbx_[k] * snby_[k]));
                }
                CK(cudaMalloc(&q.occ[d], sizeof(float) * nbf));
                if (nvof_) {
                    CK(cudaMalloc(&q.nv[d], sizeof(float2) * nbf));
                    CK(cudaMalloc(&q.nvsad[d], sizeof(float) * nbf));
                }
            }
        }
        const int gside = 2 * kGlobalRadius + 1;
        CK(cudaMalloc(&gcost_, sizeof(float) * gside * gside));
        CK(cudaHostAlloc(&host_gcost_, sizeof(float) * gside * gside, cudaHostAllocDefault));
        CK(cudaMalloc(&tmpv_, sizeof(float2) * nb0));
        CK(cudaMalloc(&stats_, 3 * sizeof(float)));
        CK(cudaMalloc(&tv_, sizeof(float2) * ntx_ * nty_));
        CK(cudaMalloc(&tcost_, sizeof(float) * ntx_ * nty_));
    }

    ~Engine() {
        cudaSetDevice(p_.device);
        cudaStreamSynchronize(stream_);
        cudaFree(raw_);
        cudaFree(out_);
        cudaFreeHost(host_in_);
        cudaFreeHost(host_out_);
        for (auto& s : slots_) {
            for (int i = 0; i < planes_; i++) cudaFree(s.plane[i]);
            if (p_.prefilter) cudaFree(s.pyr[0]);
            for (int l = 1; l < levels_; l++) cudaFree(s.pyr[l]);
            cudaFree(s.rmax);
            cudaFree(s.cmax);
            cudaFreeHost(s.host_rmax);
            cudaFreeHost(s.host_cmax);
            cudaFreeHost(s.host_top);
        }
        for (auto& q : pairs_)
            for (int d = 0; d < 2; d++) {
                for (int l = 0; l < levels_; l++) cudaFree(q.v[d][l]);
                cudaFree(q.sad0[d]);
                for (int k = 0; k < splits_; k++) {
                    cudaFree(q.fine[d][k]);
                    cudaFree(q.finesad[d][k]);
                }
                cudaFree(q.occ[d]);
                cudaFree(q.nv[d]);
                cudaFree(q.nvsad[d]);
            }
        cudaFree(gcost_);
        cudaFreeHost(host_gcost_);
        free_nvof();
        cudaFree(tmpv_);
        cudaFree(stats_);
        cudaFree(tv_);
        cudaFree(tcost_);
        cudaStreamDestroy(stream_);
    }

    // f[i] is source frame base + i (null outside the clip); pos is the output
    // frame's position in source frames
    FrameInfo interpolate(const VSFrame* const* f, int base, int count, double pos, VSFrame* dst,
                          const VSAPI* vsapi) {
        std::lock_guard<std::mutex> lock(mutex_);
        CK(cudaSetDevice(p_.device));
        auto frame = [&](int i) -> const VSFrame* { return i >= base && i < base + count ? f[i - base] : nullptr; };
        const int k = (int)std::floor(pos);
        int ia = k, ib = k + 1;
        double tt = pos - k;
        FrameInfo info;
        if (p_.dedup) {
            // The run of identical frames around k, and whether it is short enough
            // to be a held drawing rather than a still shot
            auto dup = [&](int i) { return frame(i) && frame(i + 1) && identical(i, frame(i), frame(i + 1), vsapi); };
            int s0 = k, e0 = k;
            while (e0 - s0 + 1 < p_.holdmax && dup(s0 - 1)) s0--;
            while (e0 - s0 + 1 < p_.holdmax && dup(e0)) e0++;
            const bool still = dup(e0) || dup(s0 - 1);
            if (e0 > s0 && !still && frame(e0 + 1)) {
                ia = s0;
                ib = e0 + 1;
                tt = (pos - s0) / (ib - ia);
                info.held = ib - ia;
            }
        }
        // Film look: below full strength each real frame stays on screen for part
        // of the gap, and the motion happens in the middle of it
        if (p_.strength < 1.f) {
            const double s = std::max((double)p_.strength, 0.0);
            tt = s < 0.01 ? std::floor(tt + 0.5) : std::min(std::max((tt - (1.0 - s) / 2) / s, 0.0), 1.0);
            // Positions that land on a hold boundary (common at 24 -> 60) are real frames
            if (tt < 1e-3) tt = 0.0;
            if (tt > 1.0 - 1e-3) tt = 1.0;
        }
        if (tt <= 0.0 || tt >= 1.0 || !frame(ib)) {
            const VSFrame* src = tt >= 1.0 && frame(ib) ? frame(ib) : frame(ia);
            for (int i = 0; i < planes_; i++)
                vsh::bitblt(vsapi->getWritePtr(dst, i), vsapi->getStride(dst, i), vsapi->getReadPtr(src, i),
                            vsapi->getStride(src, i), (size_t)pw_[i] * bytes_, ph_[i]);
            info.copied = 1;
            return info;
        }
        const float t = (float)tt;
        // Upload and compute in this order so the frames and fields used
        // below are the most recently touched and can't be evicted
        Slot* P = frame(ia - 1) ? &upload(frame(ia - 1), ia - 1, vsapi) : nullptr;
        Slot& A = upload(frame(ia), ia, vsapi);
        Slot& B = upload(frame(ib), ib, vsapi);
        Slot* N = frame(ib + 1) ? &upload(frame(ib + 1), ib + 1, vsapi) : nullptr;
        float prev = P ? motion(*P, A, ia - 1, ia).score : -1.f;
        float next = N ? motion(B, *N, ib, ib + 1).score : -1.f;
        Pair& q = motion(A, B, ia, ib);

        info.score = q.score;
        const Area la = q.area;
        info.area[0] = la.x0;
        info.area[1] = la.y0;
        info.area[2] = la.x1;
        info.area[3] = la.y1;
        info.gain = q.gain.gain;
        info.nvof = nvof_;
        info.scene = q.over_threshold;
        const float neighbours = std::max(prev, next);
        // Floors keep noise in near-static footage (errors ~0.1) from counting as a spike
        if (p_.scratio > 0.f && neighbours >= 0.f && q.score > 1.5f && q.score > p_.scratio * std::max(neighbours, 0.25f))
            info.scene = 1;

        const dim3 blk(32, 8);
        const float scale = (float)(1 << (bits_ - 8));
        const int maxv = (1 << bits_) - 1;
        FieldView fwd{field(q, 0), q.occ[0], fnbx_, fnby_, fbs_};
        FieldView bwd{field(q, 1), q.occ[1], fnbx_, fnby_, fbs_};
        const bool adaptive = p_.mode == 2 && !info.scene;
        // Mismatch (8-bit) the best moving vector must leave before a pixel may
        // stay still; higher static setting = lower bar
        const float keep_static = p_.statics > 0.f ? 6.f / p_.statics : 0.f;
        if (adaptive) {
            const int nt = ntx_ * nty_;
            const dim3 tblk(32, 4);
            select_vectors<<<(nt + tblk.y - 1) / tblk.y, tblk, 0, stream_>>>(
                A.pyr[0], B.pyr[0], pw_[0], la, q.gain, fwd, bwd, t, ntx_, nty_, tv_, tcost_);
            CK(cudaGetLastError());
        }
        for (int i = 0; i < planes_; i++) {
            int sx = i ? ssx_ : 0, sy = i ? ssy_ : 0;
            void* o = (uint8_t*)out_ + off_[i];
            const Area pa = plane_area(la, i);
            if (p_.mode == 2) {
                if (bytes_ == 1)
                    render_adaptive<uint8_t><<<grid2d(pw_[i], ph_[i], blk), blk, 0, stream_>>>(
                        A.plane[i], B.plane[i], pw_[i], ph_[i], pw_[i], pa, sx, sy, A.pyr[0], B.pyr[0], pw_[0],
                        ph_[0], la, q.gain, tv_, tcost_, ntx_, nty_, fwd, bwd, t, info.scene, p_.blend, p_.mask, keep_static, (uint8_t*)o,
                        pw_[i], scale, maxv);
                else
                    render_adaptive<uint16_t><<<grid2d(pw_[i], ph_[i], blk), blk, 0, stream_>>>(
                        A.plane[i], B.plane[i], pw_[i], ph_[i], pw_[i], pa, sx, sy, A.pyr[0], B.pyr[0], pw_[0],
                        ph_[0], la, q.gain, tv_, tcost_, ntx_, nty_, fwd, bwd, t, info.scene, p_.blend, p_.mask, keep_static, (uint16_t*)o,
                        pw_[i], scale, maxv);
            } else {
                if (bytes_ == 1)
                    render<uint8_t><<<grid2d(pw_[i], ph_[i], blk), blk, 0, stream_>>>(
                        A.plane[i], B.plane[i], pw_[i], ph_[i], pw_[i], pa, sx, sy, fwd, bwd, p_.mode, t, info.scene,
                        p_.blend, (uint8_t*)o, pw_[i], scale, maxv);
                else
                    render<uint16_t><<<grid2d(pw_[i], ph_[i], blk), blk, 0, stream_>>>(
                        A.plane[i], B.plane[i], pw_[i], ph_[i], pw_[i], pa, sx, sy, fwd, bwd, p_.mode, t, info.scene,
                        p_.blend, (uint16_t*)o, pw_[i], scale, maxv);
            }
            CK(cudaGetLastError());
        }
        CK(cudaMemcpyAsync(host_out_, out_, total_, cudaMemcpyDeviceToHost, stream_));
        CK(cudaStreamSynchronize(stream_));
        for (int i = 0; i < planes_; i++)
            vsh::bitblt(vsapi->getWritePtr(dst, i), vsapi->getStride(dst, i), host_out_ + off_[i],
                        (ptrdiff_t)pw_[i] * bytes_, (size_t)pw_[i] * bytes_, ph_[i]);
        return info;
    }

private:
    struct Slot {
        int idx = -1;
        uint64_t used = 0;
        float* plane[3] = {};
        float* pyr[kMaxLevels] = {};  // matching pyramid; level 0 is plane[0] or its blurred copy
        float* rmax = nullptr;  // brightest luma per row / column, device
        float* cmax = nullptr;
        float* host_rmax = nullptr;  // pinned copies, valid after the stream syncs
        float* host_cmax = nullptr;
        float* host_top = nullptr;   // coarsest pyramid level, for the mean brightness
    };
    struct Pair {
        int a = -1, b = -1;  // source frames
        uint64_t used = 0;
        float2* v[2][kMaxLevels] = {};     // pyramid vectors, [0] forward A->B, [1] backward B->A
        float* sad0[2] = {};               // full-resolution match error per block
        float2* fine[2][kMaxSplit] = {};   // after each block split
        float* finesad[2][kMaxSplit] = {};
        float* occ[2] = {};                // on the finest grid
        float2* nv[2] = {};                // from the optical-flow hardware (nvof)
        float* nvsad[2] = {};
        const float2* final_v(int d, int splits) const { return splits ? fine[d][splits - 1] : v[d][0]; }
        const float* final_sad(int d, int splits) const { return splits ? finesad[d][splits - 1] : sad0[d]; }
        Area area = {};          // active picture (letterbox bars excluded)
        Gain gain = {1.f, 0.f};  // A's brightness mapped onto B's
        int over_threshold = 0;  // thscd1/thscd2 scene change test
        float score = 0.f;       // mean forward match error
    };

    Slot& upload(const VSFrame* f, int idx, const VSAPI* vsapi) {
        tick_++;
        for (auto& s : slots_)
            if (s.idx == idx) {
                s.used = tick_;
                return s;
            }
        Slot& s = *std::min_element(slots_, slots_ + kSlots, [](const Slot& a, const Slot& b) { return a.used < b.used; });
        s.idx = idx;
        s.used = tick_;

        const dim3 blk(32, 8);
        const float scale = 1.f / (1 << (bits_ - 8));
        // host_in_ may still be feeding the previous upload
        CK(cudaStreamSynchronize(stream_));
        for (int i = 0; i < planes_; i++)
            vsh::bitblt(host_in_ + off_[i], (ptrdiff_t)pw_[i] * bytes_, vsapi->getReadPtr(f, i), vsapi->getStride(f, i),
                        (size_t)pw_[i] * bytes_, ph_[i]);
        CK(cudaMemcpyAsync(raw_, host_in_, total_, cudaMemcpyHostToDevice, stream_));
        for (int i = 0; i < planes_; i++) {
            const void* r = (const uint8_t*)raw_ + off_[i];
            if (bytes_ == 1)
                to_float<uint8_t><<<grid2d(pw_[i], ph_[i], blk), blk, 0, stream_>>>(
                    (const uint8_t*)r, pw_[i], ph_[i], pw_[i], s.plane[i], pw_[i], scale);
            else
                to_float<uint16_t><<<grid2d(pw_[i], ph_[i], blk), blk, 0, stream_>>>(
                    (const uint16_t*)r, pw_[i], ph_[i], pw_[i], s.plane[i], pw_[i], scale);
            CK(cudaGetLastError());
        }
        if (p_.prefilter) {
            blur<<<grid2d(pw_[0], ph_[0], blk), blk, 0, stream_>>>(s.plane[0], s.pyr[0], pw_[0], ph_[0], pw_[0],
                                                                  p_.prefilter);
            CK(cudaGetLastError());
        }
        for (int l = 1; l < levels_; l++) {
            downscale2<<<grid2d(lw_[l], lh_[l], blk), blk, 0, stream_>>>(s.pyr[l - 1], lw_[l - 1], lh_[l - 1],
                                                                        lw_[l - 1], s.pyr[l], lw_[l], lh_[l], lw_[l]);
            CK(cudaGetLastError());
        }
        if (p_.fades) {
            const int top = levels_ - 1;
            CK(cudaMemcpyAsync(s.host_top, s.pyr[top], sizeof(float) * lw_[top] * lh_[top], cudaMemcpyDeviceToHost,
                               stream_));
        }
        if (p_.bars) {
            row_max<<<ph_[0], 256, 0, stream_>>>(s.plane[0], pw_[0], pw_[0], s.rmax);
            col_max<<<(pw_[0] + 255) / 256, 256, 0, stream_>>>(s.plane[0], pw_[0], ph_[0], pw_[0], s.cmax);
            CK(cudaGetLastError());
            CK(cudaMemcpyAsync(s.host_rmax, s.rmax, sizeof(float) * ph_[0], cudaMemcpyDeviceToHost, stream_));
            CK(cudaMemcpyAsync(s.host_cmax, s.cmax, sizeof(float) * pw_[0], cudaMemcpyDeviceToHost, stream_));
        }
        return s;
    }

    // Letterbox bars of one pair: rows and columns from each edge whose brightest
    // pixel stays under barsth in both frames. Call after the stream has synced.
    Area raw_area(const Slot& A, const Slot& B) const {
        const int w = pw_[0], h = ph_[0];
        const Area full{0, 0, w, h};
        auto dark_row = [&](int y) { return std::max(A.host_rmax[y], B.host_rmax[y]) <= p_.barsth; };
        auto dark_col = [&](int x) { return std::max(A.host_cmax[x], B.host_cmax[x]) <= p_.barsth; };
        int y0 = 0, y1 = h, x0 = 0, x1 = w;
        while (y0 < h && dark_row(y0)) y0++;
        while (y1 > y0 && dark_row(y1 - 1)) y1--;
        while (x0 < w && dark_col(x0)) x0++;
        while (x1 > x0 && dark_col(x1 - 1)) x1--;
        // A dark scene or a fade to black isn't letterboxed
        if (y1 - y0 < h * 2 / 5 || x1 - x0 < w * 2 / 5) return full;
        // Bars come in matching pairs; dark scenery at one edge doesn't
        auto pair = [](int& lo, int& hi, int size) {
            const int a = lo, b = size - hi;
            if (a < 4 || b < 4 || std::abs(a - b) > std::max(8, size / 50)) {
                lo = 0;
                hi = size;
            }
        };
        pair(y0, y1, h);
        pair(x0, x1, w);
        // Align to the chroma grid
        const int mx = 1 << ssx_, my = 1 << ssy_;
        x0 = x0 / mx * mx;
        y0 = y0 / my * my;
        x1 = std::min((x1 + mx - 1) / mx * mx, w);
        y1 = std::min((y1 + my - 1) / my * my, h);
        return {x0, y0, x1, y1};
    }

    // Bars in use: new ones only after they have held for a while, but content
    // showing up inside the current ones widens the area at once
    Area detect_area(const Slot& A, const Slot& B) {
        if (!p_.bars) return {0, 0, pw_[0], ph_[0]};
        if (!stable_.x1) stable_ = {0, 0, pw_[0], ph_[0]};
        const Area raw = raw_area(A, B);
        auto same = [](const Area& a, const Area& b) {
            return a.x0 == b.x0 && a.y0 == b.y0 && a.x1 == b.x1 && a.y1 == b.y1;
        };
        if (raw.x0 < stable_.x0 || raw.y0 < stable_.y0 || raw.x1 > stable_.x1 || raw.y1 > stable_.y1) {
            stable_ = {std::min(raw.x0, stable_.x0), std::min(raw.y0, stable_.y0), std::max(raw.x1, stable_.x1),
                       std::max(raw.y1, stable_.y1)};
            candidate_count_ = 0;
        } else if (same(raw, candidate_)) {
            if (++candidate_count_ >= kBarsHold) stable_ = raw;
        } else {
            candidate_ = raw;
            candidate_count_ = 1;
        }
        return stable_;
    }

    // Mean brightness over the active area, from the coarsest pyramid level.
    // Call after the stream has synced.
    float mean_brightness(const Slot& s, const Area& a) const {
        const int top = levels_ - 1;
        const Area t = level_area(a, top, lw_[top], lh_[top]);
        double sum = 0;
        int n = 0;
        for (int y = t.y0; y < t.y1; y++)
            for (int x = t.x0; x < t.x1; x++) {
                sum += s.host_top[y * lw_[top] + x];
                n++;
            }
        return n ? (float)(sum / n) : 0.f;
    }

    // Maps A's brightness onto B's: scaling around black, the way fades work
    Gain fade_gain(const Slot& A, const Slot& B, const Area& a) const {
        if (!p_.fades) return {1.f, 0.f};
        const float black = 16.f;
        const float ma = mean_brightness(A, a) - black, mb = mean_brightness(B, a) - black;
        if (ma < 2.f || mb < 2.f) return {1.f, 0.f};
        const float g = std::min(std::max(mb / ma, 0.5f), 2.f);
        if (std::fabs(g - 1.f) < 0.02f) return {1.f, 0.f};
        return {g, black * (1.f - g)};
    }

    static Gain inverse(const Gain& g) { return {1.f / g.gain, -g.offset / g.gain}; }

    static Area level_area(const Area& a, int l, int lw, int lh) {
        const int m = (1 << l) - 1;
        return {a.x0 >> l, a.y0 >> l, std::min((a.x1 + m) >> l, lw), std::min((a.y1 + m) >> l, lh)};
    }

    Area plane_area(const Area& a, int i) const {
        if (!i) return a;
        return level_area_xy(a, ssx_, ssy_, pw_[i], ph_[i]);
    }

    static Area level_area_xy(const Area& a, int sx, int sy, int w, int h) {
        return {a.x0 >> sx, a.y0 >> sy, std::min((a.x1 + (1 << sx) - 1) >> sx, w),
                std::min((a.y1 + (1 << sy) - 1) >> sy, h)};
    }

    // Direction d of pair q: d = 0 searches A's blocks in B, d = 1 the reverse.
    // prev is the previous pair (temporal candidates), if it is cached.
    void search(const Slot& cur, const Slot& ref, Pair& q, int d, const Pair* prev) {
        const dim3 blk(32, 4);
        const Gain gain = d ? inverse(q.gain) : q.gain;  // cur's brightness onto ref's
        const int top = levels_ - 1;
        // Camera motion at the coarsest level, before any block search
        const float2 global = p_.gmv && top > 0 ? camera_motion(cur, ref, level_area(q.area, top, lw_[top], lh_[top]),
                                                                gain)
                                                : make_float2(0.f, 0.f);
        for (int l = top; l >= 0; l--) {
            const int nb = nbx_[l] * nby_[l];
            const dim3 grid((nb + blk.y - 1) / blk.y);
            const float2* parent = l == top ? nullptr : q.v[d][l + 1];
            const int pnbx = l == top ? 0 : nbx_[l + 1], pnby = l == top ? 0 : nby_[l + 1];
            const float2* prior = p_.temporal && prev ? prev->v[d][l] : nullptr;
            const float gs = (float)(1 << (top - l));
            const float2 g = make_float2(global.x * gs, global.y * gs);
            float2* out = (l == 0 && p_.smooth) ? tmpv_ : q.v[d][l];
            float* lsad = l == 0 ? q.sad0[d] : nullptr;
            const int halfpel = l == 0 && p_.pel > 1;
            launch(p_.blksize, grid, blk, cur.pyr[l], ref.pyr[l], lw_[l], level_area(q.area, l, lw_[l], lh_[l]),
                   nbx_[l], nby_[l], parent, nullptr,
                   pnbx, pnby, 2.f, 0.f, prior, g, p_.gmv && top > 0, p_.radius, p_.refine, halfpel, gain, out,
                   lsad);
        }
        if (p_.smooth) {
            const dim3 mblk(16, 16);
            median3x3<<<grid2d(nbx_[0], nby_[0], mblk), mblk, 0, stream_>>>(tmpv_, q.v[d][0], nbx_[0], nby_[0]);
            CK(cudaGetLastError());
        }
        // Block splitting: blocks that still match badly are searched again as four halves
        const float2 g0 = make_float2(global.x * (1 << top), global.y * (1 << top));
        const float gate = p_.thsad / 64.f;  // thsad is an 8x8 block SAD; the sad maps hold per-pixel means
        for (int k = 0; k < splits_; k++) {
            const int nb = snbx_[k] * snby_[k];
            const dim3 grid((nb + blk.y - 1) / blk.y);
            const float2* parent = k ? q.fine[d][k - 1] : q.v[d][0];
            const float* psad = k ? q.finesad[d][k - 1] : q.sad0[d];
            const int pnbx = k ? snbx_[k - 1] : nbx_[0], pnby = k ? snby_[k - 1] : nby_[0];
            launch(sbs_[k], grid, blk, cur.pyr[0], ref.pyr[0], lw_[0], q.area, snbx_[k], snby_[k], parent, psad,
                   pnbx, pnby, 1.f, gate, nullptr, g0, p_.gmv, p_.radius, p_.refine, p_.pel > 1, gain, q.fine[d][k],
                   q.finesad[d][k]);
        }
    }

    void launch(int bs, dim3 grid, dim3 blk, const float* cur, const float* ref, int pitch, Area ar, int nbx, int nby,
                const float2* parent, const float* psad, int pnbx, int pnby, float pscale, float gate,
                const float2* prior, float2 global, int use_global, int radius, int refine, int halfpel,
                Gain gain, float2* out, float* sad) {
#define LAUNCH(BS)                                                                                            \
    motion_search<BS><<<grid, blk, 0, stream_>>>(cur, ref, ar, pitch, nbx, nby, parent, psad, pnbx, pnby, pscale, \
                                                 gate, prior, global, use_global, radius, refine, p_.lambda,   \
                                                 p_.lambdaflat, p_.texref,                                     \
                                                 halfpel, gain, out, sad)
        if (bs == 8)
            LAUNCH(8);
        else if (bs == 16)
            LAUNCH(16);
        else
            LAUNCH(32);
#undef LAUNCH
        CK(cudaGetLastError());
    }

    // Camera motion estimate: the best whole-frame shift at the coarsest level,
    // up to a quarter of the frame width either way
    float2 camera_motion(const Slot& cur, const Slot& ref, const Area& ar, const Gain& gain) {
        const int top = levels_ - 1;
        const int radius = std::min(kGlobalRadius, std::max(8, lw_[top] / 4)), side = 2 * radius + 1;
        global_search<<<side * side, 256, 0, stream_>>>(cur.pyr[top], ref.pyr[top], lw_[top], ar, radius, gain,
                                                        gcost_);
        CK(cudaGetLastError());
        CK(cudaMemcpyAsync(host_gcost_, gcost_, sizeof(float) * side * side, cudaMemcpyDeviceToHost, stream_));
        CK(cudaStreamSynchronize(stream_));
        int best = side * side / 2;  // zero shift
        float best_cost = host_gcost_[best];
        for (int i = 0; i < side * side; i++) {
            const int dx = i % side - radius, dy = i / side - radius;
            // A small preference for shorter shifts settles near-ties (flat frames)
            const float c = host_gcost_[i] + 0.02f * (std::abs(dx) + std::abs(dy));
            if (c < best_cost) {
                best_cost = c;
                best = i;
            }
        }
        // Scaled to the coarsest level's units: search() scales it per level
        return make_float2((float)(best % side - radius), (float)(best / side - radius));
    }

    const float2* field(const Pair& q, int d) const { return nvof_ ? q.nv[d] : q.final_v(d, splits_); }
    const float* field_sad(const Pair& q, int d) const { return nvof_ ? q.nvsad[d] : q.final_sad(d, splits_); }

    // Optical-flow hardware: one session per direction, so each keeps using
    // its previous result as hints for the next pair
    bool init_nvof() {
        of_lib_ = LoadLibraryA("nvofapi64.dll");
        if (!of_lib_) return false;
        typedef NV_OF_STATUS(NVOFAPI * Create)(uint32_t, NV_OF_CUDA_API_FUNCTION_LIST*);
        auto create = (Create)GetProcAddress(of_lib_, "NvOFAPICreateInstanceCuda");
        if (!create || create(NV_OF_API_VERSION, &of_) != NV_OF_SUCCESS) return false;
        CK(cudaFree(0));  // make sure the runtime's context exists
        CUcontext ctx = nullptr;
        if (cuCtxGetCurrent(&ctx) != CUDA_SUCCESS || !ctx) return false;
        const NV_OF_PERF_LEVEL perf[4] = {NV_OF_PERF_LEVEL_FAST, NV_OF_PERF_LEVEL_FAST, NV_OF_PERF_LEVEL_MEDIUM,
                                          NV_OF_PERF_LEVEL_SLOW};
        NV_OF_INIT_PARAMS init = {};
        init.width = pw_[0];
        init.height = ph_[0];
        init.outGridSize = NV_OF_OUTPUT_VECTOR_GRID_SIZE_4;
        init.mode = NV_OF_MODE_OPTICALFLOW;
        init.perfLevel = perf[p_.nvof];
        NV_OF_BUFFER_DESCRIPTOR in = {(uint32_t)pw_[0], (uint32_t)ph_[0], NV_OF_BUFFER_USAGE_INPUT,
                                      NV_OF_BUFFER_FORMAT_GRAYSCALE8};
        NV_OF_BUFFER_DESCRIPTOR out = {(uint32_t)(pw_[0] + 3) / 4, (uint32_t)(ph_[0] + 3) / 4, NV_OF_BUFFER_USAGE_OUTPUT,
                                       NV_OF_BUFFER_FORMAT_SHORT2};
        for (int d = 0; d < 2; d++) {
            if (of_.nvCreateOpticalFlowCuda(ctx, &of_h_[d]) != NV_OF_SUCCESS) return false;
            if (of_.nvOFInit(of_h_[d], &init) != NV_OF_SUCCESS) return false;
            for (int k = 0; k < 2; k++)
                if (of_.nvOFCreateGPUBufferCuda(of_h_[d], &in, NV_OF_CUDA_BUFFER_TYPE_CUDEVICEPTR, &of_in_[d][k]) !=
                    NV_OF_SUCCESS)
                    return false;
            if (of_.nvOFCreateGPUBufferCuda(of_h_[d], &out, NV_OF_CUDA_BUFFER_TYPE_CUDEVICEPTR, &of_out_[d]) !=
                NV_OF_SUCCESS)
                return false;
            // The hardware works on the default stream; keep it in order with ours
            of_.nvOFSetIOCudaStreams(of_h_[d], (CUstream)stream_, (CUstream)stream_);
        }
        NV_OF_CUDA_BUFFER_STRIDE_INFO si = {};
        of_.nvOFGPUBufferGetStrideInfo(of_in_[0][0], &si);
        of_in_pitch_ = si.strideInfo[0].strideXInBytes;
        of_.nvOFGPUBufferGetStrideInfo(of_out_[0], &si);
        of_out_pitch_ = si.strideInfo[0].strideXInBytes / sizeof(NV_OF_FLOW_VECTOR);
        return true;
    }

    void free_nvof() {
        for (int d = 0; d < 2; d++) {
            if (!of_h_[d]) continue;
            for (int k = 0; k < 2; k++)
                if (of_in_[d][k]) of_.nvOFDestroyGPUBufferCuda(of_in_[d][k]);
            if (of_out_[d]) of_.nvOFDestroyGPUBufferCuda(of_out_[d]);
            of_.nvOFDestroy(of_h_[d]);
        }
        if (of_lib_) FreeLibrary(of_lib_);
    }

    // Direction d of pair q from the hardware: d = 0 matches A's pixels in B
    void nvof_flow(const Slot& cur, const Slot& ref, Pair& q, int d) {
        const dim3 blk(32, 8);
        const Gain gain = d ? inverse(q.gain) : q.gain;
        to_u8<<<grid2d(pw_[0], ph_[0], blk), blk, 0, stream_>>>(
            cur.pyr[0], pw_[0], ph_[0], pw_[0], gain, (uint8_t*)of_.nvOFGPUBufferGetCUdeviceptr(of_in_[d][0]),
            (int)of_in_pitch_);
        to_u8<<<grid2d(pw_[0], ph_[0], blk), blk, 0, stream_>>>(
            ref.pyr[0], pw_[0], ph_[0], pw_[0], Gain{1.f, 0.f}, (uint8_t*)of_.nvOFGPUBufferGetCUdeviceptr(of_in_[d][1]),
            (int)of_in_pitch_);
        CK(cudaGetLastError());
        NV_OF_EXECUTE_INPUT_PARAMS ein = {};
        ein.inputFrame = of_in_[d][0];
        ein.referenceFrame = of_in_[d][1];
        NV_OF_EXECUTE_OUTPUT_PARAMS eout = {};
        eout.outputBuffer = of_out_[d];
        if (of_.nvOFExecute(of_h_[d], &ein, &eout) != NV_OF_SUCCESS) throw std::runtime_error("optical flow failed");
        const dim3 fblk(16, 16);
        flow_to_field<<<grid2d(fnbx_, fnby_, fblk), fblk, 0, stream_>>>(
            (const NV_OF_FLOW_VECTOR*)of_.nvOFGPUBufferGetCUdeviceptr(of_out_[d]), (int)of_out_pitch_, fnbx_, fnby_,
            q.nv[d]);
        block_sad<<<grid2d(fnbx_, fnby_, fblk), fblk, 0, stream_>>>(cur.pyr[0], ref.pyr[0], pw_[0], q.area, q.nv[d], fnbx_,
                                                                    fnby_, fbs_, gain, q.nvsad[d]);
        CK(cudaGetLastError());
    }

    // Frames i and i+1 are the same picture: mean difference at quarter
    // resolution (grain and compression noise averaged out) under dupth
    bool identical(int i, const VSFrame* fa, const VSFrame* fb, const VSAPI* vsapi) {
        auto it = identical_.find(i);
        if (it != identical_.end()) return it->second;
        const int l = std::min(2, levels_ - 1), n = lw_[l] * lh_[l];
        const Slot& A = upload(fa, i, vsapi);
        const Slot& B = upload(fb, i + 1, vsapi);
        CK(cudaMemsetAsync(stats_, 0, sizeof(float), stream_));
        frame_diff<<<(n + 255) / 256, 256, 0, stream_>>>(A.pyr[l], B.pyr[l], n, stats_);
        CK(cudaGetLastError());
        float sum = 0.f;
        CK(cudaMemcpyAsync(&sum, stats_, sizeof(float), cudaMemcpyDeviceToHost, stream_));
        CK(cudaStreamSynchronize(stream_));
        const bool same = sum / n < p_.dupth;
        if (identical_.size() > 64) identical_.erase(identical_.begin());
        identical_[i] = same;
        return same;
    }

    Pair& motion(const Slot& A, const Slot& B, int a, int b) {
        tick_++;
        for (auto& q : pairs_)
            if (q.a == a && q.b == b) {
                q.used = tick_;
                return q;
            }
        Pair& q = *std::min_element(pairs_, pairs_ + kPairs, [](const Pair& x, const Pair& y) { return x.used < y.used; });
        q.a = a;
        q.b = b;
        q.used = tick_;
        // Temporal candidates come from the pair that ends where this one starts
        const Pair* prev = nullptr;
        for (auto& o : pairs_)
            if (&o != &q && o.b == a) prev = &o;
        if (p_.bars || p_.fades) CK(cudaStreamSynchronize(stream_));  // per-frame statistics of A and B
        q.area = detect_area(A, B);
        q.gain = fade_gain(A, B, q.area);

        if (nvof_) {
            nvof_flow(A, B, q, 0);
            nvof_flow(B, A, q, 1);
        } else {
            search(A, B, q, 0, prev);
            search(B, A, q, 1, prev);
        }

        // Scene statistics over the grid the vectors came from
        const float* ssad = nvof_ ? q.nvsad[0] : q.sad0[0];
        const int snbx = nvof_ ? fnbx_ : nbx_[0], sbs = nvof_ ? fbs_ : p_.blksize;
        const int nb = nvof_ ? fnbx_ * fnby_ : nbx_[0] * nby_[0];
        const float th = p_.thscd1 / 64.f;  // thscd1 is an 8x8 block SAD; sad holds per-pixel means
        CK(cudaMemsetAsync(stats_, 0, 3 * sizeof(float), stream_));
        scene_stats<<<(nb + 255) / 256, 256, 0, stream_>>>(ssad, nb, snbx, sbs, q.area, th, stats_);
        CK(cudaGetLastError());

        const dim3 blk(16, 16);
        const float inv_scale = 1.f / std::max(p_.ml * 0.16f, 1e-3f);  // ml=100: 16 px of convergence = fully occluded
        for (int d = 0; d < 2; d++) {
            occlusion<<<grid2d(fnbx_, fnby_, blk), blk, 0, stream_>>>(field(q, d), field_sad(q, d), q.occ[d], fnbx_,
                                                                     fnby_, inv_scale, p_.occsad);
            CK(cudaGetLastError());
        }
        float stats[3] = {};
        CK(cudaMemcpyAsync(stats, stats_, sizeof(stats), cudaMemcpyDeviceToHost, stream_));
        CK(cudaStreamSynchronize(stream_));
        const float active = std::max(stats[2], 1.f);
        q.over_threshold = (double)stats[0] * 255 > (double)p_.thscd2 * active;
        q.score = stats[1] / active;
        return q;
    }

    Params p_;
    cudaStream_t stream_ = nullptr;
    std::mutex mutex_;
    int bytes_ = 1, bits_ = 8, planes_ = 1, ssx_ = 0, ssy_ = 0;
    int pw_[3] = {}, ph_[3] = {};
    int levels_ = 1;
    int lw_[kMaxLevels] = {}, lh_[kMaxLevels] = {}, nbx_[kMaxLevels] = {}, nby_[kMaxLevels] = {};
    int ntx_ = 0, nty_ = 0;
    int splits_ = 0, sbs_[kMaxSplit] = {}, snbx_[kMaxSplit] = {}, snby_[kMaxSplit] = {};
    int fbs_ = 16, fnbx_ = 0, fnby_ = 0;  // finest vector grid
    bool nvof_ = false;            // optical-flow hardware in use
    HMODULE of_lib_ = nullptr;
    NV_OF_CUDA_API_FUNCTION_LIST of_ = {};
    NvOFHandle of_h_[2] = {};
    NvOFGPUBufferHandle of_in_[2][2] = {}, of_out_[2] = {};
    uint32_t of_in_pitch_ = 0, of_out_pitch_ = 0;
    float* gcost_ = nullptr;       // camera motion search costs, device and pinned host
    float* host_gcost_ = nullptr;
    Area stable_ = {}, candidate_ = {};  // letterbox bars in use, and the ones waiting to be confirmed
    int candidate_count_ = 0;
    size_t off_[3] = {}, total_ = 0;
    void* raw_ = nullptr;
    void* out_ = nullptr;
    uint8_t* host_in_ = nullptr;
    uint8_t* host_out_ = nullptr;
    float2* tmpv_ = nullptr;
    float* stats_ = nullptr;
    float2* tv_ = nullptr;
    float* tcost_ = nullptr;
    Slot slots_[kSlots];
    Pair pairs_[kPairs];
    std::map<int, bool> identical_;  // held-frame test results by first frame
    uint64_t tick_ = 0;
};

// ---------------------------------------------------------------------------
// VapourSynth filter

struct FilterData {
    VSNode* node = nullptr;
    const VSVideoInfo* vi_in = nullptr;
    VSVideoInfo vi = {};
    int64_t src_num = 0, src_den = 1;  // source fps
    int dedup = 0, holdmax = 3;
    std::unique_ptr<Engine> engine;
};

static void set_props(VSFrame* f, const FilterData* d, const FrameInfo* info, const VSAPI* vsapi) {
    VSMap* props = vsapi->getFramePropertiesRW(f);
    vsapi->mapSetInt(props, "_DurationNum", d->vi.fpsDen, maReplace);
    vsapi->mapSetInt(props, "_DurationDen", d->vi.fpsNum, maReplace);
    if (info) {
        vsapi->mapSetInt(props, "GpumvScene", info->scene, maReplace);
        vsapi->mapSetFloat(props, "GpumvScore", info->score, maReplace);
        const int64_t area[4] = {info->area[0], info->area[1], info->area[2], info->area[3]};
        vsapi->mapSetIntArray(props, "GpumvArea", area, 4);
        vsapi->mapSetFloat(props, "GpumvGain", info->gain, maReplace);
        vsapi->mapSetInt(props, "GpumvHeld", info->held, maReplace);
        vsapi->mapSetInt(props, "GpumvNvof", info->nvof, maReplace);
    }
}

static const VSFrame* VS_CC interp_get_frame(int n, int reason, void* instance, void**, VSFrameContext* ctx,
                                             VSCore* core, const VSAPI* vsapi) {
    auto* d = static_cast<FilterData*>(instance);
    // Output frame n sits at source position n * src_fps / dst_fps
    const int64_t num = (int64_t)n * d->src_num * d->vi.fpsDen;
    const int64_t den = d->src_den * d->vi.fpsNum;
    const int last = d->vi_in->numFrames - 1;
    const int k = (int)std::min<int64_t>(num / den, last);
    const int64_t rem = k == last ? 0 : num % den;
    const bool dedup = d->dedup;
    // Frames around the position: the pair and its neighbours for the scene
    // change test, plus the held-frame runs on either side
    const int reach = dedup ? d->holdmax + 1 : 1;
    const int base = std::max(0, k - reach), end = std::min(last, k + reach + 1);

    if (reason == arInitial) {
        if (!rem && !dedup) {
            vsapi->requestFrameFilter(k, d->node, ctx);
            return nullptr;
        }
        for (int i = base; i <= end; i++) vsapi->requestFrameFilter(i, d->node, ctx);
        return nullptr;
    }
    if (reason != arAllFramesReady) return nullptr;

    if (!rem && !dedup) {
        const VSFrame* fa = vsapi->getFrameFilter(k, d->node, ctx);
        VSFrame* dst = vsapi->copyFrame(fa, core);
        vsapi->freeFrame(fa);
        set_props(dst, d, nullptr, vsapi);
        return dst;
    }
    const VSFrame* f[16] = {};
    const int count = end - base + 1;
    for (int i = 0; i < count; i++) f[i] = vsapi->getFrameFilter(base + i, d->node, ctx);
    auto release = [&] {
        for (int i = 0; i < count; i++) vsapi->freeFrame(f[i]);
    };
    VSFrame* dst = vsapi->newVideoFrame(&d->vi.format, d->vi.width, d->vi.height, f[k - base], core);
    FrameInfo info;
    try {
        info = d->engine->interpolate(f, base, count, k + (double)rem / den, dst, vsapi);
    } catch (const std::exception& e) {
        release();
        vsapi->freeFrame(dst);
        vsapi->setFilterError((std::string("gpumv.Interpolate: ") + e.what()).c_str(), ctx);
        return nullptr;
    }
    release();
    set_props(dst, d, info.copied ? nullptr : &info, vsapi);
    return dst;
}

static void VS_CC interp_free(void* instance, VSCore*, const VSAPI* vsapi) {
    auto* d = static_cast<FilterData*>(instance);
    vsapi->freeNode(d->node);
    delete d;
}

static void VS_CC interp_create(const VSMap* in, VSMap* out, void*, VSCore* core, const VSAPI* vsapi) {
    auto d = std::make_unique<FilterData>();
    auto fail = [&](const std::string& msg) {
        vsapi->mapSetError(out, ("Interpolate: " + msg).c_str());
        if (d->node) vsapi->freeNode(d->node);
    };
    int err = 0;
    d->node = vsapi->mapGetNode(in, "clip", 0, nullptr);
    d->vi_in = vsapi->getVideoInfo(d->node);
    const VSVideoInfo* vi = d->vi_in;
    const VSVideoFormat& f = vi->format;

    if (!vsh::isConstantVideoFormat(vi)) return fail("clip must have constant format and dimensions");
    if ((f.colorFamily != cfYUV && f.colorFamily != cfGray) || f.sampleType != stInteger || f.bitsPerSample > 16)
        return fail("clip must be 8-16 bit integer YUV or Gray");
    if (vi->fpsNum <= 0 || vi->fpsDen <= 0) return fail("clip must have a known frame rate (use std.AssumeFPS)");

    Params p;
    auto geti = [&](const char* key, int def) {
        int v = vsapi->mapGetIntSaturated(in, key, 0, &err);
        return err ? def : v;
    };
    auto getf = [&](const char* key, float def) {
        double v = vsapi->mapGetFloat(in, key, 0, &err);
        return err ? def : (float)v;
    };
    int64_t num = vsapi->mapGetInt(in, "num", 0, nullptr);
    int64_t den = vsapi->mapGetInt(in, "den", 0, &err);
    if (err) den = 1;
    if (num <= 0 || den <= 0) return fail("num and den must be positive");
    p.mode = geti("mode", p.mode);
    p.blksize = geti("blksize", p.blksize);
    p.pel = geti("pel", p.pel);
    p.radius = geti("radius", p.radius);
    p.refine = geti("refine", p.refine);
    p.lambda = getf("lambda", p.lambda);
    p.lambdaflat = getf("lambdaflat", p.lambdaflat);
    p.texref = getf("texref", p.texref);
    p.smooth = geti("smooth", p.smooth);
    p.split = geti("split", p.split);
    p.thsad = geti("thsad", p.thsad);
    p.gmv = geti("gmv", p.gmv);
    p.temporal = geti("temporal", p.temporal);
    p.blend = geti("blend", p.blend);
    p.thscd1 = geti("thscd1", p.thscd1);
    p.thscd2 = geti("thscd2", p.thscd2);
    p.scratio = getf("scratio", p.scratio);
    p.ml = getf("ml", p.ml);
    p.mask = getf("mask", p.mask);
    p.occsad = getf("occsad", p.occsad);
    p.bars = geti("bars", p.bars);
    p.statics = getf("static", p.statics);
    p.fades = geti("fades", p.fades);
    p.prefilter = geti("prefilter", p.prefilter);
    p.dedup = geti("dedup", p.dedup);
    p.strength = getf("strength", p.strength);
    p.holdmax = geti("holdmax", p.holdmax);
    p.dupth = getf("dupth", p.dupth);
    p.barsth = getf("barsth", p.barsth);
    p.nvof = geti("nvof", p.nvof);
    p.device = geti("device", p.device);
    if (p.mode < 0 || p.mode > 2) return fail("mode must be 0 (block), 1 (flow) or 2 (adaptive)");
    if (p.blksize != 8 && p.blksize != 16 && p.blksize != 32) return fail("blksize must be 8, 16 or 32");
    if (p.pel != 1 && p.pel != 2) return fail("pel must be 1 or 2");
    if (p.prefilter < 0 || p.prefilter > 2) return fail("prefilter must be 0-2");
    if (p.holdmax < 2 || p.holdmax > 4) return fail("holdmax must be 2-4");
    if (p.nvof < 0 || p.nvof > 3) return fail("nvof must be 0-3");
    if (p.radius < 1 || p.radius > 16 || p.refine < 0 || p.refine > 8) return fail("radius must be 1-16, refine 0-8");

    d->src_num = vi->fpsNum;
    d->src_den = vi->fpsDen;
    d->dedup = p.dedup;
    d->holdmax = p.holdmax;
    d->vi = *vi;
    vsh::reduceRational(&num, &den);
    d->vi.fpsNum = num;
    d->vi.fpsDen = den;
    // Frame count scaled by the rate change (mpv passes a huge placeholder length)
    double frames = (double)vi->numFrames * num * vi->fpsDen / ((double)den * vi->fpsNum);
    d->vi.numFrames = (int)std::min(std::max(frames, 1.0), (double)INT32_MAX);

    try {
        d->engine = std::make_unique<Engine>(vi, p);
    } catch (const std::exception& e) {
        return fail(e.what());
    }

    VSFilterDependency deps[] = {{d->node, rpGeneral}};
    FilterData* raw = d.release();
    vsapi->createVideoFilter(out, "Interpolate", &raw->vi, interp_get_frame, interp_free, fmParallelRequests, deps, 1,
                             raw, core);
}

VS_EXTERNAL_API(void) VapourSynthPluginInit2(VSPlugin* plugin, const VSPLUGINAPI* vspapi) {
    vspapi->configPlugin("com.mpv-portable.gpumv", "gpumv", "GPU motion-compensated frame interpolation",
                         VS_MAKE_VERSION(0, 11), VAPOURSYNTH_API_VERSION, 0, plugin);
    vspapi->registerFunction("Interpolate",
                             "clip:vnode;num:int;den:int:opt;mode:int:opt;blksize:int:opt;pel:int:opt;radius:int:opt;"
                             "refine:int:opt;lambda:float:opt;lambdaflat:float:opt;texref:float:opt;smooth:int:opt;split:int:opt;thsad:int:opt;gmv:int:opt;temporal:int:opt;blend:int:opt;thscd1:int:opt;"
                             "thscd2:int:opt;scratio:float:opt;ml:float:opt;mask:float:opt;occsad:float:opt;bars:int:opt;barsth:float:opt;static:float:opt;fades:int:opt;prefilter:int:opt;nvof:int:opt;dedup:int:opt;holdmax:int:opt;strength:float:opt;dupth:float:opt;device:int:opt;",
                             "clip:vnode;", interp_create, nullptr, plugin);
}
