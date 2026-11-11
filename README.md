# 🐟 DebuSeek - 原生 macOS 智能桌宠（DeepSeek 大肥鱼二创）

<p align="center">
  <img src="AppIcon.png" width="150" alt="DebuSeek Icon" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-blue.svg" alt="Platform" />
  <img src="https://img.shields.io/badge/Language-Swift%205.9-orange.svg" alt="Language" />
  <img src="https://img.shields.io/badge/License-MIT-lightgrey.svg" alt="License" />
  <img src="https://img.shields.io/badge/App%20Size-24.5MB-green.svg" alt="Size" />
</p>

<p align="center">
  <img src="BV1ypb56REM7.gif" width="200" alt="DebuSeek fan-made art" />
</p>

**[简体中文](#简体中文) | [English](#english)**

---

## 简体中文

一个基于 **DeepSeek 官方“大肥鱼”免费二创形象** 制作的轻量级原生 macOS 桌面宠物应用。

项目基于 Swift + SpriteKit 开发，脱离 Web 壳子，具备高精度物理引擎与深度 AI 交互能力。目前处于 v0.2.0 阶段，核心功能已完成，并引入了深度的养成与长期记忆系统。

### ✨ 核心特性

- **DeepSeek 大肥鱼二创**：内置基于 DeepSeek 形象制作的专属桌面精灵。
- **纯原生开发**：使用 Swift、AppKit 和 SpriteKit 构建，无任何 Web/Electron 依赖。
- **高精度物理引擎**：纯数学计算实现抛掷、重力下坠、屏幕边缘与天花板碰撞反弹；新增“空中接住”机制与底部安全区判定。
- **像素级点击穿透**：点击宠物透明区域可穿透至下层应用，不阻挡正常办公；点击宠物本体触发互动。
- **长期记忆压缩系统**：自动/手动生成上下文回忆录，支持编辑摘要 Prompt，在保留 AI 记忆的同时大幅节省 Token。
- **Token 经济与养成**：使用已消耗的 Token 兑换食物，食物支持自定义饱腹度、精力与心情加成；精力耗尽会强制昏厥，支持离线挂机属性结算。
- **兼容 OpenAI 格式的 API**：支持自定义 API 地址、Key 和模型名称（推荐用于 DeepSeek，也兼容 OpenAI 或本地 Ollama 等）。
- **音画同步与 TTS 缓存**：TTS 发声才弹气泡；接入本地 GPT-SoVITS 哈希缓存，实现秒级响应。
- **丰富的 UI 增强**：内置毛玻璃状态面板、AI 调试面板（抓包查 JSON）、可视化命中区域校准、右键动态菜单与全局 Toast 提示。

### 📊 性能表现（实测数据）

- **App 体积**：约 24.5 MB（含动画资源）。
- **内存占用**：运行时约 150 MB - 250 MB。
- **CPU 占用**：静止待机时通常在 9% - 16% 左右（总核心占用率，受渲染帧率和设备性能影响）。

### 📦 安装与运行

1. 前往 Releases 页面下载最新的 `DebuSeek-v0.2.0-macOS.dmg`。
2. 双击打开 `.dmg`，将 `DebuSeek.app` 拖入 `Applications` 文件夹。
3. **⚠️ 首次运行提示**：由于未进行苹果官方公证，系统可能会提示“已损坏”并阻止打开。**不要直接双击 App！**
   **解决方法**：在 `.dmg` 窗口内，双击 **`Fix_Permissions.command`**（修复脚本），输入一次电脑密码，脚本会自动解除安全限制并启动桌宠。之后即可正常双击 App 使用。

### ⚙️ 配置与使用

1. 运行后，右键点击桌宠，选择 **设置**。
2. 在 **聊天** 标签页配置 AI API（推荐填入 DeepSeek API）。
3. 在 **语音** 标签页可配置本地 GPT-SoVITS 服务地址（默认 `http://localhost:9880`）。
4. 配置数据保存在 `~/Library/Application Support/DebuSeek/config.json`。

### ⚠️ 声明与致谢

- **AI 辅助开发**：本项目的绝大部分代码由 AI（DeepSeek 模型）辅助生成。
- **台词与交互灵感**：内置的 470+ 句台词、部分行为状态机灵感，来源于开源项目 [QCYTSN/ds-local-pet](https://github.com/QCYTSN/ds-local-pet)。特别感谢原作者及社区的无私分享。
- **形象与动图素材**：灵感源自 DeepSeek 大肥鱼及公开的二创资源。README 演示动图截取自 B 站二创视频（BV1ypb56REM7），仅作个人学习交流与展示，无商业用途。
- **版权联系**：如素材侵犯了您的权益，请提 Issue 联系我，我会第一时间删除。
- **开源协议**：代码部分基于 MIT License 开源。

---

## English

A lightweight native macOS desktop pet application featuring the **DeepSeek fan-art mascot (Da Fei Yu)**.

Built with Swift & SpriteKit, breaking away from Web wrappers, and possessing deep AI interaction capabilities. Currently in the v0.2.0 stage, core features are complete, introducing a deep nurturing and memory system.

> 🤖 **AI-Native Development**: This project's code was largely generated with the assistance of AI (DeepSeek), serving as an experiment in AI-driven development.

> ⚠️ **Important Note**: The current application UI and the built-in dialogue/behavior systems are **Simplified Chinese only**. Internationalization (i18n) support is planned for future updates.

### ✨ Features

- **DeepSeek Fan-art Mascot**: Features the fan-art character based on DeepSeek's official mascot.
- **100% Native**: Built with Swift, AppKit, and SpriteKit. No Web/Electron overhead.
- **High-Precision Physics**: Pure math-based throwing, gravity, and collision bouncing; includes a mid-air catch mechanism and bottom safe-zone detection.
- **Pixel-Level Click-Through**: Clicking transparent areas passes events to the underlying app. Only clicking the pet itself triggers interactions.
- **Long-term Memory Compression**: Auto/manual generation of conversation summaries (memories), with editable prompts, saving tokens while preserving AI memory.
- **Token Economy & Nurturing**: Use consumed tokens to buy food; food supports custom satiety, energy, and mood bonuses; exhausted energy forces fainting; offline attribute settlement.
- **Universal AI API**: Compatible with any OpenAI-formatted API (Recommended for DeepSeek, also supports OpenAI, Ollama, etc.).
- **Audio-Visual Sync & TTS Cache**: Bubbles appear only when TTS speaks; local GPT-SoVITS hash cache for instant response.
- **Rich UI Enhancements**: Frosted glass status panel, AI Debug Panel (JSON request tracing), visual hit-zone calibration, dynamic right-click menu, and global Toast notifications.

### 📊 Performance

- **App Size**: ~24.5 MB (including assets).
- **Memory Usage**: ~150 MB - 250 MB.
- **CPU Usage**: Typically 9% - 16% when idle (total core usage, affected by rendering frame rate and device performance).

### 📦 Installation

1. Download the latest `.dmg` from [Releases](https://github.com/NickeL9740/DebuSeek-mac/releases).
2. Open the `.dmg` and drag `DebuSeek.app` to your `/Applications` folder.
3. **⚠️ First Launch Note**: Since the app is not notarized by Apple, macOS Gatekeeper will block it and falsely claim it's "damaged". **Do not double-click the App directly!**
   **Fix**: Inside the `.dmg` window, double-click **`Fix_Permissions.command`**, enter your Mac password once. The script will automatically bypass the restriction and launch the pet. After that, you can open the App normally.

### ⚙️ Configuration & Usage

1. Right-click the pet and select **Settings**.
2. Go to the **Chat** tab to configure your AI API (DeepSeek API recommended).
3. Go to the **TTS** tab to set up the local GPT-SoVITS service (default: `http://localhost:9880`).
4. Configuration data is saved at `~/Library/Application Support/DebuSeek/config.json`.

### ⚠️ Credits & License

- **AI Assisted**: Core logic generated by AI (DeepSeek).
- **Dialogue & Inspiration**: 470+ dialogue lines and state machine inspiration are from [QCYTSN/ds-local-pet](https://github.com/QCYTSN/ds-local-pet). Special thanks to the original author.
- **Assets**: Based on public fan-art of DeepSeek's mascot. The demo GIF in the README is sourced from a Bilibili fan-video (BV1ypb56REM7), used for non-commercial display purposes only.
- **Copyright Contact**: If any assets infringe your rights, please open an Issue. I will remove or replace them immediately.
- **License**: Code is licensed under the MIT License.