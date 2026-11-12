import Foundation

struct GHError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct GitHubClient {
    let token: String

    private func request(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.github.com" + path) else {
            throw GHError(message: "URLが不正です")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let msg = json["message"] as? String ?? "不明なエラー"
            throw GHError(message: "GitHub API エラー (\(code)): \(msg)")
        }
        return json
    }

    func currentUser() async throws -> String {
        let json = try await request(method: "GET", path: "/user")
        return json["login"] as? String ?? "?"
    }

    /// files を1コミットで branch にアップロードする。戻り値はコミットSHA（短縮）。
    func uploadFiles(owner: String, repo: String, branch: String,
                       files: [(path: String, data: Data)],
                       message: String,
                       progress: @escaping (Int, Int) -> Void) async throws -> String {
        let base = "/repos/\(owner)/\(repo)"
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch

        // 現在のブランチ先端を取得（空のリポジトリなら無し）
        var parentCommit: String? = nil
        var baseTree: String? = nil
        if let ref = try? await request(method: "GET", path: "\(base)/git/ref/heads/\(encodedBranch)"),
           let object = ref["object"] as? [String: Any],
           let sha = object["sha"] as? String {
            parentCommit = sha
            if let commit = try? await request(method: "GET", path: "\(base)/git/commits/\(sha)"),
               let tree = commit["tree"] as? [String: Any],
               let treeSha = tree["sha"] as? String {
                baseTree = treeSha
            }
        }

        // 各ファイルを blob 化
        var treeItems: [[String: Any]] = []
        for (i, file) in files.enumerated() {
            progress(i + 1, files.count)
            let blob = try await request(method: "POST", path: "\(base)/git/blobs", body: [
                "content": file.data.base64EncodedString(),
                "encoding": "base64",
            ])
            guard let sha = blob["sha"] as? String else {
                throw GHError(message: "blobの作成に失敗しました: \(file.path)")
            }
            treeItems.append(["path": file.path, "mode": "100644", "type": "blob", "sha": sha])
        }

        // tree 作成
        var treeBody: [String: Any] = ["tree": treeItems]
        if let baseTree { treeBody["base_tree"] = baseTree }
        let tree = try await request(method: "POST", path: "\(base)/git/trees", body: treeBody)
        guard let treeSha = tree["sha"] as? String else {
            throw GHError(message: "treeの作成に失敗しました")
        }

        // commit 作成
        var commitBody: [String: Any] = ["message": message, "tree": treeSha]
        if let parentCommit { commitBody["parents"] = [parentCommit] }
        let commit = try await request(method: "POST", path: "\(base)/git/commits", body: commitBody)
        guard let commitSha = commit["sha"] as? String else {
            throw GHError(message: "commitの作成に失敗しました")
        }

        // ref 更新（新規ブランチなら作成）
        if parentCommit != nil {
            _ = try await request(method: "PATCH", path: "\(base)/git/refs/heads/\(encodedBranch)", body: ["sha": commitSha])
        } else {
            _ = try await request(method: "POST", path: "\(base)/git/refs", body: ["ref": "refs/heads/\(branch)", "sha": commitSha])
        }
        return String(commitSha.prefix(7))
    }
}

// MARK: - v2: リポジトリ作成 / Actions / 成果物

struct RunInfo {
    let id: Int
    let status: String        // queued / in_progress / completed
    let conclusion: String?   // success / failure / cancelled ...
    let htmlURL: String
}

struct ArtifactInfo: Identifiable {
    let id: Int
    let name: String
    let size: Int
}

extension GitHubClient {
    /// POST /user/repos で自分のアカウントにリポジトリを作成する
    func createRepository(name: String, isPrivate: Bool) async throws -> (fullName: String, defaultBranch: String) {
        let json = try await request(method: "POST", path: "/user/repos", body: [
            "name": name,
            "private": isPrivate,
            "auto_init": false,
        ])
        return (json["full_name"] as? String ?? name,
                json["default_branch"] as? String ?? "main")
    }

    func latestRun(owner: String, repo: String, branch: String) async throws -> RunInfo? {
        let b = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
        let json = try await request(method: "GET", path: "/repos/\(owner)/\(repo)/actions/runs?branch=\(b)&per_page=1")
        guard let runs = json["workflow_runs"] as? [[String: Any]], let r = runs.first else { return nil }
        return RunInfo(id: r["id"] as? Int ?? 0,
                       status: r["status"] as? String ?? "",
                       conclusion: r["conclusion"] as? String,
                       htmlURL: r["html_url"] as? String ?? "")
    }

    func listArtifacts(owner: String, repo: String, runId: Int) async throws -> [ArtifactInfo] {
        let json = try await request(method: "GET", path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/artifacts")
        let arr = json["artifacts"] as? [[String: Any]] ?? []
        return arr.map { ArtifactInfo(id: $0["id"] as? Int ?? 0,
                                      name: $0["name"] as? String ?? "artifact",
                                      size: $0["size_in_bytes"] as? Int ?? 0) }
    }

    func downloadArtifact(owner: String, repo: String, artifactId: Int) async throws -> Data {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/artifacts/\(artifactId)/zip") else {
            throw GHError(message: "URLが不正です")
        }
        return try await ArtifactDownloader.download(url: url, token: token)
    }
}

/// 成果物ZIPのダウンロード用。リダイレクト先（署名付きURL）には認証ヘッダを付けない。
final class ArtifactDownloader: NSObject, URLSessionDataDelegate {
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var statusCode = 0

    static func download(url: URL, token: String) async throws -> Data {
        let d = ArtifactDownloader()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try await withCheckedThrowingContinuation { cont in
            d.continuation = cont
            let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
            session.dataTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var r = request
        r.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(r)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if statusCode == 200 {
            continuation?.resume(returning: buffer)
        } else {
            continuation?.resume(throwing: GHError(message: "成果物の取得に失敗しました (HTTP \(statusCode))"))
        }
        continuation = nil
    }
}

// MARK: - v3: リポジトリ一覧

extension GitHubClient {
    private func requestList(method: String, path: String) async throws -> [[String: Any]] {
        guard let url = URL(string: "https://api.github.com" + path) else {
            throw GHError(message: "URLが不正です")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let msg = json["message"] as? String ?? "不明なエラー"
            throw GHError(message: "GitHub API エラー (\(code)): \(msg)")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// トークンでアクセスできる自分のリポジトリ一覧（更新が新しい順）
    func listMyRepos() async throws -> [(fullName: String, defaultBranch: String)] {
        let arr = try await requestList(method: "GET", path: "/user/repos?per_page=100&sort=updated")
        return arr.compactMap { r in
            guard let fn = r["full_name"] as? String else { return nil }
            return (fn, r["default_branch"] as? String ?? "main")
        }
    }
}
