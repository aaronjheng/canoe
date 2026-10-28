import Foundation
import Observation
import Synchronization

/// Central app state. Coordinates the vault (loading/saving) with UI
/// selection, request execution, history, and open tabs.
@MainActor
@Observable
final class AppStore {
    let vault = VaultStore()

    /// The QuickJS engine running request scripts (see `AppStore+Scripts`).
    /// Created lazily on the first scripted send; a failed initialization
    /// stays nil and re-tries on the next send.
    var scriptEngine: ScriptEngine?

    var presentNewWorkspace = false
    /// File ▸ Import cURL…: the paste-a-cURL-command sheet.
    var presentImportCURL = false
    /// The File menu's "Clear History" stages this instead of wiping
    /// directly: history has no undo, so the menu command confirms exactly
    /// like the sidebar's Clear button does.
    var presentClearHistoryConfirm = false
    /// Cleared whenever the tree re-lays out (filter change) so a scheduled
    /// inline rename can't fire long after its create flow ended.
    var sidebarFilter: String = "" {
        didSet {
            if sidebarFilter != oldValue { pendingInlineRenameID = nil }
        }
    }
    var sidebarTab = SidebarTab.items
    /// Transient sidebar drag hover: which row shows an insertion line
    /// (.above/.below) or the folder highlight (.into). Set by the drop
    /// delegate, cleared on exit/drop - never persisted.
    var sidebarDropIndicator: SidebarDropIndicator?
    /// What the active sidebar drag carries ("request" / "folder" /
    /// "collection"), set when the drag session starts. Drop targets read it
    /// to decide hover visuals: a collection dragged over a collection row
    /// reorders (edges = lines), a request/folder joins the collection
    /// (whole row = into). Stale values are harmless - every drag start
    /// overwrites it.
    var sidebarDraggingKind: String?

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
        static let inspectorWidth = "inspectorWidth"
        static let consoleHeight = "consoleHeight"
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
        // Restored request tabs start without a response, like freshly
        // opened ones: nothing to show until the request is sent again.
        for tab in openTabs where tab.requestID != nil {
            resetResponseTabs.insert(tab)
        }
        if let data = defaults.data(forKey: OpenTabStateKeys.selectedTab) {
            let tab = try? JSONDecoder().decode(OpenTab.self, from: data)
            if let tab, openTabs.contains(tab) {
                selectedTab = tab
            }
        }
        let savedWidth = defaults.double(forKey: OpenTabStateKeys.inspectorWidth)
        if savedWidth > 0 {
            inspectorWidth = min(max(savedWidth, AppSize.inspectorMinWidth), AppSize.inspectorMaxWidth)
        }
        let savedConsole = defaults.double(forKey: OpenTabStateKeys.consoleHeight)
        if savedConsole > 0 {
            consoleHeight = min(max(savedConsole, AppSize.consoleMinHeight), AppSize.consoleMaxHeight)
        }
    }

    /// Persists the dragged inspector width (called on drag end, not per
    /// frame, so typing-speed writes never burst).
    func saveInspectorWidth() {
        UserDefaults.standard.set(inspectorWidth, forKey: OpenTabStateKeys.inspectorWidth)
    }

    /// Height of the docked console panel, adjustable by dragging its top
    /// edge (same rule as the inspector's width).
    var consoleHeight: CGFloat = AppSize.consoleDefaultHeight

    /// Persists the dragged console height (on drag end, not per frame).
    func saveConsoleHeight() {
        UserDefaults.standard.set(consoleHeight, forKey: OpenTabStateKeys.consoleHeight)
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

    /// Width of the right inspector, adjustable by dragging its leading
    /// edge (both inspector panels share it). Persisted across launches
    /// like the other window chrome.
    var inspectorWidth: CGFloat = AppSize.inspectorWidth

    /// Open tabs (requests and/or environments) in the workspace detail area.
    var openTabs: [OpenTab] = []
    /// Tabs freshly opened whose response viewer starts empty until the
    /// request is sent again. Response history itself is untouched: it
    /// belongs to the request and survives tab close/relaunch; only the
    /// display is reset. Set on fresh open (and on launch restore),
    /// cleared when a new response lands for the request.
    var resetResponseTabs: Set<OpenTab> = []
    /// The single-click preview tab (VSCode-style): shown in italic, reused
    /// by the next previewed tab, pinned on double-click or first edit.
    /// Transient - never persisted; after a relaunch every tab opens pinned.
    var previewTab: OpenTab?
    /// Response/error/send state, keyed by tab so each tab keeps its own.
    var errorsByTab: [OpenTab: String] = [:]
    /// Per-request response history (newest first), backing the History menu
    /// in the response panel. Keyed by request id rather than tab: the same
    /// request cannot open twice, and history belongs to the REQUEST - it
    /// survives tab closes, workspace switches, and relaunches (the
    /// machine-local SQLite store).
    var responseHistoryByRequest: [UUID: [ResponseModel]] = [:]
    /// Which historical entry the request's tab is currently viewing
    /// (nil = the latest).
    var viewingHistoryIndexByRequest: [UUID: Int] = [:]
    /// The right-edge inspector to reopen from the status bar's symmetric
    /// toggle. Tracked so hide/show round-trips restore the same panel.
    var lastRightInspectorPanel: RightInspectorPanel = .variables
    var sendingTabs: Set<OpenTab> = []

    // MARK: - WebSocket sessions

    /// Per-request WebSocket connection state (keyed by request id), read
    /// by the editor's Connect/Disconnect button and the message pane's
    /// status badge.
    var webSocketStates: [UUID: WebSocketConnectionState] = [:]
    /// In-memory message logs per request id (oldest first, newest
    /// appended): sent/received frames plus connection/error system lines.
    /// Never persisted - the log dies with the app session.
    var webSocketMessages: [UUID: [WebSocketLogEntry]] = [:]
    /// Live connections per request id. Not observable: the UI reads the
    /// connection state through `webSocketStates`, and connections are
    /// torn down through the same paths that update it.
    @ObservationIgnored var webSocketConnections: [UUID: WebSocketConnection] = [:]
    /// In-flight connect tasks (handshake awaits) per request id, so a
    /// fast disconnect can await/preempt the pending handshake.
    @ObservationIgnored var webSocketConnectTasks: [UUID: Task<Void, Never>] = [:]
    /// Composed message drafts (text + format) per request id - in-memory
    /// session state, like the message logs. Survives tab switches, not
    /// relaunches.
    var webSocketDrafts: [UUID: WebSocketMessageDraft] = [:]
    /// One bump per saved-messages change made through the store path (the
    /// message pane's Save/delete). The request editor watches it and
    /// adopts the fresh list into its draft - the same pattern as the
    /// OAuth token revisions - so its whole-draft pushes never revert the
    /// message pane's changes.
    var webSocketRevisions: [UUID: UUID] = [:]
    /// When each request's handshake completed (the `.open` moment). Books
    /// the Disconnect misfire guard: a disconnect landing within the
    /// quiescence window of the connect is the button swapping under a
    /// double-click, not intent (see AppStore+WebSocket).
    @ObservationIgnored var webSocketConnectAt: [UUID: Date] = [:]

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
    /// mirrored to the local store so it survives relaunches. Tracked by the
    /// observation system so the Save button and tab dirty dots update live.
    var pendingRequestSnapshots: [UUID: Request] = [:]
    /// Monotonic id of the newest Save pass. A pass that failed to write
    /// only puts its entity back into the dirty set while it still owns that
    /// entity - see `capturedSavePasses`.
    var savePassGeneration = 0
    /// The Save pass that captured each entity's pending entry, keyed by
    /// entity id. A failed write's restore stands down only when a NEWER
    /// pass captured the SAME entity - an unrelated pass on another tab
    /// must not turn a failed save into a silently clean edit.
    @ObservationIgnored var capturedSavePasses: [UUID: Int] = [:]
    /// In-flight serialized structural write (renames, adds, deletes,
    /// commit-saves): every fire-and-forget vault write chains onto it, so
    /// the writes land in issue order and the quit path can wait for them.
    @ObservationIgnored var structuralWriteTask: Task<Void, Never>?
    /// Unsaved environment edits - same model as the request snapshots.
    var pendingEnvironmentSnapshots: [UUID: EnvironmentProfile] = [:]
    /// Unsaved workspace/collection variable edits - same draft model.
    var pendingWorkspaceVariables: [UUID: [Variable]] = [:]
    var pendingCollectionVariables: [UUID: [Variable]] = [:]
    /// Unsaved collection Authorization edits - same draft model.
    var pendingCollectionAuthorizations: [UUID: Authorization] = [:]
    /// Unsaved folder Authorization edits - same draft model, keyed by folder
    /// id. A folder has no file of its own: its settings live in the owning
    /// collection's file, so both the save and the mirror resolve the
    /// collection through the folder id.
    var pendingFolderAuthorizations: [UUID: Authorization] = [:]
    /// One bump per send-path OAuth token renewal (see AppStore+OAuth),
    /// keyed by the owning entity's id. The request/collection/folder
    /// editors watch it and adopt the fresh token fields into their local
    /// drafts - also when they hold other pending edits, which the
    /// whole-value adoption observers are deliberately guarded off for. A
    /// stale local push would otherwise revert a rotated refresh token.
    var oauthTokenRevisions: [UUID: UUID] = [:]
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
    /// Last persisted Authorization per folder id.
    @ObservationIgnored var persistedFolderAuthorizationBaselines: [UUID: Authorization] = [:]
    let historyLimit = 100
    static let responseHistoryLimit = 20
    /// Total bytes of response bodies one request's response history may
    /// keep; the oldest entries drop out once it is passed. The entry count
    /// alone is not a memory bound: 20 full responses per request, each up
    /// to `HTTPClient.maxResponseBytes`, reach a gigabyte. Bodies are the
    /// whole cost of an entry, so the budget is counted in bytes.
    static let responseHistoryByteLimit = 16 * 1024 * 1024
    /// Total bytes of retained response bodies across ALL requests (the
    /// base64 disk mirror costs ~1.33x). The per-request budget above is
    /// not enough once history is persisted: every closed tab's history
    /// stays in the map for relaunch, so unbounded requests would pin
    /// unbounded memory and disk. Exceeding it evicts the globally oldest
    /// entry, per request.
    static let responseHistoryGlobalByteLimit = 32 * 1024 * 1024
    /// Console (network log) entries, newest last. Capped by count and by
    /// retained body bytes, and mirrored to the machine-local SQLite store
    /// so the log survives relaunches.
    var consoleEntries: [ConsoleEntry] = []
    static let consoleEntryLimit = 200
    /// Total bytes of request+response bodies the console keeps across all
    /// entries. `ConsoleEntry.bodyLimit` caps a single body; this caps the
    /// log itself - 200 entries at two 512 KB bodies each would otherwise
    /// reach 200 MB.
    static let consoleBodyByteLimit = 16 * 1024 * 1024
    /// Script-written variable overrides (machine-local
    /// `canoe.sqlite`): pre-request/post-response scripts persist
    /// their `pm.environment.set` & co writes here instead of the vault
    /// files - per-device runtime state like a minted token, never synced.
    /// `variableScopesForRequest` folds them over the stored scopes, so the
    /// send path and the variables inspector read the same effective values.
    var variableOverrides = VariableOverrides()
    /// Whether the console panel is docked below the Response pane.
    var showConsole = false
    var selectedTab: OpenTab?
    /// Debounced writer for the drafts mirror; cancelled/rescheduled on
    /// every edit so typing does not rewrite the store per keystroke.
    @ObservationIgnored var draftSaveTask: Task<Void, Never>?
    /// Debounced writer for the history mirror; rescheduled on every
    /// recorded entry so a burst of sends lands in one transaction.
    @ObservationIgnored var historySaveTask: Task<Void, Never>?
    /// Debounced writer for the response-history mirror; rescheduled on
    /// every recorded (or purged) entry so a burst of sends lands in one transaction.
    @ObservationIgnored var responseHistorySaveTask: Task<Void, Never>?
    /// Debounced writer for the console-log mirror; rescheduled on every
    /// recorded entry (and on Clear) so a burst of sends lands in one transaction.
    @ObservationIgnored var consoleSaveTask: Task<Void, Never>?
    /// Debounced writer for the variable overrides; rescheduled per
    /// send so a burst of sends lands in one transaction.
    @ObservationIgnored var variableOverridesSaveTask: Task<Void, Never>?
    /// In-flight Save (⌘S) task, if any. Tracked so the quit path can
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
    /// Requests that exist only in the session: created without a collection
    /// context (New Request / new tab with no target), they live here and in
    /// the draft mirror's `unfiledRequests` until an explicit save gives
    /// them a home (the Save Request sheet). Never in the sidebar or any
    /// collection file - nothing is written until the user picks a location.
    var unfiledRequests: [UUID: Request] = [:]
    /// The unfiled request staged for the Save Request sheet (nil = closed).
    /// Identifiable so ContentView hosts the sheet with `.sheet(item:)`.
    var requestSaveContext: RequestSaveContext?
    /// A close confirmation waiting on the staged Save Request sheet: the
    /// Save branch of a dirty close must not discard a scratch request, so
    /// the sheet runs first and this close re-resolves (saving) afterwards.
    var closeAfterRequestSave: PendingClose?
    /// Postman's ⌘L ("Jump to request URL"): a monotonic token bumped by
    /// the View menu's Jump to Request URL command. The selected request's
    /// editor (see RequestEditorView) watches it and claims the URL field.
    /// A token, not a flag: a second press while the field is already
    /// focused still re-fires (the value changes), and nothing can go stale
    /// when editors unmount.
    var urlFocusToken = 0
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
        guard let id = selectedRequestID else { return nil }
        return request(withID: id)
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

    /// The folder shown in the selected tab (nil unless a folder tab is
    /// active). Folders are nested inside collection files, so this resolves
    /// through the vault rather than a flat list.
    var selectedFolderTab: Folder? {
        guard case .folder(let id) = selectedTab else { return nil }
        return folder(withID: id)
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
