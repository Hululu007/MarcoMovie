package com.pilipala.marcomovie;

import java.util.*;
import org.json.*;

/** Device-local bookmarks. Resolve fresh media URLs; never persist signed playback URLs. */
final class WatchHistory {
    static final int LIMIT = 60;
    static final String CORRUPTED_PREF = "watch_history_corrupted";
    static volatile boolean historyCorrupted = false;

    interface CorruptionRecorder {
        void recordCorruption(String key, String rawCorrupted);
    }

    interface Store {
        void writeHistoryState(String historyJson, boolean corrupted);
    }

    static boolean isCorrupted() {
        return historyCorrupted;
    }

    static void setCorrupted(boolean corrupted) {
        historyCorrupted = corrupted;
    }

    static String clear() {
        return clear(null);
    }

    static String clear(Store store) {
        historyCorrupted = false;
        if (store != null) {
            store.writeHistoryState("[]", false);
        }
        return "[]";
    }

    static String overwrite(String validJson, Store store) {
        String normalized =
                validJson == null || validJson.trim().isEmpty() ? "[]" : validJson.trim();
        if (isMalformed(normalized)) {
            boolean wasCorrupted = historyCorrupted;
            historyCorrupted = true;
            if (!wasCorrupted) {
                AppLog.w("WatchHistory", "Rejected malformed full history overwrite", null);
            }
            return null;
        }
        historyCorrupted = false;
        if (store != null) {
            store.writeHistoryState(normalized, false);
        }
        return normalized;
    }

    static boolean isMalformed(String text) {
        if (text == null) return false;
        String t = text.trim();
        if (t.isEmpty() || "[]".equals(t)) return false;
        try {
            new JSONArray(t);
            return false;
        } catch (Exception e) {
            return true;
        }
    }

    static final class Entry {
        String site, id, title, poster, line, episode;
        int index, position, duration;
        long updated;

        String key() {
            return site + "\n" + id;
        }

        boolean complete() {
            return duration > 0 && position >= duration - Math.min(5000, duration / 20);
        }

        int resume() {
            return complete() ? 0 : Math.max(0, position);
        }

        JSONObject json() throws JSONException {
            return new JSONObject()
                    .put("site", site)
                    .put("id", id)
                    .put("title", title)
                    .put("poster", poster)
                    .put("line", line)
                    .put("episode", episode)
                    .put("index", index)
                    .put("position", position)
                    .put("duration", duration)
                    .put("updated", updated);
        }
    }

    static List<Entry> read(String text) {
        return read(text, null);
    }

    static List<Entry> read(String text, CorruptionRecorder recorder) {
        List<Entry> out = new ArrayList<>();
        Set<String> keys = new HashSet<>();
        if (text == null) return out;
        String trimmed = text.trim();
        if (trimmed.isEmpty() || "[]".equals(trimmed)) return out;
        try {
            JSONArray a = new JSONArray(trimmed);
            for (int i = 0; i < a.length() && out.size() < LIMIT; i++) {
                JSONObject o = a.optJSONObject(i);
                if (o == null) continue;
                Entry e = new Entry();
                e.site = o.optString("site");
                e.id = o.optString("id");
                e.title = o.optString("title");
                e.poster = o.optString("poster");
                e.line = o.optString("line");
                e.episode = o.optString("episode");
                e.index = Math.max(0, o.optInt("index"));
                e.position = Math.max(0, o.optInt("position"));
                e.duration = Math.max(0, o.optInt("duration"));
                e.updated = o.optLong("updated");
                if (!e.site.isEmpty() && !e.id.isEmpty() && keys.add(e.key())) out.add(e);
            }
        } catch (Exception e) {
            boolean wasCorrupted = historyCorrupted;
            historyCorrupted = true;
            if (!wasCorrupted && recorder != null) {
                long ts = System.currentTimeMillis();
                recorder.recordCorruption("watch_history_corrupt_" + ts, text);
            }
            AppLog.w("WatchHistory", "History JSON corrupted, parse failed", e);
        }
        return out;
    }

    static String upsert(String text, Entry entry) {
        if (historyCorrupted || isMalformed(text)) {
            historyCorrupted = true;
            AppLog.w("WatchHistory", "Skipping upsert because watch history is corrupted", null);
            return text;
        }
        List<Entry> entries = read(text);
        for (Iterator<Entry> it = entries.iterator(); it.hasNext(); ) {
            if (it.next().key().equals(entry.key())) it.remove();
        }
        entries.add(0, entry);
        JSONArray a = new JSONArray();
        for (int i = 0; i < Math.min(LIMIT, entries.size()); i++)
            try {
                a.put(entries.get(i).json());
            } catch (Exception ignored) {
            }
        return a.toString();
    }

    static String remove(String text, String key) {
        if (historyCorrupted || isMalformed(text)) {
            historyCorrupted = true;
            return text;
        }
        JSONArray a = new JSONArray();
        for (Entry e : read(text))
            if (!e.key().equals(key))
                try {
                    a.put(e.json());
                } catch (Exception ignored) {
                }
        return a.toString();
    }
}
