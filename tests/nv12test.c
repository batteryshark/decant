// Original Decant test, GPL-3.0-or-later. No upstream shim implementation code.
// Two NV12 lifetimes, standard VIDEO_PROCESS path, independent BT.709 oracle.
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <d3d12video.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *f;
static const char *failure = "initialization";
#define CHECK(call) do { HRESULT h = (call); \
    fprintf(f, "%s hr=0x%08lx\n", #call, (unsigned long)h); \
    if (FAILED(h)) { failure = #call; goto done; } } while (0)
#define REQUIRE(test, why) do { if (!(test)) { failure = why; goto done; } } while (0)

static D3D12_RESOURCE_BARRIER transition(ID3D12Resource *r,
        D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER b = {.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
        .Transition = {.pResource = r, .Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                       .StateBefore = before, .StateAfter = after}};
    return b;
}

static int submit(ID3D12CommandQueue *q, ID3D12CommandList *list,
                  ID3D12Fence *fence, UINT64 value, HANDLE event) {
    int ok = 0;
    ID3D12CommandQueue_ExecuteCommandLists(q, 1, &list);
    CHECK(ID3D12CommandQueue_Signal(q, fence, value));
    CHECK(ID3D12Fence_SetEventOnCompletion(fence, value, event));
    DWORD wait = WaitForSingleObject(event, 5000);
    UINT64 completed = ID3D12Fence_GetCompletedValue(fence);
    fprintf(f, "fence target=%llu wait=0x%08lx completed=%llu\n",
            (unsigned long long)value, wait, (unsigned long long)completed);
    REQUIRE(wait == WAIT_OBJECT_0 && completed != UINT64_MAX && completed >= value,
            "fence timeout/device removed");
    ok = 1;
done:
    return ok;
}

static int quantize(double v) {
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    return (int)(255 * v + 0.5);
}

static int footprint_ok(D3D12_PLACED_SUBRESOURCE_FOOTPRINT p, UINT rows,
                        UINT64 bytes, UINT64 total, UINT want_rows, UINT want_bytes) {
    return rows == want_rows && bytes == want_bytes && p.Footprint.RowPitch >= bytes &&
        total <= SIZE_MAX && p.Offset <= total &&
        total - p.Offset >= (UINT64)p.Footprint.RowPitch * (rows - 1) + bytes;
}

static int frame(ID3D12Device *dev, ID3D12VideoProcessor *processor,
                 ID3D12CommandQueue *direct, ID3D12CommandQueue *video,
                 ID3D12Fence *fence, HANDLE event, unsigned iteration) {
    int ok = 0;
    ID3D12Resource *input = NULL, *output = NULL, *upload = NULL, *readback = NULL;
    ID3D12CommandAllocator *da = NULL, *va = NULL;
    ID3D12GraphicsCommandList *dl = NULL;
    ID3D12VideoProcessCommandList *vl = NULL;
    const unsigned char yuv[2][3] = {{112, 96, 176}, {144, 176, 96}};
    unsigned char Y = yuv[iteration][0], U = yuv[iteration][1], V = yuv[iteration][2];
    fprintf(f, "iteration=%u Y=%u U=%u V=%u\n", iteration, Y, U, V);
    D3D12_HEAP_PROPERTIES heap = {.Type = D3D12_HEAP_TYPE_DEFAULT, .CreationNodeMask = 1, .VisibleNodeMask = 1};
    D3D12_RESOURCE_DESC desc = {.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D,
        .Width = 16, .Height = 16, .DepthOrArraySize = 1, .MipLevels = 1,
        .Format = DXGI_FORMAT_NV12, .SampleDesc = {.Count = 1}};
    CHECK(ID3D12Device_CreateCommittedResource(dev, &heap, D3D12_HEAP_FLAG_NONE, &desc,
          D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&input));
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT planes[2], rgba;
    UINT rows[2]; UINT64 bytes[2], total;
    ID3D12Device_GetCopyableFootprints(dev, &desc, 0, 2, 0, planes, rows, bytes, &total);
    REQUIRE(footprint_ok(planes[0], rows[0], bytes[0], total, 16, 16) &&
            footprint_ok(planes[1], rows[1], bytes[1], total, 8, 16), "invalid NV12 footprints");
    fprintf(f, "planes offsets=%llu,%llu pitches=%u,%u total=%llu\n",
        (unsigned long long)planes[0].Offset, (unsigned long long)planes[1].Offset,
        planes[0].Footprint.RowPitch, planes[1].Footprint.RowPitch, (unsigned long long)total);
    D3D12_RESOURCE_DESC buffer = {.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER,
        .Width = total, .Height = 1, .DepthOrArraySize = 1, .MipLevels = 1,
        .SampleDesc = {.Count = 1}, .Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR};
    heap.Type = D3D12_HEAP_TYPE_UPLOAD;
    CHECK(ID3D12Device_CreateCommittedResource(dev, &heap, D3D12_HEAP_FLAG_NONE, &buffer,
          D3D12_RESOURCE_STATE_GENERIC_READ, NULL, &IID_ID3D12Resource, (void **)&upload));
    unsigned char *mapped = NULL;
    D3D12_RANGE empty = {0, 0};
    CHECK(ID3D12Resource_Map(upload, 0, &empty, (void **)&mapped));
    REQUIRE(mapped, "null upload mapping");
    memset(mapped, 0, (size_t)total);
    for (unsigned y = 0; y < 16; ++y)
        memset(mapped + planes[0].Offset + y * planes[0].Footprint.RowPitch, Y, 16);
    for (unsigned y = 0; y < 8; ++y)
        for (unsigned x = 0; x < 8; ++x) {
            unsigned char *p = mapped + planes[1].Offset + y * planes[1].Footprint.RowPitch + x * 2;
            p[0] = U; p[1] = V;
        }
    D3D12_RANGE written = {0, (SIZE_T)total};
    ID3D12Resource_Unmap(upload, 0, &written);
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    CHECK(ID3D12Device_CreateCommittedResource(dev, &heap, D3D12_HEAP_FLAG_NONE, &desc,
          D3D12_RESOURCE_STATE_COMMON, NULL, &IID_ID3D12Resource, (void **)&output));
    ID3D12Device_GetCopyableFootprints(dev, &desc, 0, 1, 0, &rgba, rows, bytes, &total);
    REQUIRE(footprint_ok(rgba, rows[0], bytes[0], total, 16, 64), "invalid RGBA footprint");
    buffer.Width = total; heap.Type = D3D12_HEAP_TYPE_READBACK;
    CHECK(ID3D12Device_CreateCommittedResource(dev, &heap, D3D12_HEAP_FLAG_NONE, &buffer,
          D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback));
    CHECK(ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&da));
    CHECK(ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, da, NULL,
          &IID_ID3D12GraphicsCommandList, (void **)&dl));
    for (unsigned plane = 0; plane < 2; ++plane) {
        D3D12_TEXTURE_COPY_LOCATION src = {.pResource = upload, .Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
            .PlacedFootprint = planes[plane]};
        D3D12_TEXTURE_COPY_LOCATION dst = {.pResource = input, .Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
            .SubresourceIndex = plane};
        ID3D12GraphicsCommandList_CopyTextureRegion(dl, &dst, 0, 0, 0, &src, NULL);
    }
    D3D12_RESOURCE_BARRIER b = transition(input, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COMMON);
    ID3D12GraphicsCommandList_ResourceBarrier(dl, 1, &b);
    CHECK(ID3D12GraphicsCommandList_Close(dl));
    if (!submit(direct, (ID3D12CommandList *)dl, fence, iteration * 3 + 1, event)) goto done;
    CHECK(ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_VIDEO_PROCESS, &IID_ID3D12CommandAllocator, (void **)&va));
    CHECK(ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_VIDEO_PROCESS, va, NULL,
          &IID_ID3D12VideoProcessCommandList, (void **)&vl));
    D3D12_RESOURCE_BARRIER barriers[] = {
        transition(input, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_VIDEO_PROCESS_READ),
        transition(output, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_VIDEO_PROCESS_WRITE)};
    ID3D12VideoProcessCommandList_ResourceBarrier(vl, 2, barriers);
    D3D12_VIDEO_PROCESS_INPUT_STREAM_ARGUMENTS in = {0};
    in.InputStream[0].pTexture2D = input;
    in.Transform.SourceRectangle = (D3D12_RECT){0, 0, 16, 16};
    in.Transform.DestinationRectangle = in.Transform.SourceRectangle;
    D3D12_VIDEO_PROCESS_OUTPUT_STREAM_ARGUMENTS out = {0};
    out.OutputStream[0].pTexture2D = output;
    out.TargetRectangle = in.Transform.SourceRectangle;
    ID3D12VideoProcessCommandList_ProcessFrames(vl, processor, &out, 1, &in);
    barriers[0] = transition(input, D3D12_RESOURCE_STATE_VIDEO_PROCESS_READ, D3D12_RESOURCE_STATE_COMMON);
    barriers[1] = transition(output, D3D12_RESOURCE_STATE_VIDEO_PROCESS_WRITE, D3D12_RESOURCE_STATE_COMMON);
    ID3D12VideoProcessCommandList_ResourceBarrier(vl, 2, barriers);
    CHECK(ID3D12VideoProcessCommandList_Close(vl));
    if (!submit(video, (ID3D12CommandList *)vl, fence, iteration * 3 + 2, event)) goto done;
    CHECK(ID3D12CommandAllocator_Reset(da));
    CHECK(ID3D12GraphicsCommandList_Reset(dl, da, NULL));
    b = transition(output, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE);
    ID3D12GraphicsCommandList_ResourceBarrier(dl, 1, &b);
    D3D12_TEXTURE_COPY_LOCATION src = {.pResource = output, .Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
    D3D12_TEXTURE_COPY_LOCATION dst = {.pResource = readback, .Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT, .PlacedFootprint = rgba};
    ID3D12GraphicsCommandList_CopyTextureRegion(dl, &dst, 0, 0, 0, &src, NULL);
    CHECK(ID3D12GraphicsCommandList_Close(dl));
    if (!submit(direct, (ID3D12CommandList *)dl, fence, iteration * 3 + 3, event)) goto done;
    CHECK(ID3D12Device_GetDeviceRemovedReason(dev));
    D3D12_RANGE range = {0, (SIZE_T)total};
    CHECK(ID3D12Resource_Map(readback, 0, &range, (void **)&mapped));
    REQUIRE(mapped, "null readback mapping");
    // BT.709 non-linear R'G'B': Kr=.2126, Kb=.0722; studio Y=16..235, C=16..240.
    // Matching G22 spaces require matrix/range conversion, not linear-light gamma conversion.
    double luma = (Y - 16.0) / 219.0, cb = (U - 128.0) / 224.0, cr = (V - 128.0) / 224.0;
    int expected[4] = {quantize(luma + 1.5748 * cr),
        quantize(luma - (0.0722 * 1.8556 / 0.7152) * cb - (0.2126 * 1.5748 / 0.7152) * cr),
        quantize(luma + 1.8556 * cb), 255};
    // Two code values cover matrix coefficient approximation and UNORM rounding;
    // solid chroma removes interpolation ambiguity. Alpha must be exactly opaque.
    unsigned bad = 0, max_error = 0;
    for (unsigned y = 0; y < 16; ++y)
        for (unsigned x = 0; x < 16; ++x) {
            unsigned char *p = mapped + rgba.Offset + y * rgba.Footprint.RowPitch + x * 4;
            int mismatch = p[3] != 255;
            for (unsigned c = 0; c < 3; ++c) {
                unsigned error = (unsigned)abs(p[c] - expected[c]);
                if (error > max_error) max_error = error;
                mismatch |= error > 2;
            }
            bad += mismatch;
        }
    unsigned char *first = mapped + rgba.Offset;
    fprintf(f, "iteration=%u expected=%d,%d,%d,255 first=%u,%u,%u,%u checked=256 bad=%u maxRGBerror=%u tolerance=2 alphaTolerance=0\n",
        iteration, expected[0], expected[1], expected[2], first[0], first[1], first[2], first[3], bad, max_error);
    ID3D12Resource_Unmap(readback, 0, &empty);
    REQUIRE(!bad, "pixel mismatch");
    ok = 1;
done:
    // On failure/timeout let process teardown own potentially in-flight objects.
    if (ok) {
        ID3D12VideoProcessCommandList_Release(vl); ID3D12GraphicsCommandList_Release(dl);
        ID3D12CommandAllocator_Release(va); ID3D12CommandAllocator_Release(da);
        ID3D12Resource_Release(input); ID3D12Resource_Release(output);
        ID3D12Resource_Release(upload); ID3D12Resource_Release(readback);
        fprintf(f, "iteration=%u input and command objects released after fences\n", iteration);
    }
    return ok;
}

int main(int argc, char **argv) {
    f = fopen(argc > 1 ? argv[1] : "C:\\decant-nv12test.txt", "w");
    if (!f) return 2;
    setvbuf(f, NULL, _IONBF, 0);
    int result = 1; HANDLE event = NULL;
    ID3D12Device *dev = NULL; ID3D12VideoDevice *video = NULL;
    ID3D12VideoProcessor *processor = NULL;
    ID3D12CommandQueue *direct = NULL, *vq = NULL; ID3D12Fence *fence = NULL;
    CHECK(D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev));
    CHECK(ID3D12Device_QueryInterface(dev, &IID_ID3D12VideoDevice, (void **)&video));
    D3D12_VIDEO_PROCESS_INPUT_STREAM_DESC in = {.Format = DXGI_FORMAT_NV12,
        .ColorSpace = DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709,
        .SourceAspectRatio = {1, 1}, .DestinationAspectRatio = {1, 1}, .FrameRate = {30, 1},
        .SourceSizeRange = {.MaxWidth = 16, .MaxHeight = 16, .MinWidth = 16, .MinHeight = 16},
        .DestinationSizeRange = {.MaxWidth = 16, .MaxHeight = 16, .MinWidth = 16, .MinHeight = 16},
        .StereoFormat = D3D12_VIDEO_FRAME_STEREO_FORMAT_NONE, .FieldType = D3D12_VIDEO_FIELD_TYPE_NONE};
    D3D12_VIDEO_PROCESS_OUTPUT_STREAM_DESC out = {.Format = DXGI_FORMAT_R8G8B8A8_UNORM,
        .ColorSpace = DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
        .AlphaFillMode = D3D12_VIDEO_PROCESS_ALPHA_FILL_MODE_OPAQUE, .FrameRate = {30, 1}};
    CHECK(ID3D12VideoDevice_CreateVideoProcessor(video, 0, &out, 1, &in, &IID_ID3D12VideoProcessor, (void **)&processor));
    D3D12_COMMAND_QUEUE_DESC q = {.Type = D3D12_COMMAND_LIST_TYPE_DIRECT};
    CHECK(ID3D12Device_CreateCommandQueue(dev, &q, &IID_ID3D12CommandQueue, (void **)&direct));
    q.Type = D3D12_COMMAND_LIST_TYPE_VIDEO_PROCESS;
    CHECK(ID3D12Device_CreateCommandQueue(dev, &q, &IID_ID3D12CommandQueue, (void **)&vq));
    CHECK(ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence));
    event = CreateEventA(NULL, FALSE, FALSE, NULL);
    REQUIRE(event, "CreateEvent");
    for (unsigned i = 0; i < 2; ++i)
        if (!frame(dev, processor, direct, vq, fence, event, i)) goto done;
    result = 0; failure = "none";
done:
    ; const char *names[] = {"d3d12.dll", "d3d12core.dll", "dxgi.dll", "d3dmt.dll", "dxgm.dll", "d3dcompiler_47.dll"};
    for (unsigned i = 0; i < sizeof(names)/sizeof(*names); ++i) {
        char path[MAX_PATH] = "(not loaded)"; HMODULE m = GetModuleHandleA(names[i]);
        if (m) GetModuleFileNameA(m, path, MAX_PATH);
        fprintf(f, "%s: %s\n", names[i], path);
    }
    fprintf(f, "result: %s code=%d reason=%s\nDECANT_NV12_COMPLETE code=%d\n",
            result ? "FAIL" : "PASS", result, failure, result);
    int flush_error = fflush(f), close_error = fclose(f);
    if (event) CloseHandle(event);
    return flush_error || close_error ? 3 : result;
}
