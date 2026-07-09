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

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation

#if os(macOS)
extension Application {
    /// Boot a FreeBSD VM through the real `VZVirtualMachineInstance` stack.
    ///
    /// Unlike `run`, this does not pull an OCI image, unpack an ext4 rootfs, or dial
    /// the Linux guest agent (vminitd over vsock) — FreeBSD has none of those yet.
    /// It boots a prebuilt FreeBSD raw disk via EFI and streams the serial console to
    /// a boot log. This is the first step toward a FreeBSD container: prove the
    /// containerization VM abstraction boots a FreeBSD guest. Guest control (exec,
    /// mounts) comes later via a FreeBSD agent over virtio-console.
    struct RunFreeBSD: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run-freebsd",
            abstract: "Boot a FreeBSD VM from a raw disk image (EFI, no guest agent)"
        )

        @Option(
            name: [.customLong("boot-disk"), .customShort("d")],
            help: "Path to a bootable FreeBSD arm64 raw disk image",
            completion: .file())
        var bootDisk: String

        @Option(
            name: .customLong("efi-store"),
            help: "Path to the EFI variable store (created if absent; defaults beside the disk)")
        var efiStore: String?

        @Option(
            name: [.customLong("boot-log"), .customShort("l")],
            help: "Path to write the serial boot log to")
        var bootLog: String?

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "Number of CPUs")
        var cpus: Int = 2

        @Option(name: [.customLong("memory"), .customShort("m")], help: "Memory in megabytes")
        var memory: UInt64 = 2048

        @Option(
            name: .customLong("exec"),
            help: "Run a command in the guest via the virtio-console agent, print its output, then stop")
        var exec: String?

        func run() async throws {
            let bootDiskURL = URL(fileURLWithPath: bootDisk).absoluteURL
            guard FileManager.default.fileExists(atPath: bootDiskURL.path) else {
                throw ContainerizationError(.notFound, message: "boot disk not found: \(bootDiskURL.path)")
            }

            let efiStoreURL =
                efiStore.map { URL(fileURLWithPath: $0).absoluteURL }
                ?? bootDiskURL.deletingLastPathComponent().appendingPathComponent("efi.vars")
            let bootLogURL =
                bootLog.map { URL(fileURLWithPath: $0).absoluteURL }
                ?? bootDiskURL.deletingLastPathComponent().appendingPathComponent("boot.log")

            log.info(
                "booting FreeBSD VM",
                metadata: [
                    "bootDisk": "\(bootDiskURL.path)",
                    "efiStore": "\(efiStoreURL.path)",
                    "bootLog": "\(bootLogURL.path)",
                    "cpus": "\(cpus)",
                    "memoryMB": "\(memory)",
                ])

            // When --exec is requested, attach a virtio-console agent channel via
            // an instance extension (no change to the core VM stack).
            let agentExt = exec != nil ? FreeBSDConsoleAgentExtension() : nil

            let instance = try VZVirtualMachineInstance(logger: log) { config in
                config.cpus = cpus
                config.memoryInBytes = memory.mib()
                // FreeBSD boots its own EFI loader from disk; no vminitd to dial.
                config.efiVariableStore = efiStoreURL
                config.dialsAgent = false
                config.initialFilesystem = .block(
                    format: "raw",
                    source: bootDiskURL.path,
                    destination: "/"
                )
                config.bootLog = .file(path: bootLogURL)
                if let agentExt { config.extensions.append(agentExt) }
            }

            try await instance.start()
            log.info("FreeBSD VM running; serial console -> \(bootLogURL.path).")

            // --exec: handshake with the guest agent, run the command, print its
            // output and exit code, then stop the VM.
            if let cmd = exec, let handle = agentExt?.hostHandle {
                let client = FreeBSDConsoleAgentClient(handle: handle, logger: log)
                client.start()
                defer { client.close() }
                log.info("waiting for guest agent ready")
                let ready = try await client.waitForReady()
                log.info(
                    "guest agent ready",
                    metadata: ["host": "\(ready.host ?? "?")", "release": "\(ready.release ?? "?")"])
                log.info("exec in guest", metadata: ["cmd": "\(cmd)"])
                let (code, output) = try await client.exec(cmd)
                print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
                log.info("exec complete", metadata: ["exitCode": "\(code)"])
                if instance.state == .running {
                    try await instance.stop()
                }
                log.info("FreeBSD VM stopped", metadata: ["state": "\(instance.state)"])
                return
            }

            log.info("Ctrl-C to stop.")
            let sigint = AsyncSignalHandler.create(notify: [SIGINT])

            // Wait until either Ctrl-C or the guest powers itself off.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in sigint.signals { break }
                }
                group.addTask {
                    while !Task.isCancelled && instance.state != .stopped {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                await group.next()
                group.cancelAll()
            }

            if instance.state == .running {
                log.info("stopping FreeBSD VM")
                try await instance.stop()
            }
            log.info("FreeBSD VM stopped", metadata: ["state": "\(instance.state)"])
        }
    }
}
#endif
