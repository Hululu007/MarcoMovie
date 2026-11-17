// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CQuickJS
import Foundation

public struct JsHttpResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public typealias JsHttpTransport = @Sendable (
    _ url: String,
    _ method: String,
    _ headers: [String: String],
    _ body: Data?,
    _ timeoutSeconds: TimeInterval
) throws -> JsHttpResponse

private enum NativeCallbackMagic: Int32 {
    case httpReq = 1
    case storage = 2
    case base64 = 3
    case joinUrl = 4
}

private func quickJsInterruptCallback(
    _ rt: OpaquePointer?,
    _ opaque: UnsafeMutableRawPointer?
) -> Int32 {
    guard let opaque = opaque else { return 0 }
    let deadlineNs = opaque.assumingMemoryBound(to: UInt64.self).pointee
    if deadlineNs == 0 { return 0 }
    return DispatchTime.now().uptimeNanoseconds > deadlineNs ? 1 : 0
}

private func quickJsNativeClosureCallback(
    _ ctx: OpaquePointer?,
    _ thisVal: JSValue,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<JSValue>?,
    _ magic: Int32,
    _ opaque: UnsafeMutableRawPointer?
) -> JSValue {
    guard let ctx = ctx, let opaque = opaque else {
        return cquickjs_undefined()
    }
    let bridge = Unmanaged<QuickJSBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.handleNativeCallback(ctx: ctx, argc: argc, argv: argv, magic: magic)
}

/// Thread-safe, memory-bounded, deadline-enforced Swift wrapper around QuickJS-NG (`CQuickJS`).
public final class QuickJSBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.tv.quickjs")
    private let httpQueue = DispatchQueue(label: "com.pilipala.marcoMovie.tv.quickjs.http", attributes: .concurrent)
    private var runtime: OpaquePointer?
    private var context: OpaquePointer?
    private let deadlinePtr: UnsafeMutablePointer<UInt64>
    private var kvStorage: [String: String] = [:]
    private let httpTransport: JsHttpTransport
    private var moduleRegistry: [String: String] = [:]
    private var disposed = false

    public init(
        memoryLimitBytes: Int = 64 * 1024 * 1024,
        maxStackBytes: Int = 1024 * 1024,
        httpTransport: JsHttpTransport? = nil
    ) throws {
        self.deadlinePtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        self.deadlinePtr.initialize(to: 0)

        if let customTransport = httpTransport {
            self.httpTransport = customTransport
        } else {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.httpShouldSetCookies = false
            let urlSession = URLSession(configuration: sessionConfig)
            self.httpTransport = { urlString, method, headers, bodyData, timeoutSec in
                guard let url = URL(string: CmsParser.normalizeUrl(urlString)),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else {
                    throw MarcoError.invalidFormat("Invalid HTTP URL in JS req: \(urlString)")
                }
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSec)
                req.httpMethod = method
                for (k, v) in headers {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                if req.value(forHTTPHeaderField: "User-Agent") == nil {
                    req.setValue(CmsClient.defaultSafariUserAgent, forHTTPHeaderField: "User-Agent")
                }
                req.httpBody = bodyData

                let sema = DispatchSemaphore(value: 0)
                let box = LockedResultBox<JsHttpResponse>()
                let task = urlSession.dataTask(with: req) { data, resp, err in
                    defer { sema.signal() }
                    if let err = err {
                        box.store(.failure(err))
                        return
                    }
                    let http = resp as? HTTPURLResponse
                    var respHeaders: [String: String] = [:]
                    if let all = http?.allHeaderFields {
                        for (rk, rv) in all {
                            respHeaders[String(describing: rk)] = String(describing: rv)
                        }
                    }
                    box.store(
                        .success(
                            JsHttpResponse(
                                statusCode: http?.statusCode ?? 200,
                                headers: respHeaders,
                                body: data ?? Data()
                            )
                        )
                    )
                }
                task.resume()
                let waitResult = sema.wait(timeout: .now() + timeoutSec + 0.5)
                if waitResult == .timedOut {
                    task.cancel()
                    throw MarcoError.networkFailure("JS HTTP request timed out")
                }
                return try box.load()
            }
        }

        try queue.sync {
            guard let rt = JS_NewRuntime() else {
                throw MarcoError.scriptExecutionFailed("Failed to allocate QuickJS runtime")
            }
            JS_SetMemoryLimit(rt, memoryLimitBytes)
            JS_SetMaxStackSize(rt, maxStackBytes)
            JS_SetInterruptHandler(rt, quickJsInterruptCallback, deadlinePtr)

            guard let ctx = JS_NewContext(rt) else {
                JS_FreeRuntime(rt)
                throw MarcoError.scriptExecutionFailed("Failed to allocate QuickJS context")
            }
            self.runtime = rt
            self.context = ctx
            try installHostGlobals(ctx: ctx)
        }
    }

    deinit {
        close()
        deadlinePtr.deinitialize(count: 1)
        deadlinePtr.deallocate()
    }

    public func close() {
        queue.sync {
            guard !disposed else { return }
            disposed = true
            if let ctx = context {
                JS_FreeContext(ctx)
                context = nil
            }
            if let rt = runtime {
                JS_FreeRuntime(rt)
                runtime = nil
            }
        }
    }

    public func registerModule(name: String, source: String) {
        queue.sync {
            moduleRegistry[name] = source
        }
    }

    /// Evaluates JavaScript code with an execution deadline and returns the result converted to String / JSON.
    public func evaluate(
        _ script: String,
        filename: String = "<eval>",
        asModule: Bool = false,
        timeoutSeconds: TimeInterval = 8.0
    ) throws -> String {
        try queue.sync {
            guard !disposed, let rt = runtime, let ctx = context else {
                throw MarcoError.scriptExecutionFailed("QuickJS runtime already closed")
            }
            JS_UpdateStackTop(rt)
            let budgetNs = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
            deadlinePtr.pointee = DispatchTime.now().uptimeNanoseconds &+ budgetNs
            defer { deadlinePtr.pointee = 0 }

            let flags = asModule ? Int32(JS_EVAL_TYPE_MODULE) : Int32(JS_EVAL_TYPE_GLOBAL)
            var utf8Bytes = Array(script.utf8)
            let byteCount = utf8Bytes.count
            utf8Bytes.append(0)

            let rawVal: JSValue = utf8Bytes.withUnsafeBufferPointer { codePtr in
                filename.withCString { filePtr in
                    JS_Eval(ctx, codePtr.baseAddress, byteCount, filePtr, flags)
                }
            }

            return try resolveAndStringifyValue(ctx: ctx, rt: rt, value: rawVal)
        }
    }

    /// Calls a global JavaScript function by name with JSON-encoded arguments.
    public func callGlobalFunction(
        _ name: String,
        arguments: [Any] = [],
        timeoutSeconds: TimeInterval = 10.0
    ) throws -> String {
        try queue.sync {
            guard !disposed, let rt = runtime, let ctx = context else {
                throw MarcoError.scriptExecutionFailed("QuickJS runtime already closed")
            }
            JS_UpdateStackTop(rt)
            let budgetNs = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
            deadlinePtr.pointee = DispatchTime.now().uptimeNanoseconds &+ budgetNs
            defer { deadlinePtr.pointee = 0 }

            let global = JS_GetGlobalObject(ctx)
            defer { JS_FreeValue(ctx, global) }

            let fnVal = name.withCString { JS_GetPropertyStr(ctx, global, $0) }
            defer { JS_FreeValue(ctx, fnVal) }

            guard JS_IsFunction(ctx, fnVal) else {
                throw MarcoError.scriptExecutionFailed("JS function '\(name)' is not defined")
            }

            var jsArgs: [JSValue] = []
            jsArgs.reserveCapacity(arguments.count)
            defer {
                for arg in jsArgs {
                    JS_FreeValue(ctx, arg)
                }
            }

            for arg in arguments {
                jsArgs.append(makeJsValue(ctx: ctx, from: arg))
            }

            let retVal: JSValue = jsArgs.withUnsafeMutableBufferPointer { buf in
                JS_Call(ctx, fnVal, global, Int32(buf.count), buf.baseAddress)
            }
            return try resolveAndStringifyValue(ctx: ctx, rt: rt, value: retVal)
        }
    }

    // MARK: - Internal Host Setup & Callback Dispatch

    private func installHostGlobals(ctx: OpaquePointer) throws {
        let global = JS_GetGlobalObject(ctx)
        defer { JS_FreeValue(ctx, global) }

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        func bindClosure(_ jsName: String, argc: Int32, magic: NativeCallbackMagic) {
            let fn = jsName.withCString { namePtr in
                JS_NewCClosure(ctx, quickJsNativeClosureCallback, namePtr, nil, argc, magic.rawValue, opaqueSelf)
            }
            _ = jsName.withCString { namePtr in
                JS_SetPropertyStr(ctx, global, namePtr, fn)
            }
        }

        bindClosure("marco_http_req", argc: 2, magic: .httpReq)
        bindClosure("__hostRequest", argc: 2, magic: .httpReq)
        bindClosure("__hostStorage", argc: 4, magic: .storage)
        bindClosure("__hostBase64", argc: 2, magic: .base64)
        bindClosure("__hostJoin", argc: 2, magic: .joinUrl)

        let bootstrapJs = #"""
        globalThis.global = globalThis;
        globalThis.window = globalThis;
        globalThis.self = globalThis;
        globalThis.__proxyAddress = "http://127.0.0.1:0/proxy";
        globalThis.console = {
            log: function() {},
            info: function() {},
            warn: function() {},
            error: function() {},
            debug: function() {}
        };
        globalThis.log = globalThis.console.log;
        globalThis.print = globalThis.console.log;
        globalThis.req = function(url, options) {
            var raw = __hostRequest(String(url || ""), JSON.stringify(options || {}));
            return JSON.parse(raw);
        };
        globalThis.local = {
            get: function(space, key) { return __hostStorage("get", String(space || ""), String(key || ""), ""); },
            set: function(space, key, val) { return __hostStorage("set", String(space || ""), String(key || ""), String(val || "")); },
            delete: function(space, key) { return __hostStorage("delete", String(space || ""), String(key || ""), ""); }
        };
        globalThis.joinUrl = function(base, part) {
            return __hostJoin(String(base || ""), String(part || ""));
        };
        globalThis.atob = function(s) { return __hostBase64(String(s || ""), false); };
        globalThis.btoa = function(s) { return __hostBase64(String(s || ""), true); };
        """#
        var utf8 = Array(bootstrapJs.utf8)
        let len = utf8.count
        utf8.append(0)
        let res = utf8.withUnsafeBufferPointer { ptr in
            "bootstrap.js".withCString { fPtr in
                JS_Eval(ctx, ptr.baseAddress, len, fPtr, Int32(JS_EVAL_TYPE_GLOBAL))
            }
        }
        if JS_IsException(res) {
            let msg = extractExceptionMessage(ctx: ctx)
            throw MarcoError.scriptExecutionFailed("Bootstrap failed: \(msg)")
        }
        JS_FreeValue(ctx, res)
    }

    fileprivate func handleNativeCallback(
        ctx: OpaquePointer,
        argc: Int32,
        argv: UnsafeMutablePointer<JSValue>?,
        magic: Int32
    ) -> JSValue {
        func argString(_ index: Int) -> String {
            guard let argv = argv, index < Int(argc) else { return "" }
            return jsValueToString(ctx: ctx, value: argv[index])
        }

        switch NativeCallbackMagic(rawValue: magic) {
        case .httpReq:
            let urlStr = argString(0)
            let optionsRaw = argString(1)
            let options = (try? JSONSerialization.jsonObject(with: Data(optionsRaw.utf8))) as? [String: Any] ?? [:]
            let method = ((options["method"] as? String) ?? "GET").uppercased()
            var headers: [String: String] = [:]
            if let hObj = options["headers"] as? [String: Any] {
                for (k, v) in hObj where !(v is NSNull) {
                    headers[k] = String(describing: v)
                }
            }
            var bodyData: Data?
            if let bodyStr = options["body"] as? String {
                bodyData = Data(bodyStr.utf8)
            } else if let dataObj = options["data"] {
                if let s = dataObj as? String {
                    bodyData = Data(s.utf8)
                } else if JSONSerialization.isValidJSONObject(dataObj),
                          let encoded = try? JSONSerialization.data(withJSONObject: dataObj)
                {
                    bodyData = encoded
                    if headers.keys.allSatisfy({ $0.lowercased() != "content-type" }) {
                        headers["Content-Type"] = "application/json; charset=utf-8"
                    }
                }
            }
            let timeoutMs = (options["timeout"] as? NSNumber)?.doubleValue ?? 10_000
            let remainingSec: TimeInterval = {
                let d = deadlinePtr.pointee
                guard d > 0 else { return min(max(timeoutMs / 1000.0, 0.5), 15.0) }
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= d { return 0.05 }
                return min(Double(d - now) / 1_000_000_000.0, timeoutMs / 1000.0)
            }()

            let bufferMode = (options["buffer"] as? NSNumber)?.intValue ?? 0
            let transport = self.httpTransport
            var responseDict: [String: Any] = ["code": 0, "headers": [:], "content": ""]
            let sema = DispatchSemaphore(value: 0)
            httpQueue.async {
                defer { sema.signal() }
                do {
                    let resp = try transport(urlStr, method, headers, bodyData, max(0.1, remainingSec))
                    let contentVal: Any
                    if bufferMode == 2 {
                        contentVal = resp.body.base64EncodedString()
                    } else {
                        contentVal = String(decoding: resp.body, as: UTF8.self)
                    }
                    responseDict = [
                        "code": resp.statusCode,
                        "headers": resp.headers,
                        "content": contentVal,
                    ]
                } catch {
                    responseDict = [
                        "code": 0,
                        "headers": [:],
                        "content": "",
                        "error": error.localizedDescription,
                    ]
                }
            }
            sema.wait()
            let jsonData = (try? JSONSerialization.data(withJSONObject: responseDict)) ?? Data("{}".utf8)
            return newJsString(ctx: ctx, String(decoding: jsonData, as: UTF8.self))

        case .storage:
            let op = argString(0)
            let space = argString(1)
            let key = argString(2)
            let val = argString(3)
            let compoundKey = "\(space)::\(key)"
            switch op {
            case "get":
                return newJsString(ctx: ctx, kvStorage[compoundKey] ?? "")
            case "set":
                if kvStorage.count < 512 {
                    kvStorage[compoundKey] = val
                }
                return newJsString(ctx: ctx, "ok")
            case "delete":
                kvStorage.removeValue(forKey: compoundKey)
                return newJsString(ctx: ctx, "ok")
            default:
                return newJsString(ctx: ctx, "")
            }

        case .base64:
            let input = argString(0)
            let encodeFlag: Bool = {
                guard let argv = argv, argc >= 2 else { return false }
                return JS_ToBool(ctx, argv[1]) > 0
            }()
            if encodeFlag {
                let b64 = Data(input.utf8).base64EncodedString()
                return newJsString(ctx: ctx, b64)
            } else {
                var clean = input.components(separatedBy: .whitespacesAndNewlines).joined()
                while clean.count % 4 != 0 { clean.append("=") }
                let decoded = Data(base64Encoded: clean).map { String(decoding: $0, as: UTF8.self) } ?? ""
                return newJsString(ctx: ctx, decoded)
            }

        case .joinUrl:
            let base = argString(0)
            let part = argString(1)
            return newJsString(ctx: ctx, CmsParser.resolveUrl(base: base, relative: part))

        case .none:
            return cquickjs_undefined()
        }
    }

    private func drainJobs(rt: OpaquePointer) throws {
        var safety = 0
        while JS_IsJobPending(rt) {
            var jobCtx: OpaquePointer?
            let rc = JS_ExecutePendingJob(rt, &jobCtx)
            if rc < 0 {
                if let jobCtx = jobCtx {
                    let err = extractExceptionMessage(ctx: jobCtx)
                    throw MarcoError.scriptExecutionFailed(err)
                }
                throw MarcoError.scriptExecutionFailed("Promise microtask failed")
            }
            safety += 1
            if safety > 10_000 {
                throw MarcoError.scriptExecutionFailed("Promise microtask loop limit exceeded")
            }
        }
    }

    private func resolveAndStringifyValue(
        ctx: OpaquePointer,
        rt: OpaquePointer,
        value: JSValue
    ) throws -> String {
        if JS_IsException(value) {
            let err = extractExceptionMessage(ctx: ctx)
            throw MarcoError.scriptExecutionFailed(err)
        }
        defer { JS_FreeValue(ctx, value) }

        try drainJobs(rt: rt)

        if JS_IsPromise(value) {
            let state = JS_PromiseState(ctx, value)
            switch state {
            case JS_PROMISE_FULFILLED:
                let fulfilledVal = JS_PromiseResult(ctx, value)
                defer { JS_FreeValue(ctx, fulfilledVal) }
                return try convertJsValueToOutputString(ctx: ctx, value: fulfilledVal)
            case JS_PROMISE_REJECTED:
                let reasonVal = JS_PromiseResult(ctx, value)
                defer { JS_FreeValue(ctx, reasonVal) }
                let reason = jsValueToString(ctx: ctx, value: reasonVal)
                throw MarcoError.scriptExecutionFailed("Promise rejected: \(reason)")
            default:
                throw MarcoError.scriptExecutionFailed("Promise remained pending after draining microtasks")
            }
        }

        return try convertJsValueToOutputString(ctx: ctx, value: value)
    }

    private func convertJsValueToOutputString(ctx: OpaquePointer, value: JSValue) throws -> String {
        if JS_IsUndefined(value) || JS_IsNull(value) {
            return ""
        }
        if JS_IsString(value) {
            return jsValueToString(ctx: ctx, value: value)
        }
        if JS_IsObject(value) {
            let jsonVal = JS_JSONStringify(ctx, value, cquickjs_undefined(), cquickjs_undefined())
            if JS_IsException(jsonVal) {
                let err = extractExceptionMessage(ctx: ctx)
                throw MarcoError.scriptExecutionFailed(err)
            }
            defer { JS_FreeValue(ctx, jsonVal) }
            if !JS_IsUndefined(jsonVal) {
                return jsValueToString(ctx: ctx, value: jsonVal)
            }
        }
        return jsValueToString(ctx: ctx, value: value)
    }

    private func extractExceptionMessage(ctx: OpaquePointer) -> String {
        let exc = JS_GetException(ctx)
        defer { JS_FreeValue(ctx, exc) }
        var message = jsValueToString(ctx: ctx, value: exc)
        if JS_IsObject(exc) {
            let stackVal = "stack".withCString { JS_GetPropertyStr(ctx, exc, $0) }
            defer { JS_FreeValue(ctx, stackVal) }
            if JS_IsString(stackVal) {
                let stackStr = jsValueToString(ctx: ctx, value: stackVal)
                if !stackStr.isEmpty {
                    message += "\n\(stackStr)"
                }
            }
        }
        return message.isEmpty ? "Unknown JavaScript exception" : message
    }

    private func jsValueToString(ctx: OpaquePointer, value: JSValue) -> String {
        var len = 0
        guard let cPtr = JS_ToCStringLen2(ctx, &len, value, false) else {
            return ""
        }
        defer { JS_FreeCString(ctx, cPtr) }
        let rawBuf = UnsafeBufferPointer(start: UnsafeRawPointer(cPtr).assumingMemoryBound(to: UInt8.self), count: len)
        return String(decoding: rawBuf, as: UTF8.self)
    }

    private func newJsString(ctx: OpaquePointer, _ str: String) -> JSValue {
        let utf8 = Array(str.utf8)
        return utf8.withUnsafeBufferPointer { buf in
            JS_NewStringLen(ctx, UnsafeRawPointer(buf.baseAddress)?.assumingMemoryBound(to: CChar.self) ?? "", buf.count)
        }
    }

    private func makeJsValue(ctx: OpaquePointer, from any: Any) -> JSValue {
        if any is NSNull {
            return cquickjs_null()
        }
        if let s = any as? String {
            return newJsString(ctx: ctx, s)
        }
        if let b = any as? Bool {
            return JS_NewBool(ctx, b)
        }
        if let i = any as? Int {
            return JS_NewInt64(ctx, Int64(i))
        }
        if let d = any as? Double {
            return JS_NewFloat64(ctx, d)
        }
        if JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any)
        {
            var bytes = Array(data)
            let len = bytes.count
            bytes.append(0)
            return bytes.withUnsafeBufferPointer { ptr in
                "<arg>".withCString { fPtr in
                    JS_ParseJSON(
                        ctx,
                        UnsafeRawPointer(ptr.baseAddress)?.assumingMemoryBound(to: CChar.self),
                        len,
                        fPtr
                    )
                }
            }
        }
        return newJsString(ctx: ctx, String(describing: any))
    }
}

private final class LockedResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ value: Result<T, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func load() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let result = result else {
            throw MarcoError.networkFailure("Empty HTTP transport result")
        }
        return try result.get()
    }
}
