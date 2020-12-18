import Foundation
import UIKit
import Postbox
import TelegramCore
import SyncCore
import TelegramPresentationData
import MergeLists

enum CallListNodeEntryId: Hashable {
    case setting(Int32)
    case groupCall(PeerId)
    case hole(MessageIndex)
    case message(MessageIndex)
}

private func areMessagesEqual(_ lhsMessage: Message, _ rhsMessage: Message) -> Bool {
    if lhsMessage.stableVersion != rhsMessage.stableVersion {
        return false
    }
    if lhsMessage.id != rhsMessage.id || lhsMessage.flags != rhsMessage.flags {
        return false
    }
    return true
}

enum CallListNodeEntry: Comparable, Identifiable {
    enum SortIndex: Comparable {
        case displayTab
        case displayTabInfo
        case groupCall(PeerId, String)
        case message(MessageIndex)
        case hole(MessageIndex)
        
        static func <(lhs: SortIndex, rhs: SortIndex) -> Bool {
            switch lhs {
            case .displayTab:
                return false
            case .displayTabInfo:
                switch rhs {
                case .displayTab:
                    return true
                default:
                    return false
                }
            case let .groupCall(lhsPeerId, lhsTitle):
                switch rhs {
                case .displayTab, .displayTabInfo:
                    return false
                case let .groupCall(rhsPeerId, rhsTitle):
                    if lhsTitle == rhsTitle {
                        return lhsPeerId < rhsPeerId
                    } else {
                        return lhsTitle < rhsTitle
                    }
                case .message, .hole:
                    return true
                }
            case let .hole(lhsIndex):
                switch rhs {
                case .displayTab, .displayTabInfo, .groupCall:
                    return false
                case let .hole(rhsIndex):
                    return lhsIndex < rhsIndex
                case let .message(rhsIndex):
                    return lhsIndex < rhsIndex
                }
            case let .message(lhsIndex):
                switch rhs {
                case .displayTab, .displayTabInfo, .groupCall:
                    return false
                case let .hole(rhsIndex):
                    return lhsIndex < rhsIndex
                case let .message(rhsIndex):
                    return lhsIndex < rhsIndex
                }
                
            }
        }
    }
    
    case displayTab(PresentationTheme, String, Bool)
    case displayTabInfo(PresentationTheme, String)
    case groupCall(peer: Peer, editing: Bool, isActive: Bool)
    case messageEntry(topMessage: Message, messages: [Message], theme: PresentationTheme, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, editing: Bool, hasActiveRevealControls: Bool, displayHeader: Bool)
    case holeEntry(index: MessageIndex, theme: PresentationTheme)
    
    var sortIndex: SortIndex {
        switch self {
        case .displayTab:
            return .displayTab
        case .displayTabInfo:
            return .displayTabInfo
        case let .groupCall(peer, _, _):
            return .groupCall(peer.id, peer.compactDisplayTitle)
        case let .messageEntry(message, _, _, _, _, _, _, _):
            return .message(message.index)
        case let .holeEntry(index, _):
            return .hole(index)
        }
    }
    
    var stableId: CallListNodeEntryId {
        switch self {
        case .displayTab:
            return .setting(0)
        case .displayTabInfo:
            return .setting(1)
        case let .groupCall(peer, _, _):
            return .groupCall(peer.id)
        case let .messageEntry(message, _, _, _, _, _, _, _):
            return .message(message.index)
        case let .holeEntry(index, _):
            return .hole(index)
        }
    }
    
    static func <(lhs: CallListNodeEntry, rhs: CallListNodeEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }
    
    static func ==(lhs: CallListNodeEntry, rhs: CallListNodeEntry) -> Bool {
        switch lhs {
            case let .displayTab(lhsTheme, lhsText, lhsValue):
                if case let .displayTab(rhsTheme, rhsText, rhsValue) = rhs, lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue {
                    return true
                } else {
                    return false
                }
            case let .displayTabInfo(lhsTheme, lhsText):
                if case let .displayTabInfo(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .groupCall(lhsPeer, lhsEditing, lhsIsActive):
                if case let .groupCall(rhsPeer, rhsEditing, rhsIsActive) = rhs {
                    if !lhsPeer.isEqual(rhsPeer) {
                        return false
                    }
                    if lhsEditing != rhsEditing {
                        return false
                    }
                    if lhsIsActive != rhsIsActive {
                        return false
                    }
                    return true
                } else {
                    return false
                }
            case let .messageEntry(lhsMessage, lhsMessages, lhsTheme, lhsStrings, lhsDateTimeFormat, lhsEditing, lhsHasRevealControls, lhsDisplayHeader):
                if case let .messageEntry(rhsMessage, rhsMessages, rhsTheme, rhsStrings, rhsDateTimeFormat, rhsEditing, rhsHasRevealControls, rhsDisplayHeader) = rhs {
                    if lhsTheme !== rhsTheme {
                        return false
                    }
                    if lhsStrings !== rhsStrings {
                        return false
                    }
                    if lhsDateTimeFormat != rhsDateTimeFormat {
                        return false
                    }
                    if lhsEditing != rhsEditing {
                        return false
                    }
                    if lhsHasRevealControls != rhsHasRevealControls {
                        return false
                    }
                    if lhsDisplayHeader != rhsDisplayHeader {
                        return false
                    }
                    if !areMessagesEqual(lhsMessage, rhsMessage) {
                        return false
                    }
                    if lhsMessages.count != rhsMessages.count {
                        return false
                    }
                    for i in 0 ..< lhsMessages.count {
                        if !areMessagesEqual(lhsMessages[i], rhsMessages[i]) {
                            return false
                        }
                    }
                    return true
                } else {
                    return false
                }
            case let .holeEntry(lhsIndex, lhsTheme):
                if case let .holeEntry(rhsIndex, rhsTheme) = rhs, lhsIndex == rhsIndex, lhsTheme === rhsTheme {
                    return true
                } else {
                    return false
                }
        }
    }
}

func callListNodeEntriesForView(view: CallListView, groupCalls: [Peer], state: CallListNodeState, showSettings: Bool, showCallsTab: Bool, isRecentCalls: Bool, currentGroupCallPeerId: PeerId?) -> [CallListNodeEntry] {
    var result: [CallListNodeEntry] = []
    for entry in view.entries {
        switch entry {
            case let .message(topMessage, messages):
                result.append(.messageEntry(topMessage: topMessage, messages: messages, theme: state.presentationData.theme, strings: state.presentationData.strings, dateTimeFormat: state.dateTimeFormat, editing: state.editing, hasActiveRevealControls: state.messageIdWithRevealedOptions == topMessage.id, displayHeader: !showSettings && isRecentCalls))
            case let .hole(index):
                result.append(.holeEntry(index: index, theme: state.presentationData.theme))
        }
    }
    
    if !showSettings && isRecentCalls {
        for peer in groupCalls.sorted(by: { lhs, rhs in
            let lhsTitle = lhs.compactDisplayTitle
            let rhsTitle = rhs.compactDisplayTitle
            if lhsTitle != rhsTitle {
                return lhsTitle < rhsTitle
            }
            return lhs.id < rhs.id
        }).reversed() {
            result.append(.groupCall(peer: peer, editing: state.editing, isActive: currentGroupCallPeerId == peer.id))
        }
    }
    
    if showSettings {
        result.append(.displayTabInfo(state.presentationData.theme, state.presentationData.strings.CallSettings_TabIconDescription))
        result.append(.displayTab(state.presentationData.theme, state.presentationData.strings.CallSettings_TabIcon, showCallsTab))
    }
    return result
}

func countMeaningfulCallListEntries(_ entries: [CallListNodeEntry]) -> Int {
    var count: Int = 0
    for entry in entries {
        if case .setting = entry.stableId {} else {
            count += 1
        }
    }
    return count
}
