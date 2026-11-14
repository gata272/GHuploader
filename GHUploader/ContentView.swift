import SwiftUI
import UniformTypeIdentifiers

/// LiveContainer 環境でも動くよう、UIKit の UIDocumentPicker を asCopy=true で使う。
/// （SwiftUI の fileImporter は選択状態が壊れるため使わない）
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var token = TokenStore.load()
    @State private var showToken = false
    @State private var repoText = "" // owner/repo
    @State private var branch = "main"
    @State private var commitMessage = "Upload via GHアップローダ"
    @State private var zipName = ""
    @State private var files: [(path: String, data: Data)] = []
    @State private var stripTopFolder = true
    @State private var rawZip: Data? = nil
    @State private var showPicker = false
    @State private var status = ""
    @State private var isError = false
    @State private var isBusy = false
    @State private var progressText = ""
    @State private var newRepoName = ""
    @State private var newRepoPrivate = false
    // ビルド監視（v4: 「今回のコミット」の実行だけを結果として扱う）
    @State private var runs: [RunInfo] = []
    @State private var watchStatus = ""
    @State private var watchFailed = false
    @State private var artifactList: [ArtifactInfo] = []
    @State private var artifactRunId: Int? = nil
    @State private var ipaURL: URL? = nil
    @State private var selectedRunId: Int? = nil
    @State private var downloadProgress: Double? = nil
    @State private var keptIPA: URL? = nil
    @State private var watchTask: Task<Void, Never>? = nil
    @State private var lastUploadRepo = UserDefaults.standard.string(forKey: "gh.lastUploadRepo") ?? ""
    @State private var lastUploadSha = UserDefaults.standard.string(forKey: "gh.lastUploadSha") ?? ""
    @State private var lastUploadAt = UserDefaults.standard.object(forKey: "gh.lastUploadAt") as? Date
    // リポジトリ一覧・折りたたみ
    @State private var myRepos: [(fullName: String, defaultBranch: String)] = []
    @State private var settingsExpanded = TokenStore.load().isEmpty
    @State private var createExpanded = false
    @State private var zipExpanded = true
    @State private var uploadExpanded = true

    @Environment(\.openURL) private var openURL

    private var parsedRepo: (owner: String, repo: String)? {
        let parts = repoText.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// 今回アップロードしたコミットに対する実行（前回の実行と取り違えないための照合）
    private var matchedRun: RunInfo? {
        guard !lastUploadSha.isEmpty, lastUploadRepo == repoText else { return nil }
        return runs.first { $0.headSha.hasPrefix(lastUploadSha) }
    }

    private var hasUploadContext: Bool {
        !lastUploadSha.isEmpty && lastUploadRepo == repoText
    }

    private func sectionHeader(_ title: String, _ expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation { expanded.wrappedValue.toggle() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 0 : -90))
            }
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            uploadTab
                .tabItem { Label("アップロード", systemImage: "square.and.arrow.up") }
                .tag(0)
            buildTab
                .tabItem { Label("ビルド", systemImage: "hammer") }
                .tag(1)
        }
        .task {
            if keptIPA == nil { keptIPA = ZipReader.storedIPAs().first }
        }
    }

    // MARK: - アップロードタブ

    private var uploadTab: some View {
        NavigationStack {
            Form {
                Section {
                    if settingsExpanded {
                        HStack {
                            if showToken {
                                TextField("Personal Access Token", text: $token)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Personal Access Token", text: $token)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Button {
                                showToken.toggle()
                            } label: {
                                Image(systemName: showToken ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                        }
                        .onChange(of: token) { _, new in TokenStore.save(new) }
                        Text("目のアイコンで表示に切り替えると、Simejiなど全てのキーボードが使えます（パスワード欄ではiOSの仕様で外部キーボードが無効になります）")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("owner/repo（例: username/toolkit）", text: $repoText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: repoText) { _, new in
                                if let r = myRepos.first(where: { $0.fullName == new }) {
                                    branch = r.defaultBranch
                                }
                            }
                        Button {
                            Task { await loadRepos() }
                        } label: {
                            Label("リポジトリ一覧を取得", systemImage: "list.bullet")
                        }
                        .disabled(token.isEmpty || isBusy)
                        if !myRepos.isEmpty {
                            Picker("リポジトリを選択", selection: $repoText) {
                                Text("（未選択）").tag("")
                                ForEach(myRepos, id: \.fullName) { r in
                                    Text(r.fullName).tag(r.fullName)
                                }
                            }
                        }
                        LabeledContent("ブランチ") {
                            TextField("main", text: $branch)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button {
                            Task { await testConnection() }
                        } label: {
                            Label("接続テスト", systemImage: "checkmark.circle")
                        }
                        .disabled(token.isEmpty || isBusy)
                    }
                } header: {
                    sectionHeader("GitHub設定", $settingsExpanded)
                }

                Section {
                    if createExpanded {
                        TextField("リポジトリ名（例: toolkit）", text: $newRepoName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Privateにする", isOn: $newRepoPrivate)
                        Button {
                            Task { await createRepo() }
                        } label: {
                            Label("この名前でリポジトリを作成", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(token.isEmpty || newRepoName.isEmpty || isBusy)
                        Text("作成にはトークンの Administration 権限が必要です").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    sectionHeader("新規リポジトリ", $createExpanded)
                }

                Section {
                    if zipExpanded {
                        Button {
                            showPicker = true
                        } label: {
                            Label("ZIPを選ぶ", systemImage: "doc.zipper")
                        }
                        if !zipName.isEmpty {
                            LabeledContent("選択中", value: zipName)
                                .font(.footnote)
                            Toggle("最上位フォルダを取り除く", isOn: $stripTopFolder)
                                .onChange(of: stripTopFolder) { _, _ in reExtract() }
                            LabeledContent("ファイル数", value: "\(files.count)（隠しファイル含む）")
                                .font(.footnote)
                        }
                        if !files.isEmpty {
                            ForEach(files.prefix(30), id: \.path) { f in
                                Text(f.path).font(.caption).lineLimit(1)
                            }
                            if files.count > 30 {
                                Text("…ほか \(files.count - 30) 件").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    sectionHeader("ZIPファイル", $zipExpanded)
                }

                Section {
                    if uploadExpanded {
                        TextField("コミットメッセージ", text: $commitMessage)
                        Button {
                            Task { await upload() }
                        } label: {
                            Label(isBusy ? "送信中…" : "アップロード", systemImage: "arrow.up.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || files.isEmpty || token.isEmpty || repoText.isEmpty)
                        if !progressText.isEmpty {
                            Text(progressText).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    sectionHeader("アップロード", $uploadExpanded)
                }

                if !status.isEmpty {
                    Section("結果") {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(isError ? .red : .green)
                    }
                }
            }
            .navigationTitle("GHアップローダ")
            .sheet(isPresented: $showPicker) {
                DocumentPicker { url in handlePickedURL(url) }
            }
        }
    }

    // MARK: - ビルドタブ

    private var buildTab: some View {
        NavigationStack {
            Group {
                if parsedRepo == nil {
                    ContentUnavailableView {
                        Label("リポジトリが未選択です", systemImage: "hammer")
                    } description: {
                        Text("「アップロード」タブのGitHub設定でリポジトリを選ぶと、ビルド状況がここに表示されます。")
                    }
                } else {
                    List {
                        Section {
                            if hasUploadContext {
                                LabeledContent("コミット", value: String(lastUploadSha.prefix(7)))
                                    .font(.subheadline)
                                if let lastUploadAt {
                                    LabeledContent("アップロード", value: relativeTime(lastUploadAt))
                                        .font(.subheadline)
                                }
                                if let m = matchedRun {
                                    HStack(spacing: 8) {
                                        Image(systemName: runIcon(m).name)
                                            .foregroundStyle(runIcon(m).color)
                                        Text("今回のビルド: \(runConclusionText(m))")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                } else {
                                    Label("今回のコミットのビルドはまだ開始されていません。前回のビルド結果は今回の結果ではありません。", systemImage: "exclamationmark.triangle")
                                        .font(.subheadline)
                                        .foregroundStyle(.orange)
                                }
                            } else {
                                Text("このリポジトリへの直近のアップロード記録はありません。下の一覧は過去のビルドです。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                startWatch()
                            } label: {
                                Label("ビルド状況を確認（自動更新）", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(token.isEmpty || isBusy)
                            if !watchStatus.isEmpty {
                                Text(watchStatus)
                                    .font(.footnote)
                                    .foregroundStyle(watchFailed ? .red : .primary)
                            }
                        } header: {
                            Text("今回のアップロード")
                        }

                        if artifactRunId != nil {
                            Section("成果物") {
                                if artifactList.isEmpty {
                                    Text("このビルドに成果物はありません")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(artifactList) { a in
                                    Button {
                                        Task { await fetchArtifact(a) }
                                    } label: {
                                        Label("\(a.name) を取得（\(max(a.size / 1024, 1)) KB）", systemImage: "arrow.down.circle")
                                    }
                                    .disabled(isBusy)
                                }
                                if let downloadProgress {
                                    ProgressView(value: downloadProgress) {
                                        Text("ダウンロード中… \(Int(downloadProgress * 100))%")
                                            .font(.caption)
                                    }
                                }
                                if let shareIPA {
                                    ShareLink(item: shareIPA) {
                                        Label("IPAを共有（\(shareIPA.lastPathComponent)）", systemImage: "square.and.arrow.up")
                                    }
                                    Button(role: .destructive) {
                                        deleteKeptIPA()
                                    } label: {
                                        Label("保存済みIPAを削除", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        Section("最近のビルド（タップで成果物を表示）") {
                            if runs.isEmpty {
                                Text("まだ取得していません。「ビルド状況を確認」を押してください")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(runs) { run in
                                HStack(spacing: 10) {
                                    Button {
                                        selectRun(run)
                                    } label: {
                                        HStack(spacing: 10) {
                                        Image(systemName: runIcon(run).name)
                                            .foregroundStyle(runIcon(run).color)
                                            .font(.title3)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(runConclusionText(run))
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                if hasUploadContext, run.headSha.hasPrefix(lastUploadSha) {
                                                    Text("今回")
                                                        .font(.caption2.weight(.bold))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color.accentColor.opacity(0.2))
                                                        .clipShape(Capsule())
                                                }
                                            }
                                            Text("\(run.name) ・ \(relativeTime(run.createdAt)) ・ \(String(run.headSha.prefix(7)))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selectedRunId == run.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    }
                                    .buttonStyle(.plain)
                                    Button {
                                        if let u = URL(string: run.htmlURL) { openURL(u) }
                                    } label: {
                                        Image(systemName: "safari")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("ビルド状況")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startWatch()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(token.isEmpty || parsedRepo == nil)
                }
            }
        }
    }

    // MARK: - 表示ヘルパー

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "時刻不明" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .full
        let rel = f.localizedString(for: date, relativeTo: Date())
        let abs = date.formatted(date: .abbreviated, time: .shortened)
        return "\(rel)（\(abs)）"
    }

    private func runIcon(_ run: RunInfo) -> (name: String, color: Color) {
        if run.status != "completed" { return ("clock.fill", .orange) }
        switch run.conclusion {
        case "success": return ("checkmark.circle.fill", .green)
        case "failure": return ("xmark.circle.fill", .red)
        case "cancelled": return ("minus.circle.fill", .gray)
        default: return ("exclamationmark.circle.fill", .gray)
        }
    }

    private func runConclusionText(_ run: RunInfo) -> String {
        if run.status != "completed" {
            return run.status == "queued" ? "待機中" : "実行中"
        }
        switch run.conclusion {
        case "success": return "成功"
        case "failure": return "失敗"
        case "cancelled": return "キャンセル"
        default: return run.conclusion ?? "終了"
        }
    }

    private var shareIPA: URL? { ipaURL ?? keptIPA }

    private func deleteKeptIPA() {
        if let shareIPA { try? FileManager.default.removeItem(at: shareIPA) }
        ipaURL = nil
        keptIPA = nil
    }

    // MARK: - ZIP

    private func handlePickedURL(_ url: URL) {
        // asCopy=true でアプリ内にコピーされたファイルが渡ってくるので、そのまま読める
        do {
            rawZip = try Data(contentsOf: url)
            zipName = url.lastPathComponent
            reExtract()
        } catch {
            status = "ZIPの読み込みに失敗: \(error.localizedDescription)"
            isError = true
        }
    }

    private func reExtract() {
        guard let rawZip else { return }
        do {
            files = try ZipReader.extract(data: rawZip, stripTopFolder: stripTopFolder)
            status = ""
            isError = false
        } catch {
            status = "ZIPの展開に失敗: \(error.localizedDescription)"
            isError = true
            files = []
        }
    }

    // MARK: - GitHub操作

    private func testConnection() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let login = try await GitHubClient(token: token).currentUser()
            status = "接続OK：\(login) として認証されました"
            isError = false
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }

    private func loadRepos() async {
        isBusy = true
        defer { isBusy = false }
        do {
            myRepos = try await GitHubClient(token: token).listMyRepos()
            if myRepos.isEmpty {
                status = "取得できるリポジトリがありませんでした（トークンの対象範囲を確認してください）"
                isError = true
            } else {
                status = "\(myRepos.count) 件のリポジトリを取得しました"
                isError = false
            }
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }

    private func createRepo() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let r = try await GitHubClient(token: token).createRepository(name: newRepoName, isPrivate: newRepoPrivate)
            repoText = r.fullName
            branch = r.defaultBranch
            status = "リポジトリ \(r.fullName) を作成しました。次にZIPを選んでアップロードしてください"
            isError = false
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }

    private func upload() async {
        guard let target = parsedRepo else {
            status = "リポジトリは owner/repo の形で入力してください"
            isError = true
            return
        }
        isBusy = true
        status = ""
        defer { isBusy = false; progressText = "" }
        do {
            let client = GitHubClient(token: token)
            let sha = try await client.uploadFiles(
                owner: target.owner, repo: target.repo,
                branch: branch.isEmpty ? "main" : branch,
                files: files,
                message: commitMessage.isEmpty ? "Upload" : commitMessage,
                progress: { done, total in
                    Task { @MainActor in progressText = "\(done)/\(total) ファイルを送信中…" }
                })
            // 今回のコミットを記録（ビルド照合用・アプリを閉じても残る）
            lastUploadRepo = repoText
            lastUploadSha = sha
            lastUploadAt = Date()
            UserDefaults.standard.set(repoText, forKey: "gh.lastUploadRepo")
            UserDefaults.standard.set(sha, forKey: "gh.lastUploadSha")
            UserDefaults.standard.set(lastUploadAt, forKey: "gh.lastUploadAt")
            runs = []
            artifactList = []
            artifactRunId = nil
            selectedRunId = nil
            ipaURL = nil
            status = "完了！コミット \(sha) で \(files.count) ファイルをアップロードしました。「ビルド」タブで今回のビルドを監視します"
            isError = false
            selectedTab = 1
            startWatch()
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }

    // MARK: - ビルド監視

    private func startWatch() {
        guard parsedRepo != nil else { return }
        watchTask?.cancel()
        watchFailed = false
        watchStatus = "ビルド状況を取得中…"
        watchTask = Task { await pollRuns() }
    }

    private func pollRuns() async {
        guard let target = parsedRepo else { return }
        let client = GitHubClient(token: token)
        let br = branch.isEmpty ? "main" : branch
        for _ in 0..<40 {
            if Task.isCancelled { return }
            do {
                runs = try await client.listRuns(owner: target.owner, repo: target.repo, branch: br, perPage: 10)
                if let m = matchedRun {
                    if m.status == "completed" {
                        if m.conclusion == "success" {
                            watchStatus = "今回のビルドが成功しました（\(relativeTime(m.createdAt))開始）"
                            watchFailed = false
                            if artifactRunId != m.id {
                                selectedRunId = m.id
                                await loadArtifacts(for: m.id)
                            }
                        } else {
                            watchStatus = "今回のビルドは終了しました: \(runConclusionText(m))"
                            watchFailed = true
                        }
                        return
                    }
                    watchStatus = "今回のビルドを実行中…（\(m.status)）自動で更新します"
                } else if hasUploadContext {
                    watchStatus = "今回のコミット（\(String(lastUploadSha.prefix(7)))）のビルド開始を待っています…（一覧にあるのは前回までのビルドです）"
                } else if let latest = runs.first {
                    if latest.status == "completed" {
                        watchStatus = "最新のビルドは\(runConclusionText(latest))です（\(relativeTime(latest.createdAt))開始・今回のアップロードではありません）"
                        if latest.conclusion == "success", artifactRunId != latest.id {
                            selectedRunId = latest.id
                            await loadArtifacts(for: latest.id)
                        }
                        return
                    }
                    watchStatus = "最新のビルドを実行中…（\(latest.status)）"
                } else {
                    watchStatus = "このブランチのビルド履歴はまだありません"
                    return
                }
            } catch {
                watchStatus = "状況の取得に失敗: \(error.localizedDescription)"
                watchFailed = true
                return
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
        watchStatus = "監視を終了しました（まだ終わっていない場合は、もう一度確認してください）"
    }

    private func selectRun(_ run: RunInfo) {
        selectedRunId = run.id
        ipaURL = nil
        if run.status != "completed" {
            watchStatus = "このビルドはまだ完了していません（\(run.status)）"
            watchFailed = false
            artifactList = []
            artifactRunId = run.id
        } else if run.conclusion != "success" {
            watchStatus = "このビルドは成功していないため、成果物はありません"
            watchFailed = true
            artifactList = []
            artifactRunId = run.id
        } else {
            Task { await loadArtifacts(for: run.id) }
        }
    }

    private func loadArtifacts(for runId: Int) async {
        guard let target = parsedRepo else { return }
        artifactRunId = runId
        do {
            artifactList = try await GitHubClient(token: token).listArtifacts(owner: target.owner, repo: target.repo, runId: runId)
            if artifactList.isEmpty {
                watchStatus = "このビルドに成果物はありません"
                watchFailed = false
            }
        } catch {
            watchStatus = "成果物一覧の取得に失敗: \(error.localizedDescription)"
            watchFailed = true
        }
    }

    private func fetchArtifact(_ a: ArtifactInfo) async {
        guard let target = parsedRepo else { return }
        isBusy = true
        downloadProgress = 0
        defer { isBusy = false; downloadProgress = nil }
        do {
            let data = try await GitHubClient(token: token).downloadArtifact(owner: target.owner, repo: target.repo, artifactId: a.id) { p in
                Task { @MainActor in downloadProgress = p }
            }
            let url = try ZipReader.extractFirstIPA(data: data)
            ipaURL = url
            keptIPA = url
            watchStatus = "IPAを取得しました: \(url.lastPathComponent)（アプリ内に保存済み）"
            watchFailed = false
            status = "IPAを取得しました。「IPAを共有」からLiveContainerへ送ってください"
            isError = false
        } catch {
            watchStatus = "IPAの取得に失敗: \(error.localizedDescription)"
            watchFailed = true
            status = error.localizedDescription
            isError = true
        }
    }
}
