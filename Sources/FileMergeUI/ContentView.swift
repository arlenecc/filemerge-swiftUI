import AppKit
import FileMergeCore
import SwiftUI

/// 根布局：配置区占上方 1/3，处理过程区占下方 2/3，均横向撑满
public struct ContentView: View {
    @EnvironmentObject private var vm: AppViewModel

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ConfigSectionView()
                    .frame(width: geometry.size.width, height: geometry.size.height / 3, alignment: .top)
                Divider()
                ProcessSectionView()
                    .frame(width: geometry.size.width, height: geometry.size.height * 2 / 3 - 1, alignment: .top)
            }
        }
    }
}

// MARK: - 配置区（上 1/3）

struct ConfigSectionView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("目录配置").font(.headline)
                Spacer()
                Text("去重规则：主、副目录全部子目录间按文件哈希全局排重，内容一致的文件只保留一份")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DirectoryField(
                title: "主目录",
                placeholder: "合并时以此目录的目录结构为准",
                url: vm.mainDir,
                isEnabled: !vm.busy
            ) {
                Task {
                    if let url = await DirectoryPicker.pickDirectory() {
                        vm.setMainDir(url)
                    }
                }
            }

            DirectoryField(
                title: "副目录",
                placeholder: "与主目录一起参与全局排重",
                url: vm.secondaryDir,
                isEnabled: !vm.busy
            ) {
                Task {
                    if let url = await DirectoryPicker.pickDirectory() {
                        vm.setSecondaryDir(url)
                    }
                }
            }

            DirectoryField(
                title: "最终目录",
                placeholder: "排重后的唯一文件将写入该目录",
                url: vm.destinationDir,
                isEnabled: !vm.busy
            ) {
                Task {
                    if let url = await DirectoryPicker.pickDirectory() {
                        vm.setDestinationDir(url)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    vm.beginAnalysis()
                } label: {
                    Label("开始分析", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canStartAnalysis)

                if vm.busy {
                    Button(role: .destructive) {
                        vm.cancel()
                    } label: {
                        Label("取消", systemImage: "stop.fill")
                    }
                }

                Spacer()

                if case .failed(let message) = vm.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
    }
}

struct DirectoryField: View {
    let title: String
    let placeholder: String
    let url: URL?
    let isEnabled: Bool
    let onPick: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 64, alignment: .leading)
                .font(.callout)

            Group {
                if let path = url?.path {
                    Text(path)
                        .foregroundStyle(.primary)
                } else {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            Button("选择…", action: onPick)
                .disabled(!isEnabled)
        }
    }
}

// MARK: - 处理过程区（下 2/3）

struct ProcessSectionView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            StatsBarView()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            LogView()
            Divider()
            StatusBarView()
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }
}

/// 统计条：主/副目录统计 + 预估结果（排重结果更新在开始合并按钮左侧）
struct StatsBarView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            StatBlock(
                title: "主目录",
                count: vm.mainStats?.fileCount,
                size: vm.mainStats?.totalSize
            )
            Divider().frame(height: 40)
            StatBlock(
                title: "副目录",
                count: vm.secondaryStats?.fileCount,
                size: vm.secondaryStats?.totalSize
            )
            Divider().frame(height: 40)
            StatBlock(
                title: "预计合并后",
                count: vm.estimate?.fileCount,
                size: vm.estimate?.totalSize,
                note: dedupNote,
                highlight: true
            )
            .frame(minWidth: 150)

            Spacer()

            Button {
                vm.beginMerge()
            } label: {
                Label("开始合并", systemImage: "arrow.down.doc.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!vm.canStartMerge)
        }
    }

    private var dedupNote: String? {
        guard let duplicates = vm.estimate?.duplicates, duplicates > 0,
              let saved = vm.estimate?.savedBytes, saved > 0 else { return nil }
        return "去除重复 \(Formatters.count(duplicates)) 个，节省 \(Formatters.bytes(saved))"
    }
}

struct StatBlock: View {
    let title: String
    let count: Int?
    let size: UInt64?
    var note: String?
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(highlight ? Color.accentColor : Color.secondary)
            if let count, let size {
                Text("\(Formatters.count(count)) 个文件")
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                Text(Formatters.bytes(size))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("待分析")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("—")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 日志区

struct LogView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if vm.logEntries.isEmpty {
                        Text("处理过程日志将显示在这里")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        ForEach(vm.logEntries) { entry in
                            Text(entry.text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: vm.logEntries.last?.id) { lastID in
                guard let lastID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - 状态栏

struct StatusBarView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let value = vm.progressValue {
                    ProgressView(value: value)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 240)

            Text(vm.progressText)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if vm.phase == .merged, let dir = vm.destinationDir {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
            }

            Text(vm.phaseLabel)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
