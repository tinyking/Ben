import SwiftUI
import AppKit

/// 嵌入在正文滚动区顶部的轻量可折叠 Frontmatter 属性栏：
/// - 随正文一同自然滚动，不挤占顶部吸顶空间；
/// - 展示与编辑时自动剥离首尾 YAML 引号；
/// - `http` / `https` 属性支持一键用默认浏览器打开。
struct FrontmatterBarView: View {
    var app: AppState

    var body: some View {
        if let frontmatter = app.editor.frontmatter {
            VStack(alignment: .leading, spacing: 0) {
                compactHeaderRow(frontmatter: frontmatter)

                if app.editor.isFrontmatterExpanded {
                    expandedEditor(frontmatter: frontmatter)
                }
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(height: 1)
            }
            .environment(\.colorScheme, .light)
        }
    }

    private func compactHeaderRow(frontmatter: FrontmatterDocument) -> some View {
        HStack(spacing: 8) {
            Button {
                app.editor.isFrontmatterExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: app.editor.isFrontmatterExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 9)

                    Text("属性")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !app.editor.isFrontmatterExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(frontmatter.fields.prefix(6)) { field in
                            propertyChip(field)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            if app.editor.isFrontmatterExpanded {
                Button {
                    app.editor.addFrontmatterField()
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func propertyChip(_ field: FrontmatterField) -> some View {
        let clean = field.displayValue
        if let url = field.webURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 3.5) {
                    Text(field.key)
                        .foregroundStyle(.tertiary)
                    Text(Self.compactURLDisplay(url, fallback: clean))
                        .foregroundStyle(Color(red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0))
                        .underline(color: Color.black.opacity(0.22))
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.black.opacity(0.035), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("在浏览器中打开：\(clean)")
        } else {
            Button {
                app.editor.isFrontmatterExpanded = true
            } label: {
                HStack(spacing: 3.5) {
                    Text(field.key)
                        .foregroundStyle(.tertiary)
                    if !clean.isEmpty {
                        Text(clean)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 180, alignment: .leading)
                    }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.black.opacity(0.03), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func expandedEditor(frontmatter: FrontmatterDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if frontmatter.fields.isEmpty {
                Text("暂无属性，点击右上角「添加」新增。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            } else {
                ForEach(frontmatter.fields) { field in
                    HStack(spacing: 8) {
                        TextField(
                            "键名",
                            text: Binding(
                                get: { field.key },
                                set: { app.editor.updateFrontmatterField(id: field.id, key: $0, value: field.value) }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                        .padding(.vertical, 3)

                        TextField(
                            "属性值",
                            text: Binding(
                                get: { field.displayValue },
                                set: { app.editor.updateFrontmatterField(id: field.id, key: field.key, value: $0) }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 4))

                        if let url = field.webURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("在浏览器中打开：\(field.displayValue)")
                        }

                        Button {
                            app.editor.removeFrontmatterField(id: field.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("删除此属性")
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private static func compactURLDisplay(_ url: URL, fallback: String) -> String {
        guard let host = url.host, !host.isEmpty else { return fallback }
        let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path
        if path.isEmpty || path == "/" {
            return cleanHost
        }
        let truncatedPath = path.count > 18 ? String(path.prefix(18)) + "…" : path
        return cleanHost + truncatedPath
    }
}
