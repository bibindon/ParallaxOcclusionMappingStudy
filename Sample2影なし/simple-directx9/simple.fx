// simple.fx — Parallax Occlusion Mapping (POM)
// Vertex Tangent/Binormal version
// - Always-on POM (no LOD/mip gating)
// - No self-shadow term, no specular term
// - in/out parameter style, no one-letter variables, no scientific-notation literals
// - "TS" naming replaced with "UV"
// UTF-8 (no BOM)

//==================================================
// Matrices & constants
//==================================================
float4x4 g_matWorldViewProj;
float4x4 g_matWorld;

float4 g_eyePos; // world-space eye position
float4 g_lightDirWorld; // world-space light ray direction (Lambert uses -g_lightDirWorld)

// --- POM parameters ---
int g_pomMinSamples = 24; // Steps at near-normal view
int g_pomMaxSamples = 48; // Steps at grazing view
int g_pomRefineSteps = 2; // Linear refinement iterations (0..2)
float g_pomScale = 0.04f; // Parallax height scale

// Lighting (diffuse only)
float3 g_ambientColor = float3(0.25, 0.25, 0.25);
float3 g_lightColor = float3(1.00, 1.00, 1.00);
float g_diffuseGain = 1.0f;

// Normal encoding (0 = RGB, 1 = DXT5nm: A=Nx, G=Ny)
float g_normalEncoding = 0.0f;

// UV / Normal flips
float g_flipU = 0.0f; // 1 -> flip U
float g_flipV = 0.0f; // 1 -> flip V
float g_flipRed = 0.0f; // 1 -> flip normal.x
float g_flipGreen = 0.0f; // 1 -> flip normal.y

// Height polarity (0 = white is high / 1 = invert)
float g_heightInvert = 0.0f;

// Stability epsilons (no scientific notation)
static const float g_parallaxEpsilon = 0.001f; // min abs(z) when projecting
static const float g_denominatorEpsilon = 0.00001f; // avoid divide-by-zero in refinement

//==================================================
// Textures
//==================================================
texture g_texColor;
texture g_texNormal; // tangent-space normal map
texture g_texHeight; // height (R)

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
// Helpers
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

float3 DecodeNormal(float4 sampledTexel)
{
    float3 NormUV;

    if (g_normalEncoding > 0.5f)
    {
        float normalX = sampledTexel.a * 2.0f - 1.0f;
        float normalY = sampledTexel.g * 2.0f - 1.0f;

        if (g_flipRed > 0.5f)
        {
            normalX = -normalX;
        }
        if (g_flipGreen > 0.5f)
        {
            normalY = -normalY;
        }

        float normalZSquared = 1.0f - normalX * normalX - normalY * normalY;
        float normalZ = sqrt(saturate(normalZSquared));
        NormUV = float3(normalX, normalY, normalZ);
    }
    else
    {
        NormUV = sampledTexel.rgb * 2.0f - 1.0f;

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
// Vertex Shader (in/out parameters)
//   Input includes TANGENT0 and BINORMAL0 from the mesh
//   Output: POSITION0, TEXCOORD0=WorldPos, TEXCOORD1=WorldNorm,
//           TEXCOORD2=UV, TEXCOORD3=WorldTan, TEXCOORD4=WorldBin
//==================================================
void VS(float4 inPos : POSITION0,
        float3 inNormal : NORMAL0,
        float2 inUV : TEXCOORD0,
        float3 inTangent : TANGENT0,
        float3 inBinormal : BINORMAL0,

        out float4 outPos : POSITION0,
        out float3 outWorldPos : TEXCOORD0,
        out float3 outWorldNorm : TEXCOORD1,
        out float2 outUV : TEXCOORD2,
        out float3 outWorldTan : TEXCOORD3,
        out float3 outWorldBin : TEXCOORD4)
{
    outPos = mul(inPos, g_matWorldViewProj);
    outWorldPos = mul(inPos, g_matWorld).xyz;

    float3x3 world3x3 = (float3x3) g_matWorld; // uniform scale assumed

    outWorldNorm = normalize(mul(inNormal, world3x3));
    outWorldTan = normalize(mul(inTangent, world3x3));
    outWorldBin = normalize(mul(inBinormal, world3x3));

    // Re-orthogonalize to keep a stable right-handed basis
    outWorldTan = normalize(outWorldTan - outWorldNorm * dot(outWorldNorm, outWorldTan));

    float3 binormalFromCross = normalize(cross(outWorldNorm, outWorldTan));
    float handednessCheck = dot(cross(outWorldNorm, outWorldTan), outWorldBin);
    if (handednessCheck < 0.0f)
    {
        outWorldBin = -binormalFromCross;
    }
    else
    {
        outWorldBin = binormalFromCross;
    }

    outUV = inUV;
}

//==================================================
// Parallax Occlusion Mapping — UV offset computation
// Fixed upper bound loop with early exits; linear refinement
//==================================================
static const int POM_MAX_STEPS_CONST = 48; // compile-time cap
static const int POM_REFINE_STEPS_CONST = 2; // 0..2

float2 ComputeParallaxOcclusionOffset(float2 baseUV,
        float3 viewDirectionUV)
{
    float3 viewDirectionUVUnit = normalize(viewDirectionUV);
    float viewDirectionZAbs = abs(viewDirectionUVUnit.z);

    if (viewDirectionZAbs < g_parallaxEpsilon)
    {
        viewDirectionZAbs = g_parallaxEpsilon;
    }

    // Angle-dependent step count (more steps for grazing views)
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

    // Linear refinement around the hit
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

    return currentUV; // Address WRAP/MIRROR recommended
}

//==================================================
// Pixel Shader (in/out parameters)
//==================================================
float4 PS_ParallaxOcclusion(float3 inWorldPos : TEXCOORD0,
        float3 inWorldNorm : TEXCOORD1,
        float2 inUV : TEXCOORD2,
        float3 inWorldTan : TEXCOORD3,
        float3 inWorldBin : TEXCOORD4) : COLOR0
{
    float2 baseUV = inUV;

    if (g_flipU > 0.5f)
    {
        baseUV.x = 1.0f - baseUV.x;
    }
    if (g_flipV > 0.5f)
    {
        baseUV.y = 1.0f - baseUV.y;
    }

    // TBN from vertex data (world space)
    float3x3 tangentBasisMatrix = float3x3(inWorldTan, inWorldBin, inWorldNorm);

    float3 viewDirectionWorld = g_eyePos.xyz - inWorldPos;
    float3 viewDirectionUV = normalize(mul(viewDirectionWorld, transpose(tangentBasisMatrix)));

    // Compute parallaxed UV with POM
    float2 parallaxedUV = ComputeParallaxOcclusionOffset(baseUV, viewDirectionUV);

    // Sample textures
    float3 albedoColor = tex2D(sColor, parallaxedUV).rgb;
    float4 normalTexel = tex2D(sNormal, parallaxedUV);
    float3 NormUV = DecodeNormal(normalTexel);
    float3 NormWorldFromMap = normalize(mul(NormUV, tangentBasisMatrix));

    // Diffuse-only lighting (no specular, no shadow/occlusion)
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
