# 阅读 · iOS

基于 [Legado with MD3](https://github.com/HapeLee/legado-with-MD3) 的功能设计，用 SwiftUI 重写的 iPhone 和 iPad 阅读器。应用使用 Xcode 27 和 iOS 27 SDK 构建，最低运行版本设为 iOS 26.0。iOS 27 上，书架的导入入口固定在导航栏，布局操作进入系统溢出菜单，滚动正文使用系统文本范围选择。项目没有第三方构建依赖。

## 使用

- 在「书架」导入 TXT、EPUB，或从「添加书籍」扫描一个已授权的文件夹。相同文件按内容去重。TXT 自动识别常见中英文标题，EPUB 按阅读顺序导入章节和封面。
- 在「管理 → 书源」从文件、网址或剪贴板导入 Legado 3.0 JSON。书源支持编辑、启停和导出。导入后可在「搜书」输入书名或作者，或在「发现」浏览有静态发现规则的分类。结果详情可加载目录并加入书架。
- 阅读时可切换纵向滚动和横向分页，调整字体、字号、行距、段距、加粗、首行缩进、主题和简繁转换，使用系统语音朗读。书架记住阅读位置，书籍详情提供书签、备注和章节入口。
- 在在线书籍菜单中可更新目录、换源或缓存全书。更换书源后按章节标题迁移位置，匹配不到时用原章节序号。书签仅迁移到标题唯一匹配的章节，位置从章首开始。旧书源的正文缓存会清除。
- 在「管理」配置纯文本或正则净化规则、阅读 RSS 或 Atom，或导出和恢复备份。WebDAV 支持使用 HTTPS 文件地址手动上传和恢复，支持无凭据或 HTTP Basic 验证。备份包括书架、本地正文和在线缓存、书签、进度、备注、书源、净化规则及订阅列表。

## 兼容范围

- 书源引擎支持常见 Legado 原生选择器、CSS、XPath 和 JSONPath 子集、正则提取及替换，以及搜索变量、常用分页、静态请求头、GET/POST 和字符集选项。实际可用性取决于每个书源的规则和目标网站状态。应用未预装第三方书源。
- JavaScript、WebView 执行、登录脚本和人机验证流程尚未移植。漫画、有声书专用源、HTTP 朗读引擎和原版统计功能也尚未移植。系统语音用于朗读文本。
- EPUB 按文本呈现，支持未加密的常规 EPUB 2/3、目录、章节和封面。插图、原书 CSS、固定布局、音视频和 DRM 未移植。超长正文会拆成续节以控制单次排版量。
- 应用备份是 iOS 版自己的格式。原版 Android 的整库备份兼容性尚未实现，可独立导入其 Legado 3.0 书源 JSON。WebDAV 是手动备份和还原，恢复会覆盖应用内对应的数据。

## 在 Mac 上构建

1. 安装 Xcode 27，并打开 `Legado.xcodeproj`。
2. 选中 `Legado` scheme 和 iOS 27 模拟器，按 **Run**。
3. 真机运行时，在 **Signing & Capabilities** 选择自己的 Team，根据账号需要将 Bundle ID 改为自己的唯一标识，再选择 iPhone 或 iPad。
4. 需要 IPA 时，选择 **Any iOS Device (arm64)** 后执行 **Product → Archive**。在 Organizer 中按账号和设备条件选用 Development 或 Ad Hoc 等分发方式。签名证书及描述文件由构建者配置。

```bash
swift test
xcodebuild -project Legado.xcodeproj -scheme Legado \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

仓库中的 `Verify iOS project` 工作流使用 GitHub 的 `xcode-27` runner，执行 Swift 核心测试和 iOS 模拟器目标构建。本次交付在 Windows 的 WSL 环境通过 18 项 Swift 核心测试，并检查了 iOS 源码语法。iOS 界面、模拟器构建和签名流程仍需要在 Mac 上验证。

## 许可

本项目使用 [GPL-3.0](LICENSE)。功能设计参考 [HapeLee/legado-with-MD3](https://github.com/HapeLee/legado-with-MD3)，应用以 Swift 实现。
