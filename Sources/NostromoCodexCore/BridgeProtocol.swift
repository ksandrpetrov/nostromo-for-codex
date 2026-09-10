import Foundation

public enum BridgeAppAction: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case clearComposerProject = "clear-composer-project"
        case runCommand = "run-command"
        case focusChatGPT = "focus-chatgpt"
        case toggleChatGPT = "toggle-chatgpt"
        case toggleChatWorkMode = "toggle-chat-work-mode"
        case submitActiveComposer = "submit-active-composer"
        case navigateRoute = "navigate-route"
        case scrollTask = "scroll-task"
        case insertComposerText = "insert-composer-text"
        case insertSkillMention = "insert-skill-mention"
        case preparePluginPrompt = "prepare-plugin-prompt"
        case pushToTalkStart = "push-to-talk-start"
        case pushToTalkStop = "push-to-talk-stop"
        case stopActive = "stop-active"
        case queryRuntimeState = "query-runtime-state"
    }

    case clearComposerProject
    case runCommand(id: String)
    case focusChatGPT
    case toggleChatGPT(minimizeIfVisible: Bool)
    case toggleChatWorkMode
    case submitActiveComposer
    case navigateRoute(path: String)
    case scrollTask(deltaY: Int)
    case insertComposerText(text: String)
    case insertSkillMention(name: String, displayName: String, path: String)
    case preparePluginPrompt(text: String)
    case pushToTalkStart
    case pushToTalkStop
    case stopActive
    case queryRuntimeState

    public var kind: Kind {
        switch self {
        case .clearComposerProject: .clearComposerProject
        case .runCommand: .runCommand
        case .focusChatGPT: .focusChatGPT
        case .toggleChatGPT: .toggleChatGPT
        case .toggleChatWorkMode: .toggleChatWorkMode
        case .submitActiveComposer: .submitActiveComposer
        case .navigateRoute: .navigateRoute
        case .scrollTask: .scrollTask
        case .insertComposerText: .insertComposerText
        case .insertSkillMention: .insertSkillMention
        case .preparePluginPrompt: .preparePluginPrompt
        case .pushToTalkStart: .pushToTalkStart
        case .pushToTalkStop: .pushToTalkStop
        case .stopActive: .stopActive
        case .queryRuntimeState: .queryRuntimeState
        }
    }

    public var name: String {
        kind.rawValue
    }

    public var requiredPayloadKeys: [String] {
        switch self {
        case .runCommand:
            ["commandId"]
        case .toggleChatGPT:
            ["minimizeIfVisible"]
        case .navigateRoute:
            ["path"]
        case .scrollTask:
            ["deltaY"]
        case .insertComposerText, .preparePluginPrompt:
            ["text"]
        case .insertSkillMention:
            ["displayName", "name", "path"]
        case .clearComposerProject, .focusChatGPT, .toggleChatWorkMode, .submitActiveComposer,
             .pushToTalkStart, .pushToTalkStop, .stopActive, .queryRuntimeState:
            []
        }
    }

    public var payload: [String: String] {
        switch self {
        case let .runCommand(id):
            ["commandId": id]
        case let .toggleChatGPT(minimizeIfVisible):
            ["minimizeIfVisible": minimizeIfVisible ? "true" : "false"]
        case let .navigateRoute(path):
            ["path": path]
        case let .scrollTask(deltaY):
            ["deltaY": String(deltaY)]
        case let .insertComposerText(text), let .preparePluginPrompt(text):
            ["text": text]
        case let .insertSkillMention(name, displayName, path):
            [
                "name": name,
                "displayName": displayName,
                "path": path,
            ]
        case .clearComposerProject, .focusChatGPT, .toggleChatWorkMode, .submitActiveComposer,
             .pushToTalkStart, .pushToTalkStop, .stopActive, .queryRuntimeState:
            [:]
        }
    }

    public func jsonObject(id: Int) -> [String: Any] {
        [
            "v": 2,
            "type": "app-action",
            "id": id,
            "action": kind.rawValue,
            "payload": payload,
        ]
    }
}
