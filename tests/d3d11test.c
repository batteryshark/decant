// Minimal D3D11 check: creates a device + swapchain on a window, clears and
// presents for ~3 s, reads a pixel back, and reports which d3d11/dxgi DLLs
// were loaded and which adapter answered. Usage: d3d11test.exe [outfile]
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

static void module_path(FILE *f, const char *name) {
    char path[MAX_PATH] = "(not loaded)";
    HMODULE mod = GetModuleHandleA(name);
    if (mod) GetModuleFileNameA(mod, path, MAX_PATH);
    fprintf(f, "%s: %s\n", name, path);
}

int main(int argc, char **argv) {
    FILE *f = argc > 1 ? fopen(argv[1], "w") : stdout;
    if (!f) return 1;
    fprintf(f, "pointer bits: %d\n", (int)sizeof(void *) * 8);

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "d3d11test";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("d3d11test", "decant D3D11 test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 1;
    sd.BufferDesc.Width = 640;
    sd.BufferDesc.Height = 480;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *sc = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    fprintf(f, "D3D11CreateDeviceAndSwapChain: hr=0x%08lx feature level=0x%x\n", (unsigned long)hr, fl);
    module_path(f, "d3d11.dll");
    module_path(f, "dxgi.dll");
    module_path(f, "winemetal.dll");
    module_path(f, "wined3d.dll");
    if (FAILED(hr)) { fclose(f); return 2; }

    IDXGIDevice *dxgidev = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC desc = {0};
    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgidev)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgidev, &adapter)) && SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc)))
        fprintf(f, "adapter: %ls (vendor 0x%04x)\n", desc.Description, desc.VendorId);

    ID3D11Texture2D *back = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&back);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv);

    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(back, &td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    td.MiscFlags = 0;
    ID3D11Texture2D *staging = NULL;
    ID3D11Device_CreateTexture2D(dev, &td, NULL, &staging);

    DWORD start = GetTickCount();
    int frames = 0;
    unsigned int pixel = 0;
    MSG msg;
    while (GetTickCount() - start < 3000) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        float t = (GetTickCount() - start) / 3000.0f;
        float color[4] = {t, 0.25f, 1.0f - t, 1.0f};
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, color);
        if (frames == 10) {
            float probe[4] = {1.0f, 0.5f, 0.0f, 1.0f};  // expect ff/80/00 readback
            ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, probe);
            ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)back);
            D3D11_MAPPED_SUBRESOURCE map;
            if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map))) {
                pixel = *(unsigned int *)map.pData;
                ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
            }
        }
        IDXGISwapChain_Present(sc, 1, 0);
        frames++;
    }
    fprintf(f, "frames presented in 3 s: %d\nreadback pixel (RGBA bytes LE): 0x%08x (expect 0xff0080ff)\n",
            frames, pixel);
    fclose(f);
    return 0;
}
