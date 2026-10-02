pragma Singleton

import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.config

Singleton {
    id: root

    // General Idle Settings
    property string lockCmd: Config.system.idle.general.lock_cmd ?? "ambxst lock"
    property string beforeSleepCmd: Config.system.idle.general.before_sleep_cmd ?? "loginctl lock-session"
    property string afterSleepCmd: Config.system.idle.general.after_sleep_cmd ?? "ambxst screen on"

    // Sleep/Lock monitoring is handled by the Go daemon (login1 DBus).
    // The daemon executes the configured commands itself and emits
    // SUSPEND/WAKE/LOCK events that drive the QML state below.
    property int sleepSubscription: -1

    // Keep the daemon command config in sync.
    function syncSleepCommands() {
        BackendService.call("sleep.setCommands", {
            before: root.beforeSleepCmd,
            after: root.afterSleepCmd,
            lock: root.lockCmd
        });
    }

    function handleSleepEvent(service, data) {
        if (service !== "sleep" || !data) return;
        const event = data.event;
        if (event === "SUSPEND") {
            root.lockBeforeSleep();
            SuspendManager.onPrepareForSleep();
        } else if (event === "WAKE") {
            SuspendManager.onWakingUp();
        } else if (event === "LOCK") {
            root.lockBeforeSleep();
        }
    }

    Component.onCompleted: {
        root.sleepSubscription = BackendService.addSubscription(["sleep"], (service, data) => root.handleSleepEvent(service, data));
        syncSleepCommands();
    }

    // Master Idle Logic
    property int elapsedIdleTime: 0
    property var triggeredListeners: [] // Keeps track of indices that have fired
    property int pointerWakeThreshold: 24
    property real dimCursorX: -1
    property real dimCursorY: -1
    property string cursorQueryPurpose: ""
    property var pendingBrightnessResumes: []

    property var cursorPositionProcess: Process {
        id: cursorPositionProcess
        command: ["axctl", "system", "get-cursor-position"]
        running: false
        stdout: StdioCollector { id: cursorPositionStdout }
        stderr: StdioCollector { id: cursorPositionStderr }
        onExited: (code) => {
            if (code !== 0 || !cursorPositionStdout.text) {
                console.warn("Unable to query cursor position; allowing idle brightness resume");
                if (root.cursorQueryPurpose === "wake")
                    root.finishBrightnessResume();
                return;
            }

            const parts = cursorPositionStdout.text.trim().split(",");
            const x = Number(parts[0]);
            const y = Number(parts[1]);
            if (!Number.isFinite(x) || !Number.isFinite(y)) {
                if (root.cursorQueryPurpose === "wake")
                    root.finishBrightnessResume();
                return;
            }

            if (root.cursorQueryPurpose === "dim") {
                root.dimCursorX = x;
                root.dimCursorY = y;
            } else if (root.cursorQueryPurpose === "wake") {
                const dx = x - root.dimCursorX;
                const dy = y - root.dimCursorY;
                const distance = Math.sqrt(dx * dx + dy * dy);
                // No pointer movement means the activity was most likely a
                // keyboard event, so keep keyboard wake-up immediate.
                if (distance === 0 || distance >= root.pointerWakeThreshold) {
                    root.finishBrightnessResume();
                } else {
                    console.log("Ignoring pointer wake of " + Math.round(distance) +
                        "px; waiting for " + root.pointerWakeThreshold + "px");
                    root.masterMonitor.resetActivity();
                }
            }
            root.cursorQueryPurpose = "";
        }
    }

    // Master Monitor: Detects "absence of activity" almost immediately
    property var masterMonitor: IdleMonitor {
        id: masterMonitor
        timeout: 1 // 1 second threshold to consider the session "idle"
        respectInhibitors: true

        onIsIdleChanged: {
            if (isIdle) {
                idleTimer.start();
            } else {
                idleTimer.stop();
                root.resetIdleState();
            }
        }
    }

    property var idleTimer: Timer {
        id: idleTimer
        interval: 1000 // 1 second tick
        repeat: true
        onTriggered: {
            root.elapsedIdleTime += 1;
            root.checkListeners();
        }
    }

    function executeCommand(cmd) {
        if (!cmd) return;

        // Escape backslashes and quotes for the QML string
        let escapedCmd = cmd.replace(/\\/g, "\\\\").replace(/"/g, '\\"');

        try {
            let proc = Qt.createQmlObject(`
                import Quickshell.Io
                Process {
                    stdout: StdioCollector { id: commandStdout }
                    stderr: StdioCollector { id: commandStderr }
                    command: ["sh", "-c", "${escapedCmd}"]
                    running: true
                    onExited: (code, status) => {
                        if (code !== 0) {
                            console.error("Idle command failed (" + code + "): " + "${escapedCmd}" +
                                (commandStderr.text ? "\\n" + commandStderr.text.trim() : ""));
                        }
                        destroy();
                    }
                }
            `, root, "dynamicProc");
        } catch (e) {
            console.error("Failed to create process for command:", cmd, e);
        }
    }

    function isBrightnessDimListener(listener) {
        return listener && listener.onTimeout &&
            listener.onTimeout.indexOf("brightness") !== -1;
    }

    function queryCursorPosition(purpose) {
        if (cursorPositionProcess.running)
            return;
        root.cursorQueryPurpose = purpose;
        cursorPositionProcess.running = true;
    }

    function finishBrightnessResume() {
        let listeners = Config.system.idle.listeners;
        for (let i = root.pendingBrightnessResumes.length - 1; i >= 0; i--) {
            let idx = root.pendingBrightnessResumes[i];
            let listener = listeners[idx];
            if (listener && listener.onResume) {
                console.log("Idle resuming (undoing " + (listener.timeout || 0) + "s): " + listener.onResume);
                root.executeCommand(listener.onResume);
            }
        }
        root.pendingBrightnessResumes = [];
        root.elapsedIdleTime = 0;
        root.triggeredListeners = [];
        root.cursorQueryPurpose = "";
    }

    function shouldUseInternalSleepLock() {
        const cmd = (root.beforeSleepCmd || "").trim();
        return cmd === "loginctl lock-session"
            || cmd === "loginctl lock-sessions"
            || cmd === "ambxst lock";
    }

    function lockBeforeSleep() {
        if (root.shouldUseInternalSleepLock()) {
            LockscreenService.lock();
        }
    }

    function checkListeners() {
        let listeners = Config.system.idle.listeners;
        for (let i = 0; i < listeners.length; i++) {
            let listener = listeners[i];
            let tVal = listener.timeout || 60;

            // If time matches and hasn't been triggered yet
            if (root.elapsedIdleTime >= tVal && !root.triggeredListeners.includes(i)) {
                if (listener.onTimeout) {
                    console.log("Idle timer " + tVal + "s reached: " + listener.onTimeout);
                    if (root.isBrightnessDimListener(listener))
                        root.queryCursorPosition("dim");
                    root.executeCommand(listener.onTimeout);
                }
                root.triggeredListeners.push(i);
            }
        }
    }

    function resetIdleState() {
        let listeners = Config.system.idle.listeners;

        if (root.pendingBrightnessResumes.length > 0) {
            root.queryCursorPosition("wake");
            return;
        }

        let brightnessPending = [];

        // Execute resume commands for all triggered listeners
        // We iterate backwards to undo latest states first (optional preference)
        for (let i = root.triggeredListeners.length - 1; i >= 0; i--) {
            let idx = root.triggeredListeners[i];
            let listener = listeners[idx];

            if (listener && listener.onResume && root.isBrightnessDimListener(listener)) {
                brightnessPending.push(idx);
            } else if (listener && listener.onResume) {
                console.log("Idle resuming (undoing " + (listener.timeout || 0) + "s): " + listener.onResume);
                root.executeCommand(listener.onResume);
            }
        }

        if (brightnessPending.length > 0) {
            root.pendingBrightnessResumes = brightnessPending;
            if (root.dimCursorX >= 0) {
                root.queryCursorPosition("wake");
                return;
            }
        }

        root.finishBrightnessResume();
    }
}
