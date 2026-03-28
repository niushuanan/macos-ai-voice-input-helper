import XCTest
@testable import PulseType

final class SupabaseRuntimeConfigurationTests: XCTestCase {
    func testCurrentReturnsNilForPlaceholderEnvironmentValues() {
        let configuration = SupabaseRuntimeConfiguration.current(
            bundle: .main,
            environment: [
                SupabaseRuntimeConfiguration.urlInfoKey: "$(PULSETYPE_SUPABASE_URL)",
                SupabaseRuntimeConfiguration.anonKeyInfoKey: "$(PULSETYPE_SUPABASE_ANON_KEY)"
            ]
        )

        XCTAssertNil(configuration)
    }

    func testCurrentBuildsConfigurationFromEnvironmentValues() {
        let configuration = SupabaseRuntimeConfiguration.current(
            bundle: .main,
            environment: [
                SupabaseRuntimeConfiguration.urlInfoKey: "https://demo.supabase.co",
                SupabaseRuntimeConfiguration.anonKeyInfoKey: "anon-key"
            ]
        )

        XCTAssertEqual(configuration?.url.absoluteString, "https://demo.supabase.co")
        XCTAssertEqual(configuration?.anonKey, "anon-key")
        XCTAssertEqual(
            configuration?.authStorageKey,
            SupabaseRuntimeConfiguration.authStorageKeyDefaultValue
        )
    }
}
