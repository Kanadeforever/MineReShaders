/*
    Retro2D.fx
    v1.0

    用途：
      面向 4K / 5K / 8K 显示器上的 1990 年代末～2000 年代 2D 游戏。
      目标不是完整 CRT 模拟，而是：
        1) 以“逻辑源分辨率”为基准重建低分辨率 2D 画面；
        2) 加入亮度相关扫描束；
        3) 可选极轻的 RGB 栅罩；
        4) 不加入曲面、黑边、暗角、Halation、Bloom、色散和噪点。

    设计参考：
      CRT EasyMode by EasyMode（GPL）
      本实现为 ReShade FX 的独立重写/适配，重点解决 ReShade 只能看到最终 BackBuffer、
      无法直接获得 cnc-ddraw / RetroArch 那种原始低分辨率 Source Texture 的问题。

    重要限制：
      ReShade 无法恢复在它之前已经被有损缩放丢失的信息。
      “源分辨率”应填写游戏实际逻辑画面分辨率（常见 640x480 / 800x600 / 1024x768），
      而不是最终 4K BackBuffer 分辨率。

    许可证：
      GNU 通用公共许可证 (GPL)，遵循此着色器所使用的 EasyMode 衍生重建/扫描线概念的许可要求。
*/

#include "ReShade.fxh"

#define R2D_PI      3.14159265358979323846
#define R2D_TWO_PI  6.28318530717958647692

sampler R2D_BackBufferPoint
{
    Texture = ReShade::BackBufferTex;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Point;
    MagFilter = Point;
    MipFilter = Point;
    SRGBTexture = false;
};

sampler R2D_BackBufferLinear
{
    Texture = ReShade::BackBufferTex;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Point;
    SRGBTexture = false;
};

uniform int R2D_SourcePreset <
    ui_type = "combo";
    ui_label = "逻辑源分辨率";
    ui_items =
        "320 x 200\0"
        "320 x 240\0"
        "400 x 300\0"
        "512 x 384\0"
        "640 x 400\0"
        "640 x 480（推荐起点）\0"
        "720 x 480\0"
        "720 x 576\0"
        "800 x 600\0"
        "1024 x 576\0"
        "1024 x 768\0"
        "1152 x 648\0"
        "1152 x 864\0"
        "1280 x 720\0"
        "1280 x 768\0"
        "1280 x 800\0"
        "1280 x 960\0"
        "1280 x 1024\0"
        "1360 x 768\0"
        "1366 x 768\0"
        "1440 x 900\0"
        "1600 x 900\0"
        "1680 x 1050\0"
        "1920 x 1080\0"
        "自定义\0";
    ui_tooltip =
        "选择游戏在被放大到 4K 之前的逻辑画面分辨率。\n"
        "这不是显示器分辨率。2000 年前后 PC 2D 游戏最常见的是 640x480 / 800x600。";
    ui_category = "1. 源画面";
> = 5;

uniform int R2D_CustomSourceWidth <
    ui_type = "slider";
    ui_label = "自定义源宽度";
    ui_min = 160;
    ui_max = 2560;
    ui_step = 1;
    ui_tooltip = "仅在“逻辑源分辨率 = 自定义”时使用。";
    ui_category = "1. 源画面";
> = 640;

uniform int R2D_CustomSourceHeight <
    ui_type = "slider";
    ui_label = "自定义源高度";
    ui_min = 120;
    ui_max = 1600;
    ui_step = 1;
    ui_tooltip = "仅在“逻辑源分辨率 = 自定义”时使用。";
    ui_category = "1. 源画面";
> = 480;

uniform int R2D_ContentAreaMode <
    ui_type = "combo";
    ui_label = "内容区域";
    ui_items =
        "整个 BackBuffer\0"
        "按源分辨率宽高比居中（推荐）\0"
        "按自定义宽高比居中\0";
    ui_tooltip =
        "如果 4:3 游戏在 16:9 屏幕中左右留黑边，使用“按源分辨率宽高比居中”。\n"
        "如果游戏已经被拉伸到整个屏幕，则使用“整个 BackBuffer”。\n"
        "本 Shader 不会主动制造 CRT 黑框。";
    ui_category = "1. 源画面";
> = 1;

uniform float R2D_CustomAspect <
    ui_type = "slider";
    ui_label = "自定义内容宽高比";
    ui_min = 1.0;
    ui_max = 2.5;
    ui_step = 0.001;
    ui_tooltip = "仅在“内容区域 = 按自定义宽高比居中”时使用。4:3 = 1.333333，16:9 = 1.777778。";
    ui_category = "1. 源画面";
> = 1.333333;

uniform int R2D_SourceSampling <
    ui_type = "combo";
    ui_label = "回读 BackBuffer 采样";
    ui_items =
        "Point（更硬）\0"
        "Linear（推荐）\0";
    ui_tooltip =
        "ReShade 看到的是已经放大后的 BackBuffer。\n"
        "Linear 通常更适合从非整数缩放后的 4K 画面回读逻辑像素中心；\n"
        "如果原游戏已经使用整数/最近邻缩放，可试 Point。";
    ui_category = "1. 源画面";
> = 1;

uniform bool R2D_HighQualityReconstruction <
    ui_label = "高质量 Lanczos 式横向重建";
    ui_tooltip =
        "开启：每条源扫描行使用 4 个横向采样点，轮廓更接近 cnc-ddraw 的 CRT EasyMode。\n"
        "关闭：使用较轻量的双线性式重建。";
    ui_category = "2. 2D 图像重建";
> = true;

uniform float R2D_SharpnessH <
    ui_type = "slider";
    ui_label = "水平锐度";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "控制逻辑像素之间的水平重建曲线。0 更平滑，1 更接近硬像素。";
    ui_category = "2. 2D 图像重建";
> = 0.50;

uniform float R2D_SharpnessV <
    ui_type = "slider";
    ui_label = "垂直锐度";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "控制相邻源扫描行之间的垂直重建。默认 1.0 可保持较清晰的 2D 线稿。";
    ui_category = "2. 2D 图像重建";
> = 1.00;

uniform float R2D_Dilation <
    ui_type = "slider";
    ui_label = "边缘凝聚";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip =
        "在重建前调整像素混合域，可让老式 2D 线稿更凝练。\n"
        "1.0 接近 EasyMode 的默认行为；若觉得深色轮廓过重可降低。";
    ui_category = "2. 2D 图像重建";
> = 1.00;

uniform float R2D_ScanlineStrength <
    ui_type = "slider";
    ui_label = "扫描线强度";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip =
        "扫描线绑定“逻辑源分辨率”，而不是 4K 输出像素。\n"
        "因此 640x480 游戏在 4K 下仍然按 480 条源扫描行生成扫描束。";
    ui_category = "3. 扫描束";
> = 1.00;

uniform float R2D_BeamWidthMin <
    ui_type = "slider";
    ui_label = "扫描束宽度 - 最小";
    ui_min = 0.50;
    ui_max = 5.00;
    ui_step = 0.05;
    ui_tooltip = "数值越大，暗缝越窄；默认 1.50 接近 EasyMode。";
    ui_category = "3. 扫描束";
> = 1.50;

uniform float R2D_BeamWidthMax <
    ui_type = "slider";
    ui_label = "扫描束宽度 - 最大";
    ui_min = 0.50;
    ui_max = 5.00;
    ui_step = 0.05;
    ui_tooltip = "亮部可使用更宽的电子束。与最小值相同即可获得稳定、干净的扫描线。";
    ui_category = "3. 扫描束";
> = 1.50;

uniform float R2D_ScanBrightMin <
    ui_type = "slider";
    ui_label = "暗部扫描线亮度下限";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "防止暗部扫描线彻底压黑。";
    ui_category = "3. 扫描束";
> = 0.35;

uniform float R2D_ScanBrightMax <
    ui_type = "slider";
    ui_label = "亮部扫描线亮度上限";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "亮区域会自动减轻扫描线压暗，避免白色 UI 和人物高光被切得过重。";
    ui_category = "3. 扫描束";
> = 0.65;

uniform float R2D_ScanlinePhase <
    ui_type = "slider";
    ui_label = "扫描线相位";
    ui_min = -0.50;
    ui_max = 0.50;
    ui_step = 0.01;
    ui_tooltip = "用于微调扫描线和逻辑像素中心的垂直对齐。通常保持 0。";
    ui_category = "3. 扫描束";
> = 0.00;

uniform bool R2D_AutoFadeHighResScanlines <
    ui_label = "高源分辨率自动减弱扫描线";
    ui_tooltip =
        "对接近 1000p 以上的逻辑源画面自动减弱扫描线，避免高线数素材出现过密纹理。\n"
        "640/480、800/600、1024/768 基本不受影响。";
    ui_category = "3. 扫描束";
> = true;

uniform int R2D_MaskType <
    ui_type = "combo";
    ui_label = "栅罩类型";
    ui_items =
        "关闭（推荐默认）\0"
        "RGB Aperture Grille\0"
        "RGB Staggered Mask\0";
    ui_tooltip =
        "栅罩默认关闭，以避免 CRT_Lite 那种明显的 RGB 网格污染。\n"
        "4K 原生显示时可尝试开启，并把强度控制在 0.05～0.15。";
    ui_category = "4. 栅罩（可选）";
> = 0;

uniform float R2D_MaskStrength <
    ui_type = "slider";
    ui_label = "栅罩强度";
    ui_min = 0.0;
    ui_max = 0.50;
    ui_step = 0.01;
    ui_tooltip = "建议 4K 下从 0.05～0.12 开始。";
    ui_category = "4. 栅罩（可选）";
> = 0.08;

uniform float R2D_MaskScale <
    ui_type = "slider";
    ui_label = "栅罩尺寸";
    ui_min = 1.0;
    ui_max = 6.0;
    ui_step = 1.0;
    ui_tooltip = "每个 RGB 子栅格占用的输出像素尺寸。4K 通常使用 1。";
    ui_category = "4. 栅罩（可选）";
> = 1.0;

uniform bool R2D_AutoScaleMaskFor8K <
    ui_label = "8K 自动放大栅罩";
    ui_tooltip = "输出高度接近 4320 时自动把栅罩物理尺寸约放大一倍，避免 8K 下细得看不见。";
    ui_category = "4. 栅罩（可选）";
> = true;

uniform bool R2D_MaskBrightnessCompensation <
    ui_label = "栅罩亮度补偿";
    ui_tooltip = "对 RGB 栅罩造成的平均亮度损失做近似补偿。";
    ui_category = "4. 栅罩（可选）";
> = true;

uniform float R2D_GammaInput <
    ui_type = "slider";
    ui_label = "输入 Gamma";
    ui_min = 1.0;
    ui_max = 3.0;
    ui_step = 0.01;
    ui_tooltip = "EasyMode 风格默认值为 2.0。";
    ui_category = "5. 色调与输出";
> = 2.00;

uniform float R2D_GammaOutput <
    ui_type = "slider";
    ui_label = "输出 Gamma";
    ui_min = 1.0;
    ui_max = 3.0;
    ui_step = 0.01;
    ui_tooltip =
        "默认 1.80 会略微提亮中间调，接近 EasyMode 的观感。\n"
        "如果希望更忠实于原画，可提高到 2.0～2.2。";
    ui_category = "5. 色调与输出";
> = 1.80;

uniform float R2D_Brightness <
    ui_type = "slider";
    ui_label = "整体亮度补偿";
    ui_min = 0.80;
    ui_max = 1.40;
    ui_step = 0.01;
    ui_tooltip =
        "仅用于补偿扫描线造成的亮度下降，不产生 Bloom/Halation。\n"
        "本 Shader 默认比原版 EasyMode 更克制，避免白色 UI 过曝。";
    ui_category = "5. 色调与输出";
> = 1.08;

uniform float R2D_EffectStrength <
    ui_type = "slider";
    ui_label = "整体效果强度";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "0 = 原始 BackBuffer，1 = 完整 Retro2D 效果。便于 A/B 对比。";
    ui_category = "5. 色调与输出";
> = 1.00;

float2 R2D_GetSourceSize()
{
    if (R2D_SourcePreset == 0)  return float2(320.0, 200.0);
    if (R2D_SourcePreset == 1)  return float2(320.0, 240.0);
    if (R2D_SourcePreset == 2)  return float2(400.0, 300.0);
    if (R2D_SourcePreset == 3)  return float2(512.0, 384.0);
    if (R2D_SourcePreset == 4)  return float2(640.0, 400.0);
    if (R2D_SourcePreset == 5)  return float2(640.0, 480.0);
    if (R2D_SourcePreset == 6)  return float2(720.0, 480.0);
    if (R2D_SourcePreset == 7)  return float2(720.0, 576.0);
    if (R2D_SourcePreset == 8)  return float2(800.0, 600.0);
    if (R2D_SourcePreset == 9)  return float2(1024.0, 576.0);
    if (R2D_SourcePreset == 10) return float2(1024.0, 768.0);
    if (R2D_SourcePreset == 11) return float2(1152.0, 648.0);
    if (R2D_SourcePreset == 12) return float2(1152.0, 864.0);
    if (R2D_SourcePreset == 13) return float2(1280.0, 720.0);
    if (R2D_SourcePreset == 14) return float2(1280.0, 768.0);
    if (R2D_SourcePreset == 15) return float2(1280.0, 800.0);
    if (R2D_SourcePreset == 16) return float2(1280.0, 960.0);
    if (R2D_SourcePreset == 17) return float2(1280.0, 1024.0);
    if (R2D_SourcePreset == 18) return float2(1360.0, 768.0);
    if (R2D_SourcePreset == 19) return float2(1366.0, 768.0);
    if (R2D_SourcePreset == 20) return float2(1440.0, 900.0);
    if (R2D_SourcePreset == 21) return float2(1600.0, 900.0);
    if (R2D_SourcePreset == 22) return float2(1680.0, 1050.0);
    if (R2D_SourcePreset == 23) return float2(1920.0, 1080.0);

    return max(float2(R2D_CustomSourceWidth, R2D_CustomSourceHeight), float2(1.0, 1.0));
}

void R2D_GetViewport(float2 sourceSize, out float2 viewportMin, out float2 viewportSize)
{
    viewportMin = float2(0.0, 0.0);
    viewportSize = float2(1.0, 1.0);

    if (R2D_ContentAreaMode == 0)
        return;

    float outputAspect = BUFFER_WIDTH * 1.0 / BUFFER_HEIGHT;
    float targetAspect = sourceSize.x / sourceSize.y;

    if (R2D_ContentAreaMode == 2)
        targetAspect = max(R2D_CustomAspect, 0.01);

    if (outputAspect > targetAspect)
    {
        viewportSize.x = targetAspect / outputAspect;
        viewportMin.x = (1.0 - viewportSize.x) * 0.5;
    }
    else
    {
        viewportSize.y = outputAspect / targetAspect;
        viewportMin.y = (1.0 - viewportSize.y) * 0.5;
    }
}

float3 R2D_ReadBackBuffer(float2 uv)
{
    uv = saturate(uv);

    if (R2D_SourceSampling == 0)
        return tex2D(R2D_BackBufferPoint, uv).rgb;

    return tex2D(R2D_BackBufferLinear, uv).rgb;
}

float3 R2D_ReadLogicalTap(float2 logicalUV, float2 viewportMin, float2 viewportSize)
{
    logicalUV = saturate(logicalUV);
    float2 uv = viewportMin + logicalUV * viewportSize;
    float3 c = R2D_ReadBackBuffer(uv);

    return c * lerp(float3(1.0, 1.0, 1.0), c, R2D_Dilation);
}

float R2D_CurveDistance(float x, float sharpness)
{
    float side = step(0.5, x);
    float d = x - side;
    float rootTerm = sqrt(max(0.0, 0.25 - d * d));
    float curved = 0.5 - rootTerm * sign(0.5 - x);
    return lerp(x, curved, saturate(sharpness));
}

float4 R2D_LanczosWeights(float x)
{
    float4 p = R2D_PI * float4(1.0 + x, x, 1.0 - x, 2.0 - x);
    float4 safeP = max(abs(p), float4(1e-5, 1e-5, 1e-5, 1e-5));
    float4 w = (2.0 * sin(p) * sin(0.5 * p)) / (safeP * safeP);

    float sumW = dot(w, float4(1.0, 1.0, 1.0, 1.0));
    if (abs(sumW) < 1e-5)
        return float4(0.0, 1.0, 0.0, 0.0);

    return w / sumW;
}

float3 R2D_ReconstructRow(
    float2 rowCenter,
    float2 dx,
    float curveX,
    float2 viewportMin,
    float2 viewportSize)
{
    if (!R2D_HighQualityReconstruction)
    {
        float3 a = R2D_ReadLogicalTap(rowCenter, viewportMin, viewportSize);
        float3 b = R2D_ReadLogicalTap(rowCenter + dx, viewportMin, viewportSize);
        return lerp(a, b, curveX);
    }

    float4 w = R2D_LanczosWeights(curveX);

    float3 s0 = R2D_ReadLogicalTap(rowCenter - dx,       viewportMin, viewportSize);
    float3 s1 = R2D_ReadLogicalTap(rowCenter,            viewportMin, viewportSize);
    float3 s2 = R2D_ReadLogicalTap(rowCenter + dx,       viewportMin, viewportSize);
    float3 s3 = R2D_ReadLogicalTap(rowCenter + 2.0 * dx, viewportMin, viewportSize);

    float3 c = s0 * w.x + s1 * w.y + s2 * w.z + s3 * w.w;

    return clamp(c, min(s1, s2), max(s1, s2));
}

float3 R2D_Reconstruct2D(
    float2 localUV,
    float2 sourceSize,
    float2 viewportMin,
    float2 viewportSize)
{
    float2 sourcePixel = localUV * sourceSize - float2(0.5, 0.5);
    float2 basePixel = floor(sourcePixel);
    float2 subPixel = frac(sourcePixel);

    float2 invSource = 1.0 / sourceSize;
    float2 baseCenter = (basePixel + float2(0.5, 0.5)) * invSource;
    float2 dx = float2(invSource.x, 0.0);
    float2 dy = float2(0.0, invSource.y);

    float curveX_HQ = R2D_CurveDistance(subPixel.x, R2D_SharpnessH * R2D_SharpnessH);
    float curveX_LQ = R2D_CurveDistance(subPixel.x, R2D_SharpnessH);
    float curveX = R2D_HighQualityReconstruction ? curveX_HQ : curveX_LQ;

    float3 row0 = R2D_ReconstructRow(baseCenter,      dx, curveX, viewportMin, viewportSize);
    float3 row1 = R2D_ReconstructRow(baseCenter + dy, dx, curveX, viewportMin, viewportSize);

    float curveY = R2D_CurveDistance(subPixel.y, R2D_SharpnessV);
    float3 color = lerp(row0, row1, curveY);

    float exponentIn = R2D_GammaInput / max(1.0 + R2D_Dilation, 1e-3);
    return pow(max(color, float3(0.0, 0.0, 0.0)), exponentIn);
}

float R2D_HighResScanlineFade(float sourceHeight)
{
    if (!R2D_AutoFadeHighResScanlines)
        return 1.0;

    return 1.0 - smoothstep(900.0, 1200.0, sourceHeight);
}

float3 R2D_ApplyScanlines(float3 color, float2 localUV, float2 sourceSize)
{
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float peak = max(color.r, max(color.g, color.b));
    float brightness = 0.5 * (luma + peak);

    float beamMin = min(R2D_BeamWidthMin, R2D_BeamWidthMax);
    float beamMax = max(R2D_BeamWidthMin, R2D_BeamWidthMax);
    float beam = clamp(brightness * beamMax, beamMin, beamMax);

    float phase = localUV.y * sourceSize.y + R2D_ScanlinePhase;
    float wave = 0.5 + 0.5 * cos(phase * R2D_TWO_PI);

    float strength = R2D_ScanlineStrength * R2D_HighResScanlineFade(sourceSize.y);
    float scanWeight = 1.0 - pow(saturate(wave), beam) * strength;

    float brightRecovery = clamp(brightness, R2D_ScanBrightMin, R2D_ScanBrightMax);
    float3 scanned = color * scanWeight;

    return lerp(scanned, color, brightRecovery);
}

float3 R2D_ApplyMask(float3 color, float2 screenUV)
{
    if (R2D_MaskType == 0 || R2D_MaskStrength <= 0.0)
        return color;

    float autoScale = 1.0;
    if (R2D_AutoScaleMaskFor8K)
        autoScale = max(1.0, floor((BUFFER_HEIGHT * 1.0 / 2160.0) + 0.5));

    float cell = max(1.0, R2D_MaskScale * autoScale);

    float px = floor(screenUV.x * BUFFER_WIDTH / cell);
    float py = floor(screenUV.y * BUFFER_HEIGHT / cell);

    float stagger = 0.0;
    if (R2D_MaskType == 2)
        stagger = py - floor(py * 0.5) * 2.0;

    float channelValue = px + stagger;
    int channel = (int)(channelValue - floor(channelValue / 3.0) * 3.0);

    float dim = 1.0 - R2D_MaskStrength;
    float3 weight = float3(dim, dim, dim);

    if (channel == 0) weight.r = 1.0;
    else if (channel == 1) weight.g = 1.0;
    else weight.b = 1.0;

    float3 result = color * weight;

    if (R2D_MaskBrightnessCompensation)
    {
        float average = max((1.0 + 2.0 * dim) / 3.0, 0.01);
        result /= average;
    }

    return result;
}

float4 R2D_MainPS(float4 position : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float4 original = tex2D(ReShade::BackBuffer, texcoord);

    float2 sourceSize = R2D_GetSourceSize();

    float2 viewportMin;
    float2 viewportSize;
    R2D_GetViewport(sourceSize, viewportMin, viewportSize);

    bool inside =
        texcoord.x >= viewportMin.x &&
        texcoord.y >= viewportMin.y &&
        texcoord.x <= (viewportMin.x + viewportSize.x) &&
        texcoord.y <= (viewportMin.y + viewportSize.y);

    if (!inside)
        return original;

    float2 localUV = (texcoord - viewportMin) / viewportSize;

    float3 color = R2D_Reconstruct2D(localUV, sourceSize, viewportMin, viewportSize);
    color = R2D_ApplyScanlines(color, localUV, sourceSize);
    color = R2D_ApplyMask(color, texcoord);

    color = pow(max(color, float3(0.0, 0.0, 0.0)), 1.0 / max(R2D_GammaOutput, 0.01));
    color *= R2D_Brightness;
    color = saturate(color);

    float3 finalColor = lerp(original.rgb, color, R2D_EffectStrength);
    return float4(finalColor, original.a);
}

technique Retro2D
<
    ui_label = "Retro2D - 2D 游戏视觉优化";
    ui_tooltip =
        "针对 4K 及以上显示器上的老式 2D 游戏。\n"
        "源分辨率重建 + 亮度相关扫描束；无曲面、无黑边、无 Halation/Bloom。";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = R2D_MainPS;
    }
}
