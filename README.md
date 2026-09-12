# 奇点 · Singularity

<img src="docs/icon.png" alt="Singularity icon" width="112">

A native macOS black-hole desktop pet with live desktop lensing, draggable positioning, configurable visual families, random roaming, and custom accretion-disk colors.

一个能扭曲真实桌面背景的原生 macOS 黑洞桌宠。

## 下载与安装

从 [Releases](https://github.com/zhrhaozi/singularity-desktop/releases) 下载 DMG，将「奇点.app」拖到「应用程序」。

- Apple Silicon（M 系列），macOS 13 或更高版本。
- 本机有 Apple Development 证书时，构建会使用稳定签名；没有证书的环境会回退到 ad-hoc。两种构建都**未通过 Apple Developer ID 公证**，组织或系统安全策略可能阻止启动；请遵循设备的安全策略。
- 录屏画面仅在本机内存中参与渲染，不保存、不上传，不采集系统音频。

## 功能

| 功能 | 配置 |
| --- | --- |
| 黑洞分型 | Schwarzschild、Kerr、Reissner–Nordström、Kerr–Newman |
| 分型参数 | 质量尺度、自旋方向与强度、电荷；按分型显示 |
| 吸积盘 | 炽金、冷蓝、星环、纯透镜 |
| 外观参数 | 大小、透镜强度、亮度、倾角、画面旋转、盘面流动速度 |
| 自定义颜色 | macOS 颜色选择器、`#RRGGBB` 或 `#RGB` 输入 |
| 桌面漫游 | 5–180 pt/s；随机转向、边缘随机向内折返 |
| 交互 | 拖动、双击/右键设置、菜单栏入口、隐藏、参数与位置保存 |
| Codex 状态联动 | 空闲、思考、运行命令、长任务、完成、出错；映射能量、粒子、拖影与结果事件 |

关闭设置后开始漫游。鼠标靠近、拖动或打开设置时暂停，方便操作；隐藏时停止桌面采样。移动范围限定在当前显示器的可用区域，避开菜单栏和 Dock。

自定义颜色只作用于吸积盘，保留背景原色。**纯透镜模式没有吸积盘，选择其他风格才能看到盘色变化。** 错误 HEX 输入会保留上次有效颜色。

## Codex 状态联动

设置中的「自动检测 Codex 桌面状态」默认开启。应用通过 `127.0.0.1:9229` 的本机渲染器调试端点只识别界面状态标记，不读取或保存对话内容；端点不可用时保持空闲。

状态映射为：空闲 = 慢旋转与轻微透镜；思考 = 盘面升温、粒子增加；运行命令 = 物质流加速并出现内落碎片；长任务 = 时间膨胀拖影；完成 = 短暂结果闪光；出错 = 吸积盘抖动与闪烁。

如果 Codex 运行环境没有开放本地渲染器状态，也可以通过状态桥接命令写入本机状态文件：

```sh
./singularity-codex-state thinking
./singularity-codex-state command "running shell"
./singularity-codex-state complete
./singularity-codex-state idle
```

支持 `idle`、`thinking`、`command`、`long`、`complete`、`error`。状态文件位置为 `~/Library/Application Support/Singularity/codex-state.json`，以文件修改时间判定新鲜度，达到 12 秒未更新会失效并回退到 Codex 桌面状态检测；未来修改时间或无效输入不会取得状态优先权。

完成必须由明确的 `complete` 事件表示：**忙碌后变为 `idle` 不再推断成功**，因为停止、取消也会回到空闲。当前 DOM 检测没有可靠的成功标记，自动模式需要通过上述状态桥接命令报告完成。`complete` 保持 1.4 秒，普通空闲轮询不会提前打断；新的任务可以覆盖旧完成状态。断联或观测超时只回退空闲，不触发完成。

桥接命令使用 macOS 内置 JavaScript/Foundation 做 JSON 序列化与原子写入，支持多行、引号与控制字符，每次调用生成唯一 `eventID`。相同事件 ID 的重复快照不会再次触发结果或延长保持期；自定义生产者重试同一个事件时应复用 ID，新结果使用新 ID。旧格式（没有 `eventID`）仍可读取。错误状态保持到新的正常状态或来源失效，不因重复快照反复触发提示。结果去重为当前进程内的有界缓存，不保证应用退出重启后的持久去重。

## 物理模型的范围

Schwarzschild 模式沿用上游着色器的数值光线积分。Kerr 及带电分型是在该基础上实现的**视觉近似**，用局部坐标扭曲、偏移、尺寸变化及盘面参数表达不同外观，**不是精确求解 Kerr / Kerr–Newman 度规的光线追踪器**。

质量尺度是视觉倍率；自旋、电荷是无量纲控制量。Kerr–Newman 模式限制有效电荷，使 `a*² + q*² ≤ 0.98²`。它是桌面视觉应用，不应用于科学计算。

## 录屏权限

点击「开启桌面透镜」，按系统提示授权。若没有申请弹窗或没有列表条目：

1. 进入「系统设置 → 隐私与安全性 → 录屏与系统录音」。
2. 使用**上方录屏列表**的「＋」，选择 `/Applications/奇点.app`。
3. 完成系统验证、开启权限，然后退出并重新打开奇点。

使用同一 Apple Development 身份构建时，macOS 会把后续版本视为同一录屏权限身份，通常不需要每次重新登记。第一次安装稳定签名版本仍可能需要在系统设置中重新添加或开启「奇点」；如果使用没有证书的 ad-hoc 环境更新，旧条目仍可能绑定旧二进制签名，此时通过系统设置移除**奇点这一项**，再添加当前应用并重启。不要修改系统 TCC 数据库或重置其他应用权限。

### 桌面连接恢复

1.2.5 修复了采集流中断后背景透镜一直消失、必须手动重连的问题。已知临时连接错误会按 1、2、4、8、16 秒退避，最多自动重试 5 次；短暂收到一帧不会重置预算，稳定运行 30 秒后才开始新的恢复预算。连接后必须收到有效桌面首帧才显示「已连接」，8 秒未收到首帧也会进入有限重试。

休眠、显示器睡眠和用户会话切换时暂停采集，相关恢复通知到齐后重新连接。静止桌面的 idle 帧不会被误判为故障。隐藏宠物或显式停止会取消待执行的重连；用户拒绝授权、用户停止、系统明确停止以及未知错误均等待手动开启，不自动弹出授权窗口。

仅采集连接事件、错误域与错误码写入 `~/Library/Logs/Singularity/capture.log`，达到约 64 KB 后重建日志；其中没有屏幕像素、窗口标题或对话内容。显示器热插拔、实际睡眠唤醒和所有系统停止原因无法由单一设备上的故障注入测试穷尽验证。

### 性能优化

1.2.6 通过 Core Video 纹理缓存直接使用 ScreenCaptureKit 提供的 IOSurface 桌面图像，减少逐帧整屏 CPU 复制与纹理转换；导入不可用时自动沿用原有 CPU 上传路径。保持 Retina 分辨率、30 FPS 目标、采集频率及黑洞光线积分算法不变，不以降低画质换取性能。

暂停流动后，静止画面不再持续重绘；桌面更新、窗口移动、设置修改及采集连接变化仍会刷新背景透镜。隐藏时继续停止采集。实际性能取决于屏幕尺寸、背景变化和其他应用负载，短时进程 CPU 测量不能代表整机功耗或风扇转速。

## 从源码构建

需要 Xcode Command Line Tools 和包含 ScreenCaptureKit 的 macOS SDK。

```sh
xcode-select --install
git clone https://github.com/zhrhaozi/singularity-desktop.git
cd singularity-desktop
./scripts/test.sh
./build.sh
open dist/奇点.app
```

构建目标固定为 `arm64-apple-macosx13.0`。构建脚本不依赖第三方包，输出应用到 `dist/`，也支持 `./build.sh /absolute/output/directory`。

打包 DMG、ZIP 并生成 SHA-256：

```sh
./scripts/package.sh
```

## 实现与验证

- AppKit / SwiftUI：原生浮动窗口和设置面板。
- ScreenCaptureKit：采集显示器画面，排除奇点自身全部窗口以避免反馈，并兼容快速隐藏和显示。
- OpenGL 3.2：渲染上游 GLSL 的适配版本。OpenGL 已被 Apple 弃用，此版本仍使用它；长期迁移目标可考虑 Metal。
- `Behavior.swift`：颜色解析、随机漫游和边界约束。
- `CodexState.swift`：Codex 状态识别、本地状态桥接与动效状态机。
- `scripts/test.sh`：颜色合法性、速度单位、负坐标屏幕及连续 16 万步边界检查，以及 Codex 六态解析、完成保持与去重、文件失效、断联回退、迟到响应、取消与 JSON 写入回归测试。测试使用独立文件夹、注入时钟与模拟探测器，不访问真实 Codex 或用户状态文件。

1.2.4 在 1.2.2 的基础上补齐 Codex 六态桥接、状态失效回退、完成事件保持与去重、原子状态文件写入，以及渲染连续性、盘面投影和 Retina 采样收尾。隐藏宠物会同步显示采集暂停；快速隐藏、显示和重连按最后一次请求执行，旧流的帧及错误回调不会污染新连接。

原生发布构建自测：

```sh
./build.sh
./scripts/test-native.sh
```

`--self-test` 使用在 `-O` 下仍生效的显式检查，失败返回非零退出码，结束后自动退出，不保存设置或位置，也不读取 Codex 状态。测试覆盖窗口尺寸、位置、显示隐藏、实际 GLSL 链接、48 组状态/风格/像素尺寸的 GPU 读回、阴影、透明边缘、动画暂停恢复及采集重连。生成的 PNG 仅使用无桌面背景的渲染，不含用户屏幕内容。已有录屏权限时还会测试真实屏幕采集；无权限时明确标记跳过。`scripts/test-native.sh` 额外验证故意失败会被正确报告。

1.2.5 的原生测试使用独立进程显示临时彩色棋盘背景，在当前真实采集流注入中断后，验证新流、新像素、GPU 背景贡献及暂停黑洞动画时的背景持续刷新；同时覆盖取消待重连、迟到回调、重叠休眠原因、主动停止和权限拒绝路径。实际桌面像素仅在内存中比较，不保存或上传；测试进程不写入用户设置和诊断日志。CI 运行不需要桌面权限的 `--capture-policy-test` 检查退避预算和错误分类，本机再运行完整采集测试。

1.2.6 增加 IOSurface 共享纹理与 CPU 上传的逐像素等价测试，分别覆盖非对称生成图像、普通内存回退和真实桌面采集；暂停刷新测试要求持续观察至少 6 次采集帧变化和 3 次渲染变化，超过系统的 3 帧采集池，防止纹理缓存保留旧帧导致停更。每次切换纹理都回收未使用的缓存。同时检查暂停静止画面停止重绘、恢复动画重新绘制。无桌面采集条件时可使用 `--pet-only --self-test --self-test-render-only` 单独运行生成纹理和 GPU 回归；它不能替代有录屏权限的完整原生测试。

已在 Apple Silicon macOS 上验证逻辑回归、真实 GPU 渲染、屏幕采集和签名。多实体显示器热切换与长时间 GPU 功耗仍需按具体设备实测，目标帧率为 30 FPS。应用使用 Apple Development 签名，未进行 Developer ID 公证。

## 致谢与许可

渲染基础来自 [s0xDk/ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole)，原作者 s13k，MIT 许可。保留原始署名，详见 [第三方许可](Resources/THIRD-PARTY-LICENSE.txt)。

本项目新增 macOS 桌面捕获、原生窗口与设置、拖动、漫游、分型视觉控制、自定义颜色及打包。

分型背景参考：[Einstein Online](https://www.einstein-online.info/en/spotlight/Rotating-Black-Holes-Observations-and-Working-in-General-Relativity/)、[Kerr–Newman metric / Scholarpedia](https://www.scholarpedia.org/article/Kerr-Newman_metric)。

项目采用 [MIT License](LICENSE)。
