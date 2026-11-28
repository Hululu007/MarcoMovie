// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * TV & D-pad friendly manual danmaku search dialog for long/decorated PanSou cloud filenames.
 * Searches `/api/v2/search/anime` directly, lets users pick anime -> episode cleanly (without
 * strict episode auto-filtering), and attaches a QR phone-input button beside the query field.
 */
final class TvDanmuSearchDialog {

    interface SelectionCallback {
        void onEpisodeSelected(DanmuProvider.Candidate candidate);
    }

    private TvDanmuSearchDialog() {}

    static Dialog show(
            final MainActivity a,
            final DandanplayProvider provider,
            final String rawTitle,
            final String episodeName,
            final int currentEpisodeNumber,
            final SelectionCallback callback) {
        if (a == null || provider == null) return null;
        if (provider.getConfiguredOrigins().isEmpty()) {
            a.toast("尚未配置弹幕服务源，请先在「弹幕偏好设置」中填写服务地址");
            return null;
        }

        final String defaultQuery = TvSeriesScraper.cleanNetdiskDanmuQuery(rawTitle, episodeName);

        LinearLayout root = a.vertical();
        root.setLayoutParams(new ViewGroup.LayoutParams(-1, -2));

        LinearLayout searchRow = a.row();
        searchRow.setGravity(Gravity.CENTER_VERTICAL);

        final EditText input = new EditText(a);
        input.setSingleLine(true);
        input.setText(defaultQuery);
        if (!defaultQuery.isEmpty()) input.setSelection(defaultQuery.length());
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(0x88ffffff);
        input.setHint("输入剧名（支持网盘加长文件名自动精简）");
        input.setTextSize(13.5f);
        input.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        input.setBackground(a.bg(0x28ffffff, 10));

        final List<DanmuProvider.AnimeHit> animeHits = new ArrayList<>();
        final List<String> animeLabels = new ArrayList<>();
        final List<DanmuProvider.Candidate> epHits = new ArrayList<>();
        final List<String> epLabels = new ArrayList<>();
        final AtomicInteger searchSeq = new AtomicInteger(0);
        final AtomicInteger episodeSeq = new AtomicInteger(0);
        final DanmuProvider.CancellationToken[] activeSearchToken = {null};
        final DanmuProvider.CancellationToken[] activeEpisodeToken = {null};

        final TextView statusLabel =
                a.text(
                        defaultQuery.isEmpty()
                                ? "请输入影片或番剧关键词后点击「搜索」（左侧支持手机扫码输入）"
                                : "已自动清理网盘关键词，按「搜索」可修改片名并选择剧集",
                        12f,
                        MainActivity.MUTED);
        statusLabel.setPadding(0, a.dp(8), 0, a.dp(6));

        final ListView animeList = new ListView(a);
        final ListView epList = new ListView(a);
        stylePaneList(a, animeList);
        stylePaneList(a, epList);

        final ArrayAdapter<String> animeAdapter = buildPaneAdapter(a, animeLabels);
        final ArrayAdapter<String> epAdapter = buildPaneAdapter(a, epLabels);
        animeList.setAdapter(animeAdapter);
        epList.setAdapter(epAdapter);

        final Dialog[] dialogHolder = {null};

        final java.util.function.IntConsumer loadEpisodesForIndex =
                idx -> {
                    if (idx < 0 || idx >= animeHits.size()) return;
                    final DanmuProvider.AnimeHit hit = animeHits.get(idx);
                    final int epTicket = episodeSeq.incrementAndGet();
                    if (activeEpisodeToken[0] != null) activeEpisodeToken[0].cancel();
                    final DanmuProvider.CancellationToken token =
                            new DanmuProvider.CancellationToken();
                    activeEpisodeToken[0] = token;
                    epHits.clear();
                    epLabels.clear();
                    epAdapter.notifyDataSetChanged();
                    statusLabel.setText("正在读取「" + hit.animeTitle + "」分集弹幕列表…");
                    a.worker.execute(
                            () -> {
                                try {
                                    List<DanmuProvider.Candidate> eps =
                                            provider.listEpisodes(
                                                    hit.sourceOrigin, hit.animeId, token);
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || epTicket != episodeSeq.get()
                                                        || token.isCancelled()) {
                                                    return;
                                                }
                                                epHits.clear();
                                                epLabels.clear();
                                                int selectPos = -1;
                                                if (eps != null) {
                                                    for (int i = 0; i < eps.size(); i++) {
                                                        DanmuProvider.Candidate c = eps.get(i);
                                                        if (c == null) continue;
                                                        epHits.add(c);
                                                        String label =
                                                                c.episodeTitle.isEmpty()
                                                                        ? ("第" + (i + 1) + "集")
                                                                        : c.episodeTitle;
                                                        epLabels.add(label);
                                                        if (selectPos < 0
                                                                && currentEpisodeNumber > 0) {
                                                            int parsed =
                                                                    DandanplayProvider
                                                                            .extractEpisodeNum(
                                                                                    c.episodeTitle);
                                                            if (parsed == currentEpisodeNumber) {
                                                                selectPos = epHits.size() - 1;
                                                            }
                                                        }
                                                    }
                                                }
                                                epAdapter.notifyDataSetChanged();
                                                if (epHits.isEmpty()) {
                                                    statusLabel.setText(
                                                            "「" + hit.animeTitle + "」暂无可用分集弹幕");
                                                } else {
                                                    statusLabel.setText(
                                                            "已列出「"
                                                                    + hit.animeTitle
                                                                    + "」共 "
                                                                    + epHits.size()
                                                                    + " 集 · 确认选择即可加载弹幕");
                                                    if (selectPos >= 0) {
                                                        epList.setSelection(selectPos);
                                                    }
                                                }
                                            });
                                } catch (Exception err) {
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || epTicket != episodeSeq.get()
                                                        || token.isCancelled()) {
                                                    return;
                                                }
                                                statusLabel.setText("读取分集失败：" + a.message(err));
                                            });
                                }
                            });
                };

        final Runnable runSearch =
                () -> {
                    String rawQ = input.getText() == null ? "" : input.getText().toString().trim();
                    final String q = rawQ.isEmpty() ? defaultQuery : rawQ;
                    if (q.isEmpty()) {
                        statusLabel.setText("请先输入搜索关键词");
                        return;
                    }
                    final int ticket = searchSeq.incrementAndGet();
                    episodeSeq.incrementAndGet();
                    if (activeSearchToken[0] != null) activeSearchToken[0].cancel();
                    if (activeEpisodeToken[0] != null) activeEpisodeToken[0].cancel();
                    final DanmuProvider.CancellationToken token =
                            new DanmuProvider.CancellationToken();
                    activeSearchToken[0] = token;
                    animeHits.clear();
                    animeLabels.clear();
                    epHits.clear();
                    epLabels.clear();
                    animeAdapter.notifyDataSetChanged();
                    epAdapter.notifyDataSetChanged();
                    statusLabel.setText("正在搜索弹幕库「" + q + "」…");
                    a.worker.execute(
                            () -> {
                                try {
                                    List<DanmuProvider.AnimeHit> hits =
                                            provider.searchAnimes(q, token);
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != searchSeq.get()
                                                        || token.isCancelled()) {
                                                    return;
                                                }
                                                animeHits.clear();
                                                animeLabels.clear();
                                                if (hits != null) {
                                                    for (DanmuProvider.AnimeHit h : hits) {
                                                        if (h == null) continue;
                                                        animeHits.add(h);
                                                        StringBuilder sb =
                                                                new StringBuilder(h.animeTitle);
                                                        if (!h.typeDescription.isEmpty()) {
                                                            sb.append(" · ")
                                                                    .append(h.typeDescription);
                                                        }
                                                        if (h.episodeCount > 0) {
                                                            sb.append(" (")
                                                                    .append(h.episodeCount)
                                                                    .append("集)");
                                                        }
                                                        animeLabels.add(sb.toString());
                                                    }
                                                }
                                                animeAdapter.notifyDataSetChanged();
                                                if (animeHits.isEmpty()) {
                                                    statusLabel.setText(
                                                            "未搜到「" + q + "」，请尝试缩短关键词或去掉年份后重试");
                                                } else {
                                                    statusLabel.setText(
                                                            "找到 "
                                                                    + animeHits.size()
                                                                    + " 个匹配作品，请点击左侧作品查看分集");
                                                    animeList.requestFocus();
                                                    animeList.setSelection(0);
                                                    loadEpisodesForIndex.accept(0);
                                                }
                                            });
                                } catch (Exception err) {
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != searchSeq.get()
                                                        || token.isCancelled()) {
                                                    return;
                                                }
                                                statusLabel.setText("搜索弹幕失败：" + a.message(err));
                                            });
                                }
                            });
                };

        View wrappedInput =
                TvQrInputHelper.wrap(a, input, "搜索弹幕剧名", false, false, false, runSearch);
        LinearLayout.LayoutParams inputLp = new LinearLayout.LayoutParams(0, -2, 1f);
        searchRow.addView(wrappedInput, inputLp);

        Button searchBtn = a.button("搜索", "danmu-manual-search-btn", runSearch);
        LinearLayout.LayoutParams btnLp = new LinearLayout.LayoutParams(-2, -2);
        btnLp.leftMargin = a.dp(8);
        searchRow.addView(searchBtn, btnLp);
        root.addView(searchRow, new LinearLayout.LayoutParams(-1, -2));
        root.addView(statusLabel, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout panes = a.row();
        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, a.dp(270), 1f);
        LinearLayout.LayoutParams rightLp = new LinearLayout.LayoutParams(0, a.dp(270), 1.05f);
        rightLp.leftMargin = a.dp(10);
        panes.addView(animeList, leftLp);
        panes.addView(epList, rightLp);
        root.addView(panes, new LinearLayout.LayoutParams(-1, -2));

        animeList.setOnItemClickListener((p, v, pos, id) -> loadEpisodesForIndex.accept(pos));
        animeList.setOnKeyListener(
                (v, keyCode, event) -> {
                    if (event.getAction() == KeyEvent.ACTION_DOWN
                            && keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                            && !epHits.isEmpty()) {
                        epList.requestFocus();
                        return true;
                    }
                    return false;
                });
        epList.setOnKeyListener(
                (v, keyCode, event) -> {
                    if (event.getAction() == KeyEvent.ACTION_DOWN
                            && keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                            && !animeHits.isEmpty()) {
                        animeList.requestFocus();
                        return true;
                    }
                    return false;
                });
        epList.setOnItemClickListener(
                (p, v, pos, id) -> {
                    if (pos < 0 || pos >= epHits.size()) return;
                    DanmuProvider.Candidate chosen = epHits.get(pos);
                    if (activeSearchToken[0] != null) activeSearchToken[0].cancel();
                    if (activeEpisodeToken[0] != null) activeEpisodeToken[0].cancel();
                    if (dialogHolder[0] != null) {
                        dialogHolder[0].dismiss();
                    }
                    if (callback != null) {
                        callback.onEpisodeSelected(chosen);
                    }
                });

        Dialog dlg =
                new AppDialog.Builder(a)
                        .setTitle("手动搜索匹配弹幕")
                        .setWide(true)
                        .setView(root)
                        .setNegativeButton("关闭", null)
                        .show();
        dlg.setOnDismissListener(
                d -> {
                    searchSeq.incrementAndGet();
                    episodeSeq.incrementAndGet();
                    if (activeSearchToken[0] != null) activeSearchToken[0].cancel();
                    if (activeEpisodeToken[0] != null) {
                        activeEpisodeToken[0].cancel();
                    }
                    TvQrInputHelper.dismissActive();
                });
        dialogHolder[0] = dlg;

        if (!defaultQuery.isEmpty()) {
            searchBtn.post(runSearch);
        } else {
            input.post(input::requestFocus);
        }
        return dlg;
    }

    private static void stylePaneList(MainActivity a, ListView lv) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(a.dp(10));
        bg.setColor(0x36141a24);
        bg.setStroke(Math.max(1, a.dp(1)), 0x28ffffff);
        lv.setBackground(bg);
        lv.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(6));
        lv.setClipToPadding(false);
        lv.setDividerHeight(a.dp(4));
        lv.setFocusable(true);
        lv.setItemsCanFocus(false);
    }

    private static ArrayAdapter<String> buildPaneAdapter(MainActivity a, List<String> data) {
        return new ArrayAdapter<String>(a, android.R.layout.simple_list_item_1, data) {
            @Override
            public View getView(int position, View convertView, ViewGroup parent) {
                TextView tv;
                if (convertView instanceof TextView) {
                    tv = (TextView) convertView;
                } else {
                    tv = new TextView(a);
                    tv.setTextSize(13f);
                    tv.setPadding(a.dp(10), a.dp(8), a.dp(10), a.dp(8));
                    tv.setMaxLines(2);
                    tv.setEllipsize(TextUtils.TruncateAt.END);
                }
                String item = getItem(position);
                tv.setText(item == null ? "" : item);
                tv.setTextColor(Color.WHITE);
                tv.setTypeface(null, Typeface.NORMAL);
                return tv;
            }
        };
    }
}
