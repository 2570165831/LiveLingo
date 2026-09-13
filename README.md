# LiveLingo 0.1.0

面向英语课堂的本机转写、中文翻译和学习笔记工具，使用 SwiftUI 构建，支持 Apple 芯片 Mac，最低部署目标为 **macOS 14**。

## 能做什么

- 从麦克风或系统音频（内录）接收英语，显示英文转写与中文翻译。
- 提供悬浮字幕、录音暂停和继续、双语历史及录音导出。
- 增量生成学习笔记，分别显示最近更新与整课内容。
- 录音结束后使用 9B 模型开启思考复查，保留笔记正文，单独显示意见；支持暂停和恢复。
- 模型在本机运行。应用管理 MLX / MLX-LM 和转写进程，不需要 LM Studio。

转写使用 Parakeet TDT 0.6B v2，异常结果可回退到 Qwen3-ASR 1.7B；翻译与笔记使用 Qwen3.5 4B / 9B。最终 JSON 使用 Outlines 约束，明确的计算可由 Pint、SymPy 和 ChemPy 辅助检查。模型仍可能漏译、误译或给出错误知识；格式约束与计算检查不能保证内容正确。

## 下载与安装

当前安装包为 **`LiveLingo-0.1.0-macOS14+-arm64.dmg`**，适用于 Apple 芯片 Mac（macOS 14 及以上）。此版本已完成 Developer ID 签名与苹果公证。

从 [GitHub 0.1.0 发布页](https://github.com/2570165831/LiveLingo/releases/tag/v0.1.0) 下载全部 8 个 `.part` 分卷，放进同一个新建文件夹，再按附件[分卷合并说明](https://github.com/2570165831/LiveLingo/releases/download/v0.1.0/INSTALL-zh.md)操作。说明中的命令会先检查各分卷是否齐全、大小是否正确，再按顺序还原 DMG，不会覆盖已有同名 DMG。分卷不能单独打开安装，也不是 ZIP 压缩包。

如果拿到的是完整 DMG，就直接打开，将 **LiveLingo 拖入“应用程序”**。不需要运行安装命令。运行库和正式转写、翻译、笔记模型都已内置，无需配置 Python、安装 LM Studio 或另外下载这些模型；App 和 DMG 不包含测试 CLI。首次使用时按系统提示授予麦克风、语音识别、系统音频录制及保存目录等所需权限。

**发布页下方的 `Source code (zip)` 和 `Source code (tar.gz)` 是源码，不是安装包。** 源码仓库不包含模型权重、便携 Python 或已构建的 App，仅编译 Swift 源码不会得到完整的离线应用。

## macOS 14 的功能限制与英文预览

macOS 14 可以使用内置模型做正式英文转写、中文翻译、学习笔记和复查。受系统版本限制的是 **“同步初译”**：它使用苹果翻译接口，需要 **macOS 15 或更新版本**。在 macOS 14 上这个开关不可用，中文需要等正式翻译完成；这不表示 macOS 14 不能翻译。

英文逐词预览是另一项功能：macOS 14 也可以使用，但需要系统具备可用的设备端英语识别资源，并获得语音识别授权。缺少资源时，新系统也可能无法显示逐词预览；正式英文转写仍由内置模型完成。

如果英文逐词预览不可用，可以先联网准备系统资源：

1. 打开 **系统设置 → 键盘 → 听写**。
2. 开启听写，并在语言中添加 **英语（美国）**。
3. 保持联网，等待系统准备语言资源，再打开 LiveLingo 检查预览是否可用。

资源由 macOS 管理，开启听写并不保证 LiveLingo 立即可用，最终以应用实际检测为准。操作入口见[苹果的听写说明](https://support.apple.com/en-euro/guide/mac-help/mh40584/mac)。这是可选的系统预览资源，与 DMG 已内置的正式转写模型不同。

## 验证情况与限制

发布前的功能版本已通过 97 项 Swift 测试、6 项 Python 测试、主机音频回放，以及 macOS 14.6.1 虚拟机断网下的转写、翻译、停止保存与进程恢复检查。此次开源整理主要修改文档、脚本配置和版本标识，未改变应用的转写、翻译及摘要实现。

虚拟机并非全新安装环境，尚不能据此声称完成干净机器的端到端图形界面验收。虚拟机耗时也不代表基础芯片性能。当前面向 Apple 芯片；Intel 与 Universal 构建未验证。

便携运行库还不能从本仓库一条命令重建。依赖版本与许可清单已保留，但仍需开发者准备匹配的环境及兼容 macOS 14 的原生依赖。

## 开发构建

当前开发工具为 Xcode 27.0。目标应用的最低系统版本与构建工具自身的系统要求是两回事。

```sh
git clone https://github.com/2570165831/LiveLingo.git
cd LiveLingo
xcodebuild -project LiveLingo.xcodeproj -scheme LiveLingo \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO build

xcodebuild -project LiveLingo.xcodeproj -scheme LiveLingo \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO test
```

未签名 Release 可使用 `./Scripts/build-release.sh`。需要完整功能时，继续准备并组装运行库和模型。

### 运行库与模型

- 语言运行库版本见 [MLXRuntime.lock.json](Packaging/MLXRuntime.lock.json)，ASR 环境见 [ASRRuntime.lock.json](Packaging/ASRRuntime.lock.json)。这些文件不是完整的自动安装配方。
- `Scripts/prepare-mlx-runtime.py` 从已准备好的环境组装语言运行库并核对版本；不会创建环境或下载依赖。参数见其 `--help`。
- ASR 需要完整便携 CPython 树，不能直接用 venv 代替。
- 模型名称、来源与许可见 [第三方声明](Packaging/THIRD_PARTY_NOTICES.md) 及 [模型说明](Packaging/ModelNotices/)。模型目录结构须与 `Scripts/bundle-mlx-app.py` 的映射一致。
- MLX、Outlines Core 等原生依赖须使用兼容 macOS 14 的构建。打包脚本检查最低系统版本；安装最新依赖不能替代兼容性验证。

```sh
./Scripts/build-release.sh
./Scripts/bundle-mlx-app.py \
  --app work/ReleaseDerivedData/Build/Products/Release/LiveLingo.app \
  --runtime /absolute/path/to/LanguageRuntime \
  --models /absolute/path/to/language-models \
  --asr-models /absolute/path/to/asr-models \
  --asr-python /absolute/path/to/portable-python \
  --output work/OfflineCandidate/LiveLingo.app
```

输出目录必须不存在。组装后的 App 包含运行库和模型，排除测试 CLI、XCTest 与虚拟音频播放器。开发 CLI 的说明见 [Scripts/CLI-README.md](Scripts/CLI-README.md)，它只供开发测试，不随 App 或 DMG 交付。

### 签名与 DMG

签名材料和公证凭据不存入仓库。发布者必须显式提供自己的 Developer ID 身份、证书及钥匙串路径。

```sh
./Scripts/sign-offline-app.py --app work/OfflineCandidate/LiveLingo.app \
  --identity 'Developer ID Application: Example Name (TEAMID)' \
  --certificate /absolute/path/to/developer-id.cer \
  --keychain /absolute/path/to/login.keychain-db

./Scripts/build-offline-dmg.sh --app work/OfflineCandidate/LiveLingo.app \
  --identity 'Developer ID Application: Example Name (TEAMID)' \
  --keychain /absolute/path/to/login.keychain-db
```

DMG 顶层包含 App、“应用程序”快捷方式和使用说明。分发前还需使用自己的 `notarytool` 配置提交苹果公证，成功后执行 `stapler staple` 与 `stapler validate`；签名通过不等于公证通过。

`Scripts/run-qwen-service.sh`、`Scripts/install-qwen-service.sh` 和 `Packaging/*.command` 是历史服务与旧安装布局的辅助脚本，不属于当前安装步骤。

## 数据与隐私

应用在本机处理音频、转写、翻译和笔记。录音模式在用户选择的位置保存录音、双语文本、字幕与学习笔记；实时模式使用临时录音，也可转为录音保存。代码不包含云端推理或上传录音的功能。

请勿向 Issues 或 Pull Request 提交私人录音、完整课堂转写、笔记、凭据或签名材料。反馈与贡献指南见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

除另有注明的第三方内容外，自有代码采用 **GPL-3.0-only**，完整条款见 [LICENSE](LICENSE)。允许商业使用和收费；分发程序或修改版本时须遵守相应源码提供等许可证要求。软件按现状提供，不提供担保。

第三方依赖、模型及对应源码继续适用各自许可证，不因本项目开源而改变。声明见 [Packaging/THIRD_PARTY_NOTICES.md](Packaging/THIRD_PARTY_NOTICES.md)，离线许可与必要的对应源码保留在 [Packaging/MLXLicenses](Packaging/MLXLicenses/)。

官方版本计划免费提供，这是项目的发行安排，并非对其他分发者附加的收费限制。
