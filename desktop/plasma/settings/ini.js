.pragma library
// Minimal INI reader/editor for desktop.conf. Edits values in place so comments, blank lines and
// key order survive (the same thing stag-session does in shell). No quoting, no escapes: the
// contract values never need them.

function _sectionOf(line) {
    var m = /^\s*\[([^\]]*)\]\s*$/.exec(line)
    return m ? m[1] : null
}

function _keyOf(line) {
    if (/^\s*[#;]/.test(line)) return null
    var i = line.indexOf("=")
    return i < 0 ? null : line.substring(0, i).trim()
}

function get(text, section, key, fallback) {
    var lines = text.split("\n"), sec = ""
    for (var i = 0; i < lines.length; i++) {
        var s = _sectionOf(lines[i])
        if (s !== null) { sec = s; continue }
        if (sec === section && _keyOf(lines[i]) === key)
            return lines[i].substring(lines[i].indexOf("=") + 1).trim()
    }
    return fallback
}

// returns the new text; identical text when the value is already there
function set(text, section, key, value) {
    var lines = text.split("\n"), sec = "", last = -1, secFound = false, secEnd = -1
    for (var i = 0; i < lines.length; i++) {
        var s = _sectionOf(lines[i])
        if (s !== null) { sec = s; if (s === section) { secFound = true; secEnd = i } continue }
        if (sec !== section) continue
        if (_keyOf(lines[i]) === key) {
            lines[i] = key + "=" + value
            return lines.join("\n")
        }
        if (_keyOf(lines[i]) !== null) last = i
        if (lines[i].trim() !== "") secEnd = i
    }
    if (secFound) {
        lines.splice((last >= 0 ? last : secEnd) + 1, 0, key + "=" + value)
        return lines.join("\n")
    }
    while (lines.length && lines[lines.length - 1].trim() === "") lines.pop()
    lines.push("", "[" + section + "]", key + "=" + value, "")
    return lines.join("\n")
}

// "a.desktop;b.desktop;|;c.desktop" <-> ["a.desktop", "b.desktop", "|", "c.desktop"]
function splitList(v) {
    var out = [], parts = v.split(";")
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i].trim()
        if (p !== "") out.push(p)
    }
    return out
}

function joinList(list) { return list.join(";") }
