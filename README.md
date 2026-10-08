# FileMerge（文件去重合并工具）

一个 macOS 原生 SwiftUI 应用：把**主目录**和**副目录**两棵目录树合并到**最终目录**，在合并过程中按文件内容（SHA-256）做**全局排重**——无论重复文件位于哪个子目录、属于哪个源目录，内容相同的文件最终只保留一份。

面向海量文件场景设计：全流程并发执行、哈希按需分级计算、进度节流上报，UI 不会被进度事件淹没，任务可随时取消。

---

## 功能特性

- **跨目录全局排重**：主、副目录的**全部子目录**之间统一比对，按文件哈希聚类，内容一致只保留一份。
- **主目录优先**：同一内容簇中保留「主目录」的版本；同在某一目录内时保留相对路径排序最靠前者。
- **冲突自动重命名**：副目录文件与已写入文件相对路径冲突时，自动落位为 `名称 (1).ext`、`名称 (2).ext`…（最多 9999，超限用 UUID 兜底）。
- **幂等重跑**：目标文件已存在且内容完全一致则跳过；重复执行合并不会产出重复副本，也不会产生递增编号的新副本。
- **安全校验**：禁止最终目录与任一源目录互相嵌套或相同，路径先经 `realpath` 解析符号链接、折叠大小写后再比较。
- **随时取消**：扫描、哈希、合并各阶段均在关键循环中检查取消，取消后状态可回到「已分析」再次合并。
- **实时进度与日志**：统计条、进度条、阶段文本与滚动日志区；日志上限 2000 行，超出自动滚动淘汰。
- **容错不中断**：单个文件不可读 / 复制失败只记录错误，不影响其他文件；目标位置被目录占用时拒绝覆盖并报错。
- **完成后可在访达中显示**最终目录。

## 界面说明

窗口分上下两部分：

| 区域 | 内容 |
| --- | --- |
| 配置区（上 1/3） | 主目录 / 副目录 / 最终目录三个选择框、「开始分析」按钮、执行中的「取消」按钮、失败原因提示 |
| 处理过程区（下 2/3） | 统计条（主目录、副目录、预计合并后 + 「开始合并」按钮）、日志区、底部状态栏（进度条 + 阶段文本 + 状态） |

典型流程：选择三个目录 → **开始分析** → 查看「预计合并后」与节省空间 → **开始合并** → 合并完成后「在访达中显示」。

## 架构

```
FileMergeApp  可执行入口（SwiftUI App）
   └── FileMergeUI    界面层：ContentView / AppViewModel / DirectoryPicker / Formatters
         └── FileMergeCore  引擎层（与 UI 解耦，可独立作为库使用）
```

| 模块 | 职责 |
| --- | --- |
| `FileMergeCore/FileScanner` | 有界并发递归扫描目录树，产出按相对路径排序的 `FileInfo`；跳过符号链接，不可读子目录记录 warning |
| `FileMergeCore/FileHasher` | 流式 SHA-256（1 MB 分块，内存恒定）、头部哈希（64 KB）、两文件内容比对，均支持取消 |
| `FileMergeCore/DedupEngine` | 排重并生成 `MergePlan`（待复制条目、重复数、节省字节） |
| `FileMergeCore/MergeEngine` | 执行 `MergePlan`：目标预检 → 串行决策 → 集中建目录 → 并行复制 |
| `FileMergeCore/MergeValidator` | 三个目录的存在性与嵌套关系校验 |
| `FileMergeCore/ParallelMap` | 滑动窗口式有界并发 `map`，结果顺序与输入一致 |
| `FileMergeCore/ProgressReporter` | 锁保护的进度累加器，按时间节流回调，序列号单调递增 |
| `FileMergeCore/Models` | 数据模型与 `FileMergeConfig` 全局参数 |
| `FileMergeUI/AppViewModel` | `@MainActor` 状态机：`idle → analyzing → analyzed → merging → merged / failed`，串联引擎并发布进度与日志 |

### 排重算法（`DedupEngine`）

1. **按尺寸分组**：尺寸唯一的文件直接判定唯一，不读内容。
2. **头部哈希预筛**：同尺寸组计算前 64 KB 的哈希；小于等于 64 KB 的文件直接算全量哈希。头部唯一即判定唯一。
3. **全量哈希定案**：预筛后仍冲突的「幸存者」做全量 SHA-256 聚类。
4. **生成计划**：每簇保留最优先者（主目录优先，其次相对路径升序），其余计入重复数与节省空间；条目最终按「主目录在前、各自按相对路径升序」排序，保证结果确定。

哈希结果按绝对路径缓存（锁保护），避免主/副目录嵌套重叠时同一文件重复读盘；预筛与全量哈希共用同一个 `ProgressReporter`，总量在进入全量阶段时扩展，进度条连续不回跳。

### 合并策略（`MergeEngine`）

1. **并行预检**：对每个条目判断目标是否存在、内容是否一致（幂等判断基础）。
2. **串行决策**（冲突与重命名需要全局顺序）：
   - 相对路径已被占用 → 副目录条目走重命名落位；
   - 目标存在且内容一致 → 跳过；
   - 目标存在但内容不同，且条目来自主目录 → 覆盖；
   - 其余情况 → 副目录条目重命名落位。
3. **集中创建父目录**（去重后的目录集合，避免逐文件 `mkdir`）。
4. **并行复制**：有界并发，逐文件实时上报进度；目标为目录时拒绝覆盖。

## 并发与性能

- 默认并发度 `min(max(4, CPU 核心数), 16)`（`FileMergeConfig.defaultConcurrency`）。
- 扫描：固定数量 worker 从共享目录队列取目录，不随目录深度扩张；文件按 512 个/批批量入列与上报，降低锁竞争。
- 哈希：1 MB 分块流式读取，内存占用恒定；头部预筛大幅减少全量 IO。
- 复制：`ParallelMap` 滑动窗口调度，一个任务完成立刻补位，大文件不会形成队头阻塞。
- 进度节流：默认 0.1 s 一次回调；快照携带单调 `seq`，UI 丢弃过期/跨阶段的迟到事件。

## 构建与运行

要求：macOS 13+，Swift 6 工具链（源码使用 Swift 5 语言模式）。

```bash
# 构建
swift build

# 运行
swift run FileMergeApp

# 运行测试
swift test
```

打包为独立 `.app`（脚本会先做 release 构建，再组装 `Contents`、拷贝 `Info.plist` 与图标并做 ad-hoc 签名）：

```bash
./scripts/make_app.sh     # 产物：build/FileMerge.app
```

## 测试

使用 Swift Testing（非 XCTest），共 62 个用例：

| 套件 | 覆盖 |
| --- | --- |
| `EndToEndTests` | 扫描 → 排重 → 合并全流程、路径重叠、大文件去重 |
| `DedupEngineTests` | 跨目录去重、主目录优先、尺寸/头部唯一短路、进度总量 |
| `MergeEngineTests` | 落位、重命名递增、幂等重跑、目录占用保护、进度快照、单文件失败隔离 |
| `MergeValidatorTests` | 嵌套/相同目录拒绝、符号链接别名、目录不存在 |
| `FileScannerTests` | 递归统计、符号链接、排序、取消、根目录错误、子目录警告 |
| `FileHasherTests` | 已知 SHA-256 值、分块一致性、头部哈希、空文件、取消 |
| `ParallelMapTests` | 顺序保持、并发上限、外部取消、错误传播 |
| `ProgressReporterTests` | 节流、总量、序列号单调 |
| `AppViewModelTests` | 状态机流转、统计与预估填充、校验失败、分析结果失效 |

## 目录结构

```
Sources/
  FileMergeApp/      FileMergeMain.swift        应用入口
  FileMergeUI/       ContentView.swift          布局（上 1/3 配置 + 下 2/3 过程）
                     AppViewModel.swift         状态机与流程编排
                     DirectoryPicker.swift      NSOpenPanel 封装
                     Formatters.swift           数字/字节格式化
  FileMergeCore/     Models.swift, FileScanner.swift, FileHasher.swift,
                     DedupEngine.swift, MergeEngine.swift, MergeValidator.swift,
                     ParallelMap.swift, ProgressReporter.swift
Tests/
  FileMergeCoreTests/  引擎层测试 + TestSupport.swift（临时目录/文件工具）
  FileMergeUITests/    AppViewModel 测试 + UITestSupport.swift
scripts/               make_app.sh、Info.plist、AppIcon.icns
```

## 已知限制

- 仅处理普通文件：**符号链接会被跳过**（规避环与重复计算），不是软链接合并工具。
- 排重依据是**文件内容**，与文件名无关；同路径不同内容的文件会共存（副目录版本重命名）。
- 使用 `FileManager.copyItem` 的默认复制语义，不对扩展属性、资源分支等特殊元数据做额外处理。
- 合并不会删除源目录，源数据保持不变。
- 目录选择面板依赖 `NSOpenPanel`，仅适用于 macOS GUI 会话。
