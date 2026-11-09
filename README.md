<div align="center">

<img src="assets/icon.png" width="128" alt="高小喵图标" />

# Meow · 高小喵

**A macOS desktop pet with a local LLM mind or optional Volcengine cloud chat.**
Local mode is fully offline, with the language model inside one self-contained `.app`.
A lightweight cloud-only build can use your own Volcengine Ark API Key.

![Platform](https://img.shields.io/badge/platform-macOS%2014.5%2B-blue)
![Chip](https://img.shields.io/badge/chip-Apple%20Silicon-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)
![MLX](https://img.shields.io/badge/inference-MLX-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

<img src="assets/pet-states.png" width="800" alt="高小喵的状态 — all drawn and animated procedurally, no image assets" />

*Every state above is drawn procedurally with SwiftUI Canvas — the whole cat is vector code.*

</div>

## What is this?

高小喵 is a little cat who lives on your desktop, powered by a quantized
1B-parameter LLM ([MiniCPM5-1B](https://huggingface.co/mlx-community/MiniCPM5-1B-OptiQ-4bit))
running locally on the Apple Silicon GPU via
[MLX Swift](https://github.com/ml-explore/mlx-swift). What she *says* is wired
to what she *does*: every generated reply carries an emotion tag that drives her
face and animations, her live state (hunger, energy, mood, what she's doing,
what just happened to her) is injected into every prompt, and chat commands are
actually obeyed — tell her to dance and she dances.

### She acts on her own

- Wanders along the bottom of your screen, stretches, spins, naps when tired
- **Jumps onto your app windows**, walks along their top edges, rides them when
  you drag them, and tumbles off (surprised) when you close them
- Gets hungry over time, sulks when neglected, sleeps at night
- Watches your cursor, blinks, flicks her ears
- **Talks to you spontaneously** — lines generated from her live state using your selected model

### You can interact

| Action | Result |
|---|---|
| Click | poke her (spam-poking makes her angry) |
| Double-click | open the chat window |
| Right-click / menu-bar icon | feed 🐟🍪, play 🧶, nap 💤, call her over, settings |
| Drag & toss | pick her up (she flails!) — real physics, squash-and-stretch landing |
| Stroke back and forth | petting → hearts and purring |

拖到屏幕左右边缘后松手，小喵会固定在墙边原来的高度，只露出连着耳朵、截止到眼睛下方的上半张脸，嘴巴和身体藏在屏幕外，仍会眨眼、看鼠标、聊天和分享热点。
鼠标先移开，再靠近时，它会轻轻弹出嘴巴、肚子、爪子和摇动的尾巴，用四句固定招呼轮流回应；移开后一起缩回。招呼在本地触发、不调用模型，每次靠近最多一句，间隔至少 25 秒，已有聊天或热点气泡时不抢话，睡觉时不被鼠标吵醒。
拖回桌面，或在菜单点 **过来这边!**，即可恢复活动；明确的移动指令也会让它离墙。
贴墙位置在重启后保留，支持尺寸调整与显示器变化；多显示器相接的边界可自由拖过，不会误吸附。
造型沿用现有矢量绘制，无需另外准备图片素材。

### 喵喵备忘录

在菜单中打开 **喵喵备忘录…**，直接维护时间与任务；也可以说“明天晚上七点提醒我参加聚会”、“把聚会改到八点”、“买猫粮已经完成了”。时间不明确时会先问清楚，真正保存后才确认。

到点时小喵会用 LLM 生成提醒；每半小时也会结合当前备忘录、主人偏好和最近提醒，判断是否需要提前叫你准备。提醒会显示在气泡和聊天记录中。可关闭提前提醒，保留到点闹钟；备忘录保存在本机，需应用运行、电脑唤醒并联网，恢复后会补上错过的到点提醒。

操作、模型请求与可靠性说明见 [备忘录设计](docs/MEMOS_DESIGN.md)。项目按独立 SwiftPM 业务模块组织，应用层按职责整理，扩展入口见 [模块架构](docs/ARCHITECTURE.md)。

### 喵喵信箱

两台 Apple 芯片 Mac 可以互相寄文本信。两边打开 **喵喵信箱… → 启用通信 → 设备绑定**，各复制自己的设备码给对方，再各粘贴一次对方的码。绑定完成后点 **写一封信** 即可发送；对方的小喵收到后会抱着 💌，点击信封展开正文，信会继续保留在信箱里。

基于 iroh-ffi，正文不经过大模型。离线时保存在本机待寄箱，自动重试；“已送达”表示对方已经保存。双方都需运行新版 Meow、保持电脑唤醒并启用信箱。通信版最低要求 macOS 14.5。详细使用与模块边界见 [信箱设计](docs/MAILBOX_DESIGN.md)。

### 用对话叫小喵做动作

动作库在程序内部维护，菜单里不展示。可以直接说 `打个滚`、`挥挥爪子`、`点点头`、`摇摇头`，也能说跳舞、转圈、跳跃、伸懒腰、散步、过来、跳上窗口、下来、玩毛线球、吃小鱼干、睡觉、起床、停下。
明确指令会先开始动作，再同时生成聊天回复；每轮最多执行一个。`不要打滚` 会停下，讲故事、引用或假设中的动作不会直接执行。模型未就绪时，明确的动作指令仍可在聊天框发送。

小喵也会按状态自行活动：开心且有精力时偶尔打滚或跳舞，主人靠近时挥爪，疲惫时偏向伸懒腰，不高兴时可能摇头。记忆中的安静偏好会降低活跃动作的权重。自动动作有冷却，不打断拖拽、睡觉或正在执行的动作，也不会主动离墙。
普通聊天里的动作选择复用当前回复，不增加一次单独的模型请求；空闲自主动作完全在本机判断。维护方式见 [动作系统设计](docs/ACTIONS.md)。

### Chat with her — she obeys and delivers

- **Commands**: dance / spin / jump / come here / go to sleep / wake up / climb
  onto a window / get down / play / eat / stop — detected deterministically in
  Chinese, so she obeys even when the small model forgets
  its action tag
- **Creative asks**: tell a joke, tell a story, write a poem (in a style you
  name), write a short essay, riddles, word games, a song, a fortune, praise —
  a longform generation mode with delivery-enforcing quality gates and curated
  fallback content guarantees you always get the thing you asked for
- **Context**: she remembers the conversation, knows what just happened to her
  ("you just petted me!", "I fell off a window two minutes ago"), and answers
  profile questions consistently (age, birthday, zodiac, likes, dislikes)
- **Chinese only**: UI, dialogue, commands, and fallback content use 简体中文
- **Deep thinking mode** (Settings toggle): the model reasons in a hidden
  `<think>` block before answering — you only ever see a "thinking…" indicator,
  then the answer streams in. Slower, smarter; retries auto-degrade to fast mode

## Getting started

另一台 Mac 从 Git 拉取后，需要先安装开发工具并构建。云端版一键打包会自动准备固定版本的 iroh-ffi，无需上传 `vendor/`、模型或构建产物。提交范围、拉取步骤、凭据与设备身份说明见 [上传 Git 与另一台 Mac 测试](docs/SECOND_MAC.md)。

### 每天三次的微博热点

高小喵会在北京时间 **11:00、16:00、19:00**，按主人记忆中的偏好挑选一条微博热搜，等空闲时主动分享。
可以告诉它 `我关注人工智能`、`我不喜欢娱乐八卦`。从猫咪菜单或设置打开 **热点小报…**，查看来源或点击 **现在找一条**。
需保持小喵运行和联网；休眠恢复只补一小时内最近一期。云端选题、写稿复用当前模型并消耗额度，可在设置关闭定时分享。
详情与边界见 [微博热点设计](docs/NEWS_DESIGN.md)。

### 高小喵的长期记忆

现在可以记住主人的称呼、喜好和共同经历，跨重启保留，并让熟悉度、安静偏好和跳窗偏好影响行为。
从猫咪菜单或设置打开 **小本本…**，可查看原话来源、旧版本、共同经历并删除记忆。
例如告诉它 `以后叫我珺大王吧`、`我喜欢茉莉花茶`、`我希望安静一些`；用 `清空记忆` 重新开始。
云端整理复用当前模型，会额外消耗请求额度，可在设置关闭；本机基础记忆仍可用。
设计、边界与使用说明见 [高小喵记忆设计](docs/MEMORY_DESIGN.md)。

### Volcengine Ark cloud mode (no model download)

```bash
./scripts/package_app.sh --cloud-only
open build/Meow.app
```

Settings opens automatically when cloud mode has no key yet. Otherwise open
**Settings → Conversation model → Cloud · Volcengine Ark** and enter:

| Setting | Agent Plan value |
|---|---|
| Base URL | `https://ark.cn-beijing.volces.com/api/plan/v3` |
| Model | `ark-code-latest` (the model selected in your console), or a supported model name |
| API Key | Your **Agent Plan dedicated API Key** from the [Agent Plan console](https://console.volcengine.com/ark/region:cn-beijing/subscription/agent-plan) |

Click **Test connection**, then **Save model settings**. Testing makes a small
model request; saving reloads the configuration immediately. Keys are stored in
macOS Keychain, never in the repository or preferences. The cloud-only build
needs macOS 14.5+ and a working Swift 5.10+ toolchain, without MLX or Metal shaders.

Agent Plan credentials and URLs differ from the ordinary pay-as-you-go API.
For ordinary Ark API access, use `https://ark.cn-beijing.volces.com/api/v3`, a
matching platform API Key, and your model name / inference endpoint ID. The app
never switches URLs or billing modes automatically. Refer to the official
[Agent Plan integration guide](https://docs.volcengine.com/docs/ark/agent-plan-personal-other-tools?lang=zh)
and [usage limits](https://docs.volcengine.com/docs/ark/agent-plan-personal-plan-overview?lang=zh):
subscription text-model quotas are intended for supported AI tools, and should
not be assumed to cover arbitrary application API traffic. Use ordinary Ark
API access for application use outside your subscription's permitted scope.

Cloud mode sends chat history and pet context (stats, recent interactions) to
your configured service. Spontaneous dialogue also uses cloud requests; disable
it in Settings if you only want requests when you chat. Emotion/action tags,
command detection, quality checks, and fallback content still work in cloud mode.

### Local offline mode

```bash
git clone https://github.com/Fangyuan025/Kokosuki.git
cd Kokosuki

# download the model weights (~907 MB, not in the repo) — see model/README.md
cd model && for f in config.json generation_config.json model.safetensors \
  model.safetensors.index.json tokenizer.json tokenizer_config.json \
  chat_template.jinja; do \
  curl -L -O "https://huggingface.co/mlx-community/MiniCPM5-1B-OptiQ-4bit/resolve/main/$f"; done
cd ..

# build + bundle + sign → a single self-contained app
./scripts/package_app.sh
open build/Meow.app
```

Requirements: Apple Silicon Mac, macOS 14.5+, Xcode command line tools with the
Metal compiler. Full details, packaging internals, and **how to build with a
different MLX model** (Qwen, Gemma, larger MiniCPMs, …) are in
[docs/BUILDING.md](docs/BUILDING.md).

## Customizing the pet

Settings offers four pet sizes: **Mini (0.5×)**, Small (0.8×), Medium (1.0×),
and Large (1.3×). Changing size takes effect immediately and is saved locally.

Personality and self-introduction are currently edited in source:

- `Sources/Kokosuki/Conversation/Persona.swift`, `system(_:)`: character name, personality,
  profile, preferences, speech rules, and example conversations. The Chinese
  introduction is the example following `主人: 你是谁呀?`. All prompts now use Chinese; edit this single active character definition.
- `Sources/Kokosuki/Infrastructure/Localization.swift`: UI labels, fixed interaction responses
  in `cannedTable`, and creative fallback content.

Rebuild and restart after editing source. Clearing chat history using the
chat window's trash button helps prevent old character details from carrying
over into the new conversation. There is no in-app personality editor yet.

## How it works

```
┌────────────────────────────── Meow.app ──────────────────────────────┐
│                                                                          │
│  PetEngine (30 Hz)          PetView                    Brain             │
│  ├─ physics: gravity,       ├─ SwiftUI Canvas,         ├─ MLX Swift      │
│  │  toss, squash/stretch    │  procedural vector cat   │  (GPU inference)│
│  ├─ autonomy state machine  ├─ 20+ emotion/activity    ├─ manual ChatML  │
│  ├─ window-top platforms    │  states, particles       ├─ rejection      │
│  │  (CGWindowList)          └─ 30 fps timeline         │  sampling gates │
│  ├─ stats + event memory                               ├─ curated        │
│  └─ intent detection ───────── commands/creative ─────►│  fallbacks      │
│                                                        └─ MiniCPM5-1B   │
│  speech bubble ◄─── streamed, emotion-tagged replies ───┘   (bundled)    │
└──────────────────────────────────────────────────────────────────────────┘
```

Highlights for the curious:

- **Speech ↔ behavior coupling**: replies are forced into `[emotion] text [action]`
  shape (the assistant turn is prefilled with `[`); the emotion drives the face
  the moment it streams in, the action tag triggers real animations.
- **Reliability engineering for a 1B model**: every reply passes deterministic
  quality gates — language match, no instruction echo, no verbatim repeats
  (n-gram overlap catches re-punctuated self-plagiarism), no
  announced-but-undelivered content, correct trivial arithmetic, tone checks —
  with automatic resampling and hand-written fallback content as the backstop.
- **Window parkour** uses only public `CGWindowList` bounds — no accessibility
  or screen-recording permissions required. The app requests no permissions at all.
- **Batch-tested**: `--selftest` and `--scenarios` run Chinese generation
  suites with measurable pass gates (see [docs/BUILDING.md](docs/BUILDING.md#development-utilities)).

## Privacy

In local mode, inference runs in-process on your GPU and the app makes no
network requests. In cloud mode, conversation and pet context are sent to the
configured API service using your key. Pet stats and chat history are stored in
`~/Library/Application Support/Kokosuki/`; preferences use `UserDefaults`, and
the cloud API Key uses macOS Keychain. No telemetry is collected.

## License

[MIT](LICENSE) — the bundled model retains its own
[Apache-2.0 license](https://huggingface.co/mlx-community/MiniCPM5-1B-OptiQ-4bit).
