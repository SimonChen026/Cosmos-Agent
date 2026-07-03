# 🌌 Cosmos

**A local, native macOS coding agent — a Codex-style assistant that lives entirely on your Mac.**
**一个完全运行在本地的原生 macOS 编程 Agent —— 数据不离开你的 Mac。**

Chat with it, and it reads and writes files, runs shell commands, searches code, and splits large jobs across parallel subagents — all inside a workspace folder you choose, with a permission prompt before anything is written or executed.

与它对话，它就能读写文件、执行 shell 命令、搜索代码，并把大任务拆分给多个并行的子 Agent —— 全部发生在你指定的工作区文件夹内，任何写入或执行操作前都会先向你请求授权。

Everything stays on your machine: sessions are plain JSON files under `~/Library/Application Support/Cosmos/`, and the only network traffic goes to the API providers **you** configure.

一切都留在本地：会话记录是 `~/Library/Application Support/Cosmos/` 下的纯 JSON 文件，唯一的网络请求只发往**你自己**配置的 API 服务商。

---

## ✨ Features / 功能特性

**🔌 Any provider, any format** — Paste Anthropic (`sk-ant-…`) and OpenAI-compatible keys side by side. Formats are auto-detected, and each provider carries its own base URL, model, temperature, top-p, max-tokens and capability tier. Works with OpenAI, DeepSeek, or any OpenAI-compatible endpoint.

**🔌 支持任意服务商、任意格式** —— 可同时贴入 Anthropic（`sk-ant-…`）和 OpenAI 兼容格式的 Key，格式自动识别。每个服务商都能单独设置 Base URL、模型、温度、top-p、最大 token 数和能力等级。兼容 OpenAI、DeepSeek 以及任何 OpenAI 兼容接口。

**🧭 Difficulty routing** — Every message is classified by editable regex rules (with length/code-block fallbacks) and routed automatically to a *fast*, *balanced*, or *strong* provider. Cheap questions go to cheap models; hard problems go to your best one.

**🧭 难度路由** —— 每条消息都会经过可编辑的正则规则分类（并辅以长度、代码块等启发式判断），自动路由到 *fast* / *balanced* / *strong* 等级的服务商。简单问题走便宜模型，难题交给最强的模型。

**👥 Parallel subagents** — The built-in `agent` tool delegates self-contained subtasks that run concurrently, round-robining across all your keys so the load (and rate limits) spread out. Each subtask declares its own difficulty tier.

**👥 并行子 Agent** —— 内置的 `agent` 工具可把独立子任务派发出去并发执行，在你所有的 Key 之间轮转，从而分摊负载与限流。每个子任务都可声明自己的难度等级。

**🛡️ Safety-first approvals** — Reads are auto-approved; writes and shell commands ask first (Allow once / Always allow / Deny). Clearly dangerous commands (`sudo`, `rm -rf`, `git push`, pipe-to-shell) always prompt, regardless of your settings.

**🛡️ 安全优先的授权机制** —— 读取自动放行；写入和 shell 命令会先询问（本次允许 / 始终允许 / 拒绝）。明显危险的命令（`sudo`、`rm -rf`、`git push`、管道到 shell）无论如何设置都会强制弹窗确认。

**⚡ Built for real work** — Streaming output, tool cards with inline diffs, session persistence, two-stage context compaction, and prompt caching (Anthropic).

**⚡ 为真实工作打造** —— 流式输出、带内联 diff 的工具卡片、会话持久化、两阶段上下文压缩，以及 prompt 缓存（Anthropic）。

---

## 📦 Install / 安装

1. Download `Cosmos.dmg` from the latest [GitHub Release](https://github.com/SimonChen026/Cosmos-Agent/releases/latest), open it, and drag **Cosmos** into your Applications folder.
2. Launch it. On first run, paste one or more API keys — optionally with a base URL for OpenAI-compatible services (e.g. `https://api.deepseek.com`).
3. Choose a workspace folder in the status bar, and start asking.

<br>

1. 从最新 [GitHub Release](https://github.com/SimonChen026/Cosmos-Agent/releases/latest) 下载 `Cosmos.dmg`，打开后把 **Cosmos** 拖进"应用程序"文件夹。
2. 启动应用。首次运行时贴入一个或多个 API Key —— 如使用 OpenAI 兼容服务，可一并填写 Base URL（例如 `https://api.deepseek.com`）。
3. 在状态栏选择一个工作区文件夹，然后开始提问。

> On first launch macOS may warn that the app is from an unidentified developer (it is ad-hoc signed and fully local). Right-click the app → **Open** to confirm once.
>
> 首次启动时 macOS 可能提示应用来自身份不明的开发者（本应用为 ad-hoc 签名、纯本地运行）。右键点击应用 → **打开**，确认一次即可。

---

## 🛠 Build from source / 从源码构建

```sh
swift build              # debug build / 调试构建
swift run forge-tests    # 48 offline tests — no network, no keys / 48 个离线测试，无需联网或密钥
scripts/build_app.sh     # release build → dist/Cosmos.app
scripts/make_dmg.sh      # package → dist/Cosmos.dmg; upload it as a GitHub Release asset
```

Requires macOS 14+ and the Xcode Command Line Tools (Swift 6 toolchain). **Zero third-party dependencies.**

需要 macOS 14+ 与 Xcode 命令行工具（Swift 6 工具链）。**零第三方依赖。**

---

## 🧩 How it works / 工作原理

Cosmos is a single SwiftUI app built around a stop-reason-driven agent loop with a hand-rolled SSE parser. Two wire adapters (Anthropic Messages API and OpenAI Chat Completions) share one format-agnostic loop; nine tools (read, write, edit, list, glob, grep, bash, todo, agent) do the work; a regex router chooses the provider tier; and provider credentials are held in the macOS Keychain — never written to disk in plaintext.

Cosmos 是一个单一的 SwiftUI 应用，核心是一个基于 stop-reason 的 Agent 循环，配一个手写的 SSE 解析器。两个协议适配器（Anthropic Messages API 与 OpenAI Chat Completions）共用同一套与格式无关的循环；九个工具（读、写、编辑、列目录、glob、grep、bash、todo、agent）负责干活；正则路由器负责选择服务商等级；服务商凭据保存在 macOS 钥匙串中，绝不以明文写入磁盘。

---

## 🔒 Privacy / 隐私

No telemetry. No analytics. No bundled credentials. The app talks only to the API endpoints you configure, and this repository contains no keys of any kind.

无遥测、无分析、无内置凭据。应用只与你配置的 API 端点通信，本仓库不含任何密钥。

---

## 📄 License / 许可

MIT — see [LICENSE](LICENSE). / MIT 许可，详见 [LICENSE](LICENSE)。
