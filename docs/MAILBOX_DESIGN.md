# 喵喵信箱

第一版提供两台固定 Apple 芯片 Mac 之间的文本送信。使用本地固定版本 iroh-ffi v1.2.0 的 Swift 绑定与 Rust 静态库，最低系统版本为 macOS 14.5。信箱不调用大模型，也不把来信当成指令、聊天历史或主人记忆。

## 两台设备如何使用

1. 将同一份新版 `Meow.app` 放到两台 Mac 上，分别启动。
2. 两边菜单打开“喵喵信箱…”，打开“启用通信”。首次启用时各自在钥匙串生成设备身份。
3. 在“设备绑定”里复制本机设备码，通过你选择的渠道交给对方。
4. 两边各粘贴对方的设备码并绑定。只在一边绑定还不能互相收信。
5. 点击“写一封信”，填写正文并寄出。对方离线时，信留在本机待寄箱；双方运行、唤醒且网络可用后自动重试。
6. 收件方的小喵会抱着 💌，角标表示未读数。点击信封展开来信并标记已读，信件继续保留在信箱中。

设备码包含公开设备身份和连接地址，不包含私钥。两台 Mac 各自生成身份；只需要复制应用，信箱数据和钥匙串保持各自独立。当前仅支持一个固定对端，换绑前需解除旧绑定。解绑保留历史信件，停止向旧设备投递尚未完成的信。更新同一设备的连接地址不改变对端身份。

## 传输与存储

- 使用专用 ALPN `meow/mail/1`，每次连接发送一封 UTF-8 文本信，再通过同一双向 QUIC 流返回保存回执。
- 两边都验证 QUIC 认证得到的远端公钥必须等于本机已绑定的设备。报文中声明的发件人还必须与该认证身份一致，收件人必须为本机身份；其他设备无法通过只填写某个发件人字段来冒充绑定对端。
- 生产传输使用 iroh 的 N0 预设，提供地址发现和中继能力，尽可能建立直接连接；直连不可用时可使用中继，因此“点对点”指两台固定身份之间的通信，不保证所有网络环境都能纯直连。无需自建收信服务器，当前没有服务器代收或转发离线信件的队列。
- “已送达”表示收件方已经原子保存该信，尚不表示主人已读。收到回执前，发件方保留待寄状态。失败采用退避重试，最多间隔两分钟；双方身份和信件编号保持不变。
- 接收端先将正文、未读状态与回执一起写入本机文件，再发成功回执。保存失败拒发成功回执。相同编号重试只返回已有回执，不重复显示，也不让已读信重新变成未读。删除后仍保存回执，避免丢回执重传造成信件复活。
- 正文为纯文本，最多 5000 字且 UTF-8 不超过 16 KiB；线上的 JSON 报文最多 32 KiB。不解析附件、HTML 或远端脚本。

本机 JSON 为 `~/Library/Application Support/Kokosuki/meow-mailbox.json`，包含信件、已读标记、固定对端及队列/回执。文件权限为仅本人读写；损坏文件不会用空白信箱覆盖。本机存储是 JSON 原文，传输加密由 iroh/QUIC 提供。

32 字节设备私钥单独存入 macOS 钥匙串服务 `com.kokosuki.pet.iroh.identity`，不会写入信箱文件、设备码或日志。钥匙串读取失败时不会悄悄生成新身份替代旧身份。私钥遗失或身份改变后，应解除旧绑定并重新互换设备码。

## 应用中的呈现

未读数量由信箱控制器同步到 `PetCore`，Canvas 根据该状态绘制怀中的信封、抓着信封的小爪子和角标。信封的实际命中区域与正常/贴墙坐标转换共用几何规则，单击打开信件，不触发戳猫或聊天；仍可通过拖动把小猫移动到别处。

贴墙时有未读信会平滑探出身体，保持固定，方便看到和点击信封。全部读完后恢复原本的鼠标靠近与缩回规则。收信不会调用聊天模型或替换正在显示的提醒气泡。

## 模块边界

| 位置 | 职责 |
|---|---|
| `Sources/KokosukiMailbox` | 纯 Foundation 信件模型、存储、设备码、回执去重、队列及传输协议 |
| `Sources/KokosukiIroh` | iroh-ffi 适配、监听、认证身份校验、QUIC 收发和连接生命周期 |
| `Sources/Kokosuki/Features/Mailbox` | 应用控制器、设备绑定、信箱列表、写信和读信界面 |
| `Sources/Kokosuki/Infrastructure/MailIdentityStore.swift` | 钥匙串身份适配 |
| `Sources/Kokosuki/Diagnostics/MailboxSelfTest.swift` | 内核、故障和真实本机 QUIC 集成测试 |
| `Sources/Kokosuki/Diagnostics/MailboxPreview.swift` | 信箱与抱信造型实窗检查、真实鼠标事件验证 |

传输通过 `MailTransport` 注入，信箱的数据模型不依赖 IrohLib、AppKit、SwiftUI 或 Brain。`CompanionFeatures` 统一接入信箱的启动、唤醒与退出；模型设置变更不会重启点对点通信。

## 构建与检查

`scripts/package_app.sh` 会先调用 `scripts/prepare_iroh.py` 准备固定版本 Swift 绑定与官方 Apple 二进制，核对 SHA-256 并放入忽略提交的 `.build-iroh` 缓存。无需安装 Rust 或自行构建完整 iOS 工具链。首次构建需要联网下载依赖，后续可复用缓存。固定源码提交和二进制版本必须一致，脚本不会覆盖用户改动的第三方源码。

```sh
python3 scripts/prepare_iroh.py
./scripts/package_app.sh --cloud-only
.build-cloud/release/Kokosuki --mailbox-check
.build-cloud/release/Kokosuki --mailbox-render-check /tmp/meow-mailbox-preview
```

`--mailbox-check` 使用临时信箱、临时身份，启动两个真实 iroh-ffi 端点在 `127.0.0.1` 收发，并用第三个端点验证拒收未绑定身份。还覆盖离线待寄、回执去重、已读保留、保存失败与恢复。不会读取用户钥匙串，也不接触公开发现/中继或 LLM API。`--selftest --unit-only` 包含这些本机连接测试。

实窗检查使用虚构信件，不联网，输出信箱窗口与四档尺寸下正常/左右贴墙抱信的截图，并验证信封的点击事件。最终仍需两台实际 Mac 完成跨网络验收；本机测试不能代替不同网络的 NAT、系统防火墙和中继可达性验证。

上游资料：[iroh-ffi](https://github.com/n0-computer/iroh-ffi)、[Swift 接入说明](https://github.com/n0-computer/iroh-ffi/blob/v1.2.0/README.swift.md)。项目保留上游源码和二进制版本固定信息，并在应用包中附带上游 MIT 许可。
