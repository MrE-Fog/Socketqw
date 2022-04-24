//
//  SocketManager.swift
//  
//
//  Created by Alsey Coleman Miller on 4/1/22.
//

import Foundation
import SystemPackage

/// Socket Manager
internal actor SocketManager {
    
    static let shared = SocketManager()
    
    private var sockets = [FileDescriptor: SocketState]()
    
    private var pollDescriptors = [FileDescriptor.Poll]()
    
    private var isMonitoring = false
        
    private init() { }
    
    private func startMonitoring() {
        guard isMonitoring == false else { return }
        log("Will start monitoring")
        isMonitoring = true
        // Add to runloop of background thread from concurrency thread pool
        Task(priority: Socket.configuration.monitorPriority) { [weak self] in
            while let self = self, isMonitoring {
                do {
                    try await Task.sleep(nanoseconds: Socket.configuration.monitorInterval)
                    try await self.poll()
                    // stop monitoring if no sockets
                    if pollDescriptors.isEmpty {
                        isMonitoring = false
                    }
                }
                catch {
                    log("Socket monitoring failed. \(error.localizedDescription)")
                    assertionFailure("Socket monitoring failed. \(error.localizedDescription)")
                    isMonitoring = false
                }
            }
        }
    }
    
    func contains(_ fileDescriptor: FileDescriptor) -> Bool {
        return sockets.keys.contains(fileDescriptor)
    }
    
    func add(
        fileDescriptor: FileDescriptor,
        event: ((Socket.Event) -> ())? = nil
    ) {
        guard sockets.keys.contains(fileDescriptor) == false else {
            log("Another socket for file descriptor \(fileDescriptor) already exists.")
            assertionFailure("Another socket already exists")
            return
        }
        log("Add socket \(fileDescriptor).")
        // append socket
        sockets[fileDescriptor] = SocketState(
            fileDescriptor: fileDescriptor,
            event: event
        )
        updatePollDescriptors()
        startMonitoring()
    }
    
    func remove(_ fileDescriptor: FileDescriptor, error: Error? = nil) async {
        guard let socket = sockets[fileDescriptor] else {
            return // could have been removed by `poll()`
        }
        log("Remove socket \(fileDescriptor) \(error?.localizedDescription ?? "")")
        // update sockets to monitor
        sockets[fileDescriptor] = nil
        updatePollDescriptors()
        // close actual socket
        await socket.close(error ?? Errno.connectionAbort)
        // notify
        await socket.event?(.close(error))
    }
    
    @discardableResult
    internal func write(_ data: Data, for fileDescriptor: FileDescriptor) async throws -> Int {
        guard let socket = sockets[fileDescriptor] else {
            log("Unable to write unknown socket \(fileDescriptor).")
            assertionFailure("\(#function) Unknown socket \(fileDescriptor)")
            throw Errno.invalidArgument
        }
        // attempt to execute immediately
        let event: FileEvents = .write
        try await poll()
        // wait until event is recieved
        if try events(for: fileDescriptor).contains(event) == false {
            try await withThrowingContinuation(for: fileDescriptor) { (continuation: SocketContinuation<(), Error>) in
                Task { [weak socket] in
                    guard let socket = socket else {
                        continuation.resume(throwing: Errno.connectionAbort)
                        return
                    }
                    await socket.queue(event: event, continuation)
                }
            }
        }
        return try await socket.write(data)
    }
    
    internal func read(_ length: Int, for fileDescriptor: FileDescriptor) async throws -> Data {
        guard let socket = sockets[fileDescriptor] else {
            log("Unable to read unknown socket \(fileDescriptor).")
            assertionFailure("\(#function) Unknown socket \(fileDescriptor)")
            throw Errno.invalidArgument
        }
        // attempt to execute immediately
        let event: FileEvents = .read
        try await poll()
        // wait until event is recieved
        if try events(for: fileDescriptor).contains(event) == false {
            try await withThrowingContinuation(for: fileDescriptor) { (continuation: SocketContinuation<(), Error>) in
                Task { [weak socket] in
                    guard let socket = socket else {
                        continuation.resume(throwing: Errno.connectionAbort)
                        return
                    }
                    await socket.queue(event: event, continuation)
                }
            }
        }
        return try await socket.read(length)
    }
    
    internal func setEvent(_ event: ((Socket.Event) -> ())?, for fileDescriptor: FileDescriptor) async throws {
        guard let socket = sockets[fileDescriptor] else {
            log("Unable to set event for unknown socket \(fileDescriptor).")
            assertionFailure("\(#function) Unknown socket \(fileDescriptor)")
            throw Errno.invalidArgument
        }
        await socket.setEvent(event)
    }
    
    internal func event(for fileDescriptor: FileDescriptor) async throws -> ((Socket.Event) -> ())? {
        guard let socket = sockets[fileDescriptor] else {
            log("Unknown socket \(fileDescriptor).")
            assertionFailure("\(#function) Unknown socket \(fileDescriptor)")
            throw Errno.invalidArgument
        }
        return await socket.event
    }
    
    private func events(for fileDescriptor: FileDescriptor) throws -> FileEvents {
        guard let poll = pollDescriptors.first(where: { $0.fileDescriptor == fileDescriptor }) else {
            throw Errno.connectionAbort
        }
        return poll.returnedEvents
    }
    
    private func updatePollDescriptors() {
        pollDescriptors = sockets.keys
            .lazy
            .sorted(by: { $0.rawValue < $1.rawValue })
            .map { FileDescriptor.Poll(fileDescriptor: $0, events: .socket) }
    }
    
    private func poll() async throws {
        pollDescriptors.reset()
        do {
            try pollDescriptors.poll()
        }
        catch {
            log("Unable to poll for events. \(error.localizedDescription)")
            throw error
        }
        
        // wait for concurrent handling
        for poll in pollDescriptors {
            if poll.returnedEvents.contains(.write) {
                await self.canWrite(poll.fileDescriptor)
            }
            if poll.returnedEvents.contains(.read) {
                await self.shouldRead(poll.fileDescriptor)
            }
            if poll.returnedEvents.contains(.invalidRequest) {
                assertionFailure("Polled for invalid socket \(poll.fileDescriptor)")
                await self.error(.badFileDescriptor, for: poll.fileDescriptor)
            }
            if poll.returnedEvents.contains(.hangup) {
                await self.error(.connectionReset, for: poll.fileDescriptor)
            }
            if poll.returnedEvents.contains(.error) {
                await self.error(.connectionAbort, for: poll.fileDescriptor)
            }
        }
    }
    
    private func error(_ error: Errno, for fileDescriptor: FileDescriptor) async {
        await self.remove(fileDescriptor, error: error)
    }
    
    private func shouldRead(_ fileDescriptor: FileDescriptor) async {
        guard let socket = self.sockets[fileDescriptor] else {
            log("Pending read for unknown socket \(fileDescriptor).")
            assertionFailure("\(#function) Unknown socket \(fileDescriptor)")
            return
        }
        // stop waiting
        if await socket.isBusy == false {
            await socket.dequeue(event: .read)?.resume()
        }
        // notify
        await socket.event?(.pendingRead)
    }
    
    private func canWrite(_ fileDescriptor: FileDescriptor) async {
        guard let socket = self.sockets[fileDescriptor] else {
            log("Can write for unknown socket \(fileDescriptor).")
            assertionFailure("\(#function) Unknown socket \(fileDescriptor)")
            return
        }
        // stop waiting
        if await socket.isBusy == false {
            await socket.dequeue(event: .write)?.resume()
        }
    }
}

// MARK: - Supporting Types

extension SocketManager {
    
    actor SocketState {
        
        let fileDescriptor: FileDescriptor
        
        var event: ((Socket.Event) -> ())?
        
        public var isBusy = false
        
        private var pendingEvent = [FileEvents: [SocketContinuation<(), Error>]]()
        
        init(fileDescriptor: FileDescriptor,
             event: ((Socket.Event) -> ())? = nil
        ) {
            self.fileDescriptor = fileDescriptor
            self.event = event
        }
        
        func close(_ error: Error) {
            // cancel all continuations
            for event in pendingEvent.keys {
                dequeue(event: event)?.resume(throwing: error)
            }
            // close underlying socket
            try? fileDescriptor.close()
        }
        
        func setEvent(_ newValue: ((Socket.Event) -> ())?) {
            self.event = newValue
        }
        
        func queue(event: FileEvents, _ continuation: SocketContinuation<(), Error>) {
            pendingEvent[event, default: []].append(continuation)
        }
        
        func dequeue(event: FileEvents) -> SocketContinuation<(), Error>? {
            guard pendingEvent[event, default: []].isEmpty == false else {
                return nil
            }
            return pendingEvent[event, default: []].removeFirst()
        }
    }
}

extension SocketManager.SocketState {
    
    func write(_ data: Data) throws -> Int {
        assert(isBusy == false)
        isBusy = true
        defer { isBusy = false }
        log("Will write \(data.count) bytes to \(fileDescriptor)")
        let byteCount = try data.withUnsafeBytes {
            try fileDescriptor.write($0)
        }
        // notify
        event?(.write(byteCount))
        return byteCount
    }
    
    func read(_ length: Int) throws -> Data {
        assert(isBusy == false)
        isBusy = true
        defer { isBusy = false }
        log("Will read \(length) bytes to \(fileDescriptor)")
        var data = Data(count: length)
        let bytesRead = try data.withUnsafeMutableBytes {
            try fileDescriptor.read(into: $0)
        }
        if bytesRead < length {
            data = data.prefix(bytesRead)
        }
        // notify
        event?(.read(bytesRead))
        return data
    }
}
