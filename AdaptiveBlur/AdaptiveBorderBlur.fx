// 文件名：AdaptiveBorderBlur.fx
// 版本：v1.0.0
//
// 这个 Shader 的用途：
// 把游戏画面周围因为宽高比不同而出现的黑边，替换成“实时画面延伸 + 真正高斯模糊”的动态背景。
// 它既支持常见的左右黑边，也支持上下黑边，并且会根据当前 BackBuffer 和游戏内容宽高比自动判断方向。
//
// SPDX-License-Identifier: MIT

#include "ReShade.fxh"

// ============================================================================
// 一、全局常量
// ============================================================================

// 中间模糊纹理采用 1/8 线性尺寸。
// 举例：3840×2160 的 4K 画面会在模糊阶段缩小到大约 480×270。
// 这么做是因为两侧/上下本来就要被强烈模糊，没有必要在完整 4K 上做 65 点高斯卷积，
// 可以大幅减少 GPU 负担，同时保留柔和、连续的高斯模糊观感。
#define ABB_DOWNSAMPLE 8

// 高斯卷积半径为 32。
// 采样范围是 -32 到 +32，再加上中心 0，因此每个方向一共会采样 65 个位置。
// 横向做一次、纵向再做一次，就是标准的“可分离高斯模糊”。
#define ABB_GAUSSIAN_RADIUS 32

// 这三个数字只是程序内部用来表示当前应该处理哪一种黑边。
// 0 = 没有黑边；1 = 左右黑边；2 = 上下黑边。
#define ABB_MODE_NONE 0
#define ABB_MODE_LEFT_RIGHT 1
#define ABB_MODE_TOP_BOTTOM 2


// ============================================================================
// 二、ReShade 面板选项
// ============================================================================

// 这里让用户告诉 Shader：“游戏真正的内容画面是什么宽高比？”
// 注意：这里填的是游戏内容比例，不是显示器比例。
// 显示器 / BackBuffer 比例会由 BUFFER_WIDTH 和 BUFFER_HEIGHT 自动读取。
uniform int ABB_ContentAspectPreset <
    ui_type = "combo";
    ui_label = "游戏内容宽高比";
    ui_items = "4:3\0"
               "5:4\0"
               "3:2\0"
               "16:10\0"
               "16:9\0"
               "21:9\0"
               "2.35:1\0"
               "2.39:1\0"
               "自定义\0";
    ui_tooltip =
        "设置中央实际游戏内容的宽高比，不是显示器宽高比。\n"
        "显示器 / BackBuffer 的比例会自动检测，并自动决定填充左右还是上下。";
    ui_category = "1. 几何设置";
> = 0;

// 当上面的“游戏内容宽高比”选择“自定义”时，才会读取这个数值。
// 例如 4:3 = 1.333333，16:9 = 1.777778，21:9 约等于 2.333333。
// 最小值允许小于 1，是为了兼容未来可能遇到的竖屏内容。
uniform float ABB_CustomContentAspect <
    ui_type = "slider";
    ui_label = "自定义内容宽高比";
    ui_min = 0.25;
    ui_max = 4.00;
    ui_step = 0.001;
    ui_tooltip =
        "仅当“游戏内容宽高比”选择“自定义”时生效。\n"
        "示例：4:3 = 1.333，16:9 = 1.778，21:9 ≈ 2.333，9:16 = 0.5625。";
    ui_category = "1. 几何设置";
> = 1.3333333;

// 黑边里显示的动态背景，需要从中央清晰游戏画面“向外延伸”。
// 这个参数决定延伸时取多少中央画面内容。
// 1.00 是推荐默认值；数值越大，越偏向只看靠近边缘的区域。
uniform float ABB_BorderZoom <
    ui_type = "slider";
    ui_label = "边框取样缩放";
    ui_min = 0.50;
    ui_max = 2.50;
    ui_step = 0.01;
    ui_tooltip =
        "控制黑边动态背景从中央游戏画面取样的范围。\n"
        "1.00 为推荐默认值；数值越高，背景越偏向放大靠近画面边缘的内容。";
    ui_category = "1. 几何设置";
> = 1.00;

// 这是高斯模糊最主要的强度控制。
// 内部并不是“隔很远随便取几个点”，而是按 Gaussian 权重公式计算完整对称卷积核。
// 0 表示不模糊；数值越高，标准差 sigma 越大，画面越柔和。
uniform float ABB_BlurStrength <
    ui_type = "slider";
    ui_label = "高斯模糊强度";
    ui_min = 0.0;
    ui_max = 100.0;
    ui_step = 1.0;
    ui_tooltip =
        "控制动态边框的真正高斯模糊强度。\n"
        "内部使用完整对称高斯核，并按标准差 σ 实时计算每个采样点的权重。";
    ui_category = "2. 外观设置";
> = 55.0;

// 动态背景一般比中央游戏主体稍暗更舒服。
// 1.00 表示不改变亮度；0.70 就是默认压暗到约 70%。
uniform float ABB_Brightness <
    ui_type = "slider";
    ui_label = "边框亮度";
    ui_min = 0.0;
    ui_max = 1.20;
    ui_step = 0.01;
    ui_tooltip =
        "调整动态模糊边框的亮度。\n"
        "通常略微压暗可以减少边框抢夺中央游戏画面的注意力。";
    ui_category = "2. 外观设置";
> = 0.70;

// 饱和度控制颜色鲜艳程度。
// 1.00 基本保持原色，0.00 会变成灰度，超过 1.00 会更鲜艳。
uniform float ABB_Saturation <
    ui_type = "slider";
    ui_label = "边框饱和度";
    ui_min = 0.0;
    ui_max = 1.50;
    ui_step = 0.01;
    ui_tooltip =
        "调整动态模糊边框的颜色饱和度。\n"
        "1.00 基本保持原色，降低后会让背景更安静、更不抢眼。";
    ui_category = "2. 外观设置";
> = 0.85;

// 如果清晰的中央画面直接突然切成强模糊背景，边界可能显得太硬。
// 这个参数控制从“清晰镜像边缘”过渡到“完全高斯模糊”的距离。
// 数值以 2160p 为标定基准，并会随当前输出高度自动缩放。
uniform float ABB_EdgeFeather <
    ui_type = "slider";
    ui_label = "边缘过渡宽度";
    ui_min = 0.0;
    ui_max = 128.0;
    ui_step = 1.0;
    ui_tooltip =
        "控制中央清晰画面边缘到完全高斯模糊背景之间的过渡宽度。\n"
        "数值按 2160p 标定，并会随当前输出高度自动缩放。";
    ui_category = "2. 外观设置";
> = 24.0;

// 1.00 表示完全用动态模糊背景覆盖原黑边。
// 0.50 表示新背景和原黑边各占一半。
// 0.00 就等于完全不覆盖。
uniform float ABB_FillOpacity <
    ui_type = "slider";
    ui_label = "边框填充不透明度";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip =
        "1.00 = 完全覆盖原来的黑边。\n"
        "降低数值会把动态背景与原始黑边区域混合。";
    ui_category = "2. 外观设置";
> = 1.0;

// 这是排查问题时使用的诊断开关。
// 打开以后，本 Shader 认为“应该被填充”的黑边会直接显示成洋红色。
// 如果洋红色区域正好覆盖实际黑边，就说明宽高比计算正确。
uniform bool ABB_DebugMask <
    ui_label = "显示计算出的边框遮罩";
    ui_tooltip =
        "把自动计算出的黑边区域显示为洋红色。\n"
        "用于检查 Shader 是否正确判断了左右黑边或上下黑边。";
    ui_category = "3. 诊断";
> = false;


// ============================================================================
// 三、中间纹理
// ============================================================================

// 第一个中间纹理保存“缩小后的游戏画面”。
// 它只有原始画面的 1/8 宽和 1/8 高，因此像素数量只有原来的 1/64。
texture ABB_DownsampleTex < pooled = true; >
{
    Width = BUFFER_WIDTH / ABB_DOWNSAMPLE;
    Height = BUFFER_HEIGHT / ABB_DOWNSAMPLE;
    Format = RGBA16F;
};

// 第二个中间纹理保存“只做完横向高斯模糊”的结果。
// 先横向、再纵向，是把昂贵的二维高斯卷积拆成两次一维卷积。
texture ABB_BlurHTex < pooled = true; >
{
    Width = BUFFER_WIDTH / ABB_DOWNSAMPLE;
    Height = BUFFER_HEIGHT / ABB_DOWNSAMPLE;
    Format = RGBA16F;
};

// 第三个中间纹理保存“横向 + 纵向都做完”的最终高斯模糊结果。
texture ABB_BlurVTex < pooled = true; >
{
    Width = BUFFER_WIDTH / ABB_DOWNSAMPLE;
    Height = BUFFER_HEIGHT / ABB_DOWNSAMPLE;
    Format = RGBA16F;
};

// 下面三个 sampler 分别负责读取上面的三个中间纹理。
// Clamp 表示纹理坐标跑到 0～1 外面时，停在边缘，不让它循环到另一侧。
// Linear 表示读取时允许双线性插值，让低分辨率模糊纹理看起来更平滑。
sampler ABB_DownsampleSampler
{
    Texture = ABB_DownsampleTex;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Point;
};

sampler ABB_BlurHSampler
{
    Texture = ABB_BlurHTex;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Point;
};

sampler ABB_BlurVSampler
{
    Texture = ABB_BlurVTex;
    AddressU = Clamp;
    AddressV = Clamp;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Point;
};


// ============================================================================
// 四、几何计算：先算“真正游戏内容”在屏幕中央占多大区域
// ============================================================================

// 把面板里的预设编号转换成真正的“宽 ÷ 高”数值。
// 例如 4:3 就会返回 4/3 ≈ 1.333333。
float ABB_GetContentAspect()
{
    if (ABB_ContentAspectPreset == 0) return 4.0 / 3.0;
    if (ABB_ContentAspectPreset == 1) return 5.0 / 4.0;
    if (ABB_ContentAspectPreset == 2) return 3.0 / 2.0;
    if (ABB_ContentAspectPreset == 3) return 16.0 / 10.0;
    if (ABB_ContentAspectPreset == 4) return 16.0 / 9.0;
    if (ABB_ContentAspectPreset == 5) return 21.0 / 9.0;
    if (ABB_ContentAspectPreset == 6) return 2.35;
    if (ABB_ContentAspectPreset == 7) return 2.39;

    // 如果选择“自定义”，就使用用户自己输入的比例。
    // max(..., 0.01) 是一个保险，防止出现 0 导致后面除以 0。
    return max(ABB_CustomContentAspect, 0.01);
}

// 这个函数是整个“全方向自适应”的核心。
// 它会算出中央清晰游戏画面的矩形边界：left、right、top、bottom。
// 所有坐标都使用 0～1 的 UV 比例，而不是固定像素，所以分辨率改变也不需要改代码。
//
// 返回值 mode 表示当前黑边方向：
// ABB_MODE_NONE        = 当前显示比例和游戏比例相同，不需要填充。
// ABB_MODE_LEFT_RIGHT  = 显示器更宽，所以左右有黑边。
// ABB_MODE_TOP_BOTTOM  = 显示器更高/更窄，所以上下有黑边。
int ABB_GetContentRect(
    out float left,
    out float right,
    out float top,
    out float bottom,
    out float contentWidth,
    out float contentHeight)
{
    // 当前实际 BackBuffer 宽高比 = 宽度 ÷ 高度。
    // BUFFER_RCP_HEIGHT 是 1 / BUFFER_HEIGHT，所以乘起来就等于除法。
    const float displayAspect = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;

    // 读取用户设置的“真正游戏内容宽高比”。
    const float contentAspect = ABB_GetContentAspect();

    // 如果两个比例几乎完全一样，就不应该制造任何黑边。
    // 1e-5 是一个非常小的容差，用来避免浮点数计算的微小误差。
    if (abs(displayAspect - contentAspect) <= 1e-5)
    {
        left = 0.0;
        right = 1.0;
        top = 0.0;
        bottom = 1.0;
        contentWidth = 1.0;
        contentHeight = 1.0;
        return ABB_MODE_NONE;
    }

    // 显示器比游戏内容更宽：
    // 例如 16:9 屏幕显示 4:3 游戏。
    // 这时游戏内容会占满高度，高度保持 1.0，只缩小宽度，左右留下黑边。
    if (displayAspect > contentAspect)
    {
        contentHeight = 1.0;
        contentWidth = contentAspect / displayAspect;

        // 左右黑边对称，所以把剩余宽度平均分到两边。
        left = (1.0 - contentWidth) * 0.5;
        right = 1.0 - left;

        // 高度占满整个 BackBuffer，因此上下边界就是 0 和 1。
        top = 0.0;
        bottom = 1.0;

        return ABB_MODE_LEFT_RIGHT;
    }

    // 能走到这里，说明显示器比游戏内容更窄/更高：
    // 例如 16:9 内容放到 16:10 屏幕，或者 21:9 内容放到 16:9 屏幕。
    // 这时游戏内容会占满宽度，宽度保持 1.0，只缩小高度，上下留下黑边。
    contentWidth = 1.0;
    contentHeight = displayAspect / contentAspect;

    // 上下黑边同样对称，把剩余高度平均分到上方和下方。
    top = (1.0 - contentHeight) * 0.5;
    bottom = 1.0 - top;

    // 宽度占满整个 BackBuffer。
    left = 0.0;
    right = 1.0;

    return ABB_MODE_TOP_BOTTOM;
}


// ============================================================================
// 五、动态背景取样：把黑边位置映射回中央游戏画面
// ============================================================================

// 这个小函数会生成一个 0 → 1 → 0 → 1……反复折返的三角波。
// 用它的目的，是让特别宽的 21:9 / 32:9 屏幕也能继续“镜像折返”中央画面，
// 而不是黑边太宽以后只剩最后一列或最后一行像素被无限拉伸。
float ABB_TriangleWave(float x)
{
    return 1.0 - abs(frac(x * 0.5) * 2.0 - 1.0);
}

// 这个函数接收“当前黑边像素的 UV 坐标”，然后找出它应该从中央游戏画面的哪里取样。
// 左右黑边时只改变 X；上下黑边时只改变 Y。
// 这样中央画面的空间关系会比简单整张拉伸自然。
float2 ABB_MapBorderToSource(
    float2 uv,
    int mode,
    float left,
    float right,
    float top,
    float bottom,
    float contentWidth,
    float contentHeight)
{
    // ------------------------------------------------------------------------
    // 情况一：左右黑边
    // ------------------------------------------------------------------------
    if (mode == ABB_MODE_LEFT_RIGHT)
    {
        // 当前像素位于左黑边。
        if (uv.x < left)
        {
            // 先计算这个像素距离中央画面左边缘有多远。
            float distFromEdge = left - uv.x;

            // ABB_BorderZoom 越大，实际向中央画面内部走的距离越小，
            // 看起来就像侧边背景被进一步放大。
            float travel = distFromEdge / max(ABB_BorderZoom, 0.01);

            // 三角波把任意远的 travel 折回到 0～contentWidth 范围。
            float sourceOffset =
                contentWidth *
                ABB_TriangleWave(travel / max(contentWidth, 1e-6));

            // 从中央画面左边缘向右走，得到真正要读取的 X。
            uv.x = left + sourceOffset;
        }
        // 当前像素位于右黑边。
        else if (uv.x > right)
        {
            // 和左边完全对称，只是方向相反。
            float distFromEdge = uv.x - right;
            float travel = distFromEdge / max(ABB_BorderZoom, 0.01);
            float sourceOffset =
                contentWidth *
                ABB_TriangleWave(travel / max(contentWidth, 1e-6));

            // 从中央画面右边缘向左走。
            uv.x = right - sourceOffset;
        }
    }
    // ------------------------------------------------------------------------
    // 情况二：上下黑边
    // ------------------------------------------------------------------------
    else if (mode == ABB_MODE_TOP_BOTTOM)
    {
        // 当前像素位于上黑边。
        if (uv.y < top)
        {
            // 计算它距离中央画面上边缘有多远。
            float distFromEdge = top - uv.y;
            float travel = distFromEdge / max(ABB_BorderZoom, 0.01);

            // 把距离折回到中央内容高度内部。
            float sourceOffset =
                contentHeight *
                ABB_TriangleWave(travel / max(contentHeight, 1e-6));

            // 从中央画面上边缘向下走。
            uv.y = top + sourceOffset;
        }
        // 当前像素位于下黑边。
        else if (uv.y > bottom)
        {
            // 和上边完全对称。
            float distFromEdge = uv.y - bottom;
            float travel = distFromEdge / max(ABB_BorderZoom, 0.01);
            float sourceOffset =
                contentHeight *
                ABB_TriangleWave(travel / max(contentHeight, 1e-6));

            // 从中央画面下边缘向上走。
            uv.y = bottom - sourceOffset;
        }
    }

    // 最后再强制限制一次，确保坐标绝不会跑出中央清晰游戏区域。
    // 这一步同时避免错误读取原本的黑边像素。
    uv.x = clamp(uv.x, left, right);
    uv.y = clamp(uv.y, top, bottom);
    return uv;
}


// ============================================================================
// 六、高斯模糊时的边界保护
// ============================================================================

// 横向高斯卷积会不断向左、向右取样。
// 如果靠近中央内容边缘时仍然继续取，就可能读到原始黑边，导致黑色被“卷”进模糊背景。
// 所以这里把取样点限制在中央内容内部，并额外留出半个低分辨率像素作为安全距离。
float ABB_ClampContentX(float x, float left, float right)
{
    // 一个低分辨率像素在原图里相当于 ABB_DOWNSAMPLE 个像素。
    // 这里取一半，也就是 0.5 * 8 = 4 个原图像素的安全边距。
    float guard = 0.5 * ABB_DOWNSAMPLE * BUFFER_RCP_WIDTH;

    // 如果中央内容本身极端狭窄，guard 不能大到把左右范围颠倒，
    // 所以最多只允许占内容宽度的 49.9%。
    guard = min(guard, max((right - left) * 0.499, 0.0));

    return clamp(x, left + guard, right - guard);
}

// 纵向版本和上面的逻辑完全相同，只是处理 Y / 上下边界。
// 这是新增上下黑边支持后必须补上的保护，否则 Letterbox 模式会把黑色卷进模糊结果。
float ABB_ClampContentY(float y, float top, float bottom)
{
    float guard = 0.5 * ABB_DOWNSAMPLE * BUFFER_RCP_HEIGHT;
    guard = min(guard, max((bottom - top) * 0.499, 0.0));
    return clamp(y, top + guard, bottom - guard);
}


// ============================================================================
// 七、Pass 1：把完整 BackBuffer 缩小到 1/8 线性尺寸
// ============================================================================

float4 ABB_DownsamplePS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    // 这里用四个很靠近的双线性采样做一个简单预滤波。
    // 这样比只取一个点更不容易在缩小时产生锯齿和闪烁。
    const float2 onePixel = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

    float4 color = 0.0;

    // 左上。
    color += tex2D(
        ReShade::BackBuffer,
        uv + float2(-onePixel.x, -onePixel.y));

    // 右上。
    color += tex2D(
        ReShade::BackBuffer,
        uv + float2(onePixel.x, -onePixel.y));

    // 左下。
    color += tex2D(
        ReShade::BackBuffer,
        uv + float2(-onePixel.x, onePixel.y));

    // 右下。
    color += tex2D(
        ReShade::BackBuffer,
        uv + float2(onePixel.x, onePixel.y));

    // 四个颜色求平均，所以乘 1/4。
    return color * 0.25;
}


// ============================================================================
// 八、真正的可分离高斯模糊
// ============================================================================

// 把 0～100 的面板数值转换成高斯标准差 sigma。
// sigma 越大，权重分布越宽，模糊就越强。
float ABB_GetGaussianSigma()
{
    // 先把 0～100 变成 0～1。
    float strength01 = saturate(ABB_BlurStrength / 100.0);

    // 在 2160p 下，把 sigma 从 0.35 平滑映射到 12.0。
    // 0.35 基本接近无模糊，12.0 会得到很明显的柔和背景。
    float sigma2160 = lerp(0.35, 12.0, strength01);

    // 输出分辨率越高，适当提高 sigma。
    // 这里沿用 v0.2.0 已经实机认可的 sqrt 缩放方式，避免改动已通过的视觉基线。
    float resolutionScale =
        sqrt(max(BUFFER_HEIGHT / 2160.0, 0.25));

    return sigma2160 * resolutionScale;
}

// 标准高斯权重公式。
// x 是当前采样点离中心有几个低分辨率像素。
// sigma 决定高斯曲线有多宽。
float ABB_GaussianWeight(float x, float sigma)
{
    // sigma² 会在公式里使用，所以先算出来。
    // max(..., 1e-6) 是为了避免非常极端情况下除以 0。
    float sigmaSquared = max(sigma * sigma, 1e-6);

    // exp 是自然指数函数。
// 公式就是：e^(-(x²)/(2σ²))
    return exp(-(x * x) / (2.0 * sigmaSquared));
}

// 横向高斯卷积。
// 只在 X 方向从 -32 到 +32 采样，Y 保持不变。
float4 ABB_BlurHPS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float left;
    float right;
    float top;
    float bottom;
    float contentWidth;
    float contentHeight;

    // 重新计算中央内容矩形。
    // mode 在本函数里不需要参与判断，但调用函数必须接收返回值，所以保存到变量里。
    int mode = ABB_GetContentRect(
        left,
        right,
        top,
        bottom,
        contentWidth,
        contentHeight);

    // 如果当前显示比例和游戏内容比例完全一致，就根本没有黑边需要处理。
    // 此时直接把缩小纹理原样传下去，可以避免白白执行 65 次横向采样。
    if (mode == ABB_MODE_NONE)
        return tex2D(ABB_DownsampleSampler, uv);

    // 当模糊强度为 0 时，同样不需要做 65 次采样。
    if (ABB_BlurStrength <= 0.001)
        return tex2D(ABB_DownsampleSampler, uv);

    // 取得当前高斯标准差。
    float sigma = ABB_GetGaussianSigma();

    // 低分辨率纹理的一个像素，对应原图 ABB_DOWNSAMPLE 个像素。
    // 所以 UV 步长是 ABB_DOWNSAMPLE / BUFFER_WIDTH。
    float texelX = ABB_DOWNSAMPLE * BUFFER_RCP_WIDTH;

    // sum 用来累加“颜色 × 权重”。
    float4 sum = 0.0;

    // weightSum 用来累加所有权重，最后做归一化。
    float weightSum = 0.0;

    // 从中心左边 32 个点，一直采样到右边 32 个点。
    [unroll]
    for (int i = -ABB_GAUSSIAN_RADIUS; i <= ABB_GAUSSIAN_RADIUS; ++i)
    {
        // 把整数 i 转成浮点数，供高斯公式计算。
        float offset = float(i);

        // 根据离中心的距离计算这一点应该占多大权重。
        float weight = ABB_GaussianWeight(offset, sigma);

        // 计算真正的横向采样位置。
        // ABB_ClampContentX 会阻止采样进入左右黑边。
        float sampleX =
            ABB_ClampContentX(
                uv.x + offset * texelX,
                left,
                right);

        // 把这一点的颜色乘以权重，再加入总和。
        sum +=
            tex2D(
                ABB_DownsampleSampler,
                float2(sampleX, uv.y)) *
            weight;

        // 同时记录权重总和。
        weightSum += weight;
    }

    // 用颜色总和除以权重总和，得到正确归一化后的高斯结果。
    return sum / max(weightSum, 1e-6);
}

// 纵向高斯卷积。
// 它读取“已经横向模糊”的 ABB_BlurHTex，再沿 Y 方向做同样的高斯卷积。
// 两次一维卷积合起来，效果等价于标准二维高斯模糊，但计算量小很多。
float4 ABB_BlurVPS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float left;
    float right;
    float top;
    float bottom;
    float contentWidth;
    float contentHeight;

    int mode = ABB_GetContentRect(
        left,
        right,
        top,
        bottom,
        contentWidth,
        contentHeight);

    // 如果没有黑边，就直接传递横向结果，避免无意义的纵向 65 点卷积。
    if (mode == ABB_MODE_NONE)
        return tex2D(ABB_BlurHSampler, uv);

    // 模糊强度为 0 时也直接传递横向结果。
    if (ABB_BlurStrength <= 0.001)
        return tex2D(ABB_BlurHSampler, uv);

    float sigma = ABB_GetGaussianSigma();

    // 纵向一个低分辨率像素对应的 UV 步长。
    float texelY = ABB_DOWNSAMPLE * BUFFER_RCP_HEIGHT;

    float4 sum = 0.0;
    float weightSum = 0.0;

    [unroll]
    for (int i = -ABB_GAUSSIAN_RADIUS; i <= ABB_GAUSSIAN_RADIUS; ++i)
    {
        float offset = float(i);
        float weight = ABB_GaussianWeight(offset, sigma);

        // ABB_ClampContentY 是本版新增的关键点。
        // 它保证上下黑边模式时，高斯卷积不会把原始黑色条带卷进动态背景。
        float sampleY =
            ABB_ClampContentY(
                uv.y + offset * texelY,
                top,
                bottom);

        sum +=
            tex2D(
                ABB_BlurHSampler,
                float2(uv.x, sampleY)) *
            weight;

        weightSum += weight;
    }

    return sum / max(weightSum, 1e-6);
}


// ============================================================================
// 九、外观处理
// ============================================================================

// 高斯模糊做完以后，再统一调整动态边框的饱和度和亮度。
// 中央清晰游戏画面不会调用这个函数，所以绝不会被改色。
float3 ABB_StyleBorder(float3 color)
{
    // 用标准亮度权重把 RGB 转成一个“灰度亮度”。
    float luma =
        dot(
            color,
            float3(0.2126, 0.7152, 0.0722));

    // ABB_Saturation = 0 时完全使用灰度；
    // = 1 时基本保留原色；
    // > 1 时颜色会更鲜艳。
    color = lerp(luma.xxx, color, ABB_Saturation);

    // 最后乘亮度系数。
    color *= ABB_Brightness;

    return color;
}


// ============================================================================
// 十、最终合成：只改黑边，不碰中央清晰游戏画面
// ============================================================================

float4 ABB_CompositePS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    // 先读取当前像素原本的游戏画面。
    // 如果这个像素属于中央清晰区域，后面会直接原样返回它。
    float4 original = tex2D(ReShade::BackBuffer, uv);

    float left;
    float right;
    float top;
    float bottom;
    float contentWidth;
    float contentHeight;

    // 自动计算中央游戏内容的矩形，以及当前应该处理左右还是上下。
    int mode = ABB_GetContentRect(
        left,
        right,
        top,
        bottom,
        contentWidth,
        contentHeight);

    // 如果宽高比一致，就没有任何黑边，直接返回原图。
    if (mode == ABB_MODE_NONE)
        return original;

    // 判断当前像素是不是落在中央内容矩形之外。
    // 左右模式时 top=0/bottom=1，所以只会命中 X；
    // 上下模式时 left=0/right=1，所以只会命中 Y。
    bool isBorder =
        (uv.x < left) ||
        (uv.x > right) ||
        (uv.y < top) ||
        (uv.y > bottom);

    // 中央游戏内容完全不修改。
    // 这条 return 是保证“主体保持原样”的最重要保险。
    if (!isBorder)
        return original;

    // 开启诊断时，所有被识别为黑边的区域直接显示洋红色。
    if (ABB_DebugMask)
        return float4(1.0, 0.0, 1.0, 1.0);

    // 把当前黑边像素映射回中央游戏画面内部，
    // 得到应该拿哪一块实时游戏内容来填充这个位置。
    float2 sourceUV =
        ABB_MapBorderToSource(
            uv,
            mode,
            left,
            right,
            top,
            bottom,
            contentWidth,
            contentHeight);

    // sharpSource 是还没有模糊的镜像延伸画面。
    // 它只用于黑边紧贴中央内容的那一小段过渡区域，避免边界突然断开。
    float4 sharpSource =
        tex2D(
            ReShade::BackBuffer,
            sourceUV);

    // blurredSource 是已经完成“横向 + 纵向”真正高斯模糊的结果。
    float4 blurredSource =
        tex2D(
            ABB_BlurVSampler,
            sourceUV);

    float3 styledBlur;

    // 模糊强度为 0 时，就直接使用清晰镜像延伸，但仍然允许亮度/饱和度设置生效。
    if (ABB_BlurStrength <= 0.001)
        styledBlur = ABB_StyleBorder(sharpSource.rgb);
    else
        styledBlur = ABB_StyleBorder(blurredSource.rgb);

    // 下面要计算“当前黑边像素离中央画面边缘多远”。
    // 左右黑边看 X 距离，上下黑边看 Y 距离。
    float distFromEdge = 0.0;

    if (mode == ABB_MODE_LEFT_RIGHT)
    {
        // 左边用 left - x，右边用 x - right。
        distFromEdge =
            (uv.x < left) ?
            (left - uv.x) :
            (uv.x - right);
    }
    else
    {
        // 上边用 top - y，下边用 y - bottom。
        distFromEdge =
            (uv.y < top) ?
            (top - uv.y) :
            (uv.y - bottom);
    }

    // 用户输入的过渡宽度是以 2160p 为基准的“像素感”数值。
    // 输出高度改变后按比例放大/缩小，让不同分辨率上的观感尽量一致。
    float featherPixels =
        ABB_EdgeFeather *
        (BUFFER_HEIGHT / 2160.0);

    // UV 的 X 和 Y 单位不同，所以要根据黑边方向选择正确的“每像素 UV 大小”。
    float featherUV =
        (mode == ABB_MODE_LEFT_RIGHT) ?
        (featherPixels * BUFFER_RCP_WIDTH) :
        (featherPixels * BUFFER_RCP_HEIGHT);

    // smoothstep 会把 0～featherUV 的距离平滑转换成 0～1。
    // 0 表示紧贴中央画面，1 表示已经完全进入模糊背景。
    float transition =
        (featherUV > 1e-7) ?
        smoothstep(0.0, featherUV, distFromEdge) :
        1.0;

    // 在最靠近中央画面的地方使用 sharpSource，
    // 然后逐渐过渡到真正高斯模糊 + 亮度/饱和度调整后的 styledBlur。
    float3 borderRGB =
        lerp(
            sharpSource.rgb,
            styledBlur,
            transition);

    // Alpha 沿用原始 BackBuffer，避免这个 Shader 自己制造奇怪透明度。
    float4 border =
        float4(
            borderRGB,
            original.a);

    // 最后应用“边框填充不透明度”。
    // 1.0 = 完全使用新动态背景；0.0 = 完全保留原黑边。
    return lerp(
        original,
        border,
        ABB_FillOpacity);
}


// ============================================================================
// 十一、Technique：告诉 ReShade 按什么顺序运行四个 Pass
// ============================================================================

technique AdaptiveBorderBlur <
    ui_label = "自适应全方向动态高斯模糊";
    ui_tooltip =
        "自动比较显示器 / BackBuffer 与游戏内容宽高比。\n"
        "显示器更宽时填充左右黑边；显示器更窄时填充上下黑边；比例相同时自动旁路。";
>
{
    // 第一步：把完整画面缩小到 1/8 线性尺寸。
    pass Downsample
    {
        VertexShader = PostProcessVS;
        PixelShader = ABB_DownsamplePS;
        RenderTarget = ABB_DownsampleTex;
    }

    // 第二步：在低分辨率纹理上做横向 65 点真正高斯卷积。
    pass BlurHorizontal
    {
        VertexShader = PostProcessVS;
        PixelShader = ABB_BlurHPS;
        RenderTarget = ABB_BlurHTex;
    }

    // 第三步：读取横向结果，再做纵向 65 点真正高斯卷积。
    pass BlurVertical
    {
        VertexShader = PostProcessVS;
        PixelShader = ABB_BlurVPS;
        RenderTarget = ABB_BlurVTex;
    }

    // 第四步：只把模糊结果合成到自动识别出的黑边区域。
    pass Composite
    {
        VertexShader = PostProcessVS;
        PixelShader = ABB_CompositePS;
    }
}
