package com.pilipala.marcomovie;

import java.io.*;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicLong;
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
        final boolean fromAtomicBundle;

        RecoveredState(String raw, String origin, String selectedSite, boolean fromAtomicBundle) {
            this.raw = raw;
            this.origin = origin;
            this.selectedSite = selectedSite;
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
     * Loads the last atomically committed config version ({@code config-state.json}) so a cold
     * start after a crash mid-commit can never pair new pointers with an old body or vice versa.
     * Falls back cleanly to legacy {@code config.json} + preference pointers for pre-bundle
     * installs.
     */
    synchronized RecoveredState loadRecoveredState(
            String fallbackOrigin, String fallbackSelectedSite) throws IOException {
        File stateFile = new File(directory, STATE_FILE_NAME);
        File configFile = new File(directory, CONFIG_FILE_NAME);
        if (stateFile.isFile()) {
            try {
                String stateRaw = readUtf8File(stateFile, Cms.MAX_JSON + 65536);
                JSONObject obj = new JSONObject(stateRaw);
                String body = obj.optString("raw", "");
                if (!body.isEmpty()) {
                    String origin =
                            obj.optBoolean("hasOrigin", false) ? obj.optString("origin", "") : null;
                    String selected =
                            obj.optBoolean("hasSelectedSite", false)
                                    ? obj.optString("selectedSite", "")
                                    : null;
                    boolean needHealBody = !configFile.isFile();
                    if (!needHealBody) {
                        try {
                            String existingBody = readUtf8File(configFile, Cms.MAX_JSON);
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
                    return new RecoveredState(body, origin, selected, true);
                }
            } catch (Exception err) {
                AppLog.w("ConfigStore", "Read atomic config-state failed; falling back", err);
            }
        }
        if (configFile.isFile()) {
            String body = readUtf8File(configFile, Cms.MAX_JSON);
            return new RecoveredState(body, fallbackOrigin, fallbackSelectedSite, false);
        }
        return null;
    }

    private static String readUtf8File(File file, int maxBytes) throws IOException {
        try (InputStream in = new FileInputStream(file)) {
            return Cms.read(in, maxBytes);
        }
    }

    synchronized void writeVersioned(String raw, PointerSnapshot pointers) throws IOException {
        if (!directory.exists() && !directory.mkdirs()) throw new IOException("配置目录不可用");
        if (!directory.isDirectory()) throw new IOException("配置目录不可用");
        String statePayload;
        try {
            JSONObject obj = new JSONObject();
            obj.put("v", 1);
            obj.put("raw", raw == null ? "" : raw);
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
            statePayload = obj.toString();
        } catch (Exception err) {
            throw new IOException("无法序列化配置状态", err);
        }
        File pendingState = File.createTempFile("config-state-", ".tmp", directory);
        try {
            try (FileOutputStream out = new FileOutputStream(pendingState)) {
                out.write(statePayload.getBytes("UTF-8"));
                out.getFD().sync();
            }
            // Write config.json first; if config.json cannot be replaced, neither config-state.json
            // nor preferences are touched.
            write(raw);
            replaceAtomically(pendingState, new File(directory, STATE_FILE_NAME));
        } finally {
            pendingState.delete();
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
