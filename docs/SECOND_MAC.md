# 上传 Git 与另一台 Mac 测试

## 提交哪些文件

提交 `Sources/`、`Tests/`、`scripts/`、`docs/`、`assets/`、`Package.swift`、根目录 `Package.resolved`、`.gitignore`、`README.md`、`LICENSE` 和 `model/README.md`。

模块化之后，旧目录中的文件显示为删除，新目录中的文件显示为未跟踪，这是文件迁移的正常状态。提交时需包含新目录：仅使用 `git commit -am` 会漏掉未跟踪文件。可以先执行下面的命令检查暂存内容，再自行提交、推送：

```sh
git add -A
git diff --cached --stat
git diff --cached --check
git status --short
```

`.gitignore` 排除编译缓存、`build/` 下的应用与截图、参考项目 `vendor/`、模型权重、`.env`、日志、签名材料及常见本机数据副本。根目录 `Package.resolved` 应继续提交。不要将真实密钥写进源文件；忽略规则不会移除已经提交到 Git 历史里的文件。

`vendor/mem0`、`vendor/Mochi` 和 `vendor/weibo-hot-with-your-taste` 只用于设计参考，运行时不读取。`vendor/iroh-ffi` 是构建依赖，打包脚本会自动克隆固定提交并下载、校验官方二进制，因此也无需上传。不要把整个 `vendor/` 作为嵌套仓库提交。

## 在另一台 Mac 构建云端版

要求 Apple 芯片、macOS 14.5+、可用且版本匹配的 Xcode Command Line Tools（Swift 5.10+）、Git 和 Python 3.9+。首次构建需要访问 GitHub，下载 iroh-ffi 源码和约 41 MB 的 Apple 二进制；无需 Rust、MLX 或本地模型权重。

```sh
# 若没有开发工具，先安装，并等待安装完成
xcode-select --install

# 确认工具可用
xcrun swift --version
git --version
python3 --version

# 将地址替换为你自己的仓库地址
git clone <你的仓库地址> Meow
cd Meow
./scripts/package_app.sh --cloud-only
open build/Meow.app
```

开发工具已经安装时，跳过安装命令。首次启动后，在设置中填写云端服务地址、模型名和 API Key。信箱通信不需要模型 Key；聊天、记忆的云端整理、热点选题和备忘录的智能提醒需要可用的模型配置。

已克隆过项目时，退出旧版应用，运行 `git pull`，再执行同一条打包命令并打开新版。若要直接使用 `swift build` 或 `swift test`，先运行 `python3 scripts/prepare_iroh.py`，准备被忽略的本地依赖目录。

## 开始信箱测试

两台 Mac 都启动新版应用，分别打开“喵喵信箱 → 启用通信 → 设备绑定”，各粘贴对方的设备码。之后双向寄信，检查未读信封、展开正文、历史保留和离线重试。具体步骤见 [信箱说明](MAILBOX_DESIGN.md)。

可先运行不消耗模型额度的本机检查：

```sh
build/Meow.app/Contents/MacOS/Meow --selftest --unit-only
```

其中信箱使用临时身份和临时数据，在本机回环地址上执行真实 QUIC 收发，不读取本机钥匙串或访问公网中继。跨网络收发仍需两台实际 Mac 验证。

## 哪些东西不会随 Git 同步

- 云端 API Key、微博 Cookie 和信箱设备私钥保存在钥匙串，需要在另一台设备独立配置或生成。
- 记忆、聊天、备忘录、信件和宠物状态保存在 `~/Library/Application Support/Kokosuki/`。
- 窗口位置、尺寸和模型设置等保存在本机偏好设置中。

仅复制应用或拉取源码不会迁移上述数据。测试两台独立设备时不要复制信箱私钥或整份信箱存储，两边应有不同的设备身份。

## 遇到构建工具链错误

如果在编译项目源码之前就报 `Invalid manifest`、`redefinition of module 'SwiftBridging'` 或 `PackageDescription` 链接错误，先检查 Xcode/Command Line Tools 是否完整、版本是否匹配。这些是工具链问题，不应通过修改业务源码或复制另一台机器的 `.build` 缓存解决。

本次检查中，当前机器默认 Command Line Tools 出现了上述错误；之前交付的应用通过临时编译环境规避后已构建、自检，但这不等于标准 SwiftPM 构建已在全新环境验证通过。干净目录的依赖准备还遇到了 Git HTTPS 的证书链错误；若另一台 Mac 也报 `SSL certificate problem`，需检查本机代理与证书信任配置，恢复对 GitHub 的正常 HTTPS 访问后再构建。

若安装了完整 Xcode，可仅为本次打包选择它的工具链，无需更改系统默认设置（路径按实际安装位置调整）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/package_app.sh --cloud-only
```

若只有 Command Line Tools，请先更新或重新安装与当前系统匹配的版本，再重试。完整构建说明见 [BUILDING.md](BUILDING.md)。
