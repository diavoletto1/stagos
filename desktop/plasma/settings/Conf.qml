import QtQuick

// desktop.conf model shared by every page. All UI writes go through set(); files are read and
// written with synchronous XMLHttpRequest (the stag-settings launcher sets QML_XHR_ALLOW_FILE_READ/WRITE,
// the stock `qml` runtime has no other way to touch files). Every change is saved at once.
import "ini.js" as Ini

QtObject {
    id: conf

    property string path: ""          // desktop.conf
    property string defaultPath: ""   // desktop.conf.default, used for missing keys and a missing file
    property string requestPath: ""   // reset-layout request file consumed by the path unit service
    property string text: ""
    property string defaultText: ""
    property int rev: 0               // bumps on every change; bindings read it to refresh
    property string lastError: ""

    function readFile(p) {
        if (!p) return ""
        var x = new XMLHttpRequest()
        try {
            x.open("GET", "file://" + p, false)
            x.send()
        } catch (e) { return "" }
        return x.responseText === undefined ? "" : x.responseText
    }

    function writeFile(p, content) {
        var x = new XMLHttpRequest()
        try {
            x.open("PUT", "file://" + p, false)
            x.send(content)
        } catch (e) {
            lastError = "cannot write " + p + ": " + e
            console.warn(lastError)
            return false
        }
        return true
    }

    function load() {
        defaultText = readFile(defaultPath)
        text = readFile(path)
        if (text === "") text = defaultText
        rev++
    }

    function get(section, key) { return Ini.get(text, section, key, Ini.get(defaultText, section, key, "")) }
    function getBool(section, key) { return get(section, key) === "true" }

    function set(section, key, value) {
        var v = String(value)
        if (get(section, key) === v && Ini.get(text, section, key, null) !== null) return
        var t = Ini.set(text, section, key, v)
        if (t === text) return
        if (writeFile(path, t)) { text = t; rev++ }
    }

    // ---- dock launchers ----
    function dockList() { return Ini.splitList(get("dock", "launchers")) }
    function dockSave(list) { set("dock", "launchers", Ini.joinList(list)) }
    function dockAdd(id) {
        var l = dockList()
        if (id !== "|" && l.indexOf(id) >= 0) return
        l.push(id); dockSave(l)
    }
    function dockRemove(i) { var l = dockList(); if (i >= 0 && i < l.length) { l.splice(i, 1); dockSave(l) } }
    function dockMove(i, delta) {
        var l = dockList(), j = i + delta
        if (i < 0 || j < 0 || i >= l.length || j >= l.length) return
        var x = l[i]; l[i] = l[j]; l[j] = x; dockSave(l)
    }

    // QML cannot run commands: the path unit's service consumes this request file and runs
    // `stag-plasma-apply --reset-layout`.
    function requestResetLayout() {
        if (!requestPath) return false
        return writeFile(requestPath, "reset-layout " + new Date().toISOString() + "\n")
    }
}
