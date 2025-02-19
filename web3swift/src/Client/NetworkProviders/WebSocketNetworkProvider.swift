//
//  web3.swift
//  Copyright © 2022 Argent Labs Limited. All rights reserved.
//

import BigInt
import Foundation
import GenericJSON
import Logging
import NIO
import NIOCore
import NIOSSL
import NIOWebSocket
import WebSocketKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

class WebSocketNetworkProvider: WebSocketNetworkProviderProtocol {
    private struct WebSocketRequest {
        var payload: String
        var callback: (Result<Data, JSONRPCError>) -> Void
    }

    private class SharedResources {
        private let semaphore = DispatchSemaphore(value: 1)
        // Requests that have not sent yet
        private(set) var requestQueue: [Int: WebSocketRequest] = [:]
        // Requests that have been sent and waiting for Response
        private(set) var responseQueue: [Int: WebSocketRequest] = [:]
        // List with current subscriptions
        private(set) var subscriptions: [EthereumSubscription: (Any) -> Void] = [:]

        private(set) var counter: Int = 0 {
            didSet {
                if counter == Int.max {
                    counter = 0
                }
            }
        }

        func addRequest(_ key: Int, request: WebSocketRequest) {
            exclusiveAccess(requestQueue[key] = request)
        }

        func removeRequest(_ key: Int) {
            exclusiveAccess({requestQueue.removeValue(forKey: key)}())
        }

        func addResponse(_ key: Int, request: WebSocketRequest) {
            exclusiveAccess(responseQueue[key] = request)
        }

        func removeResponse(_ key: Int) {
            exclusiveAccess({responseQueue.removeValue(forKey: key)}())
        }

        func addSubscription(_ subscription: EthereumSubscription, callback: @escaping (Any) -> Void) {
            exclusiveAccess(subscriptions[subscription] = callback)
        }

        func removeSubscription(_ subscription: EthereumSubscription) {
            exclusiveAccess({subscriptions.removeValue(forKey: subscription)}())
        }

        func incrementCounter() {
            exclusiveAccess(counter += 1)
        }

        func cleanSubscriptions() {
            exclusiveAccess(subscriptions.removeAll())
        }

        private func exclusiveAccess(_ access: @autoclosure () -> Void) {
            semaphore.wait()
            access()
            semaphore.signal()
        }
    }

    weak var delegate: EthereumWebSocketClientDelegate?

    var session: URLSession
    var onReconnectCallback: (() -> Void)?
    let url: String
    let eventLoopGroup: EventLoopGroup

    private(set) var currentState: WebSocketState = .closed

    private let eventLoopGroupProvider: EventLoopGroupProvider
    private let logger: Logger
    private let configuration: WebSocketConfiguration
    private let resources = SharedResources()
    private let semaphore = DispatchSemaphore(value: 1)

    private var reconnectAttempts = 0
    private var forcedClose = false
    private var timedOut = false

    private var retreivedNetwork: EthereumNetwork?
    private var webSocket: WebSocket?

    // won't ship with production code thanks to #if DEBUG
    // WebSocket is need it for testing purposes
#if DEBUG
    func exposeWebSocket() -> WebSocket? {
        return webSocket
    }
#endif

    required init(url: String,
                  eventLoopGroupProvider: EventLoopGroupProvider = .createNew,
                  configuration: WebSocketConfiguration = .init(),
                  session: URLSession,
                  logger: Logger? = nil) {
        self.url = url
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        case .createNew:
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        }
        self.logger = logger ?? Logger(label: "web3.swift.eth-websocket-client")
        self.configuration = configuration
        self.session = session
        // Whether or not to create a websocket upon instantiation
        if configuration.automaticOpen {
            connect(reconnectAttempt: false)
        }
    }

    deinit {
        self.logger.trace("Shutting down WebSocket")
        disconnect()

        switch self.eventLoopGroupProvider {
        case .shared:
            self.logger.trace("Running on shared EventLoopGroup. Not shutting down EventLoopGroup.")
        case .createNew:
            self.logger.trace("Shutting down EventLoopGroup")
            do {
                try self.eventLoopGroup.syncShutdownGracefully()
            } catch {
                self.logger.warning("Shutting down EventLoopGroup failed: \(error)")
            }
        }
    }

    func send<T, P, U>(method: String, params: P, receive: U.Type, completionHandler: @escaping (Result<T, EthereumClientError>) -> Void, resultDecodeHandler: @escaping (Result<Any, Error>) -> Void) where P: Encodable, U: Decodable {
        semaphore.wait()

        defer {
            semaphore.signal()
        }
        resources.incrementCounter()
        let id = resources.counter

        let requestString: String

        do {
            requestString = try encodeRequest(method: method, params: params, id: id)
        } catch {
            completionHandler(.failure(.encodeIssue))
            return
        }

        let wsRequest = WebSocketRequest(payload: requestString, callback: decoding(receive.self) { result in
            resultDecodeHandler(result.mapError({ error in
                return error
            }))
        })

        // if socket is not connected yet or reconnecting
        // add request to the queue
        if currentState == .connecting {
            resources.addRequest(id, request: wsRequest)
            return
        }

        // if socket is closed remove pending request
        // and return failure
        if currentState != .open {
            resources.removeRequest(id)
            completionHandler(.failure(.connectionNotOpen))
            return
        }

        resources.addResponse(id, request: wsRequest)
        resources.removeRequest(id)

        let sendPromise = eventLoopGroup.next().makePromise(of: Void.self)
        sendPromise.futureResult.whenFailure({ error in
            completionHandler(.failure(.webSocketError(EquatableError(base: error))))
            self.resources.removeResponse(id)
        })
        webSocket?.send(requestString, promise: sendPromise)
    }

    func connect() {
        connect(reconnectAttempt: false)
    }

    func disconnect(code: WebSocketErrorCode = .goingAway) {
        do {
            forcedClose = true
            try webSocket?.close(code: code).wait()
        } catch {
            logger.warning("Clossing WebSocket failed:  \(error)")
        }
    }

    /// Additional public API method to refresh the connection if still open (close, re-open).
    /// For example, if the app suspects bad data / missed heart beats, it can try to refresh.
    func refresh() {
        do {
            try webSocket?.close(code: .goingAway).wait()
        } catch {
            logger.warning("Failed to Close WebSocket: \(error)")
        }
    }

    func reconnect() {
        for response in resources.responseQueue {
            response.value.callback(.failure(.pendingRequestsOnReconnecting))
            resources.removeResponse(response.key)
        }

        var delay = configuration.reconnectInterval * Int(pow(configuration.reconnectDecay, Double(reconnectAttempts)))
        if delay > configuration.maxReconnectInterval {
            delay = configuration.maxReconnectInterval
        }

        logger.trace("WebSocket reconnecting... Delay: \(delay) ms")

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: {
            self.reconnectAttempts += 1
            self.connect(reconnectAttempt: true)
        })
    }

    func addSubscription(_ subscription: EthereumSubscription, callback: @escaping (Any) -> Void) {
        resources.addSubscription(subscription, callback: callback)
    }

    func removeSubscription(_ subscription: EthereumSubscription) {
        resources.removeSubscription(subscription)
    }

    private func connect(reconnectAttempt: Bool) {
        if let ws = webSocket, !ws.isClosed {
            return
        }

        if reconnectAttempt, configuration.maxReconnectAttempts > 0, reconnectAttempts > configuration.maxReconnectAttempts {
            logger.trace("WebSocket reached maxReconnectAttempts. Stop trying")

            for request in resources.requestQueue {
                request.value.callback(.failure(.maxAttemptsReachedOnReconnecting))
                resources.removeRequest(request.key)
            }
            reconnectAttempts = 0
            return
        }

        logger.trace("Requesting WebSocket connection")

        do {
            currentState = .connecting

            _ = try WebSocket.connect(to: url,
                                      configuration: WebSocketClient.Configuration(tlsConfiguration: configuration.tlsConfiguration,
                                                                                   maxFrameSize: configuration.maxFrameSize),
                                      on: eventLoopGroup) { ws in
                self.logger.trace("WebSocket connected")

                if reconnectAttempt {
                    self.delegate?.onWebSocketReconnect()
                    self.onReconnectCallback?()
                }

                self.webSocket = ws
                self.currentState = .open
                self.reconnectAttempts = 0

                // Send pending requests and delete
                for request in self.resources.requestQueue {
                    ws.send(request.value.payload)
                    self.resources.removeRequest(request.key)
                }

                ws.onText { [weak self] _, string in
                    guard let self = self else { return }

                    if let data = string.data(using: .utf8),
                       let json = try? JSONDecoder().decode(JSON.self, from: data),
                       let subscriptionId = json["params"]?.objectValue?["subscription"]?.stringValue,
                       let subscription = self.resources.subscriptions.first(where: { $0.key.id == subscriptionId }) {
                        switch subscription.key.type {
                        case .newBlockHeaders:
                            if let data = string.data(using: .utf8), let response = try? JSONDecoder().decode(JSONRPCSubscriptionResponse<EthereumHeader>.self, from: data) {
                                self.delegate?.onNewBlockHeader(subscription: subscription.key, header: response.params.result)
                                subscription.value(response.params.result)
                            }
                        case .pendingTransactions:
                            if let data = string.data(using: .utf8), let response = try? JSONDecoder().decode(JSONRPCSubscriptionResponse<String>.self, from: data) {
                                self.delegate?.onNewPendingTransaction(subscription: subscription.key, txHash: response.params.result)
                                subscription.value(response.params.result)
                            }
                        case .syncing:
                            if let data = string.data(using: .utf8), let response = try? JSONDecoder().decode(JSONRPCSubscriptionResponse<EthereumSyncStatus>.self, from: data) {
                                self.delegate?.onSyncing(subscription: subscription.key, sync: response.params.result)
                                subscription.value(response.params.result)
                            }
                        }
                    }

                    if let data = string.data(using: .utf8),
                       let json = try? JSONDecoder().decode(JSON.self, from: data),
                       let responseId = json["id"]?.doubleValue {
                        guard let response = self.resources.responseQueue.first(where: { $0.key == Int(responseId) }) else { return }
                        response.value.callback(.success(data))
                        self.resources.removeResponse(response.key)
                    }
                }

                ws.onClose.whenComplete { value in
                    if let code = ws.closeCode {
                        self.logger.trace("WebSocket closed. Code: \(code)")
                    } else {
                        self.logger.trace("WebSocket closed")
                    }

                    for request in self.resources.requestQueue {
                        request.value.callback(.failure(.connectionNotOpen))
                        self.resources.removeRequest(request.key)
                    }

                    for response in self.resources.responseQueue {
                        response.value.callback(.failure(.invalidConnection))
                        self.resources.removeResponse(response.key)
                    }

                    self.resources.cleanSubscriptions()

                    if self.forcedClose {
                        self.currentState = .closed
                    } else {
                        self.currentState = .connecting

                        self.reconnect()
                    }
                }

            }.wait()
        } catch {
            currentState = .closed
            logger.error("WebSocket connection failed: \(error)")

            for request in resources.requestQueue {
                request.value.callback(.failure(.connectionNotOpen))
                resources.removeRequest(request.key)
            }

            for response in resources.responseQueue {
                response.value.callback(.failure(.connectionNotOpen))
                resources.removeResponse(response.key)
            }

            resources.cleanSubscriptions()

            if case ChannelError.connectTimeout = error {
                reconnect()
            }
        }
    }

    private func encodeRequest<P: Encodable>(method: String, params: P, id: Int) throws -> String {
        let rpcRequest = JSONRPCRequest(jsonrpc: "2.0", method: method, params: params, id: id)
        logger.trace("\(rpcRequest)")
        let data = try JSONEncoder().encode(rpcRequest)

        guard let dataString = String(data: data, encoding: .utf8) else {
            throw JSONRPCError.encodingError
        }

        return dataString
    }

    private func decoding<T: Decodable>(_ type: T.Type, then: @escaping (Result<Any, JSONRPCError>) -> Void) -> (Result<Data, JSONRPCError>) -> Void {
        return { dataResult in
            let decodedResult: Result<Any, JSONRPCError> = dataResult.tryMap { data in
                if let result = try? JSONDecoder().decode(JSONRPCResult<T>.self, from: data) {
                    return result.result
                } else if let result = try? JSONDecoder().decode([JSONRPCResult<T>].self, from: data) {
                    let resultObjects = result.map { return $0.result }
                    return resultObjects
                } else if let errorResult = try? JSONDecoder().decode(JSONRPCErrorResult.self, from: data) {
                    throw JSONRPCError.executionError(errorResult)
                } else {
                    throw JSONRPCError.noResult
                }

            }
            then(decodedResult)
        }
    }
}
