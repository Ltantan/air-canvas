import UIKit
import UniformTypeIdentifiers

final class ArtworkLibrary: UITableViewController, UIDocumentPickerDelegate {
    private var items: [SavedArtwork] = []
    private let onSelect: (Artwork) -> Void
    private let onDelete: (UUID) -> Void
    init(onDelete: @escaping (UUID) -> Void = { _ in }, onSelect: @escaping (Artwork) -> Void) {
        self.onSelect = onSelect
        self.onDelete = onDelete
        super.init(style: .insetGrouped)
        title = "作品"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "閉じる", style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "読み込む", style: .plain, target: self, action: #selector(importFile))
        reload()
    }
    private func reload() {
        do { items = try ArtworkStore.list() } catch { showError(error) }
        let label = UILabel()
        label.text = "まだ作品がありません\n\n空間に描いた絵と動きは、自動で保存されます。"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        tableView.backgroundView = items.isEmpty ? label : nil
        tableView.reloadData()
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func importFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 15_000_000 else { throw ArtworkError.invalidFile }
            let artwork = try JSONDecoder().decode(Artwork.self, from: Data(contentsOf: url)).validated()
            try ArtworkStore.save(SavedArtwork(id: UUID(), createdAt: Date(), artwork: artwork))
            reload()
        } catch { showError(error) }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let item = items[indexPath.row]
        cell.textLabel?.text = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        cell.detailTextLabel?.text = String(format: "絵と動き · %.1f秒 · %dストローク", item.artwork.duration, item.artwork.strokes.count)
        cell.imageView?.image = UIImage(systemName: "scribble.variable")
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let artwork = items[indexPath.row].artwork
        dismiss(animated: true) { [onSelect] in onSelect(artwork) }
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = items[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: "削除") { [weak self] _, _, done in
            done(false)
            guard let self else { return }
            let alert = UIAlertController(title: "作品を削除しますか？", message: "書き出した動画やファイルは残ります。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
            alert.addAction(UIAlertAction(title: "削除", style: .destructive) { _ in
                do { try ArtworkStore.delete(id: item.id); self.onDelete(item.id); self.reload() } catch { self.showError(error) }
            })
            self.present(alert, animated: true)
        }
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = false
        return config
    }
    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "作品を処理できませんでした", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default))
        DispatchQueue.main.async { self.present(alert, animated: true) }
    }
}

final class InformationController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "使い方・プライバシー"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "閉じる", style: .plain, target: self, action: #selector(close))
        let text = UITextView()
        text.isEditable = false
        text.font = .preferredFont(forTextStyle: .body)
        text.text = """
        空間に描く。動きも作品になる。

        1. 明るい場所で、背面カメラをゆっくり動かします。
        2. 「描く」を押したまま端末を動かすと、約30cm前に線が残ります。指を離すと止まります。
        3. 「完成」で絵と人形の動きを見返します。ドラッグで回転、ピンチで拡大できます。
        4. 「動画」で絵と人形を縦動画にして共有できます。長い作品は最長60秒に収まる速さで再生します。

        両手で持ち、周りの物に気をつけてください。人形は端末の動きから推定した表現です。本人の身体を撮影・計測したものではありません。

        作品の保存
        描画中は約5秒ごとと、指を離したとき・完成時・中断時に端末内へ保存します。保存前の強制終了では直近の描画が失われる場合があります。アプリを削除すると作品も消えます。大切な作品は再生用ファイルを書き出してください。

        プライバシーポリシー
        更新日：2026年9月16日

        カメラは空間の追跡に使用します。カメラの画像・音声・本人の骨格は保存しません。保存するのは線の座標・色・時刻と端末の位置・向きです。動画はこれらのデータから生成します。

        アカウント、広告、解析SDK、開発者のサーバーへのデータ送信はありません。作品はアプリ内に保存され、OSのバックアップ対象になる場合があります。共有は利用者が選んだ保存先・アプリへ行います。共有先のサービスには、そのサービスのポリシーが適用されます。

        作品一覧で左にスワイプすると削除できます。書き出したファイルは保存先で削除してください。

        お問い合わせ
        sazabys044@gmail.com
        """
        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            text.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }
    @objc private func close() { dismiss(animated: true) }
}
