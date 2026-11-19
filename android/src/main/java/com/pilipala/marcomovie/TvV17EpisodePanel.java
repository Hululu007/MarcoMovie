package com.pilipala.marcomovie;

import android.view.View;
import android.widget.FrameLayout;

/** Visual container only; the host retains the episode data, paging and callbacks. */
final class TvV17EpisodePanel {
    private TvV17EpisodePanel() {}

    static FrameLayout wrap(MainActivity a, View content) {
        FrameLayout panel = new FrameLayout(a);
        panel.setTag("tv-v17-episode-panel");
        panel.setClipChildren(false);
        panel.setClipToPadding(false);
        panel.setPadding(a.dp(18), a.dp(14), a.dp(18), a.dp(14));
        panel.setBackground(TvV17Surface.rounded(0xe61b2528, a.dp(18), 0x2affffff, a.dp(1)));
        panel.addView(content, new FrameLayout.LayoutParams(-1, -2));
        return panel;
    }
}
