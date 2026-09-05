import Testing
import Foundation
@testable import AirRefresh

/// `devicectl list devices --json-output` reports simulators, Macs and iPhones
/// in one blob. Only one of those is something we can install onto.
struct DeviceParsingTests {

    private let report = """
    {
      "info": { "outcome": "success" },
      "result": {
        "devices": [
          {
            "identifier": "00001111-AAAA-BBBB-CCCC-222233334444",
            "connectionProperties": { "pairingState": "paired", "transportType": "localNetwork" },
            "deviceProperties": { "name": "Nikolaus' iPhone", "osVersionNumber": "26.1" },
            "hardwareProperties": {
              "udid": "00008140-000A1B2C3D4E001C",
              "marketingName": "iPhone 16 Pro",
              "platform": "iOS",
              "reality": "physical"
            }
          },
          {
            "identifier": "SIMULATOR-1",
            "connectionProperties": { "pairingState": "paired", "transportType": "wired" },
            "deviceProperties": { "name": "iPhone 17 Pro", "osVersionNumber": "26.0" },
            "hardwareProperties": {
              "udid": "SIM-UDID", "marketingName": "iPhone 17 Pro",
              "platform": "iOS", "reality": "simulator"
            }
          },
          {
            "identifier": "THIS-MAC",
            "connectionProperties": { "pairingState": "paired", "transportType": "wired" },
            "deviceProperties": { "name": "Nikolaus' MacBook Pro" },
            "hardwareProperties": {
              "udid": "MAC-UDID", "marketingName": "MacBook Pro",
              "platform": "macOS", "reality": "physical"
            }
          }
        ]
      }
    }
    """

    @Test func onlyPhysicalIOSDevicesSurvive() {
        let devices = DeviceManager.parse(Data(report.utf8))
        #expect(devices.count == 1)
        #expect(devices.first?.name == "Nikolaus' iPhone")
    }

    /// `xcodebuild -destination` wants the hardware UDID; `devicectl --device`
    /// wants the CoreDevice identifier. Mixing them up fails confusingly, so
    /// each is carried separately.
    @Test func bothIdentifiersAreKept() {
        let device = DeviceManager.parse(Data(report.utf8)).first
        #expect(device?.identifier == "00001111-AAAA-BBBB-CCCC-222233334444")
        #expect(device?.udid == "00008140-000A1B2C3D4E001C")
    }

    @Test func theSubtitleReadsLikeSomethingAHumanWrote() {
        let device = DeviceManager.parse(Data(report.utf8)).first
        #expect(device?.subtitle == "iPhone 16 Pro · iOS 26.1 · Wi-Fi")
    }

    @Test func malformedOutputYieldsNoDevicesRatherThanCrashing() {
        #expect(DeviceManager.parse(Data("not json".utf8)).isEmpty)
        #expect(DeviceManager.parse(Data("{}".utf8)).isEmpty)
        #expect(DeviceManager.parse(Data(#"{"result":{}}"#.utf8)).isEmpty)
    }
}
