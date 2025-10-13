// simple.fx — Parallax Occlusion Mapping（POM）
// UTF-8 (no BOM)

//==============================
// 行列・定数
//==============================
float4x4 g_matWorldViewProj;
float4x4 g_matWorld;

float4 g_eyePos; // world
float4 g_lightDirWorld; // world の「光線の向き」。Lambert では -L を使用

// --- POM パラメータ ---
int g_pomMinSamples = 8; // 正面での層数（少なめ）
int g_pomMaxSamples = 24; // 斜め視での層数（多め）
int g_pomRefineSteps = 1; // 交差後の線形リファイン回数（0〜2 推奨）
float g_pomScale = 0.04f; // 視差スケール（大きすぎると破綻）

// 互換：従来の変数（未使用だが残置）
float g_parallaxScale = 0.04f;
float g_parallaxBias = -0.5f * 0.04f;

// 照明（拡散のみ）
float3 g_ambientColor = float3(0.25, 0.25, 0.25);
float3 g_lightColor = float3(1.5, 1.5, 1.5);
float g_diffuseGain = 2.0;

// 法線テクスチャのエンコード方式（0=RGB、1=DXT5nm[A=nx,G=ny]）
float g_normalEncoding = 0.0;

// UV/Normal 反転トグル
float g_flipU = 0.0; // 1 で U 反転
float g_flipV = 0.0; // 1 で V 反転
float g_flipRed = 0.0; // 1 で法線 X 反転
float g_flipGreen = 0.0; // 1 で法線 Y 反転

//==============================
// テクスチャ
//==============================
texture g_texColor;
texture g_texNormal; // tangent-space normal
texture g_texHeight; // height (R)

sampler2D sColor = sampler_state
{
    Texture = <g_texColor>;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = LINEAR;
    AddressU = WRAP;
    AddressV = WRAP;
};
sampler2D sNormal = sampler_state
{
    Texture = <g_texNormal>;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = LINEAR;
    AddressU = WRAP;
    AddressV = WRAP;
};
sampler2D sHeight = sampler_state
{
    Texture = <g_texHeight>;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = LINEAR;
    AddressU = WRAP;
    AddressV = WRAP;
};

// 追加：エフェクト定数
float g_heightInvert = 1.0f; // 0=白が山(デフォルト), 1=反転

float SampleHeight(float2 uv)
{
    float h = tex2D(sHeight, uv).r;
    if (g_heightInvert > 0.5f)
    {
        h = 1.0f - h;
    }
    return h;
}

//==============================
// 頂点 I/O
//==============================
struct VSIn
{
    float4 pos : POSITION;
    float3 normal : NORMAL0;
    float2 uv : TEXCOORD0;
};

struct VSOut
{
    float4 pos : POSITION;
    float3 wp : TEXCOORD0; // world position
    float3 wn : TEXCOORD1; // world normal
    float2 uv : TEXCOORD2;
};

//==============================
// VS
//==============================
VSOut VS(VSIn v)
{
    VSOut o;
    o.pos = mul(v.pos, g_matWorldViewProj);
    o.wp = mul(v.pos, g_matWorld).xyz;

    // 等方スケール前提（非等方スケールなら逆転置行列を使用）
    o.wn = normalize(mul(v.normal, (float3x3) g_matWorld));
    o.uv = v.uv;
    return o;
}

//==============================
// TBN 構築（右手系を保証）— 三項演算子は使わず if/else
//==============================
void BuildTBN(float3 positionWorld,
              float3 normalWorld,
              float2 texCoord,
              out float3 tangent,
              out float3 bitangent,
              out float3 normalUnit)
{
    float3 dpdx = ddx(positionWorld);
    float3 dpdy = ddy(positionWorld);
    float2 dudx = ddx(texCoord);
    float2 dudy = ddy(texCoord);

    float3 tangentRaw = dpdx * dudy.y - dpdy * dudx.y;
    float3 bitanRaw = dpdy * dudx.x - dpdx * dudy.x;

    normalUnit = normalize(normalWorld);

    float3 tangentOrtho = tangentRaw - normalUnit * dot(normalUnit, tangentRaw);
    tangent = normalize(tangentOrtho);

    float3 bitanFromCross = normalize(cross(normalUnit, tangent));
    float handednessCheck = dot(cross(normalUnit, tangent), normalize(bitanRaw));

    if (handednessCheck < 0.0f)
    {
        bitangent = -bitanFromCross;
    }
    else
    {
        bitangent = bitanFromCross;
    }
}

//==============================
// 法線デコード
//==============================
float3 DecodeNormal(float4 nTexel)
{
    float3 normalTs;

    if (g_normalEncoding > 0.5f)
    {
        float nx = nTexel.a * 2.0f - 1.0f;
        float ny = nTexel.g * 2.0f - 1.0f;

        if (g_flipRed > 0.5f)
            nx = -nx;
        if (g_flipGreen > 0.5f)
            ny = -ny;

        float nz2 = 1.0f - nx * nx - ny * ny;
        float nz = sqrt(saturate(nz2));
        normalTs = float3(nx, ny, nz);
    }
    else
    {
        normalTs = nTexel.rgb * 2.0f - 1.0f;

        if (g_flipRed > 0.5f)
            normalTs.x = -normalTs.x;
        if (g_flipGreen > 0.5f)
            normalTs.y = -normalTs.y;
    }

    return normalize(normalTs);
}
// ループ回数はコンパイル時定数に固定（SM2.0向け）
static const int POM_MAX_STEPS = 24; // 12〜24 で調整
static const int POM_REFINE_STEPS = 1; // 0〜2

float2 ParallaxOcclusionOffset(float2 baseUv, float3 viewTs)
{
    float3 viewDir = normalize(viewTs);
    float viewZ = max(abs(viewDir.z), 1e-3f);

    // 斜め視ほど多く。ここは実行時に変わってOK（ループ回数は固定なので安全）
    float desiredStepsF = lerp((float) g_pomMinSamples, (float) g_pomMaxSamples, 1.0f - saturate(viewZ));
    int desiredSteps = (int) (desiredStepsF + 0.5f);

    if (desiredSteps < 1)
    {
        desiredSteps = 1;
    }
    if (desiredSteps > POM_MAX_STEPS)
    {
        desiredSteps = POM_MAX_STEPS;
    }

    float2 parallaxDir = (viewDir.xy / viewZ) * g_pomScale;
    float2 uvStep = parallaxDir / (float) desiredSteps;

    float layerHeight = 1.0f;
    float layerStep = 1.0f / (float) desiredSteps;

    float2 currentUv = baseUv;
    float2 previousUv = baseUv;

    float currentHeight = SampleHeight(currentUv);

    // 固定回数で回して中でbreak（SM2.0でもOK）
    [unroll(POM_MAX_STEPS)]
    for (int i = 0; i < POM_MAX_STEPS; i++)
    {
        if (i >= desiredSteps)
        {
            break;
        }
        if (currentHeight >= layerHeight)
        {
            break;
        }

        previousUv = currentUv;
        currentUv += uvStep;
        layerHeight -= layerStep;
        currentHeight = SampleHeight(currentUv);
    }

    // 交差点の簡易リファイン（固定回数）
    [unroll(POM_REFINE_STEPS)]
    for (int r = 0; r < POM_REFINE_STEPS; r++)
    {
        float previousHeight = tex2D(sHeight, previousUv).r;
        float denominator = currentHeight - previousHeight;

        float t = 0.5f;
        if (abs(denominator) > 1e-5f)
        {
            t = saturate((layerHeight - previousHeight) / denominator);
        }

        float2 refinedUv = lerp(previousUv, currentUv, t);

        currentUv = refinedUv;
        currentHeight = tex2D(sHeight, currentUv).r;
        previousUv = lerp(previousUv, currentUv, 0.5f);
    }

    return frac(currentUv);
}

//==============================
// PS
//==============================
float4 PS_POM(VSOut i) : COLOR
{
    // UV 反転
    float2 baseUv;
    baseUv.x = lerp(i.uv.x, 1.0f - i.uv.x, saturate(g_flipU));
    baseUv.y = lerp(i.uv.y, 1.0f - i.uv.y, saturate(g_flipV));

    // TBN と view（tangent space）
    float3 tangent, bitangent, normalWorldUnit;
    BuildTBN(i.wp, i.wn, baseUv, tangent, bitangent, normalWorldUnit);
    float3x3 tbn = float3x3(tangent, bitangent, normalWorldUnit);

    float3 viewWorld = g_eyePos.xyz - i.wp;
    float3 viewTs = normalize(mul(viewWorld, transpose(tbn)));

    // --- POM UV ---
    float2 uvParallax = ParallaxOcclusionOffset(baseUv, viewTs);

    // サンプル
    float3 albedo = tex2D(sColor, uvParallax).rgb;
    float4 nTex = tex2D(sNormal, uvParallax);
    float3 nTs = DecodeNormal(nTex);
    float3 nW = normalize(mul(nTs, tbn));

    // Lambert（光線の向き Lw に対して -Lw を使用）
    float3 lightWorld = normalize(g_lightDirWorld.xyz);
    float ndotl = saturate(dot(nW, lightWorld));
    float3 diffuse = g_lightColor * (ndotl * g_diffuseGain);

    float3 color = albedo * (g_ambientColor + diffuse);
    return float4(saturate(color), 1.0f);
}

//==============================
// Technique
//==============================
technique Technique_ParallaxOcclusion
{
    pass P0
    {
        VertexShader = compile vs_3_0 VS();
        PixelShader = compile ps_3_0 PS_POM();
    }
}

//（互換：元のTechnique名を残したい場合はここに旧PSを置く）
