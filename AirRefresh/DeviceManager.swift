import Foundation
import Observation

/// Wraps `xcrun devicectl list devices` and keeps a list of physical devices.
@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [Device] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    private var inFlight: Task<Void, Never>?

    /// Asks `devicectl` again. A caller arriving while a scan is already
    /// running waits for that scan instead of returning at once: the scheduler
    /// used to come back immediately, take the still-empty list as the truth,
    /// and decide the phone was not there.
    func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let scan = Task { await self.scan() }
        inFlight = scan
        await scan.value
        inFlight = nil
    }

    private func scan() async {
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        let jsonPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("airrefresh-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonPath) }

        do {
            let result = try await Shell.capture("/usr/bin/xcrun", [
                "devicectl", "list", "devices",
                "--timeout", "15",
                "--quiet",
                "--json-output", jsonPath.path
            ])
            guard let data = try? Data(contentsOf: jsonPath) else {
                lastError = result.exitCode == 0
                    ? "devicectl returned no data."
                    : "devicectl failed (exit \(result.exitCode))."
                return
            }
            devices = Self.parse(data)
            if devices.isEmpty {
                lastError = "No paired devices found. Connect your iPhone or make sure it is on the same Wi-Fi."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Pulls the fields we need out of devicectl's JSON report.
    nonisolated static func parse(_ data: Data) -> [Device] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let raw = result["devices"] as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry -> Device? in
            guard let identifier = entry["identifier"] as? String else { return nil }
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = entry["connectionProperties"] as? [String: Any] ?? [:]

            // Simulators and Macs are not what this tool is for.
            let platform = hardware["platform"] as? String ?? ""
            let reality = hardware["reality"] as? String ?? ""
            guard platform.hasPrefix("iOS"), reality == "physical" else { return nil }

            return Device(
                identifier: identifier,
                udid: hardware["udid"] as? String ?? identifier,
                name: properties["name"] as? String ?? hardware["marketingName"] as? String ?? "Unknown device",
                model: hardware["marketingName"] as? String ?? "",
                osVersion: properties["osVersionNumber"] as? String ?? "",
                isPaired: (connection["pairingState"] as? String) == "paired",
                transport: connection["transportType"] as? String ?? ""
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func device(withIdentifier identifier: String) -> Device? {
        devices.first { $0.identifier == identifier }
    }
}
