# 数据安全修复回执

起点 `e6f8e0b`，分支 `claude/data-safety`。仅本 worktree 的源码、合成测试及本地验收产物；未联网、未读取真实课堂、未加载推理模型、未运行 GPU 推理，未推送。

优先修复会丢失音频、覆盖正文或生成进度的高项，再修恢复、退出确认及取消归属的中项。下列测试原断言保持；旧身份夹具重新封装有效 checksum；Python 两条恢复故障注入改到发布后的目录同步点，原断言不变。英文旧课程、导出清单、导出正文及默认语言测试文件保持基线原样。

最终 `xcodebuild test` 退出 0：XCTest 1232 条、原有跳过 1 条、零失败；Swift Testing 180 条/9 suites、零失败。`check_build_warnings.py` 为 0 条，结果包也记录 warningCount=0、编译错误与测试失败均为 0；`check_test_preferences.py` PASS，359 创建/359 清理，对应 plist 全部不存在。源码/配置/测试的 32 个 hash 与最终运行前一致。

定向 XCTest 121 条、Swift Testing 14 条零失败，偏好清理 PASS（62 创建/62 清理）；目录权限修复后另跑 XCTest 47 条、Swift Testing 23 条零失败，偏好清理 PASS（16 创建/16 清理），并证实 Scheme 独立提供指定临时目录。按指定 Python 环境重建 CLI 后，全套 687 条零失败、跳过 6 条，未触发 ProbePrecision 偶发；合成质量门 10 个夹具、44 个断言通过，未调用真实模型。CLI 的多余 `try?` 移除后，CLI 编译警告门也为 0。

安全约束要求不加载模型，因此完整 Xcode 范围排除 `RealtimePolicyTests.testSystemSpeechClassifierProducesStreamingObservations`：此测试会启动系统 SoundAnalysis 模型。此项与原有运行时跳过分别计数，不能把本轮称为完全相同范围的基线验收。

测试文件简称：`Audio` = `DataSafetyAudioTests.swift`，`Runtime` = `DataSafetyRuntimeTests.swift`，`Storage` = `DataSafetyStorageTests.swift`，`App` = `DataSafetyAppTests.swift`，`Review` = `DataSafetyReviewTests.swift`，`Python` = `Scripts/test_data_safety.py`。

| 审计编号 | 修复与回归测试 |
|---|---|
| A1 | 轮转建立下一段失败即封住入口，写入器失效时不消费尾帧；Audio `testRotationOpenFailureAccountsForPersistentAndLiveOnlyTail`。 |
| A2 | 日志短写/同步失败后禁止追加，重开保留残缺尾部并恢复完整前缀；Audio `testShortJournalAppendCannotBeExtendedByFinalizer`。 |
| A3 | 停止和重开按整数帧补登记主 WAV 中已落盘的完整尾部；Audio `testMainRecordingTailRecoversAfterSecondWriterFailure`。 |
| A4 | 保留坏音频和标记，登记缺口并继续恢复健康录音；Audio `testShortCaptureDoesNotBlockHealthyCaptureRecovery`。 |
| A5 | 校验长度/格式/PCM，退役片段从主录音重建，空 WAV 不算静音；Audio `testRetiredShortChunkIsRebuiltBeforeTranscription`、`testRetiredEmptyChunkIsNotAcceptedAsSilence`、`testRetiredSameLengthDifferentPCMIsRebuilt`。 |
| A6 | 坏缓存快照从完整、身份一致的日志恢复，错误会话仍拒绝；Audio `testCorruptSnapshotFallsBackToCompleteJournal`、`testWrongSessionSnapshotIsStillRejected`（对照）。 |
| A7 | 锁内复核目录/日志身份、长度和修改时间，拒绝旧路径分叉与外部替换；Audio `testMovedJournalDirectoryCannotForkAtRecreatedPath`、`testReplacedJournalLogIsNotExtended`。 |
| A8 | 累加已拒收帧与写盘失败尾帧并保留原因；Audio `testOverflowThenWriteFailureKeepsAllRejectedFramesAndReason`。 |
| A9 | 只在已观察子进程退出后读取真实退出状态；Runtime `testA9PreReadyExitDiagnosticReportsTheObservedExitStatus`。 |
| DU-01 | 含新增来源/输出语言字段的课程封套使用阅读版本 2，旧读者先拒绝；Storage `testDU01ModernLanguagesRejectLegacyReaderBeforeResave`。 |
| DU-02 | 含新增标记字段的快照/事件同样门控版本，避免旧版删字段后破坏重放；Storage `testDU02AnnotatedCourseRejectsLegacyWriterBeforeRevision`。 |
| DU-03 | 过期保存合并磁盘检查点，删除必须有显式退休事件；合并中的旧退休请求不能删恢复后的新进度；Storage `testDU03StaleWriterPreservesCheckpointWithoutJournal`、`testDU03StaleWriterPreservesJournalCheckpoint`、`testDU03DirectSaveCannotSilentlyDeleteCheckpoint`、`testDU03CoalescedRetirementCannotDeleteResumedProgress`。 |
| DU-04 | 空目录首次导出以完整同步的兄弟目录整体交换，保留冻结文件清单及原访问权限，只读目标抛错；已有课程更新写入不可变版本并校验，以一次原子指针切换发布；先检查全部目标；迁移只接受经过校验的内部链接；Storage `testDU04ExportFailureKeepsEntirePreviousVersion`、`testInitialExportKeepsPrivateDirectoryPermissions`、`testAtomicExportCourseCanBeMigratedWithOnlyManagedLinks`、`testAtomicExportCannotFollowAnExternalVersionsDirectory`，原 `ASRRecoveryTests.exportingIntoAReadOnlyDirectoryThrowsInsteadOfCrashing`、`MultilingualSessionExporterTests`、`TargetDefaultingTests`。 |
| APP-01 | 正常退出先停止/暂停自有工作并确认归档和队列保存，失败拒绝退出；App `testAPP01NormalQuitWaitsForArchiveAcknowledgement`；Review `applicationTerminationReportsQueuePersistenceFailure`、`applicationTerminationAllowsPersistedGenerationFailure`（对照）。 |
| APP-02 | 实时课程从稳定暂存目录开始，转换时确认首份存档并提交可恢复目录索引，迁移后先改索引再退休源；App `testAPP02ConvertedLiveCourseHasDurableRecoveryIndexBeforeStop`。 |
| APP-03 | 保存失败课程保留实际目录及重试入口，重试归档和导出后才转为已保存；App `testAPP03StoppedSaveFailureCanBeRetriedDirectly`。 |
| APP-04 | 状态文本展示当前课程实际位置，设置页单独标明下次录音位置；App `testAPP04CourseLocationLabelIgnoresNextRecordingPreference`（状态文本合成红绿测试，未声称真实课程 GUI 验收）。 |
| REV-01 | 拒绝未来队列版本并保留原字节；Review `futureJournalIsRejectedWithoutRewritingItsBytes`。 |
| REV-02 | 校验失败保留原暂停状态，禁止通过保存重试绕过校验；Review `restoreValidationCannotBeBypassedBySaving`（3 场景）。 |
| REV-03 | 非阻塞文件锁及写前原字节比较，过期写者拒绝覆盖新任务；Review `staleQueueWriterCannotDiscardAnotherWritersNewJob`。 |
| REV-04 | 缓存跳过保存也检查磁盘是否被替换；Review `unchangedSaveDetectsExternalReplacement`（2 场景）。 |
| REV-05 / F06 | 完成报告同时保存冻结正文/统计；最终队列写失败保留完成任务并显式报错，重启按报告恢复而不重新生成；Review `completedReportSurvivesFinalJournalFailureWithoutRegeneration`（2 场景）。 |
| REV-06 | v4 checksum 覆盖整个队列；同进度或更高进度不可改已完成批次正文，暂停/失败/统计头仍可更新；Review `journalChecksumRejectsChangedReportBody`、`sameCompletedProgressCannotReplaceSavedReportBody`。 |
| REV-07 | 流式检查点仅接受同一次尝试的 UTF-8 单调前缀扩展；Review `streamCheckpointOnlyAcceptsMonotonicExtension`（短/分叉场景）。 |
| F01 | 启动 owner/generation 在设备读取、tap 安装及 await 后复核，停止作废晚到启动；Audio `testStopDuringInitialFormatReadCannotReviveCapture`、`testStopDuringInitialTapInstallCannotReviveCapture`。 |
| F02 | 第二个重叠启动在更换会话/写入器之前被拒绝；Audio `testOverlappingInitialStartsCannotMixSessions`。 |
| F03 | 控制超时覆盖 send 前排队及堵塞写入，独立退休精确自有子进程；启动前设置自有写 fd 的 SIGPIPE 保护，失败明确抛原 POSIX 错误；Runtime `testF03CancellationDeadlineCoversBlockedWriteAndRetiresOnlyOwnedChild`、`testWorkerPipeSuppressesSIGPIPEBeforeFirstWrite`。 |
| F04 | delivery ACK 后释放 lease 并再次检查取消；Runtime `testF04CancellationDuringDeliveryACKReleasesLeaseAndThrowsCancellation`。 |
| F05 | saved drain 的最终笔记占用同一 summaryTask 标识，取消时联动并等待；App `testF05SavedFinalNoteOwnsSummarySlotAndBlocksManualAdmission`。 |
| F07 | 重试 timer 绑定队首 UUID/deadline/token，重排/移除后重绑；Review `retryTimerFollowsNewHeadAfterQueueEdit`（2 场景）。 |
| F08 | 保留校验的异步后台读取，worker 每次 await 后复核尝试；AppModel 展示、导出、打开课程及 CLI 调用异步入口；Review `asyncReportReadYieldsMainActorWhileAnotherStoreOwnsLock`。同步兼容管理 API 和部分写入仍同步。 |
| C01 | 崩溃清理/启动 await 后重走接纳检查，共用已接纳的新 service；Runtime `testC01CrashCleanupReentryReusesTheAdmittedReplacement`。 |
| C02 | 目录级锁内重新检查日志，过期写者不能写重复序号；Audio `testTwoJournalWritersCannotAppendDuplicateSequence`。 |
| C03 | 流式回调绑定 job/input/attempt，旧回调不能覆盖或取消新尝试；Review `lateCallbackCannotOverwriteOrCancelCurrentAttempt`。 |
| C04 | 退出轮询使用不受调用方取消影响的定时挂起，保留期限与精确进程身份；Runtime `testC04CancelledUnloadKeepsExitPollingPaced`（观察轮询次数，不声称实测 CPU）。 |
| C05 | preview continuation 和任务句柄在同一锁内发布，失效准备取消本次任务；Audio `testPreviewPreparedAfterStopCannotPublishUnownedTasks`。 |
| C07 | 取消在生成器前检查，并经原取消分支记账；Review `cancellationBeforeWorkerStartsNeverEntersGenerator`，旧 `ReviewRetryTests.interruptIsCountedAsInterruptionNotFailure` 保持断言。 |
| C08 | 退出不依赖可能堵塞的 stdout；Python `test_c08_watchdog_exit_does_not_wait_for_full_stdout`。 |
| PY-01 | 仅接纳包含调用方完整前缀的恢复检查点；Python `test_py01_disk_checkpoint_cannot_shorten_caller_prefix`、`test_py01_newer_checkpoint_remains_reusable`（对照）。 |
| PY-02 | 保留最多一个失败保存对象，先交付完整文本，支持同 ID 检查点/退出重试；Python `test_py02_completed_save_failure_keeps_retryable_result`、`test_py02_periodic_save_failure_emits_latest_progress_before_error`。 |
| PY-03 | 同步文件后 replace，再同步目录；Python `test_py03_completed_checkpoint_syncs_before_and_after_publish`、`test_py03_unfinished_checkpoint_syncs_before_and_after_publish`、`test_py03_failed_file_sync_preserves_previous_checkpoint`。 |
| PY-04 | 上传总期限 30 秒、队列/推理等待 120 秒；排队超时取消，运行超时保留真实 ownership 后请求服务退出；Python `test_py04_body_deadline_releases_admission_without_inference`、`test_py04_queued_inference_deadline_cancels_and_releases`、`test_py04_running_deadline_requests_exit_without_false_release`、`test_py04_inference_exception_is_not_misreported_as_upload_timeout`。 |
| PY-06 | 普通上传及增强写入失败时清理自有临时音频；Python `test_py06_partial_raw_write_does_not_leave_unmanaged_temp`、`test_py06_partial_enhancement_write_does_not_leave_unmanaged_temp`。 |
| PY-07 | 唯一 pending 完整写入/同步后以不覆盖 hardlink 发布，再同步目录并复核身份；Python `test_py07_abrupt_exit_never_leaves_partial_final_name`、`test_py07_export_syncs_file_and_directory_around_publication`、`test_py07_failed_file_sync_never_publishes_final_name`。 |
| PY-10 | 拒绝目录/文件软链接扫描及源打开；Python `test_py10_scan_does_not_follow_directory_or_file_symlinks`、`test_py10_inspection_rejects_a_symlink_source`。 |

未完成的低项：DU-05（提交前强杀留下临时文件及首次导出交换留下的空目录，仍需独立恢复管理）；C06（保留 FIFO 有界退避，公平性涉及调度策略）；PY-05（原结果重放需要输入 digest/参数绑定及 ACK 协议）；PY-08（原测试明确要求重复导出 exit=0）；PY-09（原测试明确要求空 model 默认 0.6b）。

兼容性：直接编码的默认 `zh-Hans` 课程快照和 inputFingerprint 仍使用冻结格式；含新增字段的封套及新增退休事件使用阅读版本 2。使用审计的本地 v0.2.0 模块（`85749901f5ada7f30d02b79fdfcfc988aadcea68`）对 DU-01/02 合成课程执行读取和重存，4 次均明确 `unsupportedSchema(2)`，课程文件 hash 均未改变。复查读取保留 v2/v3，v4 增加完整 checksum；不把本地模块验证称为已安装旧 App 的 GUI 验收。

边界：只能恢复主 WAV 实际落盘的完整尾部；live-only 写盘失败仍可能有未落盘 PCM，只保证准确报缺口。协作文件锁不约束旧程序或云同步。不能强制中断阻塞的 Apple 设备调用，但其返回后不得重新发布采集。Python 运行推理超时退出整个子进程，其余 pending 需从保留音频重试；外部卷 hardlink、真实模型/设备、断电和云同步未验证。

证据：`superseded/safety-logs/red-all.log`、`superseded/safety-logs/red-f05-final.log`、`superseded/safety-logs/red-pipe.log`、`superseded/safety-logs/red-app04.log`、`superseded/safety-logs/red-initial-export-permissions.log`、`superseded/safety-logs/green-new-and-migration-red.log`、`superseded/safety-logs/green-safety.log`、`superseded/safety-logs/full-safety.log`（首轮原断言兼容回归）、`superseded/safety-logs/full-final-safety.log`（权限回归）、`work/safety/green-final-targeted.log`、`work/safety/green-export-permissions.log`、`work/safety/full-accepted-safety.log`、`work/safety/python-final-permissions.log`、`work/safety/legacy020-compatibility.json`；Python 红/绿与源码 hash 绑定记录在 `superseded/python-data-safety-*.json`。

产物：13 份已完成的早期日志与 184 项旧结果包、过时架构和临时残留移入 `superseded/`，原目录/文件身份复核一致，没有删除；一份自有只读合成空目录移动后恢复原 0500 权限。仅保留指定的一个当前 DerivedData、最终结果包及必要 CLI/质量证据；当前 DerivedData allocated bytes=792621056，临时目录为空，卷可用字节快照为 23425572864。同卷移动不算释放磁盘空间，卷变化也不能归因于本任务。完整清单及实测保留在 `work/safety/artifact-preservation-complete.json`、`artifact-final.json`。
