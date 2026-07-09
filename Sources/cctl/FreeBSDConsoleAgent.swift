//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import Synchronization
import Virtualization

/// Attaches a second virtio-console port to a `VZVirtualMachineInstance` for the
/// FreeBSD guest agent, without modifying the core VM stack. The boot-log serial
/// stays port 0 (`ttyV0.0`); this adds the agent channel (the guest auto-detects
/// it as the first non-console port). Backed by a duplex AF_UNIX socketpair: VZ
/// holds one end, the host the other (`hostHandle`).
///
/// FreeBSD has no vsock in base, so this is the transport that lets the host drive
/// the guest — the console analogue of vminitd-over-vsock.
final class FreeBSDConsoleAgentExtension: VZInstanceExtension, @unchecked Sendable {
    private let _hostHandle = Mutex<FileHandle?>(nil)

    /// The host end of the agent channel, available after the instance is created.
    var hostHandle: FileHandle? { _hostHandle.withLock { $0 } }

    func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        mountsByID: [String: [Mount]]
    ) throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ContainerizationError(.internalError, message: "failed to create agent socketpair: errno \(errno)")
        }
        // fd[0]: host side. fd[1]: VZ side (guest's agent ttyV*).
        let hostHandle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let vzHandle = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        _hostHandle.withLock { $0 = hostHandle }

        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: vzHandle,
            fileHandleForWriting: vzHandle
        )
        config.serialPorts.append(port)
    }

    func didCreate(_ instance: VZVirtualMachineInstance) throws {}

    func willStop(_ instance: VZVirtualMachineInstance) async throws {}
}

/// A frame exchanged with the FreeBSD guest agent over the virtio-console channel.
/// The protocol is newline-delimited JSON (JSONL). See
/// `container/Sources/Plugins/RuntimeFreeBSD/guest/README.md`.
struct FreeBSDAgentFrame: Decodable, Sendable {
    let event: String
    let version: String?
    let host: String?
    let release: String?
    let data: String?
    let code: Int?
    let out64: String?
}

/// Minimal host-side client for the FreeBSD guest agent over virtio-console.
/// Reads JSONL frames from the host end of the agent socketpair and lets callers
/// await the boot `ready` handshake and run commands (`exec`).
final class FreeBSDConsoleAgentClient: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let predicate: @Sendable (FreeBSDAgentFrame) -> Bool
        let cont: CheckedContinuation<FreeBSDAgentFrame, Error>
    }

    private let handle: FileHandle
    private let logger: Logger
    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [Waiter] = []
    private var closed = false

    init(handle: FileHandle, logger: Logger) {
        self.handle = handle
        self.logger = logger
    }

    func start() {
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { return }
            if chunk.isEmpty {
                self.handleEOF()
                return
            }
            self.ingest(chunk)
        }
    }

    func close() {
        handle.readabilityHandler = nil
        failAllWaiters(ContainerizationError(.internalError, message: "agent channel closed"))
        lock.withLock { closed = true }
    }

    // MARK: - Requests

    /// Await the guest agent's boot-time `ready` handshake.
    func waitForReady(timeoutSeconds: Double = 120) async throws -> FreeBSDAgentFrame {
        try await expect(timeoutSeconds: timeoutSeconds) { $0.event == "ready" }
    }

    /// Run a command in the guest, returning its exit code and combined output.
    func exec(_ command: String, timeoutSeconds: Double = 60) async throws -> (code: Int, output: String) {
        let cmd64 = Data(command.utf8).base64EncodedString()
        try send(["op": "exec", "cmd64": cmd64])
        let frame = try await expect(timeoutSeconds: timeoutSeconds) { $0.event == "exec" }
        var output = ""
        if let out64 = frame.out64, let data = Data(base64Encoded: out64) {
            output = String(decoding: data, as: UTF8.self)
        }
        return (frame.code ?? -1, output)
    }

    // MARK: - Internals

    private func send(_ object: [String: String]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func expect(
        timeoutSeconds: Double,
        where predicate: @escaping @Sendable (FreeBSDAgentFrame) -> Bool
    ) async throws -> FreeBSDAgentFrame {
        try await withThrowingTaskGroup(of: FreeBSDAgentFrame.self) { group in
            group.addTask { try await self.awaitFrame(where: predicate) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ContainerizationError(.timeout, message: "timed out after \(timeoutSeconds)s waiting for agent frame")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func awaitFrame(
        where predicate: @escaping @Sendable (FreeBSDAgentFrame) -> Bool
    ) async throws -> FreeBSDAgentFrame {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FreeBSDAgentFrame, Error>) in
                let alreadyClosed: Bool = lock.withLock {
                    if closed { return true }
                    waiters.append(Waiter(id: id, predicate: predicate, cont: cont))
                    return false
                }
                if alreadyClosed {
                    cont.resume(throwing: ContainerizationError(.internalError, message: "agent channel closed"))
                }
            }
        } onCancel: {
            let cont: CheckedContinuation<FreeBSDAgentFrame, Error>? = lock.withLock {
                guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: idx).cont
            }
            cont?.resume(throwing: CancellationError())
        }
    }

    private func ingest(_ chunk: Data) {
        var frames: [FreeBSDAgentFrame] = []
        lock.withLock {
            buffer.append(chunk)
            while let nl = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<nl.upperBound)
                guard !lineData.isEmpty else { continue }
                if let frame = try? JSONDecoder().decode(FreeBSDAgentFrame.self, from: lineData) {
                    frames.append(frame)
                } else if let raw = String(data: lineData, encoding: .utf8) {
                    logger.debug("agent non-json line", metadata: ["line": "\(raw)"])
                }
            }
        }
        for frame in frames { dispatch(frame) }
    }

    private func dispatch(_ frame: FreeBSDAgentFrame) {
        let cont: CheckedContinuation<FreeBSDAgentFrame, Error>? = lock.withLock {
            guard let idx = waiters.firstIndex(where: { $0.predicate(frame) }) else { return nil }
            return waiters.remove(at: idx).cont
        }
        cont?.resume(returning: frame)
    }

    private func handleEOF() {
        handle.readabilityHandler = nil
        failAllWaiters(ContainerizationError(.internalError, message: "agent channel reached EOF"))
    }

    private func failAllWaiters(_ error: Error) {
        let pending: [Waiter] = lock.withLock {
            let copy = waiters
            waiters.removeAll()
            return copy
        }
        for waiter in pending { waiter.cont.resume(throwing: error) }
    }
}
#endif
