#pragma comment( lib, "d3d9.lib" )
#if defined(DEBUG) || defined(_DEBUG)
#pragma comment( lib, "d3dx9d.lib" )
#else
#pragma comment( lib, "d3dx9.lib" )
#endif

#include <d3d9.h>
#include <d3dx9.h>
#include <string>
#include <tchar.h>
#include <cassert>
#include <crtdbg.h>
#include <vector>

#define SAFE_RELEASE(p) { if (p) { (p)->Release(); (p) = NULL; } }

const int WINDOW_SIZE_W = 1600;
const int WINDOW_SIZE_H = 900;

LPDIRECT3D9 g_pD3D = NULL;
LPDIRECT3DDEVICE9 g_pd3dDevice = NULL;
LPD3DXFONT g_pFont = NULL;
LPD3DXMESH g_pMesh = NULL;
std::vector<D3DMATERIAL9> g_pMaterials;
std::vector<LPDIRECT3DTEXTURE9> g_pTextures;
DWORD g_dwNumMaterials = 0;
LPD3DXEFFECT g_pEffect = NULL;
bool g_bClose = false;

// 追加：法線＆高さマップ
LPDIRECT3DTEXTURE9 g_pNormalTex = NULL;
LPDIRECT3DTEXTURE9 g_pHeightTex = NULL;

static void TextDraw(LPD3DXFONT pFont, TCHAR* text, int X, int Y);
static void InitD3D(HWND hWnd);
static void Cleanup();
static void Render();
LRESULT WINAPI MsgProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

int WINAPI _tWinMain(_In_ HINSTANCE hInstance,
                     _In_opt_ HINSTANCE hPrevInstance,
                     _In_ LPTSTR lpCmdLine,
                     _In_ int nCmdShow)
{
    _CrtSetDbgFlag(_CRTDBG_ALLOC_MEM_DF | _CRTDBG_LEAK_CHECK_DF);

    WNDCLASSEX wc { };
    wc.cbSize = sizeof(WNDCLASSEX);
    wc.style = CS_CLASSDC;
    wc.lpfnWndProc = MsgProc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = GetModuleHandle(NULL);
    wc.hIcon = NULL;
    wc.hCursor = NULL;
    wc.hbrBackground = NULL;
    wc.lpszMenuName = NULL;
    wc.lpszClassName = _T("Window1");
    wc.hIconSm = NULL;

    ATOM atom = RegisterClassEx(&wc);
    assert(atom != 0);

    RECT rect;
    SetRect(&rect, 0, 0, WINDOW_SIZE_W, WINDOW_SIZE_H);
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
    rect.right = rect.right - rect.left;
    rect.bottom = rect.bottom - rect.top;
    rect.top = 0;
    rect.left = 0;

    HWND hWnd = CreateWindow(_T("Window1"),
                             _T("Hello DirectX9 World !!"),
                             WS_OVERLAPPEDWINDOW,
                             CW_USEDEFAULT,
                             CW_USEDEFAULT,
                             rect.right,
                             rect.bottom,
                             NULL,
                             NULL,
                             wc.hInstance,
                             NULL);

    InitD3D(hWnd);
    ShowWindow(hWnd, SW_SHOWDEFAULT);
    UpdateWindow(hWnd);

    MSG msg;
    while (true)
    {
        if (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
            DispatchMessage(&msg);
        }
        else {
            Sleep(16);
            Render();
        }
        if (g_bClose) break;
    }

    Cleanup();
    UnregisterClass(_T("Window1"), wc.hInstance);
    return 0;
}

void TextDraw(LPD3DXFONT pFont, TCHAR* text, int X, int Y)
{
    RECT rect = { X, Y, 0, 0 };
    HRESULT hResult = pFont->DrawText(NULL, text, -1, &rect,
                                      DT_LEFT | DT_NOCLIP,
                                      D3DCOLOR_ARGB(255, 0, 0, 0));
    assert((int)hResult >= 0);
}

void InitD3D(HWND hWnd)
{
    HRESULT hr = E_FAIL;

    g_pD3D = Direct3DCreate9(D3D_SDK_VERSION);
    assert(g_pD3D != NULL);

    D3DPRESENT_PARAMETERS d3dpp = {};
    d3dpp.Windowed = TRUE;
    d3dpp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    d3dpp.BackBufferFormat = D3DFMT_UNKNOWN;
    d3dpp.BackBufferCount = 1;
    d3dpp.MultiSampleType = D3DMULTISAMPLE_NONE;
    d3dpp.MultiSampleQuality = 0;
    d3dpp.EnableAutoDepthStencil = TRUE;
    d3dpp.AutoDepthStencilFormat = D3DFMT_D16;
    d3dpp.hDeviceWindow = hWnd;
    d3dpp.PresentationInterval = D3DPRESENT_INTERVAL_DEFAULT;

    hr = g_pD3D->CreateDevice(D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hWnd,
                              D3DCREATE_HARDWARE_VERTEXPROCESSING,
                              &d3dpp, &g_pd3dDevice);
    if (FAILED(hr)) {
        hr = g_pD3D->CreateDevice(D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hWnd,
                                  D3DCREATE_SOFTWARE_VERTEXPROCESSING,
                                  &d3dpp, &g_pd3dDevice);
        assert(hr == S_OK);
    }

    hr = D3DXCreateFont(g_pd3dDevice, 20, 0, FW_HEAVY, 1, FALSE,
                        SHIFTJIS_CHARSET, OUT_TT_ONLY_PRECIS,
                        CLEARTYPE_NATURAL_QUALITY, FF_DONTCARE,
                        _T("ＭＳ ゴシック"), &g_pFont);
    assert(hr == S_OK);

    // cube.x を読み込み
    LPD3DXBUFFER pMtrlBuf = NULL;
    hr = D3DXLoadMeshFromX(_T("untitled.blend.x"), D3DXMESH_SYSTEMMEM, g_pd3dDevice,
                           NULL, &pMtrlBuf, NULL, &g_dwNumMaterials, &g_pMesh);
    assert(hr == S_OK);

    D3DXMATERIAL* mats = (D3DXMATERIAL*)pMtrlBuf->GetBufferPointer();
    g_pMaterials.resize(g_dwNumMaterials);
    g_pTextures.resize(g_dwNumMaterials);

    for (DWORD i = 0; i < g_dwNumMaterials; i++)
    {
        g_pMaterials[i] = mats[i].MatD3D;
        g_pMaterials[i].Ambient = g_pMaterials[i].Diffuse;
        g_pTextures[i] = NULL;

        std::string path(mats[i].pTextureFilename);
        if (!path.empty())
        {
#ifndef UNICODE
            hr = D3DXCreateTextureFromFileA(g_pd3dDevice, path.c_str(), &g_pTextures[i]);
#else
            int len = MultiByteToWideChar(CP_ACP, 0, path.c_str(), -1, nullptr, 0);
            std::wstring wpath(len, 0);
            MultiByteToWideChar(CP_ACP, 0, path.c_str(), -1, &wpath[0], len);
            hr = D3DXCreateTextureFromFileW(g_pd3dDevice, wpath.c_str(), &g_pTextures[i]);
#endif
            assert(hr == S_OK);
        }
    }
    pMtrlBuf->Release();

    // Parallax 用テクスチャ（同フォルダに normalMap.png / bumpMap.png を置く）
#ifndef UNICODE
    hr = D3DXCreateTextureFromFileA(g_pd3dDevice, "normalMap.png", &g_pNormalTex);
    assert(hr == S_OK);
    hr = D3DXCreateTextureFromFileA(g_pd3dDevice, "bumpMap.png", &g_pHeightTex);
    assert(hr == S_OK);
#else
    hr = D3DXCreateTextureFromFileW(g_pd3dDevice, L"normalMap.png", &g_pNormalTex);
    assert(hr == S_OK);
    hr = D3DXCreateTextureFromFileW(g_pd3dDevice, L"bumpMap.png", &g_pHeightTex);
    assert(hr == S_OK);
#endif

    // エフェクト
    hr = D3DXCreateEffectFromFile(g_pd3dDevice, _T("simple.fx"),
                                  NULL, NULL, D3DXSHADER_DEBUG,
                                  NULL, &g_pEffect, NULL);
    assert(hr == S_OK);
}

void Cleanup()
{
    for (auto& t : g_pTextures) SAFE_RELEASE(t);
    SAFE_RELEASE(g_pNormalTex);
    SAFE_RELEASE(g_pHeightTex);
    SAFE_RELEASE(g_pMesh);
    SAFE_RELEASE(g_pEffect);
    SAFE_RELEASE(g_pFont);
    SAFE_RELEASE(g_pd3dDevice);
    SAFE_RELEASE(g_pD3D);
}

void Render()
{
    HRESULT hr = E_FAIL;

    static float f = 0.0f;
    f += 0.01f;

    static float f2 = 0.0f;
    f2 += 0.02f;

    // 行列
    D3DXMATRIX World, View, Proj, WVP;
    D3DXMatrixIdentity(&World);

    D3DXMatrixPerspectiveFovLH(&Proj, D3DXToRadian(45),
                               (float)WINDOW_SIZE_W / WINDOW_SIZE_H,
                               1.0f, 10000.0f);

    D3DXVECTOR3 eye(3.f * sinf(f), 2.f, -3.f * cosf(f));
    D3DXVECTOR3 at(0, 0, 0);
    D3DXVECTOR3 up(0, 1, 0);
    D3DXMatrixLookAtLH(&View, &eye, &at, &up);

    WVP = World * View * Proj;

    // クリア
    hr = g_pd3dDevice->Clear(0, NULL,
                             D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER,
                             D3DCOLOR_XRGB(100, 100, 100), 1.0f, 0);
    assert(hr == S_OK);

    hr = g_pd3dDevice->BeginScene(); assert(hr == S_OK);

    //TextDraw(g_pFont, _T("Parallax Mapping Sample"), 8, 8);
    TCHAR temp[12];
//    TextDraw(g_pFont, temp, 8, 8);

    g_pEffect->SetMatrix("g_matWorldViewProj", &WVP);
    g_pEffect->SetMatrix("g_matWorld", &World);

    D3DXVECTOR4 eyePos(eye.x, eye.y, eye.z, 1.0f);
    g_pEffect->SetVector("g_eyePos", &eyePos);

    D3DXVECTOR4 lightDir = D3DXVECTOR4(1.0f * sinf(f2), 1.0f * sinf(f2), 1.0f * cosf(f2), 0.0f);
    D3DXVec4Normalize(&lightDir, &lightDir);
    g_pEffect->SetVector("g_lightDirWorld", &lightDir);

    // --- POM parameters ---
    g_pEffect->SetInt("g_pomMinSamples", 8);
    g_pEffect->SetInt("g_pomMaxSamples", 24);
    g_pEffect->SetInt("g_pomRefineSteps", 1);   // 0〜2
    g_pEffect->SetFloat("g_pomScale", 0.04f);  // 0.02〜0.06 で調整

    g_pEffect->SetTexture("g_texNormal", g_pNormalTex);
    g_pEffect->SetTexture("g_texHeight", g_pHeightTex);

    // ★ テクニック名を POM に
    g_pEffect->SetTechnique("Technique_ParallaxOcclusion");

    UINT nPass = 0;
    g_pEffect->Begin(&nPass, 0);
    g_pEffect->BeginPass(0);

    for (DWORD i = 0; i < g_dwNumMaterials; ++i)
    {
        g_pEffect->SetTexture("g_texColor", g_pTextures[i]);
        g_pEffect->CommitChanges();
        g_pMesh->DrawSubset(i);
    }

    g_pEffect->EndPass();
    g_pEffect->End();

    g_pd3dDevice->EndScene();
    g_pd3dDevice->Present(NULL, NULL, NULL, NULL);
}

LRESULT WINAPI MsgProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg)
    {
    case WM_DESTROY:
        PostQuitMessage(0);
        g_bClose = true;
        return 0;
    }
    return DefWindowProc(hWnd, msg, wParam, lParam);
}
