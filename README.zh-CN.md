# OpenBean

**让 soundcore Work（D3200）录音豆脱离官方 App 和云端，在你自己的 Mac 上本地使用。**

OpenBean 是录音豆的开源 macOS App 和本地驱动：通过蓝牙和 Wi‑Fi 连接设备、解密录音，全部在本机离线转写。

[English](README.md) · [下载](https://github.com/imraywang/openbean/releases/latest) · [使用指南（英文）](docs/GUIDE.md) · [协议文档](docs/PROTOCOL.md)

> 在 macOS 26/27、Apple 芯片、录音豆固件 04.82 上测试。界面支持中文和英文。

## 能做什么

| | |
|---|---|
| **心力模式** | 整天戴着录音豆，放回充电盒后自动同步、转写、切成一段段对话，写出当天的日记和待办 |
| **语音输入** | 按录音豆的按键（或快捷键）说话，文字打进任意 App 的光标处；录音进行中也能用 |
| **录音** | 蓝牙自动同步（可续传）或 Wi‑Fi 快速下载，离线转写、点句播放、搜索、重点标记、摘要，每条录音可写成一份 Markdown 笔记（例如放进 Obsidian） |
| **给 agent 用** | 只读的 MCP 服务，让你自己的 agent（Claude Code、Claude Desktop、Cursor 等）列出、读取、搜索录音 |
| **设备层** | Swift 库和命令行工具：扫描、设备信息、列表、下载、解密、实时音频、按键事件 |

OpenBean 不会对录音豆做绑定、解绑、恢复出厂或固件升级。从录音豆删除录音只在本机已有完整、核对过的副本时发生，
并且只有三种情况：你明确要求；心力模式设置了同步后清理；或语音输入结束后删掉它自己新建的那个文件。

## 安装

要求：macOS 26 及以上，Apple 芯片。语音模型约 250 MB。

在 [Releases](https://github.com/imraywang/openbean/releases/latest) 下载已签名、已公证的 `OpenBean-<版本>.dmg`，
打开后拖进「应用程序」。首次启动的设置向导会连接录音豆、下载语音模型并申请权限：**蓝牙**，以及往其他 App 打字需要的
**辅助功能**。App 会自动检查更新，安装前先问你。

## 使用

OpenBean 常驻菜单栏。左键点豆子图标打开主窗口，右键出菜单。

- **心力模式**：走完一段简短的介绍后才会打开。开着时页面显示今天：同步进度、日记、待办和当天的对话。
  默认同步后从录音豆删除录音、本机音频保留 7 天，两项都可以自己选；转写一直保留。
- **录音**：列表和详情并排，播放、点句跳转、搜索、摘要、导出。
- **语音输入**：说过的内容，以及它的设置：快捷键（默认 ⌥ Space）、停顿、润色和个人词表。
- **录音豆**：电量、存储、固件、同步选项，以及只录音不听写的「开始录音」。
- **设置**：录音库文件夹、笔记、给 agent 用（MCP）、语音模型、更新。

语音识别始终在本机进行（实时预览用 Apple 设备端听写，定稿用 SenseVoice-Small）。摘要、日记和语音输入的润色是可选的，
使用你自己选的 OpenAI 兼容大模型服务：本机的（llama.cpp、Ollama、LM Studio）或云端的。
**用云端服务时，转写文字会发给该服务；音频不会离开你的 Mac。**

笔记模板、个人词表、日记、自动化链接、MCP 工具等细节见[使用指南](docs/GUIDE.md)。

## 给 agent 用（MCP）

App 里自带 `openbean-mcp`。「设置 → 给 agent 用（MCP）」里有路径和可以直接拷贝的配置：

```bash
claude mcp add --transport stdio --scope user openbean -- /Applications/OpenBean.app/Contents/Helpers/openbean-mcp
```

它只读、不联网，只在 agent 启动它时运行。它读到的内容会交给你连接的 agent 和背后的模型。
心力模式的转写默认不给 agent 读，需要你自己打开。

## 从源码编译

需要 Xcode 26 及以上和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
Scripts/fetch-deps.sh          # 下载 sherpa-onnx 和语音模型（一次）
Scripts/make-signing-cert.sh   # 建议：重新编译后不用重新授权
bin/build-app && open ".build/OpenBean Dev.app"
```

编出来的是 **OpenBean Dev**，和正式版是两个 App，数据和权限分开；不要和正式版同时运行，否则都会去连录音豆。
命令行工具、Swift 库、演示版和发版流程见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)，协议见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

## 已知限制

- 录音豆空闲一阵后，按下按键的第一秒左右收不到声音。
- 录音中做完语音输入后，App 会重连一次蓝牙（约 5 秒）让录音豆停止外发实时音频。
- 蓝牙同步大约是录音时长的一半；长录音可以改走 Wi‑Fi，期间 Mac 会断网约一分钟。
- 还不能区分说话人。

## 声明

OpenBean 是独立项目，与 Anker Innovations 无关，未获其认可或赞助。「soundcore」「Anker」是其所有者的商标，
这里只用来说明支持哪款硬件。协议是为了让你使用自己的设备而整理的，固件升级随时可能让它失效。

许可：[Apache-2.0](LICENSE)
