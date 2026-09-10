import XCTest
@testable import JarvisCore

final class MemoryRequestTests: XCTestCase {
    func testRecognisesExplicitRequests() {
        XCTAssertEqual(MemoryRequest.fact(in: "Remember that I prefer concise replies with no preamble."),
                       "I prefer concise replies with no preamble.")
        XCTAssertEqual(MemoryRequest.fact(in: "remember I am vegetarian"), "I am vegetarian.")
        XCTAssertEqual(MemoryRequest.fact(in: "Please remember that my landlord is Meera."),
                       "my landlord is Meera.")
        XCTAssertEqual(MemoryRequest.fact(in: "Remember: my flight is always the early one."),
                       "my flight is always the early one.")
        XCTAssertEqual(MemoryRequest.fact(in: "  Remember that I like tea  "), "I like tea.")
    }
    func testIgnoresQuestionsAndReminiscing() {
        XCTAssertNil(MemoryRequest.fact(in: "Do you remember my landlord's name?"))
        XCTAssertNil(MemoryRequest.fact(in: "Remember when we discussed the lease?"))
        XCTAssertNil(MemoryRequest.fact(in: "Remember what I said last week?"))
        XCTAssertNil(MemoryRequest.fact(in: "Can you remember things?"))
    }
    func testAReminderIsNotAMemory() {
        // "Remember to X" is a Reminders request; create_reminder should handle it.
        XCTAssertNil(MemoryRequest.fact(in: "Remember to call the dentist at 4pm."))
    }
    func testIgnoresUnrelatedMessages() {
        XCTAssertNil(MemoryRequest.fact(in: "What is on my calendar tomorrow?"))
        XCTAssertNil(MemoryRequest.fact(in: "I will remember that myself."))
        XCTAssertNil(MemoryRequest.fact(in: "remember"))
        XCTAssertNil(MemoryRequest.fact(in: ""))
    }
}
