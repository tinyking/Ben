import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 88, height: 88)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                }

                Text("Ben（本）")
                    .font(.largeTitle.bold())

                Text("安静、轻快的本地 Markdown 笔记本")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button {
                app.openVault()
            } label: {
                Label("选择或新建文件夹作为本子…", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if !app.recentVaultURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近打开的本子")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 2) {
                        ForEach(app.recentVaultURLs, id: \.path) { url in
                            Button {
                                app.openRecentVault(url)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "books.vertical")
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(url.lastPathComponent)
                                            .font(.callout.weight(.medium))
                                        Text(abbreviatedPath(url.path))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 340)
                .padding(.top, 4)
            }

            Text("所有笔记均以纯 .md 文件保存在本地文件夹中，\n可随时使用 Git、VS Code 或 Obsidian 打开。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
