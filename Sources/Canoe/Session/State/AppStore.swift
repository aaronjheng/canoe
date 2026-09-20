import Foundation
import Observation
import Synchronization

/// Central app state. Coordinates the vault (loading/saving) with UI
/// selection, request execution, history, and open tabs.
@MainActor
@Observable
final class AppStore {
    let vault = VaultStore()

    var presentNewWorkspace = false
    /// Cleared whenever the tree re-lays out (filter change) so a scheduled
    /// inline rename can't fire long after its create flow ended.
    var sidebarFilter: String = "" {
        didSet {
            if sidebarFilter != oldValue { pendingInlineRenameID = nil }
        }
    }
    var sidebarTab = SidebarTab.items

    // MARK: - Sidebar expansion state

    /// Sidebar tree expansion remembered across launches, like VS Code's
    /// explorer view state (`workbench.explorer.treeViewState`): a set of
    /// the ids currently expanded, saved on every toggle, restored on
    /// launch. Anything absent renders collapsed, so fresh collections land
    /// folded instead of splaying open. Keyed by node id, so each
    /// workspace's tree state is separate; stored in UserDefaults (the
    /// app's machine-local key-value store - UI state is never synced).
    ///
    /// Sizing note / upgrade path if this ever outgrows UserDefaults:
    /// cfprefsd coalesces writes but flushes by rewriting the whole domain
    /// plist, so keep this to small values written at human frequency (a
    /// few dozen keys, ~KB). If UI state ever grows past that - large
    /// blobs, programmatic write bursts, or data that must survive a
    /// crash - switch to a SQLite key-value table like VS Code's
    /// `state.vscdb` ItemTable (row-level upserts, ~100 ms write
    /// coalescing, backup on close).
    var sidebarExpandedNodeIDs: Set<UUID> = []
    var isCollectionsSectionExpanded = true
    var isEnvironmentsSectionExpanded = true

    enum SidebarStateKeys {
        static let expandedNodeIDs = "sidebarExpandedNodeIDs"
        static let collectionsSectionExpanded = "sidebarCollectionsSectionExpanded"
        static let environmentsSectionExpanded = "sidebarEnvironmentsSectionExpanded"
    }

    enum OpenTabStateKeys {
        static let openTabs = "openTabs"
        static let selectedTab = "selectedTab"
    }

    init() {
        let defaults = UserDefaults.standard
        if let ids = defaults.stringArray(forKey: SidebarStateKeys.expandedNodeIDs) {
            sidebarExpandedNodeIDs = Set(ids.compactMap(UUID.init(uuidString:)))
        }
        // Sections default to open, but a stored false must be honored, so
        // only fall back when the key was never written.
        if defaults.object(forKey: SidebarStateKeys.collectionsSectionExpanded) != nil {
            isCollectionsSectionExpanded = defaults.bool(forKey: SidebarStateKeys.collectionsSectionExpanded)
        }
        if defaults.object(forKey: SidebarStateKeys.environmentsSectionExpanded) != nil {
            isEnvironmentsSectionExpanded = defaults.bool(forKey: SidebarStateKeys.environmentsSectionExpanded)
        }
        // Restores the last session's tab strip (same machine-local UI-state
        // store as the sidebar expansion); tabs referencing entities that no
        // longer exist are pruned once the vault loads.
        if let data = defaults.data(forKey: OpenTabStateKeys.openTabs) {
            openTabs = (try? JSONDecoder().decode([OpenTab].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: OpenTabStateKeys.selectedTab) {
            let tab = try? JSONDecoder().decode(OpenTab.self, from: data)
            if let tab, openTabs.contains(tab) {
                selectedTab = tab
            }
        }
    }

    /// Whether the left sidebar (collections/history) is shown. Toggled from
    /// the status bar, Postman-style.
    var showSidebar = true

    /// Whether the "Variables in Request" inspector is shown on the right.
    /// Toggled from the toolbar button next to the environment picker.
    var showVariablesSidebar = false

    /// Whether the "Code Snippet" inspector is shown on the right. The right
    /// edge hosts one inspector at a time - opening one closes the other.
    var showCodeSnippetSidebar = false

    /// Open tabs (requests and/or environments) in the workspace detail area.
    var openTabs: [OpenTab] = []
    /// Response/error/send state, keyed by tab so each tab keeps its own.
    var responsesByTab: [OpenTab: ResponseModel] = [:]
    var errorsByTab: [OpenTab: String] = [:]
    /// Per-tab response history (newest first), backing the History menu in
    /// the response panel. The first entry mirrors `responsesByTab`.
    var responseHistoryByTab: [OpenTab: [ResponseModel]] = [:]
    /// Which historical entry the tab is currently viewing (nil = the latest).
    var viewingHistoryIndexByTab: [OpenTab: Int] = [:]
    /// The right-edge inspector to reopen from the status bar's symmetric
    /// toggle. Tracked so hide/show round-trips restore the same panel.
    var lastRightInspectorPanel: RightInspectorPanel = .variables
    var sendingTabs: Set<OpenTab> = []

    /// Per-device, in-memory request history (most recent first).
    var history: [HistoryEntry] = []

    @ObservationIgnored var sendTasks: [OpenTab: Task<Void, Never>] = [:]
    @ObservationIgnored var sendTokens: [OpenTab: UUID] = [:]
    /// When each tab last cancelled a send. A Send landing within
    /// `sendAfterCancelQuiescence` of it is a misfire (the morphing button
    /// swapped under the click, or a double-click's second half) and is
    /// dropped - otherwise it would fire a brand-new request whose response
    /// then "appears despite cancelling".
    @ObservationIgnored var lastCancelAt: [OpenTab: Date] = [:]
    static let sendAfterCancelQuiescence: TimeInterval = 0.5
    /// Unsaved request edits (Postman-style dirty state): the latest draft is
    /// held here until an explicit save (Save button / ⌘S) persists it, and
    /// mirrored to drafts.json so it survives relaunches. Tracked by the
    /// observation system so the Save button and tab dirty dots update live.
    var pendingRequestSnapshots: [UUID: Request] = [:]
    /// Unsaved environment edits - same model as the request snapshots.
    var pendingEnvironmentSnapshots: [UUID: EnvironmentProfile] = [:]
    /// Unsaved workspace/collection variable edits - same draft model.
    var pendingWorkspaceVariables: [UUID: [Variable]] = [:]
    var pendingCollectionVariables: [UUID: [Variable]] = [:]
    /// Unsaved collection Authorization edits - same draft model.
    var pendingCollectionAuthorizations: [UUID: Authorization] = [:]
    /// Last persisted content per request id. The dirty check compares
    /// against this (NOT the in-memory copy, which updateRequest has already
    /// mutated - that comparison always matched, so edits never reached disk).
    @ObservationIgnored var persistedRequestBaselines: [UUID: Request] = [:]
    /// Last persisted content per environment id - the environment dirty
    /// check's baseline.
    @ObservationIgnored var persistedEnvironmentBaselines: [UUID: EnvironmentProfile] = [:]
    /// Last persisted variables per workspace/collection id.
    @ObservationIgnored var persistedWorkspaceVariableBaselines: [UUID: [Variable]] = [:]
    @ObservationIgnored var persistedCollectionVariableBaselines: [UUID: [Variable]] = [:]
    /// Last persisted Authorization per collection id.
    @ObservationIgnored var persistedCollectionAuthorizationBaselines: [UUID: Authorization] = [:]
    let historyLimit = 100
    static let responseHistoryLimit = 20
    /// Console (network log) entries, newest last; session-scoped and capped.
    var consoleEntries: [ConsoleEntry] = []
    static let consoleEntryLimit = 200
    /// Whether the console panel is docked below the Response pane.
    var showConsole = false
    var selectedTab: OpenTab?
    /// Debounced writer for the drafts mirror; cancelled/rescheduled on
    /// every edit so typing does not rewrite drafts.json per keystroke.
    @ObservationIgnored var draftSaveTask: Task<Void, Never>?
    /// In-flight Save-all (⌘S) task, if any. Tracked so the quit path can
    /// wait for the vault writes to land before the process exits: the
    /// pending snapshots are cleared up front, so quitting mid-save would
    /// otherwise strand the edits in neither the vault nor the drafts.
    @ObservationIgnored var saveAllTask: Task<Void, Never>?
    /// Latest external-change reload, if any. Reloads chain on it so two
    /// overlapping reloads cannot interleave and leave stale files in
    /// memory (the later reload always wins).
    @ObservationIgnored var externalReloadTask: Task<Void, Never>?
    /// Node scheduled to open its inline rename field in the sidebar tree
    /// (set right after creating a collection/folder, VS Code-style create
    /// flow). The row consumes it on commit or cancel.
    var pendingInlineRenameID: UUID?
    /// One-shot section deep-link for the collection detail tab. Set when
    /// opening from the variables inspector; the detail view consumes its
    /// entry on appear, so the request applies exactly once.
    var detailSectionRequests: [UUID: DetailSection] = [:]
    var pendingClose: PendingClose?
    // MARK: - Derived

    var activeWorkspace: Workspace? { vault.activeWorkspace }

    var activeEnvironment: EnvironmentProfile? {
        guard let environment = vault.activeEnvironment else { return nil }
        // Environments are workspace-scoped - one left over from another
        // workspace (stale config) must never resolve variables.
        guard
            environment.workspaceID == nil
                || environment.workspaceID == vault.config.activeWorkspaceID
        else { return nil }
        return environment
    }

    /// Environments of the active workspace (sidebar list + pickers).
    var activeWorkspaceEnvironments: [EnvironmentProfile] {
        vault.activeWorkspaceEnvironments
    }

    /// Collections shown in the sidebar (those of the active workspace).
    var visibleCollections: [Collection] { vault.activeWorkspaceCollections }

    var selectedRequest: Request? {
        vault.collections.flatMap(\.requests).first { $0.id == selectedRequestID }
    }

    /// The environment shown in the selected tab (nil unless an environment
    /// tab is active).
    var selectedEnvironmentTab: EnvironmentProfile? {
        guard case .environment(let id) = selectedTab else { return nil }
        return vault.environments.first { $0.id == id }
    }

    /// The collection shown in the selected tab (nil unless a collection
    /// variables tab is active).
    var selectedCollectionTab: Collection? {
        guard case .collection(let id) = selectedTab else { return nil }
        return vault.collections.first { $0.id == id }
    }

    /// The workspace shown in the selected tab (nil unless the workspace
    /// Overview tab is active).
    var selectedWorkspaceTab: Workspace? {
        guard case .workspace(let id) = selectedTab else { return nil }
        return vault.workspaces.first { $0.id == id }
    }

    /// The workspace whose variables are shown in the selected tab (nil
    /// unless a workspace-variables tab is active).
    var selectedWorkspaceVariablesTab: Workspace? {
        guard case .workspaceVariables(let id) = selectedTab else { return nil }
        return vault.workspaces.first { $0.id == id }
    }

    // MARK: - Helpers

    func clearSelectionIfMissing() {
        guard let selected = selectedRequestID else { return }
        let exists = vault.collections.contains { $0.requests.contains { $0.id == selected } }
        if !exists { selectedRequestID = nil }
    }

}
