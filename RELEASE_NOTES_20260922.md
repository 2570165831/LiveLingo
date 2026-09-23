# LiveLingo 0.1.0 / 20260922.2 发布说明

这份说明对应整改后的固定候选 6 和 `LiveLingo-0.1.0-20260922-macOS14+-arm64.dmg`。版本号仍为 `0.1.0`，内部构建号为 `20260922.2`。

## 主要变化

- 增加课程会话持久化、异常退出后的转写队列恢复与录音边界保护。
- 导入本地音视频时与实时课堂共用转写、翻译、学习笔记和保存流程，停止或失败时保留已经完成的结果。
- 翻译重试与字幕身份绑定，旧请求不能写回新会话；正式字幕在完整校验后入库。
- 学习笔记补充来源绑定、后文补充/冲突跟进与数值来源检查，减少编号、单位和跨句条件造成的误报。
- 复查队列保留原输入、批次与进度，支持暂停、继续和显式启动；停止录音本身不会自动触发复查。
- 资源调度明确 ASR、4B、9B 与摘要/翻译之间的所有权和并发边界，退出时继续核对自有子进程清理。

## 已验证

- 主机 macOS 27.2：Xcode `394 passed / 1 skipped / 0 failed`。
- 最终候选主程序 SHA-256：`ee27400d7f7bd2fdaeaae5c802a55eafd99c455ca39e3eb02fa50fb0ea4fb06b`。
- 冻结候选时，正式源码对清单 2233 个文件重新计算 SHA-256，`2233/2233` 一致；最终收尾后，清单内只有 `README.md` 的验收说明和工程文件中的单个行尾空格清理与冻结字节不同，应用行为源码、测试源码与打包逻辑仍与固定候选一致。
- 最终候选 6 已完成真实 GUI WAV 导入：4 段转写与中文译文、双语 SRT/JSONL、学习摘要、录音和会话快照均成功落盘；持久化状态最终为 `completed`。
- 离线 DMG 已完成 Developer ID 签名、公证、`stapler` 校验、Gatekeeper/镜像完整性检查，并确认 iCloud 上传完成。
- Apple Silicon macOS 14.6.1（23G93）VM 已对同一最终 DMG 完成实测：镜像 CRC 校验通过，App 版本为 `0.1.0 / 20260922.2`，主程序 SHA-256 与最终候选一致，严格签名验证通过，Gatekeeper 返回 `accepted / Notarized Developer ID`。
- macOS 14 完整模型流程处理 40.89 秒 WAV 后得到 4 段转写、4 段翻译、摘要、复查结果及 Markdown/TXT/DOCX/PDF 导出；最终为 `processing_finished`、`run_verified`，待处理转写为 0，ASR 与 MLX 子进程均确认清理完成。该验收轮同时保留了最终 DMG App 在 macOS 14 上启动的 GUI 截图。

## 当前发布边界

- 本轮定义的主机 GUI 与 Apple Silicon macOS 14 最终候选验收门槛均已完成。
- 新版源码和可还原为最终 DMG 的 8 个分卷经 [GitHub 最新发布页](https://github.com/2570165831/LiveLingo/releases/latest)公开，发布附件包含合并说明和校验清单。[新版完整 DMG](https://drive.google.com/file/d/1UxYwkBybdcMJq9FuNws55ZTxROEzedHL/view?usp=drivesdk)也已在 Google Drive 开放只读下载。旧版 `v0.1.0` 与旧版 Google Drive 完整包保留。
