# Apple 平台符合性审计

审计日期：2026-08-24

## 结论

当前源码和本机构建符合 Apple 对 macOS App Sandbox、用户选择文件访问、安全范围书签、App 数据容器和标准 App bundle 布局的主要技术要求。本机 DMG 是临时签名的私人构建，不是 Apple 公证发行版，也不是可直接上传的 Mac App Store 包。

## 已符合的部分

- 开启 `com.apple.security.app-sandbox`，权限仅包含用户选择文件夹的读写和 App-scope bookmark。
- 媒体库由 `NSOpenPanel` 明确选择；持久访问使用 `.withSecurityScope` bookmark，解析后成对调用 `startAccessingSecurityScopedResource()` 与 `stopAccessingSecurityScopedResource()`。
- SQLite、WAL/SHM、备份和 bookmark 位于沙盒 Application Support，不写入媒体库。
- SQLite 使用 WAL、`synchronous = FULL`、外键、事务和 Online Backup API；文件夹重命名和批量移动有冲突检查与回滚。
- 用户删除人物时仅删除 SQLite 记录，不删除用户媒体；会改变文件系统的操作在 UI 中有明确提示。
- 界面使用 SwiftUI 原生 `NavigationSplitView`、Inspector、Toolbar、Menu 和标准选择面板；主要操作有键盘快捷键、焦点操作、访问性标签与状态反馈。
- App 包含标准 `Contents/MacOS`、`Contents/Resources`、`Info.plist`、分层 App Icon 和 `.icns` 回退图标。
- `PrivacyInfo.xcprivacy` 明确声明不跟踪、不向设备外收集数据，并说明对 App 容器和用户选定文件元数据的访问原因。
- Bundle 最低系统版本与 Swift 二进制部署目标统一为 macOS 15.0。
- 构建脚本使用 Hardened Runtime，不使用 Apple 明确不建议的 `codesign --deep` 签名方式；`--deep` 仅用于递归验证。

## 分发前仍需外部条件

- Mac App Store 外分发：需要 Apple Developer Program 中的 Developer ID Application 证书、安全时间戳、Apple 公证和 stapling。构建脚本已支持该流程，但仓库不能包含证书或公证凭据。
- Mac App Store：需要开发者账号中的唯一 App ID、Mac App Distribution 签名/配置、App Store Connect 隐私政策 URL、隐私标签、应用描述/截图/年龄分级和 App Review。这些不能仅通过本地源码证明完成。
- 当前只产出 arm64，符合项目“Apple Silicon 本机版”的范围，但不支持 Intel Mac。
- App Review 是 Apple 的人工/服务端决定；本审计只能证明当前工程没有已知的本地技术阻断项，不能代替 Apple 的最终审批。
- Human Interface Guidelines 和访问性最终仍需要在受支持的实机系统上完成 VoiceOver、键盘导航、对比度、缩放与不同窗口尺寸的人工 QA。

## Apple 一手资料

- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Adding a privacy manifest to your app](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
