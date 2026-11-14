package com.pilipala.catpaw;

import android.content.Context;
import java.io.*;
import java.net.*;
import java.security.MessageDigest;
import java.util.Locale;
import org.json.*;

/** On-device CatPaw transport. Persist logical URLs, never the local capability or port. */
public final class CatPawHost {
    public static final class UnsupportedGuardArtifactException extends IOException {
        UnsupportedGuardArtifactException() {
            super("此插件版本尚未提供本机移植适配");
        }
    }

    public static final class DrpySourceException extends IOException {
        public final String code;

        public DrpySourceException(String code, String message) {
            super(message);
            this.code = code;
        }
    }

    private static final java.util.Set<String> NO_EXT_GUARD_ADAPTERS =
            new java.util.HashSet<>(
                    java.util.Arrays.asList(
                            "dm84-v1", "auete-v1", "bttwoo-v1", "appgz-v1", "fy-v1"));

    private static final java.util.Set<String> REQUIRED_EXT_GUARD_ADAPTERS =
            new java.util.HashSet<>(java.util.Arrays.asList("t4-v1", "apptt-v1"));

    private static final java.util.Set<String> OPTIONAL_EXT_GUARD_ADAPTERS =
            new java.util.HashSet<>(
                    java.util.Arrays.asList(
                            "jpys-v1",
                            "jpj-v1",
                            "nmyswv-v1",
                            "hmys-v1",
                            "app99-v1",
                            "appsx-v1",
                            "newcz-v1",
                            "libvio-v1",
                            "ygp-v1",
                            "kanqiu-v1",
                            "doubao-v1",
                            "livegz-v1",
                            "alllive-v1",
                            "tingshu275-v1",
                            "yueting-v1",
                            "seedhub-v1",
                            "szps-v1",
                            "ypanso-v1",
                            "bpanso-v1",
                            "kkss-v1",
                            "uuss-v1",
                            "jumitv-v1",
                            "wexappv7-v1",
                            "wexguazi-v1",
                            "wexduboku-v1",
                            "wexwencai-v1",
                            "wexfengye-v1",
                            "wexjianpian-v1",
                            "wexjuxiafan-v1",
                            "wexrebo-v1",
                            "wexbobo-v1",
                            "wexikanbot-v1",
                            "wexyiys-v1",
                            "wexhanxiaoquan-v1",
                            "wexduoduo-v1",
                            "wexhuban-v1",
                            "wexkuaiying-v1",
                            "wexlabi-v1",
                            "wexmuou-v1",
                            "wexshandian-v1",
                            "wexxiaopan-v1",
                            "wexzhizhen-v1",
                            "wexwogg-v1",
                            "wexhuajuan-v1",
                            "wexjutou-v1",
                            "wexzhinan-v1",
                            "wexwoniu-v1",
                            "wexpianku-v1",
                            "wexqiwei-v1",
                            "wexyidong-v1",
                            "wexaipanso-v1",
                            "wexhaiyin-v1",
                            "wexquanpan-v1",
                            "wexkaka-v1",
                            "wexmodu-v1",
                            "wexhaokan-v1",
                            "wexqimiao-v1",
                            "wexkuwoa-v1",
                            "wexqingting-v1",
                            "wexsportguazi-v1",
                            "wexkafei-v1",
                            "wexkanqiutong-v1",
                            "wexkanqiu-v1",
                            "wexwwe-v1"));

    private static String drpyErrorMessage(String code) {
        if ("drpy_verification_required".equals(code)) return "此片源需要完成网站验证码，暂时无法加载";
        if ("drpy_action_invalid".equals(code)) return "验证码已失效或格式不正确，请刷新后重试";
        if ("drpy_verification_unavailable".equals(code)) return "暂时无法获取验证码图片，请稍后重试";
        if ("drpy_unsupported_filter".equals(code)) return "此片源不支持当前筛选条件";
        if ("drpy_invalid_id".equals(code)) return "此片源的影片标识无效，请重新打开影片";
        if ("drpy_local_proxy_not_supported".equals(code)) return "此片源需要的本地代理暂不支持";
        if ("drpy_media_protocol".equals(code)) return "此片源返回的播放地址协议暂不支持";
        if ("drpy_media_unresolved".equals(code)) return "此片源暂未解析出可播放地址";
        if ("drpy_source_origin".equals(code)) return "此片源返回了不支持的跨站目录";
        if ("drpy_source_unavailable".equals(code)) return "此片源暂时无法访问";
        if ("drpy_source_response".equals(code)) return "此片源返回了无法识别的数据";
        if ("drpy_crypto_invalid".equals(code)) return "此片源的加密响应暂不兼容";
        if ("drpy_authentication_required".equals(code)) return "此片源的访问认证尚未通过";
        if ("drpy_filter_not_supported".equals(code)) return "此片源不支持当前筛选条件";
        if ("drpy_local_module_missing".equals(code)) return "本地规则包缺少依赖文件，请导入完整的规则包";
        if ("drpy_http_timeout".equals(code)) return "连接片源服务器超时，请稍后重试或切换其他片源";
        if ("drpy_http_connection_failed".equals(code)) return "无法连接片源服务器，该站点可能暂时离线或受当前网络限制";
        if ("drpy_http_response_failed".equals(code)) return "读取片源服务器响应失败，请稍后重试";
        if ("drpy_http_response_too_large".equals(code)) return "片源返回的数据超过大小上限";
        if ("drpy_http_encoding".equals(code)) return "片源响应编码异常，暂时无法解析";
        if ("drpy_http_headers".equals(code)) return "片源请求头格式不受支持";
        if ("drpy_http_method".equals(code)) return "片源请求方式不受支持";
        if ("drpy_http_body_too_large".equals(code)) return "片源请求体超过大小上限";
        if ("drpy_http_protocol".equals(code)) return "片源请求地址协议不受支持";
        if ("drpy_redirect_credentials".equals(code)) return "片源重定向包含不安全的认证信息";
        if ("drpy_http_redirect_limit".equals(code)) return "片源服务器重定向次数过多";
        if ("drpy_http_redirect".equals(code)) return "片源服务器返回了无效的重定向地址";
        if ("drpy_http_request".equals(code)) return "片源网络请求参数无效";
        if ("drpy_http_response".equals(code)) return "片源服务器返回了异常响应";
        if ("drpy_execution_timeout".equals(code)) return "片源脚本加载超时，请重试或切换其他片源";
        if ("drpy_source_failed".equals(code)) return "片源线路暂时无法返回有效数据，请稍后重试或切换其他片源";
        if ("drpy_host_error".equals(code)) return "片源本地运行环境处理失败，请重试";
        if ("drpy_storage_key".equals(code)) return "片源本地缓存键无效";
        if ("drpy_storage_action".equals(code)) return "片源本地缓存操作不受支持";
        if ("drpy_storage_limit".equals(code)) return "片源本地缓存超出容量限制";
        if ("drpy_random_size".equals(code)) return "片源随机参数长度无效";
        if ("drpy_rule_missing".equals(code)) return "片源规则尚未初始化完成，请重试";
        if ("drpy_async_result".equals(code)) return "片源异步响应格式异常";
        if ("drpy_result".equals(code)) return "片源返回结果超过大小上限或格式无效";
        if ("drpy_proxy_result".equals(code)) return "片源代理响应格式不受支持";
        return null;
    }

    private static final class BootstrapBusyException extends IOException {
        BootstrapBusyException() {
            super("插件解析繁忙（bootstrap_busy）");
        }
    }

    private static void checkBootstrapInterrupted() throws InterruptedIOException {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException("插件解析已取消");
    }

    public interface ConnectionObserver {
        void opened(HttpURLConnection connection) throws IOException;

        void closed(HttpURLConnection connection);
    }

    public static final String DRPY_RUNTIME = "drpy2-ca23ffdb-1";
    private static String endpoint;
    private final Context context;
    private final File root;

    public CatPawHost(Context context) {
        this.context = context.getApplicationContext();
        root = new File(this.context.getFilesDir(), "catpaw");
    }

    public static boolean isBundle(String code) {
        return code.contains("catServerFactory") && code.contains("catDartServerPort");
    }

    private static byte[] bytes(InputStream input, int maximum) throws IOException {
        try {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (output.size() + count > maximum) throw new IOException("CatPaw 响应过大");
                output.write(buffer, 0, count);
            }
            return output.toByteArray();
        } finally {
            input.close();
        }
    }

    private static void write(File file, byte[] content) throws IOException {
        FileOutputStream stream = new FileOutputStream(file);
        try {
            stream.write(content);
            stream.getFD().sync();
        } finally {
            stream.close();
        }
    }

    private static String hash(byte[] content) throws Exception {
        StringBuilder digest = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(content))
            digest.append(String.format(Locale.US, "%02x", b & 255));
        return digest.toString();
    }

    private void stageDrpyAssets() throws Exception {
        JSONObject manifest =
                new JSONObject(
                        new String(
                                bytes(context.getAssets().open("catpaw/drpy-assets.json"), 65536),
                                "UTF-8"));
        if (manifest.optInt("version") != 1 || !DRPY_RUNTIME.equals(manifest.optString("runtime")))
            throw new IOException("DRPY 运行资源版本不匹配");
        JSONArray files = manifest.getJSONArray("files");
        if (files.length() < 5 || files.length() > 32) throw new IOException("DRPY 运行资源清单无效");
        java.util.Map<String, byte[]> verified = new java.util.LinkedHashMap<>();
        int total = 0;
        for (int i = 0; i < files.length(); i++) {
            JSONObject entry = files.getJSONObject(i);
            String name = entry.getString("name");
            long size = entry.optLong("bytes", -1);
            if (!name.matches("drpy[-A-Za-z0-9._]+")
                    || name.equals("drpy-assets.json")
                    || verified.containsKey(name)
                    || size <= 0
                    || size > 4 * 1024 * 1024) throw new IOException("DRPY 运行资源路径或大小无效");
            byte[] data = bytes(context.getAssets().open("catpaw/" + name), 4 * 1024 * 1024);
            if (data.length != size || !hash(data).equals(entry.optString("sha256")))
                throw new IOException("DRPY 运行资源校验失败");
            total += data.length;
            if (total > 16 * 1024 * 1024) throw new IOException("DRPY 运行资源超过大小限制");
            verified.put(name, data);
        }
        for (String required :
                new String[] {
                    "drpy-worker.cjs",
                    "drpy-http.cjs",
                    "drpy-schema.cjs",
                    "drpy-core.js",
                    "drpy-dependencies.js"
                }) if (!verified.containsKey(required)) throw new IOException("DRPY 运行资源不完整");
        for (java.util.Map.Entry<String, byte[]> entry : verified.entrySet())
            write(new File(root, entry.getKey()), entry.getValue());
    }

    private String start() throws Exception {
        synchronized (CatPawHost.class) {
            if (endpoint != null) return endpoint;
            if (!root.isDirectory() && !root.mkdirs()) throw new IOException("无法创建 CatPaw 本机目录");
            for (String name : new String[] {"host.cjs", "fetch.cjs"}) {
                write(
                        new File(root, name),
                        bytes(context.getAssets().open("catpaw/" + name), 1024 * 1024));
            }
            stageDrpyAssets();
            File ready = new File(root, "ready.json");
            NodeRuntime.start(
                    context,
                    new File(root, "host.cjs").getAbsolutePath(),
                    root.getAbsolutePath(),
                    ready.getAbsolutePath());
            long deadline = System.nanoTime() + 12000000000L;
            while (System.nanoTime() < deadline) {
                if (ready.isFile()) {
                    JSONObject state =
                            new JSONObject(
                                    new String(bytes(new FileInputStream(ready), 1024), "UTF-8"));
                    int port = state.optInt("port");
                    String secret = state.optString("secret");
                    if (port > 0 && port < 65536 && secret.matches("[a-f0-9]{64}")) {
                        endpoint = "http://127.0.0.1:" + port + "/" + secret;
                        return endpoint;
                    }
                }
                Thread.sleep(40);
            }
            throw new IOException("CatPaw 本机服务启动失败");
        }
    }

    public String resolve(String address) throws Exception {
        URI uri = new URI(address);
        String hash = uri.getHost();
        if (!"catpaw".equals(uri.getScheme())
                || hash == null
                || !hash.matches("[a-f0-9]{64}")
                || uri.getUserInfo() != null
                || uri.getPort() != -1) throw new IOException("CatPaw 本机地址无效");
        for (String part : uri.getPath().split("/"))
            if (part.equals("..") || part.equals(".")) throw new IOException("CatPaw 路径无效");
        File folder = new File(root, hash);
        boolean drpy = new File(folder, "drpy.json").isFile();
        if (!new File(folder, "index.cjs").isFile() && !drpy)
            throw new IOException("此设备没有对应的 CatPaw 服务包，请重新导入原订阅");
        if (drpy
                && !uri.getPath().equals("/api/drpy")
                && !uri.getPath().equals("/_release")
                && !uri.getPath().equals("/proxy")) throw new IOException("DRPY 本机请求路径无效");
        return start()
                + "/"
                + hash
                + uri.getRawPath()
                + (uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery());
    }

    public String read(String address) throws Exception {
        return read(address, "GET");
    }

    public String settings(String address) throws Exception {
        URI logical = new URI(address);
        String raw = read("catpaw://" + logical.getHost() + "/_manage", "POST");
        URI url = new URI(new JSONObject(raw).getString("url"));
        if (!"http".equals(url.getScheme())
                || !"127.0.0.1".equals(url.getHost())
                || !url.getPath().startsWith("/authorize/"))
            throw new IOException("CatPaw 配置页面启动失败");
        return url.toString();
    }

    private String read(String address, String method) throws Exception {
        return read(address, method, null);
    }

    public String post(String address, JSONObject body) throws Exception {
        return read(address, "POST", body.toString().getBytes("UTF-8"));
    }

    public String post(String address, JSONObject body, ConnectionObserver observer)
            throws Exception {
        return read(address, "POST", body.toString().getBytes("UTF-8"), observer);
    }

    /** Decode only a reviewed imported artifact; never execute its Android bytecode. */
    public JSONObject bootstrapGuard(byte[] artifact, ConnectionObserver observer)
            throws Exception {
        return bootstrapGuard(artifact, "dm84-v1", observer);
    }

    public JSONObject bootstrapGuard(byte[] artifact, String adapter, ConnectionObserver observer)
            throws Exception {
        return bootstrapGuard(artifact, adapter, null, observer);
    }

    public JSONObject bootstrapGuard(
            byte[] artifact, String adapter, String extension, ConnectionObserver observer)
            throws Exception {
        checkBootstrapInterrupted();
        boolean requiresExt = REQUIRED_EXT_GUARD_ADAPTERS.contains(adapter);
        boolean optionalExt = OPTIONAL_EXT_GUARD_ADAPTERS.contains(adapter);
        if (!requiresExt && !optionalExt && !NO_EXT_GUARD_ADAPTERS.contains(adapter))
            throw new IOException("未知插件移植适配器");
        if (requiresExt) {
            if (extension == null
                    || extension.trim().isEmpty()
                    || extension.getBytes("UTF-8").length > 16 * 1024)
                throw new IOException("插件扩展配置无效");
        } else if (optionalExt) {
            if (extension != null && extension.getBytes("UTF-8").length > 16 * 1024)
                throw new IOException("插件扩展配置无效");
        } else if (extension != null) {
            throw new IOException("插件扩展配置无效");
        }
        if (artifact.length == 0 || artifact.length > 16 * 1024 * 1024)
            throw new IOException("移植插件包超过大小限制");
        String artifactHash = hash(artifact);
        File imports = new File(root, "imports");
        synchronized (CatPawHost.class) {
            if (!imports.isDirectory() && !imports.mkdirs()) throw new IOException("插件导入目录不可用");
            File stored = new File(imports, artifactHash + ".jar");
            if (stored.isFile()) {
                if (!hash(bytes(new FileInputStream(stored), 16 * 1024 * 1024))
                        .equals(artifactHash)) throw new IOException("已导入插件内容校验失败");
            } else {
                File temporary = File.createTempFile("import-", ".tmp", imports);
                try {
                    write(temporary, artifact);
                    if (!temporary.renameTo(stored)) throw new IOException("无法保存导入插件");
                    stored.setReadOnly();
                } finally {
                    temporary.delete();
                }
            }
        }
        byte[] body =
                new JSONObject()
                        .put("version", 1)
                        .put("adapter", adapter)
                        .put("artifactHash", artifactHash)
                        .put("extension", extension)
                        .toString()
                        .getBytes("UTF-8");
        String target = start() + "/_port-bootstrap";
        long deadline = System.nanoTime() + 2000000000L;
        int backoffMs = 80;
        while (true) {
            checkBootstrapInterrupted();
            try {
                return requestBootstrap(target, body, observer);
            } catch (BootstrapBusyException busy) {
                checkBootstrapInterrupted();
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) throw busy;
                try {
                    Thread.sleep(Math.min(backoffMs, Math.max(1, remaining / 1000000L)));
                } catch (InterruptedException cancelled) {
                    Thread.currentThread().interrupt();
                    throw new InterruptedIOException("插件解析已取消");
                }
                backoffMs = Math.min(250, backoffMs * 2);
            }
        }
    }

    private JSONObject requestBootstrap(String target, byte[] body, ConnectionObserver observer)
            throws Exception {
        checkBootstrapInterrupted();
        HttpURLConnection connection =
                (HttpURLConnection) new URL(target).openConnection(Proxy.NO_PROXY);
        try {
            if (observer != null) observer.opened(connection);
            connection.setRequestMethod("POST");
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(8000);
            connection.setReadTimeout(10000);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=UTF-8");
            connection.setFixedLengthStreamingMode(body.length);
            try (OutputStream output = connection.getOutputStream()) {
                output.write(body);
            }
            int status = connection.getResponseCode();
            InputStream response =
                    status == 200 ? connection.getInputStream() : connection.getErrorStream();
            String raw =
                    response == null
                            ? "{}"
                            : new String(
                                    bytes(response, status == 200 ? 8 * 1024 * 1024 : 65536),
                                    "UTF-8");
            checkBootstrapInterrupted();
            JSONObject result;
            try {
                result = new JSONObject(raw);
            } catch (JSONException malformed) {
                throw new IOException("插件移植服务响应格式无效", malformed);
            }
            if (status == 422
                    && result.length() == 1
                    && "guard_artifact_unsupported".equals(result.optString("error")))
                throw new UnsupportedGuardArtifactException();
            if (status == 429
                    && result.length() == 1
                    && "bootstrap_busy".equals(result.optString("error")))
                throw new BootstrapBusyException();
            if (status != 200) throw new IOException("插件移植服务拒绝处理（HTTP " + status + "）");
            if (result.length() != 3
                    || !(result.opt("version") instanceof Number)
                    || result.getDouble("version") != 1
                    || !(result.opt("rule") instanceof String)
                    || !(result.opt("origin") instanceof String)
                    || result.getString("rule").trim().isEmpty()
                    || result.getString("rule").getBytes("UTF-8").length > 6 * 1024 * 1024)
                throw new IOException("插件移植服务响应字段无效");
            URI origin = new URI(result.getString("origin"));
            if (!("http".equals(origin.getScheme()) || "https".equals(origin.getScheme()))
                    || origin.getHost() == null
                    || origin.getUserInfo() != null
                    || origin.getFragment() != null
                    || origin.toString().length() > 8192) throw new IOException("插件移植服务返回无效来源");
            return result;
        } finally {
            if (observer != null) observer.closed(connection);
            connection.disconnect();
        }
    }

    public void release(String address) throws Exception {
        URI logical = new URI(address);
        read("catpaw://" + logical.getHost() + "/_release", "POST");
    }

    private String read(String address, String method, byte[] body) throws Exception {
        return read(address, method, body, null);
    }

    private String read(String address, String method, byte[] body, ConnectionObserver observer)
            throws Exception {
        URI logical = new URI(address);
        HttpURLConnection connection =
                (HttpURLConnection) new URL(resolve(address)).openConnection(Proxy.NO_PROXY);
        try {
            if (observer != null) observer.opened(connection);
            connection.setRequestMethod(method);
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(8000);
            connection.setReadTimeout("/api/drpy".equals(logical.getPath()) ? 45000 : 35000);
            if (body != null) {
                if (body.length > 4 * 1024 * 1024) throw new IOException("DRPY 请求超过大小限制");
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json; charset=UTF-8");
                connection.setFixedLengthStreamingMode(body.length);
                try (OutputStream output = connection.getOutputStream()) {
                    output.write(body);
                }
            }
            int status = connection.getResponseCode();
            if ("/api/drpy".equals(logical.getPath()) && status == 422) {
                InputStream input = connection.getErrorStream();
                String rawError =
                        input == null ? "{}" : new String(bytes(input, 16 * 1024), "UTF-8");
                String code = null;
                try {
                    Object value = new JSONObject(rawError).opt("error");
                    if (value instanceof String) code = (String) value;
                } catch (JSONException ignored) {
                    /* Do not expose untrusted response content. */
                }
                String message = drpyErrorMessage(code);
                if (message != null) throw new DrpySourceException(code, message);
            }
            if (status != 200) throw new IOException("CatPaw 线路请求失败（HTTP " + status + "）");
            String raw = new String(bytes(connection.getInputStream(), 16 * 1024 * 1024), "UTF-8");
            return raw.replace(endpoint + "/" + logical.getHost(), "catpaw://" + logical.getHost());
        } finally {
            if (observer != null) observer.closed(connection);
            connection.disconnect();
        }
    }

    public String installDrpy(JSONObject manifest) throws Exception {
        String rule = manifest.optString("rule");
        JSONObject headers = manifest.optJSONObject("headers");
        String origin = manifest.optString("origin");
        int timeout = manifest.optInt("requestTimeoutMs", 10000);
        if (!"drpy".equals(manifest.optString("kind"))
                || manifest.optInt("version") != 1
                || !DRPY_RUNTIME.equals(manifest.optString("runtime"))
                || !manifest.optString("sourceId").matches("[a-f0-9]{64}")
                || !(manifest.opt("rule") instanceof String)
                || rule.trim().isEmpty()
                || rule.getBytes("UTF-8").length > 6 * 1024 * 1024
                || !(manifest.opt("origin") instanceof String)
                || origin.length() > 8192
                || headers == null
                || timeout < 100
                || timeout > 15000) throw new IOException("DRPY 规则清单无效");
        URI location = new URI(origin);
        if (!("http".equals(location.getScheme())
                        || "https".equals(location.getScheme())
                        || "pkg".equals(location.getScheme()))
                || location.getHost() == null
                || location.getHost().isEmpty()
                || location.getUserInfo() != null
                || location.getFragment() != null) throw new IOException("DRPY 规则来源地址无效");
        if (headers.length() > 64) throw new IOException("DRPY 请求头过多");
        java.util.Iterator<String> keys = headers.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            Object value = headers.opt(key);
            if (!(value instanceof String)
                    || !key.matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+")
                    || key.matches("(?i:host|content-length|connection|transfer-encoding)")
                    || ((String) value).length() > 8192
                    || ((String) value).contains("\r")
                    || ((String) value).contains("\n")
                    || ((String) value).contains("\0")) throw new IOException("DRPY 请求头无效");
        }
        byte[] content = manifest.toString().getBytes("UTF-8");
        if (content.length > 16 * 1024 * 1024) throw new IOException("DRPY 规则清单超过大小限制");
        String id = hash(content);
        File folder = new File(root, id);
        if (!folder.isDirectory() && !folder.mkdirs()) throw new IOException("无法保存 DRPY 规则");
        File target = new File(folder, "drpy.json");
        synchronized (CatPawHost.class) {
            if (target.isFile()) {
                if (!hash(bytes(new FileInputStream(target), 16 * 1024 * 1024)).equals(id))
                    throw new IOException("已保存的 DRPY 规则校验失败");
            } else {
                File staging = new File(folder, "drpy.tmp");
                write(staging, content);
                if (!staging.renameTo(target)) throw new IOException("DRPY 规则保存失败");
            }
        }
        return "catpaw://" + id + "/api/drpy";
    }

    public String install(String source) throws Exception {
        if (!isBundle(source)) throw new IOException("没有 CatPaw 服务入口");
        byte[] code = source.getBytes("UTF-8");
        if (code.length > 16 * 1024 * 1024) throw new IOException("CatPaw 服务包超过大小限制");
        StringBuilder digest = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(code))
            digest.append(String.format(Locale.US, "%02x", b & 255));
        String hash = digest.toString();
        File folder = new File(root, hash);
        if (!folder.isDirectory() && !folder.mkdirs()) throw new IOException("无法保存 CatPaw 服务包");
        File script = new File(folder, "index.cjs");
        if (!script.exists()) {
            File staging = new File(folder, "index.tmp");
            write(staging, code);
            if (!staging.renameTo(script)) throw new IOException("CatPaw 服务包保存失败");
        }
        JSONObject raw = new JSONObject(read("catpaw://" + hash + "/t4"));
        JSONArray sites = raw.getJSONArray("sites"), valid = new JSONArray();
        for (int i = 0; i < sites.length(); i++) {
            JSONObject site = sites.optJSONObject(i);
            if (site == null || !site.optString("api").startsWith("catpaw://" + hash + "/api/"))
                continue;
            site.put(
                    "key",
                    "paw_" + site.optString("key", new URI(site.getString("api")).getPath()));
            site.put("type", 4);
            valid.put(site);
        }
        if (valid.length() == 0) throw new IOException("CatPaw 没有可用的本机线路");
        return new JSONObject().put("sites", valid).toString();
    }
}
