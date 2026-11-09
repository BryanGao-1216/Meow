# 构建高小喵

## Requirements

For **cloud-only** builds, use an Apple Silicon Mac with macOS 14.5+, working
Swift 5.10+ command line tools, Git and Python 3.9+. Model weights, MLX
dependencies, and the Metal compiler are not used. The packaging script prepares
the pinned iroh dependency automatically; the first build needs GitHub access:

```bash
./scripts/package_app.sh --cloud-only
open build/Meow.app
```

从 Git 拉取到另一台 Mac 的完整流程、提交范围、各设备独立配置的数据，以及 Command Line Tools 的已知环境问题，见 [SECOND_MAC.md](SECOND_MAC.md)。直接运行 `swift build` / `swift test` 前，应先运行 `python3 scripts/prepare_iroh.py`。

向普通使用者分发时，可执行 `./scripts/package_dmg.sh` 生成无需开发工具的安装磁盘；已有应用可用 `--app build/Meow.app` 直接封装。签名限制、安装和更新说明见 [DISTRIBUTION.md](DISTRIBUTION.md)。

Configure **Settings → Conversation model → Cloud · Volcengine Ark** with the
Agent Plan Base URL `https://ark.cn-beijing.volces.com/api/plan/v3`, model
`ark-code-latest` or another supported model name, and your Plan-specific API Key.
Test the connection and save. See the [云端配置与使用说明](../README.md#配置火山方舟).

The requirements below apply to the **local MLX** build:

- Apple Silicon Mac (the LLM runs on the GPU via [MLX](https://github.com/ml-explore/mlx-swift))
- macOS 14.5+
- Xcode 16+ command line tools (`xcode-select --install` at minimum, full Xcode
  recommended — the Metal shader compiler is required)

## Quick start

```bash
git clone https://github.com/Fangyuan025/Kokosuki.git
cd Kokosuki

# 1. Download the model weights (~907 MB) — see model/README.md
cd model
for f in config.json generation_config.json model.safetensors \
         model.safetensors.index.json tokenizer.json tokenizer_config.json \
         chat_template.jinja; do
  curl -L -O "https://huggingface.co/mlx-community/MiniCPM5-1B-OptiQ-4bit/resolve/main/$f"
done
cd ..

# 2. Build, compile the MLX metallib, bundle everything, sign (ad-hoc)
./scripts/package_app.sh

# 3. Done — a single self-contained app
open build/Meow.app
```

The resulting `Meow.app` (~1 GB) contains the binary, the Metal kernel
library, and the model. It runs fully offline and can be copied to any Apple
Silicon Mac (on other machines, right-click → Open the first time, since it is
ad-hoc signed).

## What the packaging script does

`scripts/package_app.sh`:

Before compilation it prepares the pinned iroh-ffi Swift source and checksum-verified Apple binary with `scripts/prepare_iroh.py`.

1. `swift build -c release`
2. `scripts/build_metallib.sh` — SwiftPM builds of mlx-swift don't produce the
   Metal kernel library, so the script compiles the non-JIT kernel set
   (`rms_norm`, `rope`, `scaled_dot_product_attention`, `gemv`, …) with
   `xcrun metal` into `mlx.metallib`, which must sit next to the executable
3. Assembles the `.app` bundle: binary, metallib, SwiftPM resource bundles,
   `model/`, generated `.icns` (the icon is rendered from the same vector code
   that draws the pet), `Info.plist` (`LSUIElement` = menu-bar app)
4. Ad-hoc codesigns the bundle

## Using a different model

高小喵 talks to the model through a small, well-isolated surface, so swapping
models is easy:

**Works out of the box** — any MLX-format model that
[mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) can load
(llama/qwen/gemma/phi families, quantized or not) **and** that uses a
ChatML-style template (`<|im_start|>role … <|im_end|>`). Examples:
Qwen-family instruct models, MiniCPM. Just put its files in `model/` and run
the packaging script. Note the app looks for a single `model.safetensors`; for
sharded models edit the file list in `scripts/package_app.sh` accordingly.

**Needs a 2-line tweak** — models with a different chat template (e.g. Gemma's
`<start_of_turn>`): edit `buildPrompt` in `Sources/Kokosuki/Conversation/Brain.swift` (the
prompt is assembled manually — no Jinja at runtime) and the `extraEOSTokens`
in `Brain.load()`.

Things to keep in mind when swapping:

- **Size / speed**: the UX is tuned for ~40+ tok/s. A 3B-4B quantized model is
  still fine on an M-series Pro; expect ~2× the memory of the weights file.
- **The persona prompts** (`Sources/Kokosuki/Conversation/Persona.swift`) are written for a
  small model: heavy few-shot examples, a forced `[emotion]` tag prefill, and a
  rejection-sampling quality gate. Larger models simply comply better — no
  changes needed, replies just get smarter.
- **Chinese support**: the app supports Chinese only. Its prompts,
  command matching, quality gates, and curated fallback content are Chinese;
  choose a model with good Chinese dialogue support.
- The tokenizer-class workaround `replacementTokenizers["TokenizersBackend"]`
  in `Brain.load()` is needed for models exported with transformers v5; it is
  harmless for older exports.
- **Thinking mode**: if the model supports `<think>` reasoning blocks (MiniCPM5
  and most recent ChatML reasoning models do), the "Deep thinking" toggle in
  Settings opens a real think block before the answer. The reasoning is
  consumed silently — the stream only surfaces text after `</think>`, tags
  inside the reasoning never drive the pet's face, a runaway thinker (no
  `</think>` within budget) is discarded, and quality-gate retries always drop
  back to fast mode. For models without think support, leave the toggle off
  (or strip the `<think>` handling in `Brain.buildPrompt`).

## Development utilities

Run `.build-cloud/release/Kokosuki --selftest --unit-only` for Chinese
command, parsing, canned-content, protocol, memory, news and memo integration checks without
loading a model or making external API requests. Mailbox checks use real loopback QUIC connections; they do not use public discovery or relays. Memory checks use temporary files and
an injected fake extractor; the real memory file is untouched.

喵喵信箱构建时由 `scripts/prepare_iroh.py` 准备固定版本的官方 Apple 二进制，校验 SHA-256，无需本机 Rust。单独运行 `--mailbox-check` 检查本机双端真实 QUIC 收发；`--mailbox-render-check /tmp/meow-mailbox-preview` 检查窗口、抱信与点击区域。详见 [MAILBOX_DESIGN.md](MAILBOX_DESIGN.md)。

备忘录实窗样例：`.build-cloud/release/Kokosuki --memo-render-check /tmp/meow-memo-preview`。使用临时样例，不读取真实备忘录或云端凭据。模块目录与扩展方式见 [ARCHITECTURE.md](ARCHITECTURE.md)，备忘录调度与聊天协议见 [MEMOS_DESIGN.md](MEMOS_DESIGN.md)。

贴墙造型需要检查实际的 AppKit/SwiftUI 宿主布局，不能只检查窗口尺寸或单独渲染图案：

```bash
.build-cloud/release/Kokosuki --wall-render-check /tmp/meow-wall-render
```

这个检查会短暂打开独立测试窗口，在四种尺寸下切换桌面、左右贴墙、探身和恢复造型，并捕获真实窗口内容。它检查收起时的上半张脸、耳朵、眼睛、隐藏的嘴巴，以及探身后的嘴巴、肚子、爪子、尾巴和收回后的裁切；同时检查眨眼、耳朵动作、摇尾刷新与尾尖留白。它不启动模型或引擎，也不读取凭据或主人数据；图片输出到指定目录。`--selftest --unit-only` 还用模拟鼠标与时钟检查靠近防抖、固定招呼冷却、睡眠、气泡保护，以及尾巴展开后的屏幕边界。

Memory unit tests are included in `swift test`. The design and user controls are
documented in [MEMORY_DESIGN.md](MEMORY_DESIGN.md). Use `--memory-preview` for an
isolated native memory window with fictional data; it exits after three minutes.

News unit tests cover the Beijing schedule, retrieval, parsing, taste, and deduplication.
The same `--unit-only` command includes news integration checks using a fake clock,
data source and model. See [NEWS_DESIGN.md](NEWS_DESIGN.md).
`--news-check` reads the real public Weibo hot list without credentials or model calls;
`--news-preview` opens a window with fictional data and no credential access.

Cloud HTTP/SSE tests use mock responses and never need a real key or network:

```bash
KOKOSUKI_CLOUD_ONLY=1 swift test --scratch-path .build-cloud
```

This checks request configuration, endpoint validation, reasoning separation,
stream completion, cancellation, error handling, and credential redaction.
XCTest requires an Xcode installation that includes the test frameworks.
`KOKOSUKI_CLOUD_ONLY=1 swift build --scratch-path .build-cloud` builds only the
cloud-capable app. Omit the environment variable for the full MLX build.

`--selftest` and `--scenarios` below use the saved model provider; in cloud mode
they make real API requests and consume quota. Use the mock tests for cloud
transport changes and these suites deliberately for model/prompt evaluation.

```bash
.build/release/Kokosuki --snapshot <dir>   # render all pet states to PNGs (visual QA)
.build/release/Kokosuki --icon <dir>       # render the app icon art
.build/release/Kokosuki --selftest 2       # unit gates + Chinese LLM batch:
                                           #   chat quality, creative delivery,
                                           #   context recall, repeat-variation
.build/release/Kokosuki --scenarios 1      # 18-prompt Chinese scenario suite
.build/release/Kokosuki --platforms        # list window tops the cat can jump onto
.build/release/kokosuki-cli model "hello"  # raw generation harness
KOKOSUKI_DEBUG=1                           # env var: interaction event log to /tmp
```

The selftest suites are how the LLM behavior was tuned: every reply must pass
deterministic gates (language match, no instruction echo, no verbatim repeats,
no announced-but-undelivered content, correct arithmetic, …) with automatic
resampling and curated fallbacks. If you change the prompts, run
`--selftest 2` and `--scenarios 1` to catch regressions.
