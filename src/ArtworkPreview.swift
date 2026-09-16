import UIKit
import SceneKit
import AVFoundation

final class ArtworkPreview: UIViewController {
    private let artwork: Artwork
    private let saved: Bool
    private var playbackDuration: Double { artwork.duration }
    private var videoExporter: ReplayVideoExporter?
    private var videoProgress: UIAlertController?
    private let sceneView = SCNView()
    private let cameraNode = SCNNode()
    private var timeline: [(node: SCNNode, time: Double)] = []
    private var visibleCount = 0
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let help = UILabel()
    private let mode = UISegmentedControl(items: ["見回す", "中に入る"])
    private var playButton: UIButton!
    private var poseButton: UIButton!
    private var puppetButton: UIButton!
    private let puppetNote = UILabel()
    private let puppetNode = PuppetNode()
    private lazy var puppetMotion = PuppetMotion(poses: artwork.poses)
    private var showPuppet = false
    private var exportButton: UIButton!
    private var movementRow: UIStackView!
    private let deviceNode = SCNNode()
    private var displayLink: CADisplayLink?
    private var playing = false
    private var showDevice = false
    private var currentTime: Double = 0
    private var previousTick: Double = 0
    private var speed: Double = 1
    private var movement: Float = 0
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var lookGesture: UIPanGestureRecognizer!
    private var exporting = false
    private lazy var artworkExtent = artwork.bounds.extent
    private var hasFramedScene = false

    init(artwork: Artwork, saved: Bool = true) {
        self.artwork = artwork
        self.saved = saved
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    override var prefersStatusBarHidden: Bool { true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.045, alpha: 1)
        let result = ArtworkScene.make(artwork)
        sceneView.scene = result.scene
        timeline = result.timeline
        visibleCount = timeline.count
        sceneView.backgroundColor = UIColor(white: 0.045, alpha: 1)
        sceneView.autoenablesDefaultLighting = true
        sceneView.antialiasingMode = .multisampling4X
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.001
        cameraNode.camera?.zFar = 2000
        cameraNode.camera?.fieldOfView = 50
        cameraNode.camera?.projectionDirection = .vertical
        sceneView.scene?.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
        lookGesture = UIPanGestureRecognizer(target: self, action: #selector(lookAround(_:)))
        lookGesture.maximumNumberOfTouches = 1
        lookGesture.isEnabled = false
        sceneView.addGestureRecognizer(lookGesture)
        makeDeviceMarker()
        sceneView.scene?.rootNode.addChildNode(puppetNode)
        setupControls()
        showPuppet = !artwork.poses.isEmpty
        puppetButton.configuration?.title = showPuppet ? "人形 ON" : "人形 OFF"
        resetView()
        if !saved { help.text = "自動保存できませんでした。「…」からファイルを書き出してください" }
        setTime(artwork.duration)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        previousTick = 0
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !hasFramedScene, sceneView.bounds.height > 0 {
            hasFramedScene = true
            resetView()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPlayback()
        displayLink?.invalidate()
        displayLink = nil
        videoExporter?.cancel()
    }

    private func button(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 0.16, alpha: 0.95)
        config.cornerStyle = .medium
        button.configuration = config
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func setupControls() {
        let close = button("戻る", #selector(closePreview))
        let home = button("全体", #selector(resetView))
        exportButton = button("動画", #selector(exportVideo))
        let more = button("…", #selector(exportMenu))
        let top = UIStackView(arrangedSubviews: [close, home, exportButton, more])
        top.distribution = .fillEqually
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)

        mode.selectedSegmentIndex = 0
        mode.backgroundColor = UIColor(white: 0.2, alpha: 1)
        mode.selectedSegmentTintColor = .darkGray
        mode.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        mode.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        mode.heightAnchor.constraint(equalToConstant: 40).isActive = true
        help.textColor = .lightGray
        help.font = .preferredFont(forTextStyle: .caption1)
        help.textAlignment = .center
        help.numberOfLines = 0
        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        timeLabel.textAlignment = .center
        slider.minimumValue = 0
        slider.maximumValue = Float(max(playbackDuration, 0.001))
        slider.accessibilityLabel = "描画の再生位置"
        slider.addTarget(self, action: #selector(scrub), for: .valueChanged)

        playButton = button("▶ 再生", #selector(togglePlayback))
        let rate = button("1×", #selector(changeSpeed(_:)))
        poseButton = button("端末OFF", #selector(toggleDevice))
        let playback = UIStackView(arrangedSubviews: [playButton, rate, poseButton])
        playback.spacing = 8
        playback.distribution = .fillEqually
        poseButton.isHidden = true
        let back = button("後ろへ", #selector(stopMoving))
        let forward = button("前へ", #selector(stopMoving))
        back.tag = -1
        forward.tag = 1
        for button in [back, forward] {
            button.addTarget(self, action: #selector(startMoving(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(stopMoving), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        }
        movementRow = UIStackView(arrangedSubviews: [back, forward])
        movementRow.spacing = 8
        movementRow.distribution = .fillEqually
        movementRow.isHidden = true
        puppetButton = button("人形 OFF", #selector(togglePuppet))
        puppetButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        puppetButton.isEnabled = !artwork.poses.isEmpty
        puppetNote.text = artwork.poses.isEmpty ? "動きの記録がありません" : "端末の動きから推定した人形"
        puppetNote.font = .preferredFont(forTextStyle: .caption1)
        puppetNote.textColor = .lightGray
        puppetNote.numberOfLines = 0
        let puppetRow = UIStackView(arrangedSubviews: [puppetButton, puppetNote])
        puppetRow.spacing = 12
        let bottom = UIStackView(arrangedSubviews: [help, movementRow, puppetRow, timeLabel, slider, playback])
        bottom.axis = .vertical
        bottom.spacing = 5
        bottom.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottom)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            sceneView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            sceneView.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        poseButton.isEnabled = !artwork.poses.isEmpty
    }

    private func makeDeviceMarker() {
        let body = SCNBox(width: 0.07, height: 0.14, length: 0.009, chamferRadius: 0.008)
        body.firstMaterial?.diffuse.contents = UIColor.systemOrange
        deviceNode.geometry = body
        let lens = SCNSphere(radius: 0.012)
        lens.firstMaterial?.diffuse.contents = UIColor.white
        let front = SCNNode(geometry: lens)
        front.position = SCNVector3(0, 0, -0.02)
        deviceNode.addChildNode(front)
        let tip = SCNSphere(radius: 0.006)
        tip.firstMaterial?.diffuse.contents = UIColor.systemCyan
        let tipNode = SCNNode(geometry: tip)
        tipNode.position = SCNVector3(0, 0, -0.3)
        deviceNode.addChildNode(tipNode)
        deviceNode.isHidden = true
        sceneView.scene?.rootNode.addChildNode(deviceNode)
    }

    @objc private func resetView() {
        movement = 0
        var bounds = artwork.bounds
        if showPuppet {
            let body = puppetMotion.bounds
            let low = simd_min(bounds.center - SIMD3<Float>(repeating: bounds.extent / 2), body.center - SIMD3<Float>(repeating: body.extent / 2))
            let high = simd_max(bounds.center + SIMD3<Float>(repeating: bounds.extent / 2), body.center + SIMD3<Float>(repeating: body.extent / 2))
            bounds = ((low + high) / 2, max(high.x - low.x, max(high.y - low.y, high.z - low.z)))
        }
        let aspect = Float(max(sceneView.bounds.width, 1) / max(sceneView.bounds.height, 1))
        let halfFOV = min(Float.pi * 25 / 180, atan(tan(Float.pi * 25 / 180) * aspect))
        let distance = bounds.extent * 0.6 / max(sin(halfFOV), 0.05)
        let offset = simd_normalize(showPuppet ? SIMD3<Float>(1, 0.55, 1.4) : SIMD3<Float>(0, 0.15, 1)) * distance
        cameraNode.simdPosition = bounds.center + offset
        cameraNode.look(at: SCNVector3(bounds.center))
        sceneView.pointOfView = cameraNode
        sceneView.defaultCameraController.target = SCNVector3(bounds.center)
        sceneView.defaultCameraController.interactionMode = .orbitTurntable
        yaw = atan2(offset.x, offset.z)
        pitch = -atan2(offset.y, hypot(offset.x, offset.z))
        updateMode()
    }

    @objc private func changeMode() {
        // Preserve the orbit controller's current camera pose when entering the work.
        if let pov = sceneView.pointOfView {
            cameraNode.simdTransform = pov.presentation.simdWorldTransform
            let forward = -cameraNode.simdWorldTransform.columns.2
            yaw = atan2(-forward.x, -forward.z)
            pitch = asin(max(-0.99, min(0.99, forward.y)))
        }
        movement = 0
        updateMode()
    }

    private func updateMode() {
        let inside = mode.selectedSegmentIndex == 1
        sceneView.allowsCameraControl = !inside
        lookGesture.isEnabled = inside
        movementRow.isHidden = !inside
        help.text = inside ? "ドラッグで見回す · 前へ／後ろへを押して移動" : "ドラッグで回転 · ピンチで拡大"
        if inside { sceneView.pointOfView = cameraNode }
    }

    @objc private func lookAround(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: sceneView)
        gesture.setTranslation(.zero, in: sceneView)
        yaw -= Float(delta.x) * 0.005
        pitch = max(-1.45, min(1.45, pitch - Float(delta.y) * 0.005))
        cameraNode.simdOrientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
    }
    @objc private func startMoving(_ sender: UIButton) { movement = Float(sender.tag) }
    @objc private func stopMoving() { movement = 0 }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = previousTick == 0 ? 0 : min(link.timestamp - previousTick, 0.1)
        previousTick = link.timestamp
        if playing {
            let time = currentTime + elapsed * speed
            if time.isFinite { setTime(min(playbackDuration, time), seekVideo: false) }
            if currentTime >= playbackDuration { stopPlayback() }
        }
        if movement != 0 {
            let forward = cameraNode.simdWorldTransform.columns.2
            cameraNode.simdPosition -= SIMD3<Float>(forward.x, forward.y, forward.z) * movement * Float(elapsed) * max(0.1, min(artworkExtent * 0.4, 2))
        }
    }

    private func setTime(_ time: Double, seekVideo: Bool = true) {
        currentTime = time
        while visibleCount > 0 && timeline[visibleCount - 1].time > time {
            visibleCount -= 1
            timeline[visibleCount].node.isHidden = true
        }
        while visibleCount < timeline.count && timeline[visibleCount].time <= time {
            timeline[visibleCount].node.isHidden = false
            visibleCount += 1
        }
        slider.value = Float(time)
        timeLabel.text = String(format: "%.1f / %.1f 秒", time, playbackDuration)
        deviceNode.isHidden = true
        puppetNode.isHidden = true
        if showDevice || showPuppet, let pose = artwork.pose(at: time) {
            deviceNode.simdPosition = pose.position
            deviceNode.simdOrientation = simd_quatf(vector: pose.rotation)
            deviceNode.isHidden = false
        }
        if showPuppet, let joints = puppetMotion.joints(at: time) {
            puppetNode.update(joints)
        }
        if showPuppet {
            puppetNote.text = puppetNode.isHidden ? "ここは 動きの記録がありません" : "端末の動きから推定した人形"
        }
    }

    @objc private func togglePlayback() {
        if playing { stopPlayback(); return }
        if currentTime >= playbackDuration - 0.02 { setTime(0) }
        playing = true
        playButton.configuration?.title = "Ⅱ 停止"
    }
    @objc private func stopPlayback() {
        playing = false
        movement = 0
        playButton?.configuration?.title = "▶ 再生"
    }
    @objc private func backgrounded() { stopPlayback(); videoExporter?.cancel() }
    @objc private func scrub() { stopPlayback(); setTime(Double(slider.value)) }
    @objc private func changeSpeed(_ sender: UIButton) {
        speed = speed == 1 ? 2 : speed == 2 ? 4 : 1
        sender.configuration?.title = "\(Int(speed))×"
    }
    @objc private func toggleDevice() {
        showDevice.toggle()
        poseButton.configuration?.title = showDevice ? "端末ON" : "端末OFF"
        setTime(currentTime, seekVideo: false)
    }
    @objc private func togglePuppet() {
        showPuppet.toggle()
        puppetButton.configuration?.title = showPuppet ? "人形 ON" : "人形 OFF"
        // The phone is always shown with the puppet so its two-handed grip is visible.
        poseButton.isEnabled = !showPuppet && !artwork.poses.isEmpty
        poseButton.configuration?.title = showPuppet || showDevice ? "端末ON" : "端末OFF"
        puppetNote.text = "端末の動きから推定した人形"
        setTime(currentTime, seekVideo: false)
        resetView()
    }
    @objc private func closePreview() { videoExporter?.cancel(); dismiss(animated: true) }

    @objc private func exportMenu() {
        guard !exporting else { return }
        stopPlayback()
        let alert = UIAlertController(title: "作品の書き出し", message: "再生用ファイルは絵と端末の動きを保存します。3Dモデルは完成した絵のみです。", preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "3Dモデル（USDZ）", style: .default) { [weak self] _ in self?.export(model: true) })
        alert.addAction(UIAlertAction(title: "再生用ファイル（JSON）", style: .default) { [weak self] _ in self?.export(model: false) })
        alert.addAction(UIAlertAction(title: mode.selectedSegmentIndex == 0 ? "作品の中に入る" : "作品を外から見る", style: .default) { [weak self] _ in
            guard let self else { return }
            self.mode.selectedSegmentIndex = self.mode.selectedSegmentIndex == 0 ? 1 : 0
            self.changeMode()
        })
        alert.addAction(UIAlertAction(title: showPuppet ? "人形を隠す" : "人形を見る", style: .default) { [weak self] _ in self?.togglePuppet() })
        alert.addAction(UIAlertAction(title: showDevice ? "端末を隠す" : "端末の動きを見る", style: .default) { [weak self] _ in self?.toggleDevice() })
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.popoverPresentationController?.sourceView = exportButton
        present(alert, animated: true)
    }

    @objc private func exportVideo() {
        guard !exporting else { return }
        stopPlayback()
        let speed = max(1, artwork.duration / 58)
        let note = String(format: "絵と推定人形を全体表示で書き出します。720×1280・無音。再生速度 %.1f倍。", speed)
        let alert = UIAlertController(title: "作品を動画にする", message: note, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "書き出す", style: .default) { [weak self] _ in self?.beginVideoExport() })
        present(alert, animated: true)
    }

    private func beginVideoExport() {
        exporting = true
        exportButton.isEnabled = false
        let operation = ReplayVideoExporter()
        videoExporter = operation
        let progress = UIAlertController(title: "動画を作成中", message: "0% · この画面を開いたままお待ちください", preferredStyle: .alert)
        progress.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in operation.cancel() })
        videoProgress = progress
        present(progress, animated: true)
        operation.start(artwork: artwork, progress: { [weak self] value in
            self?.videoProgress?.message = "\(Int(value * 100))% · この画面を開いたままお待ちください"
        }) { [weak self] result in
            guard let self else {
                if case .success(let url) = result { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                return
            }
            self.exporting = false
            self.exportButton.isEnabled = true
            self.videoExporter = nil
            let finish = {
                self.videoProgress = nil
                switch result {
                case .success(let url): self.share(url)
                case .failure(let error):
                    if (error as? ReplayVideoError) != .cancelled { self.showExportError(error) }
                }
            }
            if progress.presentingViewController != nil { progress.dismiss(animated: true, completion: finish) }
            else { finish() }
        }
    }

    private func share(_ url: URL) {
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = exportButton
        share.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        present(share, animated: true)
    }

    private func showExportError(_ error: Error) {
        let alert = UIAlertController(title: "書き出せませんでした", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default))
        present(alert, animated: true)
    }

    private func export(model: Bool) {
        exporting = true
        exportButton.isEnabled = false
        exportButton.configuration?.title = "準備中…"
        let artwork = self.artwork
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<URL, Error> = Result {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(model ? "AirCanvas.usdz" : "AirCanvas-replay.json")
                if model { try ArtworkScene.exportUSDZ(artwork, to: url) }
                else { try JSONEncoder().encode(artwork).write(to: url, options: .atomic) }
                return url
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                self.exportButton.isEnabled = true
                self.exportButton.configuration?.title = "動画"
                switch result {
                case .success(let url):
                    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self.exportButton
                    share.completionWithItemsHandler = { _, _, _, _ in
                        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    }
                    self.present(share, animated: true)
                case .failure(let error):
                    let alert = UIAlertController(title: "書き出せませんでした", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "閉じる", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }
}

#if DEBUG
extension Artwork {
    // Deterministic simulator fixture; never used in normal launches or release builds.
    static var previewFixture: Artwork {
        var strokes: [InkStroke] = []
        var poses: [DevicePose] = []
        for color in 0..<3 {
            var stroke = InkStroke(color: color, radius: 0.006)
            for index in 0..<100 {
                let angle = Float(index) / 99 * .pi * 2
                let point = SIMD3<Float>(cos(angle) * 0.23, sin(angle) * 0.23, Float(color) * 0.14 - 0.3)
                let time = Double(color * 100 + index) * 0.1
                stroke.points.append(InkPoint(position: point, time: time))
                poses.append(DevicePose(position: point + SIMD3<Float>(0, 0, 0.3), rotation: [0, 0, 0, 1], time: time))
            }
            strokes.append(stroke)
        }
        return Artwork(strokes: strokes, poses: poses)
    }
}
#endif
