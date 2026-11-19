// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import MarcoTVCore

final class DrpyGuardAndCatPawTests: XCTestCase {

    func testCatPawCryptoSymmetricAndZlibRoundTrip() throws {
        let key16 = Data(repeating: 0x11, count: 16).base64EncodedString()
        let key32 = Data(repeating: 0x22, count: 32).base64EncodedString()
        let iv16 = Data(repeating: 0x33, count: 16).base64EncodedString()
        let iv12 = Data(repeating: 0x44, count: 12).base64EncodedString()
        let plainData = Data("MarcoMovie Apple TV DRPY Crypto Test!".utf8)
        let plainB64 = plainData.base64EncodedString()

        for (algo, key, iv) in [
            ("aes-128-cbc", key16, iv16),
            ("aes-256-cbc", key32, iv16),
            ("aes-128-ecb", key16, ""),
            ("aes-256-ecb", key32, ""),
            ("aes-256-gcm", key32, iv12),
            ("chacha20-poly1305", key32, iv12),
        ] {
            let enc = try CatPawCrypto.nodeCipher(
                op: "encrypt",
                algo: algo,
                keyBase64: key,
                ivBase64: iv,
                dataBase64: plainB64
            )
            let dec = try CatPawCrypto.nodeCipher(
                op: "decrypt",
                algo: algo,
                keyBase64: key,
                ivBase64: iv,
                dataBase64: enc["data"] ?? "",
                tagBase64: enc["tag"] ?? ""
            )
            XCTAssertEqual(dec["data"], plainB64, "Round-trip failed for \(algo)")
        }

        // Tampered AEAD tag must throw
        let gcmEnc = try CatPawCrypto.nodeCipher(
            op: "encrypt",
            algo: "aes-256-gcm",
            keyBase64: key32,
            ivBase64: iv12,
            dataBase64: plainB64
        )
        XCTAssertThrowsError(
            try CatPawCrypto.nodeCipher(
                op: "decrypt",
                algo: "aes-256-gcm",
                keyBase64: key32,
                ivBase64: iv12,
                dataBase64: gcmEnc["data"] ?? "",
                tagBase64: Data(repeating: 0, count: 16).base64EncodedString()
            )
        )

        // Raw deflate round-trip via ConfigDecoder.compressDeflate
        let compressed = try XCTUnwrap(ConfigDecoder.compressDeflate(plainData))
        let inflated = try CatPawCrypto.zlibInflate(mode: "inflateRaw", input: compressed)
        XCTAssertEqual(inflated, plainData)

        // Random bytes & hashing
        let rand = try CatPawCrypto.randomBytes(count: 32)
        XCTAssertEqual(rand.count, 32)
        let sha = try CatPawCrypto.hash(algorithm: "sha256", data: plainData)
        XCTAssertEqual(sha.count, 32)
    }

    func testGuardAndCatPawCapabilityClassification() {
        let guardWithJar = CmsSite(
            key: "wex_jp",
            name: "荐片",
            type: 3,
            api: "csp_WexaiJianpianGuard",
            jar: "https://fixture.invalid/spider.jar;md5;0123456789abcdef0123456789abcdef"
        )
        XCTAssertEqual(guardWithJar.guardAdapterKey, "wexjianpian-v1")
        XCTAssertTrue(guardWithJar.isGuardPortedSource)
        XCTAssertTrue(guardWithJar.supported)
        XCTAssertEqual(guardWithJar.capabilityStatus, CmsSite.statusOk)

        let guardWithoutJar = CmsSite(
            key: "dm84",
            name: "动漫巴士",
            type: 3,
            api: "csp_DM84Guard"
        )
        XCTAssertEqual(guardWithoutJar.guardAdapterKey, "dm84-v1")
        XCTAssertFalse(guardWithoutJar.isGuardPortedSource)
        XCTAssertFalse(guardWithoutJar.supported)

        let drpySite = CmsSite(
            key: "drpy_demo",
            name: "DRPY2",
            type: 3,
            api: "https://fixture.invalid/drpy2.min.js",
            ext: "https://fixture.invalid/rule.js"
        )
        XCTAssertTrue(drpySite.isDrpySource)
        XCTAssertTrue(drpySite.supported)

        let catPawSite = CmsSite(
            key: "paw_test",
            name: "CatPaw 线路",
            type: 4,
            api: "catpaw://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/api/spider/demo/1"
        )
        XCTAssertTrue(catPawSite.isCatPaw)
        XCTAssertFalse(catPawSite.supported)
        XCTAssertEqual(catPawSite.capabilityStatus, CmsSite.statusCatPawNodeRequired)
        XCTAssertTrue(catPawSite.unsupportedReason.contains("CatPaw"))

        XCTAssertTrue(ConfigDecoder.isCatPawBundle("function start(){ catServerFactory(); catDartServerPort(); }"))
        XCTAssertFalse(ConfigDecoder.isCatPawBundle("{\"sites\":[]}"))
    }

    func testDrpySourceHostExecutesRuleEndToEnd() async throws {
        let origin = "https://tvos-drpy.invalid"
        let mockTransport: JsHttpTransport = { url, _, _, _, _ in
            if url.contains("/home") {
                let html = "<html><body><ul class='items'><li><a href='/v/42' title='AppleTV片源'>AppleTV片源</a></li></ul></body></html>"
                return JsHttpResponse(
                    statusCode: 200,
                    headers: ["content-type": "text/html; charset=utf-8"],
                    body: Data(html.utf8),
                    finalUrl: url
                )
            }
            if url.contains("/gbk") {
                // GBK bytes for "中文"
                let gbkBytes = Data([0xD6, 0xD0, 0xCE, 0xC4])
                return JsHttpResponse(
                    statusCode: 200,
                    headers: ["content-type": "text/html; charset=gbk"],
                    body: gbkBytes,
                    finalUrl: url
                )
            }
            return JsHttpResponse(statusCode: 404, headers: [:], body: Data(), finalUrl: url)
        }

        let rule = #"""
        var rule = {
            title: 'tvOS DRPY 测试',
            host: 'https://tvos-drpy.invalid',
            homeUrl: '/home',
            url: '/home?t=fyclass&pg=fypage',
            detailUrl: '/v/fyid',
            class_name: '电影',
            class_url: '1',
            play_parse: true,
            预处理: 'js:rule._prep();',
            推荐: 'js:VODS=rule._list();',
            一级: 'js:VODS=rule._list();',
            二级: 'js:VOD=rule._detail();',
            搜索: 'js:VODS=rule._list();',
            lazy: 'js:input={parse:0,url:"https://cdn.invalid/stream.m3u8"};',
            _prep: function() {
                var html = request(HOST + '/home');
                var items = pdfa(html, '.items li');
                var title = items.length ? pdfh(items[0], 'a&&title') : '';
                local.set('tv', 'title', title);
                this.class_name = title;
                this.class_url = '1';
            },
            _list: function() {
                return [{ vod_id: '42', vod_name: local.get('tv', 'title') || '' }];
            },
            _detail: function() {
                var gbk = req(HOST + '/gbk', {});
                var keyB64 = Buffer.from('0123456789abcdef0123456789abcdef', 'utf8').toString('base64');
                var ivB64 = Buffer.from('0123456789ab', 'utf8').toString('base64');
                var enc = nodeCipher('encrypt', 'aes-256-gcm', keyB64, ivB64, Buffer.from('ok', 'utf8').toString('base64'), '');
                var dec = nodeCipher('decrypt', 'aes-256-gcm', keyB64, ivB64, enc.data, enc.tag);
                return {
                    vod_id: '42',
                    vod_name: (local.get('tv', 'title') || '') + '|' + gbk.content + '|' + Buffer.from(dec.data, 'base64').toString('utf8'),
                    vod_play_from: '主线',
                    vod_play_url: '第1集$42'
                };
            }
        };
        """#

        let site = CmsSite(key: "tvos_drpy", name: "tvOS DRPY 测试", type: 3, api: "csp_Drpy")
        let host = try DrpySourceHost(
            site: site,
            ruleSource: rule,
            origin: "\(origin)/rule.js",
            httpTransport: mockTransport
        )
        let home = try await host.homeContent(filter: true)
        XCTAssertEqual(home.categories.first?.name, "AppleTV片源")

        let detail = try await host.detailContent(ids: ["42"])
        XCTAssertEqual(detail?.title, "AppleTV片源|中文|ok")

        let stream = try await host.playerContent(flag: "主线", id: "42")
        XCTAssertEqual(stream.url, "https://cdn.invalid/stream.m3u8")
    }

    func testGuardPluginReferenceParsingAndExtractorBoundary() {
        let parsed = GuardPluginExtractor.parsePluginReference(
            "https://fixture.invalid/spider.jar;md5;0123456789abcdef0123456789abcdef"
        )
        XCTAssertEqual(parsed?.url, "https://fixture.invalid/spider.jar")
        XCTAssertEqual(parsed?.expectedMd5, "0123456789abcdef0123456789abcdef")

        // Non-ZIP bytes must cleanly throw a structured plugin-invalid error
        XCTAssertThrowsError(
            try GuardPluginExtractor.extract(
                artifactBytes: Data("not-a-valid-jar".utf8),
                adapter: "dm84-v1"
            )
        )
    }
}
