import SwiftUI
import UniformTypeIdentifiers

/// The PosterBoard page: wallpaper packs, a video wallpaper, and the resets.
///
/// The reference's own page has three tabs — Tendies, Templates, Video — plus a
/// reset dialog.  Templates is not here, and its absence is deliberate: a
/// `.template` is a different file format with its own options engine
/// (`template_file.py` + `template_options/`), and upstream itself lists
/// Templates and PosterBoard as two separate un-ported features.  What *is* here
/// covers everything the other two tabs do, including the video method the reset
/// dialog exists to recover from.
///
/// Three things this page says that the reference does not, all of them because
/// this port has to be honest about what has run on a device:
///
///   * **The database card.** A wallpaper is a descriptor directory *plus* three
///     rows in the store's own sqlite, and the database cannot be synthesised —
///     it has to be fetched from the device.  The card says when that happened
///     last, and the fetch is also the first stage of an apply that needs one.
///     It is hidden on AirLift, which has no such stage: that mode writes the
///     descriptors into the container and never touches the rows.
///   * **The unsafe-container warning** is shown on the pack row rather than in
///     a modal that appears on import: it is a property of the pack, and it stays
///     true for as long as the pack is listed.
///   * **The reset section states what it does not undo.** A reset makes the
///     fetched database stale, so the next apply fetches a fresh one; saying so
///     here is cheaper than the puzzle of a store that half-works.
struct PosterBoardView: View {
    /// Everything this page edits, **owned by `RootView`**: the page picks the
    /// wallpapers and the home page's single `Apply` delivers them, so the selection has
    /// to outlive this view — which a `NavigationSplitView` destroys on every sidebar
    /// selection.  The old `@AppStorage` options moved in here for the same reason: two
    /// sources of truth for "was Loop on" is one too many when the second one is the one
    /// that applies.
    @Binding var selection: PosterBoardSelection

    @State private var identity: DeviceIdentity = .unknown
    @State private var databaseSummary = "尚未检查"
    @State private var pickError: String?
    /// Only the database fetch runs from this page — the apply is the home page's.
    @State private var status: String?
    @State private var statusTone: GoldenTone = .secondary
    @State private var running = false
    @State private var runStarted: Date?

    @State private var showPackImporter = false
    @State private var showVideoImporter = false
    @State private var showThumbnailImporter = false

    /// The apply mode, seeded from the setting and written back on change.
    ///
    /// `@AppStorage` would have been the shorter version, and the reason it is not
    /// used is that the mode has to be validated against the device on this page —
    /// AirLift needs iOS 26.2 and a pairing record, and a picker that can hold a mode
    /// the page will later refuse is a worse thing to show than one that cannot be
    /// set here.
    @State private var applyMode: PosterBoardApplyMode = .airlift

    /// The imported pack awaiting a Convert / Install-as-is answer, if any. See
    /// `LegacyConvertPromptModifier` for why the question is a value rather than
    /// an immediate call.
    @State private var legacyPrompt: LegacyConvertPrompt?

    var body: some View {
        List {
            deviceSection
            applyModeSection
            // AirLift writes the descriptors into the container and never looks
            // at the store's sqlite, so on that mode the whole card is about a
            // stage the run will not perform. Leaving it up would be offering a
            // fetch that the apply below ignores.
            if applyMode != .airlift { databaseSection }
            packsSection
            videoSection
            resetSection
            if applyMode == .airlift { airliftApplySection }
            applySection
            if let pickError { errorSection(pickError) }
            if !statusText.isEmpty {
                Section {
                    Text(statusText)
                        .foregroundStyle(statusTone.nativeColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            RunLogCard()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PosterBoard")
        .navigationBarTitleDisplayMode(.inline)
        // Loading the pack list and the database state is a directory walk and a
        // file stat, so it happens here and not in `body`. `loadFromDisk` is idempotent
        // and does not touch the options: `RootView` already ran it at launch, and this
        // pass is what picks up a pack imported from somewhere else meanwhile.
        .task {
            // The device line is read here and not in `body`, like every other page: it is
            // a lockdown call.  It used to be declared and never set, so the card said
            // "unknown device" for the whole life of this page.
            identity = await DeviceIdentity.read()
            selection.loadFromDisk()
            applyMode = PosterBoardApplyModeSettings.current
            refreshDatabaseSummary()
        }
        .legacyConvertPrompt($legacyPrompt, answer: answerLegacyPrompt)
    }

    // MARK: - The legacy-format answer

    /// Store the Convert / Install-as-is answer and reload the selection, which is
    /// what puts the new answer on the pack the apply reads.
    ///
    /// The reference assigns `auto_convert` on the tendie it just created; the pack
    /// list here is re-read from disk, so the answer goes to
    /// `PosterBoardPreferences.autoConvertAnswers` through
    /// `settingAutoConvert` and the list is rebuilt from it.
    private func answerLegacyPrompt(_ prompt: LegacyConvertPrompt, _ convert: Bool) {
        legacyPrompt = nil
        // `settingAutoConvert` writes the answer straight through, which is what
        // matters here: the pack in the selection is a value read from the archive,
        // and the apply re-reads it too.
        _ = prompt.pack.settingAutoConvert(convert)
        RunLog.shared.append(convert
            ? "PosterBoard：\(prompt.pack.name) 将在应用时转换为现代格式（旧版：\(prompt.families.joined(separator: "、")))。"
            : "PosterBoard：\(prompt.pack.name) 保持其原始旧版格式（\(prompt.families.joined(separator: "、")))。")
        selection.loadFromDisk()
    }

    // MARK: - Device and database

    private var deviceSection: some View {
        Section {
            Text(identity.describe)
                .font(.headline)
            NativeNote("墙纸以文件形式交付到本应用自己对设备的备份中，位于 \(PosterBoard.domain) 域 —— 与调整使用的通道相同。在点按“应用”之前，不会向设备写入任何内容。")
        }
    }

    // MARK: - Apply mode

    /// The two ways a selection can reach the device, as a segmented choice.
    ///
    /// A `Picker` rather than a switch: this is a choice between two mechanisms
    /// with different costs, and a switch cannot show what the other option is.
    /// The consequence of picking AirLift is spelled out under it, because
    /// "AirLift" alone says nothing about the version floor or the reboot it
    /// saves.
    private var applyModeSection: some View {
        Section {
            Picker("应用方式", selection: $applyMode) {
                ForEach(PosterBoardApplyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .onChange(of: applyMode) { _, mode in
                PosterBoardApplyModeSettings.current = mode
            }
            NativeNote(applyMode.summary)
            if applyMode == .airlift, !airliftBlocker.isEmpty {
                NativeSafetyNote(airliftBlocker)
            }
            if applyMode == .airlift {
                NativeNote("此模式不涉及存储库数据库，因此其卡片被隐藏：注入会把描述器直接写入容器，不会触碰数据库行。自动刷新同样被忽略。")
            }
            if !selection.resetModes.isEmpty, !applyMode.supportsReset {
                NativeSafetyNote("你选择的重置无法通过 AirLift 完成。请切换回“保护性备份”以保留它。")
            }
        }
    }

    /// Why AirLift is not usable right now, in the page's own words.
    ///
    /// The same check `GoldenNuggetEngine` makes before it starts a run, stated
    /// here so the picker cannot be set to something the apply will refuse.
    private var airliftBlocker: String {
        let reason = Airlift.unsupportedReason(deviceVersion: identity.version)
        if !reason.isEmpty { return reason }
        if !FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) {
            return "AirLift 需要配对记录，而当前没有存储。请在主页导入一份。"
        }
        return ""
    }

    private var databaseSection: some View {
        Section("存储库数据库") {
            Toggle("自动刷新", isOn: $selection.autoRefresh)
            Button {
                fetchDatabase()
            } label: {
                HStack {
                    Label("从设备取回数据库", systemImage: "arrow.down.circle")
                    Spacer()
                    if running { ProgressView().controlSize(.small) }
                }
            }
            .disabled(running)
            NativeNote(databaseNote)
        }
    }

    private var databaseNote: String {
        var lines = [
            "已取回数据库：\(databaseSummary)",
            "一张墙纸同时存在于两个地方 —— 它的描述器文件，以及存储库 sqlite 中的三行记录。这些行承载设备的 provider 注册信息和选择器排序所用的元数据，因此无法凭空编造：应用会先从设备取回存储库，再向它的副本中添加行。",
        ]
        if selection.autoRefresh {
            lines.append("自动刷新已开启（上游默认）：每次应用还会写入 PBF_RESET_FILE_PROTECTIONS，这正是让 PosterBoard 在开机时重新读取存储库的开关。关闭它可以让设备偏好保持原样。")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Packs

    private var packsSection: some View {
        Section("墙纸包（\(selection.tendies.count)）") {
            // The desktop build opens the wallpaper downloader from right here
            // (`wallpaper_downloader.py`, reached from this page's own button),
            // and the entry point stayed here when the sidebar row was dropped:
            // the downloader edits this section's own selection, so the row in the
            // packs list is the one place a reader is looking for it.
            NavigationLink(value: AppDestination.wallpaperDownloads) {
                Label("下载墙纸", systemImage: "square.and.arrow.down")
            }
            .disabled(running)
            Button {
                showPackImporter = true
            } label: {
                Label("导入 .tendies 墙纸包", systemImage: "plus.circle")
            }
            .disabled(running)
            // Keep each document picker attached to the control that presents it.
            // Stacking three fileImporter modifiers on the parent List can cause
            // one presentation host to shadow the others on iOS 26.
            .fileImporter(isPresented: $showPackImporter, allowedContentTypes: [.data]) { result in
                importPack(result)
            }
            if selection.tendies.isEmpty {
                NativeNote("还没有导入任何壁纸包。`.tendies` 文件是一个包含墙纸描述器的 ZIP；从墙纸合集（Cowabunga 和 CaPlayground 都有发布）导入一个，然后点“应用”。")
            } else {
                ForEach(selection.tendies) { pack in
                    packRow(pack)
                }
                Button(role: .destructive) {
                    selection.tendies.forEach(PosterBoardImports.remove)
                    selection.loadFromDisk()
                } label: {
                    Label("移除所有壁纸包", systemImage: "trash")
                }
                .disabled(running)
                NativeNote("上游将选择上限设为 \(PosterBoardImports.descriptorLimit) 个描述器。每个壁纸包都会被复制进本应用，因此在这里移除一个只是移除副本 —— 你导入的原始文件不受影响。")
            }
            // Upstream's `auto_convert_legacy` checkbox, on by default. It gates
            // both the import dialog and the apply-time rewrite, so it belongs
            // here rather than in the apply card: turning it off is how a user
            // says "push what I imported, as it is" for good.
            Toggle("将旧版墙纸转换为现代格式",
                   isOn: Binding(get: { PosterBoardPreferences.autoConvertLegacy },
                                 set: { PosterBoardPreferences.autoConvertLegacy = $0 }))
            NativeNote(legacyConvertNote)
        }
    }

    private var legacyConvertNote: String {
        var lines = [
            "iOS 27 仅为现代（“Clownfish”）布局构建景深效果，因此 iOS 27 之前的壁纸包在应用时会被重写 —— 否则它安装后看起来是平的，没有景深。重写会重新标记 family、丢弃外部脚本并重新发布图层，这是尽力而为的操作：可能改变墙纸的外观。不含 27 前内容的包无论如何都保持原样。",
        ]
        if let atLeast27 = PosterBoard.compareVersion(identity.version, "27"), atLeast27 < 0 {
            lines.append("此设备是 iOS \(identity.version)，会按原样读取旧版壁纸包，因此这里不会转换，也不会询问任何包。")
        }
        if !PosterBoardPreferences.autoConvertLegacy {
            lines.append("转换已关闭，旧版壁纸包将按原始文件推送。")
        }
        return lines.joined(separator: "\n\n")
    }

    private func packRow(_ pack: PosterBoardTendie) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pack.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(pack.summary)
                        .font(.caption)
                        .foregroundStyle(pack.isUnsafeContainer ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    PosterBoardImports.remove(pack)
                    selection.loadFromDisk()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .disabled(running)
            }

            // Which extension this pack is injected under. A bare pack does not
            // carry that, and picking the wrong one is silent: the descriptor
            // lands in a folder the provider never reads and the wallpaper just
            // does not appear. The reference asks at import time
            // (`TendieItem.posterType`); here it is a row control that persists
            // with the pack.
            if !pack.isContainer {
                Picker("目标扩展", selection: Binding(
                    get: { pack.posterType },
                    set: { chosen in
                        guard let index = selection.tendies.firstIndex(where: { $0.id == pack.id })
                        else { return }
                        selection.tendies[index] = pack.settingPosterType(chosen)
                    }
                )) {
                    ForEach(PosterBoardPosterType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .disabled(running)
            }
        }
    }

    // MARK: - Video

    private var videoSection: some View {
        Section("视频墙纸") {
            Button {
                showVideoImporter = true
            } label: {
                HStack {
                    Label("选择视频", systemImage: "film")
                    if let video = selection.video?.lastPathComponent {
                        Spacer()
                        Text(video).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .disabled(running)
            .fileImporter(isPresented: $showVideoImporter,
                          allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie]) { result in
                importMedia(result, into: PosterBoard.videoDirectory) { selection.video = $0 }
            }
            Toggle("循环播放（CoreAnimation 帧列表）", isOn: $selection.loop)
            if selection.loop {
                Toggle("循环时倒放", isOn: $selection.reverse)
                Toggle("覆盖时钟", isOn: $selection.foreground)
                calculationModeRow
            } else {
                Button {
                    showThumbnailImporter = true
                } label: {
                    HStack {
                        Label("选择定格画面（.heic）", systemImage: "photo")
                        if let thumbnail = selection.thumbnail?.lastPathComponent {
                            Spacer()
                            Text(thumbnail).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .disabled(running)
                .fileImporter(isPresented: $showThumbnailImporter,
                              allowedContentTypes: [.heic, .image]) { result in
                    importMedia(result, into: PosterBoard.thumbnailDirectory) { selection.thumbnail = $0 }
                }
            }
            if selection.video != nil || selection.thumbnail != nil {
                Button(role: .destructive) {
                    PosterBoard.clearFiles(in: PosterBoard.videoDirectory)
                    PosterBoard.clearFiles(in: PosterBoard.thumbnailDirectory)
                    selection.video = nil
                    selection.thumbnail = nil
                } label: {
                    Label("清除视频选择", systemImage: "xmark.circle")
                }
            }
            NativeNote(videoNote)
        }
    }

    /// Four options in one row is 288 pt of text at the narrowest window width,
    /// so this is a menu: it keeps its value on screen instead of wrapping.
    private var calculationModeRow: some View {
        Picker("计算方式", selection: $selection.calculationMode) {
            ForEach(PosterBoardCalculationMode.allCases) { mode in
                Text(mode.title).tag(mode.rawValue)
            }
        }
    }

    private var videoNote: String {
        var lines = [String]()
        if selection.loop {
            lines.append("循环播放会把视频解码为 JPEG 帧并交给 PosterBoard 一个 CoreAnimation 帧列表（最多 \(PosterBoardVideo.frameLimit) 帧，保持视频自身分辨率）。它速度较慢，且帧会写入备份，因此长视频会造出很大的备份 —— 请先裁剪。")
            lines.append("带有旋转变换的视频会按其存储的方向解码（参考实现的解码器正是如此）；这样的视频在锁定屏幕上可能显示为旋转的。")
        } else {
            lines.append("实况照片方式会把视频写入一个照片海报描述器，并需要一张定格画面 —— 参考实现宁可报错也不交付没有缩略图的描述器。视频会被重新封装为 .mov（如果它本来不是）。")
        }
        if selection.loop && selection.reverse {
            lines.append("“循环时倒放”会先正放再倒放整个视频。")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section("重置") {
            Toggle("完全重置 —— 清空一切，从零开始", isOn: $selection.fullReset)
            ForEach(PosterBoardResetMode.allCases) { mode in
                Toggle(mode.rawValue, isOn: binding(for: mode))
            }
            if !resetWarning.isEmpty {
                NativeSafetyNote(resetWarning)
            }
        }
    }

    private func binding(for mode: PosterBoardResetMode) -> Binding<Bool> {
        Binding(
            get: { !selection.fullReset && selection.resetModes.contains(mode) },
            set: { isOn in
                if isOn {
                    selection.resetModes.insert(mode)
                } else {
                    selection.resetModes.remove(mode)
                }
            })
    }

    private var resetWarning: String {
        if selection.fullReset {
            return "完全重置：存储库的 Extensions、GalleryCache 和 Backups 目录会被清零并替换为空数据库。设备上的所有墙纸都会消失，而且在此之前取回的数据库已过期 —— 下次应用会重新取回一份。"
        }
        if selection.resetModes.isEmpty { return "" }
        let names = selection.resetModes.map(\.rawValue).sorted().joined(separator: ", ")
        return "已选择：\(names)。重置以 0 字节文件覆盖文件夹的方式写入，参考实现就是这样清除它们的；它不需要存储库数据库即可运行，因此是存储库已经出问题时的一条恢复路径。它不会撤销任何已经应用过的内容。"
    }

    // MARK: - What the one Apply will carry

    /// **There is no Apply button here**, and that is the point: the reference has one
    /// apply pass for everything (`_apply_tweak_pass`, with a `needs_posterboard` flag),
    /// and so does this app — the button lives on the home page, next to the tweaks, and
    /// it carries this page's selection with them in one backup and one restore.
    ///
    /// A second button would have been two runs of the same four stages over two payload
    /// sets: two backups, two restores, two chances to leave the device half-applied, and
    /// no way for the operator to know which of them carried what.  Upstream's own
    /// sidebar has a single Apply page for the same reason.
    /// The apply that needs no backup, on the page whose contents it delivers.
    ///
    /// It lives here rather than on the home page because the two applies are
    /// not the same run: the home page's Apply couples the wallpapers to the
    /// tweaks and to a protective backup, and this one is the wallpapers alone.
    /// Reached through the home page, a wallpapers-only run looks identical to
    /// one that also takes a backup — the page says otherwise, but the button
    /// to believe is the one that was pressed.
    private var airliftApplySection: some View {
        Section {
            if selection.isActive {
                Text("就绪：\(selection.describe)").foregroundStyle(.tint)
            } else {
                NativeNote("还没有导入任何壁纸包 —— 在上方导入一个 `.tendies` 即可以此方式应用。")
            }
            Button {
                applyViaAirlift()
            } label: {
                HStack {
                    Label("通过 AirLift 应用", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if running { ProgressView().controlSize(.small) }
                }
            }
            .disabled(!airliftAvailable)
            if !airliftBlocker.isEmpty {
                NativeSafetyNote(airliftBlocker)
            }
            NativeNote("通过隧道把描述器写入 \(PosterBoard.domain) 并注销（Respring），几秒内即可生效。不做备份，因为没有任何东西需要回传设备 —— 但同理，它**只**应用壁纸包：调整需要备份，所以仍要通过主页的“**应用**”按钮。")
        }
    }

    /// Whether the run can start: not already running, not blocked by the device,
    /// and there is something selected to inject.
    private var airliftAvailable: Bool {
        !running && airliftBlocker.isEmpty && selection.isActive
    }

    private var applySection: some View {
        Section {
            if applyMode == .airlift {
                // The home page's Apply is still a backup-mode run even when this
                // page is set to AirLift: it delivers the tweaks, and the
                // wallpapers ride that same backup. Saying "fetches the database
                // first" here would be true of that run, but the database card
                // above is hidden, so it would read as a reference to nothing.
                NativeNote("主页的“**应用**”按钮交付调整，你挑选的墙纸随它们一起进入同一次保护性备份 —— 无论本页面的设置如何，它都是一次备份模式运行。要想不带备份、单独应用壁纸包，请使用上方的“**通过 AirLift 应用**”。")
            } else if selection.isActive {
                Text("就绪：\(selection.describe)").foregroundStyle(.tint)
                NativeNote("由主页的“**应用**”按钮连同调整一起交付。它会先从设备取回存储库数据库，因此那一次运行多一个来回。完成后请重启设备 —— 存储库在开机时读取。")
            } else {
                NativeNote("还没有选择内容。这里选择的内容会由主页的“**应用**”按钮连同调整一起交付 —— 同一份备份，同一次恢复。")
            }
            if applyMode != .airlift {
                NativeNote("数据库本身也可以单独取回，就在上方的卡片里 —— 这是唯一可能因自身原因失败的阶段（设备有权决定是否上传容器），因此能够单独运行、观察和重试，值得一个独立的按钮。")
            }
        }
    }

    private var statusText: String { status ?? "" }

    private func errorSection(_ message: String) -> some View {
        Section("导入失败") {
            NativeSafetyNote(message)
        }
    }

    // MARK: - Behaviour

    private func refreshDatabaseSummary() {
        // The cache is keyed by UDID (upstream does the same), but the page has
        // no UDID outside a run — so it shows the newest database in the
        // directory rather than asking the device to render a label. There is
        // one device behind this app at a time.
        let directory = URL.documents.appendingPathComponent("PosterBoard", conformingTo: .data)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names.filter { $0.hasSuffix(".sqlite3") }.sorted()
        guard let name = candidates.last else {
            databaseSummary = "还没有 —— 添加墙纸的应用会取回一份"
            return
        }
        let url = directory.appendingPathComponent(name)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int64,
              let date = attributes?[.modificationDate] as? Date else {
            databaseSummary = name
            return
        }
        let when = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        databaseSummary = "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))，取回于 \(when)"
    }

    private func importPack(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error): pickError = error.localizedDescription
        case .success(let url):
            do {
                let existing = selection.tendies.reduce(0) { $0 + $1.descriptorCount }
                let pack = try PosterBoardImports.import(from: url)
                // Upstream's cap (`verify_tendie`): a container pack carries no
                // descriptor and so is never counted, which is also what its
                // code does.
                guard existing + pack.descriptorCount <= PosterBoardImports.descriptorLimit else {
                    PosterBoardImports.remove(pack)
                    throw GoldenNuggetError("\(pack.name) 包含 \(pack.descriptorCount) 个描述器，会使选择达到 \(existing + pack.descriptorCount) 个。PosterBoard 的选择器超过 \(PosterBoardImports.descriptorLimit) 个后就无法使用 —— 请先移除一个壁纸包。")
                }
                selection.loadFromDisk()
                pickError = nil
                RunLog.shared.append("PosterBoard：已导入 \(pack.name)（\(pack.summary)）")
                // The reference asks here, once, before the pack joins the
                // selection (`add_tendie` → `_ask_legacy_convert`), so the answer
                // is in place before any apply can read it.
                if let prompt = pack.legacyConvertPrompt(deviceVersion: identity.version) {
                    legacyPrompt = prompt
                }
            } catch {
                pickError = error.localizedDescription
                selection.loadFromDisk()
            }
        }
    }

    private func importMedia(_ result: Result<URL, Error>,
                             into directory: URL,
                             assign: (URL) -> Void) {
        switch result {
        case .failure(let error): pickError = error.localizedDescription
        case .success(let url):
            do {
                assign(try PosterBoard.store(url, in: directory))
                pickError = nil
            } catch {
                pickError = error.localizedDescription
            }
        }
    }

    private func fetchDatabase() {
        guard !running else { return }
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        status = "正在取回 PosterBoard 数据库…"
        statusTone = .accent
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            do {
                try await GoldenNuggetEngine.shared.fetchPosterBoardDatabase()
                text = "数据库已取回。"
                tone = .success
            } catch let failure as TransportFailure where failure.isCancellation {
                text = "⏹ 已被用户停止（\(failure.label)）"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                status = text
                statusTone = tone
                refreshDatabaseSummary()
            }
        }
    }

    /// Run the AirLift injection for the packs selected on this page.
    ///
    /// Shaped like `fetchDatabase` on purpose: the page already owns a run slot,
    /// a run log and a status line, and a second apply path that kept its own
    /// would mean the user watching one of them not move.
    private func applyViaAirlift() {
        guard airliftAvailable else { return }
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        status = "正在通过 AirLift 注入壁纸包…"
        statusTone = .accent
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            do {
                try await GoldenNuggetEngine.shared.applyPosterBoardViaAirlift(
                    selection, deviceVersion: identity.version)
                text = "已通过 AirLift 应用。设备已注销 —— 未做备份。"
                tone = .success
            } catch let failure as TransportFailure where failure.isCancellation {
                text = "⏹ 已被用户停止（\(failure.label)）"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                status = text
                statusTone = tone
            }
        }
    }
}
