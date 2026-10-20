// Bounded, headless native capability observation; no rendering or interposers.
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <windows.h>
#include <initguid.h>
#include <d3d11.h>
#include <d3d12.h>
#include <d3d12video.h>
#include <dxgi1_4.h>
#include <stdio.h>

static void adapter(FILE *f, const char *label, IDXGIAdapter *a) {
    DXGI_ADAPTER_DESC desc = {0};
    HRESULT hr = IDXGIAdapter_GetDesc(a, &desc);
    fprintf(f, "%s GetDesc hr=0x%08lx vendor=0x%x device=0x%x\n",
            label, (unsigned long)hr, desc.VendorId, desc.DeviceId);
    // ID3D10Device is the documented DXGI CheckInterfaceSupport device IID.
    // D3D11/12 queries are supplementary; rejection alone is not driver failure.
    const GUID *ids[] = {&IID_ID3D10Device, &IID_ID3D11Device, &IID_ID3D12Device};
    const char *names[] = {"ID3D10Device", "ID3D11Device", "ID3D12Device"};
    for (unsigned i = 0; i < 3; ++i) {
        LARGE_INTEGER version = {0};
        hr = IDXGIAdapter_CheckInterfaceSupport(a, ids[i], &version);
        fprintf(f, "%s CheckInterfaceSupport %s hr=0x%08lx driver=0x%016llx valid=%d\n",
                label, names[i], (unsigned long)hr,
                (unsigned long long)version.QuadPart, SUCCEEDED(hr));
    }
    fflush(f);
}

int main(int argc, char **argv) {
    FILE *f = fopen(argc > 1 ? argv[1] : "C:\\decant-native-capabilities.txt", "w");
    if (!f) return 1;
    setvbuf(f, NULL, _IONBF, 0);
    ID3D12Device *dev = NULL;
    HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    int baseline = SUCCEEDED(hr) && dev;
    fprintf(f, "D3D12CreateDevice hr=0x%08lx nonnull=%d\n", (unsigned long)hr, dev != NULL);
    if (baseline) {
        ID3D12VideoDevice *video = NULL;
        hr = ID3D12Device_QueryInterface(dev, &IID_ID3D12VideoDevice, (void **)&video);
        fprintf(f, "QI ID3D12VideoDevice hr=0x%08lx nonnull=%d\n", (unsigned long)hr, video != NULL);
        if (SUCCEEDED(hr) && video) {
            D3D12_FEATURE_DATA_VIDEO_PROCESS_SUPPORT s = {0};
            s.InputSample.Width = 1920; s.InputSample.Height = 1080;
            s.InputSample.Format.Format = DXGI_FORMAT_NV12;
            s.InputSample.Format.ColorSpace = DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709;
            s.InputFieldType = D3D12_VIDEO_FIELD_TYPE_NONE;
            s.InputStereoFormat = D3D12_VIDEO_FRAME_STEREO_FORMAT_NONE;
            s.InputFrameRate.Numerator = 30; s.InputFrameRate.Denominator = 1;
            s.OutputFormat.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            s.OutputFormat.ColorSpace = DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
            s.OutputStereoFormat = D3D12_VIDEO_FRAME_STEREO_FORMAT_NONE;
            s.OutputFrameRate = s.InputFrameRate;
            hr = ID3D12VideoDevice_CheckFeatureSupport(video, D3D12_FEATURE_VIDEO_PROCESS_SUPPORT, &s, sizeof(s));
            fprintf(f, "VIDEO_PROCESS_SUPPORT NV12 studio BT709 -> RGBA8 full BT709 1920x1080 progressive 30/1 hr=0x%08lx flags=0x%x supported=%d valid=%d\n",
                    (unsigned long)hr, s.SupportFlags,
                    SUCCEEDED(hr) && !!(s.SupportFlags & D3D12_VIDEO_PROCESS_SUPPORT_FLAG_SUPPORTED), SUCCEEDED(hr));
            ID3D12VideoDevice_Release(video);
        } else fprintf(f, "VIDEO_PROCESS_SUPPORT not callable: video interface unavailable\n");
    }
    IDXGIFactory *legacy = NULL;
    hr = CreateDXGIFactory(&IID_IDXGIFactory, (void **)&legacy);
    fprintf(f, "CreateDXGIFactory hr=0x%08lx\n", (unsigned long)hr);
    if (SUCCEEDED(hr) && legacy) {
        IDXGIAdapter *a = NULL;
        hr = IDXGIFactory_EnumAdapters(legacy, 0, &a);
        fprintf(f, "EnumAdapters(0) hr=0x%08lx\n", (unsigned long)hr);
        if (SUCCEEDED(hr) && a) { adapter(f, "legacy", a); IDXGIAdapter_Release(a); }
        IDXGIFactory_Release(legacy);
    }
    IDXGIFactory1 *modern = NULL;
    hr = CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&modern);
    fprintf(f, "CreateDXGIFactory1 hr=0x%08lx\n", (unsigned long)hr);
    if (SUCCEEDED(hr) && modern) {
        IDXGIAdapter1 *a = NULL;
        hr = IDXGIFactory1_EnumAdapters1(modern, 0, &a);
        fprintf(f, "EnumAdapters1(0) hr=0x%08lx\n", (unsigned long)hr);
        if (SUCCEEDED(hr) && a) { adapter(f, "modern", (IDXGIAdapter *)a); IDXGIAdapter1_Release(a); }
        IDXGIFactory1_Release(modern);
    }
    const char *modules[] = {"d3d12.dll", "d3d12core.dll", "dxgi.dll", "d3dmt.dll", "dxgm.dll", "wined3d.dll"};
    for (unsigned i = 0; i < sizeof(modules)/sizeof(*modules); ++i) {
        char path[MAX_PATH] = "(not loaded)";
        HMODULE m = GetModuleHandleA(modules[i]);
        if (m) GetModuleFileNameA(m, path, MAX_PATH);
        fprintf(f, "%s: %s\n", modules[i], path);
    }
    if (dev) ID3D12Device_Release(dev);
    fprintf(f, "result: COMPLETE device_baseline=%s; unsupported capabilities are observations, not GPU execution tests\n", baseline ? "PASS" : "FAIL");
    fprintf(f, "DECANT_NATIVE_COMPLETE code=%d\n", !baseline);
    fclose(f);
    return !baseline;
}
