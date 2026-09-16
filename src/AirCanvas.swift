import UIKit
import ARKit
import RealityKit
import UniformTypeIdentifiers
import Combine

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = CanvasController()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-demo") {
            window.rootViewController = ArtworkPreview(artwork: .previewFixture)
        }
        #endif
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class CanvasController: UIViewController, ARSessionDelegate, UIDocumentPickerDelegate {
    private let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    private let anchor = AnchorEntity(world: .zero)
    private let status = UILabel()
    private let drawingNote = UILabel()
    private var artworkID = UUID()
    private var artworkCreatedAt = Date()
    private var lastAutosave = -Double.infinity
    private var resetConfiguration = false
    private let homeView = UIView()
    private var palette: [UIButton] = []
    private var hasStarted = false
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var prefersStatusBarHidden: Bool { true }
    private let reticle = UILabel()
    private let brushGuide = ModelEntity(mesh: .generateSphere(radius: 1), materials: [UnlitMaterial(color: .systemCyan)])
    private var artwork = Artwork()
    private var recordingEpoch: Double?
    private var lastPoseTime = -Double.infinity
    private var lastGuidanceTime = -Double.infinity
    private var wasOverlapping = false
    private let drawButton = UIButton(type: .system)
    private let colors: [UIColor] = [.systemCyan, .systemPink, .systemYellow, .white]
    private var colorIndex = 0
    private var radius: Float = 0.009
    private var strokes: [Entity] = []
    private var activeStroke: Entity?
    private var previousPoint: SIMD3<Float>?
    private var holding = false
    private var tracking = false
    private var primitiveCount = 0
    private let primitiveLimit = 6000
    private var renderSubscription: Cancellable?
    private var lastRenderedFrame = -Double.infinity
    private var sessionRunning = false
    private let dotMesh = MeshResource.generateSphere(radius: 1)
    private let segmentMesh = MeshResource.generateCylinder(height: 1, radius: 1)
    #if DEBUG
    private var liveRenderDemo: Bool { ProcessInfo.processInfo.arguments.contains("--live-ink-demo") }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        arView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(arView)
        NSLayoutConstraint.activate([
            arView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            arView.topAnchor.constraint(equalTo: view.topAnchor),
            arView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        arView.scene.addAnchor(anchor)
        #if DEBUG
        if liveRenderDemo {
            arView.cameraMode = .nonAR
            let cameraAnchor = AnchorEntity(world: .zero)
            cameraAnchor.addChild(PerspectiveCamera())
            arView.scene.addAnchor(cameraAnchor)
        }
        #endif
        anchor.addChild(brushGuide)
        brushGuide.components.set(OpacityComponent(opacity: 0.35))
        brushGuide.isEnabled = false
        arView.session.delegate = self
        arView.session.delegateQueue = .main
        // Mutate RealityKit's scene during its frame update, not an ARSession callback.
        renderSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.updateDrawingFrame()
        }
        setupControls()
        setupHome()
        #if DEBUG
        if liveRenderDemo { homeView.isHidden = true; hasStarted = true }
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(pauseSession), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(startSession), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    private func button(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = UIColor(white: 0.12, alpha: 0.85)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .large
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = .systemFont(ofSize: 18, weight: .bold)
            return result
        }
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return button
    }

    private func setupControls() {
        status.text = "ゆっくりカメラを動かしてください"
        status.textColor = .white
        status.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        status.font = .systemFont(ofSize: 18, weight: .bold)
        status.textAlignment = .center
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.7
        status.layer.cornerRadius = 16
        status.clipsToBounds = true
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        reticle.text = "○"
        reticle.textColor = .white
        reticle.font = .systemFont(ofSize: 30, weight: .medium)
        reticle.isAccessibilityElement = false
        reticle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reticle)

        for (index, name) in ["水色", "ピンク", "黄色", "白"].enumerated() {
            let swatch = button(name, action: #selector(selectColor(_:)))
            swatch.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = .systemFont(ofSize: 15, weight: .bold)
                return result
            }
            swatch.tag = index
            swatch.configuration?.baseBackgroundColor = colors[index]
            swatch.configuration?.baseForegroundColor = .black
            swatch.accessibilityLabel = name
            swatch.layer.cornerRadius = 18
            swatch.layer.borderColor = UIColor.white.cgColor
            palette.append(swatch)
        }
        let left = UIStackView(arrangedSubviews: palette)
        left.axis = .horizontal
        left.spacing = 10
        left.distribution = .fillEqually
        left.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(left)

        var configuration = UIButton.Configuration.filled()
        configuration.title = "描く"
        configuration.subtitle = "押したまま"
        configuration.image = UIImage(systemName: "paintbrush.pointed.fill")
        configuration.imagePlacement = .leading
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = colors[0]
        configuration.baseForegroundColor = .black
        configuration.cornerStyle = .large
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = .systemFont(ofSize: 28, weight: .heavy)
            return result
        }
        drawButton.configuration = configuration
        drawButton.heightAnchor.constraint(equalToConstant: 90).isActive = true
        // Keep both thumbs usable: the other hand can select a color during a stroke.
        drawButton.isExclusiveTouch = false
        drawButton.accessibilityHint = "押したまま スマホをうごかすと かけます"
        drawButton.addTarget(self, action: #selector(beginStroke), for: .touchDown)
        drawButton.addTarget(self, action: #selector(endStroke), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        let doneButton = button("完成", action: #selector(previewArtwork))
        doneButton.configuration?.baseBackgroundColor = UIColor(red: 1, green: 0.77, blue: 0.30, alpha: 1)
        doneButton.configuration?.baseForegroundColor = .black
        let right = UIStackView(arrangedSubviews: [drawButton])
        right.axis = .vertical
        right.spacing = 10
        right.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(right)
        let menu = button("⌂", action: #selector(showHome))
        menu.accessibilityLabel = "ホーム"
        menu.translatesAutoresizingMaskIntoConstraints = false
        let actions = UIStackView(arrangedSubviews: [menu, button("戻す", action: #selector(undo)), doneButton])
        actions.spacing = 10
        actions.distribution = .fillEqually
        actions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actions)
        drawingNote.text = "両手で持ち、周りの物に気をつけて描いてください"
        drawingNote.textColor = .white
        drawingNote.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        drawingNote.font = .systemFont(ofSize: 14, weight: .semibold)
        drawingNote.textAlignment = .center
        drawingNote.numberOfLines = 2
        drawingNote.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawingNote)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            status.heightAnchor.constraint(equalToConstant: 38),
            actions.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            right.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            right.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            right.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -10),
            left.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            left.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            left.bottomAnchor.constraint(equalTo: right.topAnchor, constant: -12),
            left.heightAnchor.constraint(equalToConstant: 58),
            reticle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            reticle.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            drawingNote.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            drawingNote.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            drawingNote.bottomAnchor.constraint(equalTo: left.topAnchor, constant: -8),
            drawingNote.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
        updatePalette()
    }

    private func setupHome() {
        homeView.accessibilityViewIsModal = true
        homeView.backgroundColor = UIColor(red: 0.035, green: 0.05, blue: 0.09, alpha: 1)
        homeView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(homeView)
        NSLayoutConstraint.activate([
            homeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            homeView.topAnchor.constraint(equalTo: view.topAnchor),
            homeView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let mark = UIImageView(image: UIImage(systemName: "scribble.variable"))
        mark.tintColor = .systemCyan
        mark.contentMode = .scaleAspectFit
        mark.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let title = UILabel()
        title.text = "Air Canvas"
        title.font = .systemFont(ofSize: 42, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center
        let subtitle = UILabel()
        subtitle.text = "空間に描く。動きも作品になる。"
        subtitle.font = .systemFont(ofSize: 17, weight: .medium)
        subtitle.textColor = .lightGray
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        let start = button("描く", action: #selector(startDrawing))
        start.configuration?.baseBackgroundColor = .systemCyan
        start.configuration?.baseForegroundColor = .black
        start.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let library = button("作品を見る", action: #selector(openLibrary))
        let info = button("使い方・プライバシー", action: #selector(showInformation))
        info.configuration?.baseBackgroundColor = .clear
        let row = UIStackView(arrangedSubviews: [mark, title, subtitle, start, library, info])
        row.axis = .vertical
        row.spacing = 22
        row.translatesAutoresizingMaskIntoConstraints = false
        homeView.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: homeView.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: homeView.safeAreaLayoutGuide.centerYAnchor),
            row.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, multiplier: 0.84)
        ])
    }

    @objc private func startDrawing() {
        if !artwork.isEmpty {
            let menu = UIAlertController(title: "描く", message: "描きかけの作品があります。", preferredStyle: .actionSheet)
            menu.addAction(UIAlertAction(title: "続きを描く", style: .default) { [weak self] _ in self?.enterDrawing() })
            menu.addAction(UIAlertAction(title: "保存して新しく描く", style: .default) { [weak self] _ in
                guard let self else { return }
                guard self.saveArtwork() else { self.showSaveFailure(); return }
                self.resetCanvas()
                self.enterDrawing()
            })
            menu.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
            menu.popoverPresentationController?.sourceView = homeView
            present(menu, animated: true)
        } else { enterDrawing() }
    }

    private func enterDrawing() {
        hasStarted = true
        homeView.isHidden = true
        startSession()
    }

    @objc private func showHome() {
        endStroke()
        guard saveArtwork() else { showSaveFailure(); return }
        pauseSession()
        homeView.isHidden = false
    }

    @objc private func openLibrary() {
        let library = ArtworkLibrary(onDelete: { [weak self] id in
            guard let self, self.artworkID == id else { return }
            self.artwork = Artwork()
            self.resetCanvas()
        }) { [weak self] artwork in
            self?.present(ArtworkPreview(artwork: artwork), animated: true)
        }
        present(UINavigationController(rootViewController: library), animated: true)
    }

    @objc private func showInformation() {
        let info = InformationController()
        present(UINavigationController(rootViewController: info), animated: true)
    }

    private func showSaveFailure() {
        let alert = UIAlertController(title: "作品を保存できませんでした", message: "空き容量を確認してください。描画画面の「完成」→「…」から再生用ファイルを書き出すこともできます。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default))
        present(alert, animated: true)
    }

    @discardableResult private func saveArtwork() -> Bool {
        guard !artwork.isEmpty else { return true }
        var snapshot = artwork
        snapshot.strokes.removeAll { $0.points.isEmpty }
        snapshot.poses = snapshot.poses.filter { $0.time <= snapshot.duration }
        do {
            try ArtworkStore.save(SavedArtwork(id: artworkID, createdAt: artworkCreatedAt, artwork: snapshot))
            return true
        } catch {
            drawingNote.text = "保存できません。容量を確認してください。作品は終了せず書き出せます。"
            return false
        }
    }

    @objc private func selectColor(_ sender: UIButton) {
        let resume = holding
        endStroke()
        colorIndex = sender.tag
        updatePalette()
        if resume { beginStroke() }
    }

    private func updatePalette() {
        for swatch in palette {
            let selected = swatch.tag == colorIndex
            swatch.layer.borderWidth = selected ? 4 : 0
            swatch.layer.borderColor = (swatch.tag == 3 ? UIColor.systemTeal : UIColor.white).cgColor
            swatch.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
            swatch.accessibilityValue = selected ? "選択中" : nil
        }
        drawButton.configuration?.baseBackgroundColor = colors[colorIndex]
    }

    @objc private func startSession() {
        guard hasStarted, homeView.isHidden, presentedViewController == nil else { return }
        guard !sessionRunning else { return }
        #if DEBUG
        if liveRenderDemo {
            tracking = true
            sessionRunning = true
            beginStroke()
            return
        }
        #endif
        guard ARWorldTrackingConfiguration.isSupported else {
            status.text = "この端末はAR描画に対応していません。iPhone実機で開いてください。"
            drawButton.isEnabled = false
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        arView.session.run(configuration, options: resetConfiguration ? [.resetTracking, .removeExistingAnchors] : [])
        resetConfiguration = false
        sessionRunning = true
    }

    @objc private func pauseSession() {
        endStroke()
        saveArtwork()
        tracking = false
        brushGuide.isEnabled = false
        arView.session.pause()
        sessionRunning = false
        lastRenderedFrame = -.infinity
    }

    @objc private func beginStroke() {
        guard tracking, primitiveCount < primitiveLimit else { return }
        var timestamp = arView.session.currentFrame?.timestamp
        #if DEBUG
        if liveRenderDemo { timestamp = ProcessInfo.processInfo.systemUptime }
        #endif
        guard let timestamp else { return }
        if recordingEpoch == nil { recordingEpoch = timestamp }
        holding = true
        previousPoint = nil
        let stroke = Entity()
        anchor.addChild(stroke)
        activeStroke = stroke
        strokes.append(stroke)
        artwork.strokes.append(InkStroke(color: colorIndex, radius: radius))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        status.text = "描画中 · 指を離すと止まります"
    }

    @objc private func endStroke() {
        holding = false
        previousPoint = nil
        if let stroke = activeStroke, stroke.children.isEmpty {
            stroke.removeFromParent()
            strokes.removeAll { $0 === stroke }
            if artwork.strokes.last?.points.isEmpty == true { artwork.strokes.removeLast() }
        }
        activeStroke = nil
        saveArtwork()
        if tracking { status.text = "「かく」を 押したまま うごかしてね" }
    }

    @objc private func undo() {
        endStroke()
        guard let stroke = strokes.popLast() else { return }
        primitiveCount -= stroke.children.count
        stroke.removeFromParent()
        artwork.strokes.removeLast()
        if artwork.isEmpty {
            do { try ArtworkStore.delete(id: artworkID) } catch { drawingNote.text = "保存済みの作品を更新できませんでした" }
        } else { saveArtwork() }
    }

    private func resetCanvas() {
        endStroke()
        for stroke in strokes { stroke.removeFromParent() }
        strokes.removeAll()
        primitiveCount = 0
        artwork = Artwork()
        artworkID = UUID()
        artworkCreatedAt = Date()
        recordingEpoch = nil
        lastPoseTime = -.infinity
        lastAutosave = -.infinity
        wasOverlapping = false
        resetConfiguration = true
        sessionRunning = false
        drawingNote.text = "両手で持ち、周りの物に気をつけて描いてください"
    }

    private func updateDrawingFrame() {
        #if DEBUG
        if liveRenderDemo, let epoch = recordingEpoch {
            let timestamp = ProcessInfo.processInfo.systemUptime
            let elapsed = timestamp - epoch
            if elapsed > 15 { endStroke(); return }
            var camera = matrix_identity_float4x4
            let angle = Float(elapsed) * 0.4
            camera.columns.3 = [sin(angle) * 0.075, cos(angle) * 0.075, 0, 1]
            updateDrawing(camera: camera, timestamp: timestamp)
            return
        }
        #endif
        guard let frame = arView.session.currentFrame,
              frame.timestamp > lastRenderedFrame else { return }
        lastRenderedFrame = frame.timestamp
        guard case .normal = frame.camera.trackingState else { return }
        if !tracking { session(arView.session, cameraDidChangeTrackingState: frame.camera) }
        updateDrawing(camera: frame.camera.transform, timestamp: frame.timestamp)
    }

    private func updateDrawing(camera: simd_float4x4, timestamp: Double) {
        guard presentedViewController == nil, homeView.isHidden, sessionRunning else { return }
        if timestamp - lastAutosave >= 5 {
            lastAutosave = timestamp
            saveArtwork()
        }
        updateGuide(camera: camera, timestamp: timestamp)
        if let epoch = recordingEpoch, timestamp - lastPoseTime >= 0.1, artwork.poses.count < 18000 {
            let transform = camera
            let position = transform.columns.3
            artwork.poses.append(DevicePose(position: [position.x, position.y, position.z], rotation: simd_quatf(transform).vector, time: max(0, timestamp - epoch)))
            lastPoseTime = timestamp
        }
        guard holding, let stroke = activeStroke else { return }
        guard primitiveCount + 2 <= primitiveLimit else {
            endStroke()
            status.text = "描画上限です。「完成」で作品を保存してください"
            return
        }
        // Local -Z is the camera's forward direction. Record in world coordinates.
        let tip = camera * SIMD4<Float>(0, 0, -0.30, 1)
        let point = SIMD3<Float>(tip.x, tip.y, tip.z)
        let material = UnlitMaterial(color: colors[colorIndex])
        if let previous = previousPoint {
            let delta = point - previous
            let distance = simd_length(delta)
            guard distance >= 0.008 else { return }
            guard distance < 0.15 else {
                endStroke()
                status.text = "動きが速すぎます。もう一度「描く」を押してください"
                return
            }
            let segment = ModelEntity(mesh: segmentMesh, materials: [material])
            segment.scale = [radius, distance, radius]
            segment.position = (previous + point) / 2
            segment.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / distance)
            stroke.addChild(segment)
            primitiveCount += 1
        }
        let dot = ModelEntity(mesh: dotMesh, materials: [material])
        dot.scale = SIMD3<Float>(repeating: radius)
        dot.position = point
        stroke.addChild(dot)
        primitiveCount += 1
        previousPoint = point
        if let epoch = recordingEpoch, !artwork.strokes.isEmpty {
            artwork.strokes[artwork.strokes.count - 1].points.append(InkPoint(position: point, time: max(0, timestamp - epoch)))
        }
    }

    private func updateGuide(camera: simd_float4x4, timestamp: Double) {
        let tip = camera * SIMD4<Float>(0, 0, -0.3, 1)
        brushGuide.position = [tip.x, tip.y, tip.z]
        brushGuide.scale = SIMD3<Float>(repeating: radius)
        brushGuide.isEnabled = true
        guard timestamp - lastGuidanceTime >= 0.1 else { return }
        lastGuidanceTime = timestamp
        // Ignore the active stroke so a line does not constantly detect its own fresh tail.
        let finished = holding ? Array(artwork.strokes.dropLast()) : artwork.strokes
        let guide = InkGeometry.guidance(strokes: finished, camera: camera, radius: radius)
        let tint: UIColor = guide.overlaps ? .systemGreen : colors[colorIndex]
        if guide.overlaps && !wasOverlapping { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        wasOverlapping = guide.overlaps
        reticle.textColor = tint
        brushGuide.model?.materials = [UnlitMaterial(color: tint)]
    }

    @objc private func previewArtwork() {
        endStroke()
        guard !artwork.isEmpty else { status.text = "「描く」を押したまま動かしてみましょう"; return }
        let saved = saveArtwork()
        pauseSession()
        var snapshot = artwork
        snapshot.poses = snapshot.poses.filter { $0.time <= snapshot.duration }
        present(ArtworkPreview(artwork: snapshot, saved: saved), animated: true)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
                tracking = true
            status.text = holding ? "描画中 · 指を離すと止まります" : "「かく」を 押したまま うごかしてね"
        case .limited(let reason):
            tracking = false
            brushGuide.isEnabled = false
            reticle.textColor = .lightGray
            endStroke()
            switch reason {
            case .excessiveMotion: status.text = "ゆっくりカメラを動かしてください"
            case .insufficientFeatures: status.text = "明るく模様のある場所へカメラを向けてください"
            case .relocalizing: status.text = "元の場所へカメラを向けてください"
            default: status.text = "空間を確認しています"
            }
        case .notAvailable:
            tracking = false
            brushGuide.isEnabled = false
            endStroke()
            status.text = "追跡を待っています"
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        tracking = false
        brushGuide.isEnabled = false
        endStroke()
        status.text = "中断しました。位置を確認してから再開します"
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        status.text = "位置を確認しています。元の場所にカメラを向けてください。"
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sessionRunning = false
        tracking = false
        brushGuide.isEnabled = false
        endStroke()
        status.text = "ARを開始できませんでした。カメラの許可を確認してアプリを開き直してください。"
    }
}
