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
