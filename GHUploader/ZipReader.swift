import Foundation
import ZIPFoundation

enum ZipReader {
    /// ZIPをメモリ上で展開し、(パス, データ) の一覧を返す。隠しファイルも含む。
    static func extract(data: Data, stripTopFolder: Bool) throws -> [(path: String, data: Data)] {
        let archive = try Archive(data: data, accessMode: .read)
        var files: [(path: String, data: Data)] = []
        for entry in archive {
            guard entry.type == .file else { continue }
            let path = entry.path
            if path.hasPrefix("__MACOSX/") || path.hasSuffix(".DS_Store") { continue }
            var d = Data()
            _ = try archive.extract(entry) { chunk in d.append(chunk) }
            files.append((path, d))
        }
        if stripTopFolder, !files.isEmpty {
            let firsts = Set(files.map { $0.path.split(separator: "/").first.map(String.init) ?? "" })
            if firsts.count == 1, let top = firsts.first, !top.isEmpty,
               files.allSatisfy({ $0.path.hasPrefix(top + "/") }) {
                files = files.map { (String($0.path.dropFirst(top.count + 1)), $0.data) }
            }
        }
        return files.filter { !$0.path.isEmpty }
    }
}

extension ZipReader {
    /// 取得したIPAの保存先（Documents/IPAs）。一時フォルダと違いOSに消されない。
    static var ipasDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPAs", isDirectory: true)
    }

    /// 保存済みIPAの一覧（新しい順）。現在のDocumentsから探すので、コンテナ配置が変わっても見つかる
    static func storedIPAs() -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: ipasDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
    }

    /// 成果物ZIPの中から最初の .ipa を取り出して Documents/IPAs に保存する
    static func extractFirstIPA(data: Data) throws -> URL {
        let archive = try Archive(data: data, accessMode: .read)
        for entry in archive where entry.type == .file && entry.path.lowercased().hasSuffix(".ipa") {
            var d = Data()
            _ = try archive.extract(entry) { chunk in d.append(chunk) }
            let name = entry.path.split(separator: "/").last.map(String.init) ?? "app.ipa"
            try FileManager.default.createDirectory(at: ipasDir, withIntermediateDirectories: true)
            let url = ipasDir.appendingPathComponent(name)
            try d.write(to: url, options: .atomic)
            return url
        }
        throw GHError(message: "成果物の中にIPAが見つかりませんでした")
    }
}
