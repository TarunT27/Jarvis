import XCTest
@testable import JarvisCore

final class ComputerPolicyTests:XCTestCase {
    let instant=Date(timeIntervalSince1970:1_000)
    func testSessionCannotBeBorrowedOrRestartedWhileActive() throws {
        let policy=ComputerSessionPolicy();let task=UUID()
        let session=try policy.start(taskID:task,bundleID:"com.apple.TextEdit",at:instant)
        XCTAssertThrowsError(try policy.start(taskID:UUID(),bundleID:"com.apple.Notes",at:instant))
        XCTAssertThrowsError(try policy.validateApproval(taskID:UUID(),sessionID:session.id,at:instant))
        XCTAssertThrowsError(try policy.validateApproval(taskID:task,sessionID:UUID(),at:instant))
        XCTAssertNoThrow(try policy.validateApproval(taskID:task,sessionID:session.id,at:instant))
    }
    func testStaleTaskEndCannotRevokeNewSession() throws {
        let policy=ComputerSessionPolicy();let old=UUID();let new=UUID()
        _=try policy.start(taskID:old,bundleID:"com.apple.TextEdit",at:instant)
        policy.end(taskID:old)
        let session=try policy.start(taskID:new,bundleID:"com.apple.TextEdit",at:instant)
        policy.end(taskID:old)
        XCTAssertTrue(policy.isActive(taskID:new,sessionID:session.id,at:instant))
    }
    func testExpiryIsRetainedForNativeCleanup() throws {
        let policy=ComputerSessionPolicy();let task=UUID()
        let session=try policy.start(taskID:task,bundleID:"com.apple.TextEdit",at:instant)
        let expiry=instant.addingTimeInterval(300)
        XCTAssertNil(policy.currentSession(at:expiry))
        XCTAssertThrowsError(try policy.validateApproval(taskID:task,sessionID:session.id,at:expiry))
        XCTAssertEqual(policy.expireIfNeeded(at:expiry)?.id,session.id)
        XCTAssertNil(policy.expireIfNeeded(at:expiry))
    }
    func testActionLimitCountsAttemptsAndAllowsFinalObservation() throws {
        let policy=ComputerSessionPolicy();let task=UUID()
        let session=try policy.start(taskID:task,bundleID:"com.apple.TextEdit",at:instant)
        for _ in 0..<30 { _=try policy.reserveAction(taskID:task,sessionID:session.id,at:instant) }
        XCTAssertThrowsError(try policy.reserveAction(taskID:task,sessionID:session.id,at:instant))
        XCTAssertTrue(policy.isActive(taskID:task,at:instant))
        XCTAssertEqual(policy.currentSession(at:instant)?.remainingActions,0)
    }
    func testEveryMutationRequiresBoundSingleUseApproval() throws {
        let policy=ActionPolicy();let task=UUID();let session=UUID();policy.begin(task)
        let snapshot=UUID().uuidString
        let calls=[ToolCall("computer_focus"),ToolCall("computer_click",["snapshot":snapshot,"element":"2"]),
                   ToolCall("computer_type",["snapshot":snapshot,"element":"2","text":"Hello"]),
                   ToolCall("computer_key",["snapshot":snapshot,"key":"cmd+n"]),
                   ToolCall("computer_scroll",["snapshot":snapshot,"direction":"down","amount":"2"])]
        for call in calls {
            let proposal=try XCTUnwrap(policy.propose(call,taskID:task,now:instant,computerSessionID:session))
            XCTAssertEqual(proposal.computerSessionID,session)
            XCTAssertEqual(try policy.consume(proposal,now:instant),call)
            XCTAssertThrowsError(try policy.consume(proposal,now:instant))
        }
        XCTAssertNil(try policy.propose(ToolCall("computer_observe"),taskID:task,now:instant,computerSessionID:session))
    }
    func testChangingApprovalSessionAndCancellingPreventsReplay() throws {
        let policy=ActionPolicy();let task=UUID();policy.begin(task)
        let p=try XCTUnwrap(policy.propose(ToolCall("computer_focus"),taskID:task,now:instant,computerSessionID:UUID()))
        var forged=p;forged.computerSessionID=UUID()
        XCTAssertThrowsError(try policy.consume(forged,now:instant))
        let second=try XCTUnwrap(policy.propose(ToolCall("computer_focus"),taskID:task,now:instant,computerSessionID:UUID()))
        policy.revokeComputerApprovals(taskID:task)
        XCTAssertThrowsError(try policy.consume(second,now:instant))
        let third=try XCTUnwrap(policy.propose(ToolCall("computer_focus"),taskID:task,now:instant,computerSessionID:UUID()))
        policy.cancelAll();XCTAssertThrowsError(try policy.consume(third,now:instant))
    }
    func testArgumentsRejectCoordinatesCodeAndOutOfRangeValues() {
        let snapshot=UUID().uuidString
        let invalid=[ToolCall("computer_click",["snapshot":snapshot,"x":"1","y":"2"]),
                     ToolCall("computer_click",["snapshot":"fake","element":"1"]),
                     ToolCall("computer_click",["snapshot":snapshot,"element":"10000"]),
                     ToolCall("computer_click",["snapshot":snapshot,"element":"-1"]),
                     ToolCall("computer_type",["snapshot":snapshot,"element":"1","text":String(repeating:"x",count:2001)]),
                     ToolCall("computer_type",["snapshot":snapshot,"element":"1","text":"a\0b"]),
                     ToolCall("computer_key",["snapshot":snapshot,"key":"cmd+shift+j"]),
                     ToolCall("computer_scroll",["snapshot":snapshot,"direction":"down","amount":"6"]),
                     ToolCall("computer_observe",["app":"com.apple.Terminal"])]
        for call in invalid { XCTAssertThrowsError(try ActionPolicy().validate(call),call.name) }
    }
    func testApprovalCannotOutliveObservedControls() throws {
        let policy=ActionPolicy();let task=UUID();policy.begin(task)
        let deadline=instant.addingTimeInterval(10)
        let proposal=try XCTUnwrap(policy.propose(ToolCall("computer_focus"),taskID:task,now:instant,computerSessionID:UUID(),expiresAt:deadline))
        XCTAssertEqual(proposal.expires,deadline)
        XCTAssertThrowsError(try policy.consume(proposal,now:deadline))
        XCTAssertThrowsError(try policy.propose(ToolCall("computer_focus"),taskID:task,now:instant,computerSessionID:UUID(),expiresAt:instant))
    }
    func testComputerCallsCannotUseOrdinaryTaskPermission() throws {
        let policy=ActionPolicy();let task=UUID();policy.begin(task)
        XCTAssertThrowsError(try policy.propose(ToolCall("computer_observe"),taskID:task))
        XCTAssertThrowsError(try policy.propose(ToolCall("computer_focus"),taskID:task))
    }
    func testOldBrokerReplyStillDecodesWithoutImage() throws {
        let reply=try JSONDecoder().decode(BrokerReply.self,from:Data("{\"result\":\"ok\"}".utf8))
        XCTAssertNil(reply.image);XCTAssertEqual(reply.result,"ok")
    }
    @MainActor func testProtectedAppsAndStoppedControllerFailClosed() async throws {
        XCTAssertTrue(NativeComputerController.isProtectedApp("com.apple.Terminal"))
        XCTAssertTrue(NativeComputerController.isProtectedApp("com.apple.systempreferences"))
        XCTAssertFalse(NativeComputerController.isProtectedApp("com.apple.TextEdit"))
        let controller=NativeComputerController()
        do { _=try await controller.start(bundleID:"com.apple.Terminal");XCTFail("Protected app started") } catch {}
        controller.stop()
        do { _=try await controller.observe();XCTFail("Stopped controller observed") } catch {}
    }
}
