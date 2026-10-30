import Foundation
import Testing
@testable import BrightnessSyncCore

struct SyncPolicyTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func firstValueIsWritten() {
        #expect(SyncPolicy().shouldWrite(50, at: start))
    }

    @Test func unchangedTargetIsNotRewritten() {
        var policy = SyncPolicy()
        policy.didWrite(50, at: start)
        #expect(!policy.shouldWrite(50, at: start + 1))
    }

    @Test func changedTargetIsWritten() {
        var policy = SyncPolicy()
        policy.didWrite(50, at: start)
        #expect(policy.shouldWrite(60, at: start + 1))
    }

    @Test func changesWaitForTheMinimumInterval() {
        var policy = SyncPolicy(minimumInterval: 0.4)
        policy.didWrite(50, at: start)
        #expect(!policy.shouldWrite(60, at: start + 0.2))
        #expect(policy.shouldWrite(70, at: start + 0.4))
    }

    @Test func forcedResendWritesAnUnchangedTargetOnceTheIntervalAllows() {
        var policy = SyncPolicy(minimumInterval: 0.4)
        policy.didWrite(50, at: start)
        policy.forceResend()
        #expect(!policy.shouldWrite(50, at: start + 0.1))
        #expect(policy.shouldWrite(50, at: start + 0.5))
    }

    @Test func successfulWriteClearsAForcedResend() {
        var policy = SyncPolicy()
        policy.forceResend()
        policy.didWrite(50, at: start)
        #expect(!policy.shouldWrite(50, at: start + 1))
    }

    @Test func failedWriteKeepsAskingForTheValue() {
        var policy = SyncPolicy()
        policy.didWrite(50, at: start)
        #expect(policy.shouldWrite(60, at: start + 1))
        // The write failed, so didWrite was not called.
        #expect(policy.shouldWrite(60, at: start + 1.25))
        #expect(policy.lastWritten == 50)
    }
}
