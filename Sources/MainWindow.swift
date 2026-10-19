import SwiftUI

/// What the main window is currently controlling. Groups and single devices
/// share one detail pane, so the window has no duplicated control code.
enum ControlTarget: Hashable {
    case device(String)      // host
    case group(UUID)
}

/// The full-control surface: effects, palettes, colour and per-effect
/// parameters, laid out with room to breathe. The menu bar stays for quick
/// power and brightness.
struct MainWindowView: View {
    @ObservedObject var store: Store
    @State private var selection: ControlTarget?
    @State private var showingAdd = false
    @State private var newHost = ""
    @State private var renameBuffer = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            if let selection, let target = Target(store: store, target: selection) {
                DetailView(store: store, selection: selection, target: target)
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "lightbulb",
                    description: Text("Pick a group or a controller on the left.")
                )
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .onAppear(perform: selectFirstIfNeeded)
        .onChange(of: store.devices.count) { _, _ in selectFirstIfNeeded() }
        .onChange(of: store.groups.count) { _, _ in selectFirstIfNeeded() }
        .onChange(of: store.requestedTarget) { _, requested in
            guard let requested else { return }
            selection = requested
            store.requestedTarget = nil
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if !store.groups.filter({ !$0.memberHosts.isEmpty }).isEmpty {
                Section("Groups") {
                    ForEach(store.groups) { group in
                        if !group.memberHosts.isEmpty {
                            Label(group.name, systemImage: "rectangle.3.group")
                                .tag(ControlTarget.group(group.id))
                        }
                    }
                }
            }

            Section("Controllers") {
                ForEach(store.devices) { device in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(device.reachable ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(device.name)
                    }
                    .tag(ControlTarget.device(device.host))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                HStack {
                    Button("All On") { store.allOn() }
                        .controlSize(.small)
                    Button("All Off") { store.allOff() }
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
                }

                // Stacked, not side by side: the sidebar is ~190pt and two
                // labelled buttons on one row truncate to "Add Contr..." and
                // "New Gro...".
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Controller", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)

                Group {
                    Button {
                        // Created immediately and selected, so the detail pane
                        // is where it gets named — no modal just to type a word.
                        let name = "New Group"
                        store.addGroup(name: name)
                        if let group = store.groups.last {
                            selection = .group(group.id)
                        }
                    } label: {
                        Label("New Group", systemImage: "rectangle.3.group")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .controlSize(.small)
                }
            }
            .padding(8)
        }
        .sheet(isPresented: $showingAdd) {
            AddControllerSheet(host: $newHost) { host in
                store.add(host: host, name: host)
                selection = .device(host)
            }
        }
    }

    private func selectFirstIfNeeded() {
        // A deleted group or removed controller leaves a dangling selection.
        if let current = selection, Target(store: store, target: current) == nil {
            selection = nil
        }
        guard selection == nil else { return }
        if let group = store.groups.first(where: { !$0.memberHosts.isEmpty }) {
            selection = .group(group.id)
        } else if let device = store.devices.first {
            selection = .device(device.host)
        }
    }
}

// MARK: - Target resolution

/// Resolves a `ControlTarget` into a display name, a device to read current
/// values from, and a set of writes. A group reads from any reachable member —
/// effect and palette lists come from the firmware build, so any member can
/// stand in — and fans writes out to all of them.
@MainActor
private struct Target {
    let title: String
    let subtitle: String
    let source: Device
    let isOn: Bool
    let brightness: Int

    let setPower: @MainActor (Bool) -> Void
    let setBrightness: @MainActor (Int) -> Void
    let setEffect: @MainActor (Int) -> Void
    let setPalette: @MainActor (Int) -> Void
    let setSpeed: @MainActor (Int) -> Void
    let setIntensity: @MainActor (Int) -> Void
    let setColor: @MainActor (RGB) -> Void
    let setWhite: @MainActor (Int) -> Void
    let applyPreset: @MainActor (Int) -> Void

    init?(store: Store, target: ControlTarget) {
        switch target {
        case .device(let host):
            guard let device = store.devices.first(where: { $0.host == host }) else { return nil }
            title = device.name
            var parts = [device.host]
            if let version = device.version { parts.append("v\(version)") }
            if let count = device.ledCount { parts.append("\(count) LEDs") }
            if !device.reachable { parts.append("unreachable") }
            subtitle = parts.joined(separator: " · ")
            source = device
            isOn = device.isOn
            brightness = device.brightness

            setPower      = { store.setPower(host: host, on: $0) }
            setBrightness = { store.setBrightness(host: host, $0) }
            setEffect     = { store.setEffect(host: host, $0) }
            setPalette    = { store.setPalette(host: host, $0) }
            setSpeed      = { store.setSpeed(host: host, $0) }
            setIntensity  = { store.setIntensity(host: host, $0) }
            setColor      = { store.setColor(host: host, $0) }
            setWhite      = { store.setWhite(host: host, $0) }
            applyPreset   = { store.applyPreset(host: host, $0) }

        case .group(let id):
            guard let group = store.groups.first(where: { $0.id == id }),
                  let representative = store.representative(of: group)
            else { return nil }
            let members = store.devices(in: group)
            title = group.name
            subtitle = "\(members.count) controller\(members.count == 1 ? "" : "s")"
            source = representative
            isOn = store.isOn(group: group)
            brightness = store.averageBrightness(group: group)

            setPower      = { store.setPower(group: group, on: $0) }
            setBrightness = { store.setBrightness(group: group, $0) }
            setEffect     = { store.setEffect(group: group, $0) }
            setPalette    = { store.setPalette(group: group, $0) }
            setSpeed      = { store.setSpeed(group: group, $0) }
            setIntensity  = { store.setIntensity(group: group, $0) }
            setColor      = { store.setColor(group: group, $0) }
            setWhite      = { store.setWhite(group: group, $0) }
            applyPreset   = { store.applyPreset(group: group, $0) }
        }
    }
}

// MARK: - Detail pane

private struct DetailView: View {
    @ObservedObject var store: Store
    let selection: ControlTarget
    let target: Target

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                colourSection
                Divider()
                effectSection
                if !target.source.presets.isEmpty {
                    Divider()
                    presetSection
                }
                Divider()
                manageSection
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title).font(.title2.weight(.semibold))
                    Text(target.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { target.isOn },
                    set: { target.setPower($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            HStack(spacing: 10) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(target.brightness) },
                        set: { target.setBrightness(Int($0)) }
                    ),
                    in: 0...255
                )
                .disabled(!target.isOn)
                Text("\(Int(Double(target.brightness) / 255 * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Colour")

            HStack(alignment: .top, spacing: 20) {
                ColorWheel(color: target.source.color) { target.setColor($0) }
                    .frame(width: 180, height: 180)

                VStack(alignment: .leading, spacing: 10) {
                    // Swatches stay as the fast path; the wheel is for hunting.
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(30), spacing: 7), count: 6),
                        spacing: 7
                    ) {
                        ForEach(RGB.swatches, id: \.self) { swatch in
                            Button {
                                target.setColor(swatch)
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(swatch.color)
                                    .frame(height: 30)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(
                                                swatch == target.source.color ? Color.primary : Color.secondary.opacity(0.25),
                                                lineWidth: swatch == target.source.color ? 2.5 : 0.5
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 215)

                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(target.source.color.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                            )
                        Text(String(
                            format: "#%02X%02X%02X",
                            target.source.color.r, target.source.color.g, target.source.color.b
                        ))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    }

                    Text("Dim with the brightness slider — the wheel sets hue and saturation only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 215, alignment: .leading)
                }
            }

            // Only strips with separate white LEDs get this; on an RGB strip
            // the channel does not exist and the slider would do nothing.
            if target.source.supportsWhite {
                HStack(spacing: 10) {
                    Text("White")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(target.source.white) },
                            set: { target.setWhite(Int($0)) }
                        ),
                        in: 0...255
                    )
                    Text("\(target.source.white)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .frame(maxWidth: 520)
            }
        }
    }

    private var effectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Effect")

            HStack(spacing: 12) {
                Picker("Effect", selection: Binding(
                    get: { target.source.effectIndex },
                    set: { target.setEffect($0) }
                )) {
                    ForEach(Array(target.source.effects.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                .frame(maxWidth: 260)

                Picker("Palette", selection: Binding(
                    get: { target.source.paletteIndex },
                    set: { target.setPalette($0) }
                )) {
                    ForEach(Array(target.source.palettes.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                .frame(maxWidth: 260)
            }

            // Solid ignores both, so showing the sliders would just look broken.
            if target.source.effectIndex != 0 {
                labelledSlider("Speed", value: target.source.speed, set: target.setSpeed)
                labelledSlider("Intensity", value: target.source.intensity, set: target.setIntensity)
            } else {
                Text("Solid has no speed or intensity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Presets")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(target.source.presets) { preset in
                    Button {
                        target.applyPreset(preset.id)
                    } label: {
                        Label(
                            preset.name,
                            systemImage: preset.isPlaylist ? "list.and.film" : "star"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .controlSize(.regular)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    // MARK: - Manage

    /// Device and group management lives here rather than in a separate
    /// Settings window: you configure the thing you are already looking at.
    @ViewBuilder
    private var manageSection: some View {
        switch selection {
        case .group(let id):  groupManagement(id)
        case .device(let host): deviceManagement(host)
        }
    }

    @ViewBuilder
    private func groupManagement(_ id: UUID) -> some View {
        if let group = store.groups.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Group")

                HStack(spacing: 8) {
                    Text("Name").font(.callout).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    TextField("Group name", text: Binding(
                        get: { group.name },
                        set: { store.renameGroup(id: id, to: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                }

                Text("Members").font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.devices) { device in
                        Toggle(isOn: Binding(
                            get: { group.memberHosts.contains(device.host) },
                            set: { store.setMembership(host: device.host, group: id, member: $0) }
                        )) {
                            HStack(spacing: 6) {
                                Text(device.name)
                                Text(device.host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let other = store.group(containing: device.host),
                                   other.id != id {
                                    Text("in \(other.name)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                Text("A controller belongs to one group at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    store.removeGroup(id: id)
                } label: {
                    Label("Delete Group", systemImage: "trash")
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    @ViewBuilder
    private func deviceManagement(_ host: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Controller")

            HStack(spacing: 8) {
                Text("Group").font(.callout).foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(
                    get: { store.group(containing: host)?.id },
                    set: { newGroup in
                        for group in store.groups {
                            store.setMembership(
                                host: host,
                                group: group.id,
                                member: group.id == newGroup
                            )
                        }
                    }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "http://\(host)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Web UI", systemImage: "safari")
                }

                Button(role: .destructive) {
                    store.remove(host: host)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }

            Text("Removing a controller only forgets it here. Discovery will find it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func labelledSlider(
        _ title: String,
        value: Int,
        set: @escaping @MainActor (Int) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Slider(
                value: Binding(get: { Double(value) }, set: { set(Int($0)) }),
                in: 0...255
            )
            Text("\(value)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .frame(maxWidth: 520)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }
}


/// Manual entry, for controllers Bonjour cannot reach — a different subnet,
/// or mDNS blocked on the network.
private struct AddControllerSheet: View {
    @Binding var host: String
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Controller").font(.headline)

            TextField("IP address or hostname", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(commit)

            Text("For example 192.168.1.50, or wled-desk.local")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
    }

    private var trimmed: String {
        host.trimmingCharacters(in: .whitespaces)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        add(trimmed)
        host = ""
        dismiss()
    }
}
