# LiveLingo 0.1.0

面向英语课堂的本机转写、中文翻译和学习笔记工具，使用 SwiftUI 构建，支持 Apple 芯片 Mac，最低部署目标为 **macOS 14**。

## 源码、本机应用与发布包

开发源码和公开安装包可能处于不同版本，下面分别列出。

- **当前开发源码**的版本为 `0.1.0 / 20260928.8`，包含原生课堂工具栏、字幕翻译的输入前缀缓存、减少笔记完成后写盘、输入纠错边界，化学式和字面名称保留修正，以及按失败原因恢复字幕翻译。相邻前句补全失败时保留已完成的当前句；无法对应英文尾句的补全不再重复计算。验收方法见下方“运行库与模型”。
- **本机应用**的实际版本以“关于 LiveLingo”显示为准；拉取源码不会自动更新已安装的 App。
- **公开离线安装包**为 `LiveLingo-0.1.0-20260924.0014-macOS14+-arm64.dmg`，内置构建号 `20260923.1`。公开标签按 9 月 24 日 00:14（悉尼时间）收到苹果公证通过结果的时间命名。签名、公证及验证范围见 [20260924 发布说明](RELEASE_NOTES_20260924.md)。

## 能做什么

- 从麦克风或系统音频（内录）接收英语，显示英文转写与中文翻译。
- 提供悬浮字幕、录音暂停和继续、双语历史及录音导出。
- 增量生成学习笔记，分别显示最近更新与整课内容。
- 课堂界面以字幕和笔记为主：宽窗口双栏阅读，窄窗口切换阅读内容；可关闭“跟随最新”查看先前字幕。课堂设置、文字翻译和笔记核对通过独立入口打开，提示详情展开时保留正文位置。
- 录音结束后可手动启动 9B 思考复查，保留笔记正文，单独显示意见；支持暂停和恢复。停止录音本身不会自动启动复查。
- 打开已保存课程，恢复字幕、笔记及可恢复的处理进度；采集始终等待用户主动开始。旧课程缺少来源或批次信息时会说明限制。
- 转写积压保存为待处理任务，可暂停、继续或主动重试；存在正文的修正先保留为候选，确认后再更新相关内容。
- 模型在本机运行。应用管理 MLX / MLX-LM 和转写进程，不需要 LM Studio。

转写使用 Parakeet TDT 0.6B v2，异常结果可回退到 Qwen3-ASR 1.7B；翻译与笔记使用 Qwen3.5 4B / 9B。最终 JSON 使用 Outlines 约束，明确的计算可由 Pint、SymPy 和 ChemPy 辅助检查。模型仍可能漏译、误译或给出错误知识；格式约束与计算检查不能保证内容正确。

## 下载与安装

新版公开标签为 `0.1.0 / 20260924.0014`，App 内部构建号为 `20260923.1`，适用于 Apple 芯片 Mac（macOS 14 及以上）。[新版发布页](https://github.com/2570165831/LiveLingo/releases/tag/v0.1.0%2B20260924.0014)提供 Google Drive 完整 DMG 的直达链接，以及同一 DMG 的 GitHub 分卷与合并说明；分卷不能单独打开。

`20260922.2` 安装包的公开下载仍已撤回。[更早的 `v0.1.0` 发布页](https://github.com/2570165831/LiveLingo/releases/tag/v0.1.0)和[对应 Google Drive 完整 DMG](https://drive.google.com/file/d/1QHdsMVbiWxhJ9bdzctMRr3ka02Hr9D-T/view?usp=sharing)仍保留，文件名不带 `20260922` 或 `20260923`，不包含本轮整改。

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

旧发布记录中的 97 项 Swift 测试、6 项 Python 测试和旧 macOS 14 虚拟机结果仅作为历史证据。本轮固定候选 6 在主机上重新完成了 394 项通过、1 项跳过、0 项失败的 Xcode 测试，并完成 CLI 生命周期、真实子进程与 ASR Python 定向检查。

2026-09-23 又对最终候选 6 完成了真实 GUI 文件导入：40.89 秒 WAV 经界面选择后生成 4 段英文转写、中文译文、双语字幕、学习摘要、录音和会话持久化文件，最终 journal 状态为 `completed`，无待处理字幕或笔记批次。此前文件面板里“导入”灰掉的现象已复现为自动化未真正选中文件；真实选中文件后按钮会正常启用。

2026-09-23 已在 Apple Silicon 的 macOS 14.6.1（23G93）Parallels VM 上完成最终候选实测。重新挂载正式 `LiveLingo-0.1.0-20260922-macOS14+-arm64.dmg` 时，镜像 CRC 校验通过；DMG 内 App 读回为 `0.1.0 / 20260922.2`，主程序 SHA-256 与最终候选一致，严格代码签名验证通过，Gatekeeper 返回 `accepted / Notarized Developer ID`。同一验收轮保存的 GUI 截图确认最终 DMG App 能在 macOS 14 启动；40.89 秒 WAV 的完整本机模型流程生成 4 段转写、4 段翻译、整课摘要与复查结果，并导出 Markdown、纯文本、Word 和 PDF。最终记录为 `processing_finished`、`run_verified`，转写待处理数为 0，退出后 `asrRunning=false`、`remainingMLX=0`。当前面向 Apple 芯片；Intel 与 Universal 构建未验证。

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

`Scripts/recover-orphan-recordings.py` 检查异常退出后尚未收尾的 WAV。只在头部完整、编码支持且音频边界可确认时恢复；正常音频后的元数据、非零数据长度及结构不明确的文件不会被任意扩展。
**默认只报告，加 `--export` 才写出新文件，源文件始终只读，也不覆盖已有同名输出**。恢复期间源文件变化时，该次输出不计为成功；参数见其 `--help`。

### 运行库与模型

- 语言运行库版本见 [MLXRuntime.lock.json](Packaging/MLXRuntime.lock.json)，ASR 环境见 [ASRRuntime.lock.json](Packaging/ASRRuntime.lock.json)。这些文件不是完整的自动安装配方。
- `Scripts/prepare-mlx-runtime.py` 从已准备好的环境组装语言运行库并核对版本；不会创建环境或下载依赖。参数见其 `--help`。
- ASR 需要完整便携 CPython 树，不能直接用 venv 代替。
- 模型名称、来源与许可见 [第三方声明](Packaging/THIRD_PARTY_NOTICES.md) 及 [模型说明](Packaging/ModelNotices/)。模型目录结构须与 `Scripts/bundle-mlx-app.py` 的映射一致。
- MLX、Outlines Core 等原生依赖须使用兼容 macOS 14 的构建。打包脚本检查最低系统版本；安装最新依赖不能替代兼容性验证。
- 普通翻译会复用同一模型中完全相同的输入前缀，减少重复计算翻译规则。每个已加载模型只保留一份快照，最多 512 个输入 token、128 MiB；不复用生成答案，不裁剪输入。语法约束、推理和断点恢复仍走原有路径，模型卸载时缓存一并释放。
- 翻译前的字母拼读纠错只匹配完整词组，避免把 `This N two`、`alpha T plus` 等普通表达拼成化学缩写。铁离子名称纠错只使用紧跟该名称的 `Fe³⁺`，保留同段其他亚铁离子、反应起点及比较对象。相关正反例见 `SessionExporterTests.swift`；合成例句的通过情况不等于真实课堂准确率。
- 字幕翻译完整保留已识别的化学式、括号和电荷；公式标记遗漏、重复或变形时拒绝该次结果，流式字幕也隐藏未能还原的标记。单位、pH 和仪器名称保留可读形式，避免模型失去理解上下文所需的信息。当前句单独翻译；前句的可选修正仍可参考上下文，但化学式写法或数量改变时保留原有译文。辅助识别不再重复提示已经明确保护的公式。检查覆盖固定合成样例，不能保证任意化学式、语义或真实课堂准确率。
- 明确的字面代码标签及有向量、矩阵、变量等名称语境的字母拼读先保留原文，再进入纠错和翻译。例如 `N two` 不根据猜测改成平方，`"S N two"` 作为确切代码文本时不改成 `SN2`。真正的平方/立方表达、普通引述句和化学反应拼读仍按原有语义处理。输入中的请求和命令作为课堂内容翻译，不作为给模型的指令执行。这是有限名称规则，不能替代真实课堂全流程验收。
- 字幕首译与恢复结果都要通过原文保留、正文和长度检查；已判为异常的译文不再以完成态保存，英文仍保留。内容拒绝时换一组纠正指令，输出上限不足时扩大预算，临时或未分类运行错误保留一次普通重试；缺少模型不重复请求。每段最多恢复一次，仍检查取消、会话与原文修订身份。
- 保护公式/名称用的内部标记较占输出 token，首译预算在原有 160 基础上按每个标记增加 8，最高 640；预算恢复最多翻倍至 1280，30 秒请求时限不变。两档模型的合成容量样例验证了从两次截断到一次完整输出，不能换算成真实课堂准确率或省电比例。
- 相邻前句的可选补全发生运行错误时，保留已通过检查的当前句，避免为它再生成一次。中文已有稳定前缀、英文却没有可对应尾句时跳过这次不会采用的补全。取消仍向上传递，当前句未通过检查时仍按原有策略恢复；公式和长度判断保持原样。`CaptionIdentityTests.swift` 用可控模型返回及故障检查真实字幕队列的结果和调用次数，不代表真实课堂准确率或耗电测量。
- `Scripts/benchmark-prefix-cache.py` 可用本地模型和修改前的 `engine.py` 对照计时，并逐 token 核对合成课堂样例。它测量模型已加载后的请求耗时；这不等于真实课堂准确率或整机耗电测试。`Scripts/mlx_runtime/test_prefix_cache.py` 检查注意力缓存、循环状态、并发隔离和恢复边界，不加载模型权重。
- 笔记和复查算完后，只原子保存完整结果及恢复所需元数据，供 App 尚未确认收下时重放；不再写入不会继续计算的模型张量。未完成任务仍保存完整计算状态。同一工作进程中的已完成未确认结果也受缓存清理保护，ACK 或取消后才释放。
- `Scripts/benchmark-checkpoints.py --model /本机模型目录 --output /新的结果目录` 用合成笔记测量实际保存大小、耗时，并核对中途恢复和完成结果重放的逐 token 一致性。单次磁盘耗时不代表整机能耗。`test_checkpoints.py` 和 `test_checkpoint_lifecycle.py` 分别检查原子保存、旧格式读取、错误状态拒绝，以及缓存超额时对仍在使用结果的保护。

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

输出目录必须不存在。组装后的 App 包含运行库和模型，排除录音测试 CLI、质量评估 CLI、XCTest 与虚拟音频播放器。开发 CLI 的说明见 [Scripts/CLI-README.md](Scripts/CLI-README.md)，它只供开发测试，不随 App 或 DMG 交付。

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
