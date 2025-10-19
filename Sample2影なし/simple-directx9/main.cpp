#pragma comment( lib, "d3d9.lib" )
#if defined(DEBUG) || defined(_DEBUG)
#pragma comment( lib, "d3dx9d.lib" )
#else
#pragma comment( lib, "d3dx9.lib" )
#endif

#include <d3d9.h>
#include <d3dx9.h>
#include <tchar.h>
#include <cassert>
#include <crtdbg.h>
#include <string>
#include <vector>

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
#define SAFE_RELEASE(p) do { if (p) { (p)->Release(); (p) = NULL; } } while(0)

// -----------------------------------------------------------------------------
// Constants
// -----------------------------------------------------------------------------
static const int WINDOW_SIZE_W = 1600;
static const int WINDOW_SIZE_H = 900;

// -----------------------------------------------------------------------------
// Globals
// -----------------------------------------------------------------------------
LPDIRECT3D9 g_pD3D = NULL;
LPDIRECT3DDEVICE9 g_pD3dDevice = NULL;
LPD3DXMESH g_pMesh = NULL;
std::vector<D3DMATERIAL9> g_materials;
std::vector<LPDIRECT3DTEXTURE9> g_textures;
DWORD g_numMaterials = 0;
LPD3DXEFFECT g_pEffect = NULL;
bool g_shouldClose = false;

// Parallax / POM textures
LPDIRECT3DTEXTURE9 g_pNormalTex = NULL;
LPDIRECT3DTEXTURE9 g_pHeightTex = NULL;

// -----------------------------------------------------------------------------
// Forward Declarations
// -----------------------------------------------------------------------------
static void InitD3D(HWND hWnd);
static void Cleanup();
static void Render();
static LRESULT WINAPI MsgProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

// -----------------------------------------------------------------------------
// Entry Point
// -----------------------------------------------------------------------------
extern int WINAPI _tWinMain(_In_ HINSTANCE hInstance,
                            _In_opt_ HINSTANCE,
                            _In_ LPTSTR,
                            _In_ int);

int WINAPI _tWinMain(_In_ HINSTANCE hInstance,
                     _In_opt_ HINSTANCE,
                     _In_ LPTSTR,
                     _In_ int)
{
    _CrtSetDbgFlag(_CRTDBG_ALLOC_MEM_DF | _CRTDBG_LEAK_CHECK_DF);

    WNDCLASSEX windowClass = { 0 };
    windowClass.cbSize = sizeof(WNDCLASSEX);
    windowClass.style = CS_CLASSDC;
    windowClass.lpfnWndProc = MsgProc;
    windowClass.hInstance = GetModuleHandle(NULL);
    windowClass.lpszClassName = _T("Window1");

    ATOM atom = RegisterClassEx(&windowClass);
    assert(atom != 0);

    RECT rect;
    SetRect(&rect, 0, 0, WINDOW_SIZE_W, WINDOW_SIZE_H);
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);

    int windowWidth = rect.right - rect.left;
    int windowHeight = rect.bottom - rect.top;

    HWND hWnd = CreateWindow(_T("Window1"),
                             _T("Hello DirectX9 World !!"),
                             WS_OVERLAPPEDWINDOW,
                             CW_USEDEFAULT,
                             CW_USEDEFAULT,
                             windowWidth,
                             windowHeight,
                             NULL,
                             NULL,
                             windowClass.hInstance,
                             NULL);

    InitD3D(hWnd);
    ShowWindow(hWnd, SW_SHOWDEFAULT);
    UpdateWindow(hWnd);

    MSG message;
    while (true)
    {
        if (PeekMessage(&message, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&message);
            DispatchMessage(&message);
        }
        else
        {
            Sleep(16);
            Render();
        }

        if (g_shouldClose)
        {
            break;
        }
    }

    Cleanup();
    UnregisterClass(_T("Window1"), windowClass.hInstance);
    return 0;
}

/*
// -----------------------------------------------------------------------------
// D3D Init
// -----------------------------------------------------------------------------
static void InitD3D(HWND hWnd)
{
    HRESULT hResult = E_FAIL;

    g_pD3D = Direct3DCreate9(D3D_SDK_VERSION);
    assert(g_pD3D != NULL);

    D3DPRESENT_PARAMETERS presentParams = { 0 };
    presentParams.Windowed = TRUE;
    presentParams.SwapEffect = D3DSWAPEFFECT_DISCARD;
    presentParams.BackBufferFormat = D3DFMT_UNKNOWN;
    presentParams.BackBufferCount = 1;
    presentParams.MultiSampleType = D3DMULTISAMPLE_NONE;
    presentParams.MultiSampleQuality = 0;
    presentParams.EnableAutoDepthStencil = TRUE;
    presentParams.AutoDepthStencilFormat = D3DFMT_D16;
    presentParams.hDeviceWindow = hWnd;
    presentParams.PresentationInterval = D3DPRESENT_INTERVAL_DEFAULT;

    hResult = g_pD3D->CreateDevice(D3DADAPTER_DEFAULT,
                                   D3DDEVTYPE_HAL,
                                   hWnd,
                                   D3DCREATE_HARDWARE_VERTEXPROCESSING,
                                   &presentParams,
                                   &g_pD3dDevice);
    if (FAILED(hResult))
    {
        hResult = g_pD3D->CreateDevice(D3DADAPTER_DEFAULT,
                                       D3DDEVTYPE_HAL,
                                       hWnd,
                                       D3DCREATE_SOFTWARE_VERTEXPROCESSING,
                                       &presentParams,
                                       &g_pD3dDevice);
        assert(SUCCEEDED(hResult));
    }

    // Load mesh (materials & textures)
    LPD3DXBUFFER materialBuffer = NULL;
    hResult = D3DXLoadMeshFromX(_T("untitled.blend.x"),
                                D3DXMESH_SYSTEMMEM,
                                g_pD3dDevice,
                                NULL,
                                &materialBuffer,
                                NULL,
                                &g_numMaterials,
                                &g_pMesh);
    assert(SUCCEEDED(hResult));

    D3DXMATERIAL* materials = reinterpret_cast<D3DXMATERIAL*>(materialBuffer->GetBufferPointer());
    g_materials.resize(g_numMaterials);
    g_textures.resize(g_numMaterials);

    for (DWORD i = 0; i < g_numMaterials; ++i)
    {
        g_materials[i] = materials[i].MatD3D;
        g_materials[i].Ambient = g_materials[i].Diffuse;
        g_textures[i] = NULL;

        std::string texturePath;

        if (materials[i].pTextureFilename != nullptr)
        {
            texturePath = materials[i].pTextureFilename;
        }

        if (!texturePath.empty())
        {
            hResult = D3DXCreateTextureFromFileA(g_pD3dDevice, texturePath.c_str(), &g_textures[i]);
            assert(SUCCEEDED(hResult));
        }
    }
    materialBuffer->Release();

    // Parallax resources (normal / height)
    hResult = D3DXCreateTextureFromFileW(g_pD3dDevice, L"rocksNormal.png", &g_pNormalTex);
    assert(SUCCEEDED(hResult));

    hResult = D3DXCreateTextureFromFileW(g_pD3dDevice, L"rocksBump.png", &g_pHeightTex);
    assert(SUCCEEDED(hResult));

    // Effect
    hResult = D3DXCreateEffectFromFile(g_pD3dDevice,
                                       _T("simple.fx"),
                                       NULL,
                                       NULL,
                                       D3DXSHADER_DEBUG,
                                       NULL,
                                       &g_pEffect,
                                       NULL);
    assert(SUCCEEDED(hResult));
}
*/

// -----------------------------------------------------------------------------
// Cleanup
// -----------------------------------------------------------------------------
static void Cleanup()
{
    for (size_t i = 0; i < g_textures.size(); ++i)
    {
        SAFE_RELEASE(g_textures[i]);
    }

    SAFE_RELEASE(g_pNormalTex);
    SAFE_RELEASE(g_pHeightTex);
    SAFE_RELEASE(g_pMesh);
    SAFE_RELEASE(g_pEffect);
    SAFE_RELEASE(g_pD3dDevice);
    SAFE_RELEASE(g_pD3D);
}

static void AddTangentBinormalToMesh()
{
    assert(g_pMesh != NULL);

    // 1) SDKと同じ固定レイアウトでクローン（pos3, uv2, nrm3, tan3, bin3）
    const D3DVERTEXELEMENT9 declFixed[] =
    {
        { 0,  0, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_POSITION, 0 },
        { 0, 12, D3DDECLTYPE_FLOAT2, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 0 },
        { 0, 20, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_NORMAL,   0 },
        { 0, 32, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TANGENT,  0 },
        { 0, 44, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_BINORMAL, 0 },
        D3DDECL_END()
    };

    ID3DXMesh* pCloned = NULL;
    HRESULT hr = g_pMesh->CloneMesh(g_pMesh->GetOptions(), declFixed, g_pD3dDevice, &pCloned);
    assert(SUCCEEDED(hr));
    SAFE_RELEASE(g_pMesh);
    g_pMesh = pCloned;

    // 2) 必要なら法線を先に作る
    D3DVERTEXELEMENT9 oldDecl[MAX_FVF_DECL_SIZE] = {};
    BOOL hasNormal = FALSE;
    if (SUCCEEDED(g_pMesh->GetDeclaration(oldDecl)))
    {
        for (UINT i = 0; oldDecl[i].Stream != 0xFF; ++i)
        {
            if (oldDecl[i].Usage == D3DDECLUSAGE_NORMAL)
            {
                hasNormal = TRUE;
                break;
            }
        }
    }

    if (!hasNormal)
    {
        D3DXComputeNormals(g_pMesh, NULL);
    }

    // 3) 隣接情報
    std::vector<DWORD> adjacency(g_pMesh->GetNumFaces() * 3);
    hr = g_pMesh->GenerateAdjacency(1e-6f, adjacency.data());
    assert(SUCCEEDED(hr));

    // 4) Tangent / Binormal / Normal を計算（SDKのしきい値）
    ID3DXMesh* pOut = NULL;
    hr = D3DXComputeTangentFrameEx(g_pMesh,
                                   D3DDECLUSAGE_TEXCOORD, 0,   // 基準UV
                                   D3DDECLUSAGE_TANGENT,  0,   // 書き込み: Tangent
                                   D3DDECLUSAGE_BINORMAL, 0,   // 書き込み: Binormal
                                   D3DDECLUSAGE_NORMAL,   0,   // 書き込み: Normal（再計算も可）
                                   0,
                                   adjacency.data(),
                                   -1.01f, -0.01f, -1.01f,     // しきい値（SDK相当）
                                   &pOut, NULL);
    assert(SUCCEEDED(hr));

    SAFE_RELEASE(g_pMesh);
    g_pMesh = pOut;
}

static void InitD3D(HWND hWnd)
{
    HRESULT hResult = E_FAIL;

    g_pD3D = Direct3DCreate9(D3D_SDK_VERSION);
    assert(g_pD3D != NULL);

    D3DPRESENT_PARAMETERS presentParams = { 0 };
    presentParams.Windowed = TRUE;
    presentParams.SwapEffect = D3DSWAPEFFECT_DISCARD;
    presentParams.BackBufferFormat = D3DFMT_UNKNOWN;
    presentParams.BackBufferCount = 1;
    presentParams.MultiSampleType = D3DMULTISAMPLE_NONE;
    presentParams.MultiSampleQuality = 0;
    presentParams.EnableAutoDepthStencil = TRUE;
    presentParams.AutoDepthStencilFormat = D3DFMT_D16;
    presentParams.hDeviceWindow = hWnd;
    presentParams.PresentationInterval = D3DPRESENT_INTERVAL_DEFAULT;

    hResult = g_pD3D->CreateDevice(D3DADAPTER_DEFAULT,
                                   D3DDEVTYPE_HAL,
                                   hWnd,
                                   D3DCREATE_HARDWARE_VERTEXPROCESSING,
                                   &presentParams,
                                   &g_pD3dDevice);
    if (FAILED(hResult))
    {
        hResult = g_pD3D->CreateDevice(D3DADAPTER_DEFAULT,
                                       D3DDEVTYPE_HAL,
                                       hWnd,
                                       D3DCREATE_SOFTWARE_VERTEXPROCESSING,
                                       &presentParams,
                                       &g_pD3dDevice);
        assert(SUCCEEDED(hResult));
    }

    // メッシュ読込（マテリアル/テクスチャ）
    LPD3DXBUFFER materialBuffer = NULL;
    hResult = D3DXLoadMeshFromX(_T("untitled.blend.x"),
                                D3DXMESH_SYSTEMMEM,
                                g_pD3dDevice,
                                NULL,
                                &materialBuffer,
                                NULL,
                                &g_numMaterials,
                                &g_pMesh);
    assert(SUCCEEDED(hResult));

    D3DXMATERIAL* materials = reinterpret_cast<D3DXMATERIAL*>(materialBuffer->GetBufferPointer());
    g_materials.resize(g_numMaterials);
    g_textures.resize(g_numMaterials);

    for (DWORD i = 0; i < g_numMaterials; ++i)
    {
        g_materials[i] = materials[i].MatD3D;
        g_materials[i].Ambient = g_materials[i].Diffuse;
        g_textures[i] = NULL;

        std::string texturePath;
        if (materials[i].pTextureFilename != nullptr)
        {
            texturePath = materials[i].pTextureFilename;
        }
        if (!texturePath.empty())
        {
            hResult = D3DXCreateTextureFromFileA(g_pD3dDevice, texturePath.c_str(), &g_textures[i]);
            assert(SUCCEEDED(hResult));
        }
    }
    materialBuffer->Release();

    // ★ここで Tangent/Binormal を追加・生成（新規）
    AddTangentBinormalToMesh();

    // POM 用テクスチャ（法線 / 高さ）
    hResult = D3DXCreateTextureFromFileW(g_pD3dDevice, L"rocksNormal.png", &g_pNormalTex);
    assert(SUCCEEDED(hResult));
    hResult = D3DXCreateTextureFromFileW(g_pD3dDevice, L"rocksBump.png", &g_pHeightTex);
    assert(SUCCEEDED(hResult));

        // エフェクト
        hResult = D3DXCreateEffectFromFile(g_pD3dDevice,
                                           _T("simple.fx"),
                                           NULL,
                                           NULL,
                                           D3DXSHADER_DEBUG,
                                           NULL,
                                           &g_pEffect,
                                           NULL);
    assert(SUCCEEDED(hResult));
}

// -----------------------------------------------------------------------------
// Render  — simple.fx の定数名／テクスチャ名に完全対応
// -----------------------------------------------------------------------------
static void Render()
{
    HRESULT hr = E_FAIL;

    static float angleCamera = 0.0f;  angleCamera += 0.02f;
    static float angleLight  = 0.0f;  angleLight  += 0.02f;

    // 行列
    D3DXMATRIX mWorld, mView, mProj, mWVP;
    D3DXMatrixIdentity(&mWorld);

    D3DXMatrixPerspectiveFovLH(&mProj,
        D3DXToRadian(45.0f),
        float(WINDOW_SIZE_W) / float(WINDOW_SIZE_H),
        1.0f, 100.0f);

    D3DXVECTOR3 eye(3.0f * sinf(angleCamera), 2.0f, -3.0f * cosf(angleCamera));
    D3DXVECTOR3 at(0, 0, 0);
    D3DXVECTOR3 up(0, 1, 0);
    D3DXMatrixLookAtLH(&mView, &eye, &at, &up);

    mWVP = mWorld * mView * mProj;

    // クリア
    hr = g_pD3dDevice->Clear(0, NULL,
                              D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER,
                              D3DCOLOR_XRGB(100, 100, 100), 1.0f, 0);
    assert(SUCCEEDED(hr));
    hr = g_pD3dDevice->BeginScene();
    assert(SUCCEEDED(hr));

    // ===== simple.fx のパラメータ名でセット =====
    // 行列
    g_pEffect->SetMatrix("g_mWorldViewProj", &mWVP);
    g_pEffect->SetMatrix("g_mWorld",         &mWorld);

    // 視点（float4）
    D3DXVECTOR4 vEye(eye.x, eye.y, eye.z, 1.0f);
    g_pEffect->SetVector("g_vEye", &vEye);

    // 光方向（float3, 正規化）
    D3DXVECTOR3 lightDir(sinf(angleLight), 0.5f * sinf(angleLight), cosf(angleLight));
    D3DXVec3Normalize(&lightDir, &lightDir);
    g_pEffect->SetValue("g_LightDir", &lightDir, sizeof(D3DXVECTOR3));

    // マテリアル
    D3DXCOLOR colAmb(0.35f, 0.35f, 0.35f, 1.0f);
    D3DXCOLOR colDif(1, 1, 1, 1);
    D3DXCOLOR colSpc(1, 1, 1, 1);
    g_pEffect->SetValue("g_materialAmbientColor",  &colAmb, sizeof(D3DXCOLOR));
    g_pEffect->SetValue("g_materialDiffuseColor",  &colDif, sizeof(D3DXCOLOR));
    g_pEffect->SetValue("g_materialSpecularColor", &colSpc, sizeof(D3DXCOLOR));
    g_pEffect->SetFloat("g_fSpecularExponent", 60.0f);
    g_pEffect->SetBool ("g_bAddSpecular", TRUE);

    // POM パラメータ（simple.fx の名前に合わせる）
    g_pEffect->SetFloat("g_fBaseTextureRepeat", 1.0f); // 必要なら tiling を変更
    g_pEffect->SetFloat("g_fHeightMapScale",    0.1f); // 高さスケール（素材に合わせて調整）
    g_pEffect->SetInt  ("g_nMinSamples",        50);
    g_pEffect->SetInt  ("g_nMaxSamples",        50);

    // テクスチャ（simple.fx のスロット名に合わせる）
    g_pEffect->SetTexture("g_normalTexture", g_pNormalTex);
    g_pEffect->SetTexture("g_heightTexture", g_pHeightTex);

    // テクニック
    D3DXHANDLE hTech = g_pEffect->GetTechniqueByName("Technique0");
    g_pEffect->SetTechnique(hTech);

    UINT passes = 0;
    g_pEffect->Begin(&passes, 0);
    g_pEffect->BeginPass(0);

    // サブセットごとにベースカラーを設定して描画
    for (DWORD i = 0; i < g_numMaterials; ++i)
    {
        g_pEffect->SetTexture("g_baseTexture", g_textures[i]);
        g_pEffect->CommitChanges();
        g_pMesh->DrawSubset(i);
    }

    g_pEffect->EndPass();
    g_pEffect->End();

    g_pD3dDevice->EndScene();
    g_pD3dDevice->Present(NULL, NULL, NULL, NULL);
}

// -----------------------------------------------------------------------------
// Window Proc
// -----------------------------------------------------------------------------
static LRESULT WINAPI MsgProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg)
    {
    case WM_DESTROY:
    {
        PostQuitMessage(0);
        g_shouldClose = true;
        return 0;
    }
    }

    return DefWindowProc(hWnd, msg, wParam, lParam);
}
