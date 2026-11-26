import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("proseFontName") private var proseFontName = "System"
    @AppStorage("editorFontName") private var codeFontName = "SFMono-Regular"
    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("editorLineSpacing") private var lineSpacing = 5.0
    @AppStorage("comfortableLineWidth") private var comfortableLineWidth = true
    @AppStorage("hideMarkdownExtension") private var hideMarkdownExtension = true

    private struct FontOption: Identifiable {
        let id: String
        let title: String
    }

    private var availableProseFonts: [FontOption] {
        var options: [FontOption] = [
            FontOption(id: "System", title: "系统无衬线（苹方 / SF Pro）"),
            FontOption(id: "SystemSerif", title: "系统衬线（New York）")
        ]
        let candidates: [(String, String)] = [
            ("Songti SC", "宋体-简（Songti SC）"),
            ("Kaiti SC", "楷体-简（Kaiti SC）"),
            ("LXGWWenKai-Regular", "霞鹜文楷（LXGW WenKai）"),
            ("Georgia", "Georgia")
        ]
        for (psName, label) in candidates where NSFont(name: psName, size: 14) != nil {
            options.append(FontOption(id: psName, title: label))
        }
        return options
    }

    private var availableCodeFonts: [FontOption] {
        let candidates: [(String, String)] = [
            ("SFMono-Regular", "SF Mono"),
            ("Menlo-Regular", "Menlo"),
            ("Monaco", "Monaco"),
            ("JetBrainsMono-Regular", "JetBrains Mono"),
            ("FiraCode-Regular", "Fira Code")
        ]
        var options = candidates.compactMap { psName, label in
            NSFont(name: psName, size: 14) != nil ? FontOption(id: psName, title: label) : nil
        }
        if options.isEmpty {
            options.append(FontOption(id: "Menlo-Regular", title: "Menlo"))
        }
        return options
    }

    var body: some View {
        Form {
            Section("外观与显示") {
                Picker("主题模式", selection: $appearance) {
                    Text("跟随系统").tag(0)
                    Text("浅色").tag(1)
                    Text("深色").tag(2)
                }
                .pickerStyle(.segmented)

                Toggle("居中舒适阅读行宽（740 pt）", isOn: $comfortableLineWidth)
                Toggle("在列表中隐藏 .md 扩展名", isOn: $hideMarkdownExtension)
            }

            Section("排版与字体（实时生效）") {
                Picker("正文字体（所见即所得）", selection: $proseFontName) {
                    ForEach(availableProseFonts) { item in
                        Text(item.title).tag(item.id)
                    }
                }

                Picker("等宽字体（源码与代码块）", selection: $codeFontName) {
                    ForEach(availableCodeFonts) { item in
                        Text(item.title).tag(item.id)
                    }
                }

                LabeledContent("正文字号") {
                    HStack(spacing: 10) {
                        Slider(value: $fontSize, in: 12...24, step: 1)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                LabeledContent("段落行距") {
                    HStack(spacing: 10) {
                        Slider(value: $lineSpacing, in: 2...12, step: 1)
                        Text("\(Int(lineSpacing)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            Section {
                Text("所有笔记均以 UTF-8 纯 .md 文件存放在本地文件夹中，无私有数据库锁定，可随时与 Git、VS Code、Obsidian 协同。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
    }
}
