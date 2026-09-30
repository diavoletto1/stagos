import QtQuick
import org.kde.plasma.plasma5support as P5Support

// Runs a shell command through Plasma's "executable" engine; the callback gets (exitCode, stdout, stderr).
// All logic lives in stag-ctl / stag-status: QML only runs them and reads their JSON.
P5Support.DataSource {
    id: src
    engine: "executable"
    connectedSources: []

    property int seq: 0
    property var pending: ({})

    // single-quote a value for sh: user text never reaches the shell unquoted
    function shq(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function json(text) {
        try {
            return JSON.parse(text);
        } catch (e) {
            return null;
        }
    }

    function run(cmd, cb) {
        seq += 1;
        // the engine skips a source that is still connected: a trailing sh comment makes every call unique
        const key = cmd + " #" + seq;
        pending[key] = cb || null;
        connectSource(key);
    }

    onNewData: (sourceName, data) => {
        const cb = pending[sourceName];
        delete pending[sourceName];
        disconnectSource(sourceName);
        if (cb) {
            cb(data["exit code"], data["stdout"], data["stderr"]);
        }
    }
}
