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

### 与正式版分开的界面预览包

```sh
./Scripts/build-preview-app.sh
# 可选：只引用本机正式包的模型，不复制模型或运行库
./Scripts/build-preview-app.sh --reference-installed-models
```

脚本离线构建，默认输出到源码目录旁的 `../work/preview/package-<提交>-<随机串>/LiveLingo 预览版.app`，DerivedData 复用该根目录下的 `dd-build-arm64`。默认原生 arm64：destination 与 `ARCHS` 都显式指定 arm64，`ONLY_ACTIVE_ARCH=YES`；打包前用 `lipo -archs` 核对实际架构。仅在明确传入 `--arch x86_64` 时构建 Intel 包。可用 `--output-root /绝对路径` 指定专属目录。不会安装、启动或覆盖已有预览包。Xcode 会自动向 Launch Services 登记构建产物的位置，这是构建副作用，不等于安装；预览包始终使用独立 bundle ID，脚本不改系统偏好或文件关联设置。`receipt.json` 记录实际路径、大小（不跟随模型引用）、架构、Info.plist、完整源提交与是否有未提交改动；构建号含提交短哈希，脏工作区另带 `.dirty`。`codesign-display.log` 保存 `codesign -dv --verbose=4` 的只读结果。

bundle ID 固定为 `com.jianhongli.LiveLingo.preview`，显示名和窗口标题均为“LiveLingo 预览版”。只在这条构建命令中启用 `LIVELINGO_PREVIEW`；正式版的工程设置、bundle ID、模型定位、偏好和数据路径保持原有规则。

**沙盒与数据**：正式版的 `LiveLingo.entitlements` 启用 App Sandbox、用户选择文件读写及 App scope 书签，不含共享 App Group。签名包的生效 entitlements 才构成系统沙盒；`ENABLE_APP_SANDBOX=YES` 或包内声明本身不能使未签名包进入沙盒。正式版容器是否存在也不能证明另一个未签名进程会受沙盒约束。

| 数据 | 未签名预览版 | 将来授权签名且沙盒生效后 |
| --- | --- | --- |
| 偏好、窗口状态 | 独立 preview 偏好域，通常为 `~/Library/Preferences/com.jianhongli.LiveLingo.preview.plist` | preview 容器内的同名偏好域 |
| App Support | `~/Library/Application Support/LiveLingoPreview/` | `~/Library/Containers/com.jianhongli.LiveLingo.preview/Data/Library/Application Support/LiveLingoPreview/` |
| MLX 检查点 | 上述根目录的 `LanguageRuntime/Checkpoints/{4b,9b}` | 同样位于 preview 容器的数据根目录内 |
| 复查队列、诊断、目录书签 | 根目录的 `learning-review-queue.json`、`ReviewDiagnostics/`；书签保存在队列任务中 | 同上，不读取正式版队列或其书签 |
| 课程、导出、导入媒体 | 根目录的 `Courses/`；拒绝打开、写入或迁移范围外的课程 | 同一限制，且系统额外实施沙盒权限 |
| 临时录音、ASR 分块、重试音频 | 根目录的 `Temporary/`，会话使用独立 UUID | 同上 |

预览版忽略 `LIVELINGO_PREFERENCES_SUITE`、`LIVELINGO_DATA_DIRECTORY` 与 `LIVELINGO_MLX_*` 的外部覆盖；不会继承正式版保存位置。当前保存目录只保存在 AppModel 内存中，没有单独的偏好书签；复查书签与检查点分别按上表隔离。保存位置按钮在预览版中固定指向自己的 `Courses/`，媒体导入也只接受其中的文件。不要把正式版课程放进去；若需查看合成课程，先放入独立测试副本。路径检查也遍历课程内部的链接，拒绝指向根目录外的内容；拒绝操作不会回退到正式版目录。上述未签名隔离来自应用代码，并非系统级沙盒保证。未签名进程还可能无法创建 App scope 安全书签（系统报 `Failed to retrieve app-scope key`），因此课程迁移、复查定位等依赖此类书签的操作不保证可用。

**体积与功能**：默认不带 `Models`、`LanguageRuntime` 或 `ASRRuntime`，也不预热 ASR。可验收窗口、布局、设置、浮动字幕和文件面板；录音转写、MLX 翻译、模型摘要、笔记生成与复查不能用。`--reference-installed-models` 检查 `/Applications/LiveLingo.app` 的正式 bundle ID，只在预览资源中建立 `Models` 软链接；正式包只被读取，不修改权限、模型或设置。它不会补齐 Python 运行库，因此引用后仍是界面试用包。软链接**不是只读挂载**：这里只保证本脚本与所打包代码不向模型目录写入，不声称对其他程序施加只读权限。授权沙盒签名与外部模型引用的组合直接报错；沙盒不会因为软链接就自动获准读取正式包资源，脚本不加临时例外、不借用正式版书签。

**用户手动打开**：默认 arm64 包在严格未签名状态下仅作构建证据，不能直接在 Apple Silicon 上执行；右键“打开”不能补上缺失的代码签名。先取得下面的单独签名授权并生成签名预览包，再在 Finder 中打开回执里的 `.app`，无需放入 `/Applications`。若系统拦截来源不明的应用，先确认构建来源，再用 Finder 右键“打开”；部分系统版本需在“系统设置 → 隐私与安全性”中选择“仍要打开”。提示与入口会随系统版本、隔离属性和组织策略变化，未在本任务中实测；不要全局关闭 Gatekeeper。若系统提示损坏/策略禁止，或仍拒绝打开，停止并检查签名与系统策略，不承诺右键可以解决所有拦截。显式选择的 x86_64 包在 Apple Silicon 上依赖已安装的 Rosetta，脚本不安装它。

**签名是可选且需另外授权的步骤**：Apple 链接器默认为 arm64 输出添加 ad-hoc 签名，`codesign -dv --verbose=4` 通常显示 `Signature=adhoc` 与 `flags=0x20002(adhoc,linker-signed)`；这种产物已有签名，不能称为完全未签名。`CODE_SIGNING_ALLOWED=NO` 只关闭 Xcode CodeSign 步骤。本预览脚本还以 `-Wl,-no_adhoc_codesign` 关闭链接器自动签名，并逐个检查 Mach-O 的 `LC_CODE_SIGNATURE`。因此默认 arm64 包没有 linker-signed 签名，实际打开前需要另行授权至少 ad-hoc 签名。当前可选步骤使用 Developer ID 与原有沙盒 entitlements，不接受 ad-hoc 身份，默认仍跳过。获准后运行：

```sh
./Scripts/build-preview-app.sh --arch arm64 \
  --sign 'Developer ID Application: Example Name (TEAMID)' \
  --certificate /absolute/path/to/developer-id.cer \
  --keychain /absolute/path/to/login.keychain-db
```

脚本核对证书有效期及匹配的私钥身份，离线签名，不公证、不发布、不导入或解锁钥匙串。签名后的实际启动、容器与权限仍需用户真机复核。

完整回归使用本页开头的标准 `xcodebuild test`：`-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`，DerivedData 和日志放入专属输出根目录，不额外强制 Intel 架构、不关闭链接器自动签名、不启用预览编译条件，也不以直接调用 `xctest` 代替。标准 arm64 测试产物可能带有链接器自动生成的 ad-hoc 签名，须与严格未签名的预览包分开记录；不额外执行签名命令。Xcode 会自动启动 App 测试宿主；scheme 设置 `LIVELINGO_UNIT_TESTING=1`，不创建正式 AppModel、不预热模型，这不等于用户打开 App 的界面验收。对实际完整测试日志执行 `check_build_warnings.py` 和 `check_test_preferences.py`，如实记录失败与未满足项。若回归失败，用相同标准命令在未修改的基线代码上复跑，不能仅凭一次失败断言是环境问题。

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

签名材料和公证凭据不存入仓库。发布者须提供有效的 Developer ID Application 身份、匹配证书和含私钥的签名钥匙串。公证只使用本机已有的 `notarytool` keychain profile；脚本不创建、导入或解锁钥匙串，不接受仓库内的密码、API key 或凭据文件。

`--keychain` 只指定 **DMG 签名**的钥匙串。独立的 `--notary-keychain`（或 `LIVELINGO_NOTARY_KEYCHAIN`）指定公证 profile 所在钥匙串，默认省略，让 notarytool 使用正常搜索范围；用 `--sync` 保存的 profile 不应被强制限定到签名钥匙串。源码未记录发布者的 profile 名，不能猜测；下面先用 `read` 输入已有的真实名称，空值和旧文档占位符 `<你的 profile>` 都会被拒绝。

```sh
read -r LIVELINGO_NOTARY_PROFILE
export LIVELINGO_NOTARY_PROFILE

./Scripts/sign-offline-app.py --app work/OfflineCandidate/LiveLingo.app \
  --identity 'Developer ID Application: Example Name (TEAMID)' \
  --certificate /absolute/path/to/developer-id.cer \
  --keychain /absolute/path/to/login.keychain-db

./Scripts/build-offline-dmg.sh --app work/OfflineCandidate/LiveLingo.app \
  --identity 'Developer ID Application: Example Name (TEAMID)' \
  --keychain /absolute/path/to/login.keychain-db \
  --notary-profile "$LIVELINGO_NOTARY_PROFILE" \
  --output work/OfflineDMG/LiveLingo-next-macOS14+-arm64.dmg
```

身份、证书和路径也要换成发布者的实际配置。正常打包会签名 DMG，向苹果上传 App 公证容器及最终 DMG，必须已获真实发布授权后才运行。完整顺序是：

1. 校验已完整签名 App 的 entitlements、自包含依赖、签名身份和 macOS 14 最低版本。
2. 复制到私有暂存目录，再做结构检查和 `codesign --verify --deep --strict`。只含 `LiveLingo.app` 的目录生成 App 公证临时 DMG（UDZO）；不再用 `ditto -c -k` ZIP，helper 也直接拒绝 ZIP 新上传，避免超过 4 GiB 文件的 ZIP64 风险。复制仍保留资源和扩展属性。
3. 打印容器的实际字节数，提交一次，逐行保存输出；收到 `id:` 立即原子写入回执。只有上传正常退出且出现完成标志，才开始按 ID 查询及计处理时限。
4. `Accepted` 后对原暂存 App 装订、验证票据，再严格校验签名。装订最多尝试 4 次，默认等待 5、10、20 秒；可用 `--staple-max-attempts`、`--staple-retry-delay` 调整。失败保留暂存供续跑。
5. 将“应用程序”快捷方式和使用说明加入同一暂存目录，用已装订 App 创建正式发布镜像，**先放在暂存中**，签名时使用 `--timestamp`，校验签名身份和镜像完整性。
6. 公证签名后的发布 DMG，按 ID 查询到 `Accepted`。保留该已上传镜像不变，在同卷工作副本上以同样重试规则装订；副本装订/严格校验及哈希保存后才记录完成。装订后中断也能从未改变的已上传镜像恢复。
7. 检查 DMG 与内置 App 的票据、严格签名及预期 Authority；对 DMG 执行 `spctl --assess --type open --context context:primary-signature`，要求返回 `Notarized Developer ID`。只读挂载后检查真实内置 App 的票据、严格签名和执行评估。按 `attach -plist` 返回的镜像设备号卸载，最多尝试 3 次；成功后清理空挂载目录。
8. 全部自检通过且卸载成功后，才移动到正式 `--output` 文件名；已有文件或悬空链接均拒绝覆盖。半成品留在暂存，不占正式文件名。

正式 DMG 顶层只有 App、“应用程序”快捷方式和使用说明；公证临时 DMG、回执、日志、状态及工具路径记录均在 payload 外。输出、暂存和挂载点拒绝使用 `/Applications`、系统目录、主目录根或卷根，也会解析目录链接后检查。暂存与输出不能放进原输入 App，须位于同卷以保证最终移动原子完成。生产工具使用绝对路径，stapler/notarytool 经系统 xcrun 解析并记录实际路径；不从普通 PATH 获取发布工具。`LIVELINGO_TEST_TOOL_DIR` 是明确的离线测试替身入口，真实发布须取消它和测试用 `LIVELINGO_PYTHON`。

APFS 同卷暂存和 DMG 装订工作副本可共享文件块，但 App 公证镜像与发布镜像各自占用空间；不支持克隆的卷还需为工作副本预留额外空间。镜像容量按文件的逻辑长度、每个目录项的 8 KiB 元数据余量，再加 20% 和 256 MiB 估算，避免稀疏文件让自动容量估算偏小；这不是实际占用保证。暂存 App 是唯一 App 装订副本，App 临时 DMG 对应第一次提交，未改变的已上传发布 DMG 用于中断恢复，装订工作副本及日志用于自检/复核；完成真实验收且不再需要恢复后，按授权清理这些中间件。脚本不会自动删除它们。

### 上传和处理分别计时，不使用 `--wait`

0.2.0 发布记录中，`notarytool --wait` 曾以退出码 138 崩溃，还有提交处理约 9 小时的情况；这些历史现象不证明同一原因或已被拒绝。新 helper 使用普通文本 `submit --no-progress`，`info --output-format json`，不使用 `--wait`，不自动重传。

| 参数 | 默认值 | 范围 |
| --- | --- | --- |
| `--notary-submit-timeout` | 0（不限） | 只限制上传；正数为上传秒数上限 |
| `--notary-timeout` | 3600 秒 | 每件产物**上传完成后**的处理总时限；续查时重新计处理时限 |
| `--notary-command-timeout` | 60 秒 | 仅 info/log，最多使用处理时限的剩余时间 |
| `--notary-poll-interval` | 30 秒 | 相邻查询间隔 |
| `--notary-max-polls` | 120 次 | 查询总次数，失败查询也计数 |
| `--notary-max-retries` | 3 次 | 连续 info 失败、log 获取失败的额外重试次数；submit 不重试 |

默认上传不限时，不再受原来的 600 秒/3600 秒限制。若要显式限定上传，以 **14.3 GB = 14,300,000,000 字节**、假设持续上行 **2 Mbit/s** 计算：`14,300,000,000 × 8 ÷ 2,000,000 = 57,200 秒`，即 **15 小时 53 分 20 秒**，尚未计协议开销、停顿和重试。这是带宽假设下的估算，不保证实际速度。可以给每件上传 20 小时、处理 1 小时，并保持查询短超时：

```sh
./Scripts/build-offline-dmg.sh --app work/OfflineCandidate/LiveLingo.app \
  --identity 'Developer ID Application: Example Name (TEAMID)' \
  --keychain /absolute/path/to/login.keychain-db \
  --notary-profile "$LIVELINGO_NOTARY_PROFILE" \
  --notary-submit-timeout 72000 --notary-timeout 3600 \
  --notary-command-timeout 60 \
  --output work/OfflineDMG/LiveLingo-next-macOS14+-arm64.dmg
```

两件容器分别上传。实际更慢时提高上传上限或用默认 0；参数是停止条件，不是公证完成时间预测。认证失败/找不到 profile 会单独报告，并打印 stderr 摘要；其他上传失败归为结果不明。`Invalid`/`Rejected` 会尝试获取日志，获取失败也明确报告。查询次数、重试次数或处理时限耗尽都不会放行产物。

### 从暂存或已知提交编号续跑

每次运行保存新回执目录，状态文件与产物 SHA-256 用于检查复用的容器没有改变；不要手工改暂存 App、镜像或状态。切换续查回执时原子保留已确认的查询编号和旧回执引用，即使新回执尚未生成就中断，也只继续查询，不重传。下例的目录和编号必须替换为本次发布实际值。续跑会复查 App，复用 Accepted 的回执，或只查询已完成上传的编号，再自动执行剩余装订、打包及自检步骤：

```sh
./Scripts/build-offline-dmg.sh --resume-stage work/OfflineDMG/stage-ACTUAL-RUN \
  --notary-profile "$LIVELINGO_NOTARY_PROFILE"

# 仅在已确认上传完成、但需要补入编号时指定；两个选项可分别使用。
./Scripts/build-offline-dmg.sh --resume-stage work/OfflineDMG/stage-ACTUAL-RUN \
  --notary-profile "$LIVELINGO_NOTARY_PROFILE" \
  --app-submission-id ACTUAL-COMPLETED-APP-UUID \
  --dmg-submission-id ACTUAL-COMPLETED-DMG-UUID
```

**上传被中断的编号不能续查，必须重新提交。** 收到 ID 只说明苹果分配了编号，不证明上传完成；不能从 history 找到 ID 就轮询。`receipt.json` 中 `uploadComplete: false` 的上传回执，脚本拒绝续用编号，且不会自动重传。检查原 stdout/stderr，确认需要重新上传后，用 `--resume-stage ... --resubmit-incomplete` 明确发起新提交；它保留旧回执，不复用未完成的编号。仅认证/profile 配置失败也可修正配置后按此方式重试；认证失败不等于已经发生上传。

`--app-submission-id` / `--dmg-submission-id` 是调用者声明**已知完成上传**的入口，必须属于对应的同一产物，不能拿未完成的 ID 绕过回执检查。单独 helper 的 `--submission-id` 也有同一前提；query-only 回执保留 `submissionMode: explicit-resume`，不谎称本次 helper 亲自完成上传。Accepted 查询结果可用于继续装订。

```sh
./Scripts/notarize-artifact.py --submission-id ACTUAL-COMPLETED-UUID \
  --profile "$LIVELINGO_NOTARY_PROFILE" \
  --receipt-dir work/notary-resume-NEW-RUN
```

helper 本身只查询；要完成剩余发布步骤优先使用打包脚本的 `--resume-stage`。该入口支持本版生成的 `release-state.json`，旧版无状态的暂存不能直接套用。SIGHUP/SIGINT/SIGTERM 会停止本次 notarytool 进程组并记录中断及已收到编号；SIGKILL/掉电无法保证最后状态已写入。暂存锁防止同目录并发执行；如有遗留 `.release-lock`，先核实没有本次执行者，再处理锁，不能盲删锁或重复提交。

### 发布前自检与无凭据自测

```sh
./Scripts/verify-release-dmg.sh --dmg work/OfflineDMG/LiveLingo-next-macOS14+-arm64.dmg \
  --identity 'Developer ID Application: Example Name (TEAMID)'

./Scripts/build-offline-dmg.sh --dry-run
/bin/zsh -n Scripts/build-offline-dmg.sh
/bin/zsh -n Scripts/verify-release-dmg.sh
/bin/bash -n Scripts/build-offline-dmg.sh
/bin/bash -n Scripts/verify-release-dmg.sh
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3.13 Scripts/test-release-flow.py
```

独立自检的 `--identity` 可选，提供时逐行精确匹配 DMG 与挂载 App 的 Authority；打包流程总是传入预期身份。卸载资源忙时有限重试，不自动强制卸载；耗尽时保留设备号和挂载点供处理，返回失败。attach 尚未返回就中断时，使用 `hdiutil info -plist` 查回**同时匹配本次镜像与新挂载点**的设备，再有限重试卸载；没有找到设备时不对普通目录执行 detach，查询失败会明确报告。没有 `--dmg` 或 `--dry-run` 会明确跳过，不能当真实验收。

打桩自测使用 `/private/tmp` 中的最小 App 和非钥匙串文本夹具，显式提供绝对路径的假 notarytool、stapler、codesign、hdiutil、spctl、ditto，以及结构校验替身。假镜像保存**创建当时的内容快照**，挂载检查不会偷读后来改变的暂存 App。测试核对 timestamp、签名身份/钥匙串、profile、严格签名、镜像验证、装订目标和步骤顺序；覆盖两阶段查询失败/拒绝、装订退避、续跑、未知上传、信号中断、部分 attach、忙碌 detach 及正式输出保护。关键参数删除和顺序破坏另有变异测试。超时使用可控逻辑时钟、模拟进程/管道，不依赖 Python 启动必须赶在 0.2 秒内；信号测试等到回执/挂载事件后才发信号。真实 App 签名命令构造通过工具调用拦截检查 hardened runtime 和 timestamp，绝不真实签名。测试结束删除本次临时夹具，不访问真实发布产物或凭据。

本地大文件镜像实验可单独运行：

```sh
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3.13 Scripts/test-large-app-dmg.py
```

2026-10-07 本机实测：稀疏文件逻辑大小 **5,136,696,107 字节**，源与 ditto 副本各实际分配 **53,248 字节**；显式镜像容量 **6,432,549,428 字节**。只含 App 的 UDZO 为 **406,172 字节**（零数据易压缩，不代表真实权重包大小）；镜像校验、只读挂载后读回大小及整文件 SHA-256 均通过，SHA-256 为 `6cdad844203ac789e7762c1354bc6b0bbff0169021eb731ec2f62bd953901707`。按设备号卸载后临时目录已删除。自动容量版本曾返回“设备上无剩余空间”，显式容量版本通过；实验没有签名或连接苹果服务。

### 首次真实发布检查清单

以下事项无法靠打桩或稀疏文件实验代替，首次真实发布仍须逐项实测：

- 用户确认本次签名、公证上传和最终对外发布的具体产物/范围；准备可用私钥与已有 profile，确认 profile 的实际搜索范围及钥匙串锁定状态。脚本不会自行解锁或创建凭据。
- 选择已安装且稳定的 Xcode/CLT，必要时显式设置 `DEVELOPER_DIR`；检查记录的 notarytool/stapler 真实路径和版本。历史 beta 工具与退出码 138 不能证明当前工具有同一故障。
- 对含真实大权重的 App-only DMG 做第一次真实公证，确认提交文本的 ID/上传完成标志能被本版解析，以及服务为内置 App 生成可用票据；实测 App 装订和有限退避。稀疏大文件实验只证明本地容器大小和读回正确。
- 对最终 DMG 装订并只读挂载，确认实际 stapler 版本能在只读卷上 validate；实测镜像与 App 的 Authority、严格签名、Gatekeeper，以及忙碌卷卸载。线上 validate/spctl 通过不等于离线票据证明。
- 在干净 macOS 14 测试环境，对带下载隔离属性的最终文件做离线 Gatekeeper、安装、启动和模型功能验收；验证无需联网查询票据。记录测试对象的版本与校验和。
- 对最终对外文件检查隐私元数据、嵌入内容及随包文件，排除钥匙串/回执/日志/本机路径；保留必要许可证。实际上传或发布前再次核对这就是已自检的最终版本。

`Scripts/run-qwen-service.sh`、`Scripts/install-qwen-service.sh` 和 `Packaging/*.command` 是历史服务与旧安装布局的辅助脚本，不属于当前安装步骤。

## 验证记录

旧发布记录中的 97 项 Swift 测试、6 项 Python 测试和旧 macOS 14 虚拟机结果仅作为历史证据。本轮固定候选 6 在主机上重新完成了 394 项通过、1 项跳过、0 项失败的 Xcode 测试，并完成 CLI 生命周期、真实子进程与 ASR Python 定向检查。

2026-09-23 又对最终候选 6 完成了真实 GUI 文件导入：40.89 秒 WAV 经界面选择后生成 4 段英文转写、中文译文、双语字幕、学习摘要、录音和会话持久化文件，最终 journal 状态为 `completed`，无待处理字幕或笔记批次。此前文件面板里“导入”灰掉的现象已复现为自动化未真正选中文件；真实选中文件后按钮会正常启用。

2026-09-23 已在 Apple Silicon 的 macOS 14.6.1（23G93）Parallels VM 上完成最终候选实测。重新挂载正式 `LiveLingo-0.1.0-20260922-macOS14+-arm64.dmg` 时，镜像 CRC 校验通过；DMG 内 App 读回为 `0.1.0 / 20260922.2`，主程序 SHA-256 与最终候选一致，严格代码签名验证通过，Gatekeeper 返回 `accepted / Notarized Developer ID`。同一验收轮保存的 GUI 截图确认最终 DMG App 能在 macOS 14 启动；40.89 秒 WAV 的完整本机模型流程生成 4 段转写、4 段翻译、整课摘要与复查结果，并导出 Markdown、纯文本、Word 和 PDF。最终记录为 `processing_finished`、`run_verified`，转写待处理数为 0，退出后 `asrRunning=false`、`remainingMLX=0`。当前面向 Apple 芯片；Intel 与 Universal 构建未验证。

便携运行库还不能从本仓库一条命令重建。依赖版本与许可清单已保留，但仍需开发者准备匹配的环境及兼容 macOS 14 的原生依赖。
