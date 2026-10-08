# 隐私修复第三轮验证

本轮从 `cf561cd` 开始，收窄到可移植保存、退出等待和小范围兼容修正。默认中文冻结项、原有断言和安装器实现未改。全部输入为合成数据；没有下载或加载模型。证据目录为工作区旁的 `work/dd-int5/privacy3`，以下日志名均相对于该目录。

## 修复及前后对照

| 改动 | 仓库回归测试 | 修复前失败、修复后通过的证据 |
| --- | --- | --- |
| ACL、权限保留尽力而为；不支持硬链接、扩展 rename、目录同步时回退 | `R05UnsupportedStorageCapabilitiesDoNotBlockNewOrReplacementWrites`、`R05FallbackStillRespectsExistingReadOnlyObject` | `capabilities-baseline-run.log` 的 10 项中 7 项失败；`capabilities-current-run.log` 为 10/10。探针对真实系统调用作明确错误注入，不代表真实 exFAT/FAT 卷验收。 |
| 读取/比较 ACL 元数据失败也按尽力而为处理；仍由内核检查实际写权限 | `R05UnreadableACLMetadataDoesNotBlockWritableReplacement` | 最后补修前源码的 ACL getter 注入 EACCES 后覆盖保存失败，补修后通过，见 `acl-read-error-before.log`、`acl-read-error-after.log` 和相应源码绑定 JSON。已有只读、deny-write、可用 ACL 变化的拒绝断言保留。 |
| 普通停止无退出预算；退出只限制存储无进展的等待 | `testSlowSuccessfulNormalStopHasNoExitBudget`、`testSlowSaveWithProgressCanFinishWithinOneExitAttempt` | `regression-baseline-valid-run.log` 和 `regression-current-valid-run.log`：同一探针包含 15.1 秒成功保存，以及 50 毫秒无进展限时下每 20 毫秒实际写入一次的保存。前者失败，后者通过。 |
| 已开始的后台写入可续期；只接受实际存储进展 | `testPreexistingDetachedWriterRenewsOnlyWithActualStorageProgress` | `preexisting-progress-baseline-run.log` 失败、`preexisting-progress-current-run.log` 通过。旧版仅增加编译所需的新接口空适配，原绝对截止和写入行为未改。 |
| 已完成磁盘清理立即发布事实，重试不保留失效路径 | `testCompletedSynchronousDiskCleanupDoesNotLeaveStaleRoot` | 上述 `regression-*-valid-run.log` 中清理和重试两个检查均由失败变为通过。 |
| 真正挂起时可明确选择仍要退出 | `testAppKitAllowsExplicitExitAfterHungCleanup` | `delegate-quit-baseline-run.log` 失败、`delegate-quit-current-run.log` 通过。使用原样截取的 AppKit delegate 和真实截止；未走到的服务入口为替身，旧版仅增加未被读取的选择回调槽。`delegate-source-binding.json` 绑定原文件哈希。 |
| 保留正常冒号建议，过滤已知完整失败模板 | `R12ColonAdviceIsPreservedAndCompleteFailureWrappersAreRedacted` | `regression-*-valid-run.log` 中正常建议、完整失败包装两个检查均由失败变为通过。 |
| 拒绝重复 JSON/plist 键，检查 XML 丢弃内容；支持有界正常资源 | `test_duplicate_json_and_plist_keys_and_private_xml_comments_are_rejected`、`test_normal_typing_path_certificate_and_openstep_resources_are_preserved` | `package-red2.log`：三个泄漏输入未被拒绝，四种正常资源被拒绝；修复后的定向及全套 Python 验证通过。证书为测试当场生成的公有合成证书。 |
| Python checkpoint 生产序列化绑定已打开文件 | `test_generation_serializer_remains_bound_when_state_directory_is_renamed`、`test_unsupported_empty_acl_preservation_does_not_block_checkpoint_overwrite` | `checkpoint-red2.log` 的一个失败、一个错误在修复后消失。另以 CPU 上的空 safetensors 验证本机 MLX 支持二进制文件对象；不加载模型、不运行 GPU。 |

P07 普通继承 ACL 与 token-file helper 在起点已实现。本轮保留实现，`Scripts/test_installer_token_privacy.py` 的 20 项测试通过，包括普通 ALLOW ACL 清除、原有 DENY ACL 保留、打包 helper 一致性，以及只用内存 transport 的 token-file 客户端。

## 完整门槛与实盘边界

- 最终源码 `xcodebuild build-for-testing` 成功；`Scripts/check_build_warnings.py` 对 `build-final2.log` 报告 0 条编译警告。使用指定 DerivedData，测试构建临时关闭宿主沙盒，未修改工程配置。APFS 宿主实验结束后已卸载映像、恢复普通构建位置。
- Xcode 测试启动通道在本机停滞。采样显示测试宿主或测试代理读取工作区文件时停在内核 `openat`/`open`；独立启动同一真实应用宿主可运行测试。将测试宿主副本放到指定 TMPDIR 内映像提供的 APFS 卷后，正式 `xcodebuild test` 的原有菜单用例通过，见 `apfs-menu-gate.log`；编译器路径映射没有改变 `#filePath` 的夹具位置，保存用例仍停滞，见 `apfs-focused-sample.txt`。完整 `xcodebuild test` 的成功结果尚未取得，不能将编译、单例或替代启动方式称作该门槛通过。工程配置和原断言未改。
- 最终源码的完整真实应用宿主直接加载测试 bundle：1245 个 XCTest，1 个跳过、0 失败；随后 204 个 Swift Testing、11 个 suite、0 失败，进程退出 0。stdout/stderr 分开捕获，见 `host-final-stdout.log`、`host-final-stderr.log`。跳过的是既有的 SwiftUI 无障碍树检查：宿主没有暴露标识，完整键盘/VoiceOver 验收未覆盖。新增 ACL 回归所在的存储定向 13 项也通过，见 `swift-storage-final.log`；退出定向 XCTest 14 项通过，见 `direct-focused.log`。
- `Scripts/check_test_preferences.py` 对正式 Xcode 单例日志 `apfs-menu-gate.log` 为 PASS。最终完整宿主 stdout/stderr 与这份独立真实单例日志组合后，原脚本为 PASS：383 次 CREATED、383 次 CLEANED、对应 plist 全部不存在，见 `preferences-final-evidence.log`。三个输入来源在日志中明示，未补造事件或成功标记；该 PASS 验证偏好清理，不能代替完整原生 `xcodebuild test` 门槛。早先合并输出导致三个事件混行的 `preferences-successful-runs.log` 未计为通过。
- Python 全套：1131 项，只有已知的 ProbePrecision 两个子例失败，6 个跳过、0 错误，见 `python-final3.log`。沿用指定 Python gate 的依赖路径、CPU 设置和测试开关，仅将输出改到本任务 DerivedData；旧夹具根改到该目录，进程单测的 provider 限定为本次测试及其合成子进程，原断言和生产进程保护未改。先前复用目录和其他任务 worker 干扰的失败重跑未计作通过。
- hdiutil 已创建 exFAT/FAT32 小映像。有效映像未能在本机挂载；手工 mount 报文件系统驱动签名错误，最终 hdiutil 复核报“无可装载的文件系统”；按本机新版 `diskutil image attach` 帮助重试同样失败。因此新建、覆盖、导出的真实 exFAT/FAT 实测未完成。映像均已卸载，保留在 `superseded/`，见 `portable-real-volumes.json`、`portable-modern-volumes.json`。备用 macOS 测试 VM 的恢复/工具通道也不可用，已回到挂起；为离线测试临时禁用过 macOS 14 guest 的 en0，挂起状态下未能核实其恢复后的网络状态。没有运行 Windows VM 或更改宿主安全设置。不得把注入探针或 APFS 成功替代实盘验收。
- 最终源码重新编译的 APFS 可移植保存探针：课程新建/覆盖、课程导出新建/覆盖，以及 Markdown、文本、Word、PDF 笔记新建/覆盖共 12 项通过，见 `portable-apfs-final.log`，源码哈希见 `portable-source-binding.json`。仓库保留 `Scripts/test-portable-storage.swift`，供可挂载测试卷复验。

## 保留的限制

`PRIVACY.md` 已明确记录 R01/R04/R05/R07/R08 的同用户恶意抢换竞态、Python 最后检查到 `os.replace` 的竞态和兼容文件名回调的竞态；本轮不添加复杂防护。P09 系统初译离线门槛、P10 全局剪贴板保持原行为。权限不受支持时保存可回退，不保证这些卷上的隐私隔离；明确退出可能丢失尚未写盘的进度，同步内核 I/O 仍可能延迟界面响应。

保留当前构建、前后对照探针和唯一验证证据。失败重试与不再使用的映像进入 `superseded/`；同卷移动可恢复，不作为磁盘空间释放证据。

执行 XCTest 帮助命令时，工具曾意外回显进程环境，违反本任务的环境输出约束。随后停用该调用方式，对后续测试输出过滤环境段，并清理本地已知诊断日志中的该段；不能撤回已经返回的工具输出，不将本轮宣称为完全满足该安全约束。
