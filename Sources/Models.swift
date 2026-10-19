import Foundation

// MARK: - Wire format (what WLED's /json endpoint returns)

/// `GET /json` returns state, info, effects and palettes in a single request,
/// which is the only call we need to fully populate a device.
struct WLEDFullResponse: Decodable {
    var state: WLEDState
    var info: WLEDInfo
    var effects: [String]
    var palettes: [String]
}

struct WLEDState: Decodable {
    var on: Bool
    var bri: Int
    var seg: [WLEDSegment]?

    /// WLED reports effect/palette per segment; we treat segment 0 as "the device".
    var primarySegment: WLEDSegment? { seg?.first }
}

struct WLEDSegment: Decodable {
    var fx: Int?
    var pal: Int?
    var sx: Int?
    var ix: Int?
    var col: [[Int]]?
}

struct WLEDInfo: Decodable {
    var name: String?
    var ver: String?
    var leds: WLEDLeds?
}

struct WLEDLeds: Decodable {
    var count: Int?
    /// Light capabilities bitfield: 0x01 RGB, 0x02 white channel, 0x04 CCT.
    var lc: Int?
    /// Same, per segment. Preferred over `lc`, which is all segments combined.
    var seglc: [Int]?
    /// Pre-0.13 firmware only; `lc` supersedes it.
    var rgbw: Bool?

    /// True when segment 0 drives separate white LEDs, so a white channel
    /// slider is meaningful rather than a control that does nothing.
    var hasWhiteChannel: Bool {
        if let capability = seglc?.first ?? lc { return capability & 0x02 != 0 }
        return rgbw ?? false
    }
}

// MARK: - App model

/// A single WLED controller. Value type: the store owns the array and is the
/// only source of truth, which keeps SwiftUI observation flat (no nested
/// ObservableObjects) and makes persistence trivial.
struct Device: Identifiable, Hashable {
    /// Host is the stable identity: an IP literal or a `*.local` name.
    var host: String
    var name: String

    var id: String { host }

    // Live state, refreshed from the device.
    var isOn: Bool = false
    var brightness: Int = 128
    var reachable: Bool = false
    var lastError: String?
    /// Consecutive failed refreshes. A single miss is noise — controllers drop
    /// a request when busy — so the UI only reports trouble once it persists.
    var failureCount: Int = 0

    // Capabilities, populated once per refresh.
    var effects: [String] = []
    var palettes: [String] = []
    var effectIndex: Int = 0
    var paletteIndex: Int = 0
    var speed: Int = 128
    var intensity: Int = 128
    var color: RGB = .white
    /// Separate white LEDs, where the strip has them.
    var supportsWhite: Bool = false
    var white: Int = 0
    var presets: [Preset] = []
    var ledCount: Int?
    var version: String?

    /// Applies a websocket push, which carries state but no name lists.
    mutating func apply(push state: WLEDState) {
        isOn = state.on
        brightness = state.bri
        applySegment(state.primarySegment)
        reachable = true
        lastError = nil
        failureCount = 0
    }

    private mutating func applySegment(_ segment: WLEDSegment?) {
        guard let segment else { return }
        effectIndex = segment.fx ?? effectIndex
        paletteIndex = segment.pal ?? paletteIndex
        speed = segment.sx ?? speed
        intensity = segment.ix ?? intensity
        if let slot = segment.col?.first, slot.count >= 3 {
            color = RGB(r: slot[0], g: slot[1], b: slot[2])
            if slot.count >= 4 { white = slot[3] }
        }
    }

    mutating func apply(_ response: WLEDFullResponse) {
        isOn = response.state.on
        brightness = response.state.bri
        effects = response.effects
        palettes = response.palettes
        applySegment(response.state.primarySegment)
        ledCount = response.info.leds?.count
        // Capability comes from info, which websocket pushes do not carry, so
        // it is only ever learned from a full refresh.
        supportsWhite = response.info.leds?.hasWhiteChannel ?? false
        version = response.info.ver
        // Prefer the device's own configured name once we've talked to it.
        if let reported = response.info.name, !reported.isEmpty {
            name = reported
        }
        reachable = true
        lastError = nil
        failureCount = 0
    }
}

extension Device {
    var effectName: String {
        effects.indices.contains(effectIndex) ? effects[effectIndex] : "—"
    }
    var paletteName: String {
        palettes.indices.contains(paletteIndex) ? palettes[paletteIndex] : "—"
    }
}

/// One saved preset slot on a controller.
struct Preset: Identifiable, Hashable {
    var id: Int
    var name: String
    var isPlaylist: Bool
}

/// An RGB colour as WLED stores it, kept as plain ints to avoid dragging
/// SwiftUI's `Color` into the model layer.
struct RGB: Hashable {
    var r: Int
    var g: Int
    var b: Int

    static let white = RGB(r: 255, g: 255, b: 255)

    var array: [Int] { [r, g, b] }
}

/// A named set of devices controlled together. Membership is by host so a
/// group survives a device being re-discovered.
struct DeviceGroup: Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var memberHosts: [String] = []
}

// MARK: - Persistence

/// Only user-authored facts are persisted. Live state is always re-fetched,
/// so a stale cache can never make the menu lie about what the lights are doing.
struct PersistedState: Codable {
    struct PDevice: Codable {
        var host: String
        var name: String
    }
    struct PGroup: Codable {
        var id: UUID
        var name: String
        var memberHosts: [String]
    }
    var devices: [PDevice] = []
    var groups: [PGroup] = []
}
