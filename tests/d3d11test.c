// Creates a D3D11 device + swapchain, presents for ~3 s, reads a cleared pixel
// back, and writes which d3d11/dxgi DLLs and adapter were used to argv[1] or C:\decant-d3d11test.txt.
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

static void module_path(FILE *f, const char *name) {
    char path[MAX_PATH] = "(not loaded)";
    HMODULE mod = GetModuleHandleA(name);
    if (mod) GetModuleFileNameA(mod, path, MAX_PATH);
    fprintf(f, "%s: %s\n", name, path);
}

int main(int argc, char **argv) {
    FILE *f = fopen(argc > 1 ? argv[1] : "C:\\decant-d3d11test.txt", "w");
    if (!f) return 1;
    fprintf(f, "pointer bits: %d\n", (int)sizeof(void *) * 8);

    WNDCLASSA wc = {.lpfnWndProc = DefWindowProcA, .hInstance = GetModuleHandleA(NULL), .lpszClassName = "d3d11test"};
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("d3d11test", "decant D3D11 test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {
        .BufferCount = 1,
        .BufferDesc = {.Width = 640, .Height = 480, .Format = DXGI_FORMAT_R8G8B8A8_UNORM},
        .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .OutputWindow = hwnd,
        .SampleDesc.Count = 1,
        .Windowed = TRUE,
        .SwapEffect = DXGI_SWAP_EFFECT_DISCARD,
    };
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    IDXGISwapChain *sc;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    fprintf(f, "D3D11CreateDeviceAndSwapChain: hr=0x%08lx feature level=0x%x\n", (unsigned long)hr, fl);
    module_path(f, "d3d11.dll");
    module_path(f, "dxgi.dll");
    module_path(f, "winemetal.dll");
    module_path(f, "wined3d.dll");
    if (FAILED(hr)) return fclose(f), 2;

    // DXVK v1.10.3 src/d3d11/d3d11_interfaces.h: query the returned
    // device itself, not a loaded module or the factory's adapter.
    static const GUID dxvk_ext_device = {
        0x8a6e3c42, 0xf74c, 0x45b7, {0x82, 0x65, 0xa2, 0x31, 0xb6, 0x77, 0xca, 0x17}
    };
    IUnknown *ext = NULL;
    HRESULT ext_hr = ID3D11Device_QueryInterface(dev, &dxvk_ext_device, (void **)&ext);
    fprintf(f, "returned device QI ID3D11VkExtDevice (8a6e3c42-f74c-45b7-8265-a231b677ca17): hr=0x%08lx nonnull=%d\n",
            (unsigned long)ext_hr, ext != NULL);
    if (ext) IUnknown_Release(ext);

    IDXGIDevice *dxgidev;
    IDXGIAdapter *adapter;
    DXGI_ADAPTER_DESC desc;
    ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgidev);
    IDXGIDevice_GetAdapter(dxgidev, &adapter);
    IDXGIAdapter_GetDesc(adapter, &desc);
    fprintf(f, "adapter: %ls\n", desc.Description);

    ID3D11Texture2D *back, *staging;
    ID3D11RenderTargetView *rtv;
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&back);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv);
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(back, &td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Device_CreateTexture2D(dev, &td, NULL, &staging);

    float color[4] = {1.0f, 0.5f, 0.0f, 1.0f};
    int frames = 0;
    MSG msg;
    for (DWORD start = GetTickCount(); GetTickCount() - start < 3000; frames++) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, color);
        IDXGISwapChain_Present(sc, 1, 0);
    }
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, color);
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)back);
    D3D11_MAPPED_SUBRESOURCE map;
    unsigned int pixel = 0;
    HRESULT map_hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
    fprintf(f, "readback Map: hr=0x%08lx\n", (unsigned long)map_hr);
    if (SUCCEEDED(map_hr)) {
        pixel = *(unsigned int *)map.pData;
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    }
    fprintf(f, "frames presented in 3 s: %d\nreadback pixel: 0x%08x (expect 0xff0080ff)\n", frames, pixel);
    return fclose(f);
}
