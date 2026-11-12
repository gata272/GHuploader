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
