# 历史安装器的令牌文件

这里说明 `Scripts/install-qwen-service.sh`、`Packaging/install.command` 及其私有文件 helper。历史安装路线保留；当前自包含 DMG 的安装流程、ASR 服务鉴权和 Swift 客户端令牌传递没有因这些脚本而改变。App 生命周期与存储修复见 `RUNTIME-PRIVACY.md`。

## R07 的写入规则

`Scripts/installer_token_private.py` 在 Python 内生成令牌和完整 plist。令牌不会进入 shell 变量、`plutil` 参数、客户端参数或安装日志。固定 LaunchAgent 目标仍是 `Library/LaunchAgents/com.jianhongli.LiveLingoASR.plist`。

每个新文件先通过 `O_EXCL` 以 0600 创建；在写入正文前，以文件描述符删除继承的 ALLOW ACL，再重新读取 ACL 和 mode 核验。继承的 DENY ACL 保留。新旧正文的备份、生成副本和最终 plist 都遵循此规则，不依赖裸 `install -m 0600`。现有目录的 mode 和 ACL 不变。

已有最终目标必须是当前用户的普通单链接文件，mode 为 0600、无 ALLOW ACL，并且能以读写方式打开。只读、ACL 禁写、公共权限、符号链接、硬链接、不同 owner 或检查时发生变化的目标一律拒写，不通过 chmod 解除限制。允许替换的目标使用同目录私有文件原子替换，保留原有 DENY ACL，且保留新目录继承的 DENY ACL。此前正文另存为独占名字的私有备份。首次创建使用 macOS `renameatx_np(RENAME_EXCL)`，检查之后突然出现的目标也不会被覆盖。

保留件使用 `old-asr-plist-<随机名字>.plist` 和 `generated-asr-plist-<随机名字>.plist`，不会覆盖已有的 `generated-asr-plist.xml`。开发脚本将旧正文保留在自己的日志目录；旧 Payload 安装器将旧正文和生成副本保留在本次备份目录。它们不会追溯清理或修改历史副本。

失败时，helper 保留自己新建的 pending 文件：ACL 设置/校验失败发生在正文写入之前，因此此时 pending 为空；写入或提交阶段失败时，pending 已经完成私有权限核验。此处不承诺断电后的磁盘持久性，也不提供多个安装器并发更新已有固定目标的事务保证。

## 打包和 P07 的边界

`Packaging/install.command` 内嵌 canonical helper 的完整源码，旧包不需要从仓库查找另一个文件。单元测试比较两份源码的 SHA-256，并实际从内嵌版本导出 helper、用安装路径运行 `health --help`。安装器会把它写入 `ASRService/installer_token_private.py`；开发安装脚本也将同一文件放在服务目录。维护 helper 时必须同步内嵌内容，测试会拒绝两份源码不一致。

两个安装脚本的健康检查现在都使用 `health --token-file <私有 LaunchAgent plist>`。官方辅助 client 同样直接读取这份 plist，并在内存中设置 `X-LiveLingo-Token`；没有打印/导出令牌的命令。请求固定连接 `127.0.0.1:18765`，不使用代理、DNS、共享凭据或重定向。健康检查只报告退出状态，转写 client 只输出 text，并过滤服务器回显的请求令牌；文件轮换不会导致客户端改用第二次读到的令牌做过滤。

需要人工调用辅助工具时，可使用已有 ASR Python：

```sh
python3 -B Scripts/installer_token_private.py health --token-file /synthetic/agent.plist
python3 -B Scripts/installer_token_private.py client --token-file /synthetic/agent.plist --audio-file /synthetic/input.wav --model 0.6b
```

以上是接口示例，本次没有发起网络请求。辅助 client 的健康超时为 2 秒，转写超时为 120 秒，音频上限为 16 MiB。这些是该辅助入口的限制，不是应用或服务的完整接口。

本次补齐 App 侧安装脚本和辅助 client 的 token-file 路线。正式 App 沿用既有的每次启动随机令牌与 endpoint 传递，客户端鉴权回归由完整 App 测试覆盖。任意历史工具不会被自动改写；各旧调用方的自动迁移及真实安装后的端到端兼容仍未验收。服务端依然要求鉴权，没有免鉴权兼容入口。

## 轻量证据

证据位于 `work/privacy-followup/installer/`：

- `red-developer.txt`、`red-package.txt`：基线源码哈希匹配原始脚本；仅提取安装/复制/移动文件操作，用合成路径和令牌运行新断言。没有执行安装器。全部 20 条新测试失败，其中缺失新 helper/client/打包接口的失败属于功能基线，不冒充已复现的泄漏。
- `red-additional.txt`：第一版 helper 上的三条真实失败，分别是打开时权限变化、检查后目标突然出现、令牌轮换时服务器回显泄漏。修复之后这三条通过。
- `green.txt`：20 条新测试、1 条原有冻结安装脚本断言通过；两个安装脚本的 `zsh -n` 通过。回执绑定四个代码/测试文件的 SHA-256。
- `baseline/`：与初始红测哈希匹配的两份原始脚本，用于重现，不用于安装。`legacy_red_probe.py` 和 `run_green_probe.py` 是轻量复核入口。
- `superseded/`：所有合成测试现场及被替代的回执；移动保留，没有删除。早期四份合成 plist 的本机测试目录字段已替换为合成路径，mode 不变；后续测试直接使用纯合成路径。

这些轻量测试在本机 macOS 上使用真实 ACL 文件操作和内存 HTTP transport，Python 为 3.13.3。没有网络、真实安装、launchctl、模型加载、GPU、真实课堂或真实令牌；没有签名或发布。原有冻结 fixture 和断言文件不变。完整 Python/Xcode 验收及其限制单独记录在本任务的本地回执中。

新增测试均在 `Scripts/test_installer_token_privacy.py` 的 `InstallerTokenPrivacyTests` 中：

| 检查 | 测试名 |
| --- | --- |
| 新 plist、继承 ALLOW 和父目录不变 | `test_new_plist_removes_inherited_allow_before_writing_and_preserves_parent` |
| 生成副本的 ALLOW、DENY 和正文 | `test_generated_copy_removes_allow_and_keeps_inherited_deny_and_body` |
| 旧正文私有备份、源文件权限不变 | `test_private_copy_keeps_source_bytes_mode_acl_and_copies_body_privately` |
| 只读目标不变 | `test_read_only_existing_target_is_rejected_without_changes` |
| ACL 禁写目标不变 | `test_acl_denied_existing_write_is_rejected_without_changes` |
| 原子替换、DENY、mode 和备份 | `test_atomic_replace_preserves_existing_deny_mode_and_private_backup` |
| 公共权限目标不做权限迁移 | `test_public_existing_target_is_rejected_without_permission_migration` |
| 符号链接拒写 | `test_linked_existing_target_is_rejected_without_changing_either_file` |
| 硬链接拒写 | `test_hard_linked_existing_target_is_rejected_without_changing_either_file` |
| 已有生成副本不覆盖 | `test_generated_copy_uses_exclusive_names_and_preserves_existing_copy` |
| ACL 失败发生在正文写入前 | `test_acl_failure_happens_before_any_token_body_is_written` |
| 脚本无 token argv、使用 token-file 和预检 | `test_installers_keep_tokens_out_of_subprocess_arguments_and_use_token_file` |
| 内嵌源码一致、导出后的调用路径可用 | `test_packaged_installer_contains_identical_helper_and_installs_usable_path` |
| 健康和转写的内存鉴权请求 | `test_token_file_health_and_client_authenticate_memory_requests_only` |
| 重定向拒绝 | `test_token_file_client_rejects_redirect_without_following_it` |
| 非私有/缺失文件在联网前拒绝 | `test_client_rejects_public_or_missing_token_file_before_transport` |
| 内部合成 token、程序参数和保留正文 | `test_generated_launchagent_uses_internal_token_and_preserves_program_body` |
| 打开时权限变更 | `test_permission_change_during_target_open_is_rejected` |
| 检查后出现新目标 | `test_late_target_appearance_is_rejected_without_overwriting_it` |
| 令牌轮换和服务器回显 | `test_client_never_prints_server_echoed_token_even_when_token_file_rotates` |

原有断言名为 `test_installers_configure_a_private_authenticated_launchagent`。轻量探针直接执行其未改动的方法 AST，不导入 ASR 模块或模型依赖。
