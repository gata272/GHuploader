import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var token = TokenStore.load()
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
    // v2
    @State private var newRepoName = ""
    @State private var newRepoPrivate = false
    @State private var runStatus = ""
    @State private var runFailed = false
    @State private var runURL = ""
    @State private var artifactList: [ArtifactInfo] = []
    @State private var ipaURL: URL? = nil
    @State private var watchTask: Task<Void, Never>? = nil

    private var parsedRepo: (owner: String, repo: String)? {
        let parts = repoText.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub設定") {
                    SecureField("Personal Access Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: token) { _, new in TokenStore.save(new) }
                    TextField("owner/repo（例: username/toolkit）", text: $repoText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("ブランチ")
                        Spacer()
                        TextField("main", text: $branch)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button("接続テスト") { Task { await testConnection() } }
                        .disabled(token.isEmpty || isBusy)
                }

                Section("新規リポジトリ") {
                    TextField("リポジトリ名（例: toolkit）", text: $newRepoName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Privateにする", isOn: $newRepoPrivate)
                    Button("この名前でリポジトリを作成") { Task { await createRepo() } }
                        .disabled(token.isEmpty || newRepoName.isEmpty || isBusy)
                    Text("作成にはトークンの Administration 権限が必要です").font(.caption).foregroundStyle(.secondary)
                }

                Section("ZIPファイル") {
                    Button("ZIPを選ぶ") { showPicker = true }
                    if !zipName.isEmpty {
                        Text(zipName).font(.footnote).foregroundStyle(.secondary)
                        Toggle("最上位フォルダを取り除く", isOn: $stripTopFolder)
                            .onChange(of: stripTopFolder) { _, _ in reExtract() }
                        Text("\(files.count) ファイル（隠しファイル含む）")
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

                Section("アップロード") {
                    TextField("コミットメッセージ", text: $commitMessage)
                    Button(isBusy ? "送信中…" : "アップロード") {
                        Task { await upload() }
                    }
                    .disabled(isBusy || files.isEmpty || token.isEmpty || repoText.isEmpty)
                    if !progressText.isEmpty {
                        Text(progressText).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("ビルドとIPA") {
                    Button("ビルド状況を確認") { startWatch() }
                        .disabled(token.isEmpty || parsedRepo == nil || isBusy)
                    if !runStatus.isEmpty {
                        Text(runStatus).font(.footnote).foregroundStyle(runFailed ? .red : .primary)
                    }
                    if !runURL.isEmpty, let u = URL(string: runURL) {
                        Link("GitHubで開く", destination: u)
                    }
                    ForEach(artifactList) { a in
                        Button("\(a.name) を取得（\(max(a.size / 1024, 1)) KB）") {
                            Task { await fetchArtifact(a) }
                        }
                        .disabled(isBusy)
                    }
                    if let ipaURL {
                        ShareLink(item: ipaURL) {
                            Text("IPAを共有（LiveContainerへ送る）")
                        }
                    }
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
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                handlePick(result)
            }
        }
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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
            status = "完了！コミット \(sha) で \(files.count) ファイルをアップロードしました。ビルドを監視します"
            isError = false
            startWatch()
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }

    private func startWatch() {
        guard parsedRepo != nil else { return }
        watchTask?.cancel()
        artifactList = []
        ipaURL = nil
        runFailed = false
        runStatus = "ビルド状況を取得中…"
        watchTask = Task { await pollRuns() }
    }

    private func pollRuns() async {
        guard let target = parsedRepo else { return }
        let client = GitHubClient(token: token)
        let br = branch.isEmpty ? "main" : branch
        for _ in 0..<40 {
            if Task.isCancelled { return }
            do {
                guard let run = try await client.latestRun(owner: target.owner, repo: target.repo, branch: br) else {
                    runStatus = "まだビルドが始まっていません"
                    return
                }
                runURL = run.htmlURL
                if run.status == "completed" {
                    if run.conclusion == "success" {
                        runStatus = "ビルド成功。成果物を取得できます"
                        artifactList = (try? await client.listArtifacts(owner: target.owner, repo: target.repo, runId: run.id)) ?? []
                        if artifactList.isEmpty { runStatus = "ビルド成功（成果物なし）" }
                    } else {
                        runStatus = "ビルド終了: \(run.conclusion ?? "不明")"
                        runFailed = true
                    }
                    return
                }
                runStatus = "ビルド中…（\(run.status)）自動で更新します"
            } catch {
                runStatus = "状況の取得に失敗: \(error.localizedDescription)"
                runFailed = true
                return
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
        runStatus = "監視を終了しました（まだ終わっていない場合は、もう一度確認してください）"
    }

    private func fetchArtifact(_ a: ArtifactInfo) async {
        guard let target = parsedRepo else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await GitHubClient(token: token).downloadArtifact(owner: target.owner, repo: target.repo, artifactId: a.id)
            ipaURL = try ZipReader.extractFirstIPA(data: data)
            status = "IPAを取得しました。「IPAを共有」からLiveContainerへ送ってください"
            isError = false
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }
}
