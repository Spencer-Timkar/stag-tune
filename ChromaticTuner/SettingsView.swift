import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var purchases: PurchaseManager
    @Binding var referencePitch: Double
    @Binding var tolerance: Double
    @Binding var accidentalPreference: String
    @Binding var hapticsEnabled: Bool
    @Binding var reverseDirection: Bool
    @State private var showingPro = false
    @State private var requestedFeature: String?

    private var hasProAccess: Bool { purchases.isPro }
    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                proStatus

                Section("Reference pitch") {
                    if hasProAccess {
                        HStack {
                            Text("Concert A")
                            Spacer()
                            Text("\(Int(referencePitch)) Hz")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $referencePitch, in: 390...490, step: 1)
                        Button("Reset to 440 Hz") { referencePitch = 440 }
                            .disabled(referencePitch == 440)
                    } else {
                        lockedSetting("Concert A", value: "440 Hz", feature: "Custom reference pitch")
                    }
                }

                Section("Display") {
                    if hasProAccess {
                        Picker("Accidentals", selection: $accidentalPreference) {
                            ForEach(AccidentalPreference.allCases) { preference in
                                Text(preference.rawValue).tag(preference.rawValue)
                            }
                        }
                        Toggle("Reverse tuning direction", isOn: $reverseDirection)
                        Text(reverseDirection ? "Flat moves up · Sharp moves down" : "Sharp moves up · Flat moves down")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        lockedSetting("Accidental style", value: "Automatic", feature: "Accidental style")
                        lockedSetting("Display direction", value: "Sharp ↑", feature: "Display direction")
                    }
                }

                Section("Tuning") {
                    if hasProAccess {
                        HStack {
                            Text("In-tune tolerance")
                            Spacer()
                            Text("±\(Int(tolerance)) cents")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $tolerance, in: 1...10, step: 1)
                    } else {
                        lockedSetting("In-tune tolerance", value: "±10 ¢", feature: "Adjustable tuning tolerance")
                    }

                    Toggle("Haptic confirmation", isOn: $hapticsEnabled)
                }

                Section {
                    Text("Audio is analyzed entirely on this iPhone. No recordings are saved or transmitted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }

                    LabeledContent("Version", value: versionLabel)
                }
            }
            .foregroundStyle(Color.beetleIvory)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .foregroundStyle(Color.beetleIvory)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.beetleIvory)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingPro) {
            StagProView(purchases: purchases, requestedFeature: requestedFeature)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var proStatus: some View {
        if purchases.isPro {
            Section {
                Label("Stag Pro unlocked", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.beetlePurple)
            } footer: {
                Text("More Stag Pro features are coming, including additional tuning tools and personalization options.")
            }
        } else {
            Section {
                Button {
                    requestedFeature = nil
                    showingPro = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("EXPLORE STAG PRO")
                                .font(.caption.weight(.bold))
                                .tracking(1.4)
                            Text("More control. One purchase. Yours forever.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(Color.beetlePurple)

                Button("Restore Purchase") {
                    Task { await purchases.restorePurchases() }
                }
                .foregroundStyle(Color.beetleIvory)
            } footer: {
                Text("More Stag Pro features are coming, including additional tuning tools and personalization options.")
            }
        }
    }

    private func lockedSetting(_ title: String, value: String, feature: String) -> some View {
        Button {
            requestedFeature = feature
            showingPro = true
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .foregroundStyle(Color.beetleIvory)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                Text("PRO")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.beetlePurple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.beetlePurple.opacity(0.12), in: Capsule())
            }
        }
    }
}

private struct PrivacyPolicyView: View {
    private let onlinePolicyURL = URL(string: "https://spencer-timkar.github.io/stag-tune/privacy.html")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                privacySection(
                    "Microphone",
                    "Stag Tune uses microphone input only to calculate pitch while the tuner is open. Audio is processed on your iPhone and is never recorded, saved, or transmitted."
                )
                privacySection(
                    "Data collection",
                    "Stag Tune does not collect personal information, analytics, location, advertising identifiers, or usage history. The app does not track you across apps or websites."
                )
                privacySection(
                    "Purchases",
                    "Stag Pro purchases are processed by Apple through the App Store. Stag Tune checks Apple-provided purchase entitlements to unlock Pro features but does not receive your payment information."
                )
                privacySection(
                    "Settings",
                    "Your tuner preferences are stored locally on this iPhone. Deleting the app removes those locally stored preferences."
                )

                Link(destination: onlinePolicyURL) {
                    Label("VIEW FULL POLICY ONLINE", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.beetlePurple)
                }
                .accessibilityHint("Opens the Stag Tune privacy policy in your browser")

                Text("Last updated August 6, 2026")
                    .font(.caption)
                    .foregroundStyle(Color.beetleIvory.opacity(0.48))
            }
            .padding(24)
        }
        .background(Color.beetleBlack.ignoresSafeArea())
        .foregroundStyle(Color.beetleIvory)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacySection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(Color.beetlePurple)
            Text(body)
                .font(.body)
                .foregroundStyle(Color.beetleIvory.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StagProView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var purchases: PurchaseManager
    let requestedFeature: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.beetleBlack, Color(red: 0.05, green: 0.025, blue: 0.07)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.beetleIvory.opacity(0.7))
                                .frame(width: 34, height: 34)
                                .background(Color.beetleIvory.opacity(0.06), in: Circle())
                        }
                        .accessibilityLabel("Close")
                    }
                    .padding(.top, 14)

                    StagLogoMark(color: Color.beetlePurple)
                        .frame(width: 34, height: 40)
                        .shadow(color: Color.beetlePurple.opacity(0.55), radius: 9)

                    VStack(spacing: 8) {
                        Text("TUNE IT YOUR WAY")
                            .font(.system(size: 20, weight: .semibold))
                            .tracking(2.4)
                            .foregroundStyle(Color.beetleIvory)
                        Text(requestedFeature.map { "Unlock \($0.lowercased()) and every Stag Pro control." }
                             ?? "Adjust precision, reference pitch, note direction, and notation.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.beetleIvory.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        benefit("Adjustable tuning tolerance")
                        benefit("Custom concert pitch")
                        benefit("Display direction and notation controls")
                        benefit("Future Stag Pro tuning tools")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 12) {
                        Button {
                            Task { await purchases.purchasePro() }
                        } label: {
                            HStack(spacing: 9) {
                                if purchases.isPurchasing {
                                    ProgressView().tint(Color.beetleIvory)
                                }
                                Text("UNLOCK FOREVER — \(purchases.displayPrice)")
                                    .font(.system(size: 14, weight: .bold))
                                    .tracking(1)
                            }
                            .foregroundStyle(Color.beetleIvory)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.beetlePurple, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(purchases.isPurchasing)

                        Button("Not now") { dismiss() }
                            .font(.subheadline)
                            .foregroundStyle(Color.beetleIvory.opacity(0.58))

                        Button("Restore Purchase") {
                            Task { await purchases.restorePurchases() }
                        }
                        .font(.caption)
                        .foregroundStyle(Color.beetleIvory.opacity(0.58))
                    }

                    if let message = purchases.message {
                        Text(message)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.beetleIvory.opacity(0.65))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .onChange(of: purchases.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    private func benefit(_ text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.beetlePurple)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.beetleIvory.opacity(0.82))
        }
    }
}
