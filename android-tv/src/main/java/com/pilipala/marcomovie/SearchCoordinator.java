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

    static final int HTTP_CONCURRENCY = 8;
    private static int baseThreads = 6;
    private static int maxPoolThreads = 16;
    private static int wedgedWorkers = 0;
    static volatile Runnable onLowMemoryHook;
    private static final ConcurrentHashMap<String, AtomicInteger> WEDGED_SITES =
            new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, Long> WEDGED_AT_NANOS =
            new ConcurrentHashMap<>();
    private static final CopyOnWriteArraySet<SearchCoordinator> ACTIVE_COORDINATORS =
            new CopyOnWriteArraySet<>();
    private static final long WEDGED_SITE_TTL_NANOS = TimeUnit.SECONDS.toNanos(15);
    private static final ThreadPoolExecutor NETWORK =
            new ThreadPoolExecutor(
                    6,
                    6,
                    30,
                    TimeUnit.SECONDS,
                    new LinkedBlockingQueue<Runnable>(),
                    r -> {
                        Thread t = new Thread(r, "movie-global-search");
                        t.setDaemon(true);
                        return t;
                    });
    // Host-managed HTTP requests can be cancelled. Keep them out of the pool
    // used by native plugins, which may ignore both interruption and timeouts.
    private static final ThreadPoolExecutor HTTP_NETWORK =
            new ThreadPoolExecutor(
                    HTTP_CONCURRENCY,
                    HTTP_CONCURRENCY,
                    30,
                    TimeUnit.SECONDS,
                    new LinkedBlockingQueue<Runnable>(),
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
    private ScheduledFuture<?> exhaustionGraceFuture;
    private int nextHttpJob, nextPluginJob, inFlightHttp, inFlightPlugin;

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

    /**
     * Scales global session timeout to multi-depot catalogs (e.g. 400+ sites) while keeping normal
     * <= 60-site searches within the 90s default envelope.
     */
    static long computeSessionTimeoutMs(
            int sourceCount, long perSourceTimeoutMs, int pluginThreads) {
        int threads = Math.max(2, pluginThreads);
        long perSiteBudget = Math.min(Math.max(2000L, perSourceTimeoutMs), 6000L);
        long est = ((Math.max(1, sourceCount) + threads - 1L) / threads) * perSiteBudget + 45_000L;
        return Math.max(90_000L, Math.min(360_000L, est));
    }

    static long computeExhaustionGraceMs(long requestMs, long sessionMs) {
        return Math.min(Math.max(requestMs * 2L, 200L), Math.max(200L, sessionMs / 2L));
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

    private static void onWedgedJobExited(String siteKey) {
        synchronized (SearchCoordinator.class) {
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
        if (!ACTIVE_COORDINATORS.isEmpty()) {
            try {
                TIMER.execute(
                        () -> {
                            for (SearchCoordinator coord : ACTIVE_COORDINATORS) {
                                try {
                                    coord.pump();
                                } catch (Throwable ignored) {
                                }
                            }
                        });
            } catch (RejectedExecutionException ignored) {
            }
        }
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

    private static synchronized int computeFreePluginWorkers() {
        return Math.max(
                0, computePoolCapacity(baseThreads, wedgedWorkers, maxPoolThreads) - wedgedWorkers);
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
        ACTIVE_COORDINATORS.add(this);
        deadline =
                TIMER.schedule(
                        () -> {
                            for (Job job : jobs)
                                job.finish(
                                        Collections.emptyList(),
                                        job.started ? Outcome.TIMEOUT : Outcome.BUSY);
                            unregisterCoordinator();
                        },
                        sessionMs,
                        TimeUnit.MILLISECONDS);
        pump();
    }

    private synchronized void unregisterCoordinator() {
        ACTIVE_COORDINATORS.remove(this);
        if (exhaustionGraceFuture != null) {
            exhaustionGraceFuture.cancel(false);
            exhaustionGraceFuture = null;
        }
    }

    private synchronized boolean hasPendingPluginJob() {
        for (int i = nextPluginJob; i < jobs.size(); i++) {
            Job job = jobs.get(i);
            if (!usesHttpPool(job.site) && !job.done.get()) return true;
        }
        return false;
    }

    private synchronized void scheduleExhaustionGraceIfNeeded() {
        if (closed || oomAborted || inFlightPlugin > 0 || !hasPendingPluginJob()) return;
        if (exhaustionGraceFuture != null && !exhaustionGraceFuture.isDone()) return;
        long graceMs = computeExhaustionGraceMs(requestMs, sessionMs);
        try {
            exhaustionGraceFuture =
                    TIMER.schedule(
                            () -> {
                                List<Job> toBusy = null;
                                synchronized (SearchCoordinator.this) {
                                    exhaustionGraceFuture = null;
                                    if (closed || oomAborted) return;
                                    if (inFlightPlugin == 0 && isPluginPoolExhausted()) {
                                        toBusy = new ArrayList<>();
                                        while (nextPluginJob < jobs.size()) {
                                            Job j = jobs.get(nextPluginJob++);
                                            if (!usesHttpPool(j.site) && !j.done.get()) {
                                                toBusy.add(j);
                                            }
                                        }
                                    }
                                }
                                if (toBusy != null) {
                                    for (Job j : toBusy) {
                                        j.finish(Collections.emptyList(), Outcome.BUSY);
                                    }
                                } else {
                                    pump();
                                }
                            },
                            graceMs,
                            TimeUnit.MILLISECONDS);
        } catch (RejectedExecutionException ignored) {
        }
    }

    private synchronized void pump() {
        if (closed) return;
        if (oomAborted) {
            for (Job remaining : jobs) {
                if (!remaining.done.get()) {
                    remaining.finish(Collections.emptyList(), Outcome.BUSY);
                }
            }
            nextHttpJob = jobs.size();
            nextPluginJob = jobs.size();
            unregisterCoordinator();
            return;
        }

        // Lane 1: Host-controlled HTTP / Emby / Alist sources (never starved by wedged spiders).
        while (!closed && !oomAborted && nextHttpJob < jobs.size()) {
            int maxHttp =
                    maxConcurrency > 0
                            ? Math.max(0, maxConcurrency - (inFlightHttp + inFlightPlugin))
                            : Math.max(0, HTTP_CONCURRENCY - inFlightHttp);
            if (maxHttp <= 0) break;
            Job job = jobs.get(nextHttpJob++);
            if (!usesHttpPool(job.site) || job.done.get()) continue;
            if (isSiteWedged(job.site.key)) {
                job.finish(Collections.emptyList(), Outcome.BUSY);
                continue;
            }
            job.allocatedHttp = true;
            inFlightHttp++;
            try {
                job.future = RequestScope.submit(HTTP_NETWORK, job);
            } catch (RejectedExecutionException busy) {
                job.finish(Collections.emptyList(), Outcome.BUSY);
            }
        }

        // Lane 2: Native JS / Python / Dex plugin spiders.
        boolean stalledByExhaustion = false;
        while (!closed && !oomAborted && nextPluginJob < jobs.size()) {
            Job job = jobs.get(nextPluginJob);
            if (usesHttpPool(job.site) || job.done.get()) {
                nextPluginJob++;
                continue;
            }
            if (isSiteWedged(job.site.key)) {
                nextPluginJob++;
                job.finish(Collections.emptyList(), Outcome.BUSY);
                continue;
            }
            int freeWorkers = computeFreePluginWorkers();
            if (freeWorkers <= 0) {
                stalledByExhaustion = true;
                break;
            }
            int effectivePluginLimit = Math.min(baseThreads, freeWorkers);
            int pluginHeadroom =
                    maxConcurrency > 0
                            ? Math.max(
                                    0,
                                    Math.min(
                                            maxConcurrency - (inFlightHttp + inFlightPlugin),
                                            effectivePluginLimit - inFlightPlugin))
                            : Math.max(0, effectivePluginLimit - inFlightPlugin);
            if (pluginHeadroom <= 0) break;
            nextPluginJob++;
            if (exhaustionGraceFuture != null) {
                exhaustionGraceFuture.cancel(false);
                exhaustionGraceFuture = null;
            }
            job.allocatedPlugin = true;
            inFlightPlugin++;
            try {
                job.future = RequestScope.submit(NETWORK, job);
            } catch (RejectedExecutionException busy) {
                job.finish(Collections.emptyList(), Outcome.BUSY);
            }
        }
        if (stalledByExhaustion) {
            scheduleExhaustionGraceIfNeeded();
        }
        boolean allDone = true;
        for (int i = 0; i < jobs.size(); i++) {
            if (!jobs.get(i).done.get()) {
                allDone = false;
                break;
            }
        }
        if (allDone) {
            unregisterCoordinator();
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
        boolean allocatedHttp;
        boolean allocatedPlugin;
        volatile Future<?> future;
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
            if (timeout != null) timeout.cancel(false);
            if (outcome == Outcome.TIMEOUT || outcome == Outcome.BUSY) {
                if (future != null) future.cancel(true);
                markWedgedIfRunning();
            }
            synchronized (SearchCoordinator.this) {
                if (allocatedHttp) {
                    allocatedHttp = false;
                    if (inFlightHttp > 0) inFlightHttp--;
                }
                if (allocatedPlugin) {
                    allocatedPlugin = false;
                    if (inFlightPlugin > 0) inFlightPlugin--;
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
            if (timeout != null) timeout.cancel(false);
            if (future != null) future.cancel(true);
            // Do not synchronously flag a site as wedged on user-initiated close(): an
            // interruptible HTTP or plugin worker needs a brief moment to unwind after
            // future.cancel(true), otherwise an immediate second search on the same page
            // falsely marks healthy sites BUSY.
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
        unregisterCoordinator();
        if (deadline != null) deadline.cancel(false);
        for (Job job : jobs) job.cancel();
        NETWORK.purge();
        HTTP_NETWORK.purge();
    }
}
