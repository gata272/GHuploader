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

    private func upload() async {
        let parts = repoText.split(separator: "/")
        guard parts.count == 2 else {
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
                owner: String(parts[0]), repo: String(parts[1]),
                branch: branch.isEmpty ? "main" : branch,
                files: files,
                message: commitMessage.isEmpty ? "Upload" : commitMessage,
                progress: { done, total in
                    Task { @MainActor in progressText = "\(done)/\(total) ファイルを送信中…" }
                })
            status = "完了！コミット \(sha) で \(files.count) ファイルをアップロードしました"
            isError = false
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }
}
