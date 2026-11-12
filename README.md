# GHアップローダ (GHUploader) v3

ZIP をアプリ内で展開（隠しファイル含む）し、GitHub API 経由で
リポジトリ作成 → アップロード → ビルド監視 → IPA取得 までをアプリ内で完結させる。

## v3 の改善
- リポジトリを一覧から選択可能に（一覧取得ボタン＋ピッカー、ブランチも自動設定）
- トークン欄に表示/非表示トグルを追加。表示中は通常の入力欄になるため
  Simeji など全てのキーボードが使える（非表示=パスワード欄では iOS の仕様で
  外部キーボードが無効になるため）
- 全セクションを折りたたみ可能に（タイトルタップで開閉）

## 必要なトークン（Fine-grained PAT）
- Repository access: **All repositories**
- Permissions:
  - **Administration: Read and write**（リポジトリ作成）
  - **Contents: Read and write**（アップロード）
  - **Workflows: Read and write**（.github/workflows/build.yml のアップロード）
  - **Actions: Read-only**（ビルド状況と成果物の取得）
