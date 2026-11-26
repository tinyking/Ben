# Ben（本）

macOS 原生的本地 Markdown 笔记本。采用类 Apple 备忘录的三栏浏览结构与类 Bear 的实时排版体验，零第三方依赖、数据完全以纯 `.md` 文件落盘。

## 构建与运行

工程使用 `BenApp.xcodeproj` 管理，可直接打开运行：

```bash
open BenApp.xcodeproj   # ⌘R 运行
```

或使用脚本一键构建并启动：

```bash
./run.sh
```

如需修改工程结构（增删目录、修改配置等），编辑 `project.yml` 后执行：

```bash
xcodegen generate
```

- 最低系统：macOS 14 Sonoma
- 存储形式：所有笔记均为 UTF-8 纯 `.md` 文件，可随时用 Git / VS Code / Obsidian 协同

## 核心快捷键

| 快捷键 | 行为 |
|---|---|
| `⌘⇧O` | 打开／切换本子 |
| `⌘O` | 快速打开笔记（无匹配时支持直接新建） |
| `⌘N` / `⌘⇧N` | 新建笔记 / 新建文件夹 |
| `⌘1 / ⌘2` | 所见即所得（类 Bear） / 纯源码 |
| `⌘⌥O` | 显示／隐藏文档大纲 |
| `⌘F` / `⌘⇧F` | 页内查找与替换 / 全库全文搜索 |
| `⌘B / ⌘I / ⌘K` | 加粗 / 斜体 / 插入链接 |
| `⌘⇧U / ⌘⇧H / ⌘⇧K` | 删除线 / 高亮标记 / 行内代码 |
| `⌘⇧L / ⌘⇧T / ⌘⏎` | 无序列表 / 待办清单 / 切换待办完成状态 |
| `⌘↓` | 跳到文末并插入今日日期标题 |
| `⌘⇧R` | 在 Finder 中显示当前笔记 |

## 工程结构

```text
Ben/
├── App/BenApp.swift                  # @main 入口、菜单栏与全局快捷键
├── Models/                           # Vault / NoteFile / EditorState / AppState
├── Services/                         # VaultStore / SearchService / MarkdownStyler
├── Views/                            # 三栏主界面、编辑器、搜索、快速切换、查找替换、设置
├── Resources/Assets.xcassets         # 自适应浅/深色品牌色与 AppIcon
├── project.yml                       # XcodeGen 工程描述
└── BenApp.xcodeproj                  # Xcode 工程
```
