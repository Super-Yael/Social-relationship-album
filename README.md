# 个人相册（本机版）

这是针对 Apple Silicon Mac（macOS 15 或更高版本）构建的本地个人相册。

## 数据原则

- `nickname` 及其一级子文件夹是唯一媒体文件夹规范。
- App 使用 App Sandbox；用户选择的媒体库权限通过安全范围书签保存。
- SQLite、数据库备份和媒体库书签全部位于 App 自己的 Application Support 数据目录，App 不会在媒体库旁写入配置或数据库。
- App 每次启动都会扫描 `nickname`，运行期间也会监听一级目录变化并自动补录新文件夹；顶栏可随时手动扫描。
- 自动与手动扫描都只新增尚未入库的明文路径，不覆盖已有资料，也不会因文件夹消失而自动删除数据库记录。
- App 只会在用户主动操作时新建或重命名人物文件夹，或将拖入预览区的文件移入当前人物文件夹。
- 左侧“新建文件夹”只在 `nickname` 根目录创建一个空的直属子文件夹，等价于安全的 `mkdir`。
- 人物资料中的“重命名文件夹”会先备份数据库，再重命名直属子文件夹并同步 SQLite；数据库写入失败时会尝试恢复原名称。
- 点击人物时，App 才递归读取对应文件夹，用于图片和视频预览。
- SQLite 只保存人物字段和明文文件夹路径。
- 默认提供微信、QQ、X、TG、抖音、小蓝六个平台；每个平台末尾的加号可增加一条记录。
- 顶栏“平台管理”可新增、重命名和删除平台；仍有账号数据的平台会由界面和 SQLite 外键双重禁止删除。
- 资料修改会在停止输入 700 毫秒后自动保存；`⌘S` 可立即保存，界面持续显示保存状态。
- 人物列表使用系统侧边栏，资料字段使用系统 Inspector；两者都可通过“显示”菜单隐藏或显示，窄窗口会自动适配。
- 窗口变窄时会先自动收起资料 Inspector，再收起人物侧边栏；侧边栏可见时始终保持可读宽度，符合 macOS 窗口自适应惯例。
- 工具栏中的主要操作同时出现在菜单栏中，并提供常用键盘快捷键。
- 人物侧边栏可按“某个平台存在非空记录”筛选，并按名称、添加日期或修改日期升降序排列；选择会保存在 App 容器内的 SQLite 设置中。
- 媒体支持单击选择、方向键移动，以及空格或 Return 预览。
- 预览区支持同时拖入一个或多个本地文件；App 在后台使用文件系统移动将它们放入当前人物文件夹，完成后自动刷新。若目标存在同名文件，整批移动会在写入前拒绝，不会覆盖。
- Finder 旧备注在导入时分类进入五个平台，App 不再保留或显示原 Finder 备注字段。
- 删除人物表示删除 SQLite 记录，不会删除文件夹。
- 新增或修正路径时，只接受 `nickname` 的直属子文件夹。
- App 禁止同时运行多个实例，避免并发编辑同一数据库。

## 默认位置

- 媒体库：首次运行时选择 `nickname` 文件夹；之后通过安全范围书签恢复访问。
- App 数据目录：沙盒容器中的 `Library/Application Support/local.yael.personal-album`
- 数据库：App 数据目录中的 `个人相册.sqlite`
- 备份：App 数据目录中的 `个人相册数据库备份`
- 配置：App 数据目录中的 `library-root.bookmark`

如果书签失效或媒体库不存在，App 会要求重新选择 `nickname` 文件夹。数据库、备份和配置位置不会因此改变。

从旧版本升级时，可在首次选择媒体库前点击“先导入旧数据库备份…”，或之后使用“相册 > 导入旧数据库备份…”。App 只读取用户明确选择的 `.sqlite` 一致性备份，并将独立副本导入 App 数据目录；旧文件不会被修改。

## 备份

- 每次启动保存当前快照；字段写入或删除前后都使用 SQLite Online Backup API 创建一致性备份。
- 备份目录总量上限为 50 MiB。
- 超出上限后从最旧备份开始清理。
- 即使单个数据库已经大于 50 MiB，也至少保留最新一份备份。

## 构建

构建需要 Xcode 26 或更高版本：脚本会用 `actool` 将 `Packaging/AppIcon.icon` 编译为分层图标，并保留 `AppIcon.icns` 作为较旧系统的兼容回退。默认产物使用 Hardened Runtime 与本机临时签名，仅适合本机使用。

```sh
./Scripts/build_dmg.sh
```

产物位于 `dist/个人相册.app` 和 `dist/个人相册-本机版.dmg`。

要在 Mac App Store 之外分发，请使用 Developer ID Application 证书签名并通过 Apple 公证。脚本支持从环境变量读取签名身份和 `notarytool` 钥匙串配置：

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARYTOOL_PROFILE="personal-album-notary" \
./Scripts/build_dmg.sh
```

本机临时签名的 DMG 不等同于已公证发行版。Mac App Store 提交还需要在 App Store Connect 中注册 Bundle ID、提供隐私政策与元数据，并使用 Mac App Distribution 工作流签名上传。

## 许可证

本项目采用 [MIT License](LICENSE)。
