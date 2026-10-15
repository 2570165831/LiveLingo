# LL4 公证交接说明草稿

本页供 LL4 在对应授权下操作。实验室本轮只修流程和离线测试，没有执行真实 notarytool、stapler、上传、公证、VM 或发布。下列路径与哈希故意留空，最终候选产生后由派单方填写；不能引用旧 0.2.0 签名演练的哈希充当新许可输入或 0.3.0 的验收。

## 交接对象

| 字段 | 待填内容 |
|---|---|
| 最终源码提交、版本和 build | `<FINAL_SOURCE_COMMIT>` / `<FINAL_VERSION_AND_BUILD>` |
| 已签名、未公证 App | `<FINAL_SIGNED_APP_PATH>` |
| App 完整树指纹、逻辑字节数 | `<APP_TREE_SHA256>` / `<APP_BYTES>`；算法为 local_candidate.fingerprint |
| App 主程序 SHA-256 | `<APP_MAIN_SHA256>` |
| 本地候选 DMG、字节数和 SHA-256 | `<LOCAL_CANDIDATE_DMG_PATH>` / `<CANDIDATE_DMG_BYTES>` / `<CANDIDATE_DMG_SHA256>` |
| 新许可运行库及模型输入基线 | `<INPUTS_RECEIPT_PATH>` / `<INPUTS_RECEIPT_SHA256>` |
| signed-resource-review 与签名前外部收据 | `<SIGNED_REVIEW_PATH_AND_SHA256>` / `<BEFORE_SIGNING_RECEIPT_PATH_AND_SHA256>` |
| Python、Swift、发布流程、模型和元数据证据 | `<VALIDATION_RECEIPTS_AND_SHA256>` |
| 同一最终版本的 VM owner 回执 | `<VM_OWNER_RECEIPT>`；本实验室未操作 VM |
| 正式公证后 DMG 输出路径 | `<FINAL_NOTARIZED_DMG_PATH>`，须为外接任务根中的新文件 |
| App/DMG 公证编号及最终装订后哈希 | `<APP_SUBMISSION_ID>` / `<DMG_SUBMISSION_ID>` / `<STAPLED_DMG_SHA256>` |

目录没有单文件 SHA；App 使用完整树指纹，DMG 使用整个文件的数据流 SHA。最终对象、大小、版本、源码提交和证据必须互相对应。App 装订后新增票据，树指纹会变化；DMG 装订后文件 SHA 会变化，必须分别重新记录。

## LL4 需要自行确认的资料

- 已有 keychain profile 名称 `<LL4_NOTARY_PROFILE>`、其所属 Apple Developer 团队和有效凭据；实验室没有查询 profile 是否存在，也没有查询 history。不要把密码、API Key 或钥匙串内容写进交付包。
- 签名身份为 `Developer ID Application: Jianhong Li (6L6KQXUJM3)`，预期证书 SHA-1 为 `CE96F7A5CD734131B458CFC5A64BC0EEA43C0EC9`。签 DMG 前实时核验证书有效期和显式签名钥匙串中的匹配私钥身份；证书文件自身不能作为 codesign identity。
- profile 所在钥匙串与签名钥匙串独立。profile 在默认搜索列表时省略 `--notary-keychain` 整项，不要把签名钥匙串参数自动传给公证工具。
- 内置 records 目录、外接最终输出目录及精确暂存目录；权限测试仍留内置盘。新内置盘大写入前先 df，低于任务空间线不开始。重活开始前检查机器空闲，执行中每 120 秒复查，已装 App 运行时暂停本任务进程组。
- 使用宿主 Python；不执行 App 内的任何解释器或程序。所有挂载只读、不浏览、不自动打开。出现密码/交互提示或连续 15 分钟无进展，停止本任务，不解锁、导入、导出或修改钥匙串。

## 正式顺序和命令

正式入口 `build-offline-dmg.sh` 自行按以下顺序完成，**不加 `--candidate-only`**：

1. 核验已签名 App，克隆到新的私有暂存；原输入 App 保留。
2. 用只含 App 的临时 DMG 提交 App 公证，记录编号，查询到 `Accepted`，再装订暂存 App 并验证票据、严格签名和隐私。不是先公证本地候选发布 DMG。
3. 用已经装订的 App 制作正式 DMG，离线清理已识别 HFS 显示字段、转换 UDZO，再使用 Developer ID 签名，校验签名和 CRC。
4. 提交签好名的正式 DMG 公证，查询到 `Accepted`；保留已上传原件，在同卷工作副本上装订并重新验证。
5. 校验最终 DMG 和只读挂载的 App：真实票据、严格签名、Authority、Gatekeeper、内容隐私、容器元数据和全部扩展属性。成功卸载后才放到正式输出名。

变量均由派单方填入最终对象。以下命令由 LL4 通过其机器空闲及无交互监测执行器运行；前置一次空闲检查不能代替执行中的轮询。公证处理时间由 Apple 和网络决定，本地演练计时不构成公证完成时间保证。

```sh
ll4_source='<FINAL_SOURCE_CHECKOUT>'
ll4_app='<FINAL_SIGNED_APP_PATH>'
ll4_dmg='<FINAL_NOTARIZED_DMG_PATH>'
ll4_output='<EXTERNAL_OUTPUT_DIRECTORY>'
ll4_records='<NEW_INTERNAL_RECORD_DIRECTORY>'
ll4_machine_free='<MACHINE_FREE_SCRIPT>'
ll4_identity='Developer ID Application: Jianhong Li (6L6KQXUJM3)'
ll4_certificate='<DEVELOPER_ID_PUBLIC_CERTIFICATE>'
ll4_signing_keychain='<SIGNING_KEYCHAIN_DB>'
ll4_profile='<LL4_NOTARY_PROFILE>'
ll4_profile_keychain='<PROFILE_KEYCHAIN_DB>'
cd "${ll4_source}"
unset LIVELINGO_TEST_TOOL_DIR LIVELINGO_NOTARY_PROFILE LIVELINGO_NOTARY_KEYCHAIN
"${ll4_machine_free}" 0
/usr/bin/openssl x509 -inform DER -in "${ll4_certificate}" -noout -dates -fingerprint -sha1
/usr/bin/security find-identity -v -p codesigning "${ll4_signing_keychain}"
/opt/homebrew/bin/python3.13 -B Scripts/sign-offline-app.py --verify-only \
  --app "${ll4_app}" --identity "${ll4_identity}"
LIVELINGO_PYTHON=/opt/homebrew/bin/python3.13 \
  LIVELINGO_OFFLINE_OUTPUT_DIR="${ll4_output}" \
  /bin/zsh Scripts/build-offline-dmg.sh \
  --app "${ll4_app}" --output "${ll4_dmg}" \
  --identity "${ll4_identity}" --keychain "${ll4_signing_keychain}" \
  --notary-profile "${ll4_profile}" --notary-keychain "${ll4_profile_keychain}" \
  --image-method hybrid --mount-point "${ll4_records}/build-verify-mount" \
  --xattr-report "${ll4_records}/created-image-metadata.json"
```

先创建受限的 records 新目录，并确认所有输出/报告名尚不存在。正式入口分别记录上传与处理时间，不使用 `--wait`，不因结果未知自动重传。默认上传不限时，处理期限 3600 秒；需要不同期限时由 LL4 按本轮安排显式提供 `--notary-submit-timeout`、`--notary-timeout` 等参数，不照搬实验室截止时间。

## 装订后必须重新验证

从正式流程日志/状态取得真实的已装订暂存 App 路径，填入下列占位符。不要对原输入 App 原地装订。装订后的隐私阶段必须为 `signed`；`final` 和 `prepare` 会有意拒绝票据。

```sh
ll4_stapled_app='<EXACT_STAPLED_STAGE_APP_PATH>'
"${ll4_machine_free}" 0
/usr/bin/xcrun stapler validate "${ll4_stapled_app}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${ll4_stapled_app}"
/opt/homebrew/bin/python3.13 -B Scripts/sign-offline-app.py --verify-only \
  --app "${ll4_stapled_app}" --identity "${ll4_identity}"
/opt/homebrew/bin/python3.13 -B Scripts/privacy_package.py check \
  --root "${ll4_stapled_app}" --phase signed
/usr/sbin/spctl --assess --type execute --verbose=4 "${ll4_stapled_app}"
LIVELINGO_PYTHON=/opt/homebrew/bin/python3.13 \
  /bin/zsh Scripts/verify-release-dmg.sh --dmg "${ll4_dmg}" \
  --identity "${ll4_identity}" --privacy-phase signed \
  --mount-point "${ll4_records}/independent-verify-mount" \
  --xattr-report "${ll4_records}/final-image-metadata.json"
/usr/bin/shasum -a 256 "${ll4_dmg}"
/usr/bin/stat -f '%z' "${ll4_dmg}"
```

记录 App 装订后的完整树指纹、主程序 SHA、票据 SHA 和大小；实际只读挂载后再比较模型全文件哈希和已装订 App 的完整树指纹。上面的独立 verify 会重新验证 DMG 及内置 App 的票据、签名、预期 Authority、Gatekeeper、CRC、隐私与属性，并要求成功卸载。两项 Gatekeeper 都应为 `Notarized Developer ID`；不能把旧演练的未公证拒绝当正式通过。

隐私门仅把顶层 `LiveLingo.app/Contents/CodeResources`、普通非链接、`s8ch` 开头且不超过 64 KiB 的文件分类为 signed 票据；`stapled_tickets=1` 和 opaque 计数可见。它不验证票据密码学真实性，真正的 `stapler validate` 不能省略。`_CodeSignature/CodeResources` 仍使用结构化封印规则。

## 中断恢复与分发边界

使用日志给出的准确 stage，保留原件、状态、提交回执及编号，不新建任务盲目重传：

```sh
ll4_stage='<EXACT_PRESERVED_STAGE_PATH>'
LIVELINGO_PYTHON=/opt/homebrew/bin/python3.13 \
  /bin/zsh Scripts/build-offline-dmg.sh --resume-stage "${ll4_stage}" \
  --notary-profile "${ll4_profile}" --notary-keychain "${ll4_profile_keychain}" \
  --mount-point "${ll4_records}/resumed-build-verify-mount" \
  --xattr-report "${ll4_records}/resumed-image-metadata.json"
```

先核对原进程已退出、stage 无活动占用、没有本任务残留挂载或活动锁。只有证实已完成上传的编号才能传 `--app-submission-id` / `--dmg-submission-id`；不要默认加 `--resubmit-incomplete`。失败件按任务规则移入同卷 to-trash，不永久删除。

门禁检查实际分发镜像内容。内部 provenance 等未审查属性会拒绝；DMG 宿主文件自身属性另列，实际传输若携带 xattr、AppleDouble 或资源叉，必须复核那份传输对象。CAR/Metal/旧图像的专有内部结构未完全解码等已列边界，须补查或取得针对具体缺口的知情决定。新装订、复制、转换或打包后，对受影响对象重验，不沿用旧哈希。最终正式 DMG、App 和所有回执的清单交给发布负责人；日志、状态、凭据和本机路径不混入公开包。本文不授权发布、推送或额外外传。
