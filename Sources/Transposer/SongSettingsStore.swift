import Foundation

struct SongSetting: Codable, Equatable {
    var semitones: Int
    var karaoke: Bool
}

/// Persists per-track transpose/karaoke settings keyed by Spotify track ID.
final class SongSettingsStore {
    private let defaultsKey = "songSettings.v1"
    private var map: [String: SongSetting]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: SongSetting].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    func setting(for id: String) -> SongSetting? { map[id] }

    func save(_ setting: SongSetting, for id: String) {
        map[id] = setting
        persist()
    }

    func remove(for id: String) {
        guard map.removeValue(forKey: id) != nil else { return }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
