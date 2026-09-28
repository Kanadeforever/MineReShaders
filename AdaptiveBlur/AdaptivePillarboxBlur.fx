// AdaptivePillarboxBlur.fx
// 版本：v1.0.0
//
// 用途：
//   用游戏图像的实时、镜像、模糊扩展来填充左右黑边，
//   同时保持中央内容区域不受影响。
//
// 设计：
//   - 显示/后台缓冲区宽高比始终自动检测。
//   - 游戏/内容宽高比独立选择。
//   - 1/4 分辨率的可分离高斯模糊，以获得良好的 4K 性能。
//   - 无需外部纹理。
//
// SPDX-License-Identifier: MIT

#include "ReShade.fxh"

#define APB_DOWNSAMPLE 8

// -----------------------------------------------------------------------------
// 用户界面
// -----------------------------------------------------------------------------

uniform int APB_ContentAspectPreset <
    ui_type = "combo";
    ui_label = "游戏内容宽高比";
    ui_items = "4:3\0"
               "5:4\0"
               "3:2\0"
               "16:10\0"
               "16:9\0"
               "自定义\0";
    ui_tooltip =
        "中央实际游戏画面的宽高比。\n"
        "显示器 / BackBuffer 的宽高比会自动检测。";
    ui_category = "1. 几何设置";
> = 0;

uniform float APB_CustomContentAspect <
    ui_type = "slider";
    ui_label = "自定义内容宽高比";
    ui_min = 1.0;
    ui_max = 4.0;
    ui_step = 0.001;
    ui_tooltip =
        "仅当“游戏内容宽高比”设为“自定义”时生效。\n"
        "示例：1.333 = 4:3，1.25 = 5:4，1.6 = 16:10。";
    ui_category = "1. 几何设置";
> = 1.3333333;

uniform float APB_SideZoom <
    ui_type = "slider";
    ui_label = "两侧取样缩放";
    ui_min = 0.50;
    ui_max = 2.50;
    ui_step = 0.01;
    ui_tooltip =
        "控制两侧延伸背景从中央画面取样的范围。\n"
        "1.00 大致保持 1:1 的空间尺度。\n"
        "数值越高，越偏向放大靠近画面边缘的内容。";
    ui_category = "1. 几何设置";
> = 1.00;

uniform float APB_BlurStrength <
    ui_type = "slider";
    ui_label = "模糊强度";
    ui_min = 0.0;
    ui_max = 100.0;
    ui_step = 1.0;
    ui_tooltip =
        "控制左右动态背景的真正高斯模糊强度。\n"
        "内部使用按标准差 σ 实时计算权重的完整对称高斯核，\n"
        "不是通过放大采样间距模拟模糊。";
    ui_category = "2. 外观设置";
> = 55.0;

uniform float APB_Brightness <
    ui_type = "slider";
    ui_label = "两侧亮度";
    ui_min = 0.20;
    ui_max = 1.20;
    ui_step = 0.01;
    ui_tooltip = "调整左右模糊背景的亮度。";
    ui_category = "2. 外观设置";
> = 0.70;

uniform float APB_Saturation <
    ui_type = "slider";
    ui_label = "两侧饱和度";
    ui_min = 0.0;
    ui_max = 1.50;
    ui_step = 0.01;
    ui_tooltip = "调整左右模糊背景的色彩饱和度。";
    ui_category = "2. 外观设置";
> = 0.85;

uniform float APB_EdgeFeather <
    ui_type = "slider";
    ui_label = "边缘过渡宽度";
    ui_min = 0.0;
    ui_max = 128.0;
    ui_step = 1.0;
    ui_tooltip =
        "控制中央清晰画面边缘到两侧模糊背景之间的过渡宽度。\n"
        "数值按 2160p 像素尺度标定，并会随输出高度自动缩放。";
    ui_category = "2. 外观设置";
> = 24.0;

uniform float APB_FillOpacity <
    ui_type = "slider";
    ui_label = "两侧填充不透明度";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip =
        "1.00 = 完全覆盖原本的左右黑边。\n"
        "降低数值会与原黑边区域的像素混合。";
    ui_category = "2. 外观设置";
> = 1.0;

uniform bool APB_DebugMask <
    ui_label = "显示计算出的两侧遮罩";
    ui_tooltip =
        "将自动计算出的左右遮罩区域显示为洋红色。\n"
        "用于确认当前选择的游戏内容宽高比是否正确。";
    ui_category = "3. 诊断";
> = false;


// -----------------------------------------------------------------------------
// 中间纹理
// -----------------------------------------------------------------------------

texture APB_DownsampleTex < pooled = true; >
{
    Width = BUFFER_WIDTH / APB_DOWNSAMPLE;
    Height = BUFFER_HEIGHT / APB_DOWNSAMPLE;
    Format = RGBA16F;
};

texture APB_BlurHTex < pooled = true; >
{
    Width = BUFFER_WIDTH / APB_DOWNSAMPLE;
    Height = BUFFER_HEIGHT / APB_DOWNSAMPLE;
    Format = RGBA16F;
};

texture APB_BlurVTex < pooled = true; >
{
    Width = BUFFER_WIDTH / APB_DOWNSAMPLE;
    Height = BUFFER_HEIGHT / APB_DOWNSAMPLE;
    Format = RGBA16F;
};

sampler APB_DownsampleSampler
{
    Texture = APB_DownsampleTex;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Point;
};

sampler APB_BlurHSampler
{
    Texture = APB_BlurHTex;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Point;
};

sampler APB_BlurVSampler
{
    Texture = APB_BlurVTex;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Point;
};


// -----------------------------------------------------------------------------
// 几何辅助工具
// -----------------------------------------------------------------------------

float APB_GetContentAspect()
{
    if (APB_ContentAspectPreset == 0) return 4.0 / 3.0;
    if (APB_ContentAspectPreset == 1) return 5.0 / 4.0;
    if (APB_ContentAspectPreset == 2) return 3.0 / 2.0;
    if (APB_ContentAspectPreset == 3) return 16.0 / 10.0;
    if (APB_ContentAspectPreset == 4) return 16.0 / 9.0;
    return max(APB_CustomContentAspect, 0.01);
}

void APB_GetContentBounds(out float left, out float right, out float width)
{
    const float displayAspect = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;
    const float contentAspect = APB_GetContentAspect();

    // 如果显示器不比所请求的内容比例更宽，就没有需要
    // 填充的柱状黑边区域，因此该效果会变成一次干净的空操作。
    width = min(1.0, contentAspect / displayAspect);
    left = (1.0 - width) * 0.5;
    right = 1.0 - left;
}

float APB_TriangleWave(float x)
{
    // 每两个单位，0 -> 1 -> 0。
    // 这使非常宽的显示器能够继续自然地镜像源
    // 而不是钳制到单一拉伸的边缘颜色。
    return 1.0 - abs(frac(x * 0.5) * 2.0 - 1.0);
}

float2 APB_MapSideToSource(float2 uv, float left, float right, float contentWidth)
{
    float distFromEdge;
    float sourceOffset;

    if (uv.x < left)
    {
        distFromEdge = left - uv.x;
        float travel = distFromEdge / max(APB_SideZoom, 0.01);
        sourceOffset = contentWidth * APB_TriangleWave(travel / max(contentWidth, 1e-6));
        uv.x = left + sourceOffset;
    }
    else if (uv.x > right)
    {
        distFromEdge = uv.x - right;
        float travel = distFromEdge / max(APB_SideZoom, 0.01);
        sourceOffset = contentWidth * APB_TriangleWave(travel / max(contentWidth, 1e-6));
        uv.x = right - sourceOffset;
    }

    uv.x = clamp(uv.x, left, right);
    uv.y = saturate(uv.y);
    return uv;
}

float APB_ClampContentX(float x, float left, float right)
{
    // 将双线性采样点保持在内容边界内侧半个低分辨率纹素处
    // 以免黑色左右黑边像素渗入模糊中。
    float guard = 0.5 * APB_DOWNSAMPLE * BUFFER_RCP_WIDTH;
    guard = min(guard, max((right - left) * 0.499, 0.0));
    return clamp(x, left + guard, right - guard);
}


// -----------------------------------------------------------------------------
// 第 1 遍：8 倍下采样
// -----------------------------------------------------------------------------

float4 APB_DownsamplePS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    // 四次双线性采样可以在真正的高斯模糊之前提供一种廉价的预滤波。
    const float2 o = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

    float4 c = 0.0;
    c += tex2D(ReShade::BackBuffer, uv + float2(-o.x, -o.y));
    c += tex2D(ReShade::BackBuffer, uv + float2( o.x, -o.y));
    c += tex2D(ReShade::BackBuffer, uv + float2(-o.x,  o.y));
    c += tex2D(ReShade::BackBuffer, uv + float2( o.x,  o.y));
    return c * 0.25;
}


// -----------------------------------------------------------------------------
// 第 2/3 遍：真正的可分离高斯模糊
//
// 这是真正的高斯卷积：
//   weight(x) = exp(-(x*x) / (2*sigma*sigma))
//
// 在每个方向上计算一个完整对称核，并用实际累积的权重进行归一化。
// 模糊在 1/8 分辨率的图像上执行，以便在保持非常平滑结果的同时，
// 让 4K/5K/8K 的性能仍然实用。
// -----------------------------------------------------------------------------

#define APB_GAUSSIAN_RADIUS 32

float APB_GetGaussianSigma()
{
    // BlurStrength 0..100 -> sigma 0.35..12.0（在 2160p 下）。
    // 随分辨率平缓缩放，使感知模糊大体保持一致，
    // 同时不允许有限核截断得过于严重。
    float t = saturate(APB_BlurStrength / 100.0);
    float sigma2160 = lerp(0.35, 12.0, t);
    float resolutionScale = sqrt(max(BUFFER_HEIGHT / 2160.0, 0.25));
    return sigma2160 * resolutionScale;
}

float APB_GaussianWeight(float x, float sigma)
{
    float s2 = max(sigma * sigma, 1e-6);
    return exp(-(x * x) / (2.0 * s2));
}

float4 APB_BlurHPS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float left, right, contentWidth;
    APB_GetContentBounds(left, right, contentWidth);

    // 精确无模糊路径。
    if (APB_BlurStrength <= 0.001)
        return tex2D(APB_DownsampleSampler, uv);

    float sigma = APB_GetGaussianSigma();
    float texelX = APB_DOWNSAMPLE * BUFFER_RCP_WIDTH;

    float4 sum = 0.0;
    float weightSum = 0.0;

    [unroll]
    for (int i = -APB_GAUSSIAN_RADIUS; i <= APB_GAUSSIAN_RADIUS; ++i)
    {
        float fi = float(i);
        float w = APB_GaussianWeight(fi, sigma);
        float sx = APB_ClampContentX(uv.x + fi * texelX, left, right);

        sum += tex2D(APB_DownsampleSampler, float2(sx, uv.y)) * w;
        weightSum += w;
    }

    return sum / max(weightSum, 1e-6);
}

float4 APB_BlurVPS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (APB_BlurStrength <= 0.001)
        return tex2D(APB_BlurHSampler, uv);

    float sigma = APB_GetGaussianSigma();
    float texelY = APB_DOWNSAMPLE * BUFFER_RCP_HEIGHT;

    float4 sum = 0.0;
    float weightSum = 0.0;

    [unroll]
    for (int i = -APB_GAUSSIAN_RADIUS; i <= APB_GAUSSIAN_RADIUS; ++i)
    {
        float fi = float(i);
        float w = APB_GaussianWeight(fi, sigma);
        float sy = saturate(uv.y + fi * texelY);

        sum += tex2D(APB_BlurHSampler, float2(uv.x, sy)) * w;
        weightSum += w;
    }

    return sum / max(weightSum, 1e-6);
}


// -----------------------------------------------------------------------------
// 最终合成
// -----------------------------------------------------------------------------

float3 APB_StyleSide(float3 color)
{
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = lerp(luma.xxx, color, APB_Saturation);
    color *= APB_Brightness;
    return color;
}

float4 APB_CompositePS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 original = tex2D(ReShade::BackBuffer, uv);

    float left, right, contentWidth;
    APB_GetContentBounds(left, right, contentWidth);

    const float displayAspect = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;
    const float contentAspect = APB_GetContentAspect();

    // 在等于或窄于所选内容比例的显示器上，
    // 不会出现左右黑边。
    if (displayAspect <= contentAspect + 1e-5)
        return original;

    bool isSide = (uv.x < left) || (uv.x > right);

    // 中心游戏图像从当前后台缓冲区采样路径逐字节返回，
    // 并且在此处不进行任何颜色/模糊处理。
    if (!isSide)
        return original;

    if (APB_DebugMask)
        return float4(1.0, 0.0, 1.0, 1.0);

    float2 sourceUV = APB_MapSideToSource(uv, left, right, contentWidth);

    // 在紧贴内容边界处使用清晰的镜像源，以避免出现可见接缝。
    // 越往栏内延伸，我们便过渡为模糊。
    float4 sharpSource = tex2D(ReShade::BackBuffer, sourceUV);
    float4 blurredSource = tex2D(APB_BlurVSampler, sourceUV);

    float3 styledBlur;
    if (APB_BlurStrength <= 0.001)
        styledBlur = APB_StyleSide(sharpSource.rgb);
    else
        styledBlur = APB_StyleSide(blurredSource.rgb);

    float distFromEdge = (uv.x < left) ? (left - uv.x) : (uv.x - right);

    // EdgeTransition 在 2160p 下以像素为单位进行校准，并随高度缩放。
    float featherPx = APB_EdgeFeather * (BUFFER_HEIGHT / 2160.0);
    float featherUV = featherPx * BUFFER_RCP_WIDTH;

    float transition = (featherUV > 1e-7)
        ? smoothstep(0.0, featherUV, distFromEdge)
        : 1.0;

    // 精确的内边缘与游戏图像保持视觉连续；
    // 亮度/饱和度/模糊在羽化区域内渐入。
    float3 sideRGB = lerp(sharpSource.rgb, styledBlur, transition);
    float4 side = float4(sideRGB, original.a);

    return lerp(original, side, APB_FillOpacity);
}


// -----------------------------------------------------------------------------
// 技巧
// -----------------------------------------------------------------------------

technique AdaptivePillarboxBlur <
    ui_label = "自适应左右动态模糊";
    ui_tooltip =
        "在任何比游戏内容更宽的显示器 / BackBuffer 上，\n"
        "自动使用中央游戏画面的实时镜像模糊延伸填充左右黑边。";
>
{
    pass Downsample
    {
        VertexShader = PostProcessVS;
        PixelShader = APB_DownsamplePS;
        RenderTarget = APB_DownsampleTex;
    }

    pass BlurHorizontal
    {
        VertexShader = PostProcessVS;
        PixelShader = APB_BlurHPS;
        RenderTarget = APB_BlurHTex;
    }

    pass BlurVertical
    {
        VertexShader = PostProcessVS;
        PixelShader = APB_BlurVPS;
        RenderTarget = APB_BlurVTex;
    }

    pass Composite
    {
        VertexShader = PostProcessVS;
        PixelShader = APB_CompositePS;
    }
}
