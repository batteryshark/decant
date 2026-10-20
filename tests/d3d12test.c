// Headless x64 smoke test: GPU clear -> copy -> fence -> exact RGBA8 readback.
// COM objects intentionally live until process exit (also on fence timeout).
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdint.h>
#include <stdio.h>

static void module_path(FILE *f, const char *name) {
    char path[MAX_PATH] = "(not loaded)";
    HMODULE module = GetModuleHandleA(name);
    if (module && !GetModuleFileNameA(module, path, MAX_PATH))
        snprintf(path, sizeof(path), "(path error %lu)", GetLastError());
    fprintf(f, "%s: %s\n", name, path);
}

#define CHECK(call) do { \
    HRESULT hr_ = (call); \
    fprintf(f, "%s: hr=0x%08lx\n", #call, (unsigned long)hr_); \
    fflush(f); \
    if (FAILED(hr_)) { failure = #call; goto done; } \
} while (0)

int main(int argc, char **argv) {
    FILE *f = fopen(argc > 1 ? argv[1] : "C:\\decant-d3d12test.txt", "w");
    if (!f) { fprintf(stderr, "FAIL: cannot open result file\n"); return 1; }
    int result = 1;
    const char *failure = "initialization";
    HANDLE event = NULL;
    fprintf(f, "pointer bits: %u\n", (unsigned)(sizeof(void *) * 8));
    fflush(f);

    IDXGIFactory1 *factory = NULL;
    IDXGIAdapter1 *adapter = NULL;
    DXGI_ADAPTER_DESC1 adapter_desc;
    ID3D12Device *device = NULL;
    CHECK(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory));
    CHECK(IDXGIFactory1_EnumAdapters1(factory, 0, &adapter));
    CHECK(IDXGIAdapter1_GetDesc1(adapter, &adapter_desc));
    fprintf(f, "adapter: %ls vendor=0x%x device=0x%x flags=0x%x\n",
            adapter_desc.Description, adapter_desc.VendorId, adapter_desc.DeviceId, adapter_desc.Flags);
    CHECK(D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device));

    ID3D12CommandQueue *queue = NULL;
    ID3D12CommandAllocator *allocator = NULL;
    ID3D12GraphicsCommandList *list = NULL;
    D3D12_COMMAND_QUEUE_DESC queue_desc = {.Type = D3D12_COMMAND_LIST_TYPE_DIRECT};
    CHECK(ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue));
    CHECK(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&allocator));
    CHECK(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
                                       &IID_ID3D12GraphicsCommandList, (void **)&list));

    ID3D12DescriptorHeap *rtv_heap = NULL;
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV, .NumDescriptors = 1};
    CHECK(ID3D12Device_CreateDescriptorHeap(device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap));
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(rtv_heap);
    ID3D12Resource *texture = NULL, *readback = NULL;
    D3D12_HEAP_PROPERTIES gpu_heap = {.Type = D3D12_HEAP_TYPE_DEFAULT, .CreationNodeMask = 1, .VisibleNodeMask = 1};
    D3D12_RESOURCE_DESC texture_desc = {
        .Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D, .Width = 4, .Height = 4,
        .DepthOrArraySize = 1, .MipLevels = 1, .Format = DXGI_FORMAT_R8G8B8A8_UNORM,
        .SampleDesc = {.Count = 1}, .Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN,
        .Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET
    };
    const float red[4] = {1, 0, 0, 1};
    CHECK(ID3D12Device_CreateCommittedResource(device, &gpu_heap, D3D12_HEAP_FLAG_NONE, &texture_desc,
             D3D12_RESOURCE_STATE_RENDER_TARGET, NULL, &IID_ID3D12Resource, (void **)&texture));
    ID3D12Device_CreateRenderTargetView(device, texture, NULL, rtv);

    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    UINT rows = 0;
    UINT64 row_bytes = 0, total_bytes = 0;
    ID3D12Device_GetCopyableFootprints(device, &texture_desc, 0, 1, 0, &footprint, &rows, &row_bytes, &total_bytes);
    if (rows != 4 || row_bytes != 16 || total_bytes == 0 || total_bytes > SIZE_MAX ||
        footprint.Footprint.RowPitch < 16 || footprint.Offset > total_bytes ||
        total_bytes - footprint.Offset < (UINT64)footprint.Footprint.RowPitch * 3 + 16) {
        failure = "invalid copy footprint"; goto done;
    }
    D3D12_HEAP_PROPERTIES cpu_heap = {.Type = D3D12_HEAP_TYPE_READBACK, .CreationNodeMask = 1, .VisibleNodeMask = 1};
    D3D12_RESOURCE_DESC buffer_desc = {
        .Dimension = D3D12_RESOURCE_DIMENSION_BUFFER, .Width = total_bytes, .Height = 1,
        .DepthOrArraySize = 1, .MipLevels = 1, .SampleDesc = {.Count = 1}, .Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR
    };
    CHECK(ID3D12Device_CreateCommittedResource(device, &cpu_heap, D3D12_HEAP_FLAG_NONE, &buffer_desc,
             D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback));
    ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, red, 0, NULL);
    D3D12_RESOURCE_BARRIER barrier = {
        .Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
        .Transition = {.pResource = texture, .Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
            .StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET, .StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE}
    };
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
    D3D12_TEXTURE_COPY_LOCATION src = {.pResource = texture, .Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX, .SubresourceIndex = 0};
    D3D12_TEXTURE_COPY_LOCATION dst = {.pResource = readback, .Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT, .PlacedFootprint = footprint};
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    CHECK(ID3D12GraphicsCommandList_Close(list));

    ID3D12Fence *fence = NULL;
    CHECK(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence));
    event = CreateEventA(NULL, FALSE, FALSE, NULL);
    if (!event) { fprintf(f, "CreateEvent: error=%lu\n", GetLastError()); failure = "CreateEvent"; goto done; }
    ID3D12CommandList *lists[] = {(ID3D12CommandList *)list};
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, lists);
    CHECK(ID3D12CommandQueue_Signal(queue, fence, 1));
    CHECK(ID3D12Fence_SetEventOnCompletion(fence, 1, event));
    DWORD wait = WaitForSingleObject(event, 10000);
    UINT64 completed = ID3D12Fence_GetCompletedValue(fence);
    fprintf(f, "fence wait: 0x%08lx completed=%llu\n", wait, (unsigned long long)completed);
    if (wait != WAIT_OBJECT_0 || completed == UINT64_MAX || completed < 1) {
        failure = "fence timeout/failure/device removed"; goto done;
    }
    CHECK(ID3D12Device_GetDeviceRemovedReason(device));
    D3D12_RANGE range = {.Begin = 0, .End = (SIZE_T)total_bytes};
    unsigned char *mapped = NULL;
    CHECK(ID3D12Resource_Map(readback, 0, &range, (void **)&mapped));
    if (!mapped) { failure = "Map returned null"; goto done; }
    unsigned mismatches = 0;
    uint32_t first = *(uint32_t *)(mapped + footprint.Offset);
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++)
            if (*(uint32_t *)(mapped + footprint.Offset + y * footprint.Footprint.RowPitch + x * 4) != 0xff0000ffu)
                mismatches++;
    D3D12_RANGE written = {0, 0};
    ID3D12Resource_Unmap(readback, 0, &written);
    fprintf(f, "readback pixel: 0x%08x expected=0xff0000ff checked=16 mismatches=%u\n", first, mismatches);
    if (mismatches) { failure = "pixel mismatch"; goto done; }
    result = 0;
    failure = "none";

done:
    module_path(f, "d3d12.dll");
    module_path(f, "d3d12core.dll");
    module_path(f, "dxgi.dll");
    module_path(f, "d3dmt.dll");
    module_path(f, "dxgm.dll");
    fprintf(f, "result: %s code=%d reason=%s\n", result ? "FAIL" : "PASS", result, failure);
    fprintf(f, "DECANT_D3D12_COMPLETE code=%d\n", result);
    int flush_failed = fflush(f) != 0;
    int close_failed = fclose(f) != 0;
    if (event) CloseHandle(event);
    return flush_failed || close_failed ? 3 : result;
}
