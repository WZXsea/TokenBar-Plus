# 构建与验证

本分支沿用上游的 Swift macOS 客户端与 Rust helper。以下命令从仓库根目录运行。macOS 最低部署目标为 14；当前改进版在 Apple Silicon 上完成构建与测试。

## 标准构建

准备支持 Swift 6.2 或更高版本的 Xcode，以及 Rust stable / Cargo。

```bash
git clone https://github.com/WZXsea/TokenBar-Plus.git
cd TokenBar-Plus
swift build
cargo test --manifest-path Helper/Cargo.toml --locked
./Scripts/package_app.sh
```

生成的 `TokenBar.app` 位于仓库根目录，包含 helper 与第三方许可证。将其复制到应用程序目录后启动。应用的显示名称与 bundle ID 沿用 TokenBar；本分支适合作为现有 TokenBar 的替换版本。

`package_app.sh` 默认创建当前主机架构的 ad-hoc 签名开发构建。正式对外分发可使用上游保留的 `Scripts/release_app.sh`，配置 Developer ID 和 Apple 公证；完整参数见 [上游说明](https://github.com/wuruoye/TokenBar#build-and-run)。

## Command Line Tools 的兼容构建

本机验证环境为 Apple Swift 6.4、Command Line Tools，并同时安装了 macOS 26.5 和 27.0 SDK。默认 27.0 SDK 的 SwiftUI 宏组件在该环境中缺失，以下命令显式选择已安装的 26.5 SDK 与 native 构建引擎。

先核对本机路径：

```bash
swift --version
ls /Library/Developer/CommandLineTools/SDKs
```

在具备相同 SDK 的机器上，可用：

```bash
swift build --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

打包脚本内部也会调用 Swift。以下包装函数仅在当前 Bash 会话中添加相同参数：

```bash
bash <<'SH'
set -euo pipefail
swift() {
  command swift "$@" --build-system native \
    --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
}
export -f swift
./Scripts/package_app.sh
SH
```

这些路径对应本机验证环境；使用完整 Xcode 的环境优先采用标准构建命令。native 构建引擎在 Swift 6.4 中已标记为 deprecated，此处用于兼容上述 CLT 环境。

## 测试

完整 Xcode 环境可以使用 `swift test`。上述 CLT 环境通过以下参数加载其自带的 Swift Testing：

```bash
swift test --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --disable-xctest --enable-swift-testing \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xswiftc -Xfrontend -Xswiftc -plugin-path \
  -Xswiftc -Xfrontend -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks

cargo test --manifest-path Helper/Cargo.toml --locked
```

2026-10-17 精简测试集：Swift 23 项、Rust 14 项。保留额度与套餐解析、缓存兼容、重置与每日用量、实时速率边界、自定义计费、历史聚合，以及菜单栏颜色和会话徽标的关键回归；合并重复用例，清理大规模布局排列与辅助测试。完整历史测试集可从提交 `05db64c` 恢复。Windows 客户端与自托管同步服务保留上游实现，本次改进验收范围为 macOS。

## 文档配图

首页图片由应用的 DEBUG 演示数据渲染。构建 debug 可执行文件后，例如：

```bash
TOKENBAR_DEMO_MODE=1 \
TOKENBAR_DEMO_MULTI_MODEL=1 \
TOKENBAR_DEMO_QUOTA_DAYS=1 \
TOKENBAR_DEMO_DASHBOARD_SECTIONS=speed,quota,today,activity \
TOKENBAR_RENDER_PREVIEW=/tmp/tokenbar-dashboard.png \
.build/debug/TokenBar
```

生成的数据与账户、真实提示词和真实会话分离。演示值用于说明布局与交互，具体费率以设置中的规则及实际价格来源为准。

## 第三方许可证目录

`Resources/ThirdPartyLicenses.html` 收录 Helper 锁定依赖的原始许可、NOTICE 与版权文本，包含条件目标与开发依赖，作为 macOS helper 许可范围的保守超集。生成器要求 Python 3.11+，会核对 Cargo.lock、包 checksum 和每份许可源文件的 SHA-256；缺少源文件或许可时会中止。

```bash
cargo vendor --manifest-path Helper/Cargo.toml --locked /tmp/tokenbar-vendor
python3.11 Scripts/generate_locked_licenses.py --vendor /tmp/tokenbar-vendor
```

`Scripts/generate_licenses.sh` 保留上游的 cargo-about 流程。当前目录可通过上述锁定依赖生成器复现；多许可依赖会明确列出所选择的宽松许可，同时保留随包提供的原文与署名。
