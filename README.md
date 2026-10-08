# LiveLingo

英语课堂的本机字幕与笔记工具：边听课边看英文转写和中文翻译，同时整理出学习笔记。全部在你的 Mac 上运行，不联网、不上传录音。

适用于 Apple 芯片 Mac，macOS 14 及以上。开源，GPL-3.0。

<!-- TODO: 在这里放一张课堂界面截图（双语字幕 + 笔记），例如 docs/images/classroom.png -->

[English summary](#english)

## 能做什么

- **实时双语字幕**：从麦克风或系统音频（内录，适合网课和视频）接收英语，显示英文转写和中文翻译；可以开悬浮字幕，随时暂停、继续。
- **可选全屏网课模式**：仅此实验分支提供，当前下载版（0.2.0）不含。尝试在其他 App 的原生全屏中显示字幕；开启后 Dock 图标消失，用顶部菜单栏图标操作。默认关闭，真机效果需实际确认，详见[使用与检查清单](docs/FULLSCREEN_CLASS_MODE.md)。
- **边听边记笔记**：一边上课一边生成学习笔记，分开显示最近更新和整节课的内容。
- **课后复查**：录音结束后，可以手动让更大的 9B 模型复查笔记，意见单独列出，不改动原文。
- **保存与导出**：保存录音、双语字幕和笔记，可以导出 Markdown、纯文本、Word 和 PDF；以后打开旧课程能接着看、接着处理。
- **公式和名称保护**：化学式、明确要求原样保留的名称会尽量原样保留，计算可以用工具辅助核对。
- **完全离线**：转写和翻译模型都装在 App 里，不需要 Python、LM Studio，也不需要再下载模型。

## 下载

**[下载完整安装包（Google Drive，约 14.3 GB）](https://drive.google.com/file/d/11nM4jOR_lnf0seLDZg4L9Smt_sLtuO2Z/view?usp=sharing)**

Google Drive 下载不了时，可以从 [GitHub 发布页](https://github.com/2570165831/LiveLingo/releases/tag/v0.1.0%2B20260924.0014) 下载同一个安装包的分卷，按页面上的说明合并。发布页下方的 `Source code` 是源码，不是安装包。

| 要求 | |
| --- | --- |
| 电脑 | Apple 芯片 Mac（M 系列）。Intel 机型不支持 |
| 系统 | macOS 14 或更新 |
| 硬盘 | 安装包约 14.3 GB，装好后的 App 约 16 GB；安装时两者同时在硬盘上，需要约 30 GB 可用空间，装完可以删掉安装包 |
<!-- TODO: 补一行“内存”，等实测出 4B / 9B 模型运行时需要的内存后再写 -->

## 三步上手

1. 打开下载的 `.dmg`，把 **LiveLingo** 拖进“应用程序”。
2. 从“应用程序”打开 LiveLingo，按系统提示允许麦克风、语音识别和系统音频录制。
3. 选择声音来源（麦克风或系统音频），点“开始记录”，字幕和笔记就会出现。

详细操作见 [0.3.0 中文使用说明](docs/GUIDE.zh.md)，包括保存位置、声音权限、悬浮字幕、全屏网课模式、笔记复查、导出和常见问题。

## 已知限制

- **翻译和笔记可能出错**：模型会漏译、误译或写错知识点。重要内容请对照英文原文。
- **macOS 14 上没有“同步初译”**：这个功能用苹果的翻译接口，需要 macOS 15 及以上。macOS 14 上中文要等正式翻译完成后才出现，不影响翻译本身。
- **英文逐词预览需要系统资源**：它用的是 macOS 自带的英语识别。预览不出来时，打开“系统设置 → 键盘 → 听写”，开启听写并添加“英语（美国）”，联网等系统准备好资源。正式转写不受影响。详见[苹果的听写说明](https://support.apple.com/en-euro/guide/mac-help/mh40584/mac)。
- **只支持 Apple 芯片**：Intel 和通用版本没有构建，也没有验证过。
- **安装包很大**：转写和翻译模型都在包里，换来的是装好就能离线用。

## 用到的模型

| 用途 | 模型 |
| --- | --- |
| 英文转写 | Parakeet TDT 0.6B v2；结果异常时改用 Qwen3-ASR 1.7B |
| 翻译与笔记 | Qwen3.5 4B（“省电”）或 Qwen3.5 9B（“高质量”）；课后复查用 9B |

默认是“自动”：用电池，或者内存 16 GB 及以下时用 4B；插着电且内存大于 16 GB 时用 9B。也可以在设置里手动选。

模型通过 MLX 在本机运行。输出格式用 Outlines 约束，明确的计算由 Pint、SymPy 和 ChemPy 辅助检查；这些手段能减少格式错误，不能保证内容正确。模型的来源和许可见[第三方声明](Packaging/THIRD_PARTY_NOTICES.md)。

## 数据与隐私

音频、转写、翻译和笔记都在本机处理。录音模式把录音、双语文本、字幕和笔记保存在你选的位置；实时模式使用临时录音，也可以转存。代码里没有云端推理或上传录音的功能。

提 Issue 或 Pull Request 时，请不要附上私人录音、完整课堂转写、笔记或任何凭据。

## 更新记录与开发

- 每个版本改了什么：[更新记录](CHANGELOG.md)，以及各版本的发布说明（[20260924](RELEASE_NOTES_20260924.md)、[20260922](RELEASE_NOTES_20260922.md)）。
- 从源码构建、组装模型、签名和打包：[docs/BUILDING.md](docs/BUILDING.md)。只编译 Swift 源码得到的 App 不带模型，不能离线使用。
- 参与贡献：[CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

自有代码采用 **GPL-3.0-only**（见 [LICENSE](LICENSE)），允许商业使用和收费；分发程序或修改版时须按许可证提供源码。软件按现状提供，不提供担保。第三方依赖和模型继续适用各自的许可证，离线许可文本和必要的对应源码保留在 [Packaging/MLXLicenses](Packaging/MLXLicenses/)。

官方版本计划免费提供。这是项目自己的发行安排，不是对其他分发者附加的收费限制。

## English

LiveLingo is a macOS app for English-language classes. It transcribes English from the microphone or system audio, translates it into Chinese in real time, and builds study notes as the class goes on. Everything runs on your Mac: the speech and language models are bundled, nothing is uploaded, and no Python or model download is needed.

- Requires an Apple silicon Mac with macOS 14 or later, and about 30 GB of free disk space to install (14.3 GB download, 16 GB installed).
- Download: [full DMG on Google Drive](https://drive.google.com/file/d/11nM4jOR_lnf0seLDZg4L9Smt_sLtuO2Z/view?usp=sharing), or the split files on the [release page](https://github.com/2570165831/LiveLingo/releases/tag/v0.1.0%2B20260924.0014).
- The interface is in Chinese. Translations and notes can be wrong; check important points against the English transcript.
- License: GPL-3.0-only. Building from source: [docs/BUILDING.md](docs/BUILDING.md) (in Chinese).
