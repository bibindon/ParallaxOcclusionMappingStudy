// simple.fx — Parallax Mapping (RGB または DXT5nm 法線対応)
// UTF-8 (no BOM)

//==============================
// 行列・定数
//==============================
float4x4 g_matWorldViewProj;
float4x4 g_matWorld;

float4 g_eyePos; // world
float4 g_lightDirWorld; // world の「光線の向き」。Lambert では -L を使用

// Parallax
float g_parallaxScale = 0.04f; // 0.02〜0.06 程度で調整
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
// TBN 構築（右手系を保証）
//==============================
void BuildTBN(float3 P, float3 N, float2 uv, out float3 T, out float3 B, out float3 Nn)
{
    float3 dp1 = ddx(P);
    float3 dp2 = ddy(P);
    float2 du1 = ddx(uv);
    float2 du2 = ddy(uv);

    float3 tRaw = dp1 * du2.y - dp2 * du1.y;
    float3 bRaw = dp2 * du1.x - dp1 * du2.x;

    Nn = normalize(N);
    T = normalize(tRaw - Nn * dot(Nn, tRaw)); // N に直交化
    float sign = (dot(cross(Nn, T), normalize(bRaw)) < 0.0) ? -1.0 : 1.0;
    B = normalize(cross(Nn, T)) * sign; // 右手系を維持
}

//==============================
// 法線デコード
//   g_normalEncoding=0: RGB (rgb*2-1)
//   g_normalEncoding=1: DXT5nm (A=nx, G=ny, z は再構成)
//==============================
float3 DecodeNormal(float4 t)
{
    float3 n;
    if (g_normalEncoding > 0.5)
    {
        float nx = t.a * 2.0 - 1.0;
        float ny = t.g * 2.0 - 1.0;
        nx = lerp(nx, -nx, saturate(g_flipRed));
        ny = lerp(ny, -ny, saturate(g_flipGreen));
        float nz = sqrt(saturate(1.0 - nx * nx - ny * ny));
        n = float3(nx, ny, nz);
    }
    else
    {
        n = t.rgb * 2.0 - 1.0;
        n.x = lerp(n.x, -n.x, saturate(g_flipRed));
        n.y = lerp(n.y, -n.y, saturate(g_flipGreen));
    }
    return normalize(n);
}

//==============================
// PS
//==============================
float4 PS(VSOut i) : COLOR
{
    // UV 反転
    float2 baseUV;
    baseUV.x = lerp(i.uv.x, 1.0 - i.uv.x, saturate(g_flipU));
    baseUV.y = lerp(i.uv.y, 1.0 - i.uv.y, saturate(g_flipV));

    // TBN と view（tangent space）
    float3 T, B, Nw;
    BuildTBN(i.wp, i.wn, baseUV, T, B, Nw);
    float3x3 TBN = float3x3(T, B, Nw);

    float3 Vw = g_eyePos.xyz - i.wp;
    float3 Vts = normalize(mul(Vw, transpose(TBN)));

    // Parallax UV オフセット
    float h = tex2D(sHeight, baseUV).r;
    float2 uvP = baseUV + (h * g_parallaxScale + g_parallaxBias) * (Vts.xy / max(abs(Vts.z), 1e-3));

    // サンプル
    float3 albedo = tex2D(sColor, uvP).rgb;
    float4 nTex = tex2D(sNormal, uvP);
    float3 nTS = DecodeNormal(nTex);
    float3 nW = normalize(mul(nTS, TBN));

    // Lambert（光線の向き Lw に対して -Lw を使用）
    float3 Lw = normalize(g_lightDirWorld.xyz);
    float NdotL = saturate(dot(nW, -Lw));
    float3 diff = g_lightColor * (NdotL * g_diffuseGain);

    float3 color = albedo * (g_ambientColor + diff);
    return float4(saturate(color), 1.0);
}

//==============================
// Technique
//==============================
technique Technique_Parallax
{
    pass P0
    {
        VertexShader = compile vs_3_0 VS();
        PixelShader = compile ps_3_0 PS();
    }
}
