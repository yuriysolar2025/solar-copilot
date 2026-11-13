import AppKit

/// Голова компаньона. Два режима:
/// 1) ФАЙЛ-ИКОНКА (приоритет) — `setFaceImage(url)` (напр. скачанная иконка Ultron в
///    `copilot/altron_face.png`) → показываем её со свечением/пульсом/слежением. Точный вид.
/// 2) КОД-РИСУНОК (fallback) — чистая робо-маска (шлем + брови + глаза-щели + рот-решётка),
///    без арта. Для настоящего Альтрона — подставить иконку (режим 1).
/// Публичный интерфейс совместим со старым «глазом» (контроллер тот же).
final class CompanionEyeView: NSView {
    enum EyeState { case idle, looking, thinking, talking, happy, concerned, recording, dictating }

    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    // Файл-иконка
    private let faceLayer = CALayer()
    private var hasImage = false

    // Код-рисунок
    private let head = CAShapeLayer()
    private let face = CAShapeLayer()
    private let eyesGroup = CALayer()
    private let eyeL = CAShapeLayer()
    private let eyeR = CAShapeLayer()
    private let browL = CAShapeLayer()
    private let browR = CAShapeLayer()
    private let seam = CAShapeLayer()
    private var mouthBars: [CAShapeLayer] = []
    private let mouthFrame = CAShapeLayer()
    private let scan = CAShapeLayer()

    private var blinkTimer: Timer?
    private var gazeTimer: Timer?
    private var dragged = false
    private(set) var state: EyeState = .idle

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
        setState(.idle)
        startIdle()
    }
    required init?(coder: NSCoder) { fatalError("no coder") }
    override var isFlipped: Bool { false }
    deinit { blinkTimer?.invalidate(); gazeTimer?.invalidate() }

    // MARK: - Режим файл-иконки

    /// Подставить иконку из файла (png/jpg). nil/ошибка → код-рисунок.
    func setFaceImage(_ url: URL?) {
        if let url = url, let img = NSImage(contentsOf: url),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            faceLayer.contents = cg
            hasImage = true
        } else {
            faceLayer.contents = nil
            hasImage = false
        }
        let drawn: [CALayer] = [head, face, eyesGroup, browL, browR, seam, mouthFrame, scan] + mouthBars
        drawn.forEach { $0.isHidden = hasImage }
        faceLayer.isHidden = !hasImage
        setState(state)
    }

    // MARK: - Геометрия (код-рисунок)

    private func headPath(_ s: CGFloat) -> CGPath {
        let r = NSRect(x: s * 0.13, y: s * 0.08, width: s * 0.74, height: s * 0.84)
        let p = CGMutablePath()
        let topR = r.width * 0.48, botR = r.width * 0.42
        let inset = r.width * 0.04
        p.move(to: CGPoint(x: r.minX, y: r.maxY - topR))
        p.addQuadCurve(to: CGPoint(x: r.minX + topR, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - topR, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - topR), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - inset, y: r.minY + botR))
        p.addQuadCurve(to: CGPoint(x: r.maxX - inset - botR, y: r.minY), control: CGPoint(x: r.maxX - inset, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + inset + botR, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + inset, y: r.minY + botR), control: CGPoint(x: r.minX + inset, y: r.minY))
        p.closeSubpath()
        return p
    }

    private func eyeSlit(w: CGFloat, h: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
    }

    private func buildLayers() {
        let s = bounds.width

        faceLayer.frame = bounds.insetBy(dx: s * 0.05, dy: s * 0.05)
        faceLayer.contentsGravity = .resizeAspect
        faceLayer.shadowRadius = 13; faceLayer.shadowOpacity = 0.9; faceLayer.shadowOffset = .zero
        faceLayer.isHidden = true
        layer?.addSublayer(faceLayer)

        head.path = headPath(s)
        head.shadowRadius = 13; head.shadowOpacity = 0.9; head.shadowOffset = .zero
        head.lineWidth = max(1.2, s * 0.035)
        layer?.addSublayer(head)

        var faceT = CGAffineTransform(translationX: s * 0.07, y: s * 0.06).scaledBy(x: 0.86, y: 0.86)
        face.path = headPath(s).copy(using: &faceT)
        face.opacity = 0.55
        layer?.addSublayer(face)

        // глаза
        eyesGroup.frame = bounds
        eyesGroup.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        eyesGroup.position = CGPoint(x: s / 2, y: s / 2)
        layer?.addSublayer(eyesGroup)
        let ew = s * 0.26, eh = s * 0.13, eyeY = s * 0.55
        for (eye, x) in [(eyeL, s * 0.34), (eyeR, s * 0.66)] {
            eye.path = eyeSlit(w: ew, h: eh)
            eye.bounds = CGRect(x: 0, y: 0, width: ew, height: eh)
            eye.position = CGPoint(x: x, y: eyeY)
            eye.shadowRadius = 5; eye.shadowOpacity = 0.9; eye.shadowOffset = .zero
            eyesGroup.addSublayer(eye)
        }

        // брови (V-взгляд)
        let brW = ew, brH = s * 0.05
        for (bl, bx) in [(browL, s * 0.34), (browR, s * 0.66)] {
            bl.path = CGPath(roundedRect: CGRect(x: -brW / 2, y: -brH / 2, width: brW, height: brH),
                             cornerWidth: brH / 2, cornerHeight: brH / 2, transform: nil)
            bl.bounds = CGRect(x: -brW / 2, y: -brH / 2, width: brW, height: brH)
            bl.position = CGPoint(x: bx, y: s * 0.70)
            layer?.addSublayer(bl)
        }

        // шов по центру лба
        seam.path = CGPath(roundedRect: CGRect(x: s * 0.485, y: s * 0.72, width: s * 0.03, height: s * 0.14),
                           cornerWidth: s * 0.015, cornerHeight: s * 0.015, transform: nil)
        layer?.addSublayer(seam)

        // рот-решётка
        let count = 4
        let bw = s * 0.05, gap = s * 0.04
        let totalW = CGFloat(count) * bw + CGFloat(count - 1) * gap
        let startX = (s - totalW) / 2 + bw / 2
        let mouthY = s * 0.28, bh = s * 0.10
        let fw = totalW + s * 0.09, fh = bh + s * 0.07
        mouthFrame.path = CGPath(roundedRect: CGRect(x: (s - fw) / 2, y: mouthY - fh / 2, width: fw, height: fh),
                                 cornerWidth: s * 0.035, cornerHeight: s * 0.035, transform: nil)
        mouthFrame.fillColor = NSColor.clear.cgColor
        mouthFrame.lineWidth = max(1, s * 0.018)
        layer?.addSublayer(mouthFrame)
        for i in 0..<count {
            let bar = CAShapeLayer()
            bar.path = CGPath(roundedRect: CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh),
                              cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil)
            bar.bounds = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)
            bar.position = CGPoint(x: startX + CGFloat(i) * (bw + gap), y: mouthY)
            layer?.addSublayer(bar)
            mouthBars.append(bar)
        }

        scan.path = CGPath(rect: CGRect(x: s * 0.20, y: 0, width: s * 0.60, height: max(1, s * 0.02)), transform: nil)
        scan.opacity = 0
        layer?.addSublayer(scan)
    }

    // MARK: - Состояния

    private func color(for st: EyeState) -> NSColor {
        switch st {
        case .idle, .looking, .talking: return NSColor.systemTeal
        case .thinking:                 return NSColor.systemYellow
        case .happy:                    return NSColor.systemGreen
        case .concerned:                return NSColor.systemOrange
        case .recording:                return NSColor.systemRed
        case .dictating:                return NSColor.systemBlue
        }
    }

    func setState(_ st: EyeState) {
        state = st
        let c = color(for: st)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if hasImage {
            faceLayer.shadowColor = c.cgColor
        } else {
            head.fillColor = NSColor.black.withAlphaComponent(0.78).cgColor
            head.strokeColor = c.withAlphaComponent(0.95).cgColor
            head.shadowColor = c.cgColor
            face.fillColor = c.withAlphaComponent(0.10).cgColor
            face.strokeColor = c.withAlphaComponent(0.30).cgColor
            face.lineWidth = max(1, bounds.width * 0.02)
            eyeL.fillColor = c.cgColor; eyeL.shadowColor = c.cgColor
            eyeR.fillColor = c.cgColor; eyeR.shadowColor = c.cgColor
            browL.fillColor = c.withAlphaComponent(0.9).cgColor
            browR.fillColor = c.withAlphaComponent(0.9).cgColor
            seam.fillColor = c.withAlphaComponent(0.45).cgColor
            mouthFrame.fillColor = NSColor.clear.cgColor
            mouthFrame.strokeColor = c.withAlphaComponent(0.55).cgColor
            let idleMouth = (st == .idle || st == .happy || st == .concerned)
            for b in mouthBars { b.fillColor = c.withAlphaComponent(idleMouth ? 0.5 : 0.95).cgColor }
            scan.fillColor = c.withAlphaComponent(0.8).cgColor
        }
        CATransaction.commit()

        applyPulse(duration: (st == .recording || st == .dictating) ? 1.0 : (st == .talking ? 1.15 : (st == .thinking ? 1.6 : 2.6)))
        setMouthActive(!hasImage && (st == .talking || st == .recording || st == .dictating))
        setScanActive(!hasImage && (st == .thinking || st == .looking))
        if !hasImage {
            let tilt: CGFloat = (st == .happy) ? 0.05 : (st == .concerned ? 0.32 : 0.20)
            eyeL.setAffineTransform(CGAffineTransform(rotationAngle: -tilt))
            eyeR.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
            browL.setAffineTransform(CGAffineTransform(rotationAngle: -tilt * 1.4))
            browR.setAffineTransform(CGAffineTransform(rotationAngle: tilt * 1.4))
        }
    }

    // MARK: - Анимации

    private func startIdle() {
        applyPulse(duration: 2.6)
        scheduleBlink()
        startGazeTracking()
    }

    private func applyPulse(duration: CFTimeInterval) {
        layer?.removeAnimation(forKey: "pulse")
        let p = CABasicAnimation(keyPath: "transform.scale")
        p.fromValue = 1.0; p.toValue = 1.035; p.duration = duration
        p.autoreverses = true; p.repeatCount = .infinity
        p.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(p, forKey: "pulse")
    }

    private func scheduleBlink() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 3.0...6.5), repeats: false) { [weak self] _ in
            self?.blink(); self?.scheduleBlink()
        }
    }
    private func blink() {
        guard !hasImage else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
        a.values = [1.0, 0.06, 1.0]; a.keyTimes = [0, 0.5, 1]; a.duration = 0.16
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        eyesGroup.add(a, forKey: "blink")
    }

    private func setMouthActive(_ on: Bool) {
        for (i, b) in mouthBars.enumerated() {
            b.removeAnimation(forKey: "eq")
            guard on else { b.transform = CATransform3DIdentity; continue }
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = [0.35, 1.0, 0.5, 0.85, 0.4, 1.0, 0.35]
            a.keyTimes = [0, 0.18, 0.36, 0.5, 0.68, 0.84, 1]
            a.duration = 0.55 + Double(i) * 0.1
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.beginTime = CACurrentMediaTime() + Double(i) * 0.08
            b.add(a, forKey: "eq")
        }
    }

    private func setScanActive(_ on: Bool) {
        scan.removeAnimation(forKey: "scan"); scan.removeAnimation(forKey: "scanfade"); scan.opacity = 0
        guard on else { return }
        let s = bounds.width
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = s * 0.78; move.toValue = s * 0.20
        move.duration = 1.6; move.repeatCount = .infinity
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.7, 0.7, 0.0]; fade.keyTimes = [0, 0.15, 0.85, 1]
        fade.duration = 1.6; fade.repeatCount = .infinity
        scan.add(move, forKey: "scan"); scan.add(fade, forKey: "scanfade")
    }

    private func startGazeTracking() {
        gazeTimer?.invalidate()
        gazeTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.gazeTick() }
    }
    private func gazeTick() {
        guard let win = window else { return }
        let s = bounds.width
        let mouse = NSEvent.mouseLocation
        let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
        var dx = mouse.x - center.x, dy = mouse.y - center.y
        let len = max(1, (dx * dx + dy * dy).squareRoot())
        let maxOff = s * 0.05
        dx = dx / len * min(maxOff, len / 18); dy = dy / len * min(maxOff, len / 18)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if hasImage { faceLayer.frame = bounds.insetBy(dx: s * 0.05, dy: s * 0.05).offsetBy(dx: dx, dy: dy) }
        else { eyesGroup.position = CGPoint(x: s / 2 + dx, y: s / 2 + dy) }
        CATransaction.commit()
    }

    // MARK: - Мышь

    override func mouseDown(with event: NSEvent) { dragged = false }
    override func mouseDragged(with event: NSEvent) { if !dragged { dragged = true; window?.performDrag(with: event) } }
    override func mouseUp(with event: NSEvent) { if !dragged { onClick?() } }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
