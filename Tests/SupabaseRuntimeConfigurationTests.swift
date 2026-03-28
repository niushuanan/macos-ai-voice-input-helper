import XCTest
@testable import PulseType

final class SupabaseRuntimeConfigurationTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "SupabaseRuntimeConfigurationTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        testDefaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testCurrentFallsBackToBundledDefaultsForPlaceholderEnvironmentValues() {
        let configuration = SupabaseRuntimeConfiguration.current(
            bundle: .main,
            environment: [
                SupabaseRuntimeConfiguration.urlInfoKey: "$(PULSETYPE_SUPABASE_URL)",
                SupabaseRuntimeConfiguration.anonKeyInfoKey: "$(PULSETYPE_SUPABASE_ANON_KEY)"
            ],
            userDefaults: testDefaults
        )

        XCTAssertEqual(configuration?.url.absoluteString, SupabaseRuntimeConfiguration.bundledURL)
        XCTAssertEqual(configuration?.anonKey, SupabaseRuntimeConfiguration.bundledAnonKey)
    }

    func testCurrentBuildsConfigurationFromEnvironmentValues() {
        let configuration = SupabaseRuntimeConfiguration.current(
            bundle: .main,
            environment: [
                SupabaseRuntimeConfiguration.urlInfoKey: "https://demo.supabase.co",
                SupabaseRuntimeConfiguration.anonKeyInfoKey: "anon-key"
            ],
            userDefaults: testDefaults
        )

        XCTAssertEqual(configuration?.url.absoluteString, "https://demo.supabase.co")
        XCTAssertEqual(configuration?.anonKey, "anon-key")
        XCTAssertEqual(
            configuration?.authStorageKey,
            SupabaseRuntimeConfiguration.authStorageKeyDefaultValue
        )
    }

    func testCurrentBuildsConfigurationFromUserDefaultsFallbackValues() {
        testDefaults.set("https://from-defaults.supabase.co", forKey: "SUPABASE_URL")
        testDefaults.set("anon-from-defaults", forKey: "SUPABASE_ANON_KEY")

        let configuration = SupabaseRuntimeConfiguration.current(
            bundle: .main,
            environment: [:],
            userDefaults: testDefaults
        )

        XCTAssertEqual(configuration?.url.absoluteString, "https://from-defaults.supabase.co")
        XCTAssertEqual(configuration?.anonKey, "anon-from-defaults")
    }

    func testCurrentFallsBackToBundledURLWhenEnvironmentURLInvalid() {
        let configuration = SupabaseRuntimeConfiguration.current(
            bundle: .main,
            environment: [
                SupabaseRuntimeConfiguration.urlInfoKey: "https:",
                SupabaseRuntimeConfiguration.anonKeyInfoKey: "anon-key"
            ],
            userDefaults: testDefaults
        )

        XCTAssertEqual(configuration?.url.absoluteString, SupabaseRuntimeConfiguration.bundledURL)
        XCTAssertEqual(configuration?.anonKey, "anon-key")
    }

    func testCurrentFallsBackToBundledURLWhenUserDefaultsURLInvalid() {
        testDefaults.set("https:", forKey: "SUPABASE_URL")
        testDefaults.set("anon-from-defaults", forKey: "SUPABASE_ANON_KEY")

        let configuration = SupabaseRuntimeConfiguration.current(
            bundle: .main,
            environment: [:],
            userDefaults: testDefaults
        )

        XCTAssertEqual(configuration?.url.absoluteString, SupabaseRuntimeConfiguration.bundledURL)
        XCTAssertEqual(configuration?.anonKey, "anon-from-defaults")
    }

    func testCurrentSkipsUserDefaultsInXCTestEnvironment() {
        testDefaults.set("https://from-defaults.supabase.co", forKey: "SUPABASE_URL")
        testDefaults.set("anon-from-defaults", forKey: "SUPABASE_ANON_KEY")

        let configuration = SupabaseRuntimeConfiguration.current(
            bundle: .main,
            environment: [
                "XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration"
            ],
            userDefaults: testDefaults
        )

        XCTAssertEqual(configuration?.url.absoluteString, SupabaseRuntimeConfiguration.bundledURL)
        XCTAssertEqual(configuration?.anonKey, SupabaseRuntimeConfiguration.bundledAnonKey)
    }
}
