# GoldenNugget Mobile（简体中文汉化版）

这是 [GoldenNugget-Team/GoldenNugget-mobile](https://github.com/GoldenNugget-Team/GoldenNugget-mobile) 的**简体中文汉化版**。应用内全部用户界面（主页、调整、PosterBoard、状态栏、钱包、锁屏密码、守护进程、媒体、文件、设置、设置引导、全部弹窗与运行日志状态）均已翻译为简体中文。

> ⚠️ 请在使用前备份你的数据。GoldenNugget 可能造成不可预见的问题，对设备造成的任何损坏本项目与原项目均不负责。**如出现数据丢失或循环重启，后果自负。**

## 汉化范围

| 部分 | 状态 |
| --- | --- |
| 全部 18 个视图文件（按钮、开关、标题、说明、弹窗、状态行） | ✅ 完整汉化 |
| 调整目录（99 个调整的名称与描述、分区名） | ✅ 完整汉化 |
| 守护进程目录（40 个分组名称、分区名） | ✅ 完整汉化 |
| 墙纸目录来源/分类、旧版格式转换弹窗、预设导入报告 | ✅ 完整汉化 |
| 锁屏键盘主题的语言/字重选项 | ✅ 完整汉化 |
| 深层诊断日志（minimuxer 协议细节、传输故障取证段落） | 保留英文 |

保留英文的内容：品牌名（GoldenNugget）、系统组件名（PosterBoard、SpringBoard、AirLift、LocalDevVPN、minimuxer 等）、调整的逻辑 `id` 与 plist 键名，以及面向开发者的深层取证日志——这些内容在提交问题时需要原文检索。

## 汉化方式

采用**源码级直接替换**（而非 `.strings` 本地化表），因此无论设备系统语言是什么，界面始终显示中文。所有调整的 `id`、写入设备的 plist 键、launchd 标签、预设 JSON 字段名等逻辑字符串均未改动，与上游完全兼容——预设（autosave.json）可正常互导。

## 构建

与上游完全一致（见英文 README）：

- **Xcode（macOS）**：打开 `GoldenNuggetMobile.xcodeproj`，⌘R 安装到设备。
- **xtool（Linux/macOS 命令行）**：`xtool dev build`，或 `scripts/build-ipa.sh` 构建未签名 IPA 后用侧载工具签名安装。

## 与上游同步

上游更新后，重新合并上游代码即可；新增字符串会保持英文显示，不影响功能。注意 `Nugget/Core/TweakCatalog.swift` 与 `TweakCatalogDaemons.swift` 是生成文件——若运行 `scripts/gen-tweaks-from-goldennugget.py` 重新生成，目录内的中文翻译会被覆盖回英文（功能不受影响），需重新汉化该两个文件。

## 许可

与上游一致，见 [LICENSE](LICENSE)。
