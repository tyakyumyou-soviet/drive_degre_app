import SwiftUI
import AVFoundation

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.055, blue: 0.09).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    Text("ANGLE MONITOR").font(.headline).tracking(2).foregroundStyle(.secondary)
                    PortraitHUDMeter(motion: model.motion, design: model.design)
                        .frame(height: 420)
                    Picker("表示デザイン", selection: $model.design) {
                        ForEach(HUDDesign.allCases) { design in
                            Text("デザイン\(design.rawValue)").tag(design)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(.cyan)
                    Button {
                        model.vibrationSuppressionEnabled.toggle()
                    } label: {
                        Label("振動抑制モード：\(model.vibrationSuppressionEnabled ? "オン" : "オフ")",
                              systemImage: model.vibrationSuppressionEnabled ? "waveform.path.ecg" : "waveform")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.vibrationSuppressionEnabled ? .green : .gray)
                    .accessibilityValue(model.vibrationSuppressionEnabled ? "オン" : "オフ")
                    Text(model.vibrationSuppressionEnabled
                         ? "細かな揺れを抑えます。角度の反応は少しゆっくりになります。"
                         : "通常の速さで角度に追従します。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        model.absoluteAngleMode.toggle()
                    } label: {
                        Label("絶対角度モード：\(model.absoluteAngleMode ? "オン" : "オフ")",
                              systemImage: "level")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.absoluteAngleMode ? .cyan : .gray)
                    .accessibilityValue(model.absoluteAngleMode ? "オン" : "オフ")
                    Text(model.absoluteAngleMode
                         ? "取り付け補正なし・鉛直を0°とした角度を表示します。"
                         : "取り付け補正を適用した角度を表示します。")
                        .font(.caption).foregroundStyle(.secondary)
                    SampleBufferPreview(layer: model.pipeline.displayLayer)
                        .frame(width: 192, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2)))
                    Button("取り付け角度を補正（0°設定）") { model.reset() }
                        .buttonStyle(.bordered)
                        .disabled(model.absoluteAngleMode)
                    HStack(spacing: 14) {
                        Button { model.pip.start() } label: { Label("PiP開始", systemImage: "pip.enter") }.buttonStyle(.borderedProminent)
                        Button { model.pip.stop() } label: { Label("PiP終了", systemImage: "pip.exit") }.buttonStyle(.bordered)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        stateRow("センサー", model.motion.status)
                        stateRow("絶対傾斜（鉛直0°）", model.motion.absolutePitch.map { String(format: "%+.1f°", $0) } ?? "—")
                        stateRow("取り付け補正値", model.motion.mountingCorrection.map { String(format: "%+.1f°", $0) } ?? "未設定")
                        stateRow("最終センサー更新", model.motion.lastUpdate?.formatted(date: .omitted, time: .standard) ?? "—")
                        stateRow("映像生成", model.lastFrame?.formatted(date: .omitted, time: .standard) ?? "起動中")
                        stateRow("映像レイヤー", model.pipeline.displayReadiness)
                        stateRow("PiP開始可能", model.pip.isPossible ? "はい" : "いいえ")
                        stateRow("PiP", model.pip.status)
                        stateRow("アプリ状態", model.appState)
                    }.font(.footnote).padding().frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    Text("前後方向の傾き。角度の符号は実機で向きを確認してください。バックグラウンド更新はOSと実機による検証が必要です。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24)
            }
        }
        .onAppear { model.pip.prepare() }
        .preferredColorScheme(.dark)
    }
    private func stateRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(minLength: 10); Text(value).multilineTextAlignment(.trailing).lineLimit(2) }
    }
}

private struct PortraitHUDMeter: UIViewRepresentable {
    @ObservedObject var motion: MotionService
    let design: HUDDesign
    func makeUIView(context: Context) -> PortraitHUDView { PortraitHUDView() }
    func updateUIView(_ uiView: PortraitHUDView, context: Context) {
        uiView.angle = motion.angle
        uiView.design = design
        uiView.setNeedsDisplay()
    }
}

private final class PortraitHUDView: UIView {
    var angle = 0.0
    var design = HUDDesign.b
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        LevelRenderer.drawHUD(in: context, size: bounds.size, angle: angle, appState: "", design: design)
    }
}

private struct SampleBufferPreview: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> LayerHostView { let view = LayerHostView(); view.displayLayer = layer; return view }
    func updateUIView(_ uiView: LayerHostView, context: Context) { uiView.displayLayer = layer }
}

private final class LayerHostView: UIView {
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            if oldValue !== displayLayer { oldValue?.removeFromSuperlayer() }
            if let displayLayer, displayLayer.superlayer !== layer { layer.addSublayer(displayLayer) }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
