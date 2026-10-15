import Foundation
import Testing
@testable import VaultCore
@testable import noema

struct OrganisationContentsTests {
    @Test func mixedMembershipsKeepTypedIdentityAndBlockParent() {
        let sharedID = UUID(), pageID = UUID()
        let page = OrganisationContentsRowPresentation.reference(for: .page(sharedID))
        let source = OrganisationContentsRowPresentation.reference(for: .source(sharedID))
        let block = OrganisationContentsRowPresentation.reference(for: .semanticBlock(pageID: pageID, blockID: sharedID))
        #expect(Set([page, source, block]).count == 3)
        #expect(block.pageID == pageID)
        #expect(page.pageID == nil && source.pageID == nil)
        #expect(OrganisationContentsRowPresentation(kind: .semanticBlock, parentTitle: "Research").subtitle == "Knowledge block · Research")
        #expect(OrganisationContentsRowPresentation(kind: .source, parentTitle: "Research").subtitle == "Source")
    }

    @Test func emptyAndFolderOnlyContainersDescribeTheirActualContents() {
        #expect(OrganisationContentsSummary(itemCount: 0, folderCount: 0).isEmpty)
        let folders = OrganisationContentsSummary(itemCount: 0, folderCount: 2)
        #expect(!folders.isEmpty)
        #expect(folders.label == "2 folders · 0 items")
        #expect(OrganisationContentsSummary(itemCount: 1, folderCount: 1).label == "1 folder · 1 item")
        #expect(OrganisationContentsSummary(itemCount: 5, folderCount: 0).label == "5 items")
    }

    @Test func multiSelectionNeverOpensAnArbitraryMember() {
        let page = OrganisationItemReference(kind: .page, itemID: UUID())
        let entity = OrganisationItemReference(kind: .knowledgeEntity, itemID: UUID())
        #expect(OrganisationContentsSelection.itemToOpen(in: [], extendingSelection: false) == nil)
        #expect(OrganisationContentsSelection.itemToOpen(in: [page, entity], extendingSelection: false) == nil)
        #expect(OrganisationContentsSelection.itemToOpen(in: [page], extendingSelection: true) == nil)
        #expect(OrganisationContentsSelection.itemToOpen(in: [entity], extendingSelection: false) == entity)
    }
    @Test @MainActor func compactOrganisationBrowsingKeepsInspectorIntent() {
        let name = "OrganisationContentsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: WorkspacePaneState.inspectorVisibilityKey)
        let panes = WorkspacePaneState(defaults: defaults)
        panes.revealCollection()
        let compact = panes.presentation(width: 900, mainMinimum: WorkspacePaneState.contentMinimum,
            inspectorAvailable: true, contentPreferred: WorkspacePaneState.contentPreferred)
        #expect(compact.collection)
        #expect(panes.isInspectorVisible)
        let wide = panes.presentation(width: 1500, mainMinimum: WorkspacePaneState.contentMinimum,
            inspectorAvailable: true, contentPreferred: WorkspacePaneState.contentPreferred)
        #expect(wide.collection && wide.inspector)
    }
}
