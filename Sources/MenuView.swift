import SwiftUI
import AppKit

/// The menu bar popover: quick control only — All Off, power, brightness and
/// one-tap presets. Effects, palettes and colour live in the main window, where
/// there is room to lay them out.
struct MenuView: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    /// Measured height of the device list.
    ///
    /// A `MenuBarExtra` popover sizes itself to its content, so it proposes no
    /// height downward. A `ScrollView` asked to size against no proposal
    /// collapses to almost nothing — which silently hid the entire device list
    /// while the header and footer kept rendering normally. So we measure the
    /// content and pin the scroll view to it, capped so long lists still scroll.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if store.devices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        let activeGroups = store.groups.filter { !$0.memberHosts.isEmpty }

                        if !activeGroups.isEmpty {
                            sectionHeader("Groups")
                            ForEach(activeGroups) { group in
                                GroupRow(store: store, group: group)
                            }
                        }

                        let loose = store.ungroupedDevices
                        if !loose.isEmpty {
                            sectionHeader(activeGroups.isEmpty ? "Controllers" : "Ungrouped")
                            ForEach(loose) { device in
                                DeviceRow(store: store, device: device)
                            }
                        }

                        // Groups are the fastest way to use this app, so say so
                        // rather than leaving the section silently absent.
                        if activeGroups.isEmpty && store.devices.count > 1 {
                            Button("Group these controllers…") { openWindow(id: "main") }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ListHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                }
                .frame(height: min(max(listHeight, 1), 400))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            }

            if let message = store.discoveryMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    private var header: some View {
        HStack {
            Text("WLED").font(.headline)
            Spacer()
            Button {
                store.allOn()
            } label: {
                Label("All On", systemImage: "power")
            }
            .controlSize(.small)
            .disabled(store.devices.isEmpty)

            Button {
                store.allOff()
            } label: {
                Label("All Off", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.devices.isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No controllers found")
                .font(.subheadline.weight(.medium))
            Text("Discovery uses Bonjour. If your lights are on a different subnet, open the window and add them by IP.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "main")
            } label: {
                Label("Open WLED", systemImage: "macwindow")
            }
            .controlSize(.small)

            Spacer()

            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(store.isRefreshing)
            .help("Refresh")

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}

/// One group: a single toggle and slider driving every member together.
private struct GroupRow: View {
    @ObservedObject var store: Store
    let group: DeviceGroup
    @Environment(\.openWindow) private var openWindow


    /// Hands the main window a target, then brings it up on that page.
    private func open(_ target: ControlTarget) {
        store.requestedTarget = target
        openWindow(id: "main")
    }

    var body: some View {
        let isOn = store.isOn(group: group)
        let members = store.devices(in: group)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(.secondary)
                Text(group.name).font(.subheadline.weight(.semibold))
                Spacer()
                RowActions(
                    presets: store.representative(of: group)?.presets ?? [],
                    browserTargets: members,
                    applyPreset: { store.applyPreset(group: group, $0) },
                    openInWindow: { open(.group(group.id)) }
                )
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { store.setPower(group: group, on: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if isOn {
                BrightnessSlider(
                    value: Binding(
                        get: { Double(store.averageBrightness(group: group)) },
                        set: { store.setBrightness(group: group, Int($0)) }
                    )
                )

                QuickSwatchStrip(
                    current: store.representative(of: group)?.color ?? .white
                ) { colour in
                    store.setColor(group: group, colour)
                }
            }

            // Members stay individually reachable without leaving the group.
            ForEach(members) { device in
                HStack(spacing: 6) {
                    Circle()
                        .fill(device.reachable ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text(device.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { device.isOn },
                        set: { store.setPower(host: device.host, on: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .padding(.leading, 14)
            }
        }
    }
}

/// One ungrouped controller.
private struct DeviceRow: View {
    @ObservedObject var store: Store
    let device: Device
    @Environment(\.openWindow) private var openWindow


    /// Hands the main window a target, then brings it up on that page.
    private func open(_ target: ControlTarget) {
        store.requestedTarget = target
        openWindow(id: "main")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(device.reachable ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(device.name).font(.subheadline)
                Spacer()
                RowActions(
                    presets: device.presets,
                    browserTargets: [device],
                    applyPreset: { store.applyPreset(host: device.host, $0) },
                    openInWindow: { open(.device(device.host)) }
                )
                Toggle("", isOn: Binding(
                    get: { device.isOn },
                    set: { store.setPower(host: device.host, on: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!device.reachable)
            }

            // A brightness slider and colour swatches on a dark light are
            // controls for something you cannot see, so the row collapses to
            // just its name and toggle when it is off.
            if device.isOn && device.reachable {
                BrightnessSlider(
                    value: Binding(
                        get: { Double(device.brightness) },
                        set: { store.setBrightness(host: device.host, Int($0)) }
                    )
                )

                QuickSwatchStrip(current: device.color) { colour in
                    store.setColor(host: device.host, colour)
                }
            }

            // The grey dot already carries "not working". A red HTTP status
            // code is noise to anyone who is not debugging it, so the detail
            // moves to the tooltip.
            if !device.reachable, let error = device.lastError {
                Text("Not responding")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(error)
            }
        }
    }
}

/// Carries the measured height of the device list up to the scroll view.
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Overflow for what the row itself cannot already do in one click. Power and
/// brightness are deliberately absent — the toggle and slider cover both — so
/// this is only presets and the jump to the main window.
private struct RowActions: View {
    let presets: [Preset]
    /// Controllers whose own web UI this row can open. A device offers one; a
    /// group offers each member, since every controller serves its own page.
    let browserTargets: [Device]
    let applyPreset: @MainActor (Int) -> Void
    let openInWindow: @MainActor () -> Void

    var body: some View {
        Menu {
            if !presets.isEmpty {
                Menu("Presets") {
                    ForEach(presets) { preset in
                        Button {
                            applyPreset(preset.id)
                        } label: {
                            Label(
                                preset.name,
                                systemImage: preset.isPlaylist ? "list.and.film" : "star"
                            )
                        }
                    }
                }
                Divider()
            }

            Button("Open in Window") { openInWindow() }

            if browserTargets.count == 1, let device = browserTargets.first {
                Button("Open in Browser") { Self.openWeb(device.host) }
            } else if browserTargets.count > 1 {
                Menu("Open in Browser") {
                    ForEach(browserTargets) { device in
                        Button(device.name) { Self.openWeb(device.host) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Quick actions")
    }

    /// WLED serves its own UI over plain HTTP on port 80.
    @MainActor
    private static func openWeb(_ host: String) {
        guard let url = URL(string: "http://\(host)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One-click colours, inline in the row. Quick actions that need a second
/// click to reach are not quick, so these sit alongside the toggle rather than
/// inside the overflow menu.
private struct QuickSwatchStrip: View {
    let current: RGB
    let pick: @MainActor (RGB) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RGB.quickSwatches, id: \.self) { swatch in
                Button {
                    pick(swatch)
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(swatch.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    swatch == current ? Color.primary : Color.secondary.opacity(0.3),
                                    lineWidth: swatch == current ? 2 : 0.5
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct BrightnessSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.min").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $value, in: 0...255)
                .controlSize(.mini)
            Text("\(Int(value / 255 * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}
