package com.pilipala.marcomovie;

import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Bounded global search. A late or cancelled native plugin can never post a new result. */
public final class SearchCoordinator implements AutoCloseable {
    public enum Outcome {
        RESULT,
        EMPTY,
        FAILED,
        VERIFICATION_REQUIRED,
        TIMEOUT,
        BUSY
    }

    public static final class VerificationRequiredException extends java.io.IOException {
        public VerificationRequiredException() {
            super("此片源需要完成网站验证码");
        }
    }

    public interface Runner {
        List<Cms.Video> search(Cms.Site site, String query) throws Exception;
    }

    public interface Listener {
        void source(Cms.Site site, List<Cms.Video> videos, Outcome outcome);
    }

    private static int baseThreads = 6;
    private static int maxPoolThreads = 12;
    private static int wedgedWorkers = 0;
    static volatile Runnable onLowMemoryHook;
    private static final ConcurrentHashMap<String, AtomicInteger> WEDGED_SITES =
            new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, Long> WEDGED_AT_NANOS =
            new ConcurrentHashMap<>();
    private static final long WEDGED_SITE_TTL_NANOS = TimeUnit.SECONDS.toNanos(30);
    private static final ThreadPoolExecutor NETWORK =
            new ThreadPoolExecutor(
                    6,
                    6,
                    30,
                    TimeUnit.SECONDS,
                    new ArrayBlockingQueue<Runnable>(64),
                    r -> {
                        Thread t = new Thread(r, "movie-global-search");
                        t.setDaemon(true);
                        return t;
                    });
    // Host-managed HTTP requests can be cancelled. Keep them out of the pool
    // used by native plugins, which may ignore both interruption and timeouts.
    private static final ThreadPoolExecutor HTTP_NETWORK =
            new ThreadPoolExecutor(
                    4,
                    4,
                    30,
                    TimeUnit.SECONDS,
                    new ArrayBlockingQueue<Runnable>(64),
                    r -> {
                        Thread t = new Thread(r, "movie-http-search");
                        t.setDaemon(true);
                        return t;
                    });
    private static final ScheduledExecutorService TIMER =
            Executors.newSingleThreadScheduledExecutor(
                    r -> {
                        Thread t = new Thread(r, "movie-search-deadline");
                        t.setDaemon(true);
                        return t;
                    });
    private final List<Job> jobs = new ArrayList<>();
    private final long requestMs, sessionMs;
    private final Runner runner;
    private final Listener listener;
    private final int resultLimit;
    private final int maxConcurrency;
    private volatile boolean closed;
    private volatile boolean oomAborted;
    private ScheduledFuture<?> deadline;
    private int nextJob, inFlight;

    public SearchCoordinator(Runner runner, Listener listener) {
        this(runner, listener, 20000, 90000);
    }

    SearchCoordinator(Runner runner, Listener listener, long requestMs, long sessionMs) {
        this(runner, listener, requestMs, sessionMs, 24, 0);
    }

    SearchCoordinator(
            Runner runner, Listener listener, long requestMs, long sessionMs, int resultLimit) {
        this(runner, listener, requestMs, sessionMs, resultLimit, 0);
    }

    SearchCoordinator(
            Runner runner,
            Listener listener,
            long requestMs,
            long sessionMs,
            int resultLimit,
            int maxConcurrency) {
        this.runner = runner;
        this.listener = listener;
        this.requestMs = requestMs;
        this.sessionMs = sessionMs;
        this.resultLimit = Math.max(1, resultLimit);
        this.maxConcurrency = Math.max(0, maxConcurrency);
    }

    static synchronized void configureThreads(int count) {
        baseThreads = Math.max(2, Math.min(6, count));
        syncPoolCapacity();
    }

    static synchronized void configureMaxPoolThreads(int cap) {
        maxPoolThreads = Math.max(4, Math.min(16, cap));
        syncPoolCapacity();
    }

    static int computePoolCapacity(int base, int wedged, int maxCap) {
        int safeBase = Math.max(2, Math.min(6, base));
        int safeCap = Math.max(safeBase, Math.min(16, maxCap));
        return Math.max(2, Math.min(safeCap, safeBase + Math.max(0, wedged)));
    }

    private static synchronized void syncPoolCapacity() {
        int target = computePoolCapacity(baseThreads, wedgedWorkers, maxPoolThreads);
        if (target > NETWORK.getMaximumPoolSize()) {
            NETWORK.setMaximumPoolSize(target);
            NETWORK.setCorePoolSize(target);
        } else {
            NETWORK.setCorePoolSize(target);
            NETWORK.setMaximumPoolSize(target);
        }
    }

    private static synchronized void onJobWedged(String siteKey) {
        wedgedWorkers++;
        if (siteKey != null && !siteKey.isEmpty()) {
            AtomicInteger counter = WEDGED_SITES.get(siteKey);
            if (counter == null) {
                AtomicInteger created = new AtomicInteger();
                AtomicInteger prev = WEDGED_SITES.putIfAbsent(siteKey, created);
                counter = prev != null ? prev : created;
            }
            counter.incrementAndGet();
            WEDGED_AT_NANOS.put(siteKey, System.nanoTime());
        }
        syncPoolCapacity();
    }

    private static synchronized void onWedgedJobExited(String siteKey) {
        if (wedgedWorkers > 0) wedgedWorkers--;
        if (siteKey != null && !siteKey.isEmpty()) {
            AtomicInteger count = WEDGED_SITES.get(siteKey);
            if (count != null && count.decrementAndGet() <= 0) {
                WEDGED_SITES.remove(siteKey, count);
                WEDGED_AT_NANOS.remove(siteKey);
            }
        }
        syncPoolCapacity();
    }

    static boolean isSiteWedged(String siteKey) {
        if (siteKey == null || siteKey.isEmpty()) return false;
        AtomicInteger count = WEDGED_SITES.get(siteKey);
        if (count == null || count.get() <= 0) return false;
        Long since = WEDGED_AT_NANOS.get(siteKey);
        if (since != null && System.nanoTime() - since > WEDGED_SITE_TTL_NANOS) {
            synchronized (SearchCoordinator.class) {
                AtomicInteger latest = WEDGED_SITES.get(siteKey);
                Long latestSince = WEDGED_AT_NANOS.get(siteKey);
                if (latest != null
                        && latestSince != null
                        && System.nanoTime() - latestSince > WEDGED_SITE_TTL_NANOS) {
                    int expiredCount = Math.max(0, latest.get());
                    WEDGED_SITES.remove(siteKey, latest);
                    WEDGED_AT_NANOS.remove(siteKey);
                    wedgedWorkers = Math.max(0, wedgedWorkers - expiredCount);
                    syncPoolCapacity();
                    return false;
                }
            }
        }
        return true;
    }

    private static synchronized boolean isPluginPoolExhausted() {
        return wedgedWorkers >= computePoolCapacity(baseThreads, wedgedWorkers, maxPoolThreads);
    }

    private static boolean usesHttpPool(Cms.Site site) {
        return site.supported()
                || HttpT4Engine.eligible(site)
                || (site.api != null
                        && (site.api.startsWith("emby://account/")
                                || site.api.startsWith("alist://mount/")));
    }

    public synchronized void start(List<Cms.Site> sites, String query) {
        if (closed || !jobs.isEmpty()) throw new IllegalStateException("Search already started");
        for (Cms.Site site : sites) jobs.add(new Job(site, query));
        deadline =
                TIMER.schedule(
                        () -> {
                            for (Job job : jobs)
                                job.finish(
                                        Collections.emptyList(),
                                        job.started ? Outcome.TIMEOUT : Outcome.BUSY);
                        },
                        sessionMs,
                        TimeUnit.MILLISECONDS);
        pump();
    }

    private synchronized void pump() {
        if (oomAborted) {
            while (nextJob < jobs.size()) {
                Job remaining = jobs.get(nextJob++);
                if (!remaining.done.get()) {
                    remaining.finish(Collections.emptyList(), Outcome.BUSY);
                }
            }
            return;
        }
        int limit = maxConcurrency > 0 ? Math.min(maxConcurrency, baseThreads) : baseThreads;
        while (!closed && !oomAborted && inFlight < limit && nextJob < jobs.size()) {
            Job job = jobs.get(nextJob++);
            if (job.done.get()) continue;
            if (isSiteWedged(job.site.key)) {
                job.finish(Collections.emptyList(), Outcome.BUSY);
                continue;
            }
            boolean httpJob = usesHttpPool(job.site);
            if (!httpJob && isPluginPoolExhausted()) {
                job.finish(Collections.emptyList(), Outcome.BUSY);
                continue;
            }
            job.allocated = true;
            inFlight++;
            try {
                job.queueTimeout =
                        TIMER.schedule(
                                () -> {
                                    if (!job.started) {
                                        job.finish(Collections.emptyList(), Outcome.BUSY);
                                    }
                                },
                                requestMs,
                                TimeUnit.MILLISECONDS);
                job.future = RequestScope.submit(httpJob ? HTTP_NETWORK : NETWORK, job);
            } catch (RejectedExecutionException busy) {
                job.finish(Collections.emptyList(), Outcome.BUSY);
            }
        }
    }

    final class Job implements Runnable {
        final Cms.Site site;
        final String query;
        final AtomicBoolean done = new AtomicBoolean();
        final AtomicBoolean exited = new AtomicBoolean();
        final AtomicBoolean wedged = new AtomicBoolean();
        volatile boolean started;
        volatile Thread runningThread;
        boolean allocated;
        volatile Future<?> future;
        volatile ScheduledFuture<?> queueTimeout;
        volatile ScheduledFuture<?> timeout;

        Job(Cms.Site site, String query) {
            this.site = site;
            this.query = query;
        }

        public void run() {
            if (closed || done.get()) {
                exited.set(true);
                return;
            }
            if (isSiteWedged(site.key)) {
                exited.set(true);
                finish(Collections.emptyList(), Outcome.BUSY);
                return;
            }
            runningThread = Thread.currentThread();
            started = true;
            ScheduledFuture<?> qt = queueTimeout;
            if (qt != null) qt.cancel(false);
            timeout =
                    TIMER.schedule(
                            () -> finish(Collections.emptyList(), Outcome.TIMEOUT),
                            requestMs,
                            TimeUnit.MILLISECONDS);
            try {
                List<Cms.Video> raw = runner.search(site, query);
                List<Cms.Video> videos = new ArrayList<>();
                Set<String> seen = new HashSet<>();
                if (raw != null)
                    for (Cms.Video v : raw)
                        if (v != null
                                && v.id != null
                                && !v.id.isEmpty()
                                && !v.id.startsWith("msearch:")
                                && seen.add(v.id)) {
                            videos.add(v);
                            if (videos.size() == resultLimit) break;
                        }
                finish(videos, videos.isEmpty() ? Outcome.EMPTY : Outcome.RESULT);
            } catch (Throwable error) {
                if (error instanceof OutOfMemoryError) {
                    oomAborted = true;
                    Runnable hook = onLowMemoryHook;
                    if (hook != null) {
                        try {
                            hook.run();
                        } catch (Throwable ignored) {
                        }
                    }
                }
                finish(
                        Collections.emptyList(),
                        Thread.currentThread().isInterrupted()
                                ? Outcome.TIMEOUT
                                : error instanceof VerificationRequiredException
                                        ? Outcome.VERIFICATION_REQUIRED
                                        : Outcome.FAILED);
            } finally {
                exited.set(true);
                runningThread = null;
                if (wedged.compareAndSet(true, false)) {
                    onWedgedJobExited(site.key);
                }
            }
        }

        void markWedgedIfRunning() {
            if (started && !exited.get() && wedged.compareAndSet(false, true)) {
                onJobWedged(site.key);
                if (exited.get() && wedged.compareAndSet(true, false)) {
                    onWedgedJobExited(site.key);
                }
            }
        }

        void finish(List<Cms.Video> videos, Outcome outcome) {
            if (!done.compareAndSet(false, true)) return;
            if (queueTimeout != null) queueTimeout.cancel(false);
            if (timeout != null) timeout.cancel(false);
            if (outcome == Outcome.TIMEOUT || outcome == Outcome.BUSY) {
                if (future != null) future.cancel(true);
                markWedgedIfRunning();
            }
            synchronized (SearchCoordinator.this) {
                if (allocated) {
                    allocated = false;
                    inFlight--;
                }
            }
            if (!closed) {
                listener.source(site, Collections.unmodifiableList(videos), outcome);
                try {
                    TIMER.execute(
                            () -> {
                                try {
                                    pump();
                                } catch (Throwable ignored) {
                                }
                            });
                } catch (RejectedExecutionException ignored) {
                }
            }
        }

        void cancel() {
            done.set(true);
            if (queueTimeout != null) queueTimeout.cancel(false);
            if (timeout != null) timeout.cancel(false);
            if (future != null) future.cancel(true);
            // Do not synchronously flag a site as wedged on user-initiated close(): an
            // interruptible
            // HTTP or plugin worker needs a brief moment to unwind after future.cancel(true),
            // otherwise an immediate second search on the same page falsely marks healthy sites
            // BUSY.
            if (started && !exited.get() && !usesHttpPool(site)) {
                try {
                    TIMER.schedule(
                            () -> {
                                if (!exited.get()) markWedgedIfRunning();
                            },
                            4500,
                            TimeUnit.MILLISECONDS);
                } catch (RejectedExecutionException ignored) {
                }
            }
        }
    }

    @Override
    public synchronized void close() {
        if (closed) return;
        closed = true;
        if (deadline != null) deadline.cancel(false);
        for (Job job : jobs) job.cancel();
        NETWORK.purge();
        HTTP_NETWORK.purge();
    }
}
