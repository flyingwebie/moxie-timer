import SwiftUI

/// Shown at the top of the card when a newer GitHub release exists.
struct UpdateBanner: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        if let release = updater.latest {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.running)
                    Text("Moxie Timer \(release.version) is available")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Link("Notes", destination: release.pageURL)
                        .font(.system(size: 11))
                }
                HStack(spacing: 8) {
                    Button { Task { await updater.installUpdate() } } label: {
                        HStack(spacing: 6) {
                            if updater.state == .downloading || updater.state == .installing {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(buttonTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(updater.isBusy)
                }
                if case let .failed(message) = updater.state {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.running.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.running.opacity(0.25)))
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }

    private var buttonTitle: String {
        switch updater.state {
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        default: return "Install & relaunch"
        }
    }
}

/// Version info, manual check and auto-check toggle for Settings.
struct UpdatesSection: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Version \(updater.currentVersion)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    Task { await updater.check(userInitiated: true) }
                } label: {
                    HStack(spacing: 6) {
                        if updater.state == .checking { ProgressView().controlSize(.small) }
                        Text("Check for updates")
                    }
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(updater.isBusy)
            }

            if let status {
                Text(status.text)
                    .font(.system(size: 11))
                    .foregroundStyle(status.isError ? Theme.danger : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                .toggleStyle(.switch)
                .tint(Theme.navy)
                .controlSize(.small)
                .font(.system(size: 12))
        }
    }

    private var status: (text: String, isError: Bool)? {
        switch updater.state {
        case let .failed(message): return (message, true)
        case .upToDate: return ("You're on the latest version.", false)
        default:
            if let release = updater.latest { return ("Version \(release.version) is available — install it from the banner.", false) }
            return nil
        }
    }
}
