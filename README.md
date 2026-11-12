# GHアップローダ (GHUploader)

ZIPをアプリ内で展開し、隠しファイル（.github など）も含めて GitHub リポジトリへ
1コミットで直接アップロードする SwiftUI アプリ。iOS のファイル アプリを経由しないので
ドットファイルが見えない問題が起きない。

## 初回ブートストラップ
1. このフォルダの中身のうち、見えるファイルを GitHub リポジトリにアップロード
2. `.github/workflows/build.yml` だけは Add file > Create new file で
   パスを手入力し、内容を README 末尾ではなく .github/workflows/build.yml と同じ内容で作成
   （スターターZIP内のファイルと同一内容は、このリポジトリを作成したチャットに掲載済み）
3. Actions で "Build IPA" が走り、Artifacts から GHUploader.ipa が取れる
4. LiveContainer に Import して起動

## 使い方
1. GitHub で Fine-grained Personal Access Token を発行
   （対象リポジトリのみ、Permissions: Contents = Read and write）
2. アプリにトークンを入力（キーチェーンに保存される）
3. owner/repo とブランチを入力し「接続テスト」
4. ZIPを選ぶ → 中身（隠しファイル含む）が一覧表示される
5. 「アップロード」で1コミットとして送信される

## 備考
- トークンは端末内のキーチェーンにのみ保存され、api.github.com 以外へは送信されない
- ZIP内の __MACOSX と .DS_Store は自動で除外される
