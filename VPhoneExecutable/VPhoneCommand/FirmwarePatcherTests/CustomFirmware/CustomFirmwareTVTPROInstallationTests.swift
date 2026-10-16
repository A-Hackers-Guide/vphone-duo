@testable import FirmwarePatcher
import Testing

@Suite("TV dyld paired installation safety")
struct CustomFirmwareTVTPROInstallationTests {
    @Test func `existing patches require both original backup and undo`() throws {
        for priorApplied in [false, true] {
            #expect(throws: (any Error).self) {
                try CustomFirmwareTVTPROInstallation.validateBackup(
                    priorApplied: priorApplied, hasUndo: true,
                    backupExists: false, backupIsRegular: false,
                )
            }
        }
        #expect(throws: (any Error).self) {
            try CustomFirmwareTVTPROInstallation.validateBackup(
                priorApplied: true, hasUndo: false, backupExists: true, backupIsRegular: true,
            )
        }
        #expect(throws: (any Error).self) {
            try CustomFirmwareTVTPROInstallation.validateBackup(
                priorApplied: false, hasUndo: false, backupExists: true, backupIsRegular: false,
            )
        }
        try CustomFirmwareTVTPROInstallation.validateBackup(
            priorApplied: false, hasUndo: false, backupExists: false, backupIsRegular: false,
        )
        try CustomFirmwareTVTPROInstallation.validateBackup(
            priorApplied: true, hasUndo: true, backupExists: true, backupIsRegular: true,
        )
    }

    @Test func `in place disk updates are refused`() throws {
        #expect(throws: (any Error).self) {
            try CustomFirmwareTVTPROInstallation.requirePrivateClone(false)
        }
        try CustomFirmwareTVTPROInstallation.requirePrivateClone(true)
    }

    enum InjectedFailure: Error { case write }

    @Test(arguments: 0 ... 3)
    func `failure stops rollback before retiring undo or committing`(failureAt: Int) {
        var visited: [Int] = []
        var undoRetired = false
        var committed = false
        func step(_ index: Int) throws {
            visited.append(index)
            if failureAt == index { throw InjectedFailure.write }
        }
        do {
            try CustomFirmwareTVTPROInstallation.restorePair {
                try step(0)
            } restoreStandalone: {
                try step(1)
            } retireUndo: {
                try step(2)
                undoRetired = true
            }
            committed = true
        } catch {
            #expect(error is InjectedFailure)
        }
        #expect(visited == Array(0 ... min(failureAt, 2)))
        #expect(undoRetired == (failureAt == 3))
        #expect(committed == (failureAt == 3))
    }
}
