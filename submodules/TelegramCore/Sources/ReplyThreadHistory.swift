import Foundation
import SyncCore
import Postbox
import SwiftSignalKit
import TelegramApi

private class ReplyThreadHistoryContextImpl {
    private let queue: Queue
    private let account: Account
    private let messageId: MessageId
    
    private var currentHole: (MessageHistoryHolesViewEntry, Disposable)?
    
    struct State: Equatable {
        var messageId: MessageId
        var holeIndices: [MessageId.Namespace: IndexSet]
        var maxReadIncomingMessageId: MessageId?
        var maxReadOutgoingMessageId: MessageId?
    }
    
    let state = Promise<State>()
    private var stateValue: State? {
        didSet {
            if let stateValue = self.stateValue {
                if stateValue != oldValue {
                    self.state.set(.single(stateValue))
                }
            }
        }
    }
    
    let maxReadOutgoingMessageId = Promise<MessageId?>()
    private var maxReadOutgoingMessageIdValue: MessageId? {
        didSet {
            if self.maxReadOutgoingMessageIdValue != oldValue {
                self.maxReadOutgoingMessageId.set(.single(self.maxReadOutgoingMessageIdValue))
            }
        }
    }
    
    private var initialStateDisposable: Disposable?
    private var holesDisposable: Disposable?
    private var readStateDisposable: Disposable?
    private let readDisposable = MetaDisposable()
    
    init(queue: Queue, account: Account, data: ChatReplyThreadMessage) {
        self.queue = queue
        self.account = account
        self.messageId = data.messageId
        
        self.maxReadOutgoingMessageIdValue = data.maxReadOutgoingMessageId
        self.maxReadOutgoingMessageId.set(.single(self.maxReadOutgoingMessageIdValue))
        
        self.initialStateDisposable = (account.postbox.transaction { transaction -> State in
            var indices = transaction.getThreadIndexHoles(peerId: data.messageId.peerId, threadId: makeMessageThreadId(data.messageId), namespace: Namespaces.Message.Cloud)
            indices.subtract(data.initialFilledHoles)
            
            let isParticipant = transaction.getPeerChatListIndex(data.messageId.peerId) != nil
            if isParticipant {
                let historyHoles = transaction.getHoles(peerId: data.messageId.peerId, namespace: Namespaces.Message.Cloud)
                indices.formIntersection(historyHoles)
            }
            
            if let maxMessageId = data.maxMessage {
                indices.remove(integersIn: Int(maxMessageId.id + 1) ..< Int(Int32.max))
            } else {
                indices.removeAll()
            }
            
            return State(messageId: data.messageId, holeIndices: [Namespaces.Message.Cloud: indices], maxReadIncomingMessageId: data.maxReadIncomingMessageId, maxReadOutgoingMessageId: data.maxReadOutgoingMessageId)
        }
        |> deliverOn(self.queue)).start(next: { [weak self] state in
            guard let strongSelf = self else {
                return
            }
            strongSelf.stateValue = state
            strongSelf.state.set(.single(state))
        })
        
        let threadId = makeMessageThreadId(messageId)
        
        self.holesDisposable = (account.postbox.messageHistoryHolesView()
        |> map { view -> MessageHistoryHolesViewEntry? in
            for entry in view.entries {
                switch entry.hole {
                case let .peer(hole):
                    if hole.threadId == threadId {
                        return entry
                    }
                }
            }
            return nil
        }
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] entry in
            guard let strongSelf = self else {
                return
            }
            strongSelf.setCurrentHole(entry: entry)
        })
        
        self.readStateDisposable = (account.stateManager.threadReadStateUpdates
        |> deliverOn(self.queue)).start(next: { [weak self] (_, outgoing) in
            guard let strongSelf = self else {
                return
            }
            if let value = outgoing[data.messageId] {
                strongSelf.maxReadOutgoingMessageIdValue = MessageId(peerId: data.messageId.peerId, namespace: Namespaces.Message.Cloud, id: value)
            }
        })
    }
    
    deinit {
        self.initialStateDisposable?.dispose()
        self.holesDisposable?.dispose()
        self.readDisposable.dispose()
    }
    
    func setCurrentHole(entry: MessageHistoryHolesViewEntry?) {
        if self.currentHole?.0 != entry {
            self.currentHole?.1.dispose()
            if let entry = entry {
                self.currentHole = (entry, self.fetchHole(entry: entry).start(next: { [weak self] removedHoleIndices in
                    guard let strongSelf = self else {
                        return
                    }
                    if var currentHoles = strongSelf.stateValue?.holeIndices[Namespaces.Message.Cloud] {
                        currentHoles.subtract(removedHoleIndices.removedIndices)
                        strongSelf.stateValue?.holeIndices[Namespaces.Message.Cloud] = currentHoles
                    }
                }))
            } else {
                self.currentHole = nil
            }
        }
    }
    
    private func fetchHole(entry: MessageHistoryHolesViewEntry) -> Signal<FetchMessageHistoryHoleResult, NoError> {
        switch entry.hole {
        case let .peer(hole):
            let fetchCount = min(entry.count, 100)
            return fetchMessageHistoryHole(accountPeerId: self.account.peerId, source: .network(self.account.network), postbox: self.account.postbox, peerInput: .direct(peerId: hole.peerId, threadId: hole.threadId), namespace: hole.namespace, direction: entry.direction, space: entry.space, count: fetchCount)
        }
    }
    
    func applyMaxReadIndex(messageIndex: MessageIndex) {
        let account = self.account
        let messageId = self.messageId
        
        if messageIndex.id.namespace != messageId.namespace {
            return
        }
        
        let signal = self.account.postbox.transaction { transaction -> Api.InputPeer? in
            if let message = transaction.getMessage(messageId) {
                for attribute in message.attributes {
                    if let attribute = attribute as? SourceReferenceMessageAttribute {
                        if let sourceMessage = transaction.getMessage(attribute.messageId) {
                            var updatedAttribute: ReplyThreadMessageAttribute?
                            for i in 0 ..< sourceMessage.attributes.count {
                                if let attribute = sourceMessage.attributes[i] as? ReplyThreadMessageAttribute {
                                    if let maxReadMessageId = attribute.maxReadMessageId {
                                        if maxReadMessageId < messageIndex.id.id {
                                            updatedAttribute = ReplyThreadMessageAttribute(count: attribute.count, latestUsers: attribute.latestUsers, commentsPeerId: attribute.commentsPeerId, maxMessageId: attribute.maxMessageId, maxReadMessageId: messageIndex.id.id)
                                        }
                                    } else {
                                        updatedAttribute = ReplyThreadMessageAttribute(count: attribute.count, latestUsers: attribute.latestUsers, commentsPeerId: attribute.commentsPeerId, maxMessageId: attribute.maxMessageId, maxReadMessageId: messageIndex.id.id)
                                    }
                                    break
                                }
                            }
                            if let updatedAttribute = updatedAttribute {
                                transaction.updateMessage(sourceMessage.id, update: { currentMessage in
                                    var attributes = currentMessage.attributes
                                    loop: for j in 0 ..< attributes.count {
                                        if let _ = attributes[j] as? ReplyThreadMessageAttribute {
                                            attributes[j] = updatedAttribute
                                        }
                                    }
                                    return .update(StoreMessage(id: currentMessage.id, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
                                })
                            }
                        }
                        break
                    }
                }
            }
            
            return transaction.getPeer(messageIndex.id.peerId).flatMap(apiInputPeer)
        }
        |> mapToSignal { inputPeer -> Signal<Never, NoError> in
            guard let inputPeer = inputPeer else {
                return .complete()
            }
            return account.network.request(Api.functions.messages.readDiscussion(peer: inputPeer, msgId: messageId.id, readMaxId: messageIndex.id.id))
            |> `catch` { _ -> Signal<Api.Bool, NoError> in
                return .single(.boolFalse)
            }
            |> ignoreValues
        }
        self.readDisposable.set(signal.start())
    }
}

public class ReplyThreadHistoryContext {
    fileprivate final class GuardReference {
        private let deallocated: () -> Void
        
        init(deallocated: @escaping () -> Void) {
            self.deallocated = deallocated
        }
        
        deinit {
            self.deallocated()
        }
    }
    
    private let queue = Queue()
    private let impl: QueueLocalObject<ReplyThreadHistoryContextImpl>
    
    public var state: Signal<MessageHistoryViewExternalInput, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                let stateDisposable = impl.state.get().start(next: { state in
                    subscriber.putNext(MessageHistoryViewExternalInput(
                        peerId: state.messageId.peerId,
                        threadId: makeMessageThreadId(state.messageId),
                        maxReadIncomingMessageId: state.maxReadIncomingMessageId,
                        maxReadOutgoingMessageId: state.maxReadOutgoingMessageId,
                        holes: state.holeIndices
                    ))
                })
                disposable.set(stateDisposable)
            }
            
            return disposable
        }
    }
    
    public var maxReadOutgoingMessageId: Signal<MessageId?, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                disposable.set(impl.maxReadOutgoingMessageId.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            
            return disposable
        }
    }
    
    public init(account: Account, peerId: PeerId, data: ChatReplyThreadMessage) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return ReplyThreadHistoryContextImpl(queue: queue, account: account, data: data)
        })
    }
    
    public func applyMaxReadIndex(messageIndex: MessageIndex) {
        self.impl.with { impl in
            impl.applyMaxReadIndex(messageIndex: messageIndex)
        }
    }
}

public struct ChatReplyThreadMessage: Equatable {
    public var messageId: MessageId
    public var isChannelPost: Bool
    public var maxMessage: MessageId?
    public var maxReadIncomingMessageId: MessageId?
    public var maxReadOutgoingMessageId: MessageId?
    public var initialFilledHoles: IndexSet
    
    fileprivate init(messageId: MessageId, isChannelPost: Bool, maxMessage: MessageId?, maxReadIncomingMessageId: MessageId?, maxReadOutgoingMessageId: MessageId?, initialFilledHoles: IndexSet) {
        self.messageId = messageId
        self.isChannelPost = isChannelPost
        self.maxMessage = maxMessage
        self.maxReadIncomingMessageId = maxReadIncomingMessageId
        self.maxReadOutgoingMessageId = maxReadOutgoingMessageId
        self.initialFilledHoles = initialFilledHoles
    }
}

public enum FetchChannelReplyThreadMessageError {
    case generic
}

public func fetchChannelReplyThreadMessage(account: Account, messageId: MessageId) -> Signal<ChatReplyThreadMessage, FetchChannelReplyThreadMessageError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(messageId.peerId).flatMap(apiInputPeer)
    }
    |> castError(FetchChannelReplyThreadMessageError.self)
    |> mapToSignal { inputPeer -> Signal<ChatReplyThreadMessage, FetchChannelReplyThreadMessageError> in
        guard let inputPeer = inputPeer else {
            return .fail(.generic)
        }
        
        let replyInfo = Promise<AccountViewTracker.UpdatedMessageReplyInfo?>()
        replyInfo.set(account.viewTracker.replyInfoForMessageId(messageId))
        
        struct DiscussionMessage {
            public var messageId: MessageId
            public var isChannelPost: Bool
            public var maxMessage: MessageId?
            public var maxReadIncomingMessageId: MessageId?
            public var maxReadOutgoingMessageId: MessageId?
        }
        
        let remoteDiscussionMessageSignal: Signal<DiscussionMessage?, NoError> = account.network.request(Api.functions.messages.getDiscussionMessage(peer: inputPeer, msgId: messageId.id))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.messages.DiscussionMessage?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { discussionMessage -> Signal<DiscussionMessage?, NoError> in
            guard let discussionMessage = discussionMessage else {
                return .single(nil)
            }
            return account.postbox.transaction { transaction -> DiscussionMessage? in
                switch discussionMessage {
                case let .discussionMessage(_, messages, maxId, readInboxMaxId, readOutboxMaxId, chats, users):
                    let parsedMessages = messages.compactMap { message -> StoreMessage? in
                        StoreMessage(apiMessage: message)
                    }
                    
                    guard let topMessage = parsedMessages.last, let parsedIndex = topMessage.index else {
                        return nil
                    }
                    
                    var peers: [Peer] = []
                    var peerPresences: [PeerId: PeerPresence] = [:]
                    
                    for chat in chats {
                        if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                            peers.append(groupOrChannel)
                        }
                    }
                    for user in users {
                        let telegramUser = TelegramUser(user: user)
                        peers.append(telegramUser)
                        if let presence = TelegramUserPresence(apiUser: user) {
                            peerPresences[telegramUser.id] = presence
                        }
                    }
                    
                    let _ = transaction.addMessages(parsedMessages, location: .Random)
                    
                    updatePeers(transaction: transaction, peers: peers, update: { _, updated -> Peer in
                        return updated
                    })
                    
                    updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                    
                    let resolvedMaxMessage: MessageId?
                    if let maxId = maxId {
                        resolvedMaxMessage = MessageId(
                            peerId: parsedIndex.id.peerId,
                            namespace: Namespaces.Message.Cloud,
                            id: maxId
                        )
                    } else {
                        resolvedMaxMessage = nil
                    }
                    
                    return DiscussionMessage(
                        messageId: parsedIndex.id,
                        isChannelPost: true,
                        maxMessage: resolvedMaxMessage,
                        maxReadIncomingMessageId: readInboxMaxId.flatMap { readMaxId in
                            MessageId(peerId: parsedIndex.id.peerId, namespace: Namespaces.Message.Cloud, id: readMaxId)
                        },
                        maxReadOutgoingMessageId: readOutboxMaxId.flatMap { readMaxId in
                            MessageId(peerId: parsedIndex.id.peerId, namespace: Namespaces.Message.Cloud, id: readMaxId)
                        }
                    )
                }
            }
        }
        let discussionMessageSignal = (replyInfo.get()
        |> mapToSignal { replyInfo -> Signal<DiscussionMessage?, NoError> in
            guard let replyInfo = replyInfo else {
                return .single(nil)
            }
            return account.postbox.transaction { transaction -> DiscussionMessage? in
                let isParticipant = transaction.getPeerChatListIndex(replyInfo.commentsPeerId) != nil
                
                guard isParticipant else {
                    return nil
                }
                var foundDiscussionMessageId: MessageId?
                transaction.scanMessageAttributes(peerId: replyInfo.commentsPeerId, namespace: Namespaces.Message.Cloud, limit: 1000, { id, attributes in
                    for attribute in attributes {
                        if let attribute = attribute as? SourceReferenceMessageAttribute {
                            if attribute.messageId == messageId {
                                foundDiscussionMessageId = id
                                return true
                            }
                        }
                    }
                    if foundDiscussionMessageId != nil {
                        return false
                    }
                    return true
                })
                guard let discussionMessageId = foundDiscussionMessageId else {
                    return nil
                }
                return DiscussionMessage(
                    messageId: discussionMessageId,
                    isChannelPost: true,
                    maxMessage: replyInfo.maxMessageId,
                    maxReadIncomingMessageId: replyInfo.maxReadIncomingMessageId,
                    maxReadOutgoingMessageId: nil
                )
            }
        })
        |> mapToSignal { result -> Signal<DiscussionMessage?, NoError> in
            if let result = result {
                return .single(result)
            } else {
                return remoteDiscussionMessageSignal
            }
        }
        let discussionMessage = Promise<DiscussionMessage?>()
        discussionMessage.set(discussionMessageSignal)
        
        let preloadedHistoryPosition: Signal<(FetchMessageHistoryHoleThreadInput, PeerId, MessageId?, MessageId?, MessageId?), FetchChannelReplyThreadMessageError> = replyInfo.get()
            |> castError(FetchChannelReplyThreadMessageError.self)
        |> mapToSignal { replyInfo -> Signal<(FetchMessageHistoryHoleThreadInput, PeerId, MessageId?, MessageId?, MessageId?), FetchChannelReplyThreadMessageError> in
            if let replyInfo = replyInfo {
                return account.postbox.transaction { transaction -> (FetchMessageHistoryHoleThreadInput, PeerId, MessageId?, MessageId?, MessageId?) in
                    var threadInput: FetchMessageHistoryHoleThreadInput = .threadFromChannel(channelMessageId: messageId)
                    var threadMessageId: MessageId?
                    transaction.scanMessageAttributes(peerId: replyInfo.commentsPeerId, namespace: Namespaces.Message.Cloud, limit: 1000, { id, attributes in
                        for attribute in attributes {
                            if let attribute = attribute as? SourceReferenceMessageAttribute {
                                if attribute.messageId == messageId {
                                    threadMessageId = id
                                    threadInput = .direct(peerId: id.peerId, threadId: makeMessageThreadId(id))
                                    return false
                                }
                            }
                        }
                        return true
                    })
                    return (threadInput, replyInfo.commentsPeerId, threadMessageId, replyInfo.maxReadIncomingMessageId, replyInfo.maxMessageId)
                }
                |> castError(FetchChannelReplyThreadMessageError.self)
            } else {
                return discussionMessage.get()
                |> castError(FetchChannelReplyThreadMessageError.self)
                |> mapToSignal { discussionMessage -> Signal<(FetchMessageHistoryHoleThreadInput, PeerId, MessageId?, MessageId?, MessageId?), FetchChannelReplyThreadMessageError> in
                    guard let discussionMessage = discussionMessage else {
                        return .fail(.generic)
                    }
                    
                    let topMessageId = discussionMessage.messageId
                    let commentsPeerId = topMessageId.peerId
                    return .single((.direct(peerId: commentsPeerId, threadId: makeMessageThreadId(topMessageId)), commentsPeerId, discussionMessage.messageId, discussionMessage.maxReadIncomingMessageId, discussionMessage.maxMessage))
                }
            }
        }
        
        let preloadedHistory = preloadedHistoryPosition
        |> mapToSignal { peerInput, commentsPeerId, threadMessageId, aroundMessageId, maxMessageId -> Signal<FetchMessageHistoryHoleResult, FetchChannelReplyThreadMessageError> in
            guard let maxMessageId = maxMessageId else {
                return .single(FetchMessageHistoryHoleResult(removedIndices: IndexSet(integersIn: 1 ..< Int(Int32.max - 1)), strictRemovedIndices: IndexSet()))
            }
            return account.postbox.transaction { transaction -> Signal<FetchMessageHistoryHoleResult, FetchChannelReplyThreadMessageError> in
                if let threadMessageId = threadMessageId {
                    var holes = transaction.getThreadIndexHoles(peerId: threadMessageId.peerId, threadId: makeMessageThreadId(threadMessageId), namespace: Namespaces.Message.Cloud)
                    holes.remove(integersIn: Int(maxMessageId.id + 1) ..< Int(Int32.max))
                    
                    let isParticipant = transaction.getPeerChatListIndex(commentsPeerId) != nil
                    if isParticipant {
                        let historyHoles = transaction.getHoles(peerId: commentsPeerId, namespace: Namespaces.Message.Cloud)
                        holes.formIntersection(historyHoles)
                    }
                    
                    let anchor: HistoryViewInputAnchor
                    if let aroundMessageId = aroundMessageId {
                        anchor = .message(aroundMessageId)
                    } else {
                        anchor = .upperBound
                    }
                    
                    let testView = transaction.getMessagesHistoryViewState(
                        input: .external(MessageHistoryViewExternalInput(
                            peerId: commentsPeerId,
                            threadId: makeMessageThreadId(threadMessageId),
                            maxReadIncomingMessageId: nil,
                            maxReadOutgoingMessageId: nil,
                            holes: [
                                Namespaces.Message.Cloud: holes
                            ]
                        )),
                        count: 30,
                        clipHoles: true,
                        anchor: anchor,
                        namespaces: .not(Namespaces.Message.allScheduled)
                    )
                    if !testView.isLoading {
                        return .single(FetchMessageHistoryHoleResult(removedIndices: IndexSet(), strictRemovedIndices: IndexSet()))
                    }
                }
                
                let direction: MessageHistoryViewRelativeHoleDirection
                if let aroundMessageId = aroundMessageId {
                    direction = .aroundId(aroundMessageId)
                } else {
                    direction = .range(start: MessageId(peerId: commentsPeerId, namespace: Namespaces.Message.Cloud, id: Int32.max - 1), end: MessageId(peerId: commentsPeerId, namespace: Namespaces.Message.Cloud, id: 1))
                }
                return fetchMessageHistoryHole(accountPeerId: account.peerId, source: .network(account.network), postbox: account.postbox, peerInput: peerInput, namespace: Namespaces.Message.Cloud, direction: direction, space: .everywhere, count: 30)
                |> castError(FetchChannelReplyThreadMessageError.self)
            }
            |> castError(FetchChannelReplyThreadMessageError.self)
            |> switchToLatest
        }
        
        return combineLatest(
            discussionMessage.get()
            |> castError(FetchChannelReplyThreadMessageError.self),
            preloadedHistory
        )
        |> mapToSignal { discussionMessage, initialFilledHoles -> Signal<ChatReplyThreadMessage, FetchChannelReplyThreadMessageError> in
            guard let discussionMessage = discussionMessage else {
                return .fail(.generic)
            }
            return account.postbox.transaction { transaction -> Signal<ChatReplyThreadMessage, FetchChannelReplyThreadMessageError> in
                for range in initialFilledHoles.strictRemovedIndices.rangeView {
                    transaction.removeThreadIndexHole(peerId: discussionMessage.messageId.peerId, threadId: makeMessageThreadId(discussionMessage.messageId), namespace: Namespaces.Message.Cloud, space: .everywhere, range: Int32(range.lowerBound) ... Int32(range.upperBound))
                }
                
                return .single(ChatReplyThreadMessage(
                    messageId: discussionMessage.messageId,
                    isChannelPost: discussionMessage.isChannelPost,
                    maxMessage: discussionMessage.maxMessage,
                    maxReadIncomingMessageId: discussionMessage.maxReadIncomingMessageId,
                    maxReadOutgoingMessageId: discussionMessage.maxReadOutgoingMessageId,
                    initialFilledHoles: initialFilledHoles.removedIndices
                ))
            }
            |> castError(FetchChannelReplyThreadMessageError.self)
            |> switchToLatest
        }
    }
}
