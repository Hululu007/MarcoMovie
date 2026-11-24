package com.pilipala.marcomovie;

import java.io.*;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicLong;
import org.json.JSONArray;
import org.json.JSONObject;

/** Configuration destination, independent from preferences and media/account storage. */
final class ConfigStore {
    static final String CONFIG_FILE_NAME = "config.json";
    static final String STATE_FILE_NAME = "config-state.json";

    static final ExecutorService WRITE_EXECUTOR =
            Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "config-store-writer");
                        t.setDaemon(true);
                        return t;
                    });

    static final class PointerSnapshot {
        final String origin;
        final String selectedSite;
        final Object stateTag;

        PointerSnapshot(String origin, String selectedSite) {
            this(origin, selectedSite, null);
        }

        PointerSnapshot(String origin, String selectedSite, Object stateTag) {
            this.origin = origin;
            this.selectedSite = selectedSite;
            this.stateTag = stateTag;
        }
    }

    /** Atomically persisted config body + origin/selected pointers recovered at startup. */
    static final class RecoveredState {
        final String raw;
        final String origin;
        final String selectedSite;
        final String subscriptionId;
        final boolean fromAtomicBundle;

        RecoveredState(String raw, String origin, String selectedSite, boolean fromAtomicBundle) {
            this(raw, origin, selectedSite, subscriptionIdentity(origin, raw), fromAtomicBundle);
        }

        RecoveredState(
                String raw,
                String origin,
                String selectedSite,
                String subscriptionId,
                boolean fromAtomicBundle) {
            this.raw = raw;
            this.origin = origin;
            this.selectedSite = selectedSite;
            this.subscriptionId = subscriptionId == null ? "" : subscriptionId;
            this.fromAtomicBundle = fromAtomicBundle;
        }
    }

    interface PointerStore {
        PointerSnapshot readCurrentPointers();

        void applyPointers(PointerSnapshot snapshot);
    }

    interface SuccessCallback {
        void onWriteSucceeded(long seq, PointerSnapshot committed);
    }

    interface FailureCallback {
        void onWriteFailed(long seq, Exception error, PointerSnapshot rolledBackTo);
    }

    final File directory;
    private final Object pointerLock = new Object();
    private final AtomicLong writeSeq = new AtomicLong();
    private PointerSnapshot confirmedPointers;

    ConfigStore(File target) {
        directory = target;
    }

    static final class CommitResult {
        final boolean accepted;
        final long seq;
        final Future<Boolean> future;

        CommitResult(boolean accepted, long seq, Future<Boolean> future) {
            this.accepted = accepted;
            this.seq = seq;
            this.future = future;
        }
    }

    long latestWriteSeq() {
        return writeSeq.get();
    }

    Future<Boolean> saveAsync(
            final String raw,
            final PointerSnapshot nextPointers,
            final PointerStore pointerStore,
            final FailureCallback onFailure) {
        return saveInternal(-1L, raw, nextPointers, pointerStore, null, onFailure).future;
    }

    CommitResult saveAsync(
            final String raw,
            final PointerSnapshot nextPointers,
            final PointerStore pointerStore,
            final SuccessCallback onSuccess,
            final FailureCallback onFailure) {
        return saveInternal(-1L, raw, nextPointers, pointerStore, onSuccess, onFailure);
    }

    /**
     * Atomically commits {@code raw} and {@code nextPointers} only if no newer config write has
     * occurred since {@code expectedSeq}. Returns {@code accepted == false} without mutating
     * pointers or disk when stale.
     */
    CommitResult saveIfExpectedSeq(
            final long expectedSeq,
            final String raw,
            final PointerSnapshot nextPointers,
            final PointerStore pointerStore,
            final FailureCallback onFailure) {
        return saveInternal(expectedSeq, raw, nextPointers, pointerStore, null, onFailure);
    }

    CommitResult saveIfExpectedSeq(
            final long expectedSeq,
            final String raw,
            final PointerSnapshot nextPointers,
            final PointerStore pointerStore,
            final SuccessCallback onSuccess,
            final FailureCallback onFailure) {
        return saveInternal(expectedSeq, raw, nextPointers, pointerStore, onSuccess, onFailure);
    }

    private CommitResult saveInternal(
            final long expectedSeq,
            final String raw,
            final PointerSnapshot nextPointers,
            final PointerStore pointerStore,
            final SuccessCallback onSuccess,
            final FailureCallback onFailure) {
        final long seq;
        synchronized (pointerLock) {
            if (expectedSeq >= 0L && writeSeq.get() != expectedSeq) {
                return new CommitResult(false, writeSeq.get(), completedFalse());
            }
            if (confirmedPointers == null && pointerStore != null) {
                confirmedPointers = pointerStore.readCurrentPointers();
            }
            seq = writeSeq.incrementAndGet();
            // Do NOT mutate persisted preferences before disk persistence succeeds; otherwise an
            // abrupt process termination while queued leaves new pointers paired with an old body.
        }
        Future<Boolean> future =
                WRITE_EXECUTOR.submit(
                        new Callable<Boolean>() {
                            @Override
                            public Boolean call() {
                                if (seq < writeSeq.get()) {
                                    return Boolean.FALSE;
                                }
                                try {
                                    writeVersioned(raw, nextPointers);
                                    boolean committed = false;
                                    synchronized (pointerLock) {
                                        if (seq == writeSeq.get()) {
                                            confirmedPointers = nextPointers;
                                            if (pointerStore != null && nextPointers != null) {
                                                pointerStore.applyPointers(nextPointers);
                                            }
                                            committed = true;
                                        }
                                    }
                                    if (committed && onSuccess != null) {
                                        onSuccess.onWriteSucceeded(seq, nextPointers);
                                    }
                                    return Boolean.TRUE;
                                } catch (Exception error) {
                                    AppLog.w(
                                            "ConfigStore",
                                            "Sequenced config write #" + seq + " failed",
                                            error);
                                    PointerSnapshot rollback = null;
                                    boolean notify = false;
                                    synchronized (pointerLock) {
                                        if (seq == writeSeq.get()) {
                                            rollback = confirmedPointers;
                                            if (pointerStore != null && rollback != null) {
                                                pointerStore.applyPointers(rollback);
                                            }
                                            notify = true;
                                        }
                                    }
                                    if (notify && onFailure != null) {
                                        onFailure.onWriteFailed(seq, error, rollback);
                                    }
                                    return Boolean.FALSE;
                                }
                            }
                        });
        return new CommitResult(true, seq, future);
    }

    private static Future<Boolean> completedFalse() {
        return new Future<Boolean>() {
            @Override
            public boolean cancel(boolean mayInterruptIfRunning) {
                return false;
            }

            @Override
            public boolean isCancelled() {
                return false;
            }

            @Override
            public boolean isDone() {
                return true;
            }

            @Override
            public Boolean get() {
                return Boolean.FALSE;
            }

            @Override
            public Boolean get(long timeout, java.util.concurrent.TimeUnit unit) {
                return Boolean.FALSE;
            }
        };
    }

    void writeSequenced(final String raw, final PointerSnapshot confirmedAfterWrite)
            throws IOException {
        final long seq;
        synchronized (pointerLock) {
            seq = writeSeq.incrementAndGet();
        }
        Future<Void> future =
                WRITE_EXECUTOR.submit(
                        new Callable<Void>() {
                            @Override
                            public Void call() throws Exception {
                                if (seq < writeSeq.get()) {
                                    return null;
                                }
                                writeVersioned(raw, confirmedAfterWrite);
                                synchronized (pointerLock) {
                                    confirmedPointers = confirmedAfterWrite;
                                }
                                return null;
                            }
                        });
        awaitSequenced(future);
    }

    void deleteSequenced() throws IOException {
        final long seq;
        synchronized (pointerLock) {
            seq = writeSeq.incrementAndGet();
        }
        Future<Void> future =
                WRITE_EXECUTOR.submit(
                        new Callable<Void>() {
                            @Override
                            public Void call() {
                                if (seq < writeSeq.get()) {
                                    return null;
                                }
                                synchronized (ConfigStore.this) {
                                    new File(directory, STATE_FILE_NAME).delete();
                                    new File(directory, CONFIG_FILE_NAME).delete();
                                }
                                synchronized (pointerLock) {
                                    confirmedPointers = new PointerSnapshot(null, null, null);
                                }
                                return null;
                            }
                        });
        awaitSequenced(future);
    }

    private static void awaitSequenced(Future<Void> future) throws IOException {
        try {
            future.get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new InterruptedIOException("配置写入中断");
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof IOException) throw (IOException) cause;
            throw new IOException(
                    cause != null && cause.getMessage() != null ? cause.getMessage() : "无法保存配置",
                    cause);
        }
    }

    /**
     * Maximum UTF-8 byte cap when reading locally persisted configuration files. {@link
     * Cms#parseConfig} accepts up to {@link Cms#MAX_JSON} Java chars, which can occupy up to 4x as
     * many UTF-8 bytes for non-ASCII content (or up to 6x in legacy v1 JSON-escaped bundles).
     */
    private static final int MAX_LOCAL_CONFIG_BYTES = Cms.MAX_JSON * 4;

    private static final int MAX_LEGACY_V1_STATE_BYTES = Cms.MAX_JSON * 6 + 65536;
    private static final int MAX_V2_HEADER_BYTES = 128 * 1024;

    private static String normalizeOrigin(String value) {
        return value == null ? "" : value.trim();
    }

    /**
     * Computes a stable subscription identity distinct from the relative-URL base {@code origin}.
     * Non-empty HTTP/file origins identify a subscription by normalized URL; empty-origin local
     * imports (e.g., SAF {@code content://} documents) are identified by content hash so two
     * distinct local JSON subscriptions with empty origin never share identity.
     */
    static String subscriptionIdentity(String origin, String raw) {
        String body = raw == null ? "" : raw;
        try {
            return ConfigLibrary.identity(origin, body);
        } catch (Exception ignored) {
            String norm = normalizeOrigin(origin);
            return norm.isEmpty() ? "local:" + body.hashCode() : "url:" + norm;
        }
    }

    private static boolean containsSiteKey(String rawConfig, String siteKey) {
        if (rawConfig == null
                || rawConfig.isEmpty()
                || siteKey == null
                || siteKey.trim().isEmpty()) {
            return false;
        }
        try {
            JSONObject root = new JSONObject(Cms.withoutComments(rawConfig));
            JSONArray sites = root.optJSONArray("sites");
            if (sites != null) {
                for (int i = 0; i < sites.length(); i++) {
                    JSONObject item = sites.optJSONObject(i);
                    if (item != null && siteKey.equals(item.optString("key", ""))) {
                        return true;
                    }
                }
            }
        } catch (Exception ignored) {
        }
        try {
            Cms.Config parsed = Cms.parseConfig(rawConfig, null);
            for (Cms.Site s : parsed.sites) {
                if (s != null && siteKey.equals(s.key)) {
                    return true;
                }
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    private static final class ParsedStateBundle {
        final String body;
        final String origin;
        final String selectedSite;
        final String subscriptionId;

        ParsedStateBundle(String body, String origin, String selectedSite, String subscriptionId) {
            this.body = body;
            this.origin = origin;
            this.selectedSite = selectedSite;
            this.subscriptionId = subscriptionId == null ? "" : subscriptionId;
        }
    }

    /**
     * Reads either a v2 zero-expansion framed bundle ({@code <header-json>\n<raw-utf8-body>}) or a
     * legacy v1 JSON bundle ({@code {"v":1,"raw":...}}). Because v2 appends the exact raw UTF-8
     * bytes after the newline-terminated metadata header, arbitrarily quote-/backslash-heavy
     * configurations near {@link Cms#MAX_JSON} never suffer JSON-escape bloat or read-cap
     * truncation.
     */
    private static ParsedStateBundle readStateBundle(File stateFile) throws Exception {
        byte[] allBytes = readBoundedBytes(stateFile, MAX_LEGACY_V1_STATE_BYTES);
        int nl = -1;
        int headerScanLimit = Math.min(allBytes.length, MAX_V2_HEADER_BYTES);
        for (int i = 0; i < headerScanLimit; i++) {
            if (allBytes[i] == '\n') {
                nl = i;
                break;
            }
        }
        if (nl > 0) {
            String firstLine = new String(allBytes, 0, nl, "UTF-8").trim();
            if (firstLine.startsWith("{") && firstLine.endsWith("}")) {
                JSONObject header = new JSONObject(firstLine);
                if (header.optInt("v", 0) == 2 && header.has("rawBytes")) {
                    int expectedBytes = header.optInt("rawBytes", -1);
                    int payloadOffset = nl + 1;
                    int actualBytes = allBytes.length - payloadOffset;
                    if (expectedBytes < 0
                            || expectedBytes > MAX_LOCAL_CONFIG_BYTES
                            || actualBytes != expectedBytes) {
                        throw new IOException("配置状态快照长度校验失败");
                    }
                    String body = new String(allBytes, payloadOffset, actualBytes, "UTF-8");
                    String origin =
                            header.optBoolean("hasOrigin", false)
                                    ? header.optString("origin", "")
                                    : null;
                    String selected =
                            header.optBoolean("hasSelectedSite", false)
                                    ? header.optString("selectedSite", "")
                                    : null;
                    String subId = header.optString("subId", "").trim();
                    if (subId.isEmpty()) {
                        subId = subscriptionIdentity(origin, body);
                    }
                    return new ParsedStateBundle(body, origin, selected, subId);
                }
            }
        }
        // Backward compatibility: legacy v1 single-JSON bundle
        String stateRaw = new String(allBytes, "UTF-8");
        JSONObject obj = new JSONObject(stateRaw);
        String body = obj.optString("raw", "");
        String origin = obj.optBoolean("hasOrigin", false) ? obj.optString("origin", "") : null;
        String selected =
                obj.optBoolean("hasSelectedSite", false) ? obj.optString("selectedSite", "") : null;
        String subId = obj.optString("subId", "").trim();
        if (subId.isEmpty()) {
            subId = subscriptionIdentity(origin, body);
        }
        return new ParsedStateBundle(body, origin, selected, subId);
    }

    private static byte[] readBoundedBytes(File file, int maxBytes) throws IOException {
        long fileLen = file.length();
        if (fileLen > maxBytes) {
            throw new IOException("响应超过 " + maxBytes + " 字节限制");
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream((int) Math.max(256L, fileLen));
        try (InputStream in = new FileInputStream(file)) {
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) != -1) {
                if (out.size() + n > maxBytes) {
                    throw new IOException("响应超过 " + maxBytes + " 字节限制");
                }
                out.write(buf, 0, n);
            }
        }
        return out.toByteArray();
    }

    /**
     * Loads the last atomically committed config version ({@code config-state.json}) so a cold
     * start after a crash mid-commit can never pair new pointers with an old body or vice versa.
     */
    synchronized RecoveredState loadRecoveredState(
            String fallbackOrigin, String fallbackSelectedSite) throws IOException {
        return loadRecoveredState(fallbackOrigin, fallbackSelectedSite, null);
    }

    /**
     * Loads the last atomically committed config version ({@code config-state.json}), matching
     * {@code fallbackSubscriptionId} (or non-empty {@code fallbackOrigin} when no subscription ID
     * was provided) before preserving {@code fallbackSelectedSite}. Empty origins (such as SAF
     * {@code content://} imports) never count as the same subscription unless {@code
     * fallbackSubscriptionId} matches the committed bundle's identity.
     */
    synchronized RecoveredState loadRecoveredState(
            String fallbackOrigin, String fallbackSelectedSite, String fallbackSubscriptionId)
            throws IOException {
        File stateFile = new File(directory, STATE_FILE_NAME);
        File configFile = new File(directory, CONFIG_FILE_NAME);
        if (stateFile.isFile()) {
            try {
                ParsedStateBundle bundle = readStateBundle(stateFile);
                String body = bundle.body;
                if (!body.isEmpty()) {
                    String origin = bundle.origin;
                    String bundleSelected = bundle.selectedSite;
                    String bundleSubId = bundle.subscriptionId;
                    boolean sameSubscription;
                    String cleanFallbackSubId =
                            fallbackSubscriptionId == null ? "" : fallbackSubscriptionId.trim();
                    if (!cleanFallbackSubId.isEmpty()) {
                        sameSubscription =
                                !bundleSubId.isEmpty() && bundleSubId.equals(cleanFallbackSubId);
                    } else {
                        String normOrigin = normalizeOrigin(origin);
                        sameSubscription =
                                !normOrigin.isEmpty()
                                        && normOrigin.equals(normalizeOrigin(fallbackOrigin));
                    }
                    String effectiveSelected =
                            sameSubscription
                                            && fallbackSelectedSite != null
                                            && !fallbackSelectedSite.isEmpty()
                                            && containsSiteKey(body, fallbackSelectedSite)
                                    ? fallbackSelectedSite
                                    : bundleSelected;
                    boolean needHealBody = !configFile.isFile();
                    if (!needHealBody) {
                        try {
                            String existingBody = readUtf8File(configFile, MAX_LOCAL_CONFIG_BYTES);
                            needHealBody = !body.equals(existingBody);
                        } catch (Exception ignored) {
                            needHealBody = true;
                        }
                    }
                    if (needHealBody) {
                        try {
                            write(body);
                        } catch (Exception ignored) {
                        }
                    }
                    return new RecoveredState(body, origin, effectiveSelected, bundleSubId, true);
                }
            } catch (Exception err) {
                AppLog.w("ConfigStore", "Read atomic config-state failed; falling back", err);
            }
        }
        if (configFile.isFile()) {
            String body = readUtf8File(configFile, MAX_LOCAL_CONFIG_BYTES);
            return new RecoveredState(
                    body,
                    fallbackOrigin,
                    fallbackSelectedSite,
                    subscriptionIdentity(fallbackOrigin, body),
                    false);
        }
        return null;
    }

    private static String readUtf8File(File file, int maxBytes) throws IOException {
        return new String(readBoundedBytes(file, maxBytes), "UTF-8");
    }

    private static byte[] readAllBytesQuiet(File file) {
        if (file == null || !file.isFile()) return null;
        try (InputStream in = new FileInputStream(file);
                ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return out.toByteArray();
        } catch (IOException ignored) {
            return null;
        }
    }

    /**
     * Atomically commits {@code config-state.json} (v2 zero-expansion framing: metadata JSON line +
     * exact raw UTF-8 body) as the single recoverable commit point BEFORE replacing {@code
     * config.json}. Pre-checks both targets and stages both temp files with {@code fsync} so any
     * fault or abrupt process termination — including first-time upgrade from a legacy 0.6.0
     * directory without {@code config-state.json} or near-16-MiB quote-heavy configs — can only
     * ever recover complete A or complete B, never a mixed origin/body/selection tuple.
     */
    synchronized void writeVersioned(String raw, PointerSnapshot pointers) throws IOException {
        if (!directory.exists() && !directory.mkdirs()) throw new IOException("配置目录不可用");
        if (!directory.isDirectory()) throw new IOException("配置目录不可用");
        File configTarget = new File(directory, CONFIG_FILE_NAME);
        File stateTarget = new File(directory, STATE_FILE_NAME);
        if (configTarget.exists() && !configTarget.isFile()) {
            throw new IOException("无法保存配置，原配置已保留");
        }
        if (stateTarget.exists() && !stateTarget.isFile()) {
            throw new IOException("无法保存配置状态，原配置已保留");
        }
        String body = raw == null ? "" : raw;
        byte[] bodyBytes = body.getBytes("UTF-8");
        String originForId = pointers != null ? pointers.origin : null;
        String subId = subscriptionIdentity(originForId, body);
        byte[] headerLineBytes;
        try {
            JSONObject obj = new JSONObject();
            obj.put("v", 2);
            obj.put("rawBytes", bodyBytes.length);
            obj.put("subId", subId);
            if (pointers != null && pointers.origin != null) {
                obj.put("hasOrigin", true);
                obj.put("origin", pointers.origin);
            } else {
                obj.put("hasOrigin", false);
            }
            if (pointers != null && pointers.selectedSite != null) {
                obj.put("hasSelectedSite", true);
                obj.put("selectedSite", pointers.selectedSite);
            } else {
                obj.put("hasSelectedSite", false);
            }
            headerLineBytes = (obj.toString() + "\n").getBytes("UTF-8");
        } catch (Exception err) {
            throw new IOException("无法序列化配置状态", err);
        }
        byte[] previousStateBytes = readAllBytesQuiet(stateTarget);
        File pendingState = File.createTempFile("config-state-", ".tmp", directory);
        File pendingConfig = File.createTempFile("config-", ".tmp", directory);
        boolean statePublished = false;
        try {
            try (FileOutputStream out = new FileOutputStream(pendingState)) {
                out.write(headerLineBytes);
                out.write(bodyBytes);
                out.getFD().sync();
            }
            try (FileOutputStream out = new FileOutputStream(pendingConfig)) {
                out.write(bodyBytes);
                out.getFD().sync();
            }
            // Publish the single-file atomic bundle FIRST. If this fails (including on first-time
            // migration from legacy 0.6.0), config.json is completely untouched. If the process
            // dies right after this rename, cold recovery reads complete B from config-state.json
            // and heals config.json + preferences atomically.
            replaceAtomically(pendingState, stateTarget);
            statePublished = true;
            replaceAtomically(pendingConfig, configTarget);
        } catch (IOException err) {
            if (statePublished) {
                // Best-effort rollback of config-state.json if config.json rename unexpectedly
                // failed despite passing the pre-check.
                if (previousStateBytes != null) {
                    try {
                        File rollbackTmp =
                                File.createTempFile("config-state-rb-", ".tmp", directory);
                        try {
                            try (FileOutputStream out = new FileOutputStream(rollbackTmp)) {
                                out.write(previousStateBytes);
                                out.getFD().sync();
                            }
                            replaceAtomically(rollbackTmp, stateTarget);
                        } finally {
                            rollbackTmp.delete();
                        }
                    } catch (IOException ignored) {
                    }
                } else {
                    stateTarget.delete();
                }
            }
            throw err;
        } finally {
            pendingState.delete();
            pendingConfig.delete();
        }
    }

    synchronized void write(String raw) throws IOException {
        if (!directory.exists() && !directory.mkdirs()) throw new IOException("配置目录不可用");
        if (!directory.isDirectory()) throw new IOException("配置目录不可用");
        File pending = File.createTempFile("config-", ".tmp", directory);
        try {
            try (FileOutputStream out = new FileOutputStream(pending)) {
                out.write(raw.getBytes("UTF-8"));
                out.getFD().sync();
            }
            replaceAtomically(pending, new File(directory, CONFIG_FILE_NAME));
        } finally {
            pending.delete();
        }
    }

    private void replaceAtomically(File pending, File target) throws IOException {
        if (!pending.renameTo(target)) {
            // Windows cannot rename over an existing file; Android uses the atomic path above.
            File backup = new File(directory, target.getName() + ".bak");
            if (!target.isFile()
                    || (backup.exists() && !backup.delete())
                    || !target.renameTo(backup)) {
                throw new IOException("无法保存配置，原配置已保留");
            }
            if (!pending.renameTo(target)) {
                backup.renameTo(target);
                throw new IOException("无法保存配置，原配置已保留");
            }
            backup.delete();
        }
    }
}
