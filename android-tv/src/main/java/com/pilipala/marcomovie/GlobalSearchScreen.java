package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.*;
import android.widget.*;

import androidx.recyclerview.widget.DiffUtil;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;

import org.json.*;

import java.util.*;

/** Dedicated global search page with Apple TV two-column layout, exact/fuzzy match modes, and local remote-control keyboard. */
public final class GlobalSearchScreen implements AutoCloseable {
    // Apple TV dark static palette (zero runtime blur, sculpted glass hairlines for 3m viewing)
    private static final int BG_PAGE = 0xff0a0e15;
    private static final int BG_PAGE_BOTTOM = 0xff06080d;
    private static final int BG_PANEL = 0xff141923;
    private static final int BG_PANEL_BOTTOM = 0xff0e121a;
    private static final int BORDER_PANEL = 0x28ffffff;
    private static final int BG_FIELD = 0xff0b0f16;
    private static final int BG_FIELD_FOCUS = 0xff1b2535;
    private static final int BG_SEGMENT_TRACK = 0xff0a0e14;
    private static final int BG_PILL_SELECTED = 0xfff2f6fb;
    private static final int BG_KEY = 0xff212936;
    private static final int BG_KEY_SELECTED = 0xff314258;
    private static final int BG_FILTER = 0xff19212c;
    private static final int BG_FILTER_SELECTED = 0xff2b3e56;
    private static final int BORDER_FILTER_SELECTED = 0xff82b0e8;
    private static final int BG_HOT_CARD = 0xff151c27;
    private static final int BORDER_HOT_CARD = 0x22ffffff;
    private static final int TEXT_PRIMARY = 0xfff5f8fc;
    private static final int TEXT_SECONDARY = 0xffa4b5cc;
    private static final int TEXT_MUTED = 0xff7b8ca3;
    private static final int TEXT_ON_LIGHT = 0xff0b1017;

    final MainActivity a;
    final String initial;
    PinyinKeyboardModel keyboard;
    EditText input;
    TextView composition, status;
    boolean syncingInput, imeActive;
    int imeConnectionDepth;
    Runnable pendingImeRead;

    private interface ImeEdit {
        boolean run();
    }

    long lastInputClickMs;
    boolean resultPrivateMode;
    TvSearchContext pageContext;
    boolean contextDiscarded;
    final TvSearchPageSlot pageRequests = new TvSearchPageSlot();
    String pageFailureSource = "", pageFailureReason = "";
    final List<Cms.Site> searchSites = new ArrayList<>();
    final Map<String, Integer> sourceScroll = new HashMap<>(), sourceLimits = new HashMap<>();
    final Map<String, Integer> sourceScrollPos = new HashMap<>(),
            sourceScrollOffset = new HashMap<>();
    final Map<String, String> sourceFocus = new HashMap<>();
    Runnable pendingInputClick;
    LinearLayout candidates, keys, resultBody, sourceFilters;
    SearchCoordinator coordinator, retryCoordinator;
    TvSearchBudget.BatchHandoff activeBatchHandoff, activeRetryHandoff;
    List<String> searchVariants = Collections.emptyList();
    int sourceCount, columns = 4;
    Button retrySource;
    boolean closed;
    int pageTicket,
            searchSerial,
            filterSwitchSerial,
            candidatePage,
            finished,
            failed,
            timedOut,
            busy,
            matched;
    long searchMultiSourceRev;
    String activeFilter = "", submitted = "", edited = "";
    TvSearchMatcher.Mode matchMode = TvSearchMatcher.Mode.EXACT;
    String lastLeftFocusTag = "primary";
    TvSearchImeState imeDraft = new TvSearchImeState();
    Runnable pendingSearch, pendingRender;
    java.util.concurrent.Future<?> expansion;
    java.util.concurrent.Future<?> suggestionWork;
    int suggestionSerial;
    String suggestedQuery;
    HorizontalScrollView suggestionScroll;
    LinearLayout titleSuggestions;
    HorizontalScrollView filterScrollView;
    final Map<String, Button> filterButtons = new LinkedHashMap<>();
    final Map<String, GradientDrawable> filterBgs = new HashMap<>();
    final Map<String, String> filterNames = new HashMap<>();
    final Map<String, String> renderedFilterLabels = new HashMap<>();
    final Map<String, Integer> renderedFilterStates = new HashMap<>();
    final Map<TvSearchMatcher.Mode, Button> matchModeButtons = new LinkedHashMap<>();
    final Map<TvSearchMatcher.Mode, GradientDrawable> matchModeBgs = new LinkedHashMap<>();
    final Set<String> displayed = new LinkedHashSet<>();
    final List<TvSearchBudget.ProtectedItem> displayedItems = new ArrayList<>();
    LinearLayout resultGrid, lastRow;
    TextView emptyResult, resultHint;
    TextView tvHeaderTitle, tvHeaderMeta, tvTopHint, tvCollapseBubble;
    TvScrollView tvLeftPanel;
    LinearLayout tvRightPanel;
    LinearLayout tvInputCapsule;
    GradientDrawable tvInputCapsuleBg;
    View tvSearchGlyph;
    Runnable pendingHideCollapseBubble;
    boolean tvLeftCollapsed;
    float tvContentWidthDp;
    float tvFontScale = 1f;
    int tvExpandedLeftWidthDp;
    int tvExpandedSplitGapDp;
    int tvSplitHeightPx;
    int tvRightChromePx;
    int tvCardChromePx;
    int tvCellOuterMarginPx;
    Button moreResults, switchFuzzyBtn, retryAllBtn;
    LinearLayout tvStateContainer, tvRecentContainer, tvFooterRow;
    TvScrollView tvRecentScroll;
    RecyclerView tvResultRecycler;
    GridLayoutManager tvResultLayout;
    TvSearchPosterAdapter tvResultAdapter;
    int shownLimit = 24, renderPasses;
    int searchArtworkScope;
    boolean focusNewResults, restoringResults, cacheDirty, globalBudgetCapped;
    boolean pendingPaginationFocus, deferredRerankPending;
    int pendingPaginationTargetIndex = -1;
    String pendingPaginationAnchorKey = "";
    Set<String> pendingPaginationPrevKeys = Collections.emptySet();
    long lastCacheSnapshotMs, searchStartedMs, totalRenderUiMs, maxRenderUiMs;
    int peakRetainedVideos, peakInFlightImages, searchSourceArrivals;
    ScrollView resultScroll;
    int savedResultScroll;
    int savedRecyclerPos, savedRecyclerOffset;
    long resultTime;
    Cms.Config resultConfig;
    final LinkedHashMap<String, SourceResult> results = new LinkedHashMap<>();
    final Map<String, LinearLayout> posterCards = new HashMap<>();
    final Map<PinyinKeyboardModel.Mode, Button> modeButtons = new LinkedHashMap<>();
    final Map<PinyinKeyboardModel.Mode, GradientDrawable> modeButtonBgs = new LinkedHashMap<>();
    SearchInputServer qrServer;
    int qrGeneration;
    String qrAddress = "";
    AppDialog qrDialog;
    FrameLayout retainedRoot;
    LinearLayout retainedBody;
    int tvLeftInnerWidthPx;
    int tvResultColumnWidthPx;
    int tvCardPosterWidthPx;
    int tvCardPosterHeightPx;

    private static Snapshot cache;

    private static final class Snapshot {
        final TvSearchContext context;
        final String query, filter;
        final TvSearchMatcher.Mode matchMode;
        final long time;
        final List<String> variants;
        final List<Cms.Site> sites;
        final Map<String, SourceResult> results;
        final Map<String, Integer> scroll, limits, scrollPos, scrollOffset;
        final Map<String, String> focus;
        final PinyinKeyboardModel.Snapshot keyboard;
        final TvSearchImeState ime;
        final int candidatePage;

        Snapshot(GlobalSearchScreen screen) {
            context = screen.pageContext;
            query = screen.submitted;
            filter = screen.activeFilter;
            matchMode = screen.matchMode;
            time = screen.resultTime;
            variants = new ArrayList<>(screen.searchVariants);
            sites = new ArrayList<>(screen.searchSites);
            results = new LinkedHashMap<>(screen.results);
            scroll = new HashMap<>(screen.sourceScroll);
            limits = new HashMap<>(screen.sourceLimits);
            scrollPos = new HashMap<>(screen.sourceScrollPos);
            scrollOffset = new HashMap<>(screen.sourceScrollOffset);
            focus = new HashMap<>(screen.sourceFocus);
            keyboard = screen.keyboard == null ? null : screen.keyboard.snapshot();
            ime = screen.imeDraft.copy();
            candidatePage = screen.candidatePage;
        }
    }

    static final class SourceResult {
        final Cms.Site site;
        final List<Cms.Video> videos;
        final SearchCoordinator.Outcome outcome;
        final TvSearchPages pages;

        SourceResult(Cms.Site site, List<Cms.Video> videos, SearchCoordinator.Outcome outcome) {
            this(site, videos, outcome, null);
        }

        SourceResult(
                Cms.Site site,
                List<Cms.Video> videos,
                SearchCoordinator.Outcome outcome,
                TvSearchPages pages) {
            this.site = site;
            this.videos = videos;
            this.outcome = outcome;
            this.pages = pages;
        }
    }

    public GlobalSearchScreen(MainActivity activity, String initialKeyword) {
        a = activity;
        initial = initialKeyword == null ? "" : initialKeyword;
        matchMode = loadPreferredMatchMode();
    }

    /** Responsive column count for Apple TV search poster wall (wider screens 4–5 cols, 720p/1.3x fewer cols). */
    static int computeTvSearchColumns(float rightWidthDp, float fontScale) {
        float scaleFactor = fontScale > 1.15f ? 1.22f : 1f;
        float effective = rightWidthDp / scaleFactor;
        if (effective >= 720f) return 5;
        if (effective >= 520f) return 4;
        if (effective >= 360f) return 3;
        return 2;
    }

    private TvSearchMatcher.Mode loadPreferredMatchMode() {
        if (a == null || a.privateMode || a.prefs == null) {
            return TvSearchMatcher.Mode.EXACT;
        }
        return TvSearchMatcher.Mode.fromPref(
                a.prefs.getString(Prefs.SEARCH_MATCH_MODE, TvSearchMatcher.Mode.EXACT.prefValue));
    }

    private void persistMatchModeIfAllowed(TvSearchMatcher.Mode mode) {
        if (a == null || a.privateMode || a.prefs == null || mode == null) return;
        a.prefs.edit().putString(Prefs.SEARCH_MATCH_MODE, mode.prefValue).apply();
    }

    /** Pre-warms shared pinyin TSV dictionary off the UI thread so first Search open avoids asset I/O. */
    static void prewarmDictionaryAsync(final MainActivity a) {
        if (a == null || a.worker == null || PinyinKeyboardModel.hasWarmSharedDictionary()) return;
        a.worker.execute(
                () -> {
                    try {
                        if (!PinyinKeyboardModel.hasWarmSharedDictionary()) {
                            PinyinKeyboardModel.warmSharedDictionary(
                                    a.getAssets().open("search/pinyin-characters.tsv"));
                        }
                    } catch (Throwable ignored) {
                    }
                });
    }

    boolean handleBackPressed() {
        if (closed) return false;
        if (qrDialog != null && qrDialog.isShowing()) {
            qrDialog.dismiss();
            qrDialog = null;
            return true;
        }
        if (TvQrInputHelper.isActive()) {
            TvQrInputHelper.dismissActive();
            return true;
        }
        if (imeActive && input != null) {
            finishSystemIme(false);
            hideSystemIme();
            input.setCursorVisible(false);
            input.setShowSoftInputOnFocus(false);
            return true;
        }
        return false;
    }

    boolean handleMenuKey(KeyEvent event) {
        if (!current() || !a.isTvDevice() || event == null) return false;
        if (event.getKeyCode() != KeyEvent.KEYCODE_MENU) return false;
        if (MainActivity.isMenuShortPress(
                event.getAction(), event.isCanceled(), event.getFlags())) {
            if (tvLeftCollapsed) {
                expandLeftPanel(true);
            } else if (!submitted.isEmpty()) {
                collapseLeftPanel(true);
                ensureRightPaneFocusAfterCollapse();
            } else if (input != null && input.isShown()) {
                input.requestFocus();
            }
        }
        return true;
    }

    /**
     * Fast TV resume path when returning via BACK from Detail: unhides the retained search tree
     * directly in {@code tvStage} instead of re-inflating keyboard/result views, restoring search
     * mode, source filter, scroll offset, and exact {@code siteKey:vodId} card focus.
     */
    boolean resumeSyncNeeded = false;

    boolean resumeResultsSyncNeeded = false;

    boolean hasUnrenderedResults() {
        if (results.isEmpty()) return false;
        List<TvSearchMatcher.RankedHit> ranked = collectCurrentRankedHits();
        int cap = Math.min(shownLimit, ranked.size());
        for (int i = 0; i < cap; i++) {
            if (!displayed.contains(ranked.get(i).stableKey())) return true;
        }
        return false;
    }

    public void resumeOrShow() {
        if (a.isTvDevice()
                && retainedRoot != null
                && retainedBody != null
                && a.tvStage != null
                && retainedRoot.getParent() == a.tvStage
                && pageContext != null
                && contextMatches()
                && keyboard != null) {
            a.preparePage(false);
            closed = false;
            pageTicket = a.generation;
            a.root = retainedRoot;
            a.body = retainedBody;
            a.scroll = null;
            a.homeDock = null;
            a.homeAmbient = null;
            a.presentRoot(retainedRoot, true);
            a.watchRootLayout(retainedRoot);
            hideCollapseReminderBubble(false);
            updateMatchModeButtons();
            updateResultHeader();
            boolean needCards = resumeResultsSyncNeeded || hasUnrenderedResults();
            boolean needSync = resumeSyncNeeded || needCards;
            resumeSyncNeeded = false;
            resumeResultsSyncNeeded = false;
            if (sourceCount > 0) {
                updateStatus(sourceCount);
            }
            if (needSync) {
                renderFilters();
                if (needCards) {
                    renderResults();
                }
            }
            final String targetTag = resolveResumeFocusTag();
            if (tvResultRecycler != null && tvResultLayout != null) {
                final int pos = savedRecyclerPos;
                final int off = savedRecyclerOffset;
                if (pos >= 0 && tvResultAdapter != null && pos < tvResultAdapter.getItemCount()) {
                    tvResultLayout.scrollToPositionWithOffset(pos, off);
                }
                if (targetTag != null && !targetTag.isEmpty()) {
                    View immediate = retainedRoot.findViewWithTag(targetTag);
                    if (immediate != null && immediate.isShown() && immediate.isFocusable()) {
                        a.tvInitialFocus = immediate;
                    } else {
                        final int serial = searchSerial;
                        tvResultRecycler.post(
                                () -> {
                                    if (!current() || serial != searchSerial) return;
                                    View delayed = retainedRoot.findViewWithTag(targetTag);
                                    if (delayed != null
                                            && delayed.isShown()
                                            && delayed.isFocusable()) {
                                        delayed.requestFocus();
                                    }
                                });
                    }
                }
            } else {
                if (targetTag != null && !targetTag.isEmpty()) {
                    View v = retainedRoot.findViewWithTag(targetTag);
                    if (v != null && v.isShown() && v.isFocusable()) {
                        a.tvInitialFocus = v;
                    }
                }
                if (resultScroll != null && savedResultScroll > 0) {
                    final int restoreScrollY = savedResultScroll;
                    final int serial = searchSerial;
                    resultScroll.post(
                            () -> {
                                if (current() && serial == searchSerial && resultScroll != null) {
                                    resultScroll.scrollTo(0, restoreScrollY);
                                }
                            });
                }
            }
            if (a.tvInitialFocus == null) {
                if (tvLeftCollapsed) {
                    Button tab = filterButtons.get(activeFilter);
                    if (tab == null) tab = filterButtons.get("");
                    if (tab != null && tab.isShown()) {
                        a.tvInitialFocus = tab;
                    }
                } else if (input != null) {
                    a.tvInitialFocus = input;
                }
            }
            return;
        }
        retainedRoot = null;
        retainedBody = null;
        show();
    }

    private String resolveResumeFocusTag() {
        String targetTag = sourceFocus.get(activeFilter);
        if ((targetTag == null || targetTag.isEmpty()) && a.current != null) {
            targetTag = a.current.focus;
        }
        return targetTag;
    }

    public void show() {
        if (pageContext != null && !contextMatches()) discardContext();
        PinyinKeyboardModel.Snapshot restoredKeyboard =
                keyboard == null ? null : keyboard.snapshot();
        int restoredCandidatePage = candidatePage;
        String restored = keyboard == null ? (contextDiscarded ? "" : initial) : keyboard.query();
        if (keyboard == null) {
            matchMode = loadPreferredMatchMode();
        }
        Snapshot saved = cache;
        if (results.isEmpty()
                && saved != null
                && saved.context != null
                && !a.privateMode
                && saved.context.matches(a.config, a.privateMode, a.engineEpoch)
                && System.currentTimeMillis() - saved.time >= 0
                && System.currentTimeMillis() - saved.time < 7200000L
                && (restored.trim().isEmpty() || restored.trim().equals(saved.query))) {
            restored = submitted = saved.query;
            matchMode = saved.matchMode == null ? TvSearchMatcher.Mode.EXACT : saved.matchMode;
            restoredKeyboard = saved.keyboard;
            imeDraft = saved.ime.copy();
            restoredCandidatePage = saved.candidatePage;
            resultConfig = a.config;
            resultPrivateMode = a.privateMode;
            resultTime = saved.time;
            searchVariants = saved.variants;
            results.putAll(saved.results);
            searchSites.addAll(saved.sites);
            sourceCount = searchSites.size();
            activeFilter = saved.filter;
            sourceScroll.putAll(saved.scroll);
            sourceLimits.putAll(saved.limits);
            sourceScrollPos.putAll(saved.scrollPos);
            sourceScrollOffset.putAll(saved.scrollOffset);
            sourceFocus.putAll(saved.focus);
            shownLimit =
                    sourceLimits.containsKey(activeFilter) ? sourceLimits.get(activeFilter) : 24;
            savedResultScroll =
                    sourceScroll.containsKey(activeFilter) ? sourceScroll.get(activeFilter) : 0;
            savedRecyclerPos =
                    sourceScrollPos.containsKey(activeFilter)
                            ? sourceScrollPos.get(activeFilter)
                            : 0;
            savedRecyclerOffset =
                    sourceScrollOffset.containsKey(activeFilter)
                            ? sourceScrollOffset.get(activeFilter)
                            : 0;
            recount();
        }
        boolean searchAgain =
                !submitted.isEmpty() || (!contextDiscarded && !initial.trim().isEmpty());
        boolean reuse =
                !results.isEmpty()
                        && submitted.equals(restored.trim())
                        && resultConfig == a.config
                        && resultPrivateMode == a.privateMode
                        && System.currentTimeMillis() - resultTime >= 0
                        && System.currentTimeMillis() - resultTime < 7200000L;
        if (a.isTvDevice()) {
            a.renderDirectTvPage();
        } else {
            a.renderPage("", "");
        }
        retainedRoot = a.isTvDevice() ? a.root : null;
        retainedBody = a.isTvDevice() ? a.body : null;
        closed = false;
        edited = "";
        syncingInput = false;
        imeActive = false;
        lastInputClickMs = 0L;
        lastLeftFocusTag = "primary";
        if (pendingInputClick != null) {
            a.ui.removeCallbacks(pendingInputClick);
            pendingInputClick = null;
        }
        filterButtons.clear();
        filterBgs.clear();
        filterNames.clear();
        renderedFilterLabels.clear();
        renderedFilterStates.clear();
        matchModeButtons.clear();
        matchModeBgs.clear();
        displayed.clear();
        displayedItems.clear();
        clearCards();
        modeButtons.clear();
        modeButtonBgs.clear();
        globalBudgetCapped = false;
        cacheDirty = false;
        resultGrid = null;
        lastRow = null;
        emptyResult = null;
        moreResults = null;
        switchFuzzyBtn = null;
        retryAllBtn = null;
        tvResultRecycler = null;
        tvResultLayout = null;
        tvResultAdapter = null;
        tvStateContainer = null;
        tvRecentContainer = null;
        tvRecentScroll = null;
        tvFooterRow = null;
        tvHeaderTitle = null;
        tvHeaderMeta = null;
        tvTopHint = null;
        tvLeftPanel = null;
        tvRightPanel = null;
        tvInputCapsule = null;
        tvInputCapsuleBg = null;
        tvSearchGlyph = null;
        hideCollapseReminderBubble(false);
        tvCollapseBubble = null;
        tvLeftCollapsed = false;
        filterScrollView = null;
        pageTicket = a.generation;
        pageContext = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        // Solid opaque BG_PAGE avoids 1920x1080 full-screen GradientDrawable shader overdraw on
        // Mali-450 during RecyclerView scroll frames and matches TvSearchPosterArtView corner
        // masks.
        a.root.setBackgroundColor(BG_PAGE);
        if (!a.isTvDevice()) {
            if (a.root.getChildAt(0) instanceof ImageLoader.Atmosphere) a.root.removeViewAt(0);
        }
        try {
            if (!PinyinKeyboardModel.hasWarmSharedDictionary()) {
                PinyinKeyboardModel.warmSharedDictionary(
                        a.getAssets().open("search/pinyin-characters.tsv"));
            }
            keyboard = PinyinKeyboardModel.fromWarmSharedDictionary();
        } catch (Exception missing) {
            a.paragraph("内置拼音字库无法读取，请重新安装完整版本。");
            return;
        }
        if (restoredKeyboard != null) keyboard.restore(restoredKeyboard);
        else keyboard.set(restored);

        if (a.isTvDevice()) {
            buildTvAppleStyleLayout(reuse, restored, searchAgain, restoredCandidatePage);
        } else {
            buildLegacyLayout(reuse, restored, searchAgain, restoredCandidatePage);
        }
    }

    private void buildTvAppleStyleLayout(
            boolean reuse, String restored, boolean searchAgain, int restoredCandidatePage) {
        android.util.DisplayMetrics dm = a.getResources().getDisplayMetrics();
        float density = Math.max(0.5f, dm.density);
        float scaledDensity = Math.max(density, dm.scaledDensity);
        float fontScale = Math.max(0.85f, a.getResources().getConfiguration().fontScale);
        float windowWidthDp = a.windowWidth() / density;
        float windowHeightDp = a.windowHeight() / density;

        int outerHPadDp = windowWidthDp < 780f ? 18 : 26;
        int outerTopDp = fontScale > 1.15f ? 8 : 10;
        int outerBottomDp = fontScale > 1.15f ? 8 : 10;
        a.body.setPadding(
                a.dp(outerHPadDp), a.dp(outerTopDp), a.dp(outerHPadDp), a.dp(outerBottomDp));
        a.body.setClipChildren(false);
        a.body.setClipToPadding(false);

        // Slim top bar ("搜索" title + private-space tag when active + frosted remote hint pill)
        LinearLayout topBar = a.row();
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        TextView pageTitle = a.text("搜索", 23, TEXT_PRIMARY);
        pageTitle.setTypeface(null, Typeface.BOLD);
        pageTitle.setIncludeFontPadding(false);
        topBar.addView(pageTitle, new LinearLayout.LayoutParams(-2, -2));
        if (a.privateMode) {
            TextView brandSub = a.text(" · 隐私空间", 11.5f, TEXT_MUTED);
            brandSub.setIncludeFontPadding(false);
            LinearLayout.LayoutParams brandLp = new LinearLayout.LayoutParams(-2, -2);
            brandLp.leftMargin = a.dp(8);
            topBar.addView(brandSub, brandLp);
        }
        View spacer = new View(a);
        topBar.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1));
        tvTopHint = a.text("↑↓←→ 移动  ·  确认选择  ·  返回退出", 10.5f, TEXT_SECONDARY);
        tvTopHint.setIncludeFontPadding(false);
        tvTopHint.setSingleLine(true);
        tvTopHint.setPadding(a.dp(10), a.dp(3), a.dp(10), a.dp(3));
        GradientDrawable hintPillBg = new GradientDrawable();
        hintPillBg.setColor(0x14ffffff);
        hintPillBg.setCornerRadius(a.dp(11));
        hintPillBg.setStroke(Math.max(1, a.dp(1)), 0x1affffff);
        tvTopHint.setBackground(hintPillBg);
        topBar.addView(tvTopHint, new LinearLayout.LayoutParams(-2, -2));
        int topBarH = a.dp(fontScale > 1.15f ? 30 : 32);
        int topBarGap = a.dp(fontScale > 1.15f ? 4 : 6);
        LinearLayout.LayoutParams topBarLp = new LinearLayout.LayoutParams(-1, topBarH);
        topBarLp.bottomMargin = topBarGap;
        a.body.addView(topBar, topBarLp);

        float contentWidthDp = Math.max(600f, windowWidthDp - outerHPadDp * 2f);
        int splitHeightPx =
                Math.max(
                        a.dp(300),
                        a.windowHeight() - a.dp(outerTopDp + outerBottomDp) - topBarH - topBarGap);
        int leftWidthDp = Math.max(248, Math.min(302, Math.round(contentWidthDp * 0.315f)));
        int splitGapDp = windowWidthDp < 780f ? 14 : 22;
        float rightWidthDp = Math.max(320f, contentWidthDp - leftWidthDp - splitGapDp);

        tvContentWidthDp = contentWidthDp;
        tvFontScale = fontScale;
        tvExpandedLeftWidthDp = leftWidthDp;
        tvExpandedSplitGapDp = splitGapDp;
        tvSplitHeightPx = splitHeightPx;

        columns = computeTvSearchColumns(rightWidthDp, fontScale);
        int rightWidthPx = a.dp(Math.round(rightWidthDp));
        int cellOuterMarginPx = a.dp(10);
        tvCellOuterMarginPx = cellOuterMarginPx;
        tvResultColumnWidthPx = Math.max(a.dp(92), (rightWidthPx - a.dp(8)) / Math.max(1, columns));

        // Reserve FULL 2 title lines + FULL 1 metadata line + focus-ring & chrome heights using
        // real scaledDensity BEFORE deriving 2:3 poster height so Row 1 metadata is 100% visible
        // in normal and focused states across 1080p, simulated 720p, and 1.3x fontScale.
        int filterBarH = a.dp(fontScale > 1.15f ? 38 : 44);
        int filterBarTop = a.dp(fontScale > 1.15f ? 3 : 4);
        int sugBarH = a.dp(fontScale > 1.15f ? 36 : 42);
        int sugBarBottom = a.dp(fontScale > 1.15f ? 2 : 4);
        int footerBarH = a.dp(fontScale > 1.15f ? 36 : 40);
        int headerLinePx = (int) Math.ceil(21f * scaledDensity * 1.32f);
        int statusLinePx = (int) Math.ceil(12f * scaledDensity * 1.35f) + a.dp(6);
        int rvVertPadPx = a.dp(8) + a.dp(10);
        int rightChromePx =
                headerLinePx
                        + filterBarH
                        + filterBarTop
                        + statusLinePx
                        + sugBarH
                        + sugBarBottom
                        + footerBarH
                        + rvVertPadPx;
        int titleTwoLinesPx = (int) Math.ceil(2f * 13.5f * scaledDensity * 1.32f) + a.dp(6);
        int metaOneLinePx = (int) Math.ceil(11.5f * scaledDensity * 1.45f) + a.dp(6);
        int cardChromePx = a.dp(5 + 10 + 4 + 7 + 3 + 12) + titleTwoLinesPx + metaOneLinePx;
        tvRightChromePx = rightChromePx;
        tvCardChromePx = cardChromePx;
        int maxPosterH = Math.max(a.dp(108), splitHeightPx - rightChromePx - cardChromePx);
        int rawPosterW = Math.max(a.dp(76), tvResultColumnWidthPx - cellOuterMarginPx - a.dp(6));
        int cappedPosterW = Math.max(a.dp(72), Math.round(maxPosterH / 1.5f));
        tvCardPosterWidthPx = Math.min(rawPosterW, cappedPosterW);
        tvCardPosterHeightPx = Math.round(tvCardPosterWidthPx * 1.5f);

        LinearLayout split = a.row();
        split.setGravity(Gravity.TOP);
        split.setClipChildren(false);
        split.setClipToPadding(false);
        a.body.addView(split, new LinearLayout.LayoutParams(-1, splitHeightPx));

        // ---- Left Input Panel (~31.5% width, collapsible frosted glass dock) ----
        int leftPadHDp = 12;
        int leftPadVDp = 10;
        LinearLayout left = a.vertical();
        left.setPadding(a.dp(leftPadHDp), a.dp(leftPadVDp), a.dp(leftPadHDp), a.dp(leftPadVDp));
        left.setClipChildren(false);
        left.setClipToPadding(false);
        GradientDrawable leftCardBg = new GradientDrawable();
        leftCardBg.setColor(BG_PANEL);
        leftCardBg.setCornerRadius(a.dp(22));
        leftCardBg.setStroke(Math.max(1, a.dp(1)), BORDER_PANEL);

        TvScrollView keyboardScroll = new TvScrollView(a);
        keyboardScroll.setFocusFrameEnabled(false);
        keyboardScroll.setTag("search-keyboard-scroll");
        keyboardScroll.setVerticalScrollBarEnabled(false);
        keyboardScroll.setBackground(leftCardBg);
        keyboardScroll.setClipChildren(true);
        keyboardScroll.setClipToPadding(false);
        keyboardScroll.addView(left, new ScrollView.LayoutParams(-1, -2));
        tvLeftPanel = keyboardScroll;
        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(a.dp(leftWidthDp), -1);
        leftLp.rightMargin = a.dp(splitGapDp);
        split.addView(keyboardScroll, leftLp);

        tvLeftInnerWidthPx = Math.max(a.dp(180), a.dp(leftWidthDp - leftPadHDp * 2));

        // 1. Search Input Row: single unified focus capsule [glyph + EditText] + peer QR icon
        int inputRowH = a.dp(fontScale > 1.15f ? 40 : 38);
        int qrBtnPx = inputRowH;
        tvInputCapsuleBg = new GradientDrawable();
        tvInputCapsuleBg.setColor(BG_FIELD);
        tvInputCapsuleBg.setCornerRadius(a.dp(10));
        tvInputCapsuleBg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);

        tvInputCapsule = a.row();
        tvInputCapsule.setTag("search-input-capsule");
        tvInputCapsule.setGravity(Gravity.CENTER_VERTICAL);
        tvInputCapsule.setPadding(a.dp(8), 0, a.dp(8), 0);
        tvInputCapsule.setBackground(tvInputCapsuleBg);

        tvSearchGlyph = buildTvSearchGlyph();
        LinearLayout.LayoutParams glyphLp = new LinearLayout.LayoutParams(a.dp(18), a.dp(18));
        glyphLp.rightMargin = a.dp(6);
        tvInputCapsule.addView(tvSearchGlyph, glyphLp);

        input = createSearchEditText(true);
        tvInputCapsule.addView(input, new LinearLayout.LayoutParams(0, -1, 1f));

        LinearLayout inputRow = a.row();
        inputRow.setGravity(Gravity.CENTER_VERTICAL);
        inputRow.setClipChildren(false);
        inputRow.setClipToPadding(false);
        inputRow.addView(tvInputCapsule, new LinearLayout.LayoutParams(0, inputRowH, 1f));

        View qrIconBtn = buildTvQrIconButton();
        LinearLayout.LayoutParams qrLp = new LinearLayout.LayoutParams(qrBtnPx, inputRowH);
        qrLp.leftMargin = a.dp(6);
        inputRow.addView(qrIconBtn, qrLp);
        left.addView(inputRow, new LinearLayout.LayoutParams(-1, inputRowH));

        a.gap(left, 6);

        // 2. Match Mode Segmented Control: "精准搜索" | "模糊搜索" (Confirm ONLY switches mode!)
        LinearLayout matchSegRow = a.row();
        matchSegRow.setGravity(Gravity.CENTER_VERTICAL);
        matchSegRow.setPadding(a.dp(3), a.dp(3), a.dp(3), a.dp(3));
        matchSegRow.setClipChildren(false);
        matchSegRow.setClipToPadding(false);
        GradientDrawable segTrackBg = new GradientDrawable();
        segTrackBg.setColor(BG_SEGMENT_TRACK);
        segTrackBg.setCornerRadius(a.dp(10));
        segTrackBg.setStroke(Math.max(1, a.dp(1)), 0x20ffffff);
        matchSegRow.setBackground(segTrackBg);
        int segBtnH = a.dp(fontScale > 1.15f ? 32 : 30);
        int segBtnW = Math.max(a.dp(72), (tvLeftInnerWidthPx - a.dp(10)) / 2);
        addMatchModeButton(matchSegRow, TvSearchMatcher.Mode.EXACT, segBtnW, segBtnH);
        addMatchModeButton(matchSegRow, TvSearchMatcher.Mode.FUZZY, segBtnW, segBtnH);
        left.addView(matchSegRow, new LinearLayout.LayoutParams(-1, segBtnH + a.dp(6)));

        // 3. Pinyin Composition Hint + Candidate Row
        composition = a.text("", 10.5f, TEXT_MUTED);
        composition.setSingleLine(true);
        composition.setEllipsize(TextUtils.TruncateAt.END);
        composition.setIncludeFontPadding(false);
        composition.setPadding(a.dp(2), a.dp(3), a.dp(2), a.dp(2));
        left.addView(
                composition, new LinearLayout.LayoutParams(-1, a.dp(fontScale > 1.15f ? 23 : 19)));

        candidates = a.row();
        candidates.setGravity(Gravity.CENTER_VERTICAL);
        candidates.setClipChildren(false);
        candidates.setClipToPadding(false);
        left.addView(candidates, new LinearLayout.LayoutParams(-1, a.dp(29)));

        a.gap(left, 3);

        // 4. Compact Keyboard Type Row (Visually distinct from Exact/Fuzzy match mode!)
        LinearLayout kbdModeRow = a.row();
        kbdModeRow.setGravity(Gravity.CENTER_VERTICAL);
        kbdModeRow.setClipChildren(false);
        kbdModeRow.setClipToPadding(false);
        TextView kbdLabel = a.text("键盘", 10.5f, TEXT_MUTED);
        kbdLabel.setIncludeFontPadding(false);
        kbdLabel.setSingleLine(true);
        int kbdLabelW = a.dp(fontScale > 1.15f ? 34 : 28);
        kbdModeRow.addView(kbdLabel, new LinearLayout.LayoutParams(kbdLabelW, -2));
        int tvThirdKeyW = Math.max(a.dp(44), (tvLeftInnerWidthPx - kbdLabelW - a.dp(12)) / 3);
        modeButton(kbdModeRow, "拼音", PinyinKeyboardModel.Mode.PINYIN, tvThirdKeyW);
        modeButton(kbdModeRow, "字母", PinyinKeyboardModel.Mode.LETTERS, tvThirdKeyW);
        modeButton(kbdModeRow, "123", PinyinKeyboardModel.Mode.NUMBERS, tvThirdKeyW);
        left.addView(kbdModeRow, new LinearLayout.LayoutParams(-1, a.dp(29)));

        a.gap(left, 3);

        // 5. 6-Column On-screen Remote Keyboard
        keys = a.vertical();
        keys.setClipChildren(false);
        keys.setClipToPadding(false);
        left.addView(keys);

        a.gap(left, 5);

        // 6. Bottom Command Row: [空格 | 退格 | 清空 | 搜索] (Fits 100% cleanly on 720p, 1080p, 1.3x)
        LinearLayout cmdRow = a.row();
        cmdRow.setGravity(Gravity.CENTER_VERTICAL);
        cmdRow.setClipChildren(false);
        cmdRow.setClipToPadding(false);
        int cmdBtnW = Math.max(a.dp(42), (tvLeftInnerWidthPx - a.dp(16)) / 4);
        int cmdBtnH = a.dp(fontScale > 1.15f ? 34 : 32);
        addTvCommandButton(
                cmdRow,
                "空格",
                "search-space",
                false,
                cmdBtnW,
                cmdBtnH,
                () -> {
                    keyboard.space();
                    changed();
                });
        addTvCommandButton(
                cmdRow,
                "退格",
                "search-delete",
                false,
                cmdBtnW,
                cmdBtnH,
                () -> {
                    keyboard.backspace();
                    changed();
                });
        addTvCommandButton(
                cmdRow,
                "清空",
                "search-clear",
                false,
                cmdBtnW,
                cmdBtnH,
                () -> {
                    keyboard.clear();
                    changed();
                });
        addTvCommandButton(cmdRow, "搜索", "search-submit", true, cmdBtnW, cmdBtnH, () -> submit());
        left.addView(cmdRow, new LinearLayout.LayoutParams(-1, cmdBtnH + a.dp(4)));

        // ---- Right Content Area (~68.5% width; expands to 100% when left sidebar collapses) ----
        LinearLayout right = a.vertical();
        right.setClipChildren(false);
        right.setClipToPadding(false);
        tvRightPanel = right;
        split.addView(right, new LinearLayout.LayoutParams(rightWidthPx, -1));

        // Right Header: Apple TV bold section title + glass pill mode & count badge
        LinearLayout rightHeader = a.row();
        rightHeader.setGravity(Gravity.CENTER_VERTICAL);
        tvHeaderTitle = a.text("探索与搜索", 21, TEXT_PRIMARY);
        tvHeaderTitle.setTypeface(null, Typeface.BOLD);
        tvHeaderTitle.setSingleLine(true);
        tvHeaderTitle.setEllipsize(TextUtils.TruncateAt.END);
        tvHeaderTitle.setIncludeFontPadding(false);
        rightHeader.addView(tvHeaderTitle, new LinearLayout.LayoutParams(0, -2, 1));

        tvHeaderMeta = a.text("", 11.5f, TEXT_SECONDARY);
        tvHeaderMeta.setSingleLine(true);
        tvHeaderMeta.setIncludeFontPadding(false);
        tvHeaderMeta.setPadding(a.dp(11), a.dp(4), a.dp(11), a.dp(4));
        GradientDrawable metaPillBg = new GradientDrawable();
        metaPillBg.setColor(0x18ffffff);
        metaPillBg.setCornerRadius(a.dp(12));
        metaPillBg.setStroke(Math.max(1, a.dp(1)), 0x20ffffff);
        tvHeaderMeta.setBackground(metaPillBg);
        LinearLayout.LayoutParams metaLp = new LinearLayout.LayoutParams(-2, -2);
        metaLp.leftMargin = a.dp(10);
        rightHeader.addView(tvHeaderMeta, metaLp);
        right.addView(rightHeader, new LinearLayout.LayoutParams(-1, -2));

        // Horizontal Source Filter Pills
        filterScrollView = new HorizontalScrollView(a);
        filterScrollView.setTag("search-source-scroll");
        filterScrollView.setHorizontalScrollBarEnabled(false);
        filterScrollView.setClipChildren(false);
        filterScrollView.setClipToPadding(false);
        sourceFilters = a.row();
        sourceFilters.setGravity(Gravity.CENTER_VERTICAL);
        sourceFilters.setClipChildren(false);
        sourceFilters.setClipToPadding(false);
        sourceFilters.setPadding(a.dp(2), a.dp(4), a.dp(8), a.dp(4));
        filterScrollView.addView(sourceFilters);
        filterScrollView.setVisibility(View.GONE);
        LinearLayout.LayoutParams filterScrollLp = new LinearLayout.LayoutParams(-1, filterBarH);
        filterScrollLp.topMargin = filterBarTop;
        right.addView(filterScrollView, filterScrollLp);

        // Status line
        status = a.text("默认精准匹配完整片名 · 可随时切到模糊搜索", 12, TEXT_MUTED);
        status.setSingleLine(true);
        status.setEllipsize(TextUtils.TruncateAt.END);
        status.setIncludeFontPadding(false);
        LinearLayout.LayoutParams statusLp = new LinearLayout.LayoutParams(-1, -2);
        statusLp.topMargin = a.dp(2);
        statusLp.bottomMargin = a.dp(3);
        right.addView(status, statusLp);

        // Title Suggestions (public mode only, honors acceptsTitleSuggestions)
        suggestionScroll = new HorizontalScrollView(a);
        suggestionScroll.setTag("search-title-suggestions");
        suggestionScroll.setHorizontalScrollBarEnabled(false);
        suggestionScroll.setClipChildren(false);
        suggestionScroll.setClipToPadding(false);
        titleSuggestions = a.row();
        titleSuggestions.setGravity(Gravity.CENTER_VERTICAL);
        titleSuggestions.setClipChildren(false);
        titleSuggestions.setClipToPadding(false);
        titleSuggestions.setPadding(a.dp(2), a.dp(3), a.dp(8), a.dp(3));
        suggestionScroll.addView(titleSuggestions);
        suggestionScroll.setVisibility(View.GONE);
        LinearLayout.LayoutParams sugLp = new LinearLayout.LayoutParams(-1, sugBarH);
        sugLp.bottomMargin = sugBarBottom;
        right.addView(suggestionScroll, sugLp);

        // Result Body container (also referenced by IME suspension/resume slice!)
        resultBody = a.vertical();
        resultBody.setClipChildren(false);
        resultBody.setClipToPadding(false);
        right.addView(resultBody, new LinearLayout.LayoutParams(-1, 0, 1));

        // 1) Recent Searches + Trending Recommendations Scroll Container (empty query state)
        tvRecentScroll = new TvScrollView(a);
        tvRecentScroll.setFocusFrameEnabled(false);
        tvRecentScroll.setTag("tv-search-discover-scroll");
        tvRecentScroll.setVerticalScrollBarEnabled(false);
        tvRecentScroll.setClipChildren(true);
        tvRecentScroll.setClipToPadding(false);
        tvRecentContainer = a.vertical();
        tvRecentContainer.setClipChildren(false);
        tvRecentContainer.setClipToPadding(false);
        tvRecentContainer.setPadding(a.dp(2), a.dp(6), a.dp(4), a.dp(10));
        tvRecentScroll.addView(tvRecentContainer, new ScrollView.LayoutParams(-1, -2));
        resultBody.addView(tvRecentScroll, new LinearLayout.LayoutParams(-1, 0, 1));

        // 2) State Container (searching / zero-exact with Switch-to-Fuzzy / all-fail / per-source
        // error)
        tvStateContainer = a.vertical();
        tvStateContainer.setClipChildren(false);
        tvStateContainer.setClipToPadding(false);
        tvStateContainer.setPadding(a.dp(16), a.dp(18), a.dp(16), a.dp(18));
        GradientDrawable stateCardBg = new GradientDrawable();
        stateCardBg.setColor(BG_PANEL);
        stateCardBg.setCornerRadius(a.dp(14));
        stateCardBg.setStroke(Math.max(1, a.dp(1)), BORDER_PANEL);
        tvStateContainer.setBackground(stateCardBg);
        emptyResult = a.text("", 14, TEXT_SECONDARY);
        emptyResult.setLineSpacing(a.dp(4), 1f);
        tvStateContainer.addView(emptyResult, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout stateActions = a.row();
        stateActions.setGravity(Gravity.CENTER_VERTICAL);
        stateActions.setClipChildren(false);
        stateActions.setClipToPadding(false);
        LinearLayout.LayoutParams stateActLp = new LinearLayout.LayoutParams(-1, -2);
        stateActLp.topMargin = a.dp(14);
        tvStateContainer.addView(stateActions, stateActLp);

        switchFuzzyBtn =
                makeTvActionPill(
                        "切换到模糊搜索",
                        "search-switch-fuzzy",
                        true,
                        () -> setMatchMode(TvSearchMatcher.Mode.FUZZY, true));
        switchFuzzyBtn.setVisibility(View.GONE);
        LinearLayout.LayoutParams sfLp = new LinearLayout.LayoutParams(-2, a.dp(38));
        sfLp.rightMargin = a.dp(10);
        stateActions.addView(switchFuzzyBtn, sfLp);

        retryAllBtn =
                makeTvActionPill(
                        "重试全部来源",
                        "search-retry-all",
                        true,
                        () -> submitInternal(false, activeFilter, true));
        retryAllBtn.setVisibility(View.GONE);
        LinearLayout.LayoutParams raLp = new LinearLayout.LayoutParams(-2, a.dp(38));
        raLp.rightMargin = a.dp(10);
        stateActions.addView(retryAllBtn, raLp);

        retrySource = makeTvActionPill("重新搜索此源", "search-retry-source", false, this::retrySelected);
        retrySource.setVisibility(View.GONE);
        stateActions.addView(retrySource, new LinearLayout.LayoutParams(-2, a.dp(38)));

        tvStateContainer.setVisibility(View.GONE);
        LinearLayout.LayoutParams stateWrapLp = new LinearLayout.LayoutParams(-1, -2);
        stateWrapLp.topMargin = a.dp(8);
        resultBody.addView(tvStateContainer, stateWrapLp);

        // 3) RecyclerView 2:3 Poster Wall (DiffUtil incremental updates, zero flash, zero focus
        // steal)
        tvResultRecycler = new RecyclerView(a);
        tvResultRecycler.setTag("tv-search-results-wall");
        tvResultRecycler.setHasFixedSize(true);
        tvResultRecycler.setItemViewCacheSize(8);
        tvResultRecycler.setClipToPadding(true);
        tvResultRecycler.setClipChildren(true);
        tvResultRecycler.setItemAnimator(null);
        tvResultRecycler.setOverScrollMode(View.OVER_SCROLL_NEVER);
        tvResultRecycler.setPadding(a.dp(8), a.dp(8), a.dp(8), a.dp(10));
        tvResultLayout = new GridLayoutManager(a, columns);
        tvResultLayout.setSpanSizeLookup(
                new GridLayoutManager.SpanSizeLookup() {
                    @Override
                    public int getSpanSize(int position) {
                        return 1;
                    }
                });
        tvResultRecycler.setLayoutManager(tvResultLayout);
        tvResultAdapter = new TvSearchPosterAdapter();
        tvResultRecycler.setAdapter(tvResultAdapter);
        tvResultRecycler.setVisibility(View.GONE);
        resultBody.addView(tvResultRecycler, new LinearLayout.LayoutParams(-1, 0, 1));

        // 4) Compact Footer Bar (Load more / pagination / cap hint)
        tvFooterRow = a.row();
        tvFooterRow.setGravity(Gravity.CENTER_VERTICAL);
        tvFooterRow.setClipChildren(false);
        tvFooterRow.setClipToPadding(false);
        tvFooterRow.setPadding(a.dp(8), a.dp(4), a.dp(8), a.dp(2));
        moreResults =
                makeTvActionPill(
                        "读取来源更多结果", "search-more-results", false, () -> triggerMoreResults());
        moreResults.setVisibility(View.GONE);
        LinearLayout.LayoutParams mrLp =
                new LinearLayout.LayoutParams(-2, a.dp(fontScale > 1.15f ? 32 : 36));
        mrLp.rightMargin = a.dp(12);
        tvFooterRow.addView(moreResults, mrLp);

        resultHint = a.text("", 11.5f, TEXT_MUTED);
        resultHint.setSingleLine(true);
        resultHint.setEllipsize(TextUtils.TruncateAt.END);
        resultHint.setVisibility(View.GONE);
        tvFooterRow.addView(resultHint, new LinearLayout.LayoutParams(0, -2, 1));
        tvFooterRow.setVisibility(View.GONE);
        resultBody.addView(tvFooterRow, new LinearLayout.LayoutParams(-1, -2));

        resultScroll = null;

        if (!a.privateMode) {
            HotTitleCatalog.ensureLoadedAsync(
                    a,
                    () -> {
                        if (current() && !a.privateMode) {
                            suggestedQuery = null;
                            updateTitleSuggestions();
                        }
                    });
            TvCuratedHome.loadAsync(
                    a,
                    catalog -> {
                        if (current()
                                && !a.privateMode
                                && catalog != null
                                && catalog.live
                                && submitted.isEmpty()
                                && tvRecentContainer != null
                                && tvRecentContainer.getVisibility() == View.VISIBLE
                                && focusedTag(tvRecentContainer) == null) {
                            showTvHistory();
                        }
                    });
        }
        rebuildKeys();
        updateMatchModeButtons();
        updateResultHeader();
        if (reuse) {
            edited = TvSearchMatcher.isBlankQuery(restored) ? "" : restored.trim();
            changed();
            restoringResults = true;
            renderFilters();
            renderResults();
            status.setText("已恢复上次" + matchMode.label + "结果 · " + matched + " 个来源有结果");
        } else {
            changed();
            showHistory();
            if (searchAgain && !TvSearchMatcher.isBlankQuery(restored)) submit();
        }
        if (restoredCandidatePage != 0) {
            candidatePage = restoredCandidatePage;
            renderCandidates();
        }
        if (tvLeftCollapsed) {
            Button tab = filterButtons.get(activeFilter);
            if (tab == null) tab = filterButtons.get("");
            a.tvInitialFocus = (tab != null && tab.isShown()) ? tab : input;
        } else {
            a.tvInitialFocus = input;
        }
    }

    private void buildLegacyLayout(
            boolean reuse, String restored, boolean searchAgain, int restoredCandidatePage) {
        a.body.setPadding(a.dp(32), a.dp(14), a.dp(32), a.dp(16));
        LinearLayout split = a.row();
        split.setGravity(Gravity.TOP);
        int height =
                Math.max(
                        260,
                        Math.round(a.windowHeight() / a.getResources().getDisplayMetrics().density)
                                - 30);
        a.body.addView(split, new LinearLayout.LayoutParams(-1, a.dp(height)));
        LinearLayout left = a.vertical();
        left.setPadding(a.dp(4), a.dp(6), a.dp(30), a.dp(10));
        TvScrollView keyboardScroll = new TvScrollView(a);
        keyboardScroll.setFocusFrameEnabled(false);
        keyboardScroll.setTag("search-keyboard-scroll");
        keyboardScroll.setVerticalScrollBarEnabled(false);
        keyboardScroll.setClipChildren(false);
        keyboardScroll.setClipToPadding(false);
        keyboardScroll.addView(left, new ScrollView.LayoutParams(-1, -2));
        split.addView(keyboardScroll, new LinearLayout.LayoutParams(a.dp(294), -1));
        tvLeftInnerWidthPx = Math.max(a.dp(180), a.dp(294 - 34));
        float availableWidth = a.windowWidth() / a.getResources().getDisplayMetrics().density - 358;
        columns = TvLayoutPolicy.searchColumns(availableWidth);
        int rightInnerPx = Math.max(a.dp(240), a.windowWidth() - a.dp(358 + 12));
        tvResultColumnWidthPx =
                Math.max(a.dp(92), (rightInnerPx - columns * a.dp(11)) / Math.max(1, columns));
        LinearLayout headingRow = a.row();
        headingRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView heading = a.text("搜索所有片源", 22, MainActivity.WHITE);
        heading.setTypeface(null, Typeface.BOLD);
        heading.setSingleLine(true);
        headingRow.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
        Button qrBtn = a.navButton("扫码输入", "search-qr-button", () -> showQrDialog(false));
        qrBtn.setTextSize(12);
        qrBtn.setMinHeight(a.dp(30));
        qrBtn.setMinimumHeight(a.dp(30));
        qrBtn.setPadding(a.dp(10), a.dp(3), a.dp(10), a.dp(3));
        headingRow.addView(qrBtn, new LinearLayout.LayoutParams(-2, a.dp(30)));
        left.addView(headingRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(left, 12);
        input = createSearchEditText(false);
        left.addView(input, new LinearLayout.LayoutParams(-1, a.dp(46)));
        a.gap(left, 6);
        LinearLayout matchSegRow = a.row();
        addMatchModeButton(matchSegRow, TvSearchMatcher.Mode.EXACT, 0, a.dp(34));
        addMatchModeButton(matchSegRow, TvSearchMatcher.Mode.FUZZY, 0, a.dp(34));
        left.addView(matchSegRow, new LinearLayout.LayoutParams(-1, a.dp(38)));
        composition = a.text("", 12, MainActivity.MUTED);
        composition.setSingleLine(true);
        composition.setPadding(a.dp(2), a.dp(5), 0, 0);
        left.addView(composition, new LinearLayout.LayoutParams(-1, a.dp(25)));
        candidates = a.row();
        left.addView(candidates, new LinearLayout.LayoutParams(-1, a.dp(34)));
        LinearLayout modes = a.row();
        left.addView(modes, new LinearLayout.LayoutParams(-1, a.dp(38)));
        modeButton(modes, "拼音", PinyinKeyboardModel.Mode.PINYIN, 0);
        modeButton(modes, "字母", PinyinKeyboardModel.Mode.LETTERS, 0);
        modeButton(modes, "数字", PinyinKeyboardModel.Mode.NUMBERS, 0);
        keys = a.vertical();
        left.addView(keys);
        a.gap(left, 5);
        LinearLayout editing = a.row();
        left.addView(editing);
        keyButtonFixedWidth(
                editing,
                "空格",
                "search-space",
                () -> {
                    keyboard.space();
                    changed();
                },
                1,
                0);
        keyButtonFixedWidth(
                editing,
                "删除",
                "search-delete",
                () -> {
                    keyboard.backspace();
                    changed();
                },
                1,
                0);
        keyButtonFixedWidth(
                editing,
                "清空",
                "search-clear",
                () -> {
                    keyboard.clear();
                    changed();
                },
                1,
                0);
        Button submit = a.button("立即搜索", "search-submit", () -> submit());
        submit.setTextSize(15);
        submit.setMinHeight(a.dp(40));
        submit.setMinimumHeight(a.dp(40));
        submit.setPadding(a.dp(8), a.dp(5), a.dp(8), a.dp(5));
        LinearLayout.LayoutParams submitSize = new LinearLayout.LayoutParams(-1, a.dp(42));
        submitSize.topMargin = a.dp(8);
        left.addView(submit, submitSize);
        LinearLayout right = a.vertical();
        split.addView(right, new LinearLayout.LayoutParams(0, -1, 1));
        status = a.text("默认精准搜索 · 输入停顿片刻自动更新结果。", 14, MainActivity.MUTED);
        status.setMinHeight(a.dp(30));
        right.addView(status);
        HorizontalScrollView filterScroll = new HorizontalScrollView(a);
        filterScroll.setTag("search-source-scroll");
        filterScroll.setHorizontalScrollBarEnabled(false);
        filterScroll.setClipChildren(false);
        filterScroll.setClipToPadding(false);
        sourceFilters = a.row();
        sourceFilters.setClipChildren(false);
        sourceFilters.setClipToPadding(false);
        sourceFilters.setPadding(a.dp(4), a.dp(5), a.dp(4), a.dp(5));
        filterScroll.addView(sourceFilters);
        right.addView(filterScroll, new LinearLayout.LayoutParams(-1, a.dp(46)));
        resultScroll = new TvScrollView(a);
        resultScroll.setTag("global-search-results");
        resultScroll.setClipToPadding(false);
        resultBody = a.vertical();
        resultBody.setPadding(a.dp(6), a.dp(12), a.dp(6), a.dp(28));
        resultScroll.addView(resultBody);
        right.addView(resultScroll, new LinearLayout.LayoutParams(-1, 0, 1));
        rebuildKeys();
        updateMatchModeButtons();
        if (reuse) {
            edited = restored.trim();
            changed();
            resetGrid();
            restoringResults = true;
            renderFilters();
            renderResults();
            status.setText("已恢复上次结果 · " + matched + " 个来源有结果，可点立即搜索刷新");
        } else {
            changed();
            showHistory();
            if (searchAgain && !restored.trim().isEmpty()) submit();
        }
        if (restoredCandidatePage != 0) {
            candidatePage = restoredCandidatePage;
            renderCandidates();
        }
    }

    private EditText createSearchEditText(boolean tvStyle) {
        EditText field =
                new EditText(a) {
                    @Override
                    public android.view.inputmethod.InputConnection onCreateInputConnection(
                            android.view.inputmethod.EditorInfo info) {
                        android.view.inputmethod.InputConnection base =
                                super.onCreateInputConnection(info);
                        if (base == null) return null;
                        final EditText owner = this;
                        return new android.view.inputmethod.InputConnectionWrapper(base, false) {
                            private boolean edit(ImeEdit change) {
                                if (!current() || !imeActive || input != owner) return false;
                                imeConnectionDepth++;
                                try {
                                    return change.run();
                                } finally {
                                    imeConnectionDepth--;
                                    captureImeUpdate();
                                }
                            }

                            @Override
                            public boolean setComposingText(CharSequence text, int cursor) {
                                return edit(() -> super.setComposingText(text, cursor));
                            }

                            @Override
                            public boolean setComposingRegion(int start, int end) {
                                return edit(() -> super.setComposingRegion(start, end));
                            }

                            @Override
                            public boolean commitText(CharSequence text, int cursor) {
                                return edit(() -> super.commitText(text, cursor));
                            }

                            @Override
                            public boolean finishComposingText() {
                                return edit(() -> super.finishComposingText());
                            }

                            @Override
                            public boolean setSelection(int start, int end) {
                                return edit(() -> super.setSelection(start, end));
                            }

                            @Override
                            public boolean deleteSurroundingText(int before, int after) {
                                return edit(() -> super.deleteSurroundingText(before, after));
                            }
                        };
                    }

                    @Override
                    public boolean onKeyPreIme(int keyCode, KeyEvent event) {
                        if (keyCode == KeyEvent.KEYCODE_BACK && imeActive) {
                            if (event.getAction() == KeyEvent.ACTION_UP && !event.isCanceled()) {
                                finishSystemIme(false);
                                hideSystemIme();
                                setCursorVisible(false);
                                setShowSoftInputOnFocus(false);
                            }
                            return true;
                        }
                        return super.onKeyPreIme(keyCode, event);
                    }

                    @Override
                    public boolean onKeyDown(int keyCode, KeyEvent event) {
                        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                                || keyCode == KeyEvent.KEYCODE_ENTER
                                || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER) {
                            if (event.getRepeatCount() == 0) {
                                FocusMotion.key(a, this, keyCode, event);
                                performClick();
                            }
                            return true;
                        }
                        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                                || keyCode == KeyEvent.KEYCODE_DPAD_UP
                                || (!imeActive
                                        && (keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                                                || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT))) {
                            return false;
                        }
                        return super.onKeyDown(keyCode, event);
                    }

                    @Override
                    public boolean onKeyUp(int keyCode, KeyEvent event) {
                        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                                || keyCode == KeyEvent.KEYCODE_ENTER
                                || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER) {
                            FocusMotion.key(a, this, keyCode, event);
                            return true;
                        }
                        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                                || keyCode == KeyEvent.KEYCODE_DPAD_UP
                                || (!imeActive
                                        && (keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                                                || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT))) {
                            return false;
                        }
                        return super.onKeyUp(keyCode, event);
                    }
                };
        field.setTextSize(tvStyle ? 14.5f : 18);
        field.setTextColor(TEXT_PRIMARY);
        field.setHintTextColor(TEXT_MUTED);
        field.setHint(tvStyle ? "输入片名 · 双击输入法" : "输入片名…（双击调出输入法）");
        field.setGravity(Gravity.CENTER_VERTICAL);
        field.setIncludeFontPadding(false);
        field.setTag("primary");
        field.setContentDescription("搜索内容");
        field.setSingleLine(true);
        field.setInputType(android.text.InputType.TYPE_CLASS_TEXT);
        field.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH);
        field.setShowSoftInputOnFocus(false);
        field.setCursorVisible(false);
        field.setEllipsize(tvStyle ? TextUtils.TruncateAt.END : TextUtils.TruncateAt.START);
        field.setPadding(
                tvStyle ? a.dp(2) : a.dp(12),
                tvStyle ? 0 : a.dp(6),
                tvStyle ? a.dp(2) : a.dp(10),
                tvStyle ? 0 : a.dp(6));
        field.setBackground(tvStyle ? null : a.bg(0xff29292e, 10));
        UiCompat.setDefaultFocusHighlightEnabled(field, false);
        field.setFocusable(true);
        field.setFocusableInTouchMode(true);
        field.setClickable(true);
        field.setOnFocusChangeListener(
                (v, f) -> {
                    if (f) lastLeftFocusTag = "primary";
                    if (!f && imeActive) {
                        finishSystemIme(false);
                        field.setCursorVisible(false);
                        field.setShowSoftInputOnFocus(false);
                        hideSystemIme();
                    }
                    if (tvStyle) {
                        if (tvInputCapsuleBg != null) {
                            tvInputCapsuleBg.setColor(f ? BG_FIELD_FOCUS : BG_FIELD);
                            tvInputCapsuleBg.setStroke(
                                    f ? Math.max(2, a.dp(2)) : Math.max(1, a.dp(1)),
                                    f ? Color.WHITE : 0x26ffffff);
                        }
                        if (tvSearchGlyph != null) tvSearchGlyph.invalidate();
                    } else {
                        FocusMotion.style(
                                a,
                                field,
                                f,
                                0xff29292e,
                                0xff35353e,
                                10,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.01f);
                    }
                });
        field.setOnClickListener(v -> handleInputClick());
        field.setOnEditorActionListener(
                (v, actionId, event) -> {
                    finishSystemIme(true);
                    hideSystemIme();
                    submit();
                    return true;
                });
        field.addTextChangedListener(
                new android.text.TextWatcher() {
                    @Override
                    public void beforeTextChanged(
                            CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {}

                    @Override
                    public void afterTextChanged(android.text.Editable s) {
                        if (!current() || syncingInput || keyboard == null) return;
                        syncSearchInputEllipsize();
                        if (imeActive) {
                            if (imeConnectionDepth == 0) {
                                if (pendingImeRead != null) a.ui.removeCallbacks(pendingImeRead);
                                pendingImeRead =
                                        () -> {
                                            pendingImeRead = null;
                                            captureImeUpdate();
                                        };
                                a.ui.post(pendingImeRead);
                            }
                            return;
                        } else {
                            imeDraft.clear();
                            keyboard.set(s == null ? "" : s.toString());
                        }
                        updateAfterImeInput();
                    }
                });
        field.setOnKeyListener((v, key, event) -> physicalKey(key, event));
        return field;
    }

    private void addMatchModeButton(
            LinearLayout row, final TvSearchMatcher.Mode mode, int fixedW, int heightPx) {
        final String tag = "search-match:" + mode.name();
        final Button b = new Button(a);
        b.setText(mode.label);
        b.setTag(tag);
        b.setContentDescription(mode.label);
        b.setAllCaps(false);
        b.setGravity(Gravity.CENTER);
        b.setIncludeFontPadding(false);
        b.setStateListAnimator(null);
        b.setOutlineProvider(null);
        b.setSingleLine(true);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setTextSize(12.5f);
        b.setPadding(a.dp(6), 0, a.dp(6), 0);
        if (android.os.Build.VERSION.SDK_INT >= 23) {
            b.setBreakStrategy(android.text.Layout.BREAK_STRATEGY_SIMPLE);
            b.setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE);
        }
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(a.dp(8));
        b.setBackground(bg);
        UiCompat.setDefaultFocusHighlightEnabled(b, false);
        b.setFocusable(true);
        b.setFocusableInTouchMode(true);
        b.setClickable(true);
        // CRITICAL: Focus movement NEVER switches match mode; ONLY confirm/click switches mode!
        b.setOnClickListener(
                v -> {
                    if (!current()) return;
                    setMatchMode(mode, false);
                });
        b.setOnFocusChangeListener(
                (v, focused) -> {
                    if (focused) lastLeftFocusTag = tag;
                    styleMatchModeButton(b, mode, focused);
                });
        b.setOnKeyListener(
                (v, keyCode, event) -> {
                    if (a.isTvDevice()
                            && mode == TvSearchMatcher.Mode.FUZZY
                            && keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                            && event.getAction() == KeyEvent.ACTION_DOWN) {
                        return focusRightFromLeft();
                    }
                    return physicalKey(keyCode, event);
                });
        LinearLayout.LayoutParams lp =
                fixedW > 0
                        ? new LinearLayout.LayoutParams(fixedW, heightPx)
                        : new LinearLayout.LayoutParams(0, heightPx, 1);
        lp.setMargins(a.dp(1), 0, a.dp(1), 0);
        row.addView(b, lp);
        matchModeButtons.put(mode, b);
        matchModeBgs.put(mode, bg);
        styleMatchModeButton(b, mode, false);
    }

    private void styleMatchModeButton(Button b, TvSearchMatcher.Mode mode, boolean focused) {
        if (b == null) return;
        boolean selected = mode == matchMode;
        b.setSelected(selected);
        b.setTypeface(null, (selected || focused) ? Typeface.BOLD : Typeface.NORMAL);
        GradientDrawable bg = matchModeBgs.get(mode);
        if (bg != null) {
            if (focused && selected) {
                bg.setColor(Color.WHITE);
                bg.setStroke(Math.max(2, a.dp(2.5f)), 0xff5fa8ff);
            } else if (focused) {
                bg.setColor(0xff273244);
                bg.setStroke(Math.max(2, a.dp(2.5f)), Color.WHITE);
            } else if (selected) {
                bg.setColor(BG_PILL_SELECTED);
                bg.setStroke(0, Color.TRANSPARENT);
            } else {
                bg.setColor(Color.TRANSPARENT);
                bg.setStroke(0, Color.TRANSPARENT);
            }
        }
        if (focused && selected) {
            b.setTextColor(TEXT_ON_LIGHT);
        } else if (focused) {
            b.setTextColor(Color.WHITE);
        } else if (selected) {
            b.setTextColor(TEXT_ON_LIGHT);
        } else {
            b.setTextColor(TEXT_SECONDARY);
        }
    }

    void updateMatchModeButtons() {
        for (Map.Entry<TvSearchMatcher.Mode, Button> e : matchModeButtons.entrySet()) {
            styleMatchModeButton(e.getValue(), e.getKey(), e.getValue().hasFocus());
        }
    }

    void setMatchMode(TvSearchMatcher.Mode targetMode, boolean autoFocusResults) {
        if (!current() || targetMode == null) return;
        if (targetMode == matchMode) {
            updateMatchModeButtons();
            return;
        }
        matchMode = targetMode;
        persistMatchModeIfAllowed(matchMode);
        updateMatchModeButtons();
        updateResultHeader();
        String query = keyboard == null ? "" : keyboard.query().trim();
        if (query.isEmpty()) {
            if (status != null) {
                status.setText(
                        matchMode == TvSearchMatcher.Mode.EXACT
                                ? "已切到精准搜索 · 仅保留完整片名或明确别名匹配"
                                : "已切到模糊搜索 · 支持前缀、包含与拼音首字母匹配");
            }
            return;
        }
        // Preserve active source filter if still valid, and re-run with new mode & fresh serial so
        // late callbacks from the superseded mode are strictly rejected.
        String preservedFilter = isValidActiveFilter(activeFilter) ? activeFilter : "";
        submitInternal(false, preservedFilter, autoFocusResults);
    }

    private boolean isValidActiveFilter(String key) {
        if (key == null || key.isEmpty()) return false;
        for (Cms.Site s : searchSites) {
            if (s != null && key.equals(s.key) && a.isSiteEnabledInMultiSource(key)) return true;
        }
        return false;
    }

    private Button makeTvActionPill(
            String label, final String tag, final boolean primary, final Runnable action) {
        final Button b = new Button(a);
        b.setText(label);
        b.setTag(tag);
        b.setContentDescription(label);
        b.setAllCaps(false);
        b.setGravity(Gravity.CENTER);
        b.setIncludeFontPadding(false);
        b.setStateListAnimator(null);
        b.setOutlineProvider(null);
        b.setSingleLine(true);
        b.setMinWidth(a.dp(92));
        b.setMinimumWidth(a.dp(92));
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setTextSize(13);
        b.setTypeface(null, Typeface.BOLD);
        b.setPadding(a.dp(16), 0, a.dp(16), 0);
        final GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(a.dp(10));
        bg.setColor(primary ? BG_PILL_SELECTED : BG_FILTER);
        bg.setStroke(Math.max(1, a.dp(1)), primary ? 0x00000000 : 0x33ffffff);
        b.setBackground(bg);
        b.setTextColor(primary ? TEXT_ON_LIGHT : TEXT_PRIMARY);
        UiCompat.setDefaultFocusHighlightEnabled(b, false);
        b.setFocusable(true);
        b.setFocusableInTouchMode(true);
        b.setClickable(true);
        b.setOnClickListener(
                v -> {
                    if (current()) action.run();
                });
        b.setOnFocusChangeListener(
                (v, focused) -> {
                    if (focused) {
                        bg.setColor(Color.WHITE);
                        bg.setStroke(Math.max(2, a.dp(2.5f)), primary ? 0xff5fa8ff : Color.WHITE);
                        b.setTextColor(TEXT_ON_LIGHT);
                    } else {
                        bg.setColor(primary ? BG_PILL_SELECTED : BG_FILTER);
                        bg.setStroke(Math.max(1, a.dp(1)), primary ? 0x00000000 : 0x33ffffff);
                        b.setTextColor(primary ? TEXT_ON_LIGHT : TEXT_PRIMARY);
                    }
                });
        b.setOnKeyListener(
                (v, keyCode, event) -> {
                    if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                            && event.getAction() == KeyEvent.ACTION_DOWN) {
                        if (b == switchFuzzyBtn
                                || (b == retryAllBtn
                                        && (switchFuzzyBtn == null
                                                || switchFuzzyBtn.getVisibility() != View.VISIBLE))
                                || b == retrySource
                                || b == moreResults) {
                            return restoreLeftFocus();
                        }
                    }
                    if (keyCode == KeyEvent.KEYCODE_DPAD_UP
                            && event.getAction() == KeyEvent.ACTION_DOWN
                            && b == moreResults
                            && tvResultRecycler != null
                            && tvResultRecycler.getVisibility() == View.VISIBLE
                            && tvResultAdapter != null
                            && tvResultAdapter.getItemCount() > 0) {
                        focusCardAt(tvResultAdapter.getItemCount() - 1);
                        return true;
                    }
                    return false;
                });
        return b;
    }

    private void addTvCommandButton(
            LinearLayout row,
            String label,
            final String tag,
            final boolean accent,
            int fixedW,
            int heightPx,
            final Runnable action) {
        final Button b = new Button(a);
        b.setText(label);
        b.setTag(tag);
        b.setContentDescription(label);
        b.setAllCaps(false);
        b.setGravity(Gravity.CENTER);
        b.setIncludeFontPadding(false);
        b.setStateListAnimator(null);
        b.setOutlineProvider(null);
        b.setSingleLine(true);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setTextSize(12.5f);
        b.setTypeface(null, accent ? Typeface.BOLD : Typeface.NORMAL);
        b.setPadding(a.dp(2), 0, a.dp(2), 0);
        if (android.os.Build.VERSION.SDK_INT >= 23) {
            b.setBreakStrategy(android.text.Layout.BREAK_STRATEGY_SIMPLE);
            b.setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE);
        }
        final GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(a.dp(8));
        bg.setColor(accent ? BG_PILL_SELECTED : BG_KEY);
        bg.setStroke(0, Color.TRANSPARENT);
        b.setBackground(bg);
        b.setTextColor(accent ? TEXT_ON_LIGHT : TEXT_PRIMARY);
        UiCompat.setDefaultFocusHighlightEnabled(b, false);
        b.setFocusable(true);
        b.setFocusableInTouchMode(true);
        b.setClickable(true);
        b.setOnClickListener(
                v -> {
                    if (!current()) return;
                    if ("search-clear".equals(tag)) imeDraft.clear();
                    if (imeDraft.composing()) {
                        a.toast("输入法文字尚未确认，请双击输入框继续或取消");
                        return;
                    }
                    action.run();
                });
        b.setOnFocusChangeListener(
                (v, focus) -> {
                    if (focus) lastLeftFocusTag = tag;
                    if (focus) {
                        bg.setColor(Color.WHITE);
                        bg.setStroke(Math.max(2, a.dp(2.5f)), accent ? 0xff5fa8ff : Color.WHITE);
                        b.setTextColor(TEXT_ON_LIGHT);
                    } else {
                        bg.setColor(accent ? BG_PILL_SELECTED : BG_KEY);
                        bg.setStroke(0, Color.TRANSPARENT);
                        b.setTextColor(accent ? TEXT_ON_LIGHT : TEXT_PRIMARY);
                    }
                });
        b.setOnKeyListener(
                (v, keyCode, event) -> {
                    if (accent
                            && keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                            && event.getAction() == KeyEvent.ACTION_DOWN) {
                        return focusRightFromLeft();
                    }
                    return physicalKey(keyCode, event);
                });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(fixedW, heightPx);
        lp.setMargins(a.dp(2), a.dp(2), a.dp(2), a.dp(2));
        row.addView(b, lp);
    }

    static boolean shouldAutoCollapseLeftPanelOnSubmit(
            boolean tvDevice, boolean remember, boolean focusFirstOnResult, boolean hasQuery) {
        return tvDevice && hasQuery && (remember || focusFirstOnResult);
    }

    private void syncSearchInputEllipsize() {
        if (!a.isTvDevice() || input == null) return;
        android.text.Editable text = input.getText();
        TextUtils.TruncateAt desired =
                (text == null || text.length() == 0)
                        ? TextUtils.TruncateAt.END
                        : TextUtils.TruncateAt.START;
        if (input.getEllipsize() != desired) {
            input.setEllipsize(desired);
        }
    }

    private void recomputeTvPosterWallMetrics(float activeRightWidthDp) {
        if (!a.isTvDevice() || activeRightWidthDp <= 0f || tvSplitHeightPx <= 0) return;
        int nextColumns = computeTvSearchColumns(activeRightWidthDp, tvFontScale);
        int rightWidthPx = a.dp(Math.round(activeRightWidthDp));
        tvResultColumnWidthPx =
                Math.max(a.dp(92), (rightWidthPx - a.dp(8)) / Math.max(1, nextColumns));
        int maxPosterH = Math.max(a.dp(108), tvSplitHeightPx - tvRightChromePx - tvCardChromePx);
        int rawPosterW = Math.max(a.dp(76), tvResultColumnWidthPx - tvCellOuterMarginPx - a.dp(6));
        int cappedPosterW = Math.max(a.dp(72), Math.round(maxPosterH / 1.5f));
        int nextPosterW = Math.min(rawPosterW, cappedPosterW);
        int nextPosterH = Math.round(nextPosterW * 1.5f);
        boolean spanChanged = nextColumns != columns;
        boolean sizeChanged =
                nextPosterW != tvCardPosterWidthPx || nextPosterH != tvCardPosterHeightPx;
        columns = nextColumns;
        tvCardPosterWidthPx = nextPosterW;
        tvCardPosterHeightPx = nextPosterH;
        if (tvResultLayout != null && spanChanged) {
            tvResultLayout.setSpanCount(columns);
        }
        if (tvResultAdapter != null && (spanChanged || sizeChanged)) {
            tvResultAdapter.refreshThemeAndSizes(tvResultRecycler);
        }
    }

    private static boolean isFocusInside(ViewGroup group, View focus) {
        if (group == null || focus == null) return false;
        ViewParent p = focus == group ? group : focus.getParent();
        if (focus == group) return true;
        while (p != null) {
            if (p == group) return true;
            p = p.getParent();
        }
        return false;
    }

    private void collapseLeftPanel(boolean showBubbleHint) {
        if (!a.isTvDevice() || tvLeftPanel == null || tvRightPanel == null) return;
        if (tvLeftCollapsed) {
            if (showBubbleHint) showCollapseReminderBubble();
            return;
        }
        View currentFocus = a.getCurrentFocus();
        if (currentFocus != null
                && currentFocus.getTag() instanceof String
                && isFocusInside(tvLeftPanel, currentFocus)) {
            lastLeftFocusTag = (String) currentFocus.getTag();
        }
        if (imeActive && input != null) {
            finishSystemIme(false);
            hideSystemIme();
            input.setCursorVisible(false);
            input.setShowSoftInputOnFocus(false);
        }
        TvQrInputHelper.dismissActive();
        tvLeftCollapsed = true;
        tvLeftPanel.animate().cancel();
        tvLeftPanel.setVisibility(View.GONE);
        ViewGroup.LayoutParams rlp = tvRightPanel.getLayoutParams();
        if (rlp != null && tvContentWidthDp > 0f) {
            rlp.width = a.dp(Math.round(tvContentWidthDp));
            tvRightPanel.setLayoutParams(rlp);
        }
        recomputeTvPosterWallMetrics(tvContentWidthDp);
        if (tvTopHint != null) {
            tvTopHint.setText("一直按左键 / 菜单键拉起搜索  ·  确认选择  ·  返回退出");
        }
        if (showBubbleHint) showCollapseReminderBubble();
    }

    private void expandLeftPanel(boolean restoreFocus) {
        hideCollapseReminderBubble(false);
        if (!a.isTvDevice() || tvLeftPanel == null || tvRightPanel == null) return;
        if (tvLeftCollapsed) {
            tvLeftCollapsed = false;
            tvLeftPanel.animate().cancel();
            tvLeftPanel.setVisibility(View.VISIBLE);
            float rightWidthDp =
                    Math.max(320f, tvContentWidthDp - tvExpandedLeftWidthDp - tvExpandedSplitGapDp);
            ViewGroup.LayoutParams rlp = tvRightPanel.getLayoutParams();
            if (rlp != null) {
                rlp.width = a.dp(Math.round(rightWidthDp));
                tvRightPanel.setLayoutParams(rlp);
            }
            recomputeTvPosterWallMetrics(rightWidthDp);
            if (tvTopHint != null) {
                tvTopHint.setText("↑↓←→ 移动  ·  确认选择  ·  返回退出");
            }
            if (!a.reduced) {
                tvLeftPanel.setAlpha(0f);
                tvLeftPanel.setTranslationX(-a.dp(24));
                tvLeftPanel.animate().alpha(1f).translationX(0f).setDuration(160L).start();
            } else {
                tvLeftPanel.setAlpha(1f);
                tvLeftPanel.setTranslationX(0f);
            }
        }
        if (restoreFocus) {
            focusLeftPanelTarget();
            final TvScrollView panel = tvLeftPanel;
            panel.post(
                    () -> {
                        if (current()
                                && !tvLeftCollapsed
                                && panel == tvLeftPanel
                                && !isFocusInside(panel, a.getCurrentFocus())) {
                            focusLeftPanelTarget();
                        }
                    });
        }
    }

    private void ensureRightPaneFocusAfterCollapse() {
        if (!current()) return;
        if (focusSelectedResultsInternal()) return;
        Button tab = filterButtons.get(activeFilter);
        if (tab == null) tab = filterButtons.get("");
        if (tab != null && tab.isShown()) {
            tab.requestFocus();
        }
    }

    private void showCollapseReminderBubble() {
        if (!current() || !a.isTvDevice() || a.root == null) return;
        if (tvCollapseBubble == null) {
            TextView bubble = a.text("‹  已收起搜索框 · 一直按左键或按菜单键拉起", 13f, TEXT_PRIMARY);
            bubble.setTag("search-collapse-bubble");
            bubble.setTypeface(null, Typeface.BOLD);
            bubble.setSingleLine(true);
            bubble.setEllipsize(TextUtils.TruncateAt.END);
            bubble.setIncludeFontPadding(false);
            bubble.setFocusable(false);
            bubble.setClickable(false);
            if (android.os.Build.VERSION.SDK_INT >= 16) {
                bubble.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            }
            bubble.setPadding(a.dp(15), a.dp(8), a.dp(16), a.dp(8));
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(0xeb162030);
            bg.setCornerRadius(a.dp(18));
            bg.setStroke(Math.max(1, a.dp(1.2f)), 0xaa7dd3fc);
            bubble.setBackground(bg);
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                bubble.setElevation(a.dp(8));
            }
            FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(-2, -2);
            lp.gravity = Gravity.BOTTOM | Gravity.START;
            lp.leftMargin = a.dp(26);
            lp.rightMargin = a.dp(26);
            lp.bottomMargin = a.dp(46);
            a.root.addView(bubble, lp);
            tvCollapseBubble = bubble;
        }
        if (pendingHideCollapseBubble != null) {
            a.ui.removeCallbacks(pendingHideCollapseBubble);
            pendingHideCollapseBubble = null;
        }
        tvCollapseBubble.animate().cancel();
        tvCollapseBubble.setVisibility(View.VISIBLE);
        tvCollapseBubble.bringToFront();
        if (a.reduced) {
            tvCollapseBubble.setAlpha(1f);
            tvCollapseBubble.setTranslationY(0f);
        } else {
            tvCollapseBubble.setAlpha(0f);
            tvCollapseBubble.setTranslationY(a.dp(8));
            tvCollapseBubble.animate().alpha(1f).translationY(0f).setDuration(180L).start();
        }
        pendingHideCollapseBubble =
                () -> {
                    pendingHideCollapseBubble = null;
                    hideCollapseReminderBubble(!a.reduced);
                };
        a.ui.postDelayed(pendingHideCollapseBubble, 4200L);
    }

    private void hideCollapseReminderBubble(boolean animate) {
        if (pendingHideCollapseBubble != null && a.ui != null) {
            a.ui.removeCallbacks(pendingHideCollapseBubble);
            pendingHideCollapseBubble = null;
        }
        final TextView bubble = tvCollapseBubble;
        if (bubble == null || bubble.getVisibility() != View.VISIBLE) return;
        bubble.animate().cancel();
        if (animate && !a.reduced) {
            bubble.animate()
                    .alpha(0f)
                    .translationY(a.dp(6))
                    .setDuration(180L)
                    .withEndAction(() -> bubble.setVisibility(View.GONE))
                    .start();
        } else {
            bubble.setAlpha(0f);
            bubble.setVisibility(View.GONE);
        }
    }

    private boolean focusRightFromLeft() {
        if (!current()) return false;
        if (submitted.isEmpty()) {
            if (tvRecentContainer != null && tvRecentContainer.getVisibility() == View.VISIBLE) {
                View preferred = findFirstDiscoverCard(tvRecentContainer);
                if (preferred == null) preferred = findFirstFocusable(tvRecentContainer);
                if (preferred != null) {
                    preferred.requestFocus();
                    return true;
                }
            }
            return false;
        }
        // Prefer remembered poster card, then first visible card, then active filter, then state
        // CTA.
        if (focusSelectedResultsInternal()) {
            collapseLeftPanel(true);
            return true;
        }
        Button tab = filterButtons.get(activeFilter);
        if (tab != null && tab.isShown()) {
            tab.requestFocus();
            collapseLeftPanel(true);
            return true;
        }
        return false;
    }

    private static View findFirstDiscoverCard(View root) {
        if (root == null || root.getVisibility() != View.VISIBLE) return null;
        if (root.isFocusable() && root.getTag() instanceof String) {
            String t = (String) root.getTag();
            if (t.startsWith("search-history:") || t.startsWith("search-hot:")) {
                return root;
            }
        }
        if (root instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) root;
            for (int i = 0; i < g.getChildCount(); i++) {
                View found = findFirstDiscoverCard(g.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }

    private boolean focusLeftPanelTarget() {
        if (!current() || a.root == null) return false;
        if (lastLeftFocusTag != null && !lastLeftFocusTag.isEmpty()) {
            View v = a.root.findViewWithTag(lastLeftFocusTag);
            if (v != null && v.isShown() && v.isFocusable()) {
                v.requestFocus();
                return true;
            }
        }
        if (input != null && input.isShown()) {
            input.requestFocus();
            return true;
        }
        return false;
    }

    private boolean restoreLeftFocus() {
        if (!current() || a.root == null) return false;
        if (a.isTvDevice() && tvLeftCollapsed) {
            expandLeftPanel(true);
            return true;
        }
        return focusLeftPanelTarget();
    }

    private static View findFirstFocusable(View root) {
        if (root == null || root.getVisibility() != View.VISIBLE) return null;
        if (root.isFocusable()) return root;
        if (root instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) root;
            for (int i = 0; i < g.getChildCount(); i++) {
                View found = findFirstFocusable(g.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }

    boolean contextMatches() {
        return pageContext != null
                && pageContext.matches(a.config, a.privateMode, a.engineEpoch)
                && (searchMultiSourceRev == 0L || searchMultiSourceRev == a.multiSourceRevision());
    }

    boolean current() {
        return !closed
                && !a.isFinishing()
                && !a.switchingPrivacy
                && pageTicket == a.generation
                && contextMatches();
    }

    static void trimMemory(int level) {
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW
                || level >= android.content.ComponentCallbacks2.TRIM_MEMORY_BACKGROUND) {
            cache = null;
        }
    }

    static void invalidateContext(MainActivity activity) {
        TvSearchContext.revokeAll();
        cache = null;
        activity.ui.removeCallbacks(activity.learnPendingTitles);
        activity.pendingTitles.clear();
        if (activity.searchScreen != null) activity.searchScreen.discardContext();
    }

    private void deferPendingPhoneticLearn() {
        if (a.isTvDevice() && a.ui != null && !a.pendingTitles.isEmpty()) {
            a.ui.removeCallbacks(a.learnPendingTitles);
            a.ui.postDelayed(a.learnPendingTitles, 3000L);
        }
    }

    private void learnSearchTitlesDeferred(List<Cms.Video> videos) {
        if (videos == null || videos.isEmpty()) return;
        a.learnTitles(videos);
        deferPendingPhoneticLearn();
    }

    private void discardContext() {
        close();
        retainedRoot = null;
        retainedBody = null;
        tvCollapseBubble = null;
        tvLeftCollapsed = false;
        contextDiscarded = true;
        submitted = edited = activeFilter = "";
        matchMode = loadPreferredMatchMode();
        keyboard = null;
        imeDraft.clear();
        if (input != null) input.setText("");
        if (composition != null) composition.setText("");
        if (tvResultAdapter != null) tvResultAdapter.clearAll();
        if (resultBody != null && !a.isTvDevice()) resultBody.removeAllViews();
        if (sourceFilters != null) sourceFilters.removeAllViews();
        results.clear();
        searchSites.clear();
        searchVariants = Collections.emptyList();
        sourceScroll.clear();
        sourceLimits.clear();
        sourceScrollPos.clear();
        sourceScrollOffset.clear();
        sourceFocus.clear();
        filterButtons.clear();
        filterBgs.clear();
        filterNames.clear();
        renderedFilterLabels.clear();
        renderedFilterStates.clear();
        globalBudgetCapped = false;
        cacheDirty = false;
        shownLimit = 24;
        savedResultScroll = 0;
        savedRecyclerPos = 0;
        savedRecyclerOffset = 0;
    }

    private void cacheResults() {
        if (contextMatches() && !a.privateMode && !submitted.isEmpty() && !results.isEmpty()) {
            cache = new Snapshot(this);
            cacheDirty = false;
            lastCacheSnapshotMs = android.os.SystemClock.elapsedRealtime();
        }
    }

    private void maybeCacheResults(boolean force) {
        if (!contextMatches() || a.privateMode || submitted.isEmpty() || results.isEmpty()) return;
        long now = android.os.SystemClock.elapsedRealtime();
        if (force
                || (cacheDirty
                        && (lastCacheSnapshotMs == 0L || now - lastCacheSnapshotMs >= 1500L))) {
            cacheResults();
        }
    }

    int retainedVideoCount() {
        int count = 0;
        for (SourceResult r : results.values()) {
            if (r != null && r.videos != null) count += r.videos.size();
        }
        return count;
    }

    private void recount() {
        finished = results.size();
        failed = timedOut = busy = matched = 0;
        for (SourceResult result : results.values()) {
            if (result.outcome == SearchCoordinator.Outcome.RESULT
                    && result.videos != null
                    && !result.videos.isEmpty()) matched++;
            if (result.outcome == SearchCoordinator.Outcome.FAILED) failed++;
            if (result.outcome == SearchCoordinator.Outcome.TIMEOUT) timedOut++;
            if (result.outcome == SearchCoordinator.Outcome.BUSY) busy++;
        }
    }

    void modeButton(LinearLayout row, String title, PinyinKeyboardModel.Mode mode) {
        modeButton(row, title, mode, 0);
    }

    void modeButton(LinearLayout row, String title, PinyinKeyboardModel.Mode mode, int fixedW) {
        final String tag = "search-mode:" + mode.name();
        if (a.isTvDevice()) {
            final Button b = new Button(a);
            b.setText(title);
            b.setTag(tag);
            b.setContentDescription("键盘类型 " + title);
            b.setAllCaps(false);
            b.setGravity(Gravity.CENTER);
            b.setIncludeFontPadding(false);
            b.setStateListAnimator(null);
            b.setOutlineProvider(null);
            b.setSingleLine(true);
            b.setMinWidth(0);
            b.setMinimumWidth(0);
            b.setMinHeight(0);
            b.setMinimumHeight(0);
            b.setTextSize(11.5f);
            b.setPadding(a.dp(4), 0, a.dp(4), 0);
            GradientDrawable bg = new GradientDrawable();
            bg.setCornerRadius(a.dp(7));
            b.setBackground(bg);
            UiCompat.setDefaultFocusHighlightEnabled(b, false);
            b.setFocusable(true);
            b.setFocusableInTouchMode(true);
            b.setOnClickListener(
                    v -> {
                        if (!current()) return;
                        if (imeDraft.composing()) {
                            a.toast("输入法文字尚未确认，请双击输入框继续或取消");
                            return;
                        }
                        keyboard.mode(mode);
                        candidatePage = 0;
                        rebuildKeys();
                        changed();
                    });
            b.setOnFocusChangeListener(
                    (v, focused) -> {
                        if (focused) lastLeftFocusTag = tag;
                        styleKeyboardModeButton(b, mode, focused);
                    });
            b.setOnKeyListener(
                    (v, keyCode, event) -> {
                        if (mode == PinyinKeyboardModel.Mode.NUMBERS
                                && keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                                && event.getAction() == KeyEvent.ACTION_DOWN) {
                            return focusRightFromLeft();
                        }
                        return physicalKey(keyCode, event);
                    });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(fixedW, a.dp(25));
            lp.setMargins(a.dp(2), a.dp(1), a.dp(2), a.dp(1));
            row.addView(b, lp);
            modeButtons.put(mode, b);
            modeButtonBgs.put(mode, bg);
            styleKeyboardModeButton(b, mode, false);
            return;
        }
        Button b =
                keyButtonFixedWidth(
                        row,
                        title,
                        tag,
                        () -> {
                            keyboard.mode(mode);
                            candidatePage = 0;
                            rebuildKeys();
                            changed();
                        },
                        1,
                        fixedW);
        modeButtons.put(mode, b);
    }

    private void styleKeyboardModeButton(Button b, PinyinKeyboardModel.Mode mode, boolean focused) {
        if (b == null || keyboard == null) return;
        boolean selected = keyboard.mode() == mode;
        b.setSelected(selected);
        b.setTypeface(null, selected || focused ? Typeface.BOLD : Typeface.NORMAL);
        GradientDrawable bg = modeButtonBgs.get(mode);
        if (bg != null) {
            if (focused) {
                bg.setColor(Color.WHITE);
                bg.setStroke(Math.max(1, a.dp(2)), Color.WHITE);
            } else if (selected) {
                bg.setColor(BG_KEY_SELECTED);
                bg.setStroke(Math.max(1, a.dp(1)), 0x558ab4e8);
            } else {
                bg.setColor(0x16ffffff);
                bg.setStroke(0, Color.TRANSPARENT);
            }
        }
        b.setTextColor(focused ? TEXT_ON_LIGHT : (selected ? TEXT_PRIMARY : TEXT_MUTED));
    }

    Button keyButton(LinearLayout row, String label, String tag, Runnable action, float weight) {
        return keyButtonFixedWidth(row, label, tag, action, weight, 0);
    }

    Button keyButtonFixedWidth(
            LinearLayout row, String label, String tag, Runnable action, float weight, int fixedW) {
        return keyButtonFixedWidth(row, label, tag, action, weight, fixedW, false);
    }

    Button keyButtonFixedWidth(
            LinearLayout row,
            String label,
            final String tag,
            final Runnable action,
            float weight,
            int fixedW,
            final boolean rightEdgeToContent) {
        final Button b;
        if (a.isTvDevice()) {
            b = new Button(a);
            b.setText(label);
            b.setTag(tag);
            b.setAllCaps(false);
            b.setGravity(Gravity.CENTER);
            b.setIncludeFontPadding(false);
            b.setStateListAnimator(null);
            b.setOutlineProvider(null);
            b.setSingleLine(true);
            b.setMinWidth(0);
            b.setMinimumWidth(0);
            b.setMinHeight(0);
            b.setMinimumHeight(0);
            b.setTextSize(13.5f);
            b.setTextColor(TEXT_PRIMARY);
            b.setPadding(a.dp(2), 0, a.dp(2), 0);
            if (android.os.Build.VERSION.SDK_INT >= 23) {
                b.setBreakStrategy(android.text.Layout.BREAK_STRATEGY_SIMPLE);
                b.setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE);
            }
            final GradientDrawable keyBg = new GradientDrawable();
            keyBg.setColor(BG_KEY);
            keyBg.setCornerRadius(a.dp(9));
            b.setBackground(keyBg);
            UiCompat.setDefaultFocusHighlightEnabled(b, false);
            b.setFocusable(true);
            b.setFocusableInTouchMode(true);
            b.setOnClickListener(
                    v -> {
                        if (!current()) return;
                        if ("search-clear".equals(tag)) imeDraft.clear();
                        if (imeDraft.composing()) {
                            a.toast("输入法文字尚未确认，请双击输入框继续或取消");
                            return;
                        }
                        action.run();
                    });
            b.setOnFocusChangeListener(
                    (v, focus) -> {
                        if (focus) lastLeftFocusTag = tag;
                        keyBg.setColor(focus ? Color.WHITE : BG_KEY);
                        keyBg.setStroke(
                                focus ? Math.max(1, a.dp(2)) : 0,
                                focus ? Color.WHITE : Color.TRANSPARENT);
                        b.setTextColor(focus ? TEXT_ON_LIGHT : TEXT_PRIMARY);
                    });
            b.setOnKeyListener(
                    (v, key, event) -> {
                        if (rightEdgeToContent
                                && key == KeyEvent.KEYCODE_DPAD_RIGHT
                                && event.getAction() == KeyEvent.ACTION_DOWN) {
                            return focusRightFromLeft();
                        }
                        return physicalKey(key, event);
                    });
        } else {
            b =
                    a.button(
                            label,
                            tag,
                            () -> {
                                if (!current()) return;
                                if ("search-clear".equals(tag)) imeDraft.clear();
                                if (imeDraft.composing()) {
                                    a.toast("输入法文字尚未确认，请双击输入框继续或取消");
                                    return;
                                }
                                action.run();
                            });
            b.setMinWidth(0);
            b.setMinimumWidth(0);
            b.setMinHeight(0);
            b.setMinimumHeight(0);
            b.setTextSize(14);
            b.setPadding(a.dp(2), 0, a.dp(2), 0);
            b.setBackground(a.bg(0xff29292e, 7));
            b.setOnFocusChangeListener(
                    (v, focus) -> {
                        FocusMotion.style(
                                a,
                                b,
                                focus,
                                0xff29292e,
                                MainActivity.WHITE,
                                7,
                                MainActivity.WHITE,
                                MainActivity.DARK,
                                false,
                                1.08f);
                    });
            b.setOnKeyListener((v, key, event) -> physicalKey(key, event));
        }
        int keyHeightPx = a.isTvDevice() ? a.dp(29) : a.dp(28);
        LinearLayout.LayoutParams size =
                (fixedW > 0)
                        ? new LinearLayout.LayoutParams(fixedW, keyHeightPx)
                        : new LinearLayout.LayoutParams(0, keyHeightPx, weight);
        size.setMargins(a.dp(2), a.dp(1.5f), a.dp(2), a.dp(1.5f));
        row.addView(b, size);
        return b;
    }

    void rebuildKeys() {
        keys.removeAllViews();
        String characters =
                keyboard.mode() == PinyinKeyboardModel.Mode.NUMBERS
                        ? "1234567890-_:.,!?@#&/"
                        : keyboard.mode() == PinyinKeyboardModel.Mode.LETTERS
                                ? "abcdefghijklmnopqrstuvwxyz"
                                : "abcdefghijklmnopqrstuvwxyz'";
        int fixedKeyW =
                (a.isTvDevice() && tvLeftInnerWidthPx > 0)
                        ? Math.max(a.dp(28), (tvLeftInnerWidthPx - a.dp(4) * 6) / 6)
                        : 0;
        for (int start = 0; start < characters.length(); start += 6) {
            LinearLayout row = a.row();
            row.setClipChildren(false);
            row.setClipToPadding(false);
            keys.addView(row);
            int rowEnd = Math.min(characters.length(), start + 6);
            for (int column = 0; column < 6; column++) {
                int index = start + column;
                if (index >= characters.length()) {
                    LinearLayout.LayoutParams blankLp =
                            fixedKeyW > 0
                                    ? new LinearLayout.LayoutParams(fixedKeyW, a.dp(29))
                                    : new LinearLayout.LayoutParams(0, a.dp(29), 1);
                    if (fixedKeyW > 0) blankLp.setMargins(a.dp(2), a.dp(1.5f), a.dp(2), a.dp(1.5f));
                    row.addView(new View(a), blankLp);
                    continue;
                }
                final String letter = characters.substring(index, index + 1);
                boolean isRightmostInRow = (index == rowEnd - 1);
                keyButtonFixedWidth(
                        row,
                        letter.toUpperCase(Locale.ROOT),
                        "search-key:" + letter,
                        () -> {
                            keyboard.input(letter);
                            changed();
                        },
                        1,
                        fixedKeyW,
                        a.isTvDevice() && isRightmostInRow);
            }
        }
        for (Map.Entry<PinyinKeyboardModel.Mode, Button> entry : modeButtons.entrySet()) {
            if (a.isTvDevice()) {
                entry.getValue().setText(modeLabel(entry.getKey()));
                styleKeyboardModeButton(
                        entry.getValue(), entry.getKey(), entry.getValue().hasFocus());
            } else {
                entry.getValue()
                        .setText(
                                (entry.getKey() == keyboard.mode() ? "● " : "")
                                        + modeLabel(entry.getKey()));
            }
        }
    }

    String modeLabel(PinyinKeyboardModel.Mode mode) {
        return mode == PinyinKeyboardModel.Mode.PINYIN
                ? "拼音"
                : mode == PinyinKeyboardModel.Mode.LETTERS ? "字母" : (a.isTvDevice() ? "123" : "数字");
    }

    void handleInputClick() {
        if (!current()) return;
        long now = android.os.SystemClock.uptimeMillis();
        if (TvV17SearchInput.isDoubleClick(lastInputClickMs, now)) {
            lastInputClickMs = 0L;
            if (pendingInputClick != null) {
                a.ui.removeCallbacks(pendingInputClick);
                pendingInputClick = null;
            }
            openSystemIme();
            return;
        }
        lastInputClickMs = now;
        if (pendingInputClick != null) a.ui.removeCallbacks(pendingInputClick);
        pendingInputClick =
                () -> {
                    pendingInputClick = null;
                    if (!current() || imeActive || !input.hasFocus()) return;
                    View first = a.root.findViewWithTag("search-key:a");
                    if (first != null) first.requestFocus();
                };
        a.ui.postDelayed(pendingInputClick, TvV17SearchInput.DOUBLE_CLICK_MS + 1);
    }

    static int safeSelectionIndex(int requested, int textLength) {
        if (textLength <= 0) return 0;
        return Math.max(0, Math.min(textLength, requested));
    }

    static int computeEffectiveSearchThreads(
            int requestedThreads, boolean tvDevice, boolean lowRamTv) {
        int clamped = Math.max(2, Math.min(8, requestedThreads));
        if (tvDevice && lowRamTv) {
            return Math.min(clamped, 3);
        }
        return clamped;
    }

    static boolean isLowRamMemoryClass(boolean lowRamFlag, int memoryClassMb, long maxHeapBytes) {
        if (lowRamFlag) return true;
        if (memoryClassMb > 0 && memoryClassMb <= 256) return true;
        return maxHeapBytes > 0L && maxHeapBytes <= 256L * 1024L * 1024L;
    }

    private boolean isLowRamTv() {
        boolean lowRamFlag = false;
        int memClassMb = 0;
        try {
            android.app.ActivityManager am =
                    (android.app.ActivityManager)
                            a.getSystemService(android.content.Context.ACTIVITY_SERVICE);
            if (am != null) {
                lowRamFlag = am.isLowRamDevice();
                memClassMb = am.getMemoryClass();
            }
        } catch (Throwable ignored) {
        }
        return isLowRamMemoryClass(lowRamFlag, memClassMb, Runtime.getRuntime().maxMemory());
    }

    void openSystemIme() {
        if (!current() || input == null || keyboard == null) return;
        imeActive = true;
        imeDraft.open(keyboard);
        syncingInput = true;
        String currentText = imeDraft.text == null ? "" : imeDraft.text;
        android.text.Editable existingText = input.getText();
        if (!currentText.equals(existingText == null ? "" : existingText.toString())) {
            input.setText(currentText);
        }
        int actualLen = input.getText() == null ? 0 : input.getText().length();
        try {
            input.setSelection(safeSelectionIndex(imeDraft.selection, actualLen));
        } catch (Exception ignored) {
        }
        if (imeDraft.composing() && imeDraft.start >= 0 && imeDraft.end <= actualLen) {
            try {
                android.view.inputmethod.InputConnection connection =
                        input.onCreateInputConnection(new android.view.inputmethod.EditorInfo());
                if (connection != null) {
                    connection.setComposingRegion(imeDraft.start, imeDraft.end);
                }
            } catch (Exception ignored) {
            }
        }
        syncingInput = false;
        input.setShowSoftInputOnFocus(true);
        input.setCursorVisible(true);
        input.requestFocus();
        try {
            a.getWindow()
                    .setSoftInputMode(
                            WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE
                                    | WindowManager.LayoutParams.SOFT_INPUT_ADJUST_PAN);
        } catch (Exception ignored) {
        }
        android.view.inputmethod.InputMethodManager imm =
                (android.view.inputmethod.InputMethodManager)
                        a.getSystemService(android.content.Context.INPUT_METHOD_SERVICE);
        if (imm != null) {
            if (!imm.showSoftInput(
                    input, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)) {
                imm.showSoftInput(input, android.view.inputmethod.InputMethodManager.SHOW_FORCED);
            }
        }
        if (composition != null) composition.setText("已调出电视输入法 · 可直接输入中文或拼音");
    }

    void suspendForIme() {
        cancelSuggestions();
        if (pendingSearch != null) {
            a.ui.removeCallbacks(pendingSearch);
            pendingSearch = null;
        }
        searchSerial++;
        cancelWork();
        edited = "";
        status.setText("输入法正在组词，确认后搜索");
        resultBody.setVisibility(View.INVISIBLE);
    }

    void readImeDraft() {
        if (!imeActive || keyboard == null || input == null || !contextMatches()) return;
        android.text.Editable value = input.getText();
        if (value == null) return;
        imeDraft.update(
                value.toString(),
                android.view.inputmethod.BaseInputConnection.getComposingSpanStart(value),
                android.view.inputmethod.BaseInputConnection.getComposingSpanEnd(value),
                input.getSelectionEnd(),
                keyboard);
    }

    void captureImeUpdate() {
        if (!current() || !imeActive || syncingInput || imeConnectionDepth != 0) return;
        if (pendingImeRead != null) {
            a.ui.removeCallbacks(pendingImeRead);
            pendingImeRead = null;
        }
        PinyinKeyboardModel.Snapshot previous = keyboard.snapshot();
        readImeDraft();
        if (imeDraft.composing()) suspendForIme();
        else updateAfterImeInput(!TvSearchImeState.sameKeyboard(previous, keyboard.snapshot()));
    }

    void finishSystemIme(boolean commit) {
        if (!imeActive || keyboard == null) return;
        readImeDraft();
        imeActive = false;
        boolean resetCandidates = commit || imeDraft.keyboardChanged(keyboard);
        if (commit) imeDraft.commit(keyboard);
        else imeDraft.close(keyboard);
        if (imeDraft.composing()) {
            suspendForIme();
            return;
        }
        changed(resetCandidates);
    }

    void hideSystemIme() {
        if (input == null) return;
        try {
            android.view.inputmethod.InputMethodManager imm =
                    (android.view.inputmethod.InputMethodManager)
                            a.getSystemService(android.content.Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.hideSoftInputFromWindow(input.getWindowToken(), 0);
        } catch (Exception ignored) {
        }
    }

    boolean physicalKey(int key, KeyEvent event) {
        if (!current()) return false;
        if (!imeActive && imeDraft.composing()) return false;
        if (imeActive && a.getCurrentFocus() == input) {
            if (key == KeyEvent.KEYCODE_SEARCH && event.getAction() == KeyEvent.ACTION_DOWN) {
                finishSystemIme(true);
                hideSystemIme();
                submit();
                return true;
            }
            return false;
        }
        if (key == KeyEvent.KEYCODE_DPAD_CENTER || key == KeyEvent.KEYCODE_ENTER) {
            View focus = a.getCurrentFocus();
            if (focus != null) FocusMotion.key(a, focus, key, event);
        }
        if (event.getAction() != KeyEvent.ACTION_DOWN) return false;
        if (key == KeyEvent.KEYCODE_DEL) {
            keyboard.backspace();
            changed();
            return true;
        }
        if (key == KeyEvent.KEYCODE_SPACE) {
            keyboard.space();
            changed();
            return true;
        }
        if (key == KeyEvent.KEYCODE_SEARCH) {
            submit();
            return true;
        }
        int unicode = event.getUnicodeChar();
        if (unicode >= 32
                && unicode < 127
                && key != KeyEvent.KEYCODE_DPAD_CENTER
                && key != KeyEvent.KEYCODE_ENTER) {
            keyboard.input(String.valueOf((char) unicode).toLowerCase(Locale.ROOT));
            changed();
            return true;
        }
        return false;
    }

    void changed() {
        changed(true);
    }

    void changed(boolean resetCandidates) {
        if (!current() || input == null || keyboard == null) return;
        String display =
                imeDraft.composing()
                        ? imeDraft.text
                        : keyboard.query().isEmpty()
                                ? ""
                                : keyboard.committed()
                                        + (keyboard.composition().isEmpty()
                                                ? ""
                                                : "  " + keyboard.composition());
        syncingInput = true;
        android.text.Editable currentInput = input.getText();
        if (!display.equals(currentInput == null ? "" : currentInput.toString())) {
            input.setText(display);
            int actualLen = input.getText() == null ? 0 : input.getText().length();
            try {
                input.setSelection(safeSelectionIndex(display.length(), actualLen));
            } catch (Exception ignored) {
            }
        }
        syncingInput = false;
        syncSearchInputEllipsize();
        updateAfterImeInput(resetCandidates);
    }

    void updateAfterImeInput() {
        updateAfterImeInput(true);
    }

    void updateAfterImeInput(boolean resetCandidates) {
        if (!current() || keyboard == null || composition == null) return;
        if (imeDraft.composing()) {
            composition.setText("输入法文字未确认，双击继续输入");
            suspendForIme();
            return;
        }
        resultBody.setVisibility(View.VISIBLE);
        composition.setText(
                keyboard.composition().isEmpty()
                        ? (keyboard.mode() == PinyinKeyboardModel.Mode.PINYIN
                                ? "输入拼音选候选字 · 双击输入框调系统输入法"
                                : "直接输入字母、数字或符号 · 双击调系统输入法")
                        : "拼音  " + keyboard.composition());
        if (resetCandidates) candidatePage = 0;
        renderCandidates();
        updateTitleSuggestions();
        scheduleSearch();
    }

    void cancelSuggestions() {
        suggestionSerial++;
        suggestedQuery = null;
        if (suggestionWork != null) {
            suggestionWork.cancel(true);
            suggestionWork = null;
        }
        if (titleSuggestions != null) titleSuggestions.removeAllViews();
        if (suggestionScroll != null) suggestionScroll.setVisibility(View.GONE);
    }

    void updateTitleSuggestions() {
        if (suggestionScroll == null || !current() || keyboard == null) return;
        if (a.privateMode || imeDraft.composing()) {
            cancelSuggestions();
            return;
        }
        final String rawQuery = keyboard.query();
        final String query = TvSearchMatcher.isBlankQuery(rawQuery) ? "" : rawQuery.trim();
        if (query.equals(suggestedQuery)) return;
        cancelSuggestions();
        suggestedQuery = query;
        if (query.isEmpty()) return;
        final int ticket = suggestionSerial;
        try {
            suggestionWork =
                    a.phoneticWork.submit(
                            () -> {
                                if (a.phonetic == null)
                                    try {
                                        a.phoneticReady.await(
                                                8, java.util.concurrent.TimeUnit.SECONDS);
                                    } catch (InterruptedException cancelled) {
                                        Thread.currentThread().interrupt();
                                        return;
                                    }
                                if (Thread.currentThread().isInterrupted()) return;
                                PhoneticSearchIndex index = a.phonetic;
                                final List<String> values =
                                        index == null
                                                ? Collections.emptyList()
                                                : index.suggestTitles(query, 8);
                                a.ui.post(
                                        () -> {
                                            if (!acceptsTitleSuggestions(ticket, query)) return;
                                            titleSuggestions.removeAllViews();
                                            if (values.isEmpty()) return;
                                            TextView label = a.text("片名补全", 11.5f, TEXT_MUTED);
                                            label.setTypeface(null, Typeface.BOLD);
                                            label.setPadding(0, 0, a.dp(8), 0);
                                            titleSuggestions.addView(label);
                                            for (int sugIdx = 0; sugIdx < values.size(); sugIdx++) {
                                                final String title = values.get(sugIdx);
                                                final boolean isFirstSuggestion = (sugIdx == 0);
                                                final Button choice = new Button(a);
                                                choice.setText(title);
                                                choice.setTag("search-title:" + title);
                                                choice.setAllCaps(false);
                                                choice.setIncludeFontPadding(false);
                                                choice.setStateListAnimator(null);
                                                choice.setOutlineProvider(null);
                                                UiCompat.setDefaultFocusHighlightEnabled(
                                                        choice, false);
                                                choice.setTextSize(12.5f);
                                                choice.setSingleLine(true);
                                                choice.setMaxWidth(a.dp(200));
                                                choice.setEllipsize(TextUtils.TruncateAt.END);
                                                choice.setMinWidth(0);
                                                choice.setMinimumWidth(0);
                                                choice.setMinHeight(0);
                                                choice.setMinimumHeight(0);
                                                choice.setPadding(a.dp(12), 0, a.dp(12), 0);
                                                final GradientDrawable cBg = new GradientDrawable();
                                                cBg.setColor(BG_FILTER);
                                                cBg.setCornerRadius(a.dp(15));
                                                cBg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);
                                                choice.setBackground(cBg);
                                                choice.setTextColor(TEXT_PRIMARY);
                                                choice.setFocusable(true);
                                                choice.setFocusableInTouchMode(true);
                                                choice.setOnClickListener(
                                                        v -> {
                                                            if (!current()
                                                                    || ticket != suggestionSerial
                                                                    || a.privateMode
                                                                    || imeDraft.composing()) return;
                                                            imeDraft.clear();
                                                            keyboard.set(title);
                                                            changed();
                                                            submit(true);
                                                        });
                                                choice.setOnFocusChangeListener(
                                                        (v, focused) -> {
                                                            cBg.setColor(
                                                                    focused
                                                                            ? Color.WHITE
                                                                            : BG_FILTER);
                                                            cBg.setStroke(
                                                                    focused
                                                                            ? Math.max(2, a.dp(2))
                                                                            : Math.max(1, a.dp(1)),
                                                                    focused
                                                                            ? Color.WHITE
                                                                            : 0x26ffffff);
                                                            choice.setTextColor(
                                                                    focused
                                                                            ? TEXT_ON_LIGHT
                                                                            : TEXT_PRIMARY);
                                                        });
                                                if (a.isTvDevice() && isFirstSuggestion) {
                                                    choice.setOnKeyListener(
                                                            (v, keyCode, event) -> {
                                                                if (keyCode
                                                                                == KeyEvent
                                                                                        .KEYCODE_DPAD_LEFT
                                                                        && event.getAction()
                                                                                == KeyEvent
                                                                                        .ACTION_DOWN) {
                                                                    return restoreLeftFocus();
                                                                }
                                                                return false;
                                                            });
                                                }
                                                LinearLayout.LayoutParams size =
                                                        new LinearLayout.LayoutParams(-2, a.dp(32));
                                                size.rightMargin = a.dp(7);
                                                titleSuggestions.addView(choice, size);
                                            }
                                            suggestionScroll.scrollTo(0, 0);
                                            suggestionScroll.setVisibility(View.VISIBLE);
                                        });
                            });
        } catch (java.util.concurrent.RejectedExecutionException ignored) {
            suggestionWork = null;
        }
    }

    boolean acceptsTitleSuggestions(int ticket, String query) {
        return current()
                && ticket == suggestionSerial
                && !a.privateMode
                && !imeDraft.composing()
                && keyboard != null
                && query.equals(keyboard.query().trim());
    }

    void renderCandidates() {
        if (candidates == null || keyboard == null) return;
        candidates.removeAllViews();
        List<PinyinKeyboardModel.Candidate> values = keyboard.candidates();
        if (values.isEmpty()) {
            TextView hint =
                    a.text(keyboard.composition().isEmpty() ? "" : "继续输入拼音选字，或点搜索", 11, TEXT_MUTED);
            hint.setSingleLine(true);
            candidates.addView(hint);
            return;
        }
        int pages = (values.size() + 5) / 6;
        candidatePage = Math.max(0, Math.min(candidatePage, pages - 1));
        final int page = candidatePage;
        keyButton(
                        candidates,
                        "‹",
                        "candidate-previous",
                        () -> {
                            candidatePage = Math.max(0, candidatePage - 1);
                            renderCandidates();
                        },
                        1)
                .setEnabled(page > 0);
        for (int i = page * 6; i < Math.min(values.size(), page * 6 + 6); i++) {
            final PinyinKeyboardModel.Candidate candidate = values.get(i);
            keyButton(
                    candidates,
                    candidate.text,
                    "candidate:" + candidate.text,
                    () -> {
                        keyboard.select(candidate);
                        changed();
                        View first = a.root.findViewWithTag("search-key:a");
                        if (first != null) first.requestFocus();
                    },
                    1);
        }
        keyButton(
                        candidates,
                        "›",
                        "candidate-next",
                        () -> {
                            candidatePage = Math.min(pages - 1, candidatePage + 1);
                            renderCandidates();
                        },
                        1)
                .setEnabled(page < pages - 1);
    }

    void scheduleSearch() {
        if (!current() || keyboard == null || imeDraft.composing()) return;
        final String rawQuery = keyboard.query();
        String query = TvSearchMatcher.isBlankQuery(rawQuery) ? "" : rawQuery.trim();
        if (query.equals(edited)) return;
        edited = query;
        if (pendingSearch != null) a.ui.removeCallbacks(pendingSearch);
        pendingSearch = null;
        ++searchSerial;
        restoringResults = false;
        pendingPaginationFocus = false;
        cancelWork();
        if (!query.equals(submitted)) {
            cache = null;
            results.clear();
            searchSites.clear();
            sourceScroll.clear();
            sourceFocus.clear();
            sourceLimits.clear();
            sourceScrollPos.clear();
            sourceScrollOffset.clear();
            clearCards();
            displayed.clear();
            displayedItems.clear();
            filterButtons.clear();
            filterBgs.clear();
            filterNames.clear();
            renderedFilterLabels.clear();
            renderedFilterStates.clear();
            globalBudgetCapped = false;
            cacheDirty = false;
            if (sourceFilters != null) sourceFilters.removeAllViews();
            if (filterScrollView != null) filterScrollView.setVisibility(View.GONE);
            if (tvResultAdapter != null) tvResultAdapter.clearAll();
            if (!a.isTvDevice() && resultBody != null) resultBody.removeAllViews();
            resultGrid = null;
        }
        if (query.isEmpty()) {
            submitted = "";
            results.clear();
            clearCards();
            displayed.clear();
            displayedItems.clear();
            filterButtons.clear();
            filterBgs.clear();
            filterNames.clear();
            renderedFilterLabels.clear();
            renderedFilterStates.clear();
            globalBudgetCapped = false;
            cacheDirty = false;
            if (sourceFilters != null) sourceFilters.removeAllViews();
            if (filterScrollView != null) filterScrollView.setVisibility(View.GONE);
            if (tvResultAdapter != null) tvResultAdapter.clearAll();
            if (!a.isTvDevice() && resultBody != null) resultBody.removeAllViews();
            resultGrid = null;
            updateResultHeader();
            if (status != null) {
                status.setText(
                        matchMode == TvSearchMatcher.Mode.EXACT
                                ? "默认精准搜索完整片名 · 可按需切到模糊搜索"
                                : "当前模糊搜索 · 支持片名片段、拼音与首字母");
            }
            showHistory();
            if (tvLeftCollapsed) expandLeftPanel(true);
            return;
        }
        updateResultHeader();
        if (status != null) status.setText("正在输入… 停顿片刻自动" + matchMode.label);
        pendingSearch =
                () -> {
                    pendingSearch = null;
                    if (current() && keyboard != null) {
                        String cur = keyboard.query();
                        String trimmedCur = TvSearchMatcher.isBlankQuery(cur) ? "" : cur.trim();
                        if (query.equals(trimmedCur)) submit(false);
                    }
                };
        a.ui.postDelayed(pendingSearch, 650);
    }

    void submit() {
        submit(true);
    }

    void submit(boolean remember) {
        submitInternal(remember, "", false);
    }

    void submitInternal(boolean remember, String preserveFilter, boolean focusFirstOnResult) {
        if (!current() || keyboard == null) return;
        searchMultiSourceRev = a.multiSourceRevision();
        if (imeDraft.composing()) {
            a.toast("请先在输入法确认组词");
            return;
        }
        if (pendingSearch != null) {
            a.ui.removeCallbacks(pendingSearch);
            pendingSearch = null;
        }
        final String rawQuery = keyboard.query();
        if (TvSearchMatcher.isBlankQuery(rawQuery)) {
            submitted = "";
            pendingPaginationFocus = false;
            updateResultHeader();
            if (status != null) status.setText("请先输入片名；空关键词不会发起网络搜索。");
            showHistory();
            if (tvLeftCollapsed) expandLeftPanel(true);
            return;
        }
        final String query = rawQuery.trim();
        cache = null;
        cancelWork();
        restoringResults = false;
        pendingPaginationFocus = false;
        resumeSyncNeeded = false;
        resumeResultsSyncNeeded = false;
        boolean autoCollapseLeft =
                shouldAutoCollapseLeftPanelOnSubmit(
                        a.isTvDevice(), remember, focusFirstOnResult, true);
        focusNewResults = focusFirstOnResult || autoCollapseLeft;
        submitted = query;
        final TvSearchMatcher.Mode requestMode = matchMode;
        resultConfig = a.config;
        resultPrivateMode = a.privateMode;
        resultTime = System.currentTimeMillis();
        if (remember) saveHistory(query);
        if (coordinator != null) coordinator.close();
        results.clear();
        clearCards();
        displayed.clear();
        displayedItems.clear();
        deferredRerankPending = false;
        finished = failed = timedOut = busy = matched = 0;
        filterButtons.clear();
        filterBgs.clear();
        filterNames.clear();
        renderedFilterLabels.clear();
        renderedFilterStates.clear();
        globalBudgetCapped = false;
        cacheDirty = false;
        lastCacheSnapshotMs = 0L;
        searchStartedMs = android.os.SystemClock.elapsedRealtime();
        totalRenderUiMs = 0L;
        maxRenderUiMs = 0L;
        peakRetainedVideos = 0;
        peakInFlightImages = 0;
        searchSourceArrivals = 0;
        if (sourceFilters != null) sourceFilters.removeAllViews();
        shownLimit = 24;
        searchSites.clear();
        sourceScroll.clear();
        sourceFocus.clear();
        sourceLimits.clear();
        sourceScrollPos.clear();
        sourceScrollOffset.clear();

        final int serial = ++searchSerial;
        List<Cms.Site> sources = new ArrayList<>();
        if (a.config != null) {
            for (Cms.Site site : SourcePreferences.prioritized(a, a.config.sites)) {
                if (site.searchable && a.available(site)) sources.add(site);
            }
        }
        final String selected = a.prefs.getString(Prefs.SELECTED_SITE, "");
        Collections.sort(
                sources,
                (x, y) -> Boolean.compare(!x.key.equals(selected), !y.key.equals(selected)));
        final int total = sources.size();
        sourceCount = total;
        searchSites.addAll(sources);

        activeFilter = "";
        if (preserveFilter != null && !preserveFilter.isEmpty()) {
            for (Cms.Site s : sources) {
                if (preserveFilter.equals(s.key)) {
                    activeFilter = preserveFilter;
                    break;
                }
            }
        }

        if (a.isTvDevice()) {
            if (tvRecentScroll != null) tvRecentScroll.setVisibility(View.GONE);
            if (tvRecentContainer != null) tvRecentContainer.setVisibility(View.GONE);
            if (tvResultAdapter != null) tvResultAdapter.clearAll();
            if (tvResultRecycler != null) tvResultRecycler.setVisibility(View.GONE);
            if (filterScrollView != null) {
                filterScrollView.setVisibility(total > 0 ? View.VISIBLE : View.GONE);
            }
        } else {
            resetGrid();
        }
        updateResultHeader();
        renderFilters();
        if (total == 0) {
            if (status != null) status.setText("没有可搜索来源，请先导入配置并启用来源扩展。");
            renderResults();
            return;
        }
        if (status != null) {
            status.setText("正在" + requestMode.label + "全部 " + total + " 个来源…");
        }
        renderResults();
        if (autoCollapseLeft) {
            collapseLeftPanel(true);
            ensureRightPaneFocusAfterCollapse();
        }

        if (requestMode == TvSearchMatcher.Mode.EXACT) {
            // EXACT mode never needs phonetic dictionary expansion — launch immediately!
            List<String> exactTerms = TvSearchMatcher.buildRecallTerms(requestMode, query, null);
            startSources(sources, query, exactTerms, serial, requestMode);
            return;
        }
        try {
            expansion =
                    a.phoneticWork.submit(
                            () -> {
                                if (a.phonetic == null)
                                    try {
                                        a.phoneticReady.await(
                                                120, java.util.concurrent.TimeUnit.MILLISECONDS);
                                    } catch (InterruptedException cancelled) {
                                        Thread.currentThread().interrupt();
                                        return;
                                    }
                                if (Thread.currentThread().isInterrupted()) return;
                                final PhoneticSearchIndex index = a.phonetic;
                                final List<String> variants =
                                        TvSearchMatcher.buildRecallTerms(requestMode, query, index);
                                a.ui.post(
                                        () -> {
                                            if (current()
                                                    && serial == searchSerial
                                                    && requestMode == matchMode) {
                                                if (index != null
                                                        && !resultPrivateMode
                                                        && !query.matches("[A-Za-z0-9' -]+")) {
                                                    index.prefer(query);
                                                }
                                                startSources(
                                                        sources,
                                                        query,
                                                        variants,
                                                        serial,
                                                        requestMode);
                                            }
                                        });
                            });
        } catch (java.util.concurrent.RejectedExecutionException ignored) {
            expansion = null;
            startSources(
                    sources,
                    query,
                    TvSearchMatcher.buildRecallTerms(requestMode, query, null),
                    serial,
                    requestMode);
        }
    }

    void startSources(
            List<Cms.Site> sources,
            String query,
            List<String> variants,
            int serial,
            final TvSearchMatcher.Mode requestMode) {
        final TvSearchContext context = pageContext;
        if (!current()
                || serial != searchSerial
                || requestMode != matchMode
                || context == null
                || !context.matches(a.config, a.privateMode, a.engineEpoch)) return;
        final TvSearchBudget.BatchHandoff batches = new TvSearchBudget.BatchHandoff();
        if (activeBatchHandoff != null) activeBatchHandoff.close();
        activeBatchHandoff = batches;
        final int total = sources.size();
        searchVariants = variants;
        if (requestMode == TvSearchMatcher.Mode.FUZZY && variants.size() > 1 && status != null) {
            String joined =
                    variants.size() >= 2
                            ? variants.get(0) + " / " + variants.get(1)
                            : variants.get(0);
            status.setText("模糊搜索全部 " + total + " 个来源 · 扩展召回 " + joined);
        }
        final boolean lowRam = isLowRamTv();
        final boolean tvDevice = a.isTvDevice();
        final int globalCap = TvSearchBudget.globalCap(tvDevice, lowRam);
        final int initialPerSource = TvSearchBudget.initialPerSourceCap(total, tvDevice, lowRam);
        int effectiveThreads =
                computeEffectiveSearchThreads(
                        a.prefs.getInt(Prefs.SEARCH_THREADS, tvDevice && !lowRam ? 8 : 6),
                        tvDevice,
                        lowRam);
        SearchCoordinator.onLowMemoryHook =
                () -> {
                    trimMemory(android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL);
                    ImmersivePoster.trimMemory(
                            android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL);
                };
        SearchCoordinator.configureMaxPoolThreads(tvDevice ? (lowRam ? 6 : 8) : 14);
        SearchCoordinator.configureThreads(effectiveThreads);
        long rawSearchTimeoutMs =
                Prefs.clampSearchTimeoutSeconds(a.prefs.getInt(Prefs.SEARCH_TIMEOUT, 20)) * 1000L;
        long effectiveSearchTimeoutMs =
                sources.size() > 3 ? Math.min(10000L, rawSearchTimeoutMs) : rawSearchTimeoutMs;
        final SearchCoordinator[] sessionOwner = new SearchCoordinator[1];
        sessionOwner[0] =
                new SearchCoordinator(
                        (site, keyword) ->
                                firstPage(
                                        context,
                                        site,
                                        query,
                                        variants,
                                        requestMode,
                                        batches,
                                        initialPerSource),
                        (site, videos, outcome) ->
                                a.ui.post(
                                        () -> {
                                            boolean valid =
                                                    current()
                                                            && serial == searchSerial
                                                            && requestMode == matchMode
                                                            && context.matches(
                                                                    a.config,
                                                                    a.privateMode,
                                                                    a.engineEpoch)
                                                            && resultConfig == a.config
                                                            && resultPrivateMode == a.privateMode
                                                            && a.isSiteEnabledInMultiSource(
                                                                    site.key);
                                            boolean accept =
                                                    valid
                                                            && (outcome
                                                                            == SearchCoordinator
                                                                                    .Outcome.RESULT
                                                                    || outcome
                                                                            == SearchCoordinator
                                                                                    .Outcome.EMPTY);
                                            TvSearchPages pages = batches.take(site.key, accept);
                                            if (!valid) {
                                                batches.close();
                                                if (activeBatchHandoff == batches) {
                                                    activeBatchHandoff = null;
                                                }
                                                return;
                                            }
                                            List<Cms.Video> retained =
                                                    pages != null ? pages.videos : videos;
                                            if (retained != null && !retained.isEmpty()) {
                                                List<Cms.Video> ranked = new ArrayList<>(retained);
                                                TvSearchMatcher.rankSourceVideos(
                                                        requestMode,
                                                        query,
                                                        ranked,
                                                        site.name,
                                                        a.phonetic);
                                                retained = Collections.unmodifiableList(ranked);
                                            }
                                            learnSearchTitlesDeferred(retained);
                                            SearchCoordinator.Outcome effectiveOutcome = outcome;
                                            if (outcome == SearchCoordinator.Outcome.RESULT
                                                    && (retained == null || retained.isEmpty())) {
                                                effectiveOutcome = SearchCoordinator.Outcome.EMPTY;
                                            }
                                            SourceResult source =
                                                    new SourceResult(
                                                            site,
                                                            retained == null
                                                                    ? Collections.emptyList()
                                                                    : retained,
                                                            effectiveOutcome,
                                                            pages);
                                            results.put(site.key, source);
                                            boolean evicted =
                                                    TvSearchBudget.enforceGlobalResultsCapByItems(
                                                            results,
                                                            activeFilter,
                                                            site.key,
                                                            protectedBudgetItems(),
                                                            globalCap);
                                            SourceResult storedSource = results.get(site.key);
                                            if (evicted
                                                    || (storedSource != null
                                                            && storedSource.pages != null
                                                            && storedSource.pages.hasMore())) {
                                                globalBudgetCapped = true;
                                            }
                                            if (evicted) pruneEvictedCards();
                                            finished++;
                                            searchSourceArrivals++;
                                            if (effectiveOutcome == SearchCoordinator.Outcome.RESULT
                                                    && !source.videos.isEmpty()) {
                                                matched++;
                                            }
                                            if (effectiveOutcome
                                                    == SearchCoordinator.Outcome.FAILED) failed++;
                                            if (effectiveOutcome
                                                    == SearchCoordinator.Outcome.TIMEOUT)
                                                timedOut++;
                                            if (effectiveOutcome == SearchCoordinator.Outcome.BUSY)
                                                busy++;
                                            int retainedNow = retainedVideoCount();
                                            if (retainedNow > peakRetainedVideos) {
                                                peakRetainedVideos = retainedNow;
                                            }
                                            int imgInFlight = ImageLoader.inFlightCount();
                                            if (imgInFlight > peakInFlightImages) {
                                                peakInFlightImages = imgInFlight;
                                            }
                                            cacheDirty = true;
                                            if (finished >= total || evicted) {
                                                maybeCacheResults(true);
                                                updateStatus(total);
                                            }
                                            scheduleRender();
                                            if (finished >= total) {
                                                batches.close();
                                                if (activeBatchHandoff == batches) {
                                                    activeBatchHandoff = null;
                                                }
                                                if (coordinator == sessionOwner[0]) {
                                                    coordinator.close();
                                                    coordinator = null;
                                                }
                                                if (!a.privateMode) {
                                                    long elapsed =
                                                            Math.max(
                                                                    0L,
                                                                    android.os.SystemClock
                                                                                    .elapsedRealtime()
                                                                            - searchStartedMs);
                                                    AppLog.i(
                                                            "SearchDiag",
                                                            "done serial="
                                                                    + serial
                                                                    + " mode="
                                                                    + requestMode.prefValue
                                                                    + " sources="
                                                                    + total
                                                                    + " matched="
                                                                    + matched
                                                                    + " failed="
                                                                    + failed
                                                                    + " timeout="
                                                                    + timedOut
                                                                    + " busy="
                                                                    + busy
                                                                    + " retained="
                                                                    + peakRetainedVideos
                                                                    + " capped="
                                                                    + globalBudgetCapped
                                                                    + " uiMaxMs="
                                                                    + maxRenderUiMs
                                                                    + " imgPeak="
                                                                    + peakInFlightImages
                                                                    + " elapsedMs="
                                                                    + elapsed);
                                                }
                                            }
                                        }),
                        effectiveSearchTimeoutMs,
                        90000L,
                        tvDevice ? TvSearchPages.MAX_RESULTS : 24);
        coordinator = sessionOwner[0];
        coordinator.start(sources, query);
    }

    List<Cms.Video> searchSource(
            Cms.Site site, String query, List<String> variants, TvSearchMatcher.Mode requestMode)
            throws Exception {
        return SearchVariants.runVideos(
                query,
                variants,
                TvSearchMatcher.videoPredicate(requestMode, query, a.phonetic),
                term -> {
                    try {
                        return Cms.listing(a.engine(site).search(term, 1)).videos;
                    } catch (com.pilipala.catpaw.CatPawHost.DrpySourceException error) {
                        if ("drpy_verification_required".equals(error.code))
                            throw new SearchCoordinator.VerificationRequiredException();
                        throw error;
                    }
                });
    }

    List<Cms.Video> firstPage(
            TvSearchContext context,
            Cms.Site site,
            String query,
            List<String> variants,
            TvSearchMatcher.Mode requestMode,
            TvSearchBudget.BatchHandoff batches,
            int maxRetained)
            throws Exception {
        if (!a.isTvDevice()) {
            List<Cms.Video> raw = searchSource(site, query, variants, requestMode);
            if (raw.size() <= maxRetained) return raw;
            return Collections.unmodifiableList(
                    new ArrayList<>(raw.subList(0, Math.max(0, maxRetained))));
        }
        TvSearchPages pages =
                TvSearchPages.firstVideos(
                        query,
                        variants,
                        TvSearchMatcher.videoPredicate(requestMode, query, a.phonetic),
                        (term, page) -> fetchSearchPage(context, site, term, page),
                        maxRetained,
                        0);
        if (!batches.put(site.key, pages)) {
            return Collections.emptyList();
        }
        return pages.videos;
    }

    boolean matchesTitle(String title, String query) {
        return TvSearchMatcher.matches(TvSearchMatcher.Mode.FUZZY, query, title, null, a.phonetic);
    }

    Cms.Listing fetchSearchPage(TvSearchContext context, Cms.Site site, String term, int page)
            throws Exception {
        if (!context.matches(a.config, a.privateMode, a.engineEpoch)
                || Thread.currentThread().isInterrupted()) throw new InterruptedException();
        final SourceEngine engine = SourceController.engine(a, site, context);
        if (!context.matches(a.config, a.privateMode, a.engineEpoch)
                || Thread.currentThread().isInterrupted()) throw new InterruptedException();
        try {
            return Cms.listing(engine.search(term, page));
        } catch (com.pilipala.catpaw.CatPawHost.DrpySourceException error) {
            if ("drpy_verification_required".equals(error.code))
                throw new SearchCoordinator.VerificationRequiredException();
            throw error;
        }
    }

    static boolean isAllTabBudgetExhausted(
            String activeFilter,
            int displayedCount,
            int retainedCount,
            int availableCount,
            int shownLimit,
            int globalCap) {
        if (activeFilter != null && !activeFilter.isEmpty()) return false;
        if (globalCap <= 0) return false;
        if (displayedCount >= globalCap) return true;
        return retainedCount >= globalCap && availableCount <= shownLimit;
    }

    static SourceResult selectNextPageSource(
            Map<String, SourceResult> results,
            String activeFilter,
            int displayedCount,
            int retainedCount,
            int availableCount,
            int shownLimit,
            int globalCap) {
        if (results == null || results.isEmpty()) return null;
        if (isAllTabBudgetExhausted(
                activeFilter,
                displayedCount,
                retainedCount,
                availableCount,
                shownLimit,
                globalCap)) {
            return null;
        }
        String filter = activeFilter == null ? "" : activeFilter;
        for (SourceResult result : results.values()) {
            if (result != null
                    && (filter.isEmpty() || filter.equals(result.site.key))
                    && result.pages != null
                    && result.pages.hasMore()) {
                return result;
            }
        }
        return null;
    }

    SourceResult nextPageSource() {
        return nextPageSource(collectCurrentRankedHits().size());
    }

    private SourceResult nextPageSource(int availableCount) {
        int globalCap = TvSearchBudget.globalCap(a.isTvDevice(), isLowRamTv());
        return selectNextPageSource(
                results,
                activeFilter,
                displayed.size(),
                retainedVideoCount(),
                availableCount,
                shownLimit,
                globalCap);
    }

    private boolean isCurrentAllTabBudgetExhausted(int availableCount) {
        int globalCap = TvSearchBudget.globalCap(a.isTvDevice(), isLowRamTv());
        return isAllTabBudgetExhausted(
                activeFilter,
                displayed.size(),
                retainedVideoCount(),
                availableCount,
                shownLimit,
                globalCap);
    }

    private List<TvSearchBudget.ProtectedItem> protectedBudgetItems() {
        List<TvSearchBudget.ProtectedItem> items = new ArrayList<>(displayedItems.size() + 2);
        items.addAll(displayedItems);
        String wallFocused = focusedTag(tvResultRecycler);
        addFocusedProtectedItem(items, wallFocused);
        String savedFocused = sourceFocus.get(activeFilter);
        if (savedFocused != null && !savedFocused.equals(wallFocused)) {
            addFocusedProtectedItem(items, savedFocused);
        }
        return items;
    }

    private void addFocusedProtectedItem(List<TvSearchBudget.ProtectedItem> out, String cardTag) {
        if (cardTag == null || !cardTag.startsWith("global-result:")) return;
        String rawKey = cardTag.substring("global-result:".length());
        if (rawKey.isEmpty()) return;
        if (tvResultAdapter != null) {
            int idx = tvResultAdapter.indexOfTag(cardTag);
            if (idx >= 0 && idx < tvResultAdapter.items.size()) {
                TvSearchMatcher.RankedHit hit = tvResultAdapter.items.get(idx);
                if (hit != null && hit.site != null && hit.video != null) {
                    out.add(new TvSearchBudget.ProtectedItem(hit.site.key, hit.video.id));
                    return;
                }
            }
        }
        TvSearchMatcher.HitId parsed = TvSearchMatcher.HitId.parseKey(rawKey);
        if (parsed != null) {
            SourceResult sr = results.get(parsed.siteKey);
            if (sr != null && sr.videos != null) {
                for (Cms.Video v : sr.videos) {
                    if (v != null && parsed.vodId.equals(v.id)) {
                        out.add(new TvSearchBudget.ProtectedItem(parsed.siteKey, parsed.vodId));
                        return;
                    }
                }
            }
            if (rawKey.indexOf('%') >= 0) {
                return;
            }
        }
        for (Map.Entry<String, SourceResult> entry : results.entrySet()) {
            String siteKey = entry.getKey();
            SourceResult sr = entry.getValue();
            if (siteKey == null
                    || siteKey.isEmpty()
                    || sr == null
                    || sr.videos == null
                    || rawKey.length() <= siteKey.length() + 1
                    || !rawKey.startsWith(siteKey)
                    || rawKey.charAt(siteKey.length()) != ':') {
                continue;
            }
            String candidateVodId = rawKey.substring(siteKey.length() + 1);
            for (Cms.Video v : sr.videos) {
                if (v != null && candidateVodId.equals(v.id)) {
                    out.add(new TvSearchBudget.ProtectedItem(siteKey, candidateVodId));
                    return;
                }
            }
        }
    }

    private String currentPaginationAnchorKey() {
        String focused = focusedTag(tvResultRecycler);
        if (focused != null && focused.startsWith("global-result:")) {
            return focused.substring("global-result:".length());
        }
        String saved = sourceFocus.get(activeFilter);
        if (saved != null && saved.startsWith("global-result:")) {
            return saved.substring("global-result:".length());
        }
        String last = "";
        for (String key : displayed) last = key;
        return last;
    }

    /**
     * Resolves the post-pagination focus target: prefers the first newly-revealed card at or after
     * {@code targetIndex} (e.g. card #25 after expanding from 24), else the first newly-added card
     * anywhere in {@code visible}, else retains {@code anchorKey} without ever jumping back to 0.
     */
    static int resolvePaginationFocusIndex(
            List<TvSearchMatcher.RankedHit> visible,
            Set<String> prevKeys,
            int targetIndex,
            String anchorKey) {
        if (visible == null || visible.isEmpty()) return -1;
        Set<String> before = prevKeys == null ? Collections.emptySet() : prevKeys;
        int start = Math.max(0, Math.min(targetIndex, visible.size()));
        for (int i = start; i < visible.size(); i++) {
            if (!before.contains(visible.get(i).stableKey())) {
                return i;
            }
        }
        for (int i = 0; i < start; i++) {
            if (!before.contains(visible.get(i).stableKey())) {
                return i;
            }
        }
        if (anchorKey != null && !anchorKey.isEmpty()) {
            for (int i = 0; i < visible.size(); i++) {
                if (anchorKey.equals(visible.get(i).stableKey())) {
                    return i;
                }
            }
        }
        return Math.max(0, Math.min(visible.size() - 1, start > 0 ? start - 1 : 0));
    }

    void triggerMoreResults() {
        if (!current()) return;
        int available = collectCurrentRankedHits().size();
        if (available <= shownLimit) loadNextPage();
        else {
            int prevShown = Math.min(available, shownLimit);
            pendingPaginationPrevKeys = new LinkedHashSet<>(displayed);
            pendingPaginationAnchorKey = currentPaginationAnchorKey();
            pendingPaginationTargetIndex = prevShown;
            pendingPaginationFocus = true;
            shownLimit = shownLimit > Integer.MAX_VALUE - 24 ? Integer.MAX_VALUE : shownLimit + 24;
            sourceLimits.put(activeFilter, shownLimit);
            renderResults();
        }
    }

    /**
     * Returns whether a late pagination completion may update the active view's visible limit,
     * scroll position, and focus target. Only allowed when the user is still on the exact same
     * filter tab and filter-selection epoch from which pagination was triggered; stale callbacks
     * from a prior source still update their source cache without hijacking "全部" or another tab.
     */
    static boolean shouldApplyPaginationViewUpdate(
            String requestedFilter,
            String currentFilter,
            int requestedFilterSerial,
            int currentFilterSerial) {
        String req = requestedFilter == null ? "" : requestedFilter;
        String cur = currentFilter == null ? "" : currentFilter;
        return req.equals(cur) && requestedFilterSerial == currentFilterSerial;
    }

    void loadNextPage() {
        if (!current() || pageRequests.get() != null) return;
        final SourceResult source = nextPageSource();
        if (source == null) return;
        final int prevVisibleCount = displayed.size();
        final Set<String> prevVisibleKeys = new LinkedHashSet<>(displayed);
        final String prevAnchorKey = currentPaginationAnchorKey();
        final String requestedFilter = activeFilter;
        final int requestedFilterSerial = filterSwitchSerial;
        final int serial = searchSerial;
        final TvSearchMatcher.Mode requestMode = matchMode;
        final TvSearchContext context = pageContext;
        final boolean lowRam = isLowRamTv();
        final boolean tvDevice = a.isTvDevice();
        final int stepCap = TvSearchBudget.pageStepCap(tvDevice, lowRam);
        final int globalCap = TvSearchBudget.globalCap(tvDevice, lowRam);
        final java.util.concurrent.atomic.AtomicReference<TvSearchPages> completed =
                new java.util.concurrent.atomic.AtomicReference<>();
        pageFailureSource = pageFailureReason = "";
        final SearchCoordinator[] owner = new SearchCoordinator[1];
        owner[0] =
                new SearchCoordinator(
                        (site, query) -> {
                            TvSearchPages next =
                                    source.pages.nextVideos(
                                            TvSearchMatcher.videoPredicate(
                                                    requestMode, source.pages.query, a.phonetic),
                                            (term, page) ->
                                                    fetchSearchPage(context, site, term, page),
                                            stepCap,
                                            globalCap);
                            completed.set(next);
                            return next.videos;
                        },
                        (site, videos, outcome) ->
                                a.ui.post(
                                        () -> {
                                            TvSearchPages next = completed.getAndSet(null);
                                            if (!pageRequests.finish(owner[0])) return;
                                            if (!current()
                                                    || serial != searchSerial
                                                    || requestMode != matchMode
                                                    || context == null
                                                    || !context.matches(
                                                            a.config, a.privateMode, a.engineEpoch)
                                                    || resultConfig != a.config
                                                    || resultPrivateMode != a.privateMode) return;
                                            if (results.get(site.key) != source) {
                                                renderResults();
                                                return;
                                            }
                                            if (next != null
                                                    && (outcome == SearchCoordinator.Outcome.RESULT
                                                            || outcome
                                                                    == SearchCoordinator.Outcome
                                                                            .EMPTY)) {
                                                SearchCoordinator.Outcome effectiveOutcome =
                                                        next.videos.isEmpty()
                                                                ? SearchCoordinator.Outcome.EMPTY
                                                                : SearchCoordinator.Outcome.RESULT;
                                                results.put(
                                                        site.key,
                                                        new SourceResult(
                                                                site,
                                                                next.videos,
                                                                effectiveOutcome,
                                                                next));
                                                boolean evicted =
                                                        TvSearchBudget
                                                                .enforceGlobalResultsCapByItems(
                                                                        results,
                                                                        activeFilter,
                                                                        site.key,
                                                                        protectedBudgetItems(),
                                                                        globalCap);
                                                SourceResult storedNext = results.get(site.key);
                                                if (evicted
                                                        || (storedNext != null
                                                                && storedNext.pages != null
                                                                && storedNext.pages.hasMore())) {
                                                    globalBudgetCapped = true;
                                                }
                                                if (evicted) pruneEvictedCards();
                                                int retainedNow = retainedVideoCount();
                                                if (retainedNow > peakRetainedVideos) {
                                                    peakRetainedVideos = retainedNow;
                                                }
                                                if (shouldApplyPaginationViewUpdate(
                                                        requestedFilter,
                                                        activeFilter,
                                                        requestedFilterSerial,
                                                        filterSwitchSerial)) {
                                                    shownLimit =
                                                            Math.min(
                                                                            Integer.MAX_VALUE - 24,
                                                                            shownLimit)
                                                                    + 24;
                                                    sourceLimits.put(activeFilter, shownLimit);
                                                    pendingPaginationPrevKeys = prevVisibleKeys;
                                                    pendingPaginationAnchorKey = prevAnchorKey;
                                                    pendingPaginationTargetIndex = prevVisibleCount;
                                                    pendingPaginationFocus = true;
                                                }
                                                recount();
                                                cacheResults();
                                            } else {
                                                pageFailureSource = site.key;
                                                pageFailureReason =
                                                        outcome == SearchCoordinator.Outcome.TIMEOUT
                                                                ? "下一页超时"
                                                                : outcome
                                                                                == SearchCoordinator
                                                                                        .Outcome
                                                                                        .VERIFICATION_REQUIRED
                                                                        ? "下一页需网站验证码"
                                                                        : outcome
                                                                                        == SearchCoordinator
                                                                                                .Outcome
                                                                                                .BUSY
                                                                                ? "下一页未完成"
                                                                                : "下一页请求失败";
                                            }
                                            updateStatus(sourceCount);
                                            scheduleRender();
                                        }),
                        Prefs.clampSearchTimeoutSeconds(a.prefs.getInt(Prefs.SEARCH_TIMEOUT, 20))
                                * 1000L,
                        40000L,
                        TvSearchPages.MAX_RESULTS);
        pageRequests.bind(owner[0]);
        owner[0].start(Collections.singletonList(source.site), submitted);
        renderResults();
    }

    void retrySelected() {
        SourceResult selected = results.get(activeFilter);
        if (!current() || selected == null || retryCoordinator != null) return;
        pageRequests.cancel();
        pageFailureSource = pageFailureReason = "";
        final TvSearchContext context = pageContext;
        final TvSearchBudget.BatchHandoff batches = new TvSearchBudget.BatchHandoff();
        if (activeRetryHandoff != null) activeRetryHandoff.close();
        activeRetryHandoff = batches;
        final String query = submitted;
        final TvSearchMatcher.Mode requestMode = matchMode;
        final List<String> variants =
                TvSearchMatcher.buildRecallTerms(requestMode, query, a.phonetic);
        final int serial = searchSerial;
        final boolean lowRam = isLowRamTv();
        final boolean tvDevice = a.isTvDevice();
        final int stepCap = TvSearchBudget.pageStepCap(tvDevice, lowRam);
        final int globalCap = TvSearchBudget.globalCap(tvDevice, lowRam);
        if (retrySource != null) retrySource.setEnabled(false);
        if (emptyResult != null) emptyResult.setText("正在按" + requestMode.label + "重新搜索此源…");
        final SearchCoordinator[] retryOwner = new SearchCoordinator[1];
        retryOwner[0] =
                new SearchCoordinator(
                        (site, ignored) ->
                                firstPage(
                                        context,
                                        site,
                                        query,
                                        variants,
                                        requestMode,
                                        batches,
                                        stepCap),
                        (site, videos, outcome) ->
                                a.ui.post(
                                        () -> {
                                            boolean ownsRetry = retryCoordinator == retryOwner[0];
                                            if (ownsRetry) {
                                                retryCoordinator.close();
                                                retryCoordinator = null;
                                            }
                                            boolean valid =
                                                    ownsRetry
                                                            && current()
                                                            && serial == searchSerial
                                                            && requestMode == matchMode
                                                            && context != null
                                                            && context.matches(
                                                                    a.config,
                                                                    a.privateMode,
                                                                    a.engineEpoch)
                                                            && resultConfig == a.config
                                                            && resultPrivateMode == a.privateMode
                                                            && a.isSiteEnabledInMultiSource(
                                                                    site.key);
                                            boolean accept =
                                                    valid
                                                            && (outcome
                                                                            == SearchCoordinator
                                                                                    .Outcome.RESULT
                                                                    || outcome
                                                                            == SearchCoordinator
                                                                                    .Outcome.EMPTY);
                                            TvSearchPages pages = batches.take(site.key, accept);
                                            batches.close();
                                            if (activeRetryHandoff == batches) {
                                                activeRetryHandoff = null;
                                            }
                                            if (!valid) return;
                                            List<Cms.Video> retained =
                                                    pages != null ? pages.videos : videos;
                                            if (retained != null && !retained.isEmpty()) {
                                                List<Cms.Video> ranked = new ArrayList<>(retained);
                                                TvSearchMatcher.rankSourceVideos(
                                                        requestMode,
                                                        query,
                                                        ranked,
                                                        site.name,
                                                        a.phonetic);
                                                retained = Collections.unmodifiableList(ranked);
                                            }
                                            learnSearchTitlesDeferred(retained);
                                            SearchCoordinator.Outcome effectiveOutcome =
                                                    outcome == SearchCoordinator.Outcome.RESULT
                                                                    && (retained == null
                                                                            || retained.isEmpty())
                                                            ? SearchCoordinator.Outcome.EMPTY
                                                            : outcome;
                                            results.put(
                                                    site.key,
                                                    new SourceResult(
                                                            site,
                                                            retained == null
                                                                    ? Collections.emptyList()
                                                                    : retained,
                                                            effectiveOutcome,
                                                            pages));
                                            boolean evicted =
                                                    TvSearchBudget.enforceGlobalResultsCapByItems(
                                                            results,
                                                            activeFilter,
                                                            site.key,
                                                            protectedBudgetItems(),
                                                            globalCap);
                                            SourceResult storedRetry = results.get(site.key);
                                            if (evicted
                                                    || (storedRetry != null
                                                            && storedRetry.pages != null
                                                            && storedRetry.pages.hasMore())) {
                                                globalBudgetCapped = true;
                                            }
                                            if (evicted) pruneEvictedCards();
                                            int retainedNow = retainedVideoCount();
                                            if (retainedNow > peakRetainedVideos) {
                                                peakRetainedVideos = retainedNow;
                                            }
                                            recount();
                                            cacheResults();
                                            updateStatus(sourceCount);
                                            scheduleRender();
                                        }),
                        Prefs.clampSearchTimeoutSeconds(a.prefs.getInt(Prefs.SEARCH_TIMEOUT, 20))
                                * 1000L,
                        40000L,
                        tvDevice ? TvSearchPages.MAX_RESULTS : 24);
        retryCoordinator = retryOwner[0];
        retryCoordinator.start(Collections.singletonList(selected.site), submitted);
    }

    private boolean allSourcesFailed() {
        if (sourceCount <= 0 || finished < sourceCount) return false;
        int healthy = 0;
        for (SourceResult r : results.values()) {
            if (r != null
                    && (r.outcome == SearchCoordinator.Outcome.RESULT
                            || r.outcome == SearchCoordinator.Outcome.EMPTY)) {
                healthy++;
            }
        }
        return healthy == 0 && !results.isEmpty();
    }

    void updateResultHeader() {
        if (tvHeaderTitle == null || tvHeaderMeta == null) return;
        if (submitted.isEmpty()) {
            tvHeaderTitle.setText("探索与搜索");
            tvHeaderMeta.setText(matchMode.label);
            return;
        }
        tvHeaderTitle.setText("“" + submitted + "” 的结果");
        int count = collectCurrentRankedHits().size();
        String suffix =
                finished < sourceCount ? (count > 0 ? count + " 项 · 搜索中" : "搜索中…") : (count + " 项");
        tvHeaderMeta.setText(matchMode.label + " · " + suffix);
    }

    void updateStatus(int total) {
        updateResultHeader();
        String text =
                matchMode.label
                        + " · "
                        + (finished == total ? "已完成" : "搜索中")
                        + " "
                        + finished
                        + "/"
                        + total
                        + " 来源 · "
                        + matched
                        + " 个命中";
        if (timedOut > 0) text += " · " + timedOut + " 超时";
        if (failed > 0) text += " · " + failed + " 失败";
        if (busy > 0) text += " · " + busy + " 未完成";
        int verification = 0;
        for (SourceResult result : results.values())
            if (result.outcome == SearchCoordinator.Outcome.VERIFICATION_REQUIRED) verification++;
        if (verification > 0) text += " · " + verification + " 需验证";
        if (status != null) {
            CharSequence prev = status.getText();
            if (prev == null || !text.equals(prev.toString())) {
                status.setText(text);
            }
        }
    }

    void cancelWork() {
        pageRequests.cancel();
        pageFailureSource = pageFailureReason = "";
        if (activeBatchHandoff != null) {
            activeBatchHandoff.close();
            activeBatchHandoff = null;
        }
        if (activeRetryHandoff != null) {
            activeRetryHandoff.close();
            activeRetryHandoff = null;
        }
        if (retryCoordinator != null) {
            retryCoordinator.close();
            retryCoordinator = null;
        }
        if (expansion != null) {
            expansion.cancel(true);
            expansion = null;
        }
        if (coordinator != null) {
            coordinator.close();
            coordinator = null;
        }
        if (pendingRender != null) {
            a.ui.removeCallbacks(pendingRender);
            pendingRender = null;
        }
    }

    void clearCards() {
        for (LinearLayout card : posterCards.values()) {
            TvV17PosterCard.unbindCard(card);
            card.setOnClickListener(null);
            card.setOnKeyListener(null);
            card.setOnFocusChangeListener(null);
        }
        posterCards.clear();
        if (tvResultRecycler != null) {
            for (int i = 0; i < tvResultRecycler.getChildCount(); i++) {
                View child = tvResultRecycler.getChildAt(i);
                if (child instanceof ViewGroup && ((ViewGroup) child).getChildCount() > 0) {
                    View art = ((ViewGroup) child).getChildAt(0);
                    if (art instanceof TvSearchPosterArtView) {
                        ((TvSearchPosterArtView) art).clearPoster();
                    }
                }
                TvV17PosterCard.unbindCard(child);
            }
        }
        if (searchArtworkScope != 0) {
            ImageLoader.cancelScope(a, searchArtworkScope);
        }
        searchArtworkScope = ImageLoader.newScope();
    }

    void pruneEvictedCards() {
        if (posterCards.isEmpty()) return;
        Set<String> liveKeys = new HashSet<>();
        for (SourceResult r : results.values()) {
            if (r == null || r.videos == null) continue;
            for (int i = 0; i < r.videos.size(); i++) {
                Cms.Video v = r.videos.get(i);
                if (v != null && r.site != null) {
                    liveKeys.add(TvSearchMatcher.stableKey(r.site.key, v.id));
                }
            }
        }
        boolean displayedEvicted = false;
        Iterator<Map.Entry<String, LinearLayout>> it = posterCards.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<String, LinearLayout> entry = it.next();
            if (!liveKeys.contains(entry.getKey())) {
                LinearLayout card = entry.getValue();
                TvV17PosterCard.unbindCard(card);
                card.setOnClickListener(null);
                card.setOnKeyListener(null);
                card.setOnFocusChangeListener(null);
                it.remove();
                if (displayed.contains(entry.getKey())) displayedEvicted = true;
            }
        }
        if (displayedEvicted && resultGrid != null) {
            resetGrid();
        }
    }

    void scheduleRender() {
        if (pendingRender != null) return;
        final int serial = searchSerial;
        final TvSearchMatcher.Mode modeSnap = matchMode;
        pendingRender =
                () -> {
                    pendingRender = null;
                    if (!current() || serial != searchSerial || modeSnap != matchMode) return;
                    if (sourceCount > 0) updateStatus(sourceCount);
                    renderFilters();
                    renderResults();
                };
        a.ui.postDelayed(pendingRender, 90);
    }

    void renderFilters() {
        if (sourceFilters == null) return;
        if (!filterButtons.containsKey("")) addFilter("全部", "");
        int addedNow = 0;
        final int maxPerPass = a.isTvDevice() ? 16 : Integer.MAX_VALUE;
        boolean moreFiltersPending = false;
        for (SourceResult source : results.values()) {
            if (!filterButtons.containsKey(source.site.key)) {
                if (addedNow >= maxPerPass) {
                    moreFiltersPending = true;
                    break;
                }
                addFilter(clean(source.site.name), source.site.key);
                addedNow++;
            }
        }
        if (!moreFiltersPending && !searchSites.isEmpty()) {
            for (Cms.Site site : searchSites) {
                if (!filterButtons.containsKey(site.key)) {
                    if (addedNow >= maxPerPass) {
                        moreFiltersPending = true;
                        break;
                    }
                    addFilter(clean(site.name), site.key);
                    addedNow++;
                }
            }
        }
        updateFilterLabels();
        if (moreFiltersPending && pendingRender == null) {
            final int serial = searchSerial;
            final TvSearchMatcher.Mode modeSnap = matchMode;
            pendingRender =
                    () -> {
                        pendingRender = null;
                        if (current() && serial == searchSerial && modeSnap == matchMode) {
                            renderFilters();
                            renderResults();
                        }
                    };
            a.ui.postDelayed(pendingRender, 16);
        }
    }

    void addFilter(String label, final String key) {
        final Button b;
        if (a.isTvDevice()) {
            b = new Button(a);
            b.setText(label);
            b.setTag("search-filter:" + key);
            b.setAllCaps(false);
            b.setIncludeFontPadding(false);
            b.setStateListAnimator(null);
            b.setOutlineProvider(null);
            if (android.os.Build.VERSION.SDK_INT >= 23) {
                b.setBreakStrategy(android.text.Layout.BREAK_STRATEGY_SIMPLE);
                b.setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE);
            }
            GradientDrawable pillBg = new GradientDrawable();
            pillBg.setCornerRadius(a.dp(16));
            pillBg.setColor(BG_FILTER);
            b.setBackground(pillBg);
            filterBgs.put(key, pillBg);
            UiCompat.setDefaultFocusHighlightEnabled(b, false);
            b.setFocusable(true);
            b.setFocusableInTouchMode(true);
            // Confirm selects filter if unselected, or enters poster wall if already active!
            b.setOnClickListener(
                    v -> {
                        if (!current()) return;
                        if (!key.equals(activeFilter)) {
                            selectFilter(key);
                        } else {
                            focusSelectedResults();
                        }
                    });
        } else {
            b = a.button(label, "search-filter:" + key, () -> selectFilter(key));
        }
        b.setTextSize(12);
        b.setMinWidth(a.dp(58));
        b.setMinimumWidth(a.dp(58));
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setPadding(a.dp(14), 0, a.dp(14), 0);
        b.setSingleLine(true);
        b.setEllipsize(null);
        b.setGravity(Gravity.CENTER);
        b.setContentDescription(label);
        b.setOnFocusChangeListener((v, focus) -> styleFilter(b, key, focus));
        if (a.isTvDevice()) {
            b.setOnKeyListener(
                    (v, keyCode, event) -> {
                        if (event.getAction() != KeyEvent.ACTION_DOWN) return false;
                        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
                            focusSelectedResults();
                            return true;
                        }
                        if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT && key.isEmpty()) {
                            return restoreLeftFocus();
                        }
                        return false;
                    });
        }
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-2, a.dp(32));
        size.setMargins(a.dp(2), 0, a.dp(7), 0);
        sourceFilters.addView(b, size);
        filterButtons.put(key, b);
        filterNames.put(key, label);
        styleFilter(b, key, false);
    }

    void rememberSourcePosition() {
        sourceLimits.put(activeFilter, shownLimit);
        if (tvResultRecycler != null && tvResultLayout != null) {
            int firstPos = tvResultLayout.findFirstVisibleItemPosition();
            if (firstPos >= 0) {
                View child = tvResultLayout.findViewByPosition(firstPos);
                int topOff = child == null ? 0 : child.getTop() - tvResultRecycler.getPaddingTop();
                sourceScrollPos.put(activeFilter, firstPos);
                sourceScrollOffset.put(activeFilter, topOff);
                savedRecyclerPos = firstPos;
                savedRecyclerOffset = topOff;
            }
            String tag = focusedTag(tvResultRecycler);
            if (tag != null) sourceFocus.put(activeFilter, tag);
            return;
        }
        if (resultScroll == null) return;
        sourceScroll.put(activeFilter, resultScroll.getScrollY());
        String tag = focusedTag(resultGrid);
        if (tag != null) sourceFocus.put(activeFilter, tag);
    }

    void selectFilter(final String key) {
        if (!current()) return;
        if (key.equals(activeFilter)) return;
        rememberSourcePosition();
        focusNewResults = false;
        pendingPaginationFocus = false;
        deferredRerankPending = false;
        displayed.clear();
        displayedItems.clear();
        filterSwitchSerial++;
        activeFilter = key;
        shownLimit = sourceLimits.containsKey(key) ? sourceLimits.get(key) : 24;
        updateFilterLabels();
        updateResultHeader();
        if (a.isTvDevice()) {
            renderResults();
        } else {
            resetGrid();
            renderResults();
        }
        if (!key.isEmpty()) {
            SourceResult selected = results.get(key);
            if (selected != null
                    && selected.videos.isEmpty()
                    && selected.pages != null
                    && selected.pages.hasMore()) {
                loadNextPage();
            }
        }
        if (tvResultRecycler != null && tvResultLayout != null) {
            final int pos = sourceScrollPos.containsKey(key) ? sourceScrollPos.get(key) : 0;
            final int off = sourceScrollOffset.containsKey(key) ? sourceScrollOffset.get(key) : 0;
            final int serial = searchSerial;
            tvResultRecycler.post(
                    () -> {
                        if (current()
                                && serial == searchSerial
                                && key.equals(activeFilter)
                                && tvResultAdapter != null
                                && pos < tvResultAdapter.getItemCount()) {
                            tvResultLayout.scrollToPositionWithOffset(pos, off);
                        }
                    });
        } else if (resultScroll != null) {
            final int scroll = sourceScroll.containsKey(key) ? sourceScroll.get(key) : 0;
            final int serial = searchSerial;
            resultScroll.post(
                    () -> {
                        if (current() && serial == searchSerial && key.equals(activeFilter))
                            resultScroll.scrollTo(0, scroll);
                    });
        }
    }

    void focusSelectedResults() {
        focusSelectedResultsInternal();
    }

    private boolean focusSelectedResultsInternal() {
        if (!current()) return false;
        String tag = sourceFocus.get(activeFilter);
        if (tvResultRecycler != null && tvResultRecycler.getVisibility() == View.VISIBLE) {
            if (tag != null && !tag.isEmpty()) {
                View target = tvResultRecycler.findViewWithTag(tag);
                if (target != null && target.isShown()) {
                    target.requestFocus();
                    return true;
                }
                int idx = tvResultAdapter == null ? -1 : tvResultAdapter.indexOfTag(tag);
                if (idx >= 0) {
                    focusCardAt(idx);
                    return true;
                }
            }
            if (tvResultAdapter != null && tvResultAdapter.getItemCount() > 0) {
                focusCardAt(0);
                return true;
            }
        } else {
            View target = tag == null ? null : a.root.findViewWithTag(tag);
            if (target == null && !displayed.isEmpty())
                target = posterCards.get(displayed.iterator().next());
            if (target != null) {
                target.requestFocus();
                return true;
            }
        }
        if (switchFuzzyBtn != null && switchFuzzyBtn.getVisibility() == View.VISIBLE) {
            switchFuzzyBtn.requestFocus();
            return true;
        }
        if (retryAllBtn != null && retryAllBtn.getVisibility() == View.VISIBLE) {
            retryAllBtn.requestFocus();
            return true;
        }
        if (retrySource != null && retrySource.getVisibility() == View.VISIBLE) {
            retrySource.requestFocus();
            return true;
        }
        if (moreResults != null && moreResults.getVisibility() == View.VISIBLE) {
            moreResults.requestFocus();
            return true;
        }
        return false;
    }

    private void focusCardAt(final int position) {
        if (tvResultRecycler == null
                || tvResultLayout == null
                || tvResultAdapter == null
                || position < 0
                || position >= tvResultAdapter.getItemCount()) return;
        RecyclerView.ViewHolder vh = tvResultRecycler.findViewHolderForAdapterPosition(position);
        if (vh != null && vh.itemView.isShown()) {
            vh.itemView.requestFocus();
            return;
        }
        tvResultLayout.scrollToPositionWithOffset(position, a.dp(8));
        final int serial = searchSerial;
        tvResultRecycler.post(
                () -> {
                    if (!current() || serial != searchSerial || tvResultRecycler == null) return;
                    RecyclerView.ViewHolder bound =
                            tvResultRecycler.findViewHolderForAdapterPosition(position);
                    if (bound != null) {
                        bound.itemView.requestFocus();
                    } else {
                        tvResultRecycler.post(
                                () -> {
                                    if (!current()
                                            || serial != searchSerial
                                            || tvResultRecycler == null) return;
                                    RecyclerView.ViewHolder retryBound =
                                            tvResultRecycler.findViewHolderForAdapterPosition(
                                                    position);
                                    if (retryBound != null) retryBound.itemView.requestFocus();
                                });
                    }
                });
    }

    void styleFilter(Button b, String key, boolean focused) {
        boolean selected = key.equals(activeFilter);
        int stateBits = (selected ? 1 : 0) | (focused ? 2 : 0);
        Integer prevState = renderedFilterStates.get(key);
        if (prevState != null && prevState.intValue() == stateBits) return;
        renderedFilterStates.put(key, Integer.valueOf(stateBits));
        b.setSelected(selected);
        b.setTypeface(null, (selected || focused) ? Typeface.BOLD : Typeface.NORMAL);
        if (a.isTvDevice()) {
            GradientDrawable bg = filterBgs.get(key);
            if (bg != null) {
                if (focused && selected) {
                    bg.setColor(Color.WHITE);
                    bg.setStroke(Math.max(2, a.dp(2.5f)), 0xff5fa8ff);
                } else if (focused) {
                    bg.setColor(0xff253042);
                    bg.setStroke(Math.max(2, a.dp(2.5f)), Color.WHITE);
                } else if (selected) {
                    bg.setColor(BG_FILTER_SELECTED);
                    bg.setStroke(Math.max(1, a.dp(1.2f)), BORDER_FILTER_SELECTED);
                } else {
                    bg.setColor(BG_FILTER);
                    bg.setStroke(Math.max(1, a.dp(1)), 0x1effffff);
                }
            }
            if (focused && selected) {
                b.setTextColor(TEXT_ON_LIGHT);
            } else if (focused) {
                b.setTextColor(Color.WHITE);
            } else if (selected) {
                b.setTextColor(TEXT_PRIMARY);
            } else {
                b.setTextColor(TEXT_SECONDARY);
            }
        } else {
            FocusMotion.style(
                    a,
                    b,
                    focused,
                    selected ? 0xff465c76 : 0xff272f3a,
                    MainActivity.WHITE,
                    17,
                    selected ? MainActivity.WHITE : 0xffc2cbd7,
                    MainActivity.DARK,
                    true,
                    1.035f);
        }
    }

    boolean hasVerification() {
        for (SourceResult result : results.values())
            if (result.outcome == SearchCoordinator.Outcome.VERIFICATION_REQUIRED) return true;
        return false;
    }

    private List<SourceResult> orderedSourceResults() {
        List<SourceResult> ordered = new ArrayList<>(results.size());
        Set<String> seen = new HashSet<>();
        for (Cms.Site site : searchSites) {
            if (site == null) continue;
            SourceResult sr = results.get(site.key);
            if (sr != null && seen.add(site.key)) ordered.add(sr);
        }
        for (SourceResult sr : results.values()) {
            if (sr != null && sr.site != null && seen.add(sr.site.key)) ordered.add(sr);
        }
        return ordered;
    }

    private List<TvSearchMatcher.RankedHit> collectRankedHitsForFilter(String filterKey) {
        if (submitted.isEmpty() || results.isEmpty()) return Collections.emptyList();
        String preferredSite = a.prefs == null ? "" : a.prefs.getString(Prefs.SELECTED_SITE, "");
        return TvSearchMatcher.collectAndRank(
                matchMode, submitted, orderedSourceResults(), filterKey, preferredSite, a.phonetic);
    }

    private List<TvSearchMatcher.RankedHit> collectCurrentRankedHits() {
        return collectRankedHitsForFilter(activeFilter);
    }

    void updateFilterLabels() {
        int totalVideos = -1;
        for (Map.Entry<String, Button> entry : filterButtons.entrySet()) {
            Button b = entry.getValue();
            String key = entry.getKey();
            if (a.isTvDevice()) {
                String suffix;
                if (key.isEmpty()) {
                    if (totalVideos < 0) {
                        totalVideos = collectRankedHitsForFilter("").size();
                    }
                    suffix =
                            finished < sourceCount
                                    ? (totalVideos > 0 ? " " + totalVideos : " · 搜索中")
                                    : totalVideos == 0
                                                    && (failed > 0
                                                            || timedOut > 0
                                                            || busy > 0
                                                            || hasVerification())
                                            ? " 0"
                                            : " " + totalVideos;
                } else {
                    SourceResult result = results.get(key);
                    boolean hasMore =
                            result != null && result.pages != null && result.pages.hasMore();
                    int siteCount = result == null ? 0 : result.videos.size();
                    suffix =
                            result == null
                                    ? " · 搜索中"
                                    : result.outcome == SearchCoordinator.Outcome.RESULT
                                                    || result.outcome
                                                            == SearchCoordinator.Outcome.EMPTY
                                            ? (hasMore
                                                    ? (siteCount == 0
                                                            ? " · 待加载"
                                                            : " " + siteCount + "+")
                                                    : " " + siteCount)
                                            : result.outcome == SearchCoordinator.Outcome.TIMEOUT
                                                    ? " · 超时"
                                                    : result.outcome
                                                                    == SearchCoordinator.Outcome
                                                                            .VERIFICATION_REQUIRED
                                                            ? " · 验证"
                                                            : result.outcome
                                                                            == SearchCoordinator
                                                                                    .Outcome.BUSY
                                                                    ? " · 未完成"
                                                                    : " · 失败";
                }
                String fullText = filterNames.get(key) + suffix;
                if (!fullText.equals(renderedFilterLabels.get(key))) {
                    renderedFilterLabels.put(key, fullText);
                    b.setText(fullText);
                    b.requestLayout();
                }
            }
            styleFilter(b, key, b.hasFocus());
        }
    }

    void resetGrid() {
        if (a.isTvDevice()) return;
        resultBody.removeAllViews();
        displayed.clear();
        displayedItems.clear();
        lastRow = null;
        resultGrid = a.vertical();
        resultGrid.setClipChildren(false);
        resultBody.addView(resultGrid);
        emptyResult = a.text("等待匹配结果…", 15, MainActivity.MUTED);
        emptyResult.setPadding(a.dp(8), a.dp(24), 0, 0);
        resultBody.addView(emptyResult);
        switchFuzzyBtn =
                a.navButton(
                        "切换到模糊搜索",
                        "search-switch-fuzzy",
                        () -> setMatchMode(TvSearchMatcher.Mode.FUZZY, true));
        switchFuzzyBtn.setVisibility(View.GONE);
        a.addButton(resultBody, switchFuzzyBtn);
        retrySource = a.navButton("重新搜索此源", "search-retry-source", this::retrySelected);
        retrySource.setVisibility(View.GONE);
        a.addButton(resultBody, retrySource);
        moreResults = a.navButton("显示更多结果", "search-more-results", this::triggerMoreResults);
        moreResults.setVisibility(View.GONE);
        a.addButton(resultBody, moreResults);
        resultHint = a.text("已显示当前取得的结果。", 12, MainActivity.MUTED);
        resultHint.setVisibility(View.GONE);
        resultBody.addView(resultHint);
    }

    void renderResults() {
        if (a.isTvDevice()) {
            renderTvResults();
            return;
        }
        renderLegacyResults();
    }

    /**
     * Projects the visible poster-wall slice from canonical {@code ranked} hits while protecting
     * the currently focused card from eviction or index shift during passive background arrivals
     * (such as a late single-source pagination callback after the user switched to "全部").
     *
     * <p>New higher-priority items remain in the source cache and {@code ranked}; they immediately
     * take rank #1 on explicit filter switches, pagination expansion on the active view, leaving
     * the poster wall, or active re-search.
     */
    static List<TvSearchMatcher.RankedHit> projectVisibleHits(
            List<TvSearchMatcher.RankedHit> ranked,
            int shownLimit,
            List<String> previousDisplayedKeys,
            String focusedKey,
            boolean preserveFocusedPosition) {
        if (ranked == null || ranked.isEmpty() || shownLimit <= 0) {
            return Collections.emptyList();
        }
        int showCount = Math.min(ranked.size(), shownLimit);
        List<TvSearchMatcher.RankedHit> canonical = new ArrayList<>(ranked.subList(0, showCount));
        if (!preserveFocusedPosition
                || focusedKey == null
                || focusedKey.isEmpty()
                || previousDisplayedKeys == null
                || previousDisplayedKeys.isEmpty()) {
            return canonical;
        }
        int oldFocusIdx = previousDisplayedKeys.indexOf(focusedKey);
        if (oldFocusIdx < 0 || oldFocusIdx >= showCount) {
            return canonical;
        }
        Map<String, TvSearchMatcher.RankedHit> byKey = new LinkedHashMap<>(ranked.size() * 2);
        for (TvSearchMatcher.RankedHit hit : ranked) {
            byKey.put(hit.stableKey(), hit);
        }
        if (!byKey.containsKey(focusedKey)) {
            return canonical;
        }
        int newFocusIdx = -1;
        for (int i = 0; i < canonical.size(); i++) {
            if (focusedKey.equals(canonical.get(i).stableKey())) {
                newFocusIdx = i;
                break;
            }
        }
        boolean prefixUnchanged = newFocusIdx == oldFocusIdx;
        if (prefixUnchanged) {
            for (int i = 0; i <= oldFocusIdx; i++) {
                if (!previousDisplayedKeys.get(i).equals(canonical.get(i).stableKey())) {
                    prefixUnchanged = false;
                    break;
                }
            }
        }
        if (prefixUnchanged) {
            return canonical;
        }
        List<TvSearchMatcher.RankedHit> stabilized = new ArrayList<>(showCount);
        Set<String> included = new LinkedHashSet<>(showCount * 2);
        for (String prevKey : previousDisplayedKeys) {
            if (stabilized.size() >= showCount) break;
            TvSearchMatcher.RankedHit hit = byKey.get(prevKey);
            if (hit != null && included.add(prevKey)) {
                stabilized.add(hit);
            }
        }
        for (TvSearchMatcher.RankedHit hit : ranked) {
            if (stabilized.size() >= showCount) break;
            if (included.add(hit.stableKey())) {
                stabilized.add(hit);
            }
        }
        return stabilized;
    }

    private static boolean sameHitOrder(
            List<TvSearchMatcher.RankedHit> a, List<TvSearchMatcher.RankedHit> b, int count) {
        if (a == null || b == null || a.size() < count || b.size() < count) return false;
        for (int i = 0; i < count; i++) {
            if (!a.get(i).stableKey().equals(b.get(i).stableKey())) return false;
        }
        return true;
    }

    private void renderTvResults() {
        if (tvResultRecycler == null || tvResultAdapter == null) return;
        long renderStart = android.os.SystemClock.elapsedRealtime();
        if (submitted.isEmpty()) {
            deferredRerankPending = false;
            if (tvResultRecycler != null) tvResultRecycler.setVisibility(View.GONE);
            if (tvStateContainer != null) tvStateContainer.setVisibility(View.GONE);
            if (tvFooterRow != null) tvFooterRow.setVisibility(View.GONE);
            if (filterScrollView != null) filterScrollView.setVisibility(View.GONE);
            updateResultHeader();
            return;
        }
        if (tvRecentScroll != null) tvRecentScroll.setVisibility(View.GONE);
        if (tvRecentContainer != null) tvRecentContainer.setVisibility(View.GONE);
        if (filterButtons.isEmpty() && sourceCount > 0) renderFilters();
        renderPasses++;

        // Preserve focus strictly on the same siteKey:vodId without letting slow arrivals evict or
        // shift it!
        String currentWallFocusTag = focusedTag(tvResultRecycler);
        boolean hadWallFocus = currentWallFocusTag != null;
        String currentWallFocusKey =
                hadWallFocus && currentWallFocusTag.startsWith("global-result:")
                        ? currentWallFocusTag.substring("global-result:".length())
                        : "";
        boolean preserveFocusedPosition =
                hadWallFocus && !restoringResults && !pendingPaginationFocus && !focusNewResults;

        List<TvSearchMatcher.RankedHit> ranked = collectCurrentRankedHits();
        int available = ranked.size();
        int showCount = Math.min(available, shownLimit);
        List<TvSearchMatcher.RankedHit> visible =
                projectVisibleHits(
                        ranked,
                        shownLimit,
                        new ArrayList<>(displayed),
                        currentWallFocusKey,
                        preserveFocusedPosition);
        deferredRerankPending =
                preserveFocusedPosition
                        && showCount > 0
                        && !sameHitOrder(visible, ranked, showCount);

        displayed.clear();
        displayedItems.clear();
        for (int i = 0; i < visible.size(); i++) {
            TvSearchMatcher.RankedHit hit = visible.get(i);
            displayed.add(hit.stableKey());
            if (hit.site != null && hit.video != null) {
                displayedItems.add(new TvSearchBudget.ProtectedItem(hit.site.key, hit.video.id));
            }
        }

        tvResultAdapter.submitList(visible);

        if (visible.isEmpty()) {
            tvResultRecycler.setVisibility(View.GONE);
            tvStateContainer.setVisibility(View.VISIBLE);
            bindEmptyOrErrorState();
        } else {
            tvStateContainer.setVisibility(View.GONE);
            tvResultRecycler.setVisibility(View.VISIBLE);
            if (restoringResults) {
                restoringResults = false;
                String targetTag = resolveResumeFocusTag();
                if (savedRecyclerPos >= 0 && savedRecyclerPos < visible.size()) {
                    tvResultLayout.scrollToPositionWithOffset(
                            savedRecyclerPos, savedRecyclerOffset);
                }
                if (targetTag != null && !targetTag.isEmpty()) {
                    int idx = tvResultAdapter.indexOfTag(targetTag);
                    if (idx >= 0) focusCardAt(idx);
                }
            } else if (pendingPaginationFocus) {
                pendingPaginationFocus = false;
                int targetIdx =
                        resolvePaginationFocusIndex(
                                visible,
                                pendingPaginationPrevKeys,
                                pendingPaginationTargetIndex,
                                pendingPaginationAnchorKey);
                pendingPaginationPrevKeys = Collections.emptySet();
                pendingPaginationTargetIndex = -1;
                pendingPaginationAnchorKey = "";
                if (targetIdx >= 0 && targetIdx < visible.size()) {
                    sourceFocus.put(
                            activeFilter, "global-result:" + visible.get(targetIdx).stableKey());
                    focusCardAt(targetIdx);
                }
            } else if (focusNewResults) {
                focusNewResults = false;
                focusCardAt(0);
            } else if (hadWallFocus) {
                // Only re-anchor if focus stayed inside wall and needs exact key preservation.
                int idx = tvResultAdapter.indexOfTag(currentWallFocusTag);
                if (idx >= 0 && tvResultRecycler.findFocus() == null) {
                    focusCardAt(idx);
                }
            }
        }

        boolean localMore = available > shownLimit;
        boolean allTabBudgetExhausted = isCurrentAllTabBudgetExhausted(available);
        SourceResult next = nextPageSource(available);
        boolean showMoreBtn = localMore || next != null || pageRequests.get() != null;
        moreResults.setVisibility(showMoreBtn ? View.VISIBLE : View.GONE);
        moreResults.setEnabled(pageRequests.get() == null || localMore);
        moreResults.setText(
                localMore
                        ? "显示更多已取得结果 (" + (available - shownLimit) + ")"
                        : pageRequests.get() != null
                                ? "正在读取更多结果…"
                                : next != null && next.site.key.equals(pageFailureSource)
                                        ? pageFailureReason + " · 重试"
                                        : "读取来源更多结果");

        boolean limited = false;
        boolean anySourceHasMore = false;
        for (SourceResult r : results.values()) {
            if ((activeFilter.isEmpty() || activeFilter.equals(r.site.key)) && r.pages != null) {
                if (r.pages.limited) limited = true;
                if (r.pages.hasMore()) anySourceHasMore = true;
            }
        }
        boolean showHint =
                !localMore
                        && next == null
                        && (allTabBudgetExhausted || finished >= sourceCount)
                        && !visible.isEmpty();
        int currentGlobalCap = TvSearchBudget.globalCap(a.isTvDevice(), isLowRamTv());
        resultHint.setText(
                allTabBudgetExhausted && anySourceHasMore
                        ? "已达全部结果内存上限（" + currentGlobalCap + " 条），请切换到顶部具体来源继续加载更多"
                        : globalBudgetCapped && activeFilter.isEmpty()
                                ? "已按电视内存上限保留精选结果，可切换来源继续查找"
                                : limited ? "当前来源已达内存保留上限，请缩小关键词" : "已显示全部匹配结果");
        resultHint.setVisibility(showHint ? View.VISIBLE : View.GONE);
        tvFooterRow.setVisibility((showMoreBtn || showHint) ? View.VISIBLE : View.GONE);

        updateResultHeader();
        long renderElapsed = android.os.SystemClock.elapsedRealtime() - renderStart;
        totalRenderUiMs += renderElapsed;
        if (renderElapsed > maxRenderUiMs) maxRenderUiMs = renderElapsed;
    }

    private void bindEmptyOrErrorState() {
        SourceResult selected = results.get(activeFilter);
        boolean selectedDeferred =
                selected != null && selected.pages != null && selected.pages.hasMore();
        boolean allFailed = activeFilter.isEmpty() && allSourcesFailed();
        boolean doneAll = finished >= sourceCount && sourceCount > 0;

        boolean showSwitchFuzzy = false;
        boolean showRetryAll = false;
        boolean showRetryOne = false;

        if (sourceCount == 0) {
            emptyResult.setText("没有可搜索来源，请先在设置中导入配置并启用片源。");
        } else if (!activeFilter.isEmpty()) {
            if (selected == null) {
                emptyResult.setText("正在等待此来源的" + matchMode.label + "结果…");
            } else if (selectedDeferred) {
                emptyResult.setText(
                        pageRequests.get() != null ? "正在读取此来源的后续分页…" : "当前页已过滤无关项，此来源仍有后续分页可继续查找。");
            } else if (selected.outcome == SearchCoordinator.Outcome.VERIFICATION_REQUIRED) {
                emptyResult.setText("此片源搜索需要完成网站验证码，暂时无法返回结果。可切换其他来源或重试。");
                showRetryOne = true;
            } else if (selected.outcome == SearchCoordinator.Outcome.FAILED) {
                emptyResult.setText("此源请求失败或返回无效响应，并非确认无内容。可重试或切换其他来源。");
                showRetryOne = true;
            } else if (selected.outcome == SearchCoordinator.Outcome.TIMEOUT) {
                emptyResult.setText("此源搜索超时，可单独重试。");
                showRetryOne = true;
            } else if (selected.outcome == SearchCoordinator.Outcome.BUSY) {
                emptyResult.setText("此源尚未完成，可单独重试。");
                showRetryOne = true;
            } else if (matchMode == TvSearchMatcher.Mode.EXACT) {
                emptyResult.setText("此来源没有与“" + submitted + "”完整匹配的片名。");
                showSwitchFuzzy = true;
                showRetryOne = true;
            } else {
                emptyResult.setText("此来源已响应，但没有与“" + submitted + "”相关的结果。");
                showRetryOne = true;
            }
        } else {
            // "全部" filter active
            if (!doneAll) {
                emptyResult.setText(
                        "正在"
                                + matchMode.label
                                + "全部 "
                                + sourceCount
                                + " 个来源（已完成 "
                                + finished
                                + "/"
                                + sourceCount
                                + "）…");
            } else if (allFailed) {
                emptyResult.setText("全部可用来源请求失败或超时，并非确认没有内容。请检查网络后重试。");
                showRetryAll = true;
            } else if (nextPageSource() != null) {
                emptyResult.setText("当前页结果均不符合匹配规则，仍有来源包含后续分页，可点击下方继续查找。");
                showSwitchFuzzy = (matchMode == TvSearchMatcher.Mode.EXACT);
            } else if (matchMode == TvSearchMatcher.Mode.EXACT) {
                emptyResult.setText(
                        "未找到与“" + submitted + "”完整匹配的片名。\n如需匹配续集、别名扩展、片名片段或拼音首字母，可切换到模糊搜索。");
                showSwitchFuzzy = true;
            } else {
                emptyResult.setText("未找到与“" + submitted + "”相关的片源结果，可尝试更换或缩短关键词。");
            }
        }

        if (switchFuzzyBtn != null) {
            switchFuzzyBtn.setVisibility(showSwitchFuzzy ? View.VISIBLE : View.GONE);
        }
        if (retryAllBtn != null) {
            retryAllBtn.setVisibility(showRetryAll ? View.VISIBLE : View.GONE);
        }
        if (retrySource != null) {
            retrySource.setVisibility(showRetryOne ? View.VISIBLE : View.GONE);
            retrySource.setEnabled(retryCoordinator == null);
        }
    }

    private void renderLegacyResults() {
        if (resultGrid == null) return;
        long renderStart = android.os.SystemClock.elapsedRealtime();
        if (filterButtons.isEmpty()) renderFilters();
        renderPasses++;
        List<TvSearchMatcher.RankedHit> ranked = collectCurrentRankedHits();
        int available = ranked.size(), added = 0;
        boolean remaining = false;
        for (int i = 0; i < ranked.size(); i++) {
            if (i + 1 > shownLimit) continue;
            TvSearchMatcher.RankedHit hit = ranked.get(i);
            String key = hit.stableKey();
            if (displayed.contains(key)) continue;
            if (added >= 4) {
                remaining = true;
                continue;
            }
            if (displayed.size() % columns == 0 || lastRow == null) {
                lastRow = a.row();
                lastRow.setGravity(Gravity.TOP);
                lastRow.setClipChildren(false);
                resultGrid.addView(lastRow);
                for (int column = 0; column < columns; column++) {
                    LinearLayout.LayoutParams blank = new LinearLayout.LayoutParams(0, 1, 1);
                    blank.setMargins(a.dp(3), a.dp(3), a.dp(8), a.dp(13));
                    lastRow.addView(new View(a), blank);
                }
            }
            LinearLayout card = posterCards.get(key);
            if (card == null) {
                card = makeCard(hit.site, hit.video);
                posterCards.put(key, card);
            }
            if (card.getParent() instanceof ViewGroup)
                ((ViewGroup) card.getParent()).removeView(card);
            int column = displayed.size() % columns;
            LinearLayout.LayoutParams cell = new LinearLayout.LayoutParams(0, -2, 1);
            cell.setMargins(a.dp(3), a.dp(3), a.dp(8), a.dp(13));
            if (column < lastRow.getChildCount()) {
                lastRow.removeViewAt(column);
                lastRow.addView(card, column, cell);
            } else {
                lastRow.addView(card, cell);
            }
            displayed.add(key);
            if (hit.site != null && hit.video != null) {
                displayedItems.add(new TvSearchBudget.ProtectedItem(hit.site.key, hit.video.id));
            }
            added++;
            if (focusNewResults) {
                card.requestFocus();
                focusNewResults = false;
            }
        }
        emptyResult.setVisibility(displayed.isEmpty() ? View.VISIBLE : View.GONE);
        if (displayed.isEmpty()) {
            bindEmptyOrErrorState();
        } else {
            if (switchFuzzyBtn != null) switchFuzzyBtn.setVisibility(View.GONE);
            if (retrySource != null) retrySource.setVisibility(View.GONE);
        }
        boolean localMore = available > shownLimit;
        boolean allTabBudgetExhausted = isCurrentAllTabBudgetExhausted(available);
        SourceResult next = nextPageSource(available);
        moreResults.setVisibility(
                localMore || next != null || pageRequests.get() != null ? View.VISIBLE : View.GONE);
        moreResults.setEnabled(pageRequests.get() == null || localMore);
        moreResults.setText(
                localMore
                        ? "显示更多已取得结果"
                        : pageRequests.get() != null
                                ? "正在读取更多结果…"
                                : next != null && next.site.key.equals(pageFailureSource)
                                        ? pageFailureReason + " · 重试"
                                        : "读取来源更多结果");
        if (allTabBudgetExhausted) {
            int currentGlobalCap = TvSearchBudget.globalCap(a.isTvDevice(), isLowRamTv());
            resultHint.setText("已达全部结果内存上限（" + currentGlobalCap + " 条），请切换到顶部具体来源继续加载更多");
        }
        resultHint.setVisibility(
                !remaining
                                && !localMore
                                && next == null
                                && (allTabBudgetExhausted || finished >= sourceCount)
                        ? View.VISIBLE
                        : View.GONE);
        if (!remaining && restoringResults) {
            restoringResults = false;
            View saved =
                    a.current == null || a.current.focus == null
                            ? null
                            : a.root.findViewWithTag(a.current.focus);
            if (saved != null) saved.requestFocus();
            final int scroll = savedResultScroll;
            final int serial = searchSerial;
            resultScroll.post(
                    () -> {
                        if (current() && serial == searchSerial) resultScroll.scrollTo(0, scroll);
                    });
        }
        long renderElapsed = android.os.SystemClock.elapsedRealtime() - renderStart;
        totalRenderUiMs += renderElapsed;
        if (renderElapsed > maxRenderUiMs) maxRenderUiMs = renderElapsed;
        if (remaining && pendingRender == null) {
            final int serial = searchSerial;
            pendingRender =
                    () -> {
                        pendingRender = null;
                        if (current() && serial == searchSerial) renderResults();
                    };
            a.ui.postDelayed(pendingRender, 16);
        }
    }

    private String formatCardMeta(Cms.Video video, Cms.Site site) {
        String sourceName = clean(site == null ? "" : site.name);
        String year = video == null || video.year == null ? "" : video.year.trim();
        String rawRemarks = video == null || video.remarks == null ? "" : video.remarks.trim();
        String remarks =
                rawRemarks.replaceFirst(
                        "^(\\d{4}-\\d{2}-\\d{2})\\s+\\d{2}:\\d{2}(?::\\d{2})?$", "$1");
        StringBuilder sb = new StringBuilder();
        if (!remarks.isEmpty()) sb.append(remarks);
        if (site != null && site.isNetdiskSite() && video != null) {
            String lowerRemarks = remarks.toLowerCase(Locale.ROOT);
            String combined =
                    ((video.title == null ? "" : video.title)
                                    + " "
                                    + (video.tag == null ? "" : video.tag))
                            .toLowerCase(Locale.ROOT);
            String quality = "";
            if ((combined.contains("4k") || combined.contains("2160"))
                    && !lowerRemarks.contains("4k")
                    && !lowerRemarks.contains("2160")) {
                quality = "4K";
            } else if ((combined.contains("原盘")
                            || combined.contains("iso")
                            || combined.contains("bdmv"))
                    && !lowerRemarks.contains("原盘")) {
                quality = "原盘";
            } else if ((combined.contains("hdr") || combined.contains("臻彩"))
                    && !lowerRemarks.contains("hdr")
                    && !lowerRemarks.contains("臻彩")) {
                quality = "HDR";
            } else if ((combined.contains("杜比") || combined.contains("dovi"))
                    && !lowerRemarks.contains("杜比")) {
                quality = "杜比";
            }
            if (!quality.isEmpty()) {
                if (sb.length() > 0) sb.append(" · ");
                sb.append(quality);
            }
        }
        if (!year.isEmpty()) {
            if (sb.length() > 0) sb.append(" · ");
            sb.append(year);
        }
        if (!sourceName.isEmpty()) {
            if (sb.length() > 0) sb.append(" · ");
            sb.append(sourceName);
        }
        return sb.toString();
    }

    private String formatNetdiskSpecLine(Cms.Video video) {
        if (video == null) return "";
        LinkedHashSet<String> tags = new LinkedHashSet<>();
        String remarks = video.remarks == null ? "" : video.remarks.trim();
        if (!remarks.isEmpty()) tags.add(remarks);
        String combined =
                ((video.title == null ? "" : video.title)
                                + " "
                                + remarks
                                + " "
                                + (video.tag == null ? "" : video.tag))
                        .toLowerCase(Locale.ROOT);
        if (combined.contains("4k") || combined.contains("2160")) tags.add("4K超清");
        if (combined.contains("原盘") || combined.contains("iso") || combined.contains("bdmv")) {
            tags.add("原盘");
        }
        if (combined.contains("remux")) tags.add("REMUX");
        if (combined.contains("高码")) tags.add("高码率");
        if (combined.contains("臻彩") || combined.contains("hdr10")) tags.add("HDR");
        if (combined.contains("杜比") || combined.contains("dovi") || combined.contains("atmos")) {
            tags.add("杜比视界/全景声");
        }
        if (combined.contains("60fps") || combined.contains("60帧") || combined.contains("高帧")) {
            tags.add("60帧");
        }
        if (tags.isEmpty()) return "网盘资源（点击查看目录文件）";
        StringBuilder out = new StringBuilder();
        for (String tag : tags) {
            if (out.length() > 0) out.append(" · ");
            out.append(tag);
        }
        return out.toString();
    }

    /**
     * Pre-baked GPU-lightweight theme shared across all TV search poster cards. Eliminates per-card
     * {@code setClipToOutline(true)} stencil clipping, {@code GradientDrawable} stroke tessellation,
     * and full-poster bilinear scaling on Mali-450 GPUs while keeping crisp rounded corners and
     * Apple TV focus rings.
     */
    private static final class TvSearchArtTheme {
        final int artW, artH;
        final int cornerSizePx;
        final float strokePx;
        final Rect cornerSrcTl = new Rect();
        final Rect cornerSrcTr = new Rect();
        final Rect cornerSrcBl = new Rect();
        final Rect cornerSrcBr = new Rect();
        final Paint placeholderPaint = new Paint();
        final Paint focusEdgePaint = new Paint();
        final Paint badgeBgPaint = new Paint();
        final Paint badgeTextPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final float badgePadH, badgePadV, badgeMargin, badgeBoxH, badgeBaseline;
        final Bitmap normalCornerAtlas;
        final Bitmap focusRingCornerAtlas;

        TvSearchArtTheme(MainActivity a, int artW, int artH) {
            this.artW = Math.max(1, artW);
            this.artH = Math.max(1, artH);
            int radius = Math.max(4, Math.min(a.dp(10), Math.min(this.artW, this.artH) / 3));
            this.cornerSizePx = radius;
            this.strokePx = Math.max(2f, a.dp(2.5f));

            cornerSrcTl.set(0, 0, radius, radius);
            cornerSrcTr.set(radius, 0, radius * 2, radius);
            cornerSrcBl.set(0, radius, radius, radius * 2);
            cornerSrcBr.set(radius, radius, radius * 2, radius * 2);

            placeholderPaint.setStyle(Paint.Style.FILL);
            placeholderPaint.setColor(0xff252c35);

            focusEdgePaint.setStyle(Paint.Style.FILL);
            focusEdgePaint.setColor(Color.WHITE);

            badgeBgPaint.setStyle(Paint.Style.FILL);
            badgeBgPaint.setColor(0xd010141c);

            float scaledDensity = a.getResources().getDisplayMetrics().scaledDensity;
            badgeTextPaint.setColor(0xfffbbf24);
            badgeTextPaint.setTypeface(Typeface.DEFAULT_BOLD);
            badgeTextPaint.setTextSize(10.5f * scaledDensity);
            Paint.FontMetrics fm = badgeTextPaint.getFontMetrics();
            this.badgePadH = a.dp(6);
            this.badgePadV = a.dp(2.5f);
            this.badgeMargin = a.dp(6);
            this.badgeBaseline = -fm.ascent;
            this.badgeBoxH = (fm.descent - fm.ascent) + badgePadV * 2f;

            this.normalCornerAtlas = buildCornerAtlas(radius, false);
            this.focusRingCornerAtlas = buildCornerAtlas(radius, true);
        }

        private Bitmap buildCornerAtlas(int r, boolean withFocusRing) {
            int full = r * 2;
            Bitmap bmp = Bitmap.createBitmap(full, full, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(bmp);
            c.drawColor(BG_PAGE);
            Paint clearPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
            clearPaint.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.CLEAR));
            c.drawRoundRect(new RectF(0f, 0f, full, full), r, r, clearPaint);
            if (withFocusRing) {
                Paint ringPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
                ringPaint.setStyle(Paint.Style.STROKE);
                ringPaint.setStrokeWidth(strokePx);
                ringPaint.setColor(Color.WHITE);
                float hs = strokePx * 0.5f;
                float innerR = Math.max(1f, r - hs);
                c.drawRoundRect(new RectF(hs, hs, full - hs, full - hs), innerR, innerR, ringPaint);
            }
            return bmp;
        }
    }

    /** Single leaf View replacing 5 nested poster/badge/clip/focus-ring Views per TV search card. */
    private static final class TvSearchPosterArtView extends View {
        TvSearchArtTheme t;
        final Paint posterPaint = new Paint(Paint.FILTER_BITMAP_FLAG);
        final Rect srcRect = new Rect();
        final RectF dstRect = new RectF();
        final RectF dstTl = new RectF();
        final RectF dstTr = new RectF();
        final RectF dstBl = new RectF();
        final RectF dstBr = new RectF();
        final RectF badgeRect = new RectF();
        Bitmap posterBitmap;
        boolean hasSrcRect;
        boolean artFocused;
        String badgeText = "";

        TvSearchPosterArtView(MainActivity a, TvSearchArtTheme theme) {
            super(a);
            applyThemeBounds(theme);
        }

        private void applyThemeBounds(TvSearchArtTheme theme) {
            this.t = theme;
            dstRect.set(0f, 0f, t.artW, t.artH);
            float cs = t.cornerSizePx;
            dstTl.set(0f, 0f, cs, cs);
            dstTr.set(t.artW - cs, 0f, t.artW, cs);
            dstBl.set(0f, t.artH - cs, cs, t.artH);
            dstBr.set(t.artW - cs, t.artH - cs, t.artW, t.artH);
            if (!badgeText.isEmpty()) {
                float tw = t.badgeTextPaint.measureText(badgeText);
                float bw = tw + t.badgePadH * 2f;
                badgeRect.set(
                        t.artW - t.badgeMargin - bw,
                        t.badgeMargin,
                        t.artW - t.badgeMargin,
                        t.badgeMargin + t.badgeBoxH);
            }
            if (posterBitmap != null && !posterBitmap.isRecycled()) {
                recomputeSrcRect(posterBitmap);
            }
        }

        void updateTheme(TvSearchArtTheme theme) {
            if (theme == null || theme == this.t) return;
            applyThemeBounds(theme);
            requestLayout();
            invalidate();
        }

        private void recomputeSrcRect(Bitmap bmp) {
            int bw = bmp.getWidth();
            int bh = bmp.getHeight();
            if (bw <= 0 || bh <= 0) {
                hasSrcRect = false;
                return;
            }
            float targetRatio = (float) t.artW / (float) Math.max(1, t.artH);
            float bmpRatio = (float) bw / (float) bh;
            if (bmpRatio > targetRatio) {
                int cropW = Math.max(1, Math.min(bw, Math.round(bh * targetRatio)));
                int left = (bw - cropW) / 2;
                srcRect.set(left, 0, left + cropW, bh);
            } else {
                int cropH =
                        Math.max(1, Math.min(bh, Math.round(bw / Math.max(0.01f, targetRatio))));
                int top = (bh - cropH) / 2;
                srcRect.set(0, top, bw, top + cropH);
            }
            hasSrcRect = true;
        }

        void clearPoster() {
            posterBitmap = null;
            hasSrcRect = false;
            badgeText = "";
            artFocused = false;
        }

        void setBadgeText(String text) {
            String next = text == null ? "" : text;
            if (next.equals(badgeText)) return;
            badgeText = next;
            if (!badgeText.isEmpty()) {
                float tw = t.badgeTextPaint.measureText(badgeText);
                float bw = tw + t.badgePadH * 2f;
                badgeRect.set(
                        t.artW - t.badgeMargin - bw,
                        t.badgeMargin,
                        t.artW - t.badgeMargin,
                        t.badgeMargin + t.badgeBoxH);
            }
            invalidate();
        }

        void setArtFocused(boolean focused) {
            if (this.artFocused == focused) return;
            this.artFocused = focused;
            invalidate();
        }

        void setPosterBitmap(Bitmap bmp) {
            if (this.posterBitmap == bmp) return;
            if (bmp == null || bmp.isRecycled() || bmp.getWidth() <= 0 || bmp.getHeight() <= 0) {
                this.posterBitmap = null;
                this.hasSrcRect = false;
                invalidate();
                return;
            }
            this.posterBitmap = bmp;
            int bw = bmp.getWidth();
            int bh = bmp.getHeight();
            float targetRatio = (float) t.artW / (float) Math.max(1, t.artH);
            float bmpRatio = (float) bw / (float) bh;
            if (bmpRatio > targetRatio) {
                int cropW = Math.max(1, Math.min(bw, Math.round(bh * targetRatio)));
                int left = (bw - cropW) / 2;
                srcRect.set(left, 0, left + cropW, bh);
            } else {
                int cropH =
                        Math.max(1, Math.min(bh, Math.round(bw / Math.max(0.01f, targetRatio))));
                int top = (bh - cropH) / 2;
                srcRect.set(0, top, bw, top + cropH);
            }
            this.hasSrcRect = true;
            invalidate();
        }

        @Override
        protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
            setMeasuredDimension(t.artW, t.artH);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            if (posterBitmap != null && !posterBitmap.isRecycled() && hasSrcRect) {
                canvas.drawBitmap(posterBitmap, srcRect, dstRect, posterPaint);
            } else {
                canvas.drawRect(dstRect, t.placeholderPaint);
            }
            if (!badgeText.isEmpty()) {
                canvas.drawRect(badgeRect, t.badgeBgPaint);
                canvas.drawText(
                        badgeText,
                        badgeRect.left + t.badgePadH,
                        badgeRect.top + t.badgePadV + t.badgeBaseline,
                        t.badgeTextPaint);
            }
            Bitmap corners = artFocused ? t.focusRingCornerAtlas : t.normalCornerAtlas;
            if (corners != null && !corners.isRecycled()) {
                canvas.drawBitmap(corners, t.cornerSrcTl, dstTl, null);
                canvas.drawBitmap(corners, t.cornerSrcTr, dstTr, null);
                canvas.drawBitmap(corners, t.cornerSrcBl, dstBl, null);
                canvas.drawBitmap(corners, t.cornerSrcBr, dstBr, null);
            }
            if (artFocused) {
                float cs = t.cornerSizePx;
                float sw = t.strokePx;
                canvas.drawRect(cs, 0f, t.artW - cs, sw, t.focusEdgePaint);
                canvas.drawRect(cs, t.artH - sw, t.artW - cs, t.artH, t.focusEdgePaint);
                canvas.drawRect(0f, cs, sw, t.artH - cs, t.focusEdgePaint);
                canvas.drawRect(t.artW - sw, cs, t.artW, t.artH - cs, t.focusEdgePaint);
            }
        }
    }

    /** Lightweight DiffUtil-backed RecyclerView adapter for TV 2:3 Apple TV poster wall. */
    private final class TvSearchPosterAdapter
            extends RecyclerView.Adapter<TvSearchPosterAdapter.CardHolder> {
        static final int VIEW_TYPE_POSTER = 0;
        static final int VIEW_TYPE_NETDISK_WIDE = 1;
        private final List<TvSearchMatcher.RankedHit> items = new ArrayList<>();
        private TvSearchArtTheme artTheme;
        private TvSearchArtTheme netdiskThumbTheme;

        private TvSearchArtTheme ensureArtTheme() {
            if (artTheme == null
                    || artTheme.artW != tvCardPosterWidthPx
                    || artTheme.artH != tvCardPosterHeightPx) {
                artTheme = new TvSearchArtTheme(a, tvCardPosterWidthPx, tvCardPosterHeightPx);
            }
            return artTheme;
        }

        private TvSearchArtTheme ensureNetdiskThumbTheme() {
            if (netdiskThumbTheme == null) {
                netdiskThumbTheme = new TvSearchArtTheme(a, a.dp(74), a.dp(106));
            }
            return netdiskThumbTheme;
        }

        @Override
        public int getItemViewType(int position) {
            return VIEW_TYPE_POSTER;
        }

        void refreshThemeAndSizes(RecyclerView rv) {
            TvSearchArtTheme theme = ensureArtTheme();
            if (rv == null) return;
            for (int i = 0; i < rv.getChildCount(); i++) {
                View child = rv.getChildAt(i);
                RecyclerView.ViewHolder vh = rv.getChildViewHolder(child);
                if (vh instanceof CardHolder) {
                    CardHolder h = (CardHolder) vh;
                    if (h.isWide) continue;
                    h.posterArt.updateTheme(theme);
                    ViewGroup.LayoutParams pLp = h.posterArt.getLayoutParams();
                    if (pLp != null) {
                        pLp.width = tvCardPosterWidthPx;
                        pLp.height = tvCardPosterHeightPx;
                        h.posterArt.setLayoutParams(pLp);
                    }
                    ViewGroup.LayoutParams tLp = h.title.getLayoutParams();
                    if (tLp != null) {
                        tLp.width = tvCardPosterWidthPx;
                        h.title.setLayoutParams(tLp);
                    }
                    ViewGroup.LayoutParams mLp = h.meta.getLayoutParams();
                    if (mLp != null) {
                        mLp.width = tvCardPosterWidthPx;
                        h.meta.setLayoutParams(mLp);
                    }
                }
            }
            rv.requestLayout();
        }

        void clearAll() {
            int n = items.size();
            if (n == 0) return;
            items.clear();
            notifyItemRangeRemoved(0, n);
        }

        void submitList(final List<TvSearchMatcher.RankedHit> next) {
            final List<TvSearchMatcher.RankedHit> oldList = new ArrayList<>(items);
            final List<TvSearchMatcher.RankedHit> newList =
                    next == null ? Collections.emptyList() : next;
            DiffUtil.DiffResult diff =
                    DiffUtil.calculateDiff(
                            new DiffUtil.Callback() {
                                @Override
                                public int getOldListSize() {
                                    return oldList.size();
                                }

                                @Override
                                public int getNewListSize() {
                                    return newList.size();
                                }

                                @Override
                                public boolean areItemsTheSame(int oldPos, int newPos) {
                                    return oldList.get(oldPos)
                                            .hitId()
                                            .equals(newList.get(newPos).hitId());
                                }

                                @Override
                                public boolean areContentsTheSame(int oldPos, int newPos) {
                                    TvSearchMatcher.RankedHit o = oldList.get(oldPos);
                                    TvSearchMatcher.RankedHit n = newList.get(newPos);
                                    return TextUtils.equals(o.video.title, n.video.title)
                                            && TextUtils.equals(o.video.year, n.video.year)
                                            && TextUtils.equals(o.video.remarks, n.video.remarks)
                                            && TextUtils.equals(o.video.tag, n.video.tag)
                                            && TextUtils.equals(o.video.poster, n.video.poster)
                                            && TextUtils.equals(o.site.name, n.site.name);
                                }
                            },
                            true);
            items.clear();
            items.addAll(newList);
            diff.dispatchUpdatesTo(this);
        }

        int indexOfTag(String fullTag) {
            if (fullTag == null) return -1;
            for (int i = 0; i < items.size(); i++) {
                if (("global-result:" + items.get(i).stableKey()).equals(fullTag)) return i;
            }
            return -1;
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        @Override
        public CardHolder onCreateViewHolder(ViewGroup parent, int viewType) {
            if (viewType == VIEW_TYPE_NETDISK_WIDE) {
                LinearLayout card = a.row();
                card.setGravity(Gravity.CENTER_VERTICAL);
                card.setClipChildren(true);
                card.setClipToPadding(false);
                card.setPadding(a.dp(10), a.dp(10), a.dp(12), a.dp(10));
                GradientDrawable wideBg = new GradientDrawable();
                wideBg.setCornerRadius(a.dp(10));
                wideBg.setColor(0xaa131924);
                wideBg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);
                card.setBackground(wideBg);
                card.setFocusable(true);
                card.setFocusableInTouchMode(true);
                card.setClickable(true);
                UiCompat.setDefaultFocusHighlightEnabled(card, false);

                TvSearchArtTheme thumbTheme = ensureNetdiskThumbTheme();
                TvSearchPosterArtView posterArt = new TvSearchPosterArtView(a, thumbTheme);
                LinearLayout.LayoutParams posterLp =
                        new LinearLayout.LayoutParams(thumbTheme.artW, thumbTheme.artH);
                card.addView(posterArt, posterLp);

                LinearLayout infoCol = a.vertical();
                LinearLayout.LayoutParams colLp = new LinearLayout.LayoutParams(0, -2, 1f);
                colLp.leftMargin = a.dp(12);
                card.addView(infoCol, colLp);

                TextView title = a.text("", 14f, 0xffeef4fc);
                title.setTypeface(null, Typeface.BOLD);
                title.setMaxLines(3);
                title.setEllipsize(TextUtils.TruncateAt.END);
                title.setLineSpacing(a.dp(1.5f), 1f);
                title.setIncludeFontPadding(false);
                infoCol.addView(title, new LinearLayout.LayoutParams(-1, -2));

                TextView specs = a.text("", 12f, 0xfffbbf24);
                specs.setTypeface(null, Typeface.BOLD);
                specs.setMaxLines(2);
                specs.setEllipsize(TextUtils.TruncateAt.END);
                specs.setIncludeFontPadding(false);
                LinearLayout.LayoutParams specsLp = new LinearLayout.LayoutParams(-1, -2);
                specsLp.topMargin = a.dp(5);
                infoCol.addView(specs, specsLp);

                TextView meta = a.text("", 11.5f, TEXT_MUTED);
                meta.setSingleLine(true);
                meta.setEllipsize(TextUtils.TruncateAt.END);
                meta.setIncludeFontPadding(false);
                LinearLayout.LayoutParams metaLp = new LinearLayout.LayoutParams(-1, -2);
                metaLp.topMargin = a.dp(4);
                infoCol.addView(meta, metaLp);

                RecyclerView.LayoutParams cellLp =
                        new RecyclerView.LayoutParams(
                                ViewGroup.LayoutParams.MATCH_PARENT,
                                ViewGroup.LayoutParams.WRAP_CONTENT);
                cellLp.setMargins(a.dp(4), a.dp(2), a.dp(4), a.dp(8));
                card.setLayoutParams(cellLp);

                return new CardHolder(card, wideBg, posterArt, title, specs, meta, true);
            }

            LinearLayout card = a.vertical();
            card.setGravity(Gravity.CENTER_HORIZONTAL);
            card.setClipChildren(true);
            card.setClipToPadding(false);
            card.setPadding(a.dp(5), a.dp(5), a.dp(5), a.dp(10));
            card.setFocusable(true);
            card.setFocusableInTouchMode(true);
            card.setClickable(true);
            UiCompat.setDefaultFocusHighlightEnabled(card, false);

            TvSearchPosterArtView posterArt = new TvSearchPosterArtView(a, ensureArtTheme());
            LinearLayout.LayoutParams posterLp =
                    new LinearLayout.LayoutParams(tvCardPosterWidthPx, tvCardPosterHeightPx);
            posterLp.gravity = Gravity.CENTER_HORIZONTAL;
            card.addView(posterArt, posterLp);

            TextView title = a.text("", 13.5f, 0xffd7e0ec);
            title.setTypeface(null, Typeface.BOLD);
            title.setMaxLines(2);
            title.setEllipsize(TextUtils.TruncateAt.END);
            title.setLineSpacing(a.dp(1.5f), 1f);
            title.setIncludeFontPadding(false);
            LinearLayout.LayoutParams titleLp =
                    new LinearLayout.LayoutParams(tvCardPosterWidthPx, -2);
            titleLp.topMargin = a.dp(7);
            card.addView(title, titleLp);

            TextView meta = a.text("", 11.5f, TEXT_MUTED);
            meta.setSingleLine(true);
            meta.setEllipsize(TextUtils.TruncateAt.END);
            meta.setIncludeFontPadding(false);
            LinearLayout.LayoutParams metaLp =
                    new LinearLayout.LayoutParams(tvCardPosterWidthPx, -2);
            metaLp.topMargin = a.dp(3);
            card.addView(meta, metaLp);

            RecyclerView.LayoutParams cellLp =
                    new RecyclerView.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT);
            cellLp.setMargins(0, 0, 0, a.dp(4));
            card.setLayoutParams(cellLp);

            return new CardHolder(card, null, posterArt, title, null, meta, false);
        }

        @Override
        public void onBindViewHolder(final CardHolder holder, int position) {
            final TvSearchMatcher.RankedHit hit = items.get(position);
            final Cms.Site site = hit.site;
            final Cms.Video video = hit.video;
            final String cardTag = "global-result:" + hit.stableKey();

            holder.boundKey = hit.stableKey();
            final int seq = ++holder.bindSeq;
            holder.itemView.setTag(cardTag);
            holder.title.setText(video.title == null ? "" : video.title);
            holder.meta.setText(formatCardMeta(video, site));
            if (holder.specs != null) {
                holder.specs.setText(formatNetdiskSpecLine(video));
            }
            holder.itemView.setContentDescription(
                    (video.title == null ? "" : video.title) + " " + formatCardMeta(video, site));

            final int artW = holder.isWide ? ensureNetdiskThumbTheme().artW : tvCardPosterWidthPx;
            final int artH = holder.isWide ? ensureNetdiskThumbTheme().artH : tvCardPosterHeightPx;
            final int scope = searchArtworkScope;
            ImageLoader.unbindBitmapTarget(holder.posterArt);
            Bitmap cached = ImageLoader.cachedPosterBitmap(a, video.poster, artW, artH);
            holder.posterArt.setPosterBitmap(cached);
            if (cached == null && video.poster != null && !video.poster.isEmpty()) {
                ImageLoader.loadPosterBitmap(
                        a,
                        video.poster,
                        artW,
                        artH,
                        pageTicket,
                        scope,
                        holder.posterArt,
                        bmp -> {
                            if (current()
                                    && holder.bindSeq == seq
                                    && scope == searchArtworkScope
                                    && !ImageLoader.isScopeCancelled(scope)) {
                                holder.posterArt.setPosterBitmap(bmp);
                            }
                        });
            }

            // Show immediate / RAM-cached Douban rating with zero background HTTP thread storm
            // during active TV remote browsing.
            String badgeLabel = "";
            if (!SourceController.isConfigOrNetdiskActionCard(site, video)) {
                double score = DoubanScoreRepository.extractImmediateScore(video);
                if (score < 2.0 && !a.privateMode) {
                    String lookupKey =
                            DoubanScoreRepository.normalizeLookupKey(video.title, video.year);
                    DoubanScoreRepository.CacheEntry entry =
                            DoubanScoreRepository.getCached(a, lookupKey);
                    if (entry != null && entry.score >= 2.0) {
                        score = entry.score;
                    }
                }
                if (score >= 2.0) {
                    badgeLabel = DoubanScoreRepository.formatBadgeText(score);
                }
            }
            holder.posterArt.setBadgeText(badgeLabel);

            holder.applyFocusVisual(holder.itemView.hasFocus(), false);

            final String query = submitted;
            holder.itemView.setOnClickListener(
                    v -> {
                        if (!current()) return;
                        if (!a.isSiteEnabledInMultiSource(site.key)) {
                            a.toast("该片源所属订阅已停用，请先重新启用来源");
                            return;
                        }
                        sourceFocus.put(activeFilter, cardTag);
                        rememberSourcePosition();
                        saveHistory(query);
                        a.openListing(site, video);
                    });
            holder.itemView.setOnFocusChangeListener(
                    (v, focused) -> {
                        if (focused) {
                            sourceFocus.put(activeFilter, cardTag);
                            deferPendingPhoneticLearn();
                        } else if (deferredRerankPending && tvResultRecycler != null) {
                            tvResultRecycler.post(
                                    () -> {
                                        if (current()
                                                && deferredRerankPending
                                                && focusedTag(tvResultRecycler) == null) {
                                            renderTvResults();
                                        }
                                    });
                        }
                        holder.applyFocusVisual(focused, !a.reduced);
                    });
            holder.itemView.setOnKeyListener(
                    (v, keyCode, event) -> {
                        if (event.getAction() != KeyEvent.ACTION_DOWN) return false;
                        int pos = holder.getBindingAdapterPosition();
                        if (pos == RecyclerView.NO_POSITION) return false;
                        GridLayoutManager.SpanSizeLookup ssl =
                                tvResultLayout != null ? tvResultLayout.getSpanSizeLookup() : null;
                        int spanIdx =
                                ssl != null ? ssl.getSpanIndex(pos, columns) : (pos % columns);
                        int spanSize = ssl != null ? ssl.getSpanSize(pos) : 1;
                        int groupIdx =
                                ssl != null ? ssl.getSpanGroupIndex(pos, columns) : (pos / columns);
                        if (keyCode == KeyEvent.KEYCODE_DPAD_UP && groupIdx == 0) {
                            Button tab = filterButtons.get(activeFilter);
                            if (tab != null && tab.isShown()) {
                                tab.requestFocus();
                                return true;
                            }
                        } else if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT && spanIdx == 0) {
                            return restoreLeftFocus();
                        } else if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                                && (spanIdx + spanSize >= columns || pos == items.size() - 1)) {
                            return true;
                        } else if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
                            int lastGroup =
                                    ssl != null
                                            ? ssl.getSpanGroupIndex(items.size() - 1, columns)
                                            : ((items.size() - 1) / columns);
                            if (groupIdx >= lastGroup
                                    && moreResults != null
                                    && moreResults.getVisibility() == View.VISIBLE) {
                                moreResults.requestFocus();
                                return true;
                            }
                        }
                        return false;
                    });
        }

        @Override
        public void onViewRecycled(CardHolder holder) {
            super.onViewRecycled(holder);
            holder.bindSeq++;
            ImageLoader.unbindBitmapTarget(holder.posterArt);
            holder.posterArt.clearPoster();
            holder.itemView.setOnClickListener(null);
            holder.itemView.setOnFocusChangeListener(null);
            holder.itemView.setOnKeyListener(null);
        }

        final class CardHolder extends RecyclerView.ViewHolder {
            final GradientDrawable wideBg;
            final TvSearchPosterArtView posterArt;
            final TextView title;
            final TextView specs;
            final TextView meta;
            final boolean isWide;
            String boundKey = "";
            int bindSeq;

            CardHolder(
                    View itemView,
                    GradientDrawable wideBg,
                    TvSearchPosterArtView posterArt,
                    TextView title,
                    TextView specs,
                    TextView meta,
                    boolean isWide) {
                super(itemView);
                this.wideBg = wideBg;
                this.posterArt = posterArt;
                this.title = title;
                this.specs = specs;
                this.meta = meta;
                this.isWide = isWide;
            }

            void applyFocusVisual(boolean focused, boolean animate) {
                // Single-View pre-baked rounded focus ring + crisp text luminance contrast: zero
                // layout passes, zero stencil clip masks, zero path tessellation, zero texture
                // scaling.
                posterArt.setArtFocused(focused);
                if (wideBg != null) {
                    wideBg.setColor(focused ? 0xff1c2536 : 0xaa131924);
                    wideBg.setStroke(
                            Math.max(1, a.dp(focused ? 2f : 1f)),
                            focused ? 0xff5fa8ff : 0x26ffffff);
                }
                title.setTextColor(focused ? TEXT_PRIMARY : 0xffcfd9e6);
                if (specs != null) {
                    specs.setTextColor(focused ? 0xfffde68a : 0xfffbbf24);
                }
                meta.setTextColor(focused ? 0xffc6d4e6 : TEXT_MUTED);
            }
        }
    }

    LinearLayout makeCard(final Cms.Site site, final Cms.Video video) {
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));
        ImageView poster = new ImageView(a);
        if (a.isTvDevice()) TvV17PosterCard.artwork(a, poster);
        else {
            poster.setScaleType(ImageView.ScaleType.CENTER_CROP);
            poster.setBackground(a.bg(0xff25252a, 9));
            poster.setClipToOutline(true);
        }
        int posterWidth = 110;
        LinearLayout.LayoutParams posterSize =
                new LinearLayout.LayoutParams(a.dp(posterWidth), a.dp(posterWidth * 3 / 2));
        posterSize.gravity = Gravity.CENTER_HORIZONTAL;
        boolean badge = !SourceController.isConfigOrNetdiskActionCard(site, video);
        int scope = searchArtworkScope;
        FrameLayout posterWrap =
                TvV17PosterCard.wrapArtworkWithDoubanBadge(a, poster, video, badge, scope);
        card.addView(posterWrap, posterSize);
        ImageLoader.poster(a, video.poster, poster, false, scope);
        TextView title = a.text(video.title, 14, MainActivity.WHITE);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setPadding(a.dp(2), a.dp(6), 0, 0);
        card.addView(title);
        TextView origin = a.text(formatCardMeta(video, site), 11, MainActivity.MUTED);
        origin.setSingleLine(true);
        origin.setEllipsize(TextUtils.TruncateAt.END);
        card.addView(origin);
        final String cardResultKey = TvSearchMatcher.stableKey(site.key, video.id);
        card.setTag("global-result:" + cardResultKey);
        card.setFocusable(a.isTvDevice());
        card.setFocusableInTouchMode(a.isTvDevice());
        card.setClickable(true);
        if (a.isTvDevice()) TvFocusFrame.attachCard(card, "search-results-grid");
        a.pressFeedback(card);
        final String query = submitted;
        card.setOnClickListener(
                view -> {
                    if (!current()) return;
                    if (!a.isSiteEnabledInMultiSource(site.key)) {
                        a.toast("该片源所属订阅已停用，请先重新启用来源");
                        return;
                    }
                    saveHistory(query);
                    a.openListing(site, video);
                });
        card.setOnFocusChangeListener(
                (view, selected) -> {
                    if (selected) sourceFocus.put(activeFilter, String.valueOf(card.getTag()));
                    if (a.isTvDevice()) TvV17PosterCard.focus(a, card, title, selected);
                    else
                        FocusMotion.style(
                                a,
                                card,
                                selected,
                                Color.TRANSPARENT,
                                0xff393940,
                                11,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.035f);
                });
        return card;
    }

    String focusedTag(ViewGroup group) {
        if (group == null) return null;
        View focus = a.getCurrentFocus();
        if (focus == null || focus.getTag() == null) return null;
        View parent = focus;
        while (parent != null) {
            if (parent == group) return String.valueOf(focus.getTag());
            if (!(parent.getParent() instanceof View)) break;
            parent = (View) parent.getParent();
        }
        return null;
    }

    String clean(String title) {
        return title == null
                ? "来源"
                : title.replaceAll("[\\p{So}\\p{Cs}]", "").replace('┃', ' ').trim();
    }

    private final Object qrLock = new Object();
    private static String cachedQrKey = "";
    private static Bitmap cachedQrBitmap;

    String ensureQrServer(boolean forceRefresh) throws Exception {
        synchronized (qrLock) {
            if (!forceRefresh
                    && qrServer != null
                    && !qrServer.expired()
                    && qrAddress != null
                    && !qrAddress.isEmpty()) {
                return qrAddress;
            }
            closeQrServer();
            String ip = PhoneConfigDialog.lanAddress();
            final int generation = qrGeneration;
            qrServer =
                    new SearchInputServer(
                            new SearchInputServer.Listener() {
                                @Override
                                public void onKeyword(String keyword, boolean submitNow) {
                                    a.ui.post(
                                            () -> {
                                                if (!current()
                                                        || keyboard == null
                                                        || generation != qrGeneration
                                                        || qrServer == null
                                                        || qrServer.expired()) return;
                                                if (submitNow) {
                                                    if (qrDialog != null && qrDialog.isShowing()) {
                                                        qrDialog.dismiss();
                                                    }
                                                    TvQrInputHelper.dismissActive();
                                                }
                                                imeDraft.clear();
                                                keyboard.set(keyword == null ? "" : keyword);
                                                changed();
                                                if (submitNow
                                                        && keyword != null
                                                        && !keyword.isEmpty()) {
                                                    submit(true);
                                                    a.toast("已接收手机输入：" + keyword);
                                                } else if (keyword == null || keyword.isEmpty()) {
                                                    a.toast("已清空电视搜索框");
                                                } else {
                                                    a.toast("已同步文字：" + keyword);
                                                }
                                            });
                                }

                                @Override
                                public List<String> recentKeywords() {
                                    return !current() || generation != qrGeneration || a.privateMode
                                            ? Collections.emptyList()
                                            : history();
                                }

                                @Override
                                public String currentKeyword() {
                                    return !current()
                                                    || generation != qrGeneration
                                                    || keyboard == null
                                            ? ""
                                            : keyboard.query().trim();
                                }
                            });
            qrAddress = qrServer.address(ip);
            return qrAddress;
        }
    }

    Bitmap createQrBitmap(String content, int sizePx) throws Exception {
        int px = Math.max(96, sizePx);
        String key = content + "|" + px;
        synchronized (qrLock) {
            if (key.equals(cachedQrKey) && cachedQrBitmap != null && !cachedQrBitmap.isRecycled()) {
                return cachedQrBitmap;
            }
        }
        BitMatrix matrix = new QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, px, px);
        int[] pixels = new int[px * px];
        for (int y = 0; y < px; y++) {
            for (int x = 0; x < px; x++) {
                pixels[y * px + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
            }
        }
        Bitmap bmp = Bitmap.createBitmap(pixels, px, px, Bitmap.Config.ARGB_8888);
        synchronized (qrLock) {
            cachedQrKey = key;
            cachedQrBitmap = bmp;
        }
        return bmp;
    }

    void showQrDialog(boolean forceRefresh) {
        if (!current()) return;
        if (qrDialog != null && qrDialog.isShowing()) {
            qrDialog.dismiss();
            qrDialog = null;
        }
        try {
            String address = ensureQrServer(forceRefresh);
            LinearLayout panel = a.vertical();
            panel.setGravity(Gravity.CENTER_HORIZONTAL);
            TextView note =
                    a.text(
                            "手机与电视连接同一局域网，用手机相机或浏览器扫码即可直接输入中文、英文或拼音并推送到电视全站搜索。",
                            14,
                            MainActivity.MUTED);
            note.setLineSpacing(a.dp(4), 1f);
            panel.addView(note);
            a.gap(panel, 12);
            int qrSize = a.dp(186);
            ImageView qr = new ImageView(a);
            qr.setTag("search-qr-dialog-image");
            qr.setContentDescription("手机扫码输入搜索词二维码");
            qr.setImageBitmap(createQrBitmap(address, qrSize));
            qr.setPadding(a.dp(8), a.dp(8), a.dp(8), a.dp(8));
            qr.setBackground(a.bg(Color.WHITE, 12));
            panel.addView(qr, new LinearLayout.LayoutParams(qrSize + a.dp(16), qrSize + a.dp(16)));
            TextView url = a.text(address, 12, 0xff7cb8ff);
            url.setTag("search-qr-dialog-address");
            url.setGravity(Gravity.CENTER);
            url.setPadding(0, a.dp(10), 0, a.dp(4));
            panel.addView(url);
            panel.addView(a.text("二维码 10 分钟内有效 · 退出搜索页后自动停止监听", 12, MainActivity.MUTED));
            qrDialog =
                    new AppDialog.Builder(a)
                            .setTitle("手机扫码输入搜索词")
                            .setView(panel)
                            .setPositiveButton("刷新二维码", (d, w) -> showQrDialog(true))
                            .setNegativeButton("关闭", null)
                            .create();
            qrDialog.show();
            if (qrDialog.getButton(-2) != null) qrDialog.getButton(-2).requestFocus();
        } catch (Exception error) {
            a.toast("未检测到局域网连接，请确认电视已连接 Wi-Fi 或有线网络");
        }
    }

    void closeQrServer() {
        synchronized (qrLock) {
            qrGeneration++;
            if (qrServer != null) {
                qrServer.close();
                qrServer = null;
            }
            qrAddress = "";
        }
    }

    void showHistory() {
        if (!current()) return;
        if (a.isTvDevice()) {
            showTvHistory();
            return;
        }
        resultBody.removeAllViews();
        resultBody.addView(a.text("最近搜索", 17, MainActivity.WHITE));
        List<String> history = history();
        if (history.isEmpty()) {
            TextView hint =
                    a.text(
                            a.privateMode
                                    ? "隐私模式已开启，不保存也不显示历史搜索词。"
                                    : "默认精准匹配完整片名；可按需切换模糊搜索，支持拼音、首字母和片名片段。",
                            15,
                            MainActivity.MUTED);
            hint.setLineSpacing(a.dp(6), 1);
            hint.setPadding(0, a.dp(18), 0, 0);
            resultBody.addView(hint);
            return;
        }
        for (final String value : history) {
            Button recent =
                    a.navButton(
                            value,
                            "search-history:" + value,
                            () -> {
                                if (!current()) return;
                                imeDraft.clear();
                                keyboard.set(value);
                                changed();
                                submit();
                            });
            a.addButton(resultBody, recent);
        }
        Button clear =
                a.navButton(
                        "清除搜索记录",
                        "search-clear-history",
                        () -> {
                            if (!current()) return;
                            a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                            showHistory();
                        });
        a.addButton(resultBody, clear);
    }

    private List<Cms.Video> collectTvHotRecommendations() {
        TvCuratedHome.Catalog catalog = TvCuratedHome.peekOrSeed(a.privateMode ? null : a);
        List<Cms.Video> merged = new ArrayList<>();
        Set<String> seen = new LinkedHashSet<>();
        if (catalog != null) {
            int maxDramas = Math.min(5, catalog.hotDramas.size());
            for (int i = 0; i < maxDramas; i++) {
                Cms.Video v = catalog.hotDramas.get(i);
                if (v != null && v.title != null && !v.title.trim().isEmpty()) {
                    String key = TvSearchMatcher.normalizeStrict(v.title);
                    if (!key.isEmpty() && seen.add(key)) merged.add(v);
                }
            }
            int maxMovies = Math.min(4, catalog.hotMovies.size());
            for (int i = 0; i < maxMovies && merged.size() < 8; i++) {
                Cms.Video v = catalog.hotMovies.get(i);
                if (v != null && v.title != null && !v.title.trim().isEmpty()) {
                    String key = TvSearchMatcher.normalizeStrict(v.title);
                    if (!key.isEmpty() && seen.add(key)) merged.add(v);
                }
            }
            for (int i = maxDramas; i < catalog.hotDramas.size() && merged.size() < 8; i++) {
                Cms.Video v = catalog.hotDramas.get(i);
                if (v != null && v.title != null && !v.title.trim().isEmpty()) {
                    String key = TvSearchMatcher.normalizeStrict(v.title);
                    if (!key.isEmpty() && seen.add(key)) merged.add(v);
                }
            }
        }
        return merged;
    }

    private void showTvHistory() {
        if (tvRecentContainer == null) return;
        if (tvResultRecycler != null) tvResultRecycler.setVisibility(View.GONE);
        if (tvStateContainer != null) tvStateContainer.setVisibility(View.GONE);
        if (tvFooterRow != null) tvFooterRow.setVisibility(View.GONE);
        if (filterScrollView != null) filterScrollView.setVisibility(View.GONE);
        if (tvRecentScroll != null) {
            tvRecentScroll.setVisibility(View.VISIBLE);
            tvRecentScroll.scrollTo(0, 0);
        }
        tvRecentContainer.removeAllViews();
        tvRecentContainer.setVisibility(View.VISIBLE);
        updateResultHeader();

        if (a.privateMode) {
            TextView priv = a.text("隐私模式已开启 · 不记录也不展示历史搜索词，仍可从下方热门推荐快速查找。", 13, TEXT_SECONDARY);
            priv.setLineSpacing(a.dp(4), 1f);
            LinearLayout.LayoutParams privLp = new LinearLayout.LayoutParams(-1, -2);
            privLp.bottomMargin = a.dp(12);
            tvRecentContainer.addView(priv, privLp);
        } else {
            List<String> history = history();
            if (!history.isEmpty()) {
                LinearLayout recentHead = a.row();
                recentHead.setGravity(Gravity.CENTER_VERTICAL);
                recentHead.setClipChildren(false);
                recentHead.setClipToPadding(false);
                TextView recTitle = a.text("最近搜索", 14.5f, TEXT_PRIMARY);
                recTitle.setTypeface(null, Typeface.BOLD);
                recTitle.setIncludeFontPadding(false);
                recentHead.addView(recTitle, new LinearLayout.LayoutParams(0, -2, 1));

                Button clearBtn =
                        makeTvActionPill(
                                "清除记录",
                                "search-clear-history",
                                false,
                                () -> {
                                    if (!current()) return;
                                    a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                                    showHistory();
                                });
                clearBtn.setTextSize(11.5f);
                clearBtn.setPadding(a.dp(12), 0, a.dp(12), 0);
                recentHead.addView(clearBtn, new LinearLayout.LayoutParams(-2, a.dp(30)));
                LinearLayout.LayoutParams rhLp = new LinearLayout.LayoutParams(-1, -2);
                rhLp.bottomMargin = a.dp(8);
                tvRecentContainer.addView(recentHead, rhLp);

                int perRow = columns >= 4 ? 4 : 3;
                LinearLayout chipRow = null;
                for (int i = 0; i < history.size(); i++) {
                    final String value = history.get(i);
                    final boolean isRowStart = (i % perRow == 0);
                    if (isRowStart) {
                        chipRow = a.row();
                        chipRow.setClipChildren(false);
                        chipRow.setClipToPadding(false);
                        LinearLayout.LayoutParams rLp = new LinearLayout.LayoutParams(-1, -2);
                        rLp.bottomMargin = a.dp(8);
                        tvRecentContainer.addView(chipRow, rLp);
                    }
                    final Button chip = new Button(a);
                    chip.setText(value);
                    chip.setTag("search-history:" + value);
                    chip.setAllCaps(false);
                    chip.setIncludeFontPadding(false);
                    chip.setStateListAnimator(null);
                    chip.setOutlineProvider(null);
                    chip.setSingleLine(true);
                    chip.setEllipsize(TextUtils.TruncateAt.END);
                    chip.setMaxWidth(a.dp(180));
                    chip.setMinWidth(a.dp(66));
                    chip.setMinimumWidth(a.dp(66));
                    chip.setMinHeight(0);
                    chip.setMinimumHeight(0);
                    chip.setTextSize(13f);
                    chip.setPadding(a.dp(15), 0, a.dp(15), 0);
                    final GradientDrawable bg = new GradientDrawable();
                    bg.setColor(BG_FILTER);
                    bg.setCornerRadius(a.dp(17));
                    bg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);
                    chip.setBackground(bg);
                    chip.setTextColor(TEXT_PRIMARY);
                    UiCompat.setDefaultFocusHighlightEnabled(chip, false);
                    chip.setFocusable(true);
                    chip.setFocusableInTouchMode(true);
                    chip.setOnClickListener(
                            v -> {
                                if (!current()) return;
                                imeDraft.clear();
                                keyboard.set(value);
                                changed();
                                submit();
                            });
                    chip.setOnFocusChangeListener(
                            (v, focused) -> {
                                bg.setColor(focused ? Color.WHITE : BG_FILTER);
                                bg.setStroke(
                                        focused ? Math.max(2, a.dp(2.5f)) : Math.max(1, a.dp(1)),
                                        focused ? Color.WHITE : 0x26ffffff);
                                chip.setTextColor(focused ? TEXT_ON_LIGHT : TEXT_PRIMARY);
                            });
                    if (isRowStart) {
                        chip.setOnKeyListener(
                                (v, keyCode, event) -> {
                                    if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                                            && event.getAction() == KeyEvent.ACTION_DOWN) {
                                        return restoreLeftFocus();
                                    }
                                    return false;
                                });
                    }
                    LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(-2, a.dp(34));
                    cLp.rightMargin = a.dp(9);
                    chipRow.addView(chip, cLp);
                }
            }
        }

        // Apple TV Trending / Hot Shows Discovery Grid (zero CMS source calls on blank search!)
        List<Cms.Video> hotList = collectTvHotRecommendations();
        if (!hotList.isEmpty()) {
            LinearLayout hotHead = a.row();
            hotHead.setGravity(Gravity.CENTER_VERTICAL);
            TextView hotTitle = a.text("热门推荐", 15f, TEXT_PRIMARY);
            hotTitle.setTypeface(null, Typeface.BOLD);
            hotTitle.setIncludeFontPadding(false);
            hotHead.addView(hotTitle, new LinearLayout.LayoutParams(-2, -2));
            TextView hotSub = a.text("  ·  热门剧集与电影，确认即搜", 11.5f, TEXT_MUTED);
            hotSub.setSingleLine(true);
            hotSub.setEllipsize(TextUtils.TruncateAt.END);
            hotSub.setIncludeFontPadding(false);
            hotHead.addView(hotSub, new LinearLayout.LayoutParams(0, -2, 1));
            LinearLayout.LayoutParams hhLp = new LinearLayout.LayoutParams(-1, -2);
            hhLp.topMargin = a.dp(8);
            hhLp.bottomMargin = a.dp(10);
            tvRecentContainer.addView(hotHead, hhLp);

            final int hotCols = 2;
            LinearLayout row = null;
            for (int i = 0; i < hotList.size(); i++) {
                final Cms.Video item = hotList.get(i);
                final String hotQuery = item.title.trim();
                final boolean rowStart = (i % hotCols == 0);
                if (rowStart) {
                    row = a.row();
                    row.setClipChildren(false);
                    row.setClipToPadding(false);
                    LinearLayout.LayoutParams rl = new LinearLayout.LayoutParams(-1, -2);
                    rl.bottomMargin = a.dp(9);
                    tvRecentContainer.addView(row, rl);
                }
                final LinearLayout tile = a.row();
                tile.setTag("search-hot:" + hotQuery);
                tile.setGravity(Gravity.CENTER_VERTICAL);
                tile.setPadding(a.dp(13), a.dp(10), a.dp(13), a.dp(10));
                tile.setFocusable(true);
                tile.setFocusableInTouchMode(true);
                tile.setClickable(true);
                UiCompat.setDefaultFocusHighlightEnabled(tile, false);
                final GradientDrawable tileBg = new GradientDrawable();
                tileBg.setColor(BG_HOT_CARD);
                tileBg.setCornerRadius(a.dp(13));
                tileBg.setStroke(Math.max(1, a.dp(1)), BORDER_HOT_CARD);
                tile.setBackground(tileBg);

                final int rankNum = i + 1;
                final int rankIdleColor = rankNum <= 3 ? 0xfff5c16c : TEXT_MUTED;
                final TextView rankView =
                        a.text(String.format(Locale.ROOT, "%02d", rankNum), 14f, rankIdleColor);
                rankView.setTypeface(null, Typeface.BOLD);
                rankView.setIncludeFontPadding(false);
                LinearLayout.LayoutParams rkLp = new LinearLayout.LayoutParams(a.dp(28), -2);
                rkLp.rightMargin = a.dp(8);
                tile.addView(rankView, rkLp);

                LinearLayout textCol = a.vertical();
                final TextView nameView = a.text(hotQuery, 13.5f, TEXT_PRIMARY);
                nameView.setTypeface(null, Typeface.BOLD);
                nameView.setSingleLine(true);
                nameView.setEllipsize(TextUtils.TruncateAt.END);
                nameView.setIncludeFontPadding(false);
                textCol.addView(nameView, new LinearLayout.LayoutParams(-1, -2));

                StringBuilder metaSb = new StringBuilder();
                if (item.year != null && !item.year.trim().isEmpty()) {
                    metaSb.append(item.year.trim());
                }
                if (item.genre != null && !item.genre.trim().isEmpty()) {
                    if (metaSb.length() > 0) metaSb.append(" · ");
                    metaSb.append(item.genre.trim());
                }
                if (item.doubanScore != null && !item.doubanScore.trim().isEmpty()) {
                    if (metaSb.length() > 0) metaSb.append(" · ");
                    metaSb.append("豆 ").append(item.doubanScore.trim());
                }
                final TextView subView =
                        a.text(metaSb.length() > 0 ? metaSb.toString() : "热门推荐", 11f, TEXT_MUTED);
                subView.setSingleLine(true);
                subView.setEllipsize(TextUtils.TruncateAt.END);
                subView.setIncludeFontPadding(false);
                LinearLayout.LayoutParams subLp = new LinearLayout.LayoutParams(-1, -2);
                subLp.topMargin = a.dp(3);
                textCol.addView(subView, subLp);
                tile.addView(textCol, new LinearLayout.LayoutParams(0, -2, 1));

                final TextView chevron = a.text("›", 16f, TEXT_MUTED);
                chevron.setIncludeFontPadding(false);
                LinearLayout.LayoutParams chevLp = new LinearLayout.LayoutParams(-2, -2);
                chevLp.leftMargin = a.dp(8);
                tile.addView(chevron, chevLp);

                tile.setContentDescription(hotQuery + " " + subView.getText());
                tile.setOnClickListener(
                        v -> {
                            if (!current()) return;
                            imeDraft.clear();
                            keyboard.set(hotQuery);
                            changed();
                            submit();
                        });
                tile.setOnFocusChangeListener(
                        (v, focused) -> {
                            tileBg.setColor(focused ? Color.WHITE : BG_HOT_CARD);
                            tileBg.setStroke(
                                    focused ? Math.max(2, a.dp(2.5f)) : Math.max(1, a.dp(1)),
                                    focused ? Color.WHITE : BORDER_HOT_CARD);
                            rankView.setTextColor(focused ? 0xffb4690e : rankIdleColor);
                            nameView.setTextColor(focused ? TEXT_ON_LIGHT : TEXT_PRIMARY);
                            subView.setTextColor(focused ? 0xff465568 : TEXT_MUTED);
                            chevron.setTextColor(focused ? TEXT_ON_LIGHT : TEXT_MUTED);
                        });
                if (rowStart) {
                    tile.setOnKeyListener(
                            (v, keyCode, event) -> {
                                if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                                        && event.getAction() == KeyEvent.ACTION_DOWN) {
                                    return restoreLeftFocus();
                                }
                                return false;
                            });
                }
                LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(0, -2, 1f);
                if (rowStart) tLp.rightMargin = a.dp(10);
                row.addView(tile, tLp);
            }
            if (hotList.size() % hotCols != 0 && row != null) {
                row.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));
            }
        }
    }

    List<String> history() {
        List<String> out = new ArrayList<>();
        if (!current() || a.privateMode) return out;
        try {
            JSONArray list = new JSONArray(a.prefs.getString(Prefs.GLOBAL_SEARCH_HISTORY, "[]"));
            for (int i = 0; i < Math.min(8, list.length()); i++) {
                String text = list.optString(i);
                if (!text.isEmpty()) out.add(text);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    void saveHistory(String query) {
        if (!current() || a.privateMode || TvSearchMatcher.isBlankQuery(query)) return;
        query = query.trim();
        List<String> previous = history();
        previous.remove(query);
        previous.add(0, query);
        JSONArray list = new JSONArray();
        for (int i = 0; i < Math.min(8, previous.size()); i++) list.put(previous.get(i));
        a.prefs.edit().putString(Prefs.GLOBAL_SEARCH_HISTORY, list.toString()).apply();
    }

    private View buildTvSearchGlyph() {
        View glyph =
                new View(a) {
                    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);

                    @Override
                    protected void onDraw(Canvas canvas) {
                        super.onDraw(canvas);
                        int w = getWidth();
                        int h = getHeight();
                        if (w <= 0 || h <= 0) return;
                        float s = Math.min(w, h) * 0.62f;
                        float cx = w * 0.48f;
                        float cy = h * 0.45f;
                        float r = s * 0.36f;
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(Math.max(1.8f, s * 0.12f));
                        p.setStrokeCap(Paint.Cap.ROUND);
                        p.setColor(input != null && input.hasFocus() ? TEXT_PRIMARY : TEXT_MUTED);
                        canvas.drawCircle(cx, cy, r, p);
                        float d = r * 0.72f;
                        canvas.drawLine(cx + d, cy + d, cx + r * 1.42f, cy + r * 1.42f, p);
                    }
                };
        glyph.setFocusable(false);
        glyph.setClickable(false);
        return glyph;
    }

    private View buildTvQrIconButton() {
        final View iconBtn =
                new View(a) {
                    private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
                    private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
                    private final RectF box = new RectF();

                    @Override
                    protected void onDraw(Canvas canvas) {
                        super.onDraw(canvas);
                        int w = getWidth();
                        int h = getHeight();
                        if (w <= 0 || h <= 0) return;
                        int tint = hasFocus() ? TEXT_ON_LIGHT : 0xffe6edf7;
                        float s = Math.min(w, h) * 0.56f;
                        float ox = (w - s) * 0.5f;
                        float oy = (h - s) * 0.5f;
                        float unit = s / 7f;
                        float sw = Math.max(1.5f, unit * 0.62f);
                        float cr = unit * 0.35f;

                        strokePaint.setStyle(Paint.Style.STROKE);
                        strokePaint.setStrokeWidth(sw);
                        strokePaint.setColor(tint);
                        fillPaint.setStyle(Paint.Style.FILL);
                        fillPaint.setColor(tint);

                        drawFinder(canvas, ox, oy, unit * 3f, cr);
                        drawFinder(canvas, ox + unit * 4f, oy, unit * 3f, cr);
                        drawFinder(canvas, ox, oy + unit * 4f, unit * 3f, cr);

                        drawDot(canvas, ox + unit * 4.0f, oy + unit * 4.0f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 5.9f, oy + unit * 4.0f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 4.95f, oy + unit * 4.95f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 4.0f, oy + unit * 5.9f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 5.9f, oy + unit * 5.9f, unit * 1.1f);
                    }

                    private void drawFinder(
                            Canvas canvas, float x, float y, float size, float radius) {
                        float inset = strokePaint.getStrokeWidth() * 0.5f;
                        box.set(x + inset, y + inset, x + size - inset, y + size - inset);
                        canvas.drawRoundRect(box, radius, radius, strokePaint);
                        float pip = size * 0.34f;
                        float px = x + (size - pip) * 0.5f;
                        float py = y + (size - pip) * 0.5f;
                        box.set(px, py, px + pip, py + pip);
                        canvas.drawRoundRect(box, radius * 0.5f, radius * 0.5f, fillPaint);
                    }

                    private void drawDot(Canvas canvas, float x, float y, float size) {
                        box.set(x, y, x + size, y + size);
                        canvas.drawRoundRect(box, size * 0.25f, size * 0.25f, fillPaint);
                    }
                };
        iconBtn.setTag("search-qr-button");
        iconBtn.setContentDescription("手机扫码输入");
        iconBtn.setFocusable(true);
        iconBtn.setFocusableInTouchMode(true);
        iconBtn.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(iconBtn, false);
        final GradientDrawable qrBg = new GradientDrawable();
        qrBg.setColor(BG_KEY);
        qrBg.setCornerRadius(a.dp(8));
        qrBg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);
        iconBtn.setBackground(qrBg);
        a.pressFeedback(iconBtn);
        iconBtn.setOnClickListener(
                v -> {
                    try {
                        String address = ensureQrServer(false);
                        TvQrInputHelper.showSearchBubble(a, v, address);
                    } catch (Exception error) {
                        a.toast("未检测到局域网连接，请确认电视已连接 Wi-Fi 或有线网络");
                    }
                });
        iconBtn.setOnFocusChangeListener(
                (v, focused) -> {
                    if (focused) lastLeftFocusTag = "search-qr-button";
                    qrBg.setColor(focused ? Color.WHITE : BG_KEY);
                    qrBg.setStroke(
                            focused ? Math.max(2, a.dp(2)) : Math.max(1, a.dp(1)),
                            focused ? Color.WHITE : 0x26ffffff);
                    iconBtn.invalidate();
                });
        iconBtn.setOnKeyListener(
                (v, keyCode, event) -> {
                    if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                            && event.getAction() == KeyEvent.ACTION_DOWN) {
                        return focusRightFromLeft();
                    }
                    return false;
                });
        return iconBtn;
    }

    /**
     * Suspends background search/QR activity when pushing a child Detail screen above Search on TV
     * while keeping {@code retainedRoot} attached in {@code tvStage} for fast BACK resume.
     */
    void pauseForChildPage() {
        hideCollapseReminderBubble(false);
        cancelSuggestions();
        if (imeActive && keyboard != null && contextMatches()) {
            readImeDraft();
            imeDraft.close(keyboard);
        }
        imeActive = false;
        if (pendingImeRead != null) {
            a.ui.removeCallbacks(pendingImeRead);
            pendingImeRead = null;
        }
        closed = true;
        if (qrDialog != null && qrDialog.isShowing()) {
            qrDialog.dismiss();
        }
        qrDialog = null;
        TvQrInputHelper.dismissActive();
        closeQrServer();
        rememberSourcePosition();
        if (resultScroll != null) savedResultScroll = resultScroll.getScrollY();
        if (pendingInputClick != null) {
            a.ui.removeCallbacks(pendingInputClick);
            pendingInputClick = null;
        }
        hideSystemIme();
        if (pendingSearch != null) {
            a.ui.removeCallbacks(pendingSearch);
            pendingSearch = null;
        }
        boolean hadPendingRender = pendingRender != null;
        searchSerial++;
        cancelWork();
        boolean markedAnyBusy = false;
        if (contextMatches()
                && !submitted.isEmpty()
                && resultConfig == a.config
                && resultPrivateMode == a.privateMode) {
            for (Cms.Site site : searchSites)
                if (!results.containsKey(site.key)) {
                    results.put(
                            site.key,
                            new SourceResult(
                                    site, Collections.emptyList(), SearchCoordinator.Outcome.BUSY));
                    finished++;
                    busy++;
                    markedAnyBusy = true;
                }
        }
        boolean unrendered = hasUnrenderedResults();
        resumeSyncNeeded = hadPendingRender || markedAnyBusy || unrendered;
        resumeResultsSyncNeeded = hadPendingRender || unrendered;
        if (matched == 0 && busy > 0) {
            cache = null;
            return;
        }
        cacheResults();
    }

    @Override
    public void close() {
        hideCollapseReminderBubble(false);
        tvCollapseBubble = null;
        retainedRoot = null;
        retainedBody = null;
        resumeSyncNeeded = false;
        resumeResultsSyncNeeded = false;
        cancelSuggestions();
        if (imeActive && keyboard != null && contextMatches()) {
            readImeDraft();
            imeDraft.close(keyboard);
        }
        imeActive = false;
        if (pendingImeRead != null) {
            a.ui.removeCallbacks(pendingImeRead);
            pendingImeRead = null;
        }
        closed = true;
        if (qrDialog != null && qrDialog.isShowing()) {
            qrDialog.dismiss();
        }
        qrDialog = null;
        TvQrInputHelper.dismissActive();
        closeQrServer();
        rememberSourcePosition();
        if (resultScroll != null) savedResultScroll = resultScroll.getScrollY();
        if (pendingInputClick != null) {
            a.ui.removeCallbacks(pendingInputClick);
            pendingInputClick = null;
        }
        hideSystemIme();
        if (pendingSearch != null) {
            a.ui.removeCallbacks(pendingSearch);
            pendingSearch = null;
        }
        clearCards();
        searchSerial++;
        cancelWork();
        if (contextMatches()
                && !submitted.isEmpty()
                && resultConfig == a.config
                && resultPrivateMode == a.privateMode) {
            for (Cms.Site site : searchSites)
                if (!results.containsKey(site.key)) {
                    results.put(
                            site.key,
                            new SourceResult(
                                    site, Collections.emptyList(), SearchCoordinator.Outcome.BUSY));
                    finished++;
                    busy++;
                }
        }
        cacheResults();
    }
}
