// simple2.fx — Parallax Occlusion Mapping (POM)
// UTF-8 (no BOM)

//==================================================
// 行列・定数
//==================================================
float4x4 g_matWorldViewProj;
float4x4 g_matWorld;

float4 g_eyePos; // ワールド空間のカメラ位置
float4 g_lightDirWorld; // ワールド空間の「光線の向き」（Lambert では -g_lightDirWorld を使用）

// --- POM パラメータ ---
int g_pomMinSamples = 8; // 正面での層数（少なめ）
int g_pomMaxSamples = 24; // 斜め視での層数（多め）
int g_pomRefineSteps = 2; // 交差後のリファイン回数（0〜2 推奨）
float g_pomScale = 0.04f; // 視差スケール（大きすぎると破綻）

// 旧互換（未使用だが残置）
float g_parallaxScale = 0.04f;
float g_parallaxBias = -0.5f * 0.04f;

// 照明（拡散のみ）
float3 g_ambientColor = float3(0.25, 0.25, 0.25);
float3 g_lightColor = float3(1.50, 1.50, 1.50);
float g_diffuseGain = 2.0f;

// 法線テクスチャのエンコード方式（0=RGB、1=DXT5nm[A=nx,G=ny]）
float g_normalEncoding = 0.0;

// UV / Normal 反転トグル
float g_flipU = 0.0; // 1 で U 反転
float g_flipV = 0.0; // 1 で V 反転
float g_flipRed = 0.0; // 1 で法線 X 反転
float g_flipGreen = 0.0; // 1 で法線 Y 反転

// 追加：ハイト反転（0=白が山 / 1=反転）
float g_heightInvert = 1.0f;

// 安定化イプシロン（科学表記は使わない）
static const float g_parallaxEpsilon = 0.001f; // 分母の下限
static const float g_denominatorEpsilon = 0.00001f; // 0 除算回避

//==================================================
// テクスチャ
//==================================================
texture g_texColor;
texture g_texNormal; // 接空間法線（UV空間での法線）
texture g_texHeight; // 高さ (R)

sampler2D sColor
{
    Texture = <g_texColor>;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = LINEAR;
    AddressU = WRAP;
    AddressV = WRAP;
};

sampler2D sNormal
{
    Texture = <g_texNormal>;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = LINEAR;
    AddressU = WRAP;
    AddressV = WRAP;
};

sampler2D sHeight
{
    Texture = <g_texHeight>;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = LINEAR;
    AddressU = WRAP;
    AddressV = WRAP;
};

//==================================================
// ヘルパ
//==================================================
float SampleHeight(float2 sampleUV)
{
    float heightValue = tex2D(sHeight, sampleUV).r;

    if (g_heightInvert > 0.5f)
    {
        heightValue = 1.0f - heightValue;
    }

    return heightValue;
}

float3 DecodeNormal(float4 texel)
{
    float3 NormUV;

    if (g_normalEncoding > 0.5f)
    {
        float nx = texel.a * 2.0f - 1.0f;
        float ny = texel.g * 2.0f - 1.0f;

        if (g_flipRed > 0.5f)
        {
            nx = -nx;
        }
        if (g_flipGreen > 0.5f)
        {
            ny = -ny;
        }

        float nzSquared = 1.0f - nx * nx - ny * ny;
        float nz = sqrt(saturate(nzSquared));
        NormUV = float3(nx, ny, nz);
    }
    else
    {
        NormUV = texel.rgb * 2.0f - 1.0f;

        if (g_flipRed > 0.5f)
        {
            NormUV.x = -NormUV.x;
        }
        if (g_flipGreen > 0.5f)
        {
            NormUV.y = -NormUV.y;
        }
    }

    return normalize(NormUV);
}

//==================================================
// VS（in/out 形式）
// 出力: POSITION0, TEXCOORD0=WorldPos, TEXCOORD1=WorldNorm, TEXCOORD2=UV
//==================================================
void VS(float4 inPos : POSITION0,
        float3 inNormal : NORMAL0,
        float2 inUV : TEXCOORD0,

        out float4 outPos : POSITION0,
        out float3 outWorldPos : TEXCOORD0,
        out float3 outWorldNorm : TEXCOORD1,
        out float2 outUV : TEXCOORD2)
{
    outPos = mul(inPos, g_matWorldViewProj);
    outWorldPos = mul(inPos, g_matWorld).xyz;

    // 等方スケール前提（非等方スケールなら逆転置行列を使用）
    float3x3 world3x3 = (float3x3) g_matWorld;
    outWorldNorm = normalize(mul(inNormal, world3x3));

    outUV = inUV;
}

//==================================================
// TBN 構築（右手系を保証）— 三項演算子は使わず if/else
//==================================================
void BuildTBN(float3 positionWorld,
        float3 NormWorld,
        float2 baseUV,

        out float3 tangentVec,
        out float3 binormalVec,
        out float3 NormWorldUnit)
{
    float3 derivativePositionDX = ddx(positionWorld);
    float3 derivativePositionDY = ddy(positionWorld);
    float2 derivativeUVdx = ddx(baseUV);
    float2 derivativeUVdy = ddy(baseUV);

    float3 tangentRaw = derivativePositionDX * derivativeUVdy.y - derivativePositionDY * derivativeUVdx.y;
    float3 binormalRaw = derivativePositionDY * derivativeUVdx.x - derivativePositionDX * derivativeUVdy.x;

    NormWorldUnit = normalize(NormWorld);

    float3 tangentOrthogonal = tangentRaw - NormWorldUnit * dot(NormWorldUnit, tangentRaw);
    tangentVec = normalize(tangentOrthogonal);

    float3 binormalFromCross = normalize(cross(NormWorldUnit, tangentVec));
    float handednessCheck = dot(cross(NormWorldUnit, tangentVec), normalize(binormalRaw));

    if (handednessCheck < 0.0f)
    {
        binormalVec = -binormalFromCross;
    }
    else
    {
        binormalVec = binormalFromCross;
    }
}

//==================================================
// POM — UV オフセット計算（固定回数ループ + 早期 break）
//==================================================
static const int POM_MAX_STEPS_CONST = 24; // コンパイル時定数（命令数管理）
static const int POM_REFINE_STEPS_CONST = 2; // 0〜2

float2 ComputeParallaxOcclusionOffset(float2 baseUV,
        float3 viewDirectionUV)
{
    float3 viewDirectionUVUnit = normalize(viewDirectionUV);
    float viewDirectionZAbs = abs(viewDirectionUVUnit.z);

    if (viewDirectionZAbs < g_parallaxEpsilon)
    {
        viewDirectionZAbs = g_parallaxEpsilon;
    }

    // 視角依存の目標ステップ数（斜め視ほど増やす）
    float desiredStepCountFloat = lerp((float) g_pomMinSamples, (float) g_pomMaxSamples, 1.0f - saturate(viewDirectionZAbs));
    int desiredStepCount = (int) (desiredStepCountFloat + 0.5f);

    if (desiredStepCount < 1)
    {
        desiredStepCount = 1;
    }
    if (desiredStepCount > POM_MAX_STEPS_CONST)
    {
        desiredStepCount = POM_MAX_STEPS_CONST;
    }

    float2 parallaxDirection = (viewDirectionUVUnit.xy / viewDirectionZAbs) * g_pomScale;
    float2 uvStepPerLayer = parallaxDirection / (float) desiredStepCount;

    float currentLayerHeight = 1.0f;
    float layerHeightStep = 1.0f / (float) desiredStepCount;

    float2 currentUV = baseUV;
    float2 previousUV = baseUV;

    float currentSampledHeight = SampleHeight(currentUV);

    [unroll(POM_MAX_STEPS_CONST)]
    for (int stepIndex = 0; stepIndex < POM_MAX_STEPS_CONST; stepIndex++)
    {
        if (stepIndex >= desiredStepCount)
        {
            break;
        }

        if (currentSampledHeight >= currentLayerHeight)
        {
            break;
        }

        previousUV = currentUV;
        currentUV += uvStepPerLayer;
        currentLayerHeight -= layerHeightStep;
        currentSampledHeight = SampleHeight(currentUV);
    }

    // 交差点近傍の線形リファイン（固定回数）
    [unroll(POM_REFINE_STEPS_CONST)]
    for (int refineIndex = 0; refineIndex < POM_REFINE_STEPS_CONST; refineIndex++)
    {
        float previousSampledHeight = SampleHeight(previousUV);
        float denominator = currentSampledHeight - previousSampledHeight;

        float interpolationT = 0.5f;
        if (abs(denominator) > g_denominatorEpsilon)
        {
            interpolationT = saturate((currentLayerHeight - previousSampledHeight) / denominator);
        }

        float2 refinedUV = lerp(previousUV, currentUV, interpolationT);

        currentUV = refinedUV;
        currentSampledHeight = SampleHeight(currentUV);
        previousUV = lerp(previousUV, currentUV, 0.5f);
    }

    return currentUV; // Address=WRAP のためそのまま返す
}

//==================================================
// PS（in/out 形式）
//==================================================
float4 PS_ParallaxOcclusion(float3 inWorldPos : TEXCOORD0,
        float3 inWorldNorm : TEXCOORD1,
        float2 inUV : TEXCOORD2) : COLOR0
{
    float2 baseUV = inUV;

    // UV 反転
    if (g_flipU > 0.5f)
    {
        baseUV.x = 1.0f - baseUV.x;
    }
    if (g_flipV > 0.5f)
    {
        baseUV.y = 1.0f - baseUV.y;
    }

    // TBN とビュー方向（UV 空間）
    float3 tangentVec;
    float3 binormalVec;
    float3 NormWorldUnit;
    BuildTBN(inWorldPos, inWorldNorm, baseUV, tangentVec, binormalVec, NormWorldUnit);

    float3x3 tangentBasisMatrix = float3x3(tangentVec, binormalVec, NormWorldUnit);

    float3 viewDirectionWorld = g_eyePos.xyz - inWorldPos;
    float3 viewDirectionUV = normalize(mul(viewDirectionWorld, transpose(tangentBasisMatrix)));

    // --- POM でオフセットした UV ---
    float2 parallaxedUV = ComputeParallaxOcclusionOffset(baseUV, viewDirectionUV);

    // サンプリング
    float3 albedoColor = tex2D(sColor, parallaxedUV).rgb;
    float4 normalTexel = tex2D(sNormal, parallaxedUV);
    float3 NormUV = DecodeNormal(normalTexel);
    float3 NormWorldFromMap = normalize(mul(NormUV, tangentBasisMatrix));

    // Lambert 拡散（g_lightDirWorld は「光線の向き」なので - を取る）
    float3 lightDirectionWorld = normalize(g_lightDirWorld.xyz);
    float NdL = saturate(dot(NormWorldFromMap, -lightDirectionWorld));
    float3 diffuseTerm = g_lightColor * (NdL * g_diffuseGain);

    float3 finalColor = albedoColor * (g_ambientColor + diffuseTerm);
    return float4(saturate(finalColor), 1.0f);
}

//==================================================
// Technique
//==================================================
technique Technique_ParallaxOcclusion
{
    pass P0
    {
        VertexShader = compile vs_3_0 VS();
        PixelShader = compile ps_3_0 PS_ParallaxOcclusion();
    }
}