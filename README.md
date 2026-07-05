# 🌌 Cosmos

**A local, native macOS agent — chat, generate real Office documents, and code, entirely on your Mac.**
**一个完全运行在本地的原生 macOS Agent —— 聊天、生成真正的 Office 文档、编写代码，数据不离开你的 Mac。**

Chat with it, and it reads and writes files, runs shell commands, searches code and the web, produces real Word/PowerPoint/Excel documents, and splits large jobs across parallel subagents — all inside a workspace folder you choose, with a permission prompt before anything is written or executed.

与它对话，它就能读写文件、执行 shell 命令、搜索代码与网页、生成真正的 Word/PowerPoint/Excel 文档，并把大任务拆分给多个并行的子 Agent —— 全部发生在你指定的工作区文件夹内，任何写入或执行操作前都会先向你请求授权。

Everything stays on your machine: sessions are plain JSON files under `~/Library/Application Support/Cosmos/`, and the only network traffic goes to the API providers **you** configure.

一切都留在本地：会话记录是 `~/Library/Application Support/Cosmos/` 下的纯 JSON 文件，唯一的网络请求只发往**你自己**配置的 API 服务商。

---

## ✨ Features / 功能特性

**🏠 Three modes, one window** — Claude-style pill navigation switches between **Home** and **Code**. Home offers *Chat* for casual conversation and *Cowork* for document generation — with one-click Word · Slides · Spreadsheet starter cards — while Code is the full coding agent.

**🏠 三种模式，一个窗口** —— Claude 风格的胶囊导航在 **Home** 与 **Code** 之间切换。Home 下有 *Chat*（日常对话）与 *Cowork*（文档生成，自带一键启动的 Word · 幻灯片 · 表格卡片）两个子模式；Code 则是完整的编程 Agent。

**🔌 Any provider, any format** — Paste Anthropic (`sk-ant-…`) and OpenAI-compatible keys side by side. Formats are auto-detected, and each provider carries its own base URL, model, temperature, top-p, max-tokens and capability tier. Works with OpenAI, DeepSeek, or any OpenAI-compatible endpoint.

**🔌 支持任意服务商、任意格式** —— 可同时贴入 Anthropic（`sk-ant-…`）和 OpenAI 兼容格式的 Key，格式自动识别。每个服务商都能单独设置 Base URL、模型、温度、top-p、最大 token 数和能力等级。兼容 OpenAI、DeepSeek 以及任何 OpenAI 兼容接口。

**🧭 LLM-judge difficulty routing** — Every message is triaged by your fastest configured model, which picks the right *fast* / *balanced* / *strong* tier for the job — in any language — and can even suggest fanning the work out to parallel subagents. Watch the routed model swap live in the composer's model picker.

**🧭 LLM 裁判难度路由** —— 每条消息都先由你配置的最快模型进行分诊，为任务挑选合适的 *fast* / *balanced* / *strong* 等级（任何语言都适用），还能建议把工作拆给并行子 Agent。路由到的模型会实时显示在输入框的模型选择器里。

**👥 Parallel subagents** — The built-in `agent` tool delegates self-contained subtasks that run concurrently, round-robining across all your keys so the load (and rate limits) spread out. Each subtask declares its own difficulty tier.

**👥 并行子 Agent** —— 内置的 `agent` 工具可把独立子任务派发出去并发执行，在你所有的 Key 之间轮转，从而分摊负载与限流。每个子任务都可声明自己的难度等级。

**📄 Office document generation** — `create_docx` / `create_pptx` / `create_xlsx` produce real `.docx` / `.pptx` / `.xlsx` files — written from scratch, zero dependencies.

**📄 Office 文档生成** —— `create_docx` / `create_pptx` / `create_xlsx` 能生成真正的 `.docx` / `.pptx` / `.xlsx` 文件 —— 全部从零实现，零第三方依赖。

**🔎 Web search built in** — The `web_search` tool queries DuckDuckGo directly. No extra API key needed.

**🔎 内置网页搜索** —— `web_search` 工具直接查询 DuckDuckGo，无需额外的 API Key。

**🗂 Artifacts** — Substantial outputs — code, markdown, live HTML/SVG previews — open in a dedicated side panel with one-click copy and save.

**🗂 Artifacts 面板** —— 大块输出（代码、Markdown、可实时预览的 HTML/SVG）会在专属的侧边面板中打开，支持一键复制与保存。

**🖼 Multimodal** — Paste or attach images right in the composer; if the current model can't see, Cosmos automatically switches to a vision-capable one.

**🖼 多模态** —— 直接在输入框粘贴或附加图片；若当前模型不支持视觉，Cosmos 会自动切换到支持视觉的模型。

**🛡️ Five-tier permissions** — Reads are auto-approved; writes and shell commands ask first (Allow once / Always allow / Deny). Pick your level right under the composer: Read Only → Ask Every Time → Accept Edits → Accept All → Bypass. Clearly dangerous commands (`sudo`, `rm -rf`, `git push`, pipe-to-shell) prompt at every level except Bypass.

**🛡️ 五级权限** —— 读取自动放行；写入和 shell 命令会先询问（本次允许 / 始终允许 / 拒绝）。权限等级就在输入框下方随手可选：只读 → 每次询问 → 自动接受编辑 → 全部接受 → 完全跳过。明显危险的命令（`sudo`、`rm -rf`、`git push`、管道到 shell）除"完全跳过"外在任何等级都会强制弹窗确认。

**🏷 Smart session titles** — After the first exchange, a quick model call names the session for you — no more truncated first sentences in the sidebar.

**🏷 智能会话标题** —— 首轮对话结束后，由一次快速模型调用自动为会话命名 —— 侧边栏里不再是被截断的第一句话。

**⚡ Built for real work** — Streaming output, tool cards with inline diffs, session persistence, two-stage context compaction, prompt caching (Anthropic), and a light/dark appearance toggle.

**⚡ 为真实工作打造** —— 流式输出、带内联 diff 的工具卡片、会话持久化、两阶段上下文压缩、prompt 缓存（Anthropic），以及浅色/深色外观切换。

---

## 📦 Install / 安装

1. Download `Cosmos.dmg` (v0.3.0) from the [latest GitHub Release](https://github.com/SimonChen026/Cosmos-Agent/releases/latest), open it, and drag **Cosmos** into your Applications folder.
2. Launch it. On first run, paste one or more API keys — optionally with a base URL for OpenAI-compatible services (e.g. `https://api.deepseek.com`).
3. Choose a workspace folder in the status bar, and start asking.

<br>

1. 从 [GitHub Release 最新版本](https://github.com/SimonChen026/Cosmos-Agent/releases/latest)下载 `Cosmos.dmg`（v0.3.0），打开后把 **Cosmos** 拖进"应用程序"文件夹。
2. 启动应用。首次运行时贴入一个或多个 API Key —— 如使用 OpenAI 兼容服务，可一并填写 Base URL（例如 `https://api.deepseek.com`）。
3. 在状态栏选择一个工作区文件夹，然后开始提问。

> On first launch macOS may warn that the app is from an unidentified developer (it is locally signed, not notarized — and fully local). Right-click the app → **Open** to confirm once.
>
> 首次启动时 macOS 可能提示应用来自身份不明的开发者（本应用为本地签名、未经公证、纯本地运行）。右键点击应用 → **打开**，确认一次即可。

---

## 🛠 Build from source / 从源码构建

```sh
swift build              # debug build / 调试构建
swift run forge-tests    # 66 offline tests — no network, no keys / 66 个离线测试，无需联网或密钥
scripts/build_app.sh     # release build → dist/Cosmos.app
scripts/make_dmg.sh      # package → dist/Cosmos.dmg
```

Requires macOS 14+ and the Xcode Command Line Tools (Swift 6 toolchain). **Zero third-party dependencies.**

需要 macOS 14+ 与 Xcode 命令行工具（Swift 6 工具链）。**零第三方依赖。**

---

## 🧩 How it works / 工作原理

Cosmos is a single SwiftUI app built around a stop-reason-driven agent loop with a hand-rolled SSE parser. Two wire adapters (Anthropic Messages API and OpenAI Chat Completions) share one format-agnostic loop; thirteen tools (read, write, edit, list, glob, grep, bash, todo, artifact, docx, pptx, xlsx, web search) plus the `agent` spawn tool do the work; an LLM-judge router triages each message through your fastest model to choose the provider tier; and provider credentials are held in the macOS Keychain — never written to disk in plaintext.

Cosmos 是一个单一的 SwiftUI 应用，核心是一个基于 stop-reason 的 Agent 循环，配一个手写的 SSE 解析器。两个协议适配器（Anthropic Messages API 与 OpenAI Chat Completions）共用同一套与格式无关的循环；十三个工具（读、写、编辑、列目录、glob、grep、bash、todo、artifact、docx、pptx、xlsx、网页搜索）加上派发子任务的 `agent` 工具负责干活；LLM 裁判路由器用你最快的模型为每条消息分诊、选择服务商等级；服务商凭据保存在 macOS 钥匙串中，绝不以明文写入磁盘。

---

## 🔒 Privacy / 隐私

No telemetry. No analytics. No bundled credentials. The app talks only to the API endpoints you configure, and this repository contains no keys of any kind.

无遥测、无分析、无内置凭据。应用只与你配置的 API 端点通信，本仓库不含任何密钥。

---

## 📄 License / 许可

MIT — see [LICENSE](LICENSE). / MIT 许可，详见 [LICENSE](LICENSE)。
