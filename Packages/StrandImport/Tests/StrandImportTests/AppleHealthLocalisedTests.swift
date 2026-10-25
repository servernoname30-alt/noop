import XCTest
@testable import StrandImport

/// Personal build: an export.zip from a non-English iPhone names its main file in the device language.
final class AppleHealthLocalisedTests: XCTestCase {
    func testPicksTheLocalisedExportBesideItsClinicalTwin() {
        let russian = ["экспорт_данных_apple_health/экспорт.xml", "экспорт_данных_apple_health/экспорт_cda.xml",
                       "экспорт_данных_apple_health/workout-routes/route_2026-10-24_8.05am.gpx"]
        XCTAssertEqual(AppleHealthImporter.soleLocalisedExportEntry(russian), "экспорт_данных_apple_health/экспорт.xml")
        XCTAssertEqual(AppleHealthImporter.soleLocalisedExportEntry(["экспорт.xml"]), "экспорт.xml")
    }

    func testRefusesToGuessAmongSeveralOrDeepFiles() {
        XCTAssertNil(AppleHealthImporter.soleLocalisedExportEntry(["a/один.xml", "a/два.xml"]))
        XCTAssertNil(AppleHealthImporter.soleLocalisedExportEntry(["a/b/экспорт.xml"]))
        XCTAssertNil(AppleHealthImporter.soleLocalisedExportEntry(["a/экспорт_cda.xml"]))
    }
}
