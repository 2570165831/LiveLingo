# 从源码构建 LiveLingo

本文件面向开发者。普通用户请直接下载安装包，见 [README](../README.md#下载)。

## 构建 App

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

## 运行库与模型

- 语言运行库版本见 [MLXRuntime.lock.json](../Packaging/MLXRuntime.lock.json)，ASR 环境见 [ASRRuntime.lock.json](../Packaging/ASRRuntime.lock.json)。这些文件不是完整的自动安装配方。
- `Scripts/prepare-mlx-runtime.py` 从已准备好的环境组装语言运行库并核对版本；不会创建环境或下载依赖。参数见其 `--help`。
- ASR 需要完整便携 CPython 树，不能直接用 venv 代替。
- 模型名称、来源与许可见 [第三方声明](../Packaging/THIRD_PARTY_NOTICES.md) 及 [模型说明](../Packaging/ModelNotices/)。模型目录结构须与 `Scripts/bundle-mlx-app.py` 的映射一致。
- MLX、Outlines Core 等原生依赖须使用兼容 macOS 14 的构建。打包脚本检查最低系统版本；安装最新依赖不能替代兼容性验证。
- 模型加载时的语法词表改用内置字符转换，保留每个原始字节和 token ID；未知 ByteLevel 字符仍拒绝，普通新增 token 仍按 UTF-8 编码，特殊 token 仍排除。词表仍在加载时准备，不把开销移到首次笔记。`test_grammar_bytes.py` 检查无效 Latin-1 字符、其他 Unicode、代理项及新增/特殊 token 边界；`test_grammar_vocabulary.py` 可用本地分词器核对中文、化学式和表情。构建步骤变快不等于整场翻译加速或耗电下降。
- 普通翻译和摘要会复用同一模型中完全相同的输入前缀，减少任务切换后重复读取固定提示。非思考模式的结构化笔记也可使用剩余额度，最多保存 256 个输入 token；普通任务最多保存 512 个。每个已加载模型仍最多保留两份快照，合计受 128 MiB 限制。笔记不能挤掉字幕或普通摘要的快照，也不改变它们的淘汰顺序；普通任务需要空间时先释放笔记快照，再释放最久未使用的普通快照。优先复用最长的完全一致前缀，每个请求取得独立副本，语法约束状态分别创建。不复用生成答案、不裁剪输入；思考、带输出前缀的续写和断点恢复不读取新请求的前缀缓存，模型卸载时缓存一并释放。
- 笔记缓存的本机验证包括 94 项运行库检查，以及 4B、9B 共 44 次生成的 22 组对照，完整文本和 token 序列均一致；8 次中途恢复及 8 次完成结果重放通过。每档只有两组笔记缓存命中的计时样本，平均数、中位数和最长耗时均保留；这些结果不等于真实课堂准确率、普遍加速或整机省电。新增笔记快照会使用部分原来空闲的内存额度，总上限不变。
- 翻译前的字母拼读纠错只匹配完整词组，避免把 `This N two`、`alpha T plus` 等普通表达拼成化学缩写。铁离子名称纠错只使用紧跟该名称的 `Fe³⁺`，保留同段其他亚铁离子、反应起点及比较对象。相关正反例见 `SessionExporterTests.swift`；合成例句的通过情况不等于真实课堂准确率。
- 字幕翻译完整保留已识别的化学式、括号和电荷；公式标记遗漏、重复或变形时拒绝该次结果，流式字幕也隐藏未能还原的标记。单位、pH 和仪器名称保留可读形式，避免模型失去理解上下文所需的信息。当前句单独翻译；前句的可选修正仍可参考上下文，但化学式写法或数量改变时保留原有译文。辅助识别不再重复提示已经明确保护的公式。检查覆盖固定合成样例，不能保证任意化学式、语义或真实课堂准确率。
- 明确的字面代码标签及有向量、矩阵、变量等名称语境的字母拼读先保留原文，再进入纠错和翻译。例如 `N two` 不根据猜测改成平方，`"S N two"` 作为确切代码文本时不改成 `SN2`。真正的平方/立方表达、普通引述句和化学反应拼读仍按原有语义处理。输入中的请求和命令作为课堂内容翻译，不作为给模型的指令执行。这是有限名称规则，不能替代真实课堂全流程验收。
- 字幕首译与恢复结果都要通过原文保留、正文和长度检查；已判为异常的译文不再以完成态保存，英文仍保留。内容拒绝时换一组纠正指令，输出上限不足时扩大预算，临时或未分类运行错误保留一次普通重试；缺少模型不重复请求。每段最多恢复一次，仍检查取消、会话与原文修订身份。
- 保护公式/名称用的内部标记较占输出 token，首译预算在原有 160 基础上按每个标记增加 8，最高 640；预算恢复最多翻倍至 1280，30 秒请求时限不变。两档模型的合成容量样例验证了从两次截断到一次完整输出，不能换算成真实课堂准确率或省电比例。
- 相邻前句的可选补全发生运行错误时，保留已通过检查的当前句，避免为它再生成一次。中文已有稳定前缀、英文却没有可对应尾句时跳过这次不会采用的补全。取消仍向上传递，当前句未通过检查时仍按原有策略恢复。`CaptionIdentityTests.swift` 用可控模型返回及故障检查真实字幕队列的结果和调用次数，不代表真实课堂准确率或耗电测量。
- 长度检查沿用 1.3 的汉字/原文字符容差，但原文短于 24 字符时不再完全跳过，而是按 24 字符留出最低额度。忽略原文首尾空白和应用自己的“公式待核对”提示，计数覆盖正文验收支持的各个汉字区段。缩写全称和纯公式仍可通过，异常长中文不能直接成为完成字幕；这只是粗略长度判断，不能发现短的误译、所有英文混入或保证真实课堂误拒率。
- `Scripts/benchmark-prefix-cache.py` 可用本地模型和修改前的 `engine.py` 对照计时，并逐 token 核对合成课堂样例。它测量模型已加载后的请求耗时；这不等于真实课堂准确率或整机耗电测试。`Scripts/mlx_runtime/test_prefix_cache.py` 与 `test_prefix_rotation.py` 检查注意力缓存、循环状态、任务切换、总容量限制、请求隔离和恢复边界，不加载模型权重。
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

输出目录必须不存在。组装后的 App 包含运行库和模型，排除录音测试 CLI、质量评估 CLI、XCTest 与虚拟音频播放器。开发 CLI 的说明见 [Scripts/CLI-README.md](../Scripts/CLI-README.md)，它只供开发测试，不随 App 或 DMG 交付。

## 签名、公证与 DMG

签名材料和公证凭据不存入仓库。发布者必须显式提供自己的 Developer ID 身份、证书及钥匙串路径；证书须有效，并与钥匙串中可用的私钥匹配。公证只使用发布者本机已有的 `notarytool` keychain profile，不接受仓库内的密码、API key 或凭据文件。

本文沿用原脚本的 `<你的 profile>` 占位写法；这个源码起点没有记录具体 profile 名，不能据此猜测发布者本机的配置。真实运行时必须把它替换为已有名称，也可用 `LIVELINGO_NOTARY_PROFILE` 指定。占位符或空名称会在提交前报错；脚本不创建、导入或解锁钥匙串。

```sh
./Scripts/sign-offline-app.py --app work/OfflineCandidate/LiveLingo.app \
  --identity 'Developer ID Application: Example Name (TEAMID)' \
  --certificate /absolute/path/to/developer-id.cer \
  --keychain /absolute/path/to/login.keychain-db

./Scripts/build-offline-dmg.sh --app work/OfflineCandidate/LiveLingo.app \
  --identity 'Developer ID Application: Example Name (TEAMID)' \
  --keychain /absolute/path/to/login.keychain-db \
  --notary-profile '<你的 profile>' \
  --output work/OfflineDMG/LiveLingo-next-macOS14+-arm64.dmg
```

`build-offline-dmg.sh` 的正常运行会签名 DMG 并向苹果上传两件发布产物，须在真实发布已获授权、凭据已准备好后执行。App 签名仍由前一条 `sign-offline-app.py` 命令完成，打包脚本不会补签或降低签名要求。完整顺序是：

1. 完整签名 App，校验签名、entitlements、自包含依赖与 macOS 14 最低版本。
2. 复制到独立暂存目录，原输入 App 保持只读。用 `ditto -c -k --sequesterRsrc --keepParent` 把暂存 App 打成 ZIP，保留资源和目录结构；不拿最终 DMG 代替 App 的公证容器。
3. 提交 App ZIP，用返回的 submission ID 查询到 `Accepted`。
4. 对同一暂存 App 执行 `xcrun stapler staple`、`xcrun stapler validate` 和 `codesign --verify --deep --strict`。任何一步失败都不生成 DMG，装订后不再修改或重新签名 App。
5. 用已装订的 App 创建 DMG，然后签名并校验 DMG。
6. 提交签名后的 DMG，仍按 submission ID 查询到 `Accepted`，再对 DMG 装订票据。
7. 检查最终 DMG 的票据、严格签名和镜像完整性，只读挂载它，对**镜像内的 App**执行 `stapler validate`、`codesign --verify --deep --strict` 和 `spctl --assess --type execute`；成功卸载后才报告发布自检通过。

DMG 顶层仍只有 App、“应用程序”快捷方式和使用说明。App ZIP、提交编号、苹果返回的日志都在 `work/OfflineDMG/stage-.../` 的包内容之外，不进入 DMG，也不提交到 Git。APFS 暂存可复用文件块，但 ZIP 和 DMG 会另占空间，发布前须准备足够的临时空间。暂存 App 用于核对票据，ZIP 对应 App 提交，日志用于故障诊断；验收完成且不再需要恢复该次发布后，再按授权清理这些中间产物。

该流程用于下一次发布，不能证明旧安装包的 App 已有票据，也不改变 0.2.0 用户首次打开时需要联网查询的发布说明。签名、公证服务返回 `Accepted`、票据装订和实际离线启动分别验证；挂载自检也不能代替干净 macOS 14 的离线 Gatekeeper 与模型功能测试。

### 不使用 `--wait`：有界轮询与恢复

0.2.0 发布时，`notarytool --wait` 曾以退出码 **138** 崩溃，还有一次提交停留在处理中约 **9 小时**。这两件事不代表苹果已经拒绝该提交，也不能直接认定是同一个原因。新流程由 `Scripts/notarize-artifact.py` 执行：`notarytool submit ... --output-format json` 后保存 ID，再用 `notarytool info <ID> ... --output-format json` 轮询；不使用 `--wait`，不自动重复上传。

| 参数 | 默认值 | 范围 |
| --- | --- | --- |
| `--notary-timeout` | 3600 秒 | 每件产物从提交开始的总时限，包含上传与查询 |
| `--notary-command-timeout` | 600 秒 | 单次命令时限，最多使用总时限的剩余时间 |
| `--notary-poll-interval` | 30 秒 | 相邻查询的等待间隔 |
| `--notary-max-polls` | 120 次 | 每件产物的查询总次数，失败查询也计数 |
| `--notary-max-retries` | 3 次 | 连续查询失败后的重试次数；成功查询重置此计数，提交不重试 |

上传大文件时，可按实际连接速度显式调整超时；这些数值是停止条件，不是预计公证完成时间。`Invalid`、`Rejected`、编号不匹配或未知状态都会停止，拒绝时在剩余时限内尝试保存苹果诊断日志；达到时限、次数或重试上限也会停止。未通过完整流程的 DMG 不能当作发布通过。

如果上传报错、超时或返回无法解析的内容，结果可能不明，不能假定未上传就重跑。先读取对应 `notary-app/` 或 `notary-dmg/` 中的输出和 `receipt.json`；没有 ID 时，用相同 profile 的 `notarytool history` 核对该次提交。已有 ID 可继续查询，不再次上传：

```sh
./Scripts/notarize-artifact.py \
  --submission-id '<原提交编号>' --profile '<你的 profile>' \
  --keychain /absolute/path/to/login.keychain-db \
  --receipt-dir work/notary-resume-new-run
```

恢复查询的日志目录必须是新目录。此命令只查询状态，不装订票据、不生成 DMG；得到 `Accepted` 后须继续处理原暂存 App 或原 DMG，并重新检查最终版本。失败的 DMG 会保留，打包脚本拒绝覆盖已有输出，不应通过盲目重跑来恢复。

### 发布前自检与无凭据自测

完整打包流程会自动调用以下独立检查，也可在分发前对同一份最终 DMG 重跑：

```sh
./Scripts/verify-release-dmg.sh --dmg work/OfflineDMG/LiveLingo-next-macOS14+-arm64.dmg
```

检查会验证 DMG 的票据、签名和完整性，随后只读挂载，检查镜像内 App 的票据、严格签名和 `spctl` 结果；检查失败也会尝试卸载，卸载失败会报告挂载目录并返回失败。未给 `--dmg` 或使用 `--dry-run` 时明确说明**跳过真实产物检查**，不算验收通过；显式给出的文件不存在会报错。真实发布必须给出最终文件，不能使用跳过结果放行。

不需要凭据和真实产物时，使用：

```sh
./Scripts/build-offline-dmg.sh --dry-run
/bin/zsh -n Scripts/build-offline-dmg.sh
/bin/zsh -n Scripts/verify-release-dmg.sh
python3 Scripts/test-release-flow.py
```

打桩自测在当前 worktree 的 `work/release-flow-tests/` 下创建最小假 App 和假钥匙串文件，把假 `xcrun`、`notarytool`、`stapler`、`codesign`、`hdiutil`、`spctl` 放在 PATH 前面；结构签名预检也由明确的测试替身处理。它验证步骤顺序、按 ID 轮询、查询恢复、超时和重试上限、拒绝后停止、挂载检查失败后的卸载、原 App 不变及已有输出保护。命令轨迹和结果保留在该目录，不删除其他文件、不访问真实钥匙串、不上传文件，也不验证真实签名、公证或 Gatekeeper 可用性。真实发布仍须发布者用有效身份和已有 profile 执行完整流程，再完成干净 macOS 14 离线安装与功能验收。

`Scripts/run-qwen-service.sh`、`Scripts/install-qwen-service.sh` 和 `Packaging/*.command` 是历史服务与旧安装布局的辅助脚本，不属于当前安装步骤。

## 验证记录

旧发布记录中的 97 项 Swift 测试、6 项 Python 测试和旧 macOS 14 虚拟机结果仅作为历史证据。本轮固定候选 6 在主机上重新完成了 394 项通过、1 项跳过、0 项失败的 Xcode 测试，并完成 CLI 生命周期、真实子进程与 ASR Python 定向检查。

2026-09-23 又对最终候选 6 完成了真实 GUI 文件导入：40.89 秒 WAV 经界面选择后生成 4 段英文转写、中文译文、双语字幕、学习摘要、录音和会话持久化文件，最终 journal 状态为 `completed`，无待处理字幕或笔记批次。此前文件面板里“导入”灰掉的现象已复现为自动化未真正选中文件；真实选中文件后按钮会正常启用。

2026-09-23 已在 Apple Silicon 的 macOS 14.6.1（23G93）Parallels VM 上完成最终候选实测。重新挂载正式 `LiveLingo-0.1.0-20260922-macOS14+-arm64.dmg` 时，镜像 CRC 校验通过；DMG 内 App 读回为 `0.1.0 / 20260922.2`，主程序 SHA-256 与最终候选一致，严格代码签名验证通过，Gatekeeper 返回 `accepted / Notarized Developer ID`。同一验收轮保存的 GUI 截图确认最终 DMG App 能在 macOS 14 启动；40.89 秒 WAV 的完整本机模型流程生成 4 段转写、4 段翻译、整课摘要与复查结果，并导出 Markdown、纯文本、Word 和 PDF。最终记录为 `processing_finished`、`run_verified`，转写待处理数为 0，退出后 `asrRunning=false`、`remainingMLX=0`。当前面向 Apple 芯片；Intel 与 Universal 构建未验证。

便携运行库还不能从本仓库一条命令重建。依赖版本与许可清单已保留，但仍需开发者准备匹配的环境及兼容 macOS 14 的原生依赖。
