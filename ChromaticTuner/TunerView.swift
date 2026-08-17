import SwiftUI
import UIKit

struct TunerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = TunerEngine()
    @StateObject private var purchases = PurchaseManager()
    @AppStorage("referencePitch") private var referencePitch = 440.0
    @AppStorage("tolerance") private var tolerance = 10.0
    @AppStorage("accidentalPreference") private var accidentalPreference = AccidentalPreference.automatic.rawValue
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("reverseDirection") private var reverseDirection = false
    @State private var showingSettings = false
    @State private var showingSupportPrompt = false
    @State private var showingLaunchPro = false
    @State private var hasPresentedSupportPrompt = false

    private var configuration: TunerConfiguration {
        TunerConfiguration(
            referencePitch: activeReferencePitch,
            tolerance: activeTolerance,
            accidentalPreference: activeAccidentalPreference,
            hapticsEnabled: hapticsEnabled,
            reverseDirection: activeReverseDirection
        )
    }

    private var activeReferencePitch: Double { purchases.isPro ? referencePitch : 440 }
    private var activeTolerance: Double { purchases.isPro ? tolerance : 10 }
    private var activeAccidentalPreference: AccidentalPreference {
        guard purchases.isPro else { return .automatic }
        return AccidentalPreference(rawValue: accidentalPreference) ?? .automatic
    }
    private var activeReverseDirection: Bool { purchases.isPro ? reverseDirection : false }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.beetleBlack, Color(red: 0.042, green: 0.025, blue: 0.056), Color.beetleBlack],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            PitchWheelView(
                midiNote: engine.midiNote,
                cents: engine.cents,
                isTuned: engine.isTuned,
                accidentalPreference: activeAccidentalPreference,
                reverseDirection: activeReverseDirection
            )
            .ignoresSafeArea(.container, edges: .vertical)

            VStack(spacing: 0) {
                header
                statusReadout
                Spacer(minLength: 0)
                footer
            }

            if engine.microphoneDenied {
                MicrophoneAccessCard {
                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(settingsURL)
                }
                .zIndex(20)
            }

            if showingSupportPrompt {
                LaunchProPrompt(
                    openPro: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showingSupportPrompt = false
                        }
                        showingLaunchPro = true
                    },
                    dismiss: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showingSupportPrompt = false
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            engine.update(configuration: configuration)
            engine.start()
            scheduleSupportPromptIfNeeded()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            engine.stop()
        }
        .onChange(of: referencePitch) { _, _ in engine.update(configuration: configuration) }
        .onChange(of: tolerance) { _, _ in engine.update(configuration: configuration) }
        .onChange(of: accidentalPreference) { _, _ in engine.update(configuration: configuration) }
        .onChange(of: hapticsEnabled) { _, _ in engine.update(configuration: configuration) }
        .onChange(of: reverseDirection) { _, _ in engine.update(configuration: configuration) }
        .onChange(of: purchases.entitlementCheckComplete) { _, complete in
            if complete {
                enforceFreeDefaultsIfNeeded()
                scheduleSupportPromptIfNeeded()
            }
        }
        .onChange(of: purchases.isPro) { _, _ in
            enforceFreeDefaultsIfNeeded()
            engine.update(configuration: configuration)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                engine.start()
                Task { await purchases.refreshStoreState() }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                purchases: purchases,
                referencePitch: $referencePitch,
                tolerance: $tolerance,
                accidentalPreference: $accidentalPreference,
                hapticsEnabled: $hapticsEnabled,
                reverseDirection: $reverseDirection
            )
        }
        .sheet(isPresented: $showingLaunchPro) {
            StagProView(purchases: purchases, requestedFeature: nil)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                StagLogoMark(color: isTuned ? Color.beetlePurple : Color.beetleIvory.opacity(0.5))
                    .frame(width: 25, height: 29)
                    .shadow(color: isTuned ? Color.beetlePurple.opacity(0.9) : .clear, radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("STAG").font(.system(size: 9, weight: .bold)).tracking(3)
                    Text("TUNE").font(.caption2.weight(.medium)).tracking(2.1)
                }
                .foregroundStyle(Color.beetleIvory.opacity(0.65))
            }
            Spacer()
            if !purchases.isPro {
                Button {
                    showingSupportPrompt = false
                    showingLaunchPro = true
                } label: {
                    Text("PRO")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Color.beetlePurple)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.beetlePurple.opacity(0.1), in: Capsule())
                        .overlay(Capsule().stroke(Color.beetlePurple.opacity(0.4), lineWidth: 1))
                }
                .accessibilityLabel("Upgrade to Stag Pro")
                .padding(.trailing, 8)
            }
            Button { showingSettings = true } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Color.beetleIvory.opacity(0.72))
                    .background(Color.beetleBlack.opacity(0.5), in: Circle())
                    .overlay(Circle().stroke(Color.beetleIvory.opacity(0.14)))
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    private var statusReadout: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(engine.status.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .default))
                .tracking(2)
                .foregroundStyle(statusColor.opacity(0.9))
            Spacer()
            Text(centsLabel)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(statusColor)
                .contentTransition(.numericText())
        }
        .frame(height: 30)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityReading)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: "tuningfork")
                    .font(.system(size: 11, weight: .medium))
                Text("A = \(Int(activeReferencePitch)) HZ")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            Spacer()
            if let frequency = engine.frequency {
                Text(String(format: "%.1f HZ", frequency))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            } else {
                Text("LISTENING")
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .tracking(1.6)
            }
        }
        .foregroundStyle(Color.beetleIvory.opacity(0.5))
        .padding(.horizontal, 16)
        .frame(height: 42)
        .padding(.horizontal, 18)
        .padding(.bottom, 7)
    }

    private var centsLabel: String {
        guard let cents = engine.cents else { return "— ¢" }
        return String(format: "%+.1f ¢", cents)
    }

    private var statusColor: Color {
        guard engine.cents != nil else { return .secondary }
        return engine.isTuned ? .beetlePurple : .beetleIvory.opacity(0.72)
    }

    private var isTuned: Bool {
        engine.isTuned
    }

    private var accessibilityReading: String {
        guard let midi = engine.midiNote, let cents = engine.cents else { return engine.status }
        let direction = engine.isTuned ? "in tune" : (cents > 0 ? "sharp" : "flat")
        return "\(noteName(for: midi, preference: configuration.accidentalPreference)), \(String(format: "%.1f", abs(cents))) cents \(direction)"
    }

    private func enforceFreeDefaultsIfNeeded() {
        guard purchases.entitlementCheckComplete,
              !purchases.isPro else { return }
        referencePitch = 440
        tolerance = 10
        accidentalPreference = AccidentalPreference.automatic.rawValue
        reverseDirection = false
    }

    private func scheduleSupportPromptIfNeeded() {
        guard purchases.entitlementCheckComplete,
              !purchases.isPro,
              !hasPresentedSupportPrompt else { return }
        hasPresentedSupportPrompt = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !purchases.isPro else { return }
            withAnimation(.easeOut(duration: 0.24)) {
                showingSupportPrompt = true
            }
        }
    }
}

private struct MicrophoneAccessCard: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.beetlePurple)

            VStack(spacing: 7) {
                Text("MICROPHONE ACCESS NEEDED")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.beetleIvory)
                Text("Enable microphone access in Settings so Stag Tune can hear your instrument. Audio stays on this iPhone.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.beetleIvory.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("OPEN SETTINGS", action: openSettings)
                .font(.system(size: 12, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Color.beetleIvory)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.beetlePurple, in: RoundedRectangle(cornerRadius: 13))
        }
        .padding(22)
        .frame(maxWidth: 320)
        .background(Color.beetleBlack.opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.beetlePurple.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.beetleBlack.opacity(0.65), radius: 30, y: 12)
        .padding(.horizontal, 26)
    }
}

private struct LaunchProPrompt: View {
    let openPro: () -> Void
    let dismiss: () -> Void
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LOVE THE APP?")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Color.beetleIvory)
                    Text("Consider supporting Stag by upgrading to Stag Pro.")
                        .font(.footnote)
                        .foregroundStyle(Color.beetleIvory.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Button("STAG PRO", action: openPro)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.beetlePurple)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Color.beetlePurple.opacity(0.13), in: Capsule())

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.beetleIvory.opacity(0.5))
                        .frame(width: 26, height: 26)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 15)
            .padding(.trailing, 8)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.beetlePurple.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 48)
            .offset(y: dragOffset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        if value.translation.height > 36 || value.predictedEndTranslation.height > 80 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .accessibilityAction(named: "Dismiss") {
                dismiss()
            }
        }
    }
}

private struct PitchWheelView: View {
    let midiNote: Int?
    let cents: Double?
    let isTuned: Bool
    let accidentalPreference: AccidentalPreference
    let reverseDirection: Bool
    @State private var displayedPitchPosition = 69.0

    private var pitchPosition: Double { Double(midiNote ?? 69) + (cents ?? 0) / 100 }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let centerY = size.height / 2
            let nearest = Int(displayedPitchPosition.rounded())
            let noteSpacing = min(size.height / 7.2, 112)

            ZStack {
                ForEach((nearest - 4)...(nearest + 4), id: \.self) { note in
                    let delta = Double(note) - displayedPitchPosition
                    // Every semitone uses the same amount of vertical space. Reverse
                    // direction only changes which way pitch travels on screen.
                    let direction: CGFloat = reverseDirection ? 1 : -1
                    let y = centerY + direction * CGFloat(delta) * noteSpacing
                    let isNearest = note == nearest

                    NoteRow(
                        name: noteName(for: note, preference: accidentalPreference),
                        active: isNearest,
                        tuned: isNearest && isTuned
                    )
                    .frame(width: size.width)
                    .position(x: size.width / 2, y: y)
                }

                // The photographic beetle sits above the complete note layer.
                BottomStagGuide(cents: cents, tuned: isTuned)
                centerGuide(size: size)
            }
        }
        .onAppear {
            displayedPitchPosition = pitchPosition
        }
        .onChange(of: pitchPosition) { oldValue, newValue in
            if abs(newValue - oldValue) > 1.0 {
                // A string change is one state change, not a long trip through
                // every note in between. Updating atomically prevents rows from
                // crossing and overlapping during rapid pitch changes.
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    displayedPitchPosition = newValue
                }
            } else {
                withAnimation(.easeOut(duration: 0.055)) {
                    displayedPitchPosition = newValue
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func centerGuide(size: CGSize) -> some View {
        PrecisionMeter(cents: cents, tuned: isTuned)
        .frame(width: size.width - 56, height: 20)
        .position(x: size.width / 2, y: size.height / 2)
    }

}

private struct PrecisionMeter: View {
    let cents: Double?
    let tuned: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let centerGap: CGFloat = 112
            let railWidth = (width - centerGap) / 2
            let clampedCents = max(-50, min(50, cents ?? 0))
            let distance = CGFloat(abs(clampedCents) / 50)
            let markerX = clampedCents < 0
                ? railWidth * (1 - distance)
                : railWidth + centerGap + railWidth * distance
            let guideOpacity = cents == nil ? 0.12 : 0.48

            ZStack {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.beetleIvory.opacity(guideOpacity))
                        .frame(height: 1.3)
                    Color.clear.frame(width: centerGap)
                    Rectangle()
                        .fill(Color.beetleIvory.opacity(guideOpacity))
                        .frame(height: 1.3)
                }

                ForEach(1...5, id: \.self) { step in
                    let fraction = CGFloat(step) / 5
                    let tickHeight: CGFloat = step == 5 ? 9 : 5

                    Capsule()
                        .fill(Color.beetleIvory.opacity(cents == nil ? 0.10 : 0.30))
                        .frame(width: 1, height: tickHeight)
                        .position(x: railWidth * (1 - fraction), y: 10)

                    Capsule()
                        .fill(Color.beetleIvory.opacity(cents == nil ? 0.10 : 0.30))
                        .frame(width: 1, height: tickHeight)
                        .position(x: railWidth + centerGap + railWidth * fraction, y: 10)
                }

                if cents != nil {
                    if tuned && abs(clampedCents) < 0.5 {
                        Circle()
                            .fill(Color.beetlePurple)
                            .frame(width: 5, height: 5)
                            .position(x: railWidth, y: 10)
                        Circle()
                            .fill(Color.beetlePurple)
                            .frame(width: 5, height: 5)
                            .position(x: railWidth + centerGap, y: 10)
                    } else {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(tuned ? Color.beetlePurple : Color.beetleIvory)
                            .frame(width: 7, height: 7)
                            .rotationEffect(.degrees(45))
                            .shadow(
                                color: tuned ? Color.beetlePurple.opacity(0.55) : .clear,
                                radius: 4
                            )
                            .position(x: markerX, y: 10)
                    }
                }
            }
        }
    }
}

private struct NoteRow: View {
    let name: String
    let active: Bool
    let tuned: Bool

    var body: some View {
        Text(name)
            .font(.system(size: active ? 56 : 46, weight: active ? .semibold : .light, design: .default))
            .minimumScaleFactor(0.7)
            .foregroundStyle(tuned ? Color.beetlePurple : Color.beetleIvory)
            .shadow(color: tuned ? Color.beetlePurple.opacity(0.65) : .clear, radius: 11)
            .opacity(active ? 1 : 0.54)
    }
}

private struct BottomStagGuide: View {
    let cents: Double?
    let tuned: Bool

    private var hasSignal: Bool { cents != nil }
    private var clasp: Double {
        // Keep the mandibles completely still until the pitch enters the
        // accepted tuning window, then close them in one locking motion.
        tuned ? 1 : 0
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Image(uiImage: BeetlePhotos.glow)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(tuned ? 1 : 0)

                ZStack {
                    photographicMandible(mirrored: false, size: geometry.size)
                        .rotationEffect(
                            .degrees(-20 + clasp * 14),
                            anchor: UnitPoint(x: 0.49, y: 0.91)
                        )

                    photographicMandible(mirrored: true, size: geometry.size)
                        .rotationEffect(
                            .degrees(20 - clasp * 14),
                            anchor: UnitPoint(x: 0.51, y: 0.91)
                        )

                    Image(uiImage: BeetlePhotos.body)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(1)
                }
                .scaleEffect(0.62, anchor: .bottom)
                .offset(y: 0)
            }
            .animation(
                .timingCurve(0.82, 0.0, 0.16, 1.0, duration: 0.10),
                value: clasp
            )
            .animation(.easeOut(duration: 0.2), value: hasSignal)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func photographicMandible(mirrored: Bool, size: CGSize) -> some View {
        Image(uiImage: BeetlePhotos.mandible)
            .resizable()
            .interpolation(.medium)
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .opacity(hasSignal ? 0.96 : 0.5)
    }
}

private enum BeetlePhotos {
    static let body = load(name: "StagBody-v2")
    static let mandible = load(name: "StagMandible-v2")
    static let glow = load(name: "StagGlow")

    private static func load(name: String) -> UIImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else {
            assertionFailure("Missing bundled beetle photograph: \(name).png")
            return UIImage()
        }
        return image
    }
}

struct StagLogoMark: View {
    let color: Color

    var body: some View {
        Image("StagLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
    }
}

extension Color {
    static let beetleBlack = Color(red: 0.025, green: 0.03, blue: 0.028)
    static let beetleIvory = Color(red: 0.92, green: 0.91, blue: 0.85)
    static let beetlePurple = Color(red: 0.68, green: 0.35, blue: 0.96)
}

private func noteName(for midi: Int, preference: AccidentalPreference) -> String {
    let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
    let index = (midi % 12 + 12) % 12
    return preference == .flats ? flatNames[index] : sharpNames[index]
}
