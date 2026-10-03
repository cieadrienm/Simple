import XCTest
@testable import SimpleRecorder

final class SettingsMigrationTests: XCTestCase {
    private var oldName: String!
    private var newName: String!
    private var old: UserDefaults!
    private var new: UserDefaults!

    override func setUp() {
        oldName = "migration-old-\(UUID().uuidString)"
        newName = "migration-new-\(UUID().uuidString)"
        old = UserDefaults(suiteName: oldName)
        new = UserDefaults(suiteName: newName)
    }

    override func tearDown() {
        old.removePersistentDomain(forName: oldName)
        new.removePersistentDomain(forName: newName)
    }

    func testSettingsAreMigratedOnce() {
        old.set("hevc", forKey: "RecorderCodec")
        old.set(25.0, forKey: "RecorderFPS")
        old.set("/Volumes/Show", forKey: "RecorderFolder")
        old.set("Depth", forKey: "RecorderName")
        old.set("something else", forKey: "NSWindow Frame MainWindow")

        SettingsMigration.migrate(from: oldName, to: new, domain: newName)
        XCTAssertEqual(new.string(forKey: "RecorderCodec"), "hevc")
        XCTAssertEqual(new.double(forKey: "RecorderFPS"), 25)
        XCTAssertEqual(new.string(forKey: "RecorderFolder"), "/Volumes/Show")
        XCTAssertEqual(new.string(forKey: "RecorderName"), "Depth")
        XCTAssertNil(new.persistentDomain(forName: newName)?["NSWindow Frame MainWindow"], "only the recorder's settings are copied")

        // Changed since in Simple Recorder: Simple Client's settings must not come back
        new.set("prores422", forKey: "RecorderCodec")
        old.set("h264", forKey: "RecorderCodec")
        SettingsMigration.migrate(from: oldName, to: new, domain: newName)
        XCTAssertEqual(new.string(forKey: "RecorderCodec"), "prores422")
    }

    func testDefaultsTheRecorderRegistersAreNotSettings() {
        // What any recorder in this process registers is answered by every UserDefaults: it must not be taken for
        // a setting made in Simple Recorder, nor copied as one made in Simple Client
        new.register(defaults: ["RecorderCodec": "h264", "RecorderName": ""])
        old.set("Depth", forKey: "RecorderName")
        SettingsMigration.migrate(from: oldName, to: new, domain: newName)
        XCTAssertEqual(new.string(forKey: "RecorderName"), "Depth")
        XCTAssertNil(new.persistentDomain(forName: newName)?["RecorderCodec"])
    }

    func testNothingToMigrateIsNotAnError() {
        SettingsMigration.migrate(from: oldName, to: new, domain: newName)
        XCTAssertNil(new.persistentDomain(forName: newName)?["RecorderCodec"])
    }

    func testSettingsAlreadyMadeInSimpleRecorderAreKept() {
        new.set("prores4444", forKey: "RecorderCodec")
        old.set("hevc", forKey: "RecorderCodec")
        old.set("Depth", forKey: "RecorderName")
        SettingsMigration.migrate(from: oldName, to: new, domain: newName)
        XCTAssertEqual(new.string(forKey: "RecorderCodec"), "prores4444")
        XCTAssertEqual(new.string(forKey: "RecorderName"), "Depth")
    }
}
