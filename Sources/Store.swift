import Foundation
import SwiftUI

/// Single source of truth. Everything the UI shows and every write to a
/// controller goes through here, so there is exactly one observable object and
/// no nested-observation surprises in SwiftUI.
@MainActor
final class Store: ObservableObject {

    @Published var devices: [Device] = []
    @Published var groups: [DeviceGroup] = []
    @Published var discoveryMessage: String?

    /// Set by a menu bar row to ask the main window to jump to that target.
    /// Cleared once the window consumes it.
    @Published var requestedTarget: ControlTarget?
    @Published var isRefreshing = false

    private let discovery = Discovery()
    private let defaultsKey = "wled.state.v1"

    /// Pending brightness writes, keyed by host. Dragging a slider emits far more
    /// values than a controller should be asked to handle, so each host keeps one
    /// in-flight debounce task and only the last value is sent.
    private var brightnessTasks: [String: Task<Void, Never>] = [:]

    /// One live websocket per controller, so external changes (phone app,
    /// physical button, timer) show up without polling.
    private var liveConnections: [String: LiveConnection] = [:]

    /// While the user is dragging a slider we ignore pushed values for that
    /// host, otherwise a ~1/sec broadcast of the pre-drag value fights the drag.
    private var suppressPushUntil: [String: Date] = [:]

    private var healthTask: Task<Void, Never>?

    init() {
        load()
        for host in devices.map(\.host) { connectLive(host: host) }
        startDiscovery()
        Task { await refreshAll() }
        startHealthChecks()
    }

    // MARK: - Devices not in any group

    var ungroupedDevices: [Device] {
        let grouped = Set(groups.flatMap(\.memberHosts))
        return devices.filter { !grouped.contains($0.host) }
    }

    func devices(in group: DeviceGroup) -> [Device] {
        group.memberHosts.compactMap { host in devices.first { $0.host == host } }
    }

    private func index(of host: String) -> Int? {
        devices.firstIndex { $0.host == host }
    }

    /// Re-checks anything currently unreachable. Without this a single
    /// transient failure stuck permanently: the row stayed grey with an error
    /// until the user pressed Refresh, even once the controller was fine.
    private func startHealthChecks() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let ailing = self.devices.filter { !$0.reachable }.map(\.host)
                for host in ailing {
                    await self.refresh(host: host)
                }
            }
        }
    }

    // MARK: - Discovery

    func startDiscovery() {
        discovery.onFound = { [weak self] host, serviceName in
            guard let self else { return }
            self.add(host: host, name: serviceName)
        }
        discovery.onStateChange = { [weak self] running, message in
            // A Bonjour failure here is almost always the macOS Local Network
            // permission being denied, which is otherwise completely silent.
            self?.discoveryMessage = running
                ? nil
                : (message ?? "Discovery stopped. Check Local Network permission.")
        }
        discovery.start()
    }

    /// Adds a controller if it's new, then immediately fetches its state.
    func add(host: String, name: String) {
        if index(of: host) == nil {
            devices.append(Device(host: host, name: name))
            devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            save()
        }
        connectLive(host: host)
        Task { await refresh(host: host) }
    }

    private func connectLive(host: String) {
        guard liveConnections[host] == nil else { return }
        let connection = LiveConnection(host: host)
        connection.onPush = { [weak self] state in
            guard let self, let i = self.index(of: host) else { return }
            if let until = self.suppressPushUntil[host], until > Date() { return }
            self.devices[i].apply(push: state)
        }
        liveConnections[host] = connection
        connection.connect()
    }

    func remove(host: String) {
        liveConnections[host]?.disconnect()
        liveConnections.removeValue(forKey: host)
        devices.removeAll { $0.host == host }
        for i in groups.indices {
            groups[i].memberHosts.removeAll { $0 == host }
        }
        save()
    }

    // MARK: - Reads

    func refreshAll() async {
        isRefreshing = true
        // Controllers are independent, so fan out rather than walking the list.
        await withTaskGroup(of: Void.self) { group in
            for host in devices.map(\.host) {
                group.addTask { await self.refresh(host: host) }
            }
        }
        isRefreshing = false
    }

    func refresh(host: String) async {
        do {
            let response = try await WLEDClient.fetchAll(host: host)
            guard let i = index(of: host) else { return }
            devices[i].apply(response)
            save()   // the device may have told us a better name

            // Presets live on a separate endpoint and are optional; a
            // controller with none still works fine.
            if let presets = try? await WLEDClient.fetchPresets(host: host),
               let j = index(of: host) {
                devices[j].presets = presets
            }
        } catch {
            guard let i = index(of: host) else { return }
            devices[i].failureCount += 1
            devices[i].reachable = false
            // One dropped request is not worth shouting about; the status dot
            // already went grey. Only name the fault once it sticks.
            devices[i].lastError = devices[i].failureCount >= 3
                ? error.localizedDescription
                : nil
        }
    }

    // MARK: - Writes

    func setPower(host: String, on: Bool) {
        guard let i = index(of: host) else { return }
        devices[i].isOn = on                       // optimistic, for a responsive menu
        Task { await write(host: host, ["on": on]) }
    }

    func togglePower(host: String) {
        guard let i = index(of: host) else { return }
        setPower(host: host, on: !devices[i].isOn)
    }

    /// Debounced: safe to call on every slider tick.
    func setBrightness(host: String, _ value: Int) {
        guard let i = index(of: host) else { return }
        let clamped = max(0, min(255, value))
        devices[i].brightness = clamped
        suppressPushUntil[host] = Date().addingTimeInterval(1.5)

        brightnessTasks[host]?.cancel()
        brightnessTasks[host] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            await self?.write(host: host, ["bri": clamped])
        }
    }

    private func write(host: String, _ body: [String: Any]) async {
        do {
            try await WLEDClient.setState(host: host, body)
            if let i = index(of: host) {
                devices[i].reachable = true
                devices[i].lastError = nil
            }
        } catch {
            if let i = index(of: host) {
                devices[i].failureCount += 1
                devices[i].reachable = false
                devices[i].lastError = devices[i].failureCount >= 3
                    ? error.localizedDescription
                    : nil
            }
        }
    }

    func setEffect(host: String, _ index: Int) {
        guard let i = self.index(of: host) else { return }
        devices[i].effectIndex = index
        suppressPushUntil[host] = Date().addingTimeInterval(1.0)
        Task { await write(host: host, ["seg": [["fx": index]]]) }
    }

    func setPalette(host: String, _ index: Int) {
        guard let i = self.index(of: host) else { return }
        devices[i].paletteIndex = index
        suppressPushUntil[host] = Date().addingTimeInterval(1.0)
        Task { await write(host: host, ["seg": [["pal": index]]]) }
    }

    func setSpeed(host: String, _ value: Int) {
        guard let i = self.index(of: host) else { return }
        devices[i].speed = value
        debounce(host: host, ["seg": [["sx": value]]])
    }

    func setIntensity(host: String, _ value: Int) {
        guard let i = self.index(of: host) else { return }
        devices[i].intensity = value
        debounce(host: host, ["seg": [["ix": value]]])
    }

    func setColor(host: String, _ color: RGB) {
        guard let i = self.index(of: host) else { return }
        devices[i].color = color
        debounce(host: host, ["seg": [["col": colourSlots(host: host)]]])
    }

    func setWhite(host: String, _ value: Int) {
        guard let i = self.index(of: host) else { return }
        devices[i].white = max(0, min(255, value))
        debounce(host: host, ["seg": [["col": colourSlots(host: host)]]])
    }

    /// WLED's colour slot is one array, so RGB and white are written together.
    /// Sending three components to an RGBW strip would drop the white channel,
    /// which would make picking a colour silently switch the white LEDs off.
    private func colourSlots(host: String) -> [[Int]] {
        guard let i = self.index(of: host) else { return [] }
        var slot = devices[i].color.array
        if devices[i].supportsWhite { slot.append(devices[i].white) }
        return [slot]
    }

    /// Applying a preset can change anything, so re-read the device afterwards
    /// rather than trying to predict the resulting state.
    func applyPreset(host: String, _ id: Int) {
        suppressPushUntil[host] = nil
        Task {
            await write(host: host, ["ps": id])
            try? await Task.sleep(nanoseconds: 350_000_000)
            await refresh(host: host)
        }
    }

    /// Shared debounce for the continuous controls (brightness, speed,
    /// intensity, colour) so dragging never floods a controller.
    private func debounce(host: String, _ body: [String: Any]) {
        suppressPushUntil[host] = Date().addingTimeInterval(1.5)
        brightnessTasks[host]?.cancel()
        brightnessTasks[host] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            await self?.write(host: host, body)
        }
    }

    // MARK: - Groups

    func setPower(group: DeviceGroup, on: Bool) {
        for host in group.memberHosts { setPower(host: host, on: on) }
    }

    func setBrightness(group: DeviceGroup, _ value: Int) {
        for host in group.memberHosts { setBrightness(host: host, value) }
    }

    /// A group reads as "on" if anything in it is on, so the toggle turns the
    /// whole group off in one press rather than inverting each member.
    func isOn(group: DeviceGroup) -> Bool {
        devices(in: group).contains { $0.isOn }
    }

    func averageBrightness(group: DeviceGroup) -> Int {
        let members = devices(in: group)
        guard !members.isEmpty else { return 0 }
        return members.map(\.brightness).reduce(0, +) / members.count
    }

    func setEffect(group: DeviceGroup, _ index: Int) {
        for host in group.memberHosts { setEffect(host: host, index) }
    }

    func setPalette(group: DeviceGroup, _ index: Int) {
        for host in group.memberHosts { setPalette(host: host, index) }
    }

    func setColor(group: DeviceGroup, _ color: RGB) {
        for host in group.memberHosts { setColor(host: host, color) }
    }

    func setSpeed(group: DeviceGroup, _ value: Int) {
        for host in group.memberHosts { setSpeed(host: host, value) }
    }

    func setIntensity(group: DeviceGroup, _ value: Int) {
        for host in group.memberHosts { setIntensity(host: host, value) }
    }

    func setWhite(group: DeviceGroup, _ value: Int) {
        for host in group.memberHosts { setWhite(host: host, value) }
    }

    func applyPreset(group: DeviceGroup, _ id: Int) {
        for host in group.memberHosts { applyPreset(host: host, id) }
    }

    /// Effect and palette lists come from the firmware build, so any reachable
    /// member can stand in for the group when populating pickers.
    func representative(of group: DeviceGroup) -> Device? {
        let members = devices(in: group)
        return members.first { $0.reachable && !$0.effects.isEmpty } ?? members.first
    }

    func allOff() {
        for host in devices.map(\.host) { setPower(host: host, on: false) }
    }

    /// WLED restores each controller's own last brightness on power-on, so this
    /// deliberately sends only `on` and lets every device keep its own level.
    func allOn() {
        for host in devices.map(\.host) { setPower(host: host, on: true) }
    }

    func addGroup(name: String) {
        groups.append(DeviceGroup(name: name))
        save()
    }

    func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    func renameGroup(id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = name
        save()
    }

    func setMembership(host: String, group id: UUID, member: Bool) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        if member {
            // A device belongs to at most one group, so joining leaves the others.
            for j in groups.indices where j != i {
                groups[j].memberHosts.removeAll { $0 == host }
            }
            if !groups[i].memberHosts.contains(host) {
                groups[i].memberHosts.append(host)
            }
        } else {
            groups[i].memberHosts.removeAll { $0 == host }
        }
        save()
    }

    func group(containing host: String) -> DeviceGroup? {
        groups.first { $0.memberHosts.contains(host) }
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = PersistedState(
            devices: devices.map { .init(host: $0.host, name: $0.name) },
            groups: groups.map { .init(id: $0.id, name: $0.name, memberHosts: $0.memberHosts) }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        devices = snapshot.devices.map { Device(host: $0.host, name: $0.name) }
        groups = snapshot.groups.map {
            DeviceGroup(id: $0.id, name: $0.name, memberHosts: $0.memberHosts)
        }
    }
}
