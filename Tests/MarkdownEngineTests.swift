import XCTest
import AppKit
@testable import Ben

final class MarkdownEngineTests: XCTestCase {
    private let wysiwygConfig = MarkdownStyler.StyleConfig(
        mode: .wysiwyg,
        proseFontName: "System",
        codeFontName: "SFMono-Regular",
        fontSize: 15,
        lineSpacing: 5
    )

    // MARK: - 1. YAML Frontmatter 解耦与无损往返

    func testFrontmatterDecouplingAndLosslessRoundTrip() throws {
        let original = """
        ---
        title: "深度重构笔记"
        date: 2026-11-26
        # YAML 内部注释不应进入正文或大纲
        tags:
          - markdown
          - macos
        ---

        # 正文一级标题

        **首段重点**：这是剥离 Frontmatter 后的真实正文。
        """

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("note.md")
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let editor = EditorState()
        XCTAssertTrue(editor.load(fileURL))

        // 验证 Frontmatter 被剥离且键值正确，正文不含 Frontmatter
        let fm = try XCTUnwrap(editor.frontmatter)
        XCTAssertEqual(fm.fields.map(\.key), ["title", "date", "tags"])
        XCTAssertEqual(fm.fields.first(where: { $0.key == "title" })?.value, "\"深度重构笔记\"")
        XCTAssertEqual(fm.fields.first(where: { $0.key == "tags" })?.value, "[markdown, macos]")
        XCTAssertFalse(editor.text.contains("title:"))
        XCTAssertTrue(editor.text.hasPrefix("\n# 正文一级标题"))

        // 验证 YAML 内 `# 注释` 不污染文档大纲，且大纲仅包含正文标题
        XCTAssertEqual(editor.outline, [OutlineEntry(line: 2, level: 1, title: "正文一级标题")])

        // 验证未改动属性栏时，保存回 `.md` 100% 字节级原样保留（含注释与多行缩进格式）
        XCTAssertTrue(editor.save())
        let savedUnmodified = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(savedUnmodified, original)

        // 验证编辑属性栏与正文后，保存并重新加载全部往返一致
        let titleFieldID = try XCTUnwrap(fm.fields.first(where: { $0.key == "title" })?.id)
        editor.updateFrontmatterField(id: titleFieldID, key: "title", value: "更新后的标题")
        editor.updateTextFromUser(editor.text + "\n---\n")
        XCTAssertTrue(editor.save())

        let reloaded = EditorState()
        XCTAssertTrue(reloaded.load(fileURL))
        XCTAssertEqual(reloaded.frontmatter?.fields.first(where: { $0.key == "title" })?.value, "更新后的标题")
        XCTAssertTrue(reloaded.text.hasSuffix("\n---\n"))
    }

    func testHorizontalRulesAtTopAreNotMistakenForFrontmatter() {
        let markdown = """
        ---

        # 第一章
        普通段落正文，没有任何 YAML 冒号键值。

        ---
        """
        let parsed = FrontmatterParser.parse(markdown)
        XCTAssertNil(parsed.frontmatter, "首尾分割线包裹普通正文绝不能误判为 YAML Frontmatter")
        XCTAssertEqual(parsed.body, markdown)
    }

    // MARK: - 2. 行首 `**加粗**` 不缩进、不误判列表

    func testLeadingBoldHasZeroIndentAndHiddenDelimiters() {
        let markdown = "**行首加粗标题**\n普通第二行"
        let storage = MarkdownStyler.styledStorage(for: markdown, config: wysiwygConfig)
        let ns = storage.string as NSString

        // 第 1 行段落缩进必须严格为 0（绝不被误判为 `* ` 无序列表）
        let para = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(para?.firstLineHeadIndent, 0)
        XCTAssertEqual(para?.headIndent, 0)

        // 开闭 `**` 在非光标行中应零宽隐藏，消除两格假缩进
        XCTAssertEqual(storage.attribute(.benHiddenSyntax, at: 0, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(storage.attribute(.benHiddenSyntax, at: 1, effectiveRange: nil) as? Bool, true)

        let bodyRange = ns.range(of: "行首加粗标题")
        let boldFont = storage.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(boldFont)
        XCTAssertTrue(MarkdownStyler.isBoldFont(boldFont!))
        XCTAssertNil(storage.attribute(.benHiddenSyntax, at: bodyRange.location, effectiveRange: nil))

        // 光标进入第 1 行时，`*` 自动显现以便编辑
        let activeStorage = MarkdownStyler.styledStorage(
            for: markdown,
            config: wysiwygConfig,
            activeRanges: [NSRange(location: 2, length: 0)]
        )
        XCTAssertNil(activeStorage.attribute(.benHiddenSyntax, at: 0, effectiveRange: nil))
    }

    // MARK: - 3. 有序列表 + 加粗 + 中文冒号：`1. **加粗**：正文` & 段落样式不串位

    func testOrderedListWithBoldAndChineseColonDoesNotLeakParagraphStyle() {
        let markdown = "1. **加粗**：正文说明\n下一行普通段落"
        let storage = MarkdownStyler.styledStorage(for: markdown, config: wysiwygConfig)
        let ns = storage.string as NSString

        // 列表行具有悬挂缩进，但下一行普通段落缩进必须归零（绝不串位）
        let listPara = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(listPara?.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(listPara?.headIndent ?? 0, 14)

        let nextLineRange = ns.range(of: "下一行普通段落")
        let nextPara = storage.attribute(.paragraphStyle, at: nextLineRange.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(nextPara?.firstLineHeadIndent, 0)
        XCTAssertEqual(nextPara?.headIndent, 0)

        // 验证「加粗」为粗体，紧贴的「：正文说明」保持常规字重
        let boldRange = ns.range(of: "加粗")
        let colonRange = ns.range(of: "：正文说明")
        let boldFont = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        let regularFont = storage.attribute(.font, at: colonRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(MarkdownStyler.isBoldFont(boldFont!))
        XCTAssertFalse(MarkdownStyler.isBoldFont(regularFont!))
    }

    // MARK: - 4. 中文引号内加粗 `**「AI」**` 与中文紧贴混排

    func testBoldWithChineseQuotesAndAdjacentCJK() {
        let markdown = "聚焦**「AI」**能力与**核心关键词**：持续演进"
        let storage = MarkdownStyler.styledStorage(for: markdown, config: wysiwygConfig)
        let ns = storage.string as NSString

        let quoteBold = ns.range(of: "「AI」")
        for offset in 0..<quoteBold.length {
            let font = storage.attribute(.font, at: quoteBold.location + offset, effectiveRange: nil) as? NSFont
            XCTAssertTrue(MarkdownStyler.isBoldFont(font!), "索引 \(offset) 字符应为粗体")
        }

        let keywordBold = ns.range(of: "核心关键词")
        let keywordFont = storage.attribute(.font, at: keywordBold.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(MarkdownStyler.isBoldFont(keywordFont!))

        // 前后相邻中文与冒号不应被误加粗
        let prefixFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let middleRange = ns.range(of: "能力与")
        let middleFont = storage.attribute(.font, at: middleRange.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(MarkdownStyler.isBoldFont(prefixFont!))
        XCTAssertFalse(MarkdownStyler.isBoldFont(middleFont!))
    }

    // MARK: - 5. 独立 `---` / `***` / `___` 分割线标记与光标激活态

    func testHorizontalRuleDetectionAndEditableReveal() {
        let markdown = "上方段落\n\n---\n\n* * *\n\n___\n\n下方段落"
        let storage = MarkdownStyler.styledStorage(for: markdown, config: wysiwygConfig)
        let ns = storage.string as NSString

        let dashRange = ns.range(of: "---")
        let starRange = ns.range(of: "* * *")
        let underRange = ns.range(of: "___")

        for ruleRange in [dashRange, starRange, underRange] {
            XCTAssertEqual(storage.attribute(.benHorizontalRule, at: ruleRange.location, effectiveRange: nil) as? Bool, true)
            XCTAssertEqual(storage.attribute(.benHiddenSyntax, at: ruleRange.location, effectiveRange: nil) as? Bool, true)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: ruleRange.location, effectiveRange: nil) as? NSColor, .clear)
        }

        // 光标移入 `---` 行时，源码字符恢复可见可编辑，同时底层文本不发生任何替换
        let editingStorage = MarkdownStyler.styledStorage(
            for: markdown,
            config: wysiwygConfig,
            activeRanges: [NSRange(location: dashRange.location + 1, length: 0)]
        )
        XCTAssertEqual(editingStorage.string, markdown)
        XCTAssertEqual(editingStorage.attribute(.benHorizontalRule, at: dashRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(editingStorage.attribute(.benHiddenSyntax, at: dashRange.location, effectiveRange: nil))
        XCTAssertNotEqual(editingStorage.attribute(.foregroundColor, at: dashRange.location, effectiveRange: nil) as? NSColor, .clear)
    }

    // MARK: - 6. 引用块 `>` 与多级嵌套 `>>`

    func testBlockquoteIndentDepthAndInlineBold() {
        let markdown = "> **引用重点**：单层引用\n>> 二层嵌套引用"
        let storage = MarkdownStyler.styledStorage(for: markdown, config: wysiwygConfig)
        let ns = storage.string as NSString

        XCTAssertEqual(storage.attribute(.benBlockquoteDepth, at: 0, effectiveRange: nil) as? Int, 1)
        let para1 = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(para1?.firstLineHeadIndent, 16)
        XCTAssertEqual(para1?.headIndent, 16)

        let quoteBold = ns.range(of: "引用重点")
        let boldFont = storage.attribute(.font, at: quoteBold.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(MarkdownStyler.isBoldFont(boldFont!))

        let line2Range = ns.range(of: ">> 二层嵌套引用")
        XCTAssertEqual(storage.attribute(.benBlockquoteDepth, at: line2Range.location, effectiveRange: nil) as? Int, 2)
        let para2 = storage.attribute(.paragraphStyle, at: line2Range.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(para2?.firstLineHeadIndent, 32)
    }

    // MARK: - 7. 围栏代码块 ````text 包裹内层 ``` 与 ~~~

    func testFourBacktickCodeFenceProtectsInnerMarkdownAndTripleBackticks() {
        let markdown = """
        ````text
        # 这不是标题
        **这不是加粗**
        ```swift
        let x = 1
        ```
        ---
        ````
        # 真正标题
        """

        let storage = MarkdownStyler.styledStorage(for: markdown, config: wysiwygConfig)
        let ns = storage.string as NSString

        let fakeHeading = ns.range(of: "# 这不是标题")
        let fakeBold = ns.range(of: "这不是加粗")
        let innerFence = ns.range(of: "```swift")
        let innerDash = ns.range(of: "---")
        let realHeading = ns.range(of: "真正标题")

        XCTAssertEqual(storage.attribute(.benCodeBlock, at: fakeHeading.location, effectiveRange: nil) as? String, "body")
        XCTAssertEqual(storage.attribute(.benCodeBlock, at: innerFence.location, effectiveRange: nil) as? String, "body")
        XCTAssertNil(storage.attribute(.benHorizontalRule, at: innerDash.location, effectiveRange: nil))

        let codeBoldFont = storage.attribute(.font, at: fakeBold.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(MarkdownStyler.isBoldFont(codeBoldFont!))

        let realHeadingFont = storage.attribute(.font, at: realHeading.location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(realHeadingFont?.pointSize ?? 0, 20)
    }

    // MARK: - 8. 其他全套 Markdown 语法与完整往返测试

    func testComprehensiveInlineAndBlockSyntaxSuite() throws {
        let fullDoc = """
        ---
        author: Ben
        status: draft
        ---
        # 一级标题

        * 无序列表项含 *中文斜体* 与 *English Italic*
        - [ ] 未完成任务
        - [x] 已完成任务

        代码隔离测试：`a * b` 乘以 `c * d` 以及 `**不加粗**`、`` `双反引号` ``。
        标识符保护：snake_case_variable_name 不应斜体，而 _独立斜体_ 生效。
        复合样式：***粗斜体***、~~删除线~~、==高亮文本==、[带括号链接](https://en.wikipedia.org/wiki/Markdown_(markup))。

        | 语法 | 状态 |
        | :--- | ---: |
        | **加粗** | 正常 |
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("suite-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try fullDoc.write(to: tempURL, atomically: true, encoding: .utf8)

        let editor = EditorState()
        XCTAssertTrue(editor.load(tempURL))

        let storage = MarkdownStyler.styledStorage(for: editor.text, config: wysiwygConfig)
        let ns = storage.string as NSString

        // 1. 无序列表 `* ` 不误吞行内 `*中文斜体*`
        let cnItalicRange = ns.range(of: "中文斜体")
        XCTAssertEqual((storage.attribute(.obliqueness, at: cnItalicRange.location, effectiveRange: nil) as? CGFloat) ?? 0, 0.16, accuracy: 0.01)

        let enItalicRange = ns.range(of: "English Italic")
        let enFont = storage.attribute(.font, at: enItalicRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(enFont!.fontDescriptor.symbolicTraits.contains(.italic))

        // 2. 两段行内代码之间的「 乘以 」绝不被跨区间误判为斜体
        let betweenCode = ns.range(of: "乘以")
        XCTAssertNil(storage.attribute(.obliqueness, at: betweenCode.location, effectiveRange: nil))
        let insideCodeBold = ns.range(of: "不加粗")
        let insideCodeFont = storage.attribute(.font, at: insideCodeBold.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(MarkdownStyler.isBoldFont(insideCodeFont!))

        // 3. snake_case 不误触发斜体
        let snakeRange = ns.range(of: "case")
        let snakeFont = storage.attribute(.font, at: snakeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(snakeFont!.fontDescriptor.symbolicTraits.contains(.italic))

        // 4. 粗斜体、删除线、高亮、带括号 URL 链接、已完成待办删除线
        let boldItalicRange = ns.range(of: "粗斜体")
        let biFont = storage.attribute(.font, at: boldItalicRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(MarkdownStyler.isBoldFont(biFont!))
        XCTAssertEqual((storage.attribute(.obliqueness, at: boldItalicRange.location, effectiveRange: nil) as? CGFloat) ?? 0, 0.16, accuracy: 0.01)

        let strikeRange = ns.range(of: "删除线")
        XCTAssertEqual(storage.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)

        let highlightRange = ns.range(of: "高亮文本")
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: highlightRange.location, effectiveRange: nil))

        let linkLabelRange = ns.range(of: "带括号链接")
        XCTAssertEqual(storage.attribute(.underlineStyle, at: linkLabelRange.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        let wikiClosingParen = ns.range(of: "(markup)")
        XCTAssertEqual(storage.attribute(.benHiddenSyntax, at: wikiClosingParen.location, effectiveRange: nil) as? Bool, true)

        let checkedTodoRange = ns.range(of: "已完成任务")
        XCTAssertEqual(storage.attribute(.strikethroughStyle, at: checkedTodoRange.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)

        // 5. 保存回 `.md` 原文 100% 无损
        XCTAssertTrue(editor.save())
        let diskAfterSave = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertEqual(diskAfterSave, fullDoc)
    }

    // MARK: - 9. 图片语法（含空 alt `![](...)`、带空格路径、WikiLink `![[...]]`、本地真实图片加载与缺失占位）

    func testMarkdownAndWikiLinkImageSyntaxRendering() throws {
        let vaultDir = FileManager.default.temporaryDirectory.appendingPathComponent("img-vault-\(UUID().uuidString)")
        let assetsDir = vaultDir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultDir) }

        // 生成一张真实 240x120 PNG 测试图片写入 `assets/CleanShot 2026 (1).png` 与 `assets/chart.png`
        let image = NSImage(size: NSSize(width: 240, height: 120), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let spacedImgURL = assetsDir.appendingPathComponent("CleanShot 2026 (1).png")
        let chartImgURL = assetsDir.appendingPathComponent("chart.png")
        try pngData.write(to: spacedImgURL)
        try pngData.write(to: chartImgURL)

        let noteURL = vaultDir.appendingPathComponent("test-note.md")
        let markdown = """
        ![](assets/chart.png)
        ![架构示意图](assets/CleanShot 2026 (1).png "系统图")
        ![[chart.png|180]]
        ![缺失图](assets/not_exist.png)
        [普通链接](https://example.com)
        """

        let config = MarkdownStyler.StyleConfig(
            mode: .wysiwyg,
            proseFontName: "System",
            codeFontName: "SFMono-Regular",
            fontSize: 15,
            lineSpacing: 5,
            noteURL: noteURL,
            vaultURL: vaultDir
        )

        let storage = MarkdownStyler.styledStorage(for: markdown, config: config)
        let ns = storage.string as NSString

        // 1. 空 alt `![](assets/chart.png)` 必须成功识别并加载真实图片，且非激活态隐藏源码字符
        let line1Range = ns.range(of: "![](assets/chart.png)")
        let spec1 = try XCTUnwrap(storage.attribute(.benImageAttachment, at: line1Range.location, effectiveRange: nil) as? BenImageLayoutSpec)
        XCTAssertTrue(spec1.isStandaloneLine)
        XCTAssertEqual(spec1.items.count, 1)
        if case let .loaded(_, size) = spec1.items[0].state {
            XCTAssertEqual(size.width, 240)
            XCTAssertEqual(size.height, 120)
        } else {
            XCTFail("空 alt 本地图片应成功加载")
        }
        XCTAssertEqual(storage.attribute(.benHiddenSyntax, at: line1Range.location, effectiveRange: nil) as? Bool, true)

        // 2. 含空格与括号路径 + title 属性 `![架构示意图](assets/CleanShot 2026 (1).png "系统图")`
        let line2Range = ns.range(of: "![架构示意图](assets/CleanShot 2026 (1).png \"系统图\")")
        let spec2 = try XCTUnwrap(storage.attribute(.benImageAttachment, at: line2Range.location, effectiveRange: nil) as? BenImageLayoutSpec)
        XCTAssertEqual(spec2.items.first?.alt, "架构示意图")
        XCTAssertEqual(spec2.items.first?.title, "系统图")
        if case .loaded = spec2.items.first?.state {} else {
            XCTFail("含空格与括号的本地图片路径应成功解析加载")
        }

        // 3. Obsidian WikiLink `![[chart.png|180]]` 自动在本子 assets 目录定位图片并识别宽度参数 180
        let line3Range = ns.range(of: "![[chart.png|180]]")
        let spec3 = try XCTUnwrap(storage.attribute(.benImageAttachment, at: line3Range.location, effectiveRange: nil) as? BenImageLayoutSpec)
        XCTAssertEqual(spec3.items.first?.preferredMaxWidth, 180)
        if case .loaded = spec3.items.first?.state {} else {
            XCTFail("WikiLink 图片应自动从 assets 子目录加载成功")
        }

        // 4. 缺失图片生成 `.missing` 占位卡片规格
        let line4Range = ns.range(of: "![缺失图](assets/not_exist.png)")
        let spec4 = try XCTUnwrap(storage.attribute(.benImageAttachment, at: line4Range.location, effectiveRange: nil) as? BenImageLayoutSpec)
        XCTAssertEqual(spec4.items.first?.state, .missing)

        // 5. 普通链接绝不挂载 `.benImageAttachment`
        let linkRange = ns.range(of: "[普通链接](https://example.com)")
        XCTAssertNil(storage.attribute(.benImageAttachment, at: linkRange.location, effectiveRange: nil))
    }

    // MARK: - 10. 属性栏引号剥离与链接识别、剪藏笔记跳过图片摘要、有序列表序号低饱和中灰配色

    func testClippedNoteSummaryFrontmatterQuotesAndMutedListMarker() throws {
        let clipped = """
        ---
        title: "AI 剪藏文章标题"
        source: "https://example.com/articles/123"
        ---

        ![Cover](https://cdn.example.com/cover_(hero).jpg)

        [![Image](https://cdn.example.com/badge.png)](https://example.com)

        ![[banner.webp]]

        这是剪藏文章真正的第一段核心摘要内容。
        """

        // 1. 验证 Frontmatter 展示值自动去除首尾双引号，且 `http`/`https` 识别为可点击 URL
        let parsed = FrontmatterParser.parse(clipped)
        let fm = try XCTUnwrap(parsed.frontmatter)
        let titleField = try XCTUnwrap(fm.fields.first(where: { $0.key == "title" }))
        let sourceField = try XCTUnwrap(fm.fields.first(where: { $0.key == "source" }))
        XCTAssertEqual(titleField.displayValue, "AI 剪藏文章标题")
        XCTAssertNil(titleField.webURL)
        XCTAssertEqual(sourceField.displayValue, "https://example.com/articles/123")
        XCTAssertEqual(sourceField.webURL?.absoluteString, "https://example.com/articles/123")

        // 2. 验证笔记列表摘要提取自动跳过 `![Cover](...)`、`![Image](...)`、`![[...]]`，提取真实首段正文
        let summary = VaultStore.extractPreviewSummary(from: clipped)
        XCTAssertEqual(summary, "这是剪藏文章真正的第一段核心摘要内容。")

        // 3. 验证有序列表序号 `1. ` 在所见即所得模式下使用低饱和中灰 `#6E6E73` 而非系统蓝色
        let listStorage = MarkdownStyler.styledStorage(for: "1. 第一项\n2. 第二项", config: wysiwygConfig)
        let markerColor = listStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(markerColor, MarkdownStyler.listMarkerMutedGray)
    }
}
