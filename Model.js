// Model.js
//
// Pure helpers for the Rclone Drive Sync bar widget. Kept inside Omarchy's
// plugin-disk convention (a .js loaded via `"Model.js" as Model`). All
// functions are side-effect free so the Panel and Service can share them
// without touching the host API.

.pragma library

function bytes(human) {
    var s = human + " B";
    var v = Number(human || 0);
    if (!isFinite(v) || v <= 0) return "0 B";
    if (v >= 1024 * 1024 * 1024 * 1024) return (v / (1024 * 1024 * 1024 * 1024)).toFixed(1) + " TB";
    if (v >= 1024 * 1024 * 1024) return (v / (1024 * 1024 * 1024)).toFixed(1) + " GB";
    if (v >= 1024 * 1024) return (v / (1024 * 1024)).toFixed(0) + " MB";
    if (v >= 1024) return (v / 1024).toFixed(0) + " KB";
    return s;
}

function parseList(rawOutput) {
    try {
        var data = JSON.parse(rawOutput);
        return Array.isArray(data) ? data : [];
    } catch (e) {
        return [];
    }
}

function parseStatus(rawOutput) {
    try {
        if (!rawOutput) return { ok: false, error: "no response" };
        var obj = JSON.parse(rawOutput);
        return obj || { ok: false, error: "empty response" };
    } catch (e) {
        // Avoid exposing a raw SyntaxError when the backend returns non-JSON.
        return { ok: false, error: "invalid response: " + String(rawOutput).slice(0, 120) };
    }
}

function fileGlyph(name) {
    var lower = String(name || "").toLowerCase();
    if (lower.indexOf(".") < 0) return "";
    if (/\.(zip|rar|7z|tar|gz|zst|xz)$/.test(lower)) return "";
    if (/\.(mp4|mkv|avi|mov)$/.test(lower)) return "";
    if (/\.(exe|msi)$/.test(lower)) return "";
    if (/\.(txt|md|log|scr)$/.test(lower)) return "";
    if (/\.(xlsx?|csv|ods)$/.test(lower)) return "";
    if (/\.(dwt|dwg)$/.test(lower)) return "";
    if (/\.(pdf)$/.test(lower)) return "";
    return "";
}

function isLocal(entry) {
    if (!entry) return false;
    return entry.local === true || entry.local === 1 || entry.local === "1";
}

function entryMeta(entry) {
    if (!entry) return "";
    var parts = [];
    if (entry.isDir === true) parts.push("Folder");
    else parts.push(bytes(entry.sizeBytes));
    if (isLocal(entry)) parts.push("· local");
    return parts.join(" ");
}

function entryState(entry) {
    // "subido"  -> available locally (downloaded)
    // "pendiente"-> selected but not yet local
    // "remoto"  -> only exists in Drive
    if (!entry) return "remoto";
    var loc = isLocal(entry);
    if (loc) return "subido";
    if (entry.selected === 1) return "pendiente";
    return "remoto";
}

function formatEta(rawEta) {
    var s = String(rawEta || "").trim();
    if (!s || s === "-") return "";
    // e.g. "1h20m30s", "1m30s", "45s", "2h5m"
    var res = s
        .replace(/(\d+)h/g, "$1 h ")
        .replace(/(\d+)m/g, "$1 min ")
        .replace(/(\d+)s/g, "$1 s");
    return res.trim();
}

function formatFileName(path) {
    var s = String(path || "").trim();
    if (!s) return "";
    var parts = s.split("/");
    return parts[parts.length - 1] || s;
}

function entryColor(state, foreground, dim, accent) {
    switch (state) {
        case "subido": return accent;          // verde: descargado
        case "pendiente": return foreground;   // neutro: marcado, por descargar
        default: return dim;                   // atenuado: solo remoto
    }
}
