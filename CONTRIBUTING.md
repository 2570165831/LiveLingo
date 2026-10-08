# 参与 LiveLingo 开发

本文件只说明最短路径；功能说明见 [README.md](README.md)，构建细节与验收边界见 [docs/BUILDING.md](docs/BUILDING.md)。

## 许可证与提交约定

- 自有代码采用 GPL-3.0-only，见 [LICENSE](LICENSE)。提交贡献即表示同意以同一许可证提供（inbound = outbound）。
- 不要删除、改写或重新授权第三方许可证原文、模型卡与对应源码；它们继续适用各自许可证。
- 不要提交签名证书、私钥、钥匙串导出物、公证凭据、`.env`、录音、转写或笔记内容。提交前自行检查待提交文件，不能只依赖 `.gitignore`。
- 隔离测试和独立分发请使用自己的 bundle ID；保留依法需要的版权与许可声明。

## 开发环境

- macOS 14 或更高版本，Apple 芯片；Xcode 27.0 或更高版本（当前使用 Xcode 27.0 Beta 4 验证）。
- 不需要 LM Studio。语言运行库是应用自有的 MLX / MLX-LM 进程；转写由应用内置的 `ASRRuntime` 在本机启动。
- 只跑 Xcode 构建不会包含运行库与模型；ASR 只从 App 包内的 `Contents/Resources/ASRRuntime` 与 `Models` 加载。需要完整功能时按 [docs/BUILDING.md](docs/BUILDING.md) 组装离线候选。
- 便携运行库目前**不能**一条命令重现，详见 [docs/BUILDING.md](docs/BUILDING.md) 的“验证记录”。不要声称已复现。

## 构建与测试

```sh
xcodebuild -project LiveLingo.xcodeproj -scheme LiveLingo -configuration Debug \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO build

xcodebuild -project LiveLingo.xcodeproj -scheme LiveLingo -configuration Debug \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO test
```

- 测试位于 `LiveLingoTests/`，属于发布内容，请不要删除或跳过。
- 全量编译和测试应使用全新的 DerivedData 目录，并将标准输出和错误输出一起保存为日志；结束后运行 `python3 Scripts/check_build_warnings.py "$TMPDIR/xcodebuild-test.log"`。脚本列出编译器警告，有警告时非零退出；仅排除 `appintentsmetadataprocessor` 的工具提示，不替代构建与测试成功检查。
- 完整测试请将标准输出和错误输出一起保存为日志（例如在上述 `test` 命令末尾加 `> "$TMPDIR/xcodebuild-test.log" 2>&1`），结束后运行 `python3 Scripts/check_test_preferences.py "$TMPDIR/xcodebuild-test.log"`。守护会逐个核对 `TEST_PREFERENCE_CREATED` / `TEST_PREFERENCE_CLEANED` 的 UUID 套件名，并只读确认真实用户的偏好目录中对应文件不存在；缺少成功结束标记、缺失或重复事件、文件残留都会报错。新建偏好套件必须先注册 `TestPreferenceCleanup`，在本测试的任务停止后调用它清理；辅助只接受列明前缀、事先不存在的 UUID 套件和普通文件，不处理历史文件。`TMPDIR` 应指向本次获准的临时目录。
- 未签名 Release 构建：`./Scripts/build-release.sh`。
- 签名、DMG 与离线候选组装都需要显式传入路径和签名身份。身份缺失时脚本必须报错；不要添加自动挑选本机身份或降级为 ad-hoc 签名的回退逻辑。
- 新增或修改脚本请先做语法检查（`zsh -n`、`bash -n`、`python3 -m py_compile`），并在本地实际跑一遍对应流程。

## 代码与文档约定

- Swift 代码保持现有 App Sandbox 边界：不引入云端 API、遥测或上传录音/转写的逻辑。
- 不硬编码个人主目录、机器名、账号、Team ID 或签名身份。新增配置请用显式参数或环境变量，并让缺失值直接失败。
- 影响行为、依赖或验收范围的改动，请同步更新 README 或对应说明；不要夸大验证结论，未实测的内容请标注为未实测。
- 历史脚本（`Scripts/run-qwen-service.sh`、`Scripts/install-qwen-service.sh`、`Packaging/install.command`、`Packaging/verify.command`）只用于旧布局与回滚，请保持其 legacy 定位。

## 反馈问题

请通过仓库托管平台已启用的 Issues 入口提交，并尽量附上：

- 复现步骤、期望结果与实际结果。
- macOS 版本、芯片型号、Xcode 版本。
- 使用的构建命令与完整报错文本（去掉个人信息）。
- 涉及字幕或翻译时：质量模式（省电/高质量）、音频来源（麦克风/内录）、是否使用离线发行件，以及相关日志片段。

请不要附上：签名证书、私钥、钥匙串导出、公证凭据、`.env`、完整录音、完整转写或含个人信息的会议内容。需要样例时请提供最小化的合成片段。

安全或敏感问题请先私下联系维护者，不要直接公开细节。

## 中文用语与命名

语言名称写法是项目命名规范，以 OutputLanguage 中的原名为准。用语经大模型审阅，非母语者人工审校；不得把 LLM 期望列标成母语者人工金样。四份 ZhVariants 项目表的每条映射必须注明学科、审阅者、官方公开出处及具体词目或章节，不确定的条目不收。通用词表与学科覆盖分开，覆盖表先匹配，替换结果不递归转换。

新增条目同时加入 terms.tsv 的正例与反例，特别检查数学函数、研究对象、实验程序、测量数据、长词、代码、公式、JSON 键。更新 SOURCE.json 的项目表计数、哈希和 converterVersion；保留上游字典与原始 OpenCC 用例。审阅样本、过程脚本与报告放在任务工作目录，不进入仓库。参见 [中文用语说明](docs/CHINESE_TERMINOLOGY.md)。
