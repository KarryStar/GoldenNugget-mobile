import SwiftUI
import Minimuxer

/// Settings: what this build is, and the switches that change what a run does.
///
/// A plain `Form` in the system's grouped style.  The platform draws the
/// surface, the section headers, the row insets, the disclosure chrome and the
/// Liquid Glass; every colour and font here is semantic, so light and dark and
/// the user's text size all work without a palette of our own.
///
/// The About half is what a bug report actually needs — version, build, and the
/// two log files with their sizes.  The Apply half is the one switch that is not
/// a development switch: Skip Setup.  The Development half sits behind a master
/// switch because every row on it changes a real device.
struct SettingsView: View {
    // Reactive mirrors of `DevSettings.Key`, so a toggle redraws the page. The
    // engine reads the same strings through `DevSettings.effective`.
    @AppStorage(DevSettings.Key.enabled) private var devModeOn = false
    @AppStorage(DevSettings.Key.forcePartialRestore) private var forcePartialRestore = false
    @AppStorage(DevSettings.Key.verboseLog) private var verboseLog = true
    @AppStorage(DevSettings.Key.skipAfcMedia) private var skipAfcMedia = false

    /// Skip Setup's switch. Observed rather than mirrored with a second
    /// `@AppStorage` on the same key: the store is what the engine reads.
    @ObservedObject private var skipSetup = SkipSetupSettings.shared

    /// Read through `engine` rather than recomputed in the body, because a log is
    /// written by another thread while this page is open.
    @State private var logs = LogSizes()

    /// The setup guide, as a full-screen cover.
    ///
    /// It is the same view the app opens with on a first launch, on purpose: a
    /// second "getting started" page would be a second set of instructions to fall
    /// out of step with the first, and the whole reason this row exists is that a
    /// user who skipped the gate still needs it. A `NavigationLink` would have no
    /// place to return to after "Finish setup", which on an already-set-up app
    /// changes nothing the user can see.
    @State private var showSetupGuide = false

    /// Sizes and existence of the two files a report is built from.
    private struct LogSizes: Equatable {
        var appBytes: UInt64 = 0
        var rustBytes: UInt64 = 0
        var rustStatus: String = ""

        var appKB: UInt64 { appBytes / 1024 }
        var rustKB: UInt64 { rustBytes / 1024 }
        var hasApp: Bool { appBytes > 0 }
        var hasRust: Bool { rustBytes > 0 }
    }

    var body: some View {
        Form {
            aboutSection
            creditsSection
            setupSection
            logsSection
            applySection
            developmentSection
        }
        .navigationTitle("设置")
        // Compact widths only -- on a tablet the split view draws its own sidebar
        // toggle, and a second button beside it is the duplicate-controls mess.
        .goldenSidebarButton()
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showSetupGuide) {
            NavigationStack {
                FirstRunView { showSetupGuide = false }
            }
        }
        .task {
            refreshLogs()
        }
        .onChange(of: devModeOn) { _, _ in DevSettings.applyLoggingPreference() }
        .onChange(of: verboseLog) { _, _ in DevSettings.applyLoggingPreference() }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("关于") {
            VStack(spacing: 12) {
                NativeLogo(size: 88)
                Text("GoldenNugget")
                    .font(.title2.bold())
                Text(Self.versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)

            // A credit, not a setting: centred and on its own, so it does not
            // read as a row.
            Text("由 ❤️ 打造\nGoldenNugget 开发团队")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)

            NativeNote("GoldenNugget 桌面版是本应用移植自的原作。它以自己的 Rust 和 Swift 技术栈运行相同的协议，而不是驱动 pymobiledevice3，并且同时支持 iOS 26 和 27，而不只是有线连接的设备。")
        }
    }

    // MARK: - Credits

    /// What the app is built on, and by whom. Every row is a component that is
    /// really in the binary — the two static Rust/C archives are linked into the
    /// executable rather than embedded as frameworks (only `EMProxy.framework`
    /// ships as a dynamic framework in the IPA).
    private var creditsSection: some View {
        Section("致谢") {
            creditRow("GoldenNugget", "桌面版应用 · 本应用移植自它",
                      systemImage: "desktopcomputer")
            creditRow("idevice", "Rust 设备与备份栈",
                      systemImage: "shippingbox")
            creditRow("libimobiledevice", "C 协议核心",
                      systemImage: "chevron.left.forwardslash.chevron.right")
            creditRow("Minimuxer", "SideStore · 隧道与 usbmux",
                      systemImage: "network")
            creditRow("ZIPFoundation", "压缩包处理",
                      systemImage: "archivebox")
            NativeNote("内置的副本带有本地补丁，每项补丁及其原因都列在 Vendor/patches/README.md。SideStore 的 minimuxer 版权所有 © 2026 SideStore。")
        }
    }

    private func creditRow(_ title: String, _ role: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 12)
            Text(role)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Setup

    /// The guide, reachable after the fact.
    ///
    /// Its own section rather than a row under Apply: those rows are switches a run
    /// reads, and this one changes nothing about a run — it opens a screen. It
    /// also sits above them, because it is the answer to "why is nothing
    /// connecting", which is the question a user opens Settings with.
    private var setupSection: some View {
        Section("设置引导") {
            Button {
                showSetupGuide = true
            } label: {
                Label("设置引导", systemImage: "list.number")
            }
            NativeNote("检查本应用连接设备前需要的两件事 —— LocalDevVPN 隧道和一份配对记录 —— 并逐项引导完成。首次启动时打开的就是这份引导。")
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        Section("日志") {
            // The two halves of a report's evidence: this one is what the host
            // decided, the other is what the protocol did.
            shareRow(title: "goldennugget.log",
                     size: logs.appKB,
                     systemImage: "doc.plaintext",
                     url: GoldenNuggetEngine.appLogURL,
                     available: logs.hasApp)
            shareRow(title: "minimuxer.log",
                     size: logs.rustKB,
                     systemImage: "doc.text.magnifyingglass",
                     url: GoldenNuggetEngine.rustLogURL,
                     available: logs.hasRust)
            if !logs.hasRust, !logs.rustStatus.isEmpty {
                NativeNote(logs.rustStatus)
            }
            NativeNote(logs.hasApp
                ? "提交问题需要两个文件：应用日志记录了主机决定了什么，minimuxer.log 记录了设备应答了什么。"
                : "还没有应用日志 —— 它从本次会话的第一次运行开始写入。")
        }
    }

    private func shareRow(title: String, size: UInt64, systemImage: String,
                          url: URL, available: Bool) -> some View {
        ShareLink(item: url) {
            HStack(spacing: 12) {
                Label("\(title)（\(size) KB）", systemImage: systemImage)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(available ? Color.primary : Color.secondary)
    }

    // MARK: - Apply

    /// Skip Setup, on its own page rather than behind the Development master: it is
    /// not a switch for working around a bug, it is part of what a run writes.
    private var applySection: some View {
        Section("应用") {
            switchRow("跳过设置",
                      note: skipSetupNote,
                      isOn: Binding(
                          get: { skipSetup.skipSetupEnabled },
                          set: { skipSetup.setSkipSetup($0) }))
        }
    }

    /// What the switch does, in the order the two files are written.
    private var skipSetupNote: String {
        [
            "默认开启，与上游一致。关闭：应用只携带调整。",
            "开启：应用会在调整之前额外写入两个文件，顺序如下 ——",
            "1. SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/CloudConfigurationDetails.plist，标记 \(SkipSetup.panes.count) 个设置面板为跳过；",
            "2. ManagedPreferencesDomain/mobile/com.apple.purplebuddy.plist，标记设置已完成。",
            "设备已有的云端配置不会被合并进来（读取它需要一个本移植没有通道的 lockdown 服务），也不会生成 keybag 证书。",
        ].joined(separator: "\n")
    }

    // MARK: - Development

    private var developmentSection: some View {
        Section("开发") {
            Toggle(isOn: $devModeOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开发模式")
                    NativeNote(devModeOn
                        ? "下方这些开关在下次运行时生效。"
                        : "关闭：运行走正常路径。已存储的开关被忽略。")
                }
            }

            if devModeOn {
                switchRow("强制部分恢复",
                          note: "走 iOS 26 分支 —— 从零构建的部分恢复（Partial Restore）—— 即使设备报告为 iOS 27+，并且完全跳过保护性备份。",
                          isOn: $forcePartialRestore)

                switchRow("详细日志",
                          note: verboseLog
                            ? "把协议细节记录进 minimuxer.log。关闭时保留应用日志和运行本身，丢弃逐帧的行。"
                            : "未在记录协议细节。应用日志仍在记录。",
                          isOn: $verboseLog)

                switchRow("跳过 AFC 媒体",
                          note: "运行通常会在备份与清理之间复制相册媒体。开启后跳过它 —— 相册满的时候，这就是几分钟与几秒的差别。",
                          isOn: $skipAfcMedia)

                Button("重置开关", systemImage: "arrow.counterclockwise") {
                    DevSettings.resetSwitches()
                    DevSettings.applyLoggingPreference()
                }

                NativeSafetyNote("这些是排障开关，不是修复。对真实的 iOS 27 设备使用“强制部分恢复”，预期会在恢复步骤失败，因为合成出来的 manifest 不携带域注册。")
            }
        }
    }

    // MARK: - Rows

    /// A labelled switch with the explanation underneath it.
    private func switchRow(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                NativeNote(note)
            }
        }
    }

    private func refreshLogs() {
        logs = LogSizes(appBytes: GoldenNuggetEngine.appLogSize(),
                        rustBytes: GoldenNuggetEngine.rustLogSize(),
                        rustStatus: GoldenNuggetEngine.rustLogStatus())
    }

    // MARK: - Bundle facts

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "未知"
    }

    private static var versionText: String {
        "\(info("CFBundleShortVersionString"))（\(info("CFBundleVersion"))）"
    }
}
