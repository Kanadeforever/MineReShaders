# MineReShaders

个人自用的 ReShade Shader 收藏仓库。

这里存放我自己为实际游玩需求写的 ReShade FX Shader，全部为独立实现，**不需要任何外部纹理**，直接丢进 `reshade-shaders\Shaders` 就能用。

目前包含两组 Shader：一组解决宽高比不同造成的黑边问题，一组针对 4K 及以上显示器上的老式 2D 游戏。

---

# 目录结构

| 目录 | Shader | 用途 | 详细文档 |
|---|---|---|---|
| `AdaptiveBlur/` | `AdaptiveBorderBlur.fx` | 自动处理左右 / 上下黑边 | [AdaptiveBlur/README.md](AdaptiveBlur/README.md) |
| `AdaptiveBlur/` | `AdaptivePillarboxBlur.fx` | 只处理左右黑边 | [AdaptiveBlur/README.md](AdaptiveBlur/README.md) |
| `Retro2D/` | `Retro2D.fx` | 老式 2D 游戏的源分辨率重建 + 扫描线 | [Retro2D/README.md](Retro2D/README.md) |

```text
AdaptiveBlur/
├─ AdaptiveBorderBlur.fx      全方向：左右 Pillarbox + 上下 Letterbox
├─ AdaptivePillarboxBlur.fx   仅左右：固定 4:3 → 宽屏 场景
├─ LICENSE                    MIT License
└─ README.md                  完整参数说明 / 安装 / 示例

Retro2D/
├─ Retro2D.fx                 2D 游戏源分辨率重建 + 扫描束 + 可选栅罩
├─ LICENSE                    GNU General Public License v3.0
└─ README.md                  完整参数说明 / 安装 / 推荐配置
```

---

# 快速开始

## 1. 安装

把需要的 `.fx` 文件复制到游戏目录下：

```text
游戏目录\
└─ reshade-shaders\
   └─ Shaders\
      └─ 这里
```

然后在 ReShade 里点 **Reload**（或按 ReShade 的重载快捷键），就能在 Shader 列表里看到新的 Technique。

## 2. 启用

ReShade 面板中显示的 Technique 名称都是简体中文：

| 文件 | 启用哪一个 Technique |
|---|---|
| `AdaptivePillarboxBlur.fx` | 自适应左右动态模糊 |
| `AdaptiveBorderBlur.fx` | 自适应全方向动态高斯模糊 |
| `Retro2D.fx` | Retro2D - 2D 游戏视觉优化 |

---

# 各组 Shader 简介

## AdaptiveBlur —— 黑边动态高斯模糊

把游戏画面周围因为宽高比不同而产生的黑边，替换成**由实时游戏画面生成的动态高斯模糊背景**，中央游戏画面保持原样、不做任何修改。

- 显示器 / BackBuffer 比例全自动读取（`BUFFER_WIDTH` / `BUFFER_HEIGHT`），不写死 16:9，也不写死 1080p / 1440p / 4K
- 游戏内容比例由用户指定，与显示器比例完全解耦
- 真正的 Separable Gaussian Blur：横向 65 taps + 纵向 65 taps，权重按标准差 σ 实时计算
- 模糊在 1/8 线性分辨率的中间纹理上执行，4K / 5K / 8K 下开销可控
- 超宽屏（32:9 等）使用镜像折返取样，不会把边缘像素无限拉伸
- 需要哪个版本就装哪个，两个版本**不要同时启用**

`AdaptiveBorderBlur` 会自动判断方向：

```text
显示器比内容更宽  →  填充左右黑边
显示器比内容更窄  →  填充上下黑边
比例相同          →  自动旁路，不加任何边框
```

完整说明、参数表和分辨率示例见 [AdaptiveBlur/README.md](AdaptiveBlur/README.md)。

## Retro2D —— 老式 2D 游戏优化

面向 1990 年代末～2000 年代 2D 游戏的视觉优化，目标不是完整 CRT 模拟，而是：

1. 以**逻辑源分辨率**为基准重建低分辨率 2D 画面
2. 加入亮度相关扫描束
3. 可选极轻的 RGB 栅罩
4. **不**加入曲面、黑边、暗角、Halation、Bloom、色散和噪点

关键限制：ReShade 只能看到已经被放大后的最终 BackBuffer，无法恢复在此之前就已经被有损缩放丢掉的信息。所以「源分辨率」要填游戏真正的逻辑画面分辨率（640×480 / 800×600 / 1024×768 之类），而不是 4K 输出分辨率。

完整说明、参数表和推荐配置见 [Retro2D/README.md](Retro2D/README.md)。

---

# 组合使用

两组 Shader 可以同时启用，顺序建议：

```text
原始游戏
   ↓
色彩 / 锐化等主体画质 Shader
   ↓
Retro2D         （只在游戏内容区域内做重建与扫描线）
   ↓
AdaptiveBlur    （把剩下的黑边填成动态模糊背景）
```

搭配要点：

- `Retro2D` 的「内容区域」选择 **按源分辨率宽高比居中**，它只会处理中央游戏区域，viewport 之外的黑边原样保留
- 再由 `AdaptiveBlur` 接管这些黑边，用游戏画面的实时模糊延伸去填充
- 这样 4:3 老游戏放到 16:9 / 21:9 / 32:9 显示器上，就能得到「中央 2D 扫描线 + 两侧动态环境模糊」的效果

---

# 运行要求

- ReShade 6.x（开发和测试基线为 ReShade 6.x / 6.8）
- 需要 ReShade 能够看到黑边本身：如果黑边是游戏输出之后由 GPU Scaling、显卡驱动或显示器硬件缩放补出来的，那么 ReShade 看不到它们，任何 ReShade Shader 都无法在那块区域绘制内容
- 无外部纹理依赖，不读取 `Textures` 目录中的任何资源

---

# 授权

本仓库的授权**按目录独立**，每个目录各自带一份专属的授权文件，根目录不再放置统一的 LICENSE：

| 目录 | 授权 | 授权文件 |
|---|---|---|
| `AdaptiveBlur/` | MIT License | [AdaptiveBlur/LICENSE](AdaptiveBlur/LICENSE) |
| `Retro2D/` | GNU General Public License v3.0 | [Retro2D/LICENSE](Retro2D/LICENSE) |

`Retro2D.fx` 参考了 EasyMode 的 **CRT EasyMode**（GPL）的重建与扫描线思路，按该来源的授权要求，其独立重写实现同样采用 GPL 授权。

## 授权按目录独立，互不影响

本仓库的授权是 **按目录 / 按文件独立** 的，不是整仓库统一授权：

```text
AdaptiveBlur/   →  MIT License                    （AdaptiveBlur/LICENSE）
Retro2D/        →  GNU General Public License v3.0  （Retro2D/LICENSE）
```

也就是说：

- **Retro2D 的 GPL 只跟随 Retro2D 本身**，只约束 `Retro2D/Retro2D.fx` 这一个文件及其副本、修改版和再分发
- 它**不会**影响仓库的其他部分。`AdaptiveBlur/` 下的两个 Shader 始终是 MIT，不会因为仓库里存在一个 GPL 文件而变成 GPL
- 只使用 `AdaptiveBlur/` 的人，不需要遵守任何 GPL 条款，按 [AdaptiveBlur/LICENSE](AdaptiveBlur/LICENSE) 的 MIT 条款使用即可
- 只使用 `Retro2D.fx` 的人，按 GPL 条款使用
- 两组 Shader 在 ReShade 里同时启用，属于各自独立的使用行为，不会让任何一方的授权扩散到另一方

换言之：**用到哪个，就遵守哪个的授权。**

---

# 说明

- 每个 Shader 的版本号写在文件头注释里
- ReShade 面板中的参数全部为简体中文，并带 tooltip
- 每个 Shader 都提供诊断选项（自适应遮罩显示 / 整体效果强度），方便在第一次配置时确认设置是否正确
