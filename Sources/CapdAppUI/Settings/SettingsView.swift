import KeyboardShortcuts
import SwiftUI

package struct SettingsView: View {
    @Bindable var settings: AppSettings

    package init(settings: AppSettings) {
        self.settings = settings
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Hotkeys") {
                row("Capture") {
                    KeyboardShortcuts.Recorder("", name: .capture)
                }
                hairline
                row("Note last capture") {
                    KeyboardShortcuts.Recorder("", name: .annotate)
                }
                hairline
                row("Search") {
                    KeyboardShortcuts.Recorder("", name: .search)
                }
                hairline
                row("Open HUD reminder") {
                    KeyboardShortcuts.Recorder("", name: .openReminder)
                }
            }
            section("Network") {
                row("Load website icons") {
                    toggle($settings.websiteIconsEnabled)
                }
                Text(
                    "This Mac’s background agent requests only the saved HTTPS host’s /favicon.ico, including for links saved on your connected devices. Page paths, queries, source text and notes are excluded. It sends no cookies or credentials and follows no redirects. Synced icons remain available when this is off."
                ).font(.caption).foregroundStyle(Theme.textSecondary)
                if let issue = settings.websiteIconIssue {
                    Text(issue).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                hairline
                row("Fetch page content for link captures") {
                    toggle($settings.fetchesPageBodies)
                }
                hairline
                row("Check weekly for a new version") {
                    toggle($settings.checksForUpdates)
                }
            }
            section("Context") {
                row("Contextual reminders") {
                    toggle($settings.contextualRemindersEnabled)
                }
                Text(
                    "Uses Accessibility to check the visible browser page locally after you pause. "
                        + "Links opened from Capd include capd.jxd.dev attribution."
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            section("Intelligence") {
                row("Find titles and manual tags in system search") {
                    toggle($settings.systemSearchEnabled)
                }
                Text("Indexed entries receive a 30-day expiration and renew while capd is running.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if let issue = settings.systemSearchIssue {
                    Text(issue).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                hairline
                row("Auto-tag captures on device") {
                    toggle($settings.autoTagsCaptures)
                        .disabled(settings.autoTagsUnavailableReason != nil)
                }
                hairline
                row("Regenerate automatic tags") {
                    Button("Retag All", action: settings.requestRetagging)
                        .controlSize(.small)
                        .disabled(
                            !settings.autoTagsCaptures
                                || settings.autoTagsUnavailableReason != nil)
                }
                if let reason = settings.autoTagsUnavailableReason {
                    Text(reason)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.mono(9.5))
                .kerning(1)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 12)
            VStack(spacing: 0) {
                rows()
            }
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1))
        }
    }

    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding.animation(Theme.quickSpring))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.success)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .padding(.leading, 12)
    }
}

#Preview {
    let defaults = UserDefaults(suiteName: "dev.jxd.capd.preview")!
    SettingsView(settings: AppSettings(defaults: defaults))
}
