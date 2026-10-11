import Foundation
import Testing
import VaultCore
@testable import noema

@Test func windowGeometryUsesSeparateWelcomeAndWorkspaceFrames() {
    #expect(WindowGeometryProfile.welcome.defaultContentSize == CGSize(width: 680, height: 480))
    #expect(WindowGeometryProfile.workspace.defaultContentSize == CGSize(width: 1280, height: 820))
    #expect(WindowGeometryProfile.welcome.frameSaveName != WindowGeometryProfile.workspace.frameSaveName)
    #expect(WindowGeometryProfile.welcome.minimumContentSize.width < WindowGeometryProfile.workspace.minimumContentSize.width)
}

@Test func windowGeometryRetainsWorkingFrameDuringOpeningAndLocking() {
    var state = WindowGeometryState(phase: .closed)
    state.request(.opening)
    let applied1 = state.applyPending(canResize: true)
    #expect(!applied1)
    #expect(state.profile == .welcome)
    state.request(.open)
    let applied2 = state.applyPending(canResize: true)
    #expect(applied2)
    for phase in [VaultSessionPhase.opening, .locking, .open] {
        state.request(phase)
        let applied3 = state.applyPending(canResize: true)
        #expect(!applied3)
        #expect(state.profile == .workspace)
    }
    state.request(.locked)
    let applied4 = state.applyPending(canResize: true)
    #expect(applied4)
    #expect(state.profile == .welcome)
}

@Test func windowGeometryAppliesLatestPendingPresentationAfterFullScreen() {
    var state = WindowGeometryState(phase: .open)
    state.applyPending(canResize: true)
    state.request(.closed)
    let applied5 = state.applyPending(canResize: false)
    #expect(!applied5)
    #expect(state.profile == .workspace)
    state.request(.opening)
    let applied6 = state.applyPending(canResize: false)
    #expect(!applied6)
    let applied7 = state.applyPending(canResize: true)
    #expect(!applied7)
    #expect(state.profile == .workspace)
    state.request(.locked)
    let applied8 = state.applyPending(canResize: false)
    #expect(!applied8)
    #expect(state.profile == .workspace)
    let applied9 = state.applyPending(canResize: true)
    #expect(applied9)
    #expect(state.profile == .welcome)
}

@Test func windowGeometryClampsOversizedFramesAndMinimumsToSmallScreens() {
    let screen = CGRect(x: 0, y: 25, width: 640, height: 455)
    let frame = CGRect(x: -500, y: -400, width: 1280, height: 850)
    let result = WindowGeometry.clamped(frame, to: screen, minimumSize: CGSize(width: 720, height: 540))
    #expect(result == screen)
}

@Test func windowGeometryPreservesUsableFramesAndEnforcesMinimumSize() {
    let screen = CGRect(x: 0, y: 25, width: 1400, height: 900)
    let valid = CGRect(x: 80, y: 90, width: 900, height: 650)
    let minimum = CGSize(width: 720, height: 540)
    #expect(WindowGeometry.clamped(valid, to: screen, minimumSize: minimum) == valid)
    let tiny = CGRect(x: 1350, y: 900, width: 100, height: 100)
    let result = WindowGeometry.clamped(tiny, to: screen, minimumSize: minimum)
    #expect(result.size == minimum)
    #expect(screen.contains(result))
}

@Test func windowGeometryRestoresToNegativeCoordinateAndDisconnectedDisplays() {
    let primary = CGRect(x: 0, y: 25, width: 1400, height: 900)
    let secondary = CGRect(x: -1600, y: 25, width: 1600, height: 1000)
    let saved = CGRect(x: -1500, y: 100, width: 1280, height: 820)
    #expect(WindowGeometry.visibleFrame(for: saved, screens: [primary, secondary]) == secondary)
    #expect(WindowGeometry.clamped(saved, to: secondary, minimumSize: CGSize(width: 720, height: 540)) == saved)
    #expect(WindowGeometry.visibleFrame(for: saved, screens: [primary]) == primary)
    let result = WindowGeometry.clamped(saved, to: primary, minimumSize: CGSize(width: 720, height: 540))
    #expect(primary.contains(result))
    #expect(WindowGeometry.visibleFrame(for: saved, screens: []) == nil)
}

@Test func windowGeometryChoosesClosestScreenForOffscreenFrame() {
    let left = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
    let right = CGRect(x: 0, y: 0, width: 1400, height: 900)
    let disconnected = CGRect(x: 2500, y: 200, width: 1000, height: 600)
    #expect(WindowGeometry.visibleFrame(for: disconnected, screens: [left, right]) == right)
}
