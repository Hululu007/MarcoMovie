// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import MarcoTVCore

final class WebdavBindCryptoTests: XCTestCase {
    private static func hexToData(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            let byte = UInt8(hex[idx..<next], radix: 16) ?? 0
            data.append(byte)
            idx = next
        }
        return data
    }

    func testDeterministicVectorAndTamperRejection() throws {
        let key = Self.hexToData("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let nonce = Self.hexToData("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
        let plaintext = #"{"v":1,"type":"webdav_bind","mode":"push","url":"https://dav.example/dav/","username":"alice","password":"secret"}"#

        let envJson = try WebdavBindCrypto.sealPlaintextWithNonce(
            key: key,
            nonce: nonce,
            plaintextJson: plaintext
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(envJson.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["alg"] as? String, WebdavBindCrypto.alg)
        XCTAssertEqual(obj["n"] as? String, "oKGio6SlpqeoqaqrrK2urw")
        XCTAssertEqual(
            obj["c"] as? String,
            "xfDx9RrOpL1khU7sInR6r_FEkaUAWr2Gb1uRwQsipYvnlQXfmuWnU5fb1UB1NCg2Qgx2MIpAZ8fkGJgZrE4XXZddPAUF7j81s4Zo6uyIPLCLJTUuJuCXD8uI9zvN0-9vg3Kk1yHHvQGjKt_1Ol9xDa6I"
        )
        XCTAssertEqual(obj["t"] as? String, "RFROaISW8WSfiPGKWfQ6WwsFqQIsJsoJ3h7w0hgUPOM")

        let opened = try WebdavBindCrypto.openJson(key: key, envelopeJson: envJson)
        XCTAssertEqual(opened["url"] as? String, "https://dav.example/dav/")
        XCTAssertEqual(opened["username"] as? String, "alice")
        XCTAssertEqual(opened["password"] as? String, "secret")

        var tampered = obj
        tampered["t"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered)
        let tamperedStr = String(decoding: tamperedData, as: UTF8.self)
        XCTAssertThrowsError(try WebdavBindCrypto.openJson(key: key, envelopeJson: tamperedStr))

        let qrUrl = try WebdavBindCrypto.buildBindQrUrl(
            baseEndpointUrl: "http://127.0.0.1:8080/configure/deadbeef",
            key: key
        )
        let parsed = WebdavBindCrypto.parseBindQrInput(qrUrl)
        XCTAssertEqual(parsed?.bindUrl, "http://127.0.0.1:8080/configure/deadbeef/bind")
        XCTAssertEqual(parsed?.syncUrl, "http://127.0.0.1:8080/configure/deadbeef/sync")
        XCTAssertEqual(parsed?.key, key)
    }

    func testLanConfigServerBindPushAndPullEndpoints() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marco-tvos-bind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storage = TvStorageManager(
            baseDirectory: dir,
            keychain: InMemoryTvKeychainStore()
        )
        let server = LanConfigServer(storage: storage)
        let port = try await server.start(loopbackOnly: true)
        defer { server.stop() }

        let bindEndpoint = URL(string: "http://127.0.0.1:\(port)\(server.tokenPath)/bind")!
        // Initially unconfigured -> GET returns unconfigured mode
        let (getData1, getResp1) = try await URLSession.shared.data(from: bindEndpoint)
        XCTAssertEqual((getResp1 as? HTTPURLResponse)?.statusCode, 200)
        let getObj1 = try WebdavBindCrypto.openJson(
            key: server.bindKey,
            envelopeJson: String(decoding: getData1, as: UTF8.self)
        )
        XCTAssertEqual(getObj1["mode"] as? String, "unconfigured")

        // POST encrypted WebDAV credentials
        let sealedReq = try WebdavBindCrypto.sealJson(
            key: server.bindKey,
            payload: [
                "v": 1,
                "type": "webdav_bind",
                "mode": "push",
                "url": "https://dav.example/dav/",
                "username": "alice",
                "password": "secret",
                "auto": true,
                "syncSubs": true,
                "syncHistory": true,
            ]
        )
        var postReq = URLRequest(url: bindEndpoint)
        postReq.httpMethod = "POST"
        postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        postReq.httpBody = Data(sealedReq.utf8)
        let (postData, postResp) = try await URLSession.shared.data(for: postReq)
        XCTAssertEqual((postResp as? HTTPURLResponse)?.statusCode, 200)
        let ack = try WebdavBindCrypto.openJson(
            key: server.bindKey,
            envelopeJson: String(decoding: postData, as: UTF8.self)
        )
        XCTAssertEqual(ack["ok"] as? Bool, true)
        XCTAssertEqual(storage.loadWebDavConfig().url, "https://dav.example/dav/")
        XCTAssertEqual(storage.loadWebDavConfig().username, "alice")
        XCTAssertEqual(storage.loadWebDavConfig().password, "secret")
    }
}
