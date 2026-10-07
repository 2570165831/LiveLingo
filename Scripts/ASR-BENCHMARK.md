# 离线检查语音分段边界

`benchmark-asr-chunking.py` 用同一份录音比较两种处理：连续固定长度分段，以及每段前后各多听一小段、再用 Parakeet 自带的对齐方法合并。它只读取本地模型和音频，不启动或修改 App，也不下载模型。

输入必须是 **16 kHz、单声道、PCM16 WAV**。输出必须是一个尚不存在的 JSON 文件；重复运行要换输出文件名。使用已有 ASR 运行环境的 Python 和依赖，例如在仓库根目录运行：

```sh
PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH=/Applications/LiveLingo.app/Contents/Resources/ASRRuntime/python/lib/python3.13/site-packages \
python3.13 -B Scripts/benchmark-asr-chunking.py \
  --audio /path/to/lecture.wav \
  --model /Applications/LiveLingo.app/Contents/Resources/Models/mlx-community/parakeet-tdt-0.6b-v2 \
  --output /path/to/new-comparison.json \
  --duration-seconds 600 --chunk-seconds 8 --overlap-seconds 0.5
```

`--start-seconds` 可选择录音内的起点。最后一段按实际音频长度截断，额外上下文也不超出所选区间。模型需要与当前 ASR 运行环境兼容；不要为运行测试替换 App 内的依赖。

默认结果只保留时长、分段计数、实际音频帧数、校验值和依赖版本，不保存逐段原文、合并文本或输入文件名。需要私下核对识别文字时显式加 `--include-content`，该报告会含正文。新建输出文件为 0600，新建输出目录为 0700；失败只记录固定错误类别，不回显原始诊断。模型配置校验值不是模型权重的校验值，跨机器复现时还应核对所用权重。

每次先预热一次，之后交替改变两种处理的先后顺序。`generation_seconds` 仅记录识别调用，不包含模型载入、音频读取及 App 排队；合并耗时另列。`processed_audio_seconds` 是累计送入模型的音频长度，重叠部分会重复计入。它们都不能直接代表耗电或实时字幕延迟。

`prefix_checks` 检查合并有没有改写前一段可能已显示的文字。其 `lag_seconds` 是按照词元时间戳划出的保留尾部长度，**不是实测的字幕延迟**；若等下一段到来才确认尾字，等待可能达到另一个分段周期。这里只统计诊断信息，没有实现可用于实时字幕的提交策略。

工具不计算准确率。若另行与课程字幕对照，应保留参考来源和标准化方法，逐条核实否定、数字、术语等关键变化。官方发布的字幕也可能有错，文字差异减少不等于真实识别错误减少。固定时长的离线分段也不等于 App 当前按停顿决定的分段。

不载入模型即可运行边界与音频格式检查：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s Scripts -p test_benchmark_asr_chunking.py -v
```
