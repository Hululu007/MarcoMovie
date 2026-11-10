package com.pilipala.marcomovie;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import org.json.*;

/** Independent saved subscriptions; each retains its own base URL, spider and account settings. */
final class ConfigLibrary {
    private static final Object LOCK = new Object();

    static final class Entry {
        final String id, origin, name, selected, digest;

        Entry(JSONObject value) throws Exception {
            id = value.getString("id");
            origin = value.getString("origin");
            name = value.getString("name");
            selected = value.optString("selected");
            digest = value.getString("digest");
            if (!id.matches("[0-9a-f]{64}") || !digest.matches("[0-9a-f]{64}"))
                throw new IOException("保存的订阅索引损坏，原文件已保留");
        }
    }

    final File directory;

    ConfigLibrary(File configDirectory) {
        directory = new File(configDirectory, "subscriptions");
    }

    static String hash(String value) throws Exception {
        byte[] bytes =
                MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
        StringBuilder out = new StringBuilder(64);
        for (byte b : bytes) out.append(String.format(Locale.ROOT, "%02x", b & 255));
        return out.toString();
    }

    static String identity(String origin, String raw) throws Exception {
        return hash(
                origin == null || origin.trim().isEmpty()
                        ? "local:" + raw
                        : "url:" + origin.trim());
    }

    private JSONArray index() throws Exception {
        File file = new File(directory, "index.json");
        if (!file.exists() && new File(directory, "index.json.bak").exists())
            file = new File(directory, "index.json.bak");
        if (!file.exists()) return new JSONArray();
        return new JSONArray(read(file, 1024 * 1024));
    }

    List<Entry> entries() throws Exception {
        synchronized (LOCK) {
            JSONArray items = index();
            List<Entry> out = new ArrayList<>();
            for (int i = 0; i < items.length(); i++) out.add(new Entry(items.getJSONObject(i)));
            return out;
        }
    }

    Entry remember(String raw, String origin, String name, String selected) throws Exception {
        synchronized (LOCK) {
            String source = origin == null ? "" : origin.trim();
            String id = identity(source, raw), digest = hash(raw);
            JSONArray items = index();
            JSONObject value =
                    new JSONObject()
                            .put("id", id)
                            .put("origin", source)
                            .put("name", name)
                            .put("selected", selected == null ? "" : selected)
                            .put("digest", digest);
            Entry saved = new Entry(value);
            // Content files are immutable: a failed index write cannot damage an older
            // subscription.
            File content = content(saved);
            if (!content.exists()) write(content, raw);
            int position = items.length();
            for (int i = 0; i < items.length(); i++) {
                if (id.equals(new Entry(items.getJSONObject(i)).id)) {
                    position = i;
                    break;
                }
            }
            items.put(position, value);
            write(new File(directory, "index.json"), items.toString());
            return saved;
        }
    }

    String raw(Entry entry) throws Exception {
        String value = read(content(entry), 4 * 1024 * 1024);
        if (!hash(value).equals(entry.digest)) throw new IOException("保存的订阅内容损坏，原文件已保留");
        return value;
    }

    private File content(Entry entry) {
        return new File(directory, entry.id + "-" + entry.digest + ".json");
    }

    private static String read(File file, int limit) throws Exception {
        if (file.length() > limit) throw new IOException("保存的订阅文件过大");
        try (FileInputStream in = new FileInputStream(file);
                ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int n;
            while ((n = in.read(buffer)) >= 0) {
                if (out.size() + n > limit) throw new IOException("保存的订阅文件过大");
                out.write(buffer, 0, n);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private void write(File target, String raw) throws Exception {
        if (!directory.exists() && !directory.mkdirs()) throw new IOException("无法创建订阅目录");
        File pending = File.createTempFile("subscription-", ".tmp", directory);
        try {
            try (FileOutputStream out = new FileOutputStream(pending)) {
                out.write(raw.getBytes(StandardCharsets.UTF_8));
                out.getFD().sync();
            }
            if (!pending.renameTo(target)) {
                // Windows cannot rename over an existing file. Android uses the atomic path above.
                File backup = new File(directory, target.getName() + ".bak");
                if (!target.isFile()
                        || (backup.exists() && !backup.delete())
                        || !target.renameTo(backup)) throw new IOException("无法保存订阅，原文件已保留");
                if (!pending.renameTo(target)) {
                    backup.renameTo(target);
                    throw new IOException("无法保存订阅，原文件已保留");
                }
                backup.delete();
            }
        } finally {
            pending.delete();
        }
    }
}
