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
    /// 成果物ZIPの中から最初の .ipa を取り出して一時フォルダに書き出す
    static func extractFirstIPA(data: Data) throws -> URL {
        let archive = try Archive(data: data, accessMode: .read)
        for entry in archive where entry.type == .file && entry.path.lowercased().hasSuffix(".ipa") {
            var d = Data()
            _ = try archive.extract(entry) { chunk in d.append(chunk) }
            let name = entry.path.split(separator: "/").last.map(String.init) ?? "app.ipa"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try d.write(to: url, options: .atomic)
            return url
        }
        throw GHError(message: "成果物の中にIPAが見つかりませんでした")
    }
}
