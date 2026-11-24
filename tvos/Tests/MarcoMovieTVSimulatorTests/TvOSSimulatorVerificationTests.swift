// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network
import XCTest
@testable import MarcoTVCore

#if os(tvOS)
import AVFoundation
import SwiftUI
import UIKit
@testable import MarcoMovieTV

// MARK: - Loopback HTTP & WebDAV Test Doubles (tvOS Simulator)

private final class SimLoopbackMediaServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "marco.sim.media.server")
    private(set) var port: UInt16 = 0
    private var posterHits: [String: Int] = [:]
    private var posterBytesByPath: [String: Data] = [:]

    var baseUrl: String { "http://127.0.0.1:\(port)" }

    func setPosterPng(_ data: Data, forPath path: String) {
        lock.lock()
        posterBytesByPath[path] = data
        lock.unlock()
    }

    func resetPosterCounts() {
        lock.lock()
        posterHits.removeAll()
        lock.unlock()
    }

    func posterHitCount(forPath path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return posterHits[path] ?? 0
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = NSLock()
            var done = false
            listener.stateUpdateHandler = { state in
                resumed.lock()
                defer { resumed.unlock() }
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    self.port = listener.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let err):
                    done = true
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn: conn, buffer: Data())
    }

    private func receiveRequest(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else {
                conn.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let headerRange = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(decoding: next[..<headerRange.lowerBound], as: UTF8.self)
                let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
                let parts = requestLine.split(separator: " ")
                let rawTarget = parts.count >= 2 ? String(parts[1]) : "/"
                self.respond(conn: conn, rawTarget: rawTarget)
                return
            }
            if isComplete {
                conn.cancel()
            } else {
                self.receiveRequest(conn: conn, buffer: next)
            }
        }
    }

    private func respond(conn: NWConnection, rawTarget: String) {
        let comps = URLComponents(string: "http://127.0.0.1\(rawTarget)")
        let path = comps?.path ?? rawTarget
        let query = Dictionary(
            uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        if path.hasPrefix("/poster/") {
            lock.lock()
            posterHits[path, default: 0] += 1
            let png = posterBytesByPath[path] ?? Data()
            lock.unlock()
            sendResponse(conn: conn, status: "200 OK", contentType: "image/png", body: png)
            return
        }

        if path == "/sub/public.json" {
            let cfg: [String: Any] = [
                "sites": [
                    [
                        "key": "pub_cms",
                        "name": "公开影院源",
                        "type": 1,
                        "api": "\(baseUrl)/api/public",
                    ],
                ],
                "lives": [
                    [
                        "name": "公开直播",
                        "type": 0,
                        "url": "\(baseUrl)/live/public.m3u",
                    ],
                ],
            ]
            sendJson(conn: conn, object: cfg)
            return
        }

        if path == "/sub/private.json" {
            let cfg: [String: Any] = [
                "sites": [
                    [
                        "key": "priv_cms",
                        "name": "私密影院源",
                        "type": 1,
                        "api": "\(baseUrl)/api/private",
                    ],
                ],
                "lives": [
                    [
                        "name": "私密直播",
                        "type": 0,
                        "url": "\(baseUrl)/live/private.m3u",
                    ],
                ],
            ]
            sendJson(conn: conn, object: cfg)
            return
        }

        if path == "/live/public.m3u" {
            let m3u = """
            #EXTM3U
            #EXTINF:-1 group-title="公开频道",公开新闻台
            \(baseUrl)/media/public_live.m3u8
            """
            sendResponse(conn: conn, status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data(m3u.utf8))
            return
        }

        if path == "/live/private.m3u" {
            let m3u = """
            #EXTM3U
            #EXTINF:-1 group-title="私密频道",秘密频道
            \(baseUrl)/media/private_live.m3u8
            """
            sendResponse(conn: conn, status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data(m3u.utf8))
            return
        }

        if path == "/api/public" {
            let ac = query["ac"] ?? ""
            if ac == "detail" && !(query["ids"] ?? "").isEmpty {
                let vod: [String: Any] = [
                    "vod_id": "101",
                    "vod_name": "星际漫游记",
                    "vod_pic": "\(baseUrl)/poster/public_1.png",
                    "vod_remarks": "更新至第12集",
                    "vod_year": "2026",
                    "vod_area": "科幻",
                    "vod_content": "用于 tvOS 模拟器端到端回归验证的本地合成影片条目。",
                    "vod_play_from": "极速主线$$$备用线路",
                    "vod_play_url": "第1集$\(baseUrl)/media/ep1.m3u8#第2集$\(baseUrl)/media/ep2.m3u8$$$第1集$\(baseUrl)/media/ep1_b.m3u8#第2集$\(baseUrl)/media/ep2_b.m3u8",
                ]
                sendJson(conn: conn, object: ["code": 1, "list": [vod]])
            } else {
                let list: [[String: Any]] = [
                    [
                        "vod_id": "101",
                        "vod_name": "星际漫游记",
                        "vod_pic": "\(baseUrl)/poster/public_1.png",
                        "vod_remarks": "更新至第12集",
                    ],
                    [
                        "vod_id": "102",
                        "vod_name": "深海观测站",
                        "vod_pic": "\(baseUrl)/poster/public_2.png",
                        "vod_remarks": "HD 4K",
                    ],
                    [
                        "vod_id": "103",
                        "vod_name": "极光列车",
                        "vod_pic": "\(baseUrl)/poster/public_3.png",
                        "vod_remarks": "全8集",
                    ],
                ]
                sendJson(
                    conn: conn,
                    object: [
                        "code": 1,
                        "page": 1,
                        "pagecount": 1,
                        "class": [
                            ["type_id": "1", "type_name": "电影"],
                            ["type_id": "2", "type_name": "剧集"],
                        ],
                        "list": list,
                    ]
                )
            }
            return
        }

        if path == "/api/private" {
            let ac = query["ac"] ?? ""
            let vod: [String: Any] = [
                "vod_id": "99",
                "vod_name": "机密测试片",
                "vod_pic": "\(baseUrl)/poster/secret_99.png",
                "vod_remarks": "全1集",
                "vod_play_from": "私密线路",
                "vod_play_url": "第1集$\(baseUrl)/media/secret.m3u8",
            ]
            if ac == "detail" {
                sendJson(conn: conn, object: ["code": 1, "list": [vod]])
            } else {
                sendJson(
                    conn: conn,
                    object: [
                        "code": 1,
                        "page": 1,
                        "pagecount": 1,
                        "class": [["type_id": "9", "type_name": "私密分类"]],
                        "list": [vod],
                    ]
                )
            }
            return
        }

        sendResponse(conn: conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
    }

    private func sendJson(conn: NWConnection, object: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        sendResponse(conn: conn, status: "200 OK", contentType: "application/json; charset=utf-8", body: body)
    }

    private func sendResponse(conn: NWConnection, status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

private final class SimLoopbackWebDavServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "marco.sim.webdav.server")
    private(set) var port: UInt16 = 0
    private var files: [String: (body: Data, etag: String)] = [:]
    private var versionCounter = 0

    var baseUrl: String { "http://127.0.0.1:\(port)/dav" }

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = NSLock()
            var done = false
            listener.stateUpdateHandler = { state in
                resumed.lock()
                defer { resumed.unlock() }
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    self.port = listener.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let err):
                    done = true
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHttp(conn: conn, buffer: Data())
    }

    private func readHttp(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else {
                conn.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let headerRange = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(decoding: next[..<headerRange.lowerBound], as: UTF8.self)
                let lines = headerText.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let idx = line.firstIndex(of: ":") {
                        let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                        let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                let bodyStart = headerRange.upperBound
                if next.count - bodyStart >= contentLength {
                    let body = next.subdata(in: bodyStart..<(bodyStart + contentLength))
                    let reqLine = (lines.first ?? "").split(separator: " ")
                    let method = reqLine.first.map(String.init) ?? "GET"
                    let path = reqLine.count >= 2 ? String(reqLine[1]) : "/"
                    self.handleRequest(conn: conn, method: method, path: path, headers: headers, body: body)
                    return
                }
            }
            if isComplete {
                conn.cancel()
            } else {
                self.readHttp(conn: conn, buffer: next)
            }
        }
    }

    private func handleRequest(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        lock.lock()
        defer { lock.unlock() }
        switch method {
        case "MKCOL":
            send(conn: conn, status: "201 Created", headers: [:], body: Data())
        case "GET":
            if let existing = files[path] {
                send(conn: conn, status: "200 OK", headers: ["ETag": existing.etag, "Content-Type": "application/json"], body: existing.body)
            } else {
                send(conn: conn, status: "404 Not Found", headers: [:], body: Data())
            }
        case "PUT":
            if let inm = headers["if-none-match"], inm == "*", files[path] != nil {
                send(conn: conn, status: "412 Precondition Failed", headers: [:], body: Data())
                return
            }
            if let im = headers["if-match"], let existing = files[path], existing.etag != im {
                send(conn: conn, status: "412 Precondition Failed", headers: [:], body: Data())
                return
            }
            versionCounter += 1
            let newTag = "\"v\(versionCounter)\""
            files[path] = (body: body, etag: newTag)
            send(conn: conn, status: "200 OK", headers: ["ETag": newTag], body: Data())
        default:
            send(conn: conn, status: "200 OK", headers: [:], body: Data())
        }
    }

    private func send(conn: NWConnection, status: String, headers: [String: String], body: Data) {
        var raw = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { raw += "\(k): \(v)\r\n" }
        raw += "\r\n"
        var payload = Data(raw.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

private final class SimLoopbackHlsServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "marco.sim.hls.server")
    private(set) var port: UInt16 = 0
    private var playlistHits = 0
    private var slowStarted = 0
    private var slowCancelled = 0
    private var lastAuthHeader = ""
    private var activeSlowTimers: [DispatchSourceTimer] = []

    var baseUrl: String { "http://127.0.0.1:\(port)" }

    struct Stats {
        let playlistHits: Int
        let slowStarted: Int
        let slowCancelled: Int
        let lastAuthHeader: String
    }

    func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(
            playlistHits: playlistHits,
            slowStarted: slowStarted,
            slowCancelled: slowCancelled,
            lastAuthHeader: lastAuthHeader
        )
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = NSLock()
            var done = false
            listener.stateUpdateHandler = { state in
                resumed.lock()
                defer { resumed.unlock() }
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    self.port = listener.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let err):
                    done = true
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock()
        let timers = activeSlowTimers
        activeSlowTimers.removeAll()
        lock.unlock()
        timers.forEach { $0.cancel() }
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn: conn, buffer: Data())
    }

    private func readRequest(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, _ in
            guard let self else {
                conn.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let headerRange = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(decoding: next[..<headerRange.lowerBound], as: UTF8.self)
                let lines = headerText.components(separatedBy: "\r\n")
                let reqParts = (lines.first ?? "").split(separator: " ")
                let path = reqParts.count >= 2 ? String(reqParts[1]) : "/"
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let idx = line.firstIndex(of: ":") {
                        headers[line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()] =
                            line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                self.dispatchRoute(conn: conn, path: path, headers: headers)
                return
            }
            if isComplete {
                conn.cancel()
            } else {
                self.readRequest(conn: conn, buffer: next)
            }
        }
    }

    private func dispatchRoute(conn: NWConnection, path: String, headers: [String: String]) {
        if let auth = headers["x-sim-auth"] {
            lock.lock()
            lastAuthHeader = auth
            lock.unlock()
        }

        if path == "/play/slow.m3u8" {
            lock.lock()
            playlistHits += 1
            lock.unlock()
            let m3u8 = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:6
            #EXT-X-MEDIA-SEQUENCE:0
            #EXTINF:6.0,
            /seg/slow.ts
            #EXT-X-ENDLIST
            """
            sendSimple(conn: conn, status: "200 OK", contentType: "application/vnd.apple.mpegurl", body: Data(m3u8.utf8))
            return
        }

        if path == "/play/fast.m3u8" {
            let m3u8 = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:6
            #EXT-X-MEDIA-SEQUENCE:0
            #EXTINF:6.0,
            /seg/fast.ts
            #EXT-X-ENDLIST
            """
            sendSimple(conn: conn, status: "200 OK", contentType: "application/vnd.apple.mpegurl", body: Data(m3u8.utf8))
            return
        }

        if path == "/seg/fast.ts" {
            var tsPacket = Data(repeating: 0x00, count: 188)
            tsPacket[0] = 0x47
            sendSimple(conn: conn, status: "200 OK", contentType: "video/mp2t", body: tsPacket)
            return
        }

        if path == "/seg/slow.ts" {
            lock.lock()
            slowStarted += 1
            lock.unlock()

            let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: 4194304\r\nConnection: close\r\n\r\n"
            var firstChunk = Data(head.utf8)
            var tsPacket = Data(repeating: 0x00, count: 188)
            tsPacket[0] = 0x47
            firstChunk.append(tsPacket)

            let closedLock = NSLock()
            var markedCancelled = false
            let timer = DispatchSource.makeTimerSource(queue: queue)

            let markCancelled: () -> Void = { [weak self] in
                closedLock.lock()
                let shouldMark = !markedCancelled
                markedCancelled = true
                closedLock.unlock()
                timer.cancel()
                if shouldMark {
                    self?.lock.lock()
                    self?.slowCancelled += 1
                    self?.lock.unlock()
                }
                conn.cancel()
            }

            // Detect peer EOF / RST promptly when proxy revokes session
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16) { _, _, isComplete, err in
                if isComplete || err != nil {
                    markCancelled()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled:
                    markCancelled()
                default:
                    break
                }
            }

            conn.send(content: firstChunk, completion: .contentProcessed { err in
                if err != nil {
                    markCancelled()
                }
            })

            var sentTicks = 0
            timer.schedule(deadline: .now() + .milliseconds(80), repeating: .milliseconds(80))
            timer.setEventHandler {
                sentTicks += 1
                if sentTicks > 200 {
                    timer.cancel()
                    conn.cancel()
                    return
                }
                conn.send(content: tsPacket, completion: .contentProcessed { err in
                    if err != nil {
                        markCancelled()
                    }
                })
            }
            lock.lock()
            activeSlowTimers.append(timer)
            lock.unlock()
            timer.resume()
            return
        }

        sendSimple(conn: conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
    }

    private func sendSimple(conn: NWConnection, status: String, contentType: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - tvOS Simulator End-to-End Verification Suite

@MainActor
final class TvOSSimulatorVerificationTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marco-sim-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makePosterPng(top: UIColor, bottom: UIColor, title: String) -> Data {
        let size = CGSize(width: 320, height: 480)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { ctx in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    grad,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 34),
                .foregroundColor: UIColor.white,
            ]
            let textRect = CGRect(x: 24, y: size.height - 120, width: size.width - 48, height: 96)
            (title as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    private func activeSimulatorWindow() throws -> UIWindow {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            throw NSError(
                domain: "TvOSSimulatorVerificationTests",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No active UIWindowScene in tvOS Simulator"]
            )
        }
        if let existing = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            existing.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            existing.makeKeyAndVisible()
            return existing
        }
        let created = UIWindow(windowScene: scene)
        created.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        created.makeKeyAndVisible()
        return created
    }

    @discardableResult
    private func renderAndCapture<V: View>(
        _ view: V,
        filename: String,
        settleSeconds: Double = 0.85
    ) async throws -> UIImage {
        let window = try activeSimulatorWindow()
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        host.view.frame = window.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let deadline = Date().addingTimeInterval(settleSeconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let pngData = try XCTUnwrap(image.pngData(), "Failed to encode tvOS Simulator screenshot \(filename)")
        XCTAssertGreaterThan(pngData.count, 8_000, "Screenshot \(filename) unexpectedly small/blank")
        XCTAssertTrue(hasVisibleNonBlackContent(image), "Screenshot \(filename) appears completely black")

        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let shotDir = cachesDir.appendingPathComponent("sim-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try pngData.write(to: shotDir.appendingPathComponent(filename), options: .atomic)

        let attachment = XCTAttachment(image: image)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func hasVisibleNonBlackContent(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let width = 64
        let height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var brightPixels = 0
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[idx] > 18 || pixels[idx + 1] > 18 || pixels[idx + 2] > 18 {
                brightPixels += 1
            }
        }
        return brightPixels > 20
    }

    // MARK: - Sim Test 1: Real tvOS App Bundle, Assets.car, QuickJS-NG & Keychain

    func testSim01_AppBundleAssetsBrandLogoQuickJsAndKeychainOnTvOS() async throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.pilipala.marcoMovie.tv")

        let resourceRoot = try XCTUnwrap(Bundle.main.resourceURL, "MarcoMovieTV.app resourceURL missing")
        let jsHostDir = resourceRoot.appendingPathComponent("js-host", isDirectory: true)
        for required in ["bootstrap.js", "catvod.mjs", "crypto-js.js", "crypto.LICENSE", "drpy-core.js", "module-interop.js"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: jsHostDir.appendingPathComponent(required).path),
                "Missing bundled js-host/\(required) inside MarcoMovieTV.app on tvOS Simulator"
            )
        }
        let catpawManifest = resourceRoot
            .appendingPathComponent("catpaw", isDirectory: true)
            .appendingPathComponent("drpy-assets.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: catpawManifest.path))

        let logoImage = UIImage(named: "BrandLogoMark")
        XCTAssertNotNil(logoImage, "BrandLogoMark must load from compiled Assets.car on tvOS")
        XCTAssertGreaterThan(logoImage?.size.width ?? 0, 0)

        // Execute a real DRPY QuickJS script inside tvOS Simulator using bundled assets
        let rule = #"""
        var rule = {
            title: 'tvOS 模拟器脚本校验',
            host: 'https://sim-drpy.invalid',
            class_name: '模拟器映画',
            class_url: '1',
            推荐: 'js:VODS=[{vod_id:"sim_1",vod_name:"QuickJS在tvOS运行正常"}];',
            一级: 'js:VODS=[];',
            二级: 'js:VOD={vod_id:"sim_1",vod_name:"QuickJS在tvOS运行正常",vod_play_from:"主线",vod_play_url:"正片$https://cdn.invalid/ok.m3u8"};',
            搜索: 'js:VODS=[];'
        };
        """#
        let site = CmsSite(key: "sim_drpy", name: "模拟器脚本源", type: 3, api: "csp_Drpy")
        let drpyHost = try DrpySourceHost(
            site: site,
            ruleSource: rule,
            origin: "https://sim-drpy.invalid/rule.js",
            httpTransport: { url, _, _, _, _ in
                JsHttpResponse(statusCode: 200, headers: [:], body: Data("<html></html>".utf8), finalUrl: url)
            }
        )
        let home = try await drpyHost.homeContent(filter: false)
        XCTAssertEqual(home.categories.first?.name, "模拟器映画")
        XCTAssertEqual(home.listing.videos.first?.title, "QuickJS在tvOS运行正常")

        // Verify SystemKeychainStore roundtrip on tvOS Simulator
        let keychain = SystemKeychainStore(service: "com.pilipala.marcoMovie.tv.simtest")
        let testAccount = "sim_verify_\(UUID().uuidString)"
        let payload = Data("marco-tvos-sim-keychain-ok".utf8)
        defer { try? keychain.removeData(forAccount: testAccount) }
        try keychain.setData(payload, forAccount: testAccount)
        let loaded = try keychain.data(forAccount: testAccount)
        XCTAssertEqual(loaded, payload)
    }

    // MARK: - Sim Test 2: Two Devices Same Subscription URL -> WebDAV Sync -> Resume + UI Captures

    func testSim02_TwoDevicesSameUrlWebDavSyncResumeAndDiscoverDetailUI() async throws {
        let mediaServer = SimLoopbackMediaServer()
        mediaServer.setPosterPng(
            makePosterPng(top: UIColor(red: 0.11, green: 0.25, blue: 0.56, alpha: 1), bottom: UIColor(red: 0.05, green: 0.09, blue: 0.18, alpha: 1), title: "星际漫游记"),
            forPath: "/poster/public_1.png"
        )
        mediaServer.setPosterPng(
            makePosterPng(top: UIColor(red: 0.09, green: 0.42, blue: 0.48, alpha: 1), bottom: UIColor(red: 0.04, green: 0.12, blue: 0.17, alpha: 1), title: "深海观测站"),
            forPath: "/poster/public_2.png"
        )
        mediaServer.setPosterPng(
            makePosterPng(top: UIColor(red: 0.36, green: 0.19, blue: 0.52, alpha: 1), bottom: UIColor(red: 0.08, green: 0.06, blue: 0.16, alpha: 1), title: "极光列车"),
            forPath: "/poster/public_3.png"
        )
        let davServer = SimLoopbackWebDavServer()
        try await mediaServer.start()
        try await davServer.start()
        defer {
            mediaServer.stop()
            davServer.stop()
        }

        let storageA = TvStorageManager(cachesDirectory: try makeTempDir("devA"), keychain: InMemoryKeychainStore())
        let storageB = TvStorageManager(cachesDirectory: try makeTempDir("devB"), keychain: InMemoryKeychainStore())
        let appA = AppViewModel(storage: storageA)
        let appB = AppViewModel(storage: storageB)

        let subUrl = "\(mediaServer.baseUrl)/sub/public.json"
        try await appA.importSubscriptionFromUrl(subUrl, name: "公开影院源")
        try await appB.importSubscriptionFromUrl(subUrl, name: "公开影院源")

        XCTAssertEqual(appA.subscriptions.first?.id, appB.subscriptions.first?.id)
        XCTAssertEqual(appA.discoverVideos.count, 3)

        // Render live Discover screen on tvOS Simulator and capture screenshot
        _ = try await renderAndCapture(
            LivingRoomShellView().environmentObject(appA),
            filename: "02_discover_configured.png",
            settleSeconds: 1.1
        )

        let activeSiteA = try XCTUnwrap(appA.activeSite)
        let video101 = try XCTUnwrap(appA.discoverVideos.first { $0.id == "101" })

        appA.recordPlaybackProgress(
            site: activeSiteA,
            video: video101,
            lineName: "极速主线",
            episodeName: "第1集",
            episodeIndex: 0,
            positionMs: 420_000,
            durationMs: 2_700_000
        )
        appA.toggleFavorite(site: activeSiteA, video: video101)

        // Render live DetailView showing resume state ("续播 · 第1集") on tvOS Simulator
        _ = try await renderAndCapture(
            DetailView(site: activeSiteA, summaryVideo: video101).environmentObject(appA),
            filename: "03_detail_resume_stage.png",
            settleSeconds: 1.0
        )

        // Sync Device A -> WebDAV -> Device B
        appA.webdavConfig = WebDavConfig(url: davServer.baseUrl, username: "u", password: "p", autoSync: false)
        await appA.triggerManualWebDavSync()

        appB.webdavConfig = WebDavConfig(url: davServer.baseUrl, username: "u", password: "p", autoSync: false)
        await appB.triggerManualWebDavSync()

        let histOnB = try XCTUnwrap(appB.watchHistory.first { $0.id == "101" })
        XCTAssertEqual(histOnB.position, 420_000)
        XCTAssertEqual(appB.favorites.count, 1)

        // Open history card on Device B -> must resolve to origin site (NOT unavailable!)
        appB.openWatchHistoryItem(histOnB)
        let detailCtxB = try XCTUnwrap(appB.selectedDetailContext, "Device B must resolve synced history card to origin site")
        XCTAssertEqual(detailCtxB.video.id, "101")

        // Resume & advance on B, unfavorite on B, sync back to A
        appB.recordPlaybackProgress(
            site: detailCtxB.site,
            video: video101,
            lineName: "极速主线",
            episodeName: "第2集",
            episodeIndex: 1,
            positionMs: 915_000,
            durationMs: 2_700_000
        )
        appB.toggleFavorite(site: detailCtxB.site, video: video101)
        XCTAssertTrue(appB.favorites.isEmpty)
        await appB.triggerManualWebDavSync()

        await appA.triggerManualWebDavSync()
        let updatedOnA = try XCTUnwrap(appA.watchHistory.first { $0.id == "101" })
        XCTAssertEqual(updatedOnA.episode, "第2集")
        XCTAssertEqual(updatedOnA.position, 915_000)
        XCTAssertTrue(appA.favorites.isEmpty, "Unfavorite on Device B must propagate back to Device A")
    }

    // MARK: - Sim Test 3: Private Toggle Cold-Start Zero Poster Requests, Live Shift & LAN QR Scrub

    func testSim03_PrivateTransitionColdStartZeroPosterRequestsLiveShiftAndLanQrUI() async throws {
        let mediaServer = SimLoopbackMediaServer()
        mediaServer.setPosterPng(
            makePosterPng(top: UIColor(red: 0.65, green: 0.14, blue: 0.22, alpha: 1), bottom: UIColor(red: 0.16, green: 0.04, blue: 0.07, alpha: 1), title: "机密测试片"),
            forPath: "/poster/secret_99.png"
        )
        mediaServer.setPosterPng(
            makePosterPng(top: UIColor(red: 0.12, green: 0.36, blue: 0.62, alpha: 1), bottom: UIColor(red: 0.05, green: 0.10, blue: 0.20, alpha: 1), title: "公开影片"),
            forPath: "/poster/public_1.png"
        )
        try await mediaServer.start()
        defer { mediaServer.stop() }

        let sharedDir = try makeTempDir("privacy-cold")
        let sharedKeychain = InMemoryKeychainStore()
        let storage1 = TvStorageManager(cachesDirectory: sharedDir, keychain: sharedKeychain)
        let app1 = AppViewModel(storage: storage1)

        // Import public first, then private (insert at index 0) so "私密直播" occupies index 0
        // and "公开直播" shifts into index 0 when the private source turns private.
        try await app1.importSubscriptionFromUrl("\(mediaServer.baseUrl)/sub/public.json", name: "公开源")
        try await app1.importSubscriptionFromUrl("\(mediaServer.baseUrl)/sub/private.json", name: "私密源")

        let privSub = try XCTUnwrap(app1.subscriptions.first { $0.url.contains("/sub/private.json") })
        let privSite = try XCTUnwrap(app1.config.publicAvailableSites.first { $0.subscriptionId == privSub.id })
        XCTAssertEqual(app1.config.publicSupportedLives.first?.name, "私密直播")

        // Load Live index 0 ("私密直播") and watch + favorite video 99 with ambientPosterSync enabled
        await app1.loadLiveCatalog(sourceIndex: 0)
        XCTAssertTrue(app1.liveGroups.flatMap(\.channels).contains { $0.name == "秘密频道" })

        app1.updatePlaybackPreferences { $0.ambientPosterSync = true }
        let secretVideo = CmsVideo(
            id: "99",
            title: "机密测试片",
            poster: "\(mediaServer.baseUrl)/poster/secret_99.png",
            remarks: "全1集"
        )
        app1.recordPlaybackProgress(
            site: privSite,
            video: secretVideo,
            lineName: "私密线路",
            episodeName: "第1集",
            episodeIndex: 0,
            positionMs: 180_000,
            durationMs: 1_200_000
        )
        app1.toggleFavorite(site: privSite, video: secretVideo)
        XCTAssertEqual(app1.watchHistory.count, 1)
        XCTAssertEqual(app1.favorites.count, 1)

        // Switch source to PRIVATE, reset poster hit counters, verify immediate clearance
        mediaServer.resetPosterCounts()
        _ = try storage1.upsertSubscription(
            id: privSub.id,
            name: privSub.name,
            url: privSub.url,
            rawContent: privSub.rawContent,
            group: privSub.group,
            isPrivate: true,
            enabled: privSub.enabled,
            warehouseUrl: privSub.warehouseUrl,
            activeDepotName: privSub.activeDepotName,
            depots: privSub.depots
        )
        app1.reloadLocalState()

        XCTAssertTrue(app1.watchHistory.isEmpty)
        XCTAssertTrue(app1.favorites.isEmpty)
        XCTAssertFalse(app1.backdropPosterUrl.contains("secret_99"))
        XCTAssertEqual(app1.config.publicSupportedLives.first?.name, "公开直播")
        XCTAssertTrue(
            app1.liveGroups.isEmpty,
            "Switching live source at index 0 to private must clear stale channels even when another public live source shifts into index 0"
        )

        // Simulate full cold-start with a brand-new AppViewModel backed by the same storage
        let storageCold = TvStorageManager(cachesDirectory: sharedDir, keychain: sharedKeychain)
        let appCold = AppViewModel(storage: storageCold)
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(appCold.watchHistory.isEmpty)
        XCTAssertTrue(appCold.favorites.isEmpty)
        XCTAssertFalse(appCold.backdropPosterUrl.contains("secret_99"))
        XCTAssertTrue(
            storageCold.watchHistory().contains { $0.id == "99" && $0.position == 180_000 },
            "Local private watch breakpoint must remain preserved on Device A"
        )

        // Render Discover and Library tabs on live tvOS Simulator window and assert zero HTTP hits to private poster
        appCold.selectedTab = .discover
        _ = try await renderAndCapture(
            LivingRoomShellView().environmentObject(appCold),
            filename: "04a_privacy_coldstart_discover.png",
            settleSeconds: 0.7
        )
        appCold.selectedTab = .library
        _ = try await renderAndCapture(
            LivingRoomShellView().environmentObject(appCold),
            filename: "04_privacy_coldstart_library.png",
            settleSeconds: 0.8
        )
        XCTAssertEqual(
            mediaServer.posterHitCount(forPath: "/poster/secret_99.png"),
            0,
            "Private poster URL must NEVER be requested after privacy toggle and cold start"
        )

        // Verify LAN QR modal renders QR code on tvOS Simulator and `/sync` scrubs all private records
        appCold.openLanQrModal()
        for _ in 0..<25 where appCold.lanQrUrl.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(appCold.lanQrUrl.isEmpty, "LAN QR URL must be generated on tvOS Simulator")
        _ = try await renderAndCapture(
            LanQrPushModalView().environmentObject(appCold),
            filename: "05_lan_qr_modal.png",
            settleSeconds: 0.8
        )

        let syncUrl = try XCTUnwrap(URL(string: "\(appCold.lanQrUrl)/sync"))
        let (syncData, syncResp) = try await URLSession.shared.data(from: syncUrl)
        let httpStatus = (syncResp as? HTTPURLResponse)?.statusCode
        XCTAssertEqual(httpStatus, 200)
        let syncText = String(decoding: syncData, as: UTF8.self)
        XCTAssertFalse(syncText.contains("机密测试片"), "LAN QR sync must not leak private video title")
        XCTAssertFalse(syncText.contains("secret_99"), "LAN QR sync must not leak private poster URL")
        XCTAssertFalse(syncText.contains("priv_cms"), "LAN QR sync must not leak private site key")
        appCold.closeLanQrModal()
    }

    // MARK: - Sim Test 4: Non-Numbered Line Switch Prompt + Real TvPlayerView Slow HLS Exit Cancel

    func testSim04_TvPlayerNonNumberedLineSwitchAndSlowHlsExitCancellation() async throws {
        let hlsServer = SimLoopbackHlsServer()
        try await hlsServer.start()
        defer { hlsServer.stop() }

        let storage = TvStorageManager(cachesDirectory: try makeTempDir("player-sim"), keychain: InMemoryKeychainStore())
        let appModel = AppViewModel(storage: storage)

        let site = CmsSite(
            key: "sim_vod_site",
            name: "模拟器点播源",
            type: 1,
            api: "\(hlsServer.baseUrl)/api",
            headers: ["X-Sim-Auth": "marco-tvos-sim"]
        )
        let video = CmsVideo(
            id: "vod_special_1",
            title: "特辑测试片",
            poster: "",
            remarks: "双线路特辑",
            lines: [
                CmsLine(
                    name: "A线",
                    episodes: [
                        CmsEpisode(name: "预告片", url: "\(hlsServer.baseUrl)/play/fast.m3u8"),
                        CmsEpisode(name: "片尾访谈", url: "\(hlsServer.baseUrl)/play/slow.m3u8"),
                    ]
                ),
                CmsLine(
                    name: "B线",
                    episodes: [
                        CmsEpisode(name: "正片", url: "\(hlsServer.baseUrl)/play/fast.m3u8"),
                        CmsEpisode(name: "制作花絮", url: "\(hlsServer.baseUrl)/play/fast.m3u8"),
                    ]
                ),
            ]
        )

        // Part A: Non-numbered episode switch from "片尾访谈" (5:00) -> line with only "制作花絮" at index 1 must prompt
        let checkEngine = AVKitPlayerEngine()
        let coordinator = PlaybackSessionCoordinator(
            initialTarget: PlaybackTargetDescriptor(
                site: site,
                video: video,
                lineIndex: 0,
                episodeIndex: 1,
                initialSeekMs: 300_000,
                isLiveStream: false
            ),
            engine: checkEngine,
            resolver: { target in
                let ep = try XCTUnwrap(target.currentEpisode)
                return ResolvedPlayback(
                    originalUrl: ep.url,
                    playableUrl: try XCTUnwrap(URL(string: ep.url)),
                    headers: [:],
                    isProxied: false,
                    kernelLabel: "AVKit 硬解"
                )
            },
            progressRecorder: { _, _, _ in }
        )
        let switchOutcome = coordinator.switchVodLine(to: 1)
        switch switchOutcome {
        case .missingEpisode(let info):
            XCTAssertEqual(info.requestedEpisodeName, "片尾访谈")
            XCTAssertEqual(info.fallbackEpisodeName, "制作花絮")
            XCTAssertEqual(info.targetLineName, "B线")
            XCTAssertEqual(coordinator.target.lineIndex, 0, "Must stay on A线 until user picks on missing-episode sheet")
        default:
            XCTFail("Expected .missingEpisode when switching from 片尾访谈 to 制作花絮, got \(switchOutcome)")
        }
        coordinator.teardownAndPersist()

        // Part B: Mount REAL TvPlayerView (AVPlayerViewController on tvOS) playing proxied slow HLS,
        // verify AVPlayer fetches playlist & slow segment via LocalHeaderProxyServer, then exit and verify cancel!
        let session = ActivePlaybackSession(
            site: site,
            video: video,
            lineIndex: 0,
            episodeIndex: 1,
            initialSeekMs: 0,
            isLiveStream: false
        )
        let window = try activeSimulatorWindow()
        let playerHost = UIHostingController(
            rootView: TvPlayerView(session: session)
                .environmentObject(appModel)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        )
        playerHost.view.frame = window.bounds
        window.rootViewController = playerHost
        window.makeKeyAndVisible()

        // Wait up to 8s for AVPlayer on tvOS Simulator to load proxied /play/slow.m3u8 and start /seg/slow.ts
        let waitDeadline = Date().addingTimeInterval(8.0)
        while Date() < waitDeadline {
            if hlsServer.stats().slowStarted >= 1 {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let beforeExitStats = hlsServer.stats()
        XCTAssertGreaterThanOrEqual(beforeExitStats.playlistHits, 1, "AVPlayer must fetch proxied HLS playlist on tvOS Simulator")
        XCTAssertGreaterThanOrEqual(beforeExitStats.slowStarted, 1, "AVPlayer must start fetching proxied slow HLS segment")
        XCTAssertEqual(beforeExitStats.lastAuthHeader, "marco-tvos-sim", "LocalHeaderProxyServer must inject custom site header")

        // Capture live TvPlayerView screenshot while active on tvOS Simulator
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        let playerImage = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let png = playerImage.pngData() {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let shotDir = cachesDir.appendingPathComponent("sim-screenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
            try png.write(to: shotDir.appendingPathComponent("06_tv_player_active.png"), options: .atomic)
        }

        // Simulate user exiting TvPlayerView -> triggers .onDisappear -> coordinator.teardownAndPersist() -> revokeSession
        let emptyHost = UIViewController()
        emptyHost.view.backgroundColor = .black
        window.rootViewController = emptyHost
        let cancelDeadline = Date().addingTimeInterval(4.0)
        while Date() < cancelDeadline {
            if hlsServer.stats().slowCancelled >= 1 && appModel.proxyServer.cancelledRequestCount() >= 1 {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let afterExitStats = hlsServer.stats()
        XCTAssertGreaterThanOrEqual(
            afterExitStats.slowCancelled,
            1,
            "Exiting TvPlayerView must cancel the in-flight slow HLS upstream download promptly"
        )
        XCTAssertGreaterThanOrEqual(
            appModel.proxyServer.cancelledRequestCount(),
            1,
            "LocalHeaderProxyServer must record cancelled in-flight request upon TvPlayerView exit"
        )

        // Verify next playback session starts cleanly right after exit
        let fastUrl = try XCTUnwrap(URL(string: "\(hlsServer.baseUrl)/play/fast.m3u8"))
        let (fastSid, fastProxyUrl) = try await appModel.proxyServer.registerStreamWithId(
            url: fastUrl,
            headers: ["X-Sim-Auth": "marco-tvos-sim"]
        )
        defer { appModel.proxyServer.revokeSession(fastSid) }
        let (fastData, fastResp) = try await URLSession.shared.data(from: fastProxyUrl)
        XCTAssertEqual((fastResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: fastData, as: UTF8.self).contains("#EXTM3U"))
    }

    // MARK: - Sim Test 5: Deleting Unrelated Sub During Slow Discover/Live Allows Finish & Pagination While Private Drops Cleanly

    func testSim05_DeletingUnrelatedSubDuringSlowDiscoverAndLiveAllowsFinishAndPaginationWhilePrivateDropped() async throws {
        let slowServer = SimSlowCatalogServer()
        try await slowServer.start()
        defer { slowServer.stop() }

        let dir = try makeTempDir("slow-unrelated-delete")
        let storage = TvStorageManager(cachesDirectory: dir, keychain: InMemoryKeychainStore())
        let rawA = """
        {
          "sites": [{"key":"slow_site_a","name":"慢源A","type":1,"api":"\(slowServer.baseUrl)/api/slow_a"}],
          "lives": [{"name":"慢直播A","url":"\(slowServer.baseUrl)/live/slow_a.m3u"}]
        }
        """
        let rawB = """
        {
          "sites": [{"key":"other_site_b","name":"无关源B","type":1,"api":"\(slowServer.baseUrl)/api/other_b"}],
          "lives": [{"name":"无关直播B","url":"\(slowServer.baseUrl)/live/other_b.m3u"}]
        }
        """
        let (subA, _) = try storage.upsertSubscription(id: "sub_slow_a", name: "订阅A", url: "\(slowServer.baseUrl)/sub/a.json", rawContent: rawA, isPrivate: false, nowMs: 1_000)
        let (subB, _) = try storage.upsertSubscription(id: "sub_other_b", name: "无关订阅B", url: "\(slowServer.baseUrl)/sub/b.json", rawContent: rawB, isPrivate: false, nowMs: 1_100)

        let app = AppViewModel(storage: storage)
        // Let AppViewModel.init()'s background startup task finish cleanly while server is ungated
        try? await Task.sleep(nanoseconds: 350_000_000)

        let siteA = try XCTUnwrap(app.config.publicAvailableSites.first(where: { $0.subscriptionId == subA.id }))
        let liveAIdx = try XCTUnwrap(app.config.publicSupportedLives.firstIndex(where: { $0.subscriptionId == subA.id }))

        // Select Site A and gate slow server before kicking off controlled slow Discover & Live loads
        storage.updatePreferences { $0.selectedSiteKey = siteA.key }
        app.reloadLocalState()
        XCTAssertEqual(app.activeSite?.key, siteA.key)

        slowServer.resetCounters()
        slowServer.setGated(true)
        let discoverTask = Task { await app.loadHomeForActiveSite() }
        let liveTask = Task { await app.loadLiveCatalog(sourceIndex: liveAIdx) }

        let gateDeadline = Date().addingTimeInterval(5.0)
        while Date() < gateDeadline {
            if slowServer.parkedCount(pathPrefix: "/api/slow_a") >= 1
                && slowServer.parkedCount(pathPrefix: "/live/slow_a.m3u") >= 1
                && app.isLoadingDiscover
                && app.isLoadingLive
            {
                break
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertGreaterThanOrEqual(slowServer.parkedCount(pathPrefix: "/api/slow_a"), 1)
        XCTAssertGreaterThanOrEqual(slowServer.parkedCount(pathPrefix: "/live/slow_a.m3u"), 1)
        XCTAssertTrue(app.isLoadingDiscover)
        XCTAssertTrue(app.isLoadingLive)

        // Delete UNRELATED subscription B while A is slowly loading Discover & Live!
        storage.removeSubscription(id: subB.id)
        app.reloadLocalState()

        // Release gate -> A MUST finish loading cleanly, clear loading flags, and allow page 2 pagination!
        slowServer.setGated(false)
        await discoverTask.value
        await liveTask.value

        XCTAssertFalse(app.isLoadingDiscover, "Deleting unrelated sub B must NOT leave isLoadingDiscover stuck true")
        XCTAssertFalse(app.isLoadingLive, "Deleting unrelated sub B must NOT leave isLoadingLive stuck true")
        XCTAssertEqual(app.discoverVideos.count, 6, "Site A page 1 must finish loading despite unrelated sub B deletion")
        XCTAssertEqual(app.currentPage, 1)
        XCTAssertEqual(app.totalPageCount, 2)
        XCTAssertTrue(app.liveGroups.flatMap(\.channels).contains(where: { $0.name == "慢源频道A" }))

        // Continue paginating to page 2!
        let lastPage1Video = try XCTUnwrap(app.discoverVideos.last)
        await app.loadMoreDiscoverIfNeeded(currentVideo: lastPage1Video)
        XCTAssertFalse(app.isLoadingMore)
        XCTAssertEqual(app.currentPage, 2)
        XCTAssertEqual(app.discoverVideos.count, 8, "Site A must continue paginating to page 2 cleanly")

        // Part 2: Start another slow Discover & Live load on A, then switch A ITSELF to PRIVATE while in flight!
        slowServer.resetCounters()
        slowServer.setGated(true)
        let privDiscoverTask = Task { await app.loadHomeForActiveSite() }
        let privLiveTask = Task { await app.loadLiveCatalog(sourceIndex: 0) }

        let privGateDeadline = Date().addingTimeInterval(5.0)
        while Date() < privGateDeadline {
            if slowServer.parkedCount(pathPrefix: "/api/slow_a") >= 1
                && slowServer.parkedCount(pathPrefix: "/live/slow_a.m3u") >= 1
            {
                break
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        // Switch Subscription A itself to PRIVATE while slow requests are in flight
        var curSubs = storage.subscriptions()
        curSubs[curSubs.firstIndex(where: { $0.id == subA.id })!].isPrivate = true
        storage.saveSubscriptions(curSubs)
        app.reloadLocalState()

        slowServer.setGated(false)
        await privDiscoverTask.value
        await privLiveTask.value

        XCTAssertTrue(app.discoverVideos.isEmpty, "Late Discover response from now-private A must be dropped")
        XCTAssertTrue(app.liveGroups.isEmpty, "Late Live response from now-private A must be dropped")
        XCTAssertFalse(app.isLoadingDiscover, "Dropped private Discover load must not leave isLoadingDiscover stuck true")
        XCTAssertFalse(app.isLoadingLive, "Dropped private Live load must not leave isLoadingLive stuck true")
    }

    // MARK: - Sim Test 6: Public Sub Removing Private Child Site B -> Cold Start Zero Poster Requests

    func testSim06_PublicSubPrivateChildRemovedColdStartZeroPosterRequests() async throws {
        let mediaServer = SimLoopbackMediaServer()
        mediaServer.setPosterPng(
            makePosterPng(top: UIColor(red: 0.10, green: 0.32, blue: 0.58, alpha: 1), bottom: UIColor(red: 0.04, green: 0.08, blue: 0.16, alpha: 1), title: "公开影片A"),
            forPath: "/poster/public_1.png"
        )
        mediaServer.setPosterPng(
            makePosterPng(top: UIColor(red: 0.65, green: 0.14, blue: 0.22, alpha: 1), bottom: UIColor(red: 0.16, green: 0.04, blue: 0.07, alpha: 1), title: "私密子片B"),
            forPath: "/poster/secret_99.png"
        )
        try await mediaServer.start()
        defer { mediaServer.stop() }

        let dir = try makeTempDir("mixed-child-remove")
        let keychain = InMemoryKeychainStore()
        let storage = TvStorageManager(cachesDirectory: dir, keychain: keychain)

        let mixedRaw = """
        {
          "sites": [
            {"key":"pub_a","name":"公开站A","type":1,"api":"\(mediaServer.baseUrl)/api/public"},
            {"key":"priv_b","name":"私密子站B","type":1,"api":"\(mediaServer.baseUrl)/api/private","isPrivate":true}
          ],
          "lives": [
            {"name":"私密直播L","url":"\(mediaServer.baseUrl)/live/private.m3u","isPrivate":true}
          ]
        }
        """
        let subUrl = "\(mediaServer.baseUrl)/sub/mixed.json"
        let (parentSub, _) = try storage.upsertSubscription(
            id: "sub_sim_mixed",
            name: "混合公开订阅",
            url: subUrl,
            rawContent: mixedRaw,
            isPrivate: false,
            nowMs: 1_000
        )

        let pubAKey = CmsSite.canonicalScopedKey(rawKey: "pub_a", subscriptionId: parentSub.id)
        let privBKey = CmsSite.canonicalScopedKey(rawKey: "priv_b", subscriptionId: parentSub.id)
        storage.updatePreferences { $0.ambientPosterSync = true }
        storage.upsertWatchHistory(
            WatchHistoryItem(site: pubAKey, id: "101", title: "星际漫游记", poster: "\(mediaServer.baseUrl)/poster/public_1.png", line: "极速主线", episode: "第1集", index: 0, position: 60_000, duration: 1_800_000, updated: 2_000)
        )
        storage.upsertWatchHistory(
            WatchHistoryItem(site: privBKey, id: "99", title: "机密子片B", poster: "\(mediaServer.baseUrl)/poster/secret_99.png", line: "私密线路", episode: "第1集", index: 0, position: 145_000, duration: 1_800_000, updated: 3_000)
        )
        _ = storage.toggleFavorite(site: privBKey, video: CmsVideo(id: "99", title: "机密子片B", poster: "\(mediaServer.baseUrl)/poster/secret_99.png"), nowMs: 3_100)

        // Refresh parent subscription removing private child B (only public A remains)
        let refreshedRaw = """
        {
          "sites": [
            {"key":"pub_a","name":"公开站A","type":1,"api":"\(mediaServer.baseUrl)/api/public"}
          ]
        }
        """
        _ = try storage.upsertSubscription(
            id: parentSub.id,
            name: parentSub.name,
            url: subUrl,
            rawContent: refreshedRaw,
            isPrivate: false,
            nowMs: 4_000
        )

        // Cold restart and render BOTH Discover and Library on live Apple TV Simulator!
        mediaServer.resetPosterCounts()
        let restartedStorage = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        let appCold = AppViewModel(storage: restartedStorage)
        try? await Task.sleep(nanoseconds: 500_000_000)

        appCold.selectedTab = .discover
        _ = try await renderAndCapture(
            LivingRoomShellView().environmentObject(appCold),
            filename: "07a_child_removed_discover.png",
            settleSeconds: 0.7
        )
        appCold.selectedTab = .library
        _ = try await renderAndCapture(
            LivingRoomShellView().environmentObject(appCold),
            filename: "07b_child_removed_library.png",
            settleSeconds: 0.7
        )

        XCTAssertTrue(appCold.watchHistory.contains(where: { $0.id == "101" }))
        XCTAssertFalse(appCold.watchHistory.contains(where: { $0.id == "99" }), "Removed private child B must never appear on home/library after cold start")
        XCTAssertFalse(appCold.favorites.contains(where: { $0.id == "99" }))
        XCTAssertFalse(appCold.backdropPosterUrl.contains("secret_99"))
        XCTAssertEqual(
            mediaServer.posterHitCount(forPath: "/poster/secret_99.png"),
            0,
            "Removed private child B poster must NEVER be requested after cold start"
        )
        XCTAssertEqual(
            restartedStorage.watchHistory().first(where: { $0.id == "99" })?.position,
            145_000,
            "Local breakpoint for removed private child B must remain preserved in storage"
        )
    }
}

private final class SimSlowCatalogServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "marco.sim.slow.catalog.server")
    private(set) var port: UInt16 = 0
    private var gated = false
    private var parked: [(path: String, sendAction: () -> Void)] = []
    private var parkedCounts: [String: Int] = [:]

    var baseUrl: String { "http://127.0.0.1:\(port)" }

    func resetCounters() {
        lock.lock()
        parkedCounts.removeAll()
        lock.unlock()
    }

    func setGated(_ enable: Bool) {
        var toFlush: [() -> Void] = []
        lock.lock()
        gated = enable
        if !enable {
            toFlush = parked.map(\.sendAction)
            parked.removeAll()
        }
        lock.unlock()
        for fn in toFlush { fn() }
    }

    func parkedCount(pathPrefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return parkedCounts.reduce(0) { acc, kv in
            kv.key.hasPrefix(pathPrefix) ? acc + kv.value : acc
        }
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = NSLock()
            var done = false
            listener.stateUpdateHandler = { state in
                resumed.lock()
                defer { resumed.unlock() }
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    self.port = listener.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let err):
                    done = true
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        setGated(false)
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readReq(conn: conn, buffer: Data())
    }

    private func readReq(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, _ in
            guard let self else {
                conn.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: next[..<range.lowerBound], as: UTF8.self)
                let reqParts = (head.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
                let rawTarget = reqParts.count >= 2 ? String(reqParts[1]) : "/"
                self.dispatch(conn: conn, rawTarget: rawTarget)
                return
            }
            if isComplete {
                conn.cancel()
            } else {
                self.readReq(conn: conn, buffer: next)
            }
        }
    }

    private func dispatch(conn: NWConnection, rawTarget: String) {
        let comps = URLComponents(string: "http://127.0.0.1\(rawTarget)")
        let path = comps?.path ?? rawTarget
        let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let page = Int(query["pg"] ?? "1") ?? 1

        let sendAction: () -> Void = { [weak self] in
            guard let self else {
                conn.cancel()
                return
            }
            if path == "/api/slow_a" {
                let videos: [[String: Any]] = (page == 2)
                    ? [
                        ["vod_id": "v7", "vod_name": "慢源第2页-7", "vod_pic": "", "vod_remarks": "HD"],
                        ["vod_id": "v8", "vod_name": "慢源第2页-8", "vod_pic": "", "vod_remarks": "HD"],
                    ]
                    : (1...6).map { i in
                        ["vod_id": "v\(i)", "vod_name": "慢源第1页-\(i)", "vod_pic": "", "vod_remarks": "HD"]
                    }
                let obj: [String: Any] = [
                    "code": 1,
                    "page": page,
                    "pagecount": 2,
                    "class": [["type_id": "1", "type_name": "电影"]],
                    "list": videos,
                ]
                let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
                self.writeHttp(conn: conn, contentType: "application/json; charset=utf-8", body: body)
            } else if path == "/live/slow_a.m3u" {
                let m3u = "#EXTM3U\n#EXTINF:-1 group-title=\"慢源分组\",慢源频道A\n\(self.baseUrl)/stream/a.m3u8\n"
                self.writeHttp(conn: conn, contentType: "text/plain; charset=utf-8", body: Data(m3u.utf8))
            } else {
                let obj: [String: Any] = ["code": 1, "page": 1, "pagecount": 1, "class": [], "list": []]
                let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
                self.writeHttp(conn: conn, contentType: "application/json; charset=utf-8", body: body)
            }
        }

        let shouldPark: Bool = {
            guard path == "/api/slow_a" || path == "/live/slow_a.m3u" else { return false }
            lock.lock()
            defer { lock.unlock() }
            if gated {
                parked.append((path: path, sendAction: sendAction))
                parkedCounts[path, default: 0] += 1
                return true
            }
            return false
        }()
        if !shouldPark {
            sendAction()
        }
    }

    private func writeHttp(conn: NWConnection, contentType: String, body: Data) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
#endif
