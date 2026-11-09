# Meow 模块结构

项目由五个独立业务内核、一个 iroh 传输适配库和一个应用装配层组成。五个业务内核只依赖 Foundation；iroh 适配库依赖信箱内核和第三方 IrohLib。应用层通过注入的闭包连接云服务、通信、小猫表现和窗口，新增功能有明确的接入位置。

```text
Sources/
  KokosukiCloud/        火山引擎协议、SSE、请求配置
  KokosukiMemory/       记忆数据、检索、版本、学习规则
  KokosukiNews/         热榜抓取、选题、偏好、时间策略
  KokosukiMemos/        备忘录数据、事务规则、调度策略、模型协议
  KokosukiMailbox/      信箱模型、设备码、队列、回执与传输接口
  KokosukiIroh/         基于 iroh-ffi 的认证 QUIC 收发适配
  Kokosuki/
    main.swift         应用与诊断入口
    App/               AppDelegate、名称、菜单栏图标、CompanionFeatures 装配
    Conversation/      Brain、Persona、对话工具路由、聊天窗口、气泡
    Pet/               状态、行为引擎、物理、动作库、矢量造型、贴墙
    Features/
      Memory/          记忆控制器与小本本窗口
      News/            热点控制器、小报窗口、微博凭据适配
      Memos/           备忘录控制器与编辑窗口
      Mailbox/         设备绑定、收发编排、信箱与读写信窗口
    Settings/          偏好及设置窗口
    Infrastructure/    本机存储、钥匙串、中文文案
    Diagnostics/       隔离自检、场景检查、实窗截图
```

## 编译边界与依赖方向

云端、记忆、热点、备忘录和信箱内核不导入应用、AppKit、SwiftUI，也不互相依赖。`KokosukiIroh` 实现信箱内核的 `MailTransport`，单独承担 IrohLib/Rust FFI 依赖。主应用负责 MainActor、Combine 与原生窗口。目录层次是应用内的职责边界，不是额外的动态插件系统。

`CompanionFeatures` 是功能装配入口：将具体 Brain、记忆偏好、PetEngine 和通信传输适配成依赖。热点、备忘录和信箱遵循 `CompanionFeature`，统一处理启动、休眠恢复、配置变更和退出；备忘录优先于热点，等待中的到点提醒也会抑制无关闲聊和贴墙招呼。信箱独立于模型，不将正文交给 Brain；未读数量单独更新小猫抱信状态。

`ConversationTool` 只负责识别可处理的请求、规划并执行本机操作，以及返回已经验证的结果。`ConversationToolRouter` 将请求交给对应功能。PetEngine 等待工具准备完成后，仍调用 Brain 用统一人设生成角色回复；Brain 不直接写备忘录文件，宠物引擎也不理解备忘录的数据结构。

## 新增功能的位置

1. 将可独立测试的数据、策略与协议放入单独的 SwiftPM 库，在 `Package.swift` 声明依赖。
2. 在 `Features/<功能>/` 增加控制器和视图。控制器通过依赖闭包使用模型、当前时间和展示通道，测试注入假实现。
3. 需要后台运行时，实现 `CompanionFeature` 并在 `CompanionFeatures` 注册；需要聊天操作时实现 `ConversationTool` 并注册路由。
4. 菜单只负责打开功能窗口。主动展示使用引擎的 `speakProactively`；功能控制器只有实际展示成功后才记录已提醒。
5. 将离线集成测试放在 `Diagnostics`，接入 `--selftest --unit-only`。涉及原生布局时增加独立样例截图入口。

应用名称仍为 Meow.app，小猫称为高小喵。原有 bundle id、钥匙串标识和 Application Support 目录保留，避免模块整理导致已有配置、聊天或记忆丢失。
