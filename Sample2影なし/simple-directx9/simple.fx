//------------------------------------------------------------
// 視差遮蔽マッピング
// (Parallax Occlusion Mapping)
//------------------------------------------------------------

texture g_baseTexture; // ベースカラー（アルベド）テクスチャ
texture g_normalTexture; // 法線マップテクスチャ
texture g_heightTexture; // 高さマップテクスチャ

float4 g_materialAmbientColor; // マテリアルの環境色
float4 g_materialDiffuseColor; // マテリアルの拡散反射色
float4 g_materialSpecularColor; // マテリアルの鏡面反射色

float g_fSpecularExponent; // 鏡面ハイライトの指数
bool g_bAddSpecular; // 鏡面成分を有効化するかどうか

// 光源パラメータ:
float3 g_LightDir; // 光の方向（ワールド空間）
float4 g_LightDiffuse; // 光の拡散色
float4 g_LightAmbient; // 光の環境色

float4 g_vEye; // カメラ位置
float g_fBaseTextureRepeat; // ベース／法線テクスチャのタイリング係数
float g_fHeightMapScale; // 高さマップの有効な値域（スケール）を表す

// 行列:
float4x4 g_mWorld; // オブジェクトのワールド行列
float4x4 g_mWorldViewProj; // World * View * Projection 行列

int g_nMinSamples = 50; // 高さプロファイルをサンプリングする最小サンプル数
int g_nMaxSamples = 50; // 高さプロファイルをサンプリングする最大サンプル数

//--------------------------------------------------------------------------------------
// テクスチャサンプラ
//--------------------------------------------------------------------------------------
sampler tBase =
sampler_state
{
    Texture = <g_baseTexture>;
    MipFilter = LINEAR;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
};

sampler normalMapSampler =
sampler_state
{
    Texture = <g_normalTexture>;
    MipFilter = LINEAR;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
};

sampler heightMapSampler =
sampler_state
{
    Texture = <g_heightTexture>;
    MipFilter = LINEAR;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
};

//--------------------------------------------------------------------------------------
// 頂点シェーダ出力構造体
//--------------------------------------------------------------------------------------
struct VS_OUTPUT
{
    float4 position : POSITION;
    float2 texCoord : TEXCOORD0;
    float3 vLightTS : TEXCOORD1; // 接空間の光ベクトル（正規化していない）
    float3 vViewTS : TEXCOORD2; // 接空間の視線ベクトル（正規化していない）
    float2 vParallaxOffsetTS : TEXCOORD3; // 接空間での視差オフセットベクトル
    float3 vNormalWS : TEXCOORD4; // ワールド空間の法線
    float3 vViewWS : TEXCOORD5; // ワールド空間の視線ベクトル
};

// 末尾のOSはObjectSpace = ローカル座標空間の意味
// 末尾のTSはTangentSpace = 接空間の意味
VS_OUTPUT VS(float4 inPositionOS  : POSITION,
             float2 inTexCoord    : TEXCOORD0,
             float3 vInNormalOS   : NORMAL,
             float3 vInBinormalOS : BINORMAL,
             float3 vInTangentOS  : TANGENT)
{
    VS_OUTPUT Out;

    Out.position = mul(inPositionOS, g_mWorldViewProj);
    Out.texCoord = inTexCoord * g_fBaseTextureRepeat;

    float3 vNormalWS = mul(vInNormalOS, (float3x3) g_mWorld);
    float3 vTangentWS = mul(vInTangentOS, (float3x3) g_mWorld);
    float3 vBinormalWS = mul(vInBinormalOS, (float3x3) g_mWorld);

    Out.vNormalWS = vNormalWS;

    vNormalWS = normalize(vNormalWS);
    vTangentWS = normalize(vTangentWS);
    vBinormalWS = normalize(vBinormalWS);

    float4 vPositionWS = mul(inPositionOS, g_mWorld);

    float3 vViewWS = g_vEye.xyz - vPositionWS.xyz;
    Out.vViewWS = vViewWS;

    // 光源ベクトル（正規化しない）
    float3 vLightWS = g_LightDir;

    // 光源ベクトル・カメラ方向ベクトルを接空間へ変換
    float3x3 mWorldToTangent = float3x3(vTangentWS, vBinormalWS, vNormalWS);

    Out.vLightTS = mul(mWorldToTangent, vLightWS);
    Out.vViewTS = mul(mWorldToTangent, vViewWS);

    // ズレ量
    // グレージング角なら沢山ズレるし、正面を向いてるならズレない。
    // それを表す数値
    Out.vParallaxOffsetTS = Out.vViewTS.xy / Out.vViewTS.z;

    Out.vParallaxOffsetTS *= g_fHeightMapScale;

    return Out;
}

//--------------------------------------------------------------------------------------
// ピクセルシェーダ出力構造体
//--------------------------------------------------------------------------------------

struct PS_INPUT
{
    float2 texCoord : TEXCOORD0;
    float3 vLightTS : TEXCOORD1; // 接空間の光ベクトル（正規化していない）
    float3 vViewTS : TEXCOORD2; // 接空間の視線ベクトル（正規化していない）
    float2 vParallaxOffsetTS : TEXCOORD3; // 接空間での視差オフセット
    float3 vNormalWS : TEXCOORD4; // ワールド空間の法線
    float3 vViewWS : TEXCOORD5; // ワールド空間の視線ベクトル
};

float4 ComputeIllumination(float2 texCoord, float3 vLightTS, float3 vViewTS);

//--------------------------------------------------------------------------------------
// 視差遮蔽マッピング（POM）のピクセルシェーダ
//--------------------------------------------------------------------------------------
float4 PS(PS_INPUT i) : COLOR0
{
    float4 cResultColor = float4(0, 0, 0, 1);

    float3 vViewTS = normalize(i.vViewTS);
    float3 vViewWS = normalize(i.vViewWS);
    float3 vLightTS = normalize(i.vLightTS);
    float3 vNormalWS = normalize(i.vNormalWS);

    // まずは入力のテクスチャ座標でサンプル（=バンプマップ相当）
    float2 texSample = i.texCoord;

    // 視角に応じてサンプル数を変更。
    // グレージング角であるほどステップを細かくして精度を上げる。
    int nNumSteps = (int) lerp(g_nMaxSamples, g_nMinSamples, dot(vViewWS, vNormalWS));

    float fStepSize = 1.0 / (float) nNumSteps;
    int nStepIndex = 0;

    float fCurrHeight = 0.0;

    float2 vTexOffsetPerStep = fStepSize * i.vParallaxOffsetTS;
    float2 vTexCurrentOffset = i.texCoord;

    // 今どの深さの層（Layer）までレイを進めたか
    float fCurrentLayer = 1.0;

    while (nStepIndex < nNumSteps)
    {
        vTexCurrentOffset -= vTexOffsetPerStep;

        // tex2Dgrad関数を使うとPIX For Windowsが落ちる
        // fCurrHeight = tex2Dgrad( tNormalHeightMap, vTexCurrentOffset, dx, dy ).a;
        //fCurrHeight = tex2Dlod(tNormalHeightMap, float4(vTexCurrentOffset, 0.0f, 0.0f)).a;
        fCurrHeight = tex2Dlod(heightMapSampler, float4(vTexCurrentOffset, 0.0f, 0.0f)).r;

        fCurrentLayer -= fStepSize;

        if (fCurrHeight > fCurrentLayer)
        {
            break;
        }

        nStepIndex++;
    }

    float2 vParallaxOffset = i.vParallaxOffsetTS * (1 - fCurrentLayer);

    // 疑似的に押し出された表面上の最終テクスチャ座標
    float2 texSampleBase = i.texCoord - vParallaxOffset;
    texSample = texSampleBase;

    // ライトをちゃんとやるか否か
    if (true)
    {
        cResultColor = ComputeIllumination(texSample, vLightTS, vViewTS);
    }
    else
    {
        cResultColor = tex2D(tBase, texSample);
    }

    return cResultColor;
}

//--------------------------------------------------------------------------------------
// 関数:    ComputeIllumination
//
// 説明:    指定ピクセルの属性テクスチャと光ベクトルを用いて
//          Phong 風の照明を計算する
//--------------------------------------------------------------------------------------
float4 ComputeIllumination(float2 texCoord, float3 vLightTS, float3 vViewTS)
{
    // 法線マップから法線（接空間）をサンプルして正規化
    float3 vNormalTS = normalize(tex2D(normalMapSampler, texCoord) * 2 - 1).xyz;

    // ベースカラーをサンプル
    float4 cBaseColor = tex2D(tBase, texCoord);

    // 拡散反射成分を計算
    float3 vLightTSAdj = float3(vLightTS.x, -vLightTS.y, vLightTS.z);

    float4 cDiffuse = saturate(dot(vNormalTS, vLightTSAdj)) * g_materialDiffuseColor;

    // 必要であれば鏡面成分を計算
    float4 cSpecular = 0;
    if (g_bAddSpecular)
    {
        float3 vReflectionTS = normalize(2 * dot(vViewTS, vNormalTS) * vNormalTS - vViewTS);

        float fRdotL = saturate(dot(vReflectionTS, vLightTSAdj));
        cSpecular = saturate(pow(fRdotL, g_fSpecularExponent)) * g_materialSpecularColor;
    }

    // 最終色を合成
    float4 cFinalColor = (g_materialAmbientColor + cDiffuse) * cBaseColor + cSpecular;

    return cFinalColor;
}

technique Technique0
{
    pass P0
    {
        VertexShader = compile vs_3_0 VS();
        PixelShader = compile ps_3_0 PS();
    }
}

