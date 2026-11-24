#!/bin/bash
# "Hub dempen" v3: pauzeert ALLE muziek/video op je Mac zodra een microfoon (stabiel) aan staat,
# en zet het daarna weer aan met het volume rustig oplopend (±2 s).
# Jarvis gebruikt dezelfde truc: hij zet de microfoon stil aan zolang hij praat.
# Draait alleen op je eigen computer. Verwijderen: bash verwijder-hub-dempen.sh
set -e

BASE="$HOME/Library/Application Support/HubDempen"
APP="$BASE/HubDempen.app"
PL="$HOME/Library/LaunchAgents/nl.tdtrading.hubdempen.plist"
mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents"

VER=$(sw_vers -productVersion)
MAJ=$(echo "$VER" | cut -d. -f1); MIN=$(echo "$VER" | cut -d. -f2)
if [ "$MAJ" -lt 14 ] || { [ "$MAJ" -eq 14 ] && [ "${MIN:-0}" -lt 4 ]; }; then
  echo "Je macOS is $VER. Dit werkt vanaf macOS 14.4."; exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Installeer eerst de 'Command Line Tools' (venster verschijnt), start daarna dit script opnieuw."
  xcode-select --install || true; exit 1
fi

cat > "$BASE/main.swift" <<'SWIFT'
import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import ApplicationServices
import Network

// ---- Instellingen ----
let micOnStable: TimeInterval = 0.6   // microfoon moet zo lang onafgebroken aan zijn voor pauze
let micOffStable: TimeInterval = 1.0  // en zo lang uit voor hervatten
let fadeSeconds: Double = 2.0         // volume rustig laten oplopen
let ignoreOutput = ["com.anthropic", "com.apple.CoreSpeech", "com.apple.assistantd", "com.apple.siri"]

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
let sys = AudioObjectID(kAudioObjectSystemObject)

func processList() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyProcessObjectList); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}
func flag(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Bool {
    var a = addr(sel); var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr && v != 0
}
func bundleID(_ obj: AudioObjectID) -> String {
    var a = addr(kAudioProcessPropertyBundleID); var ref: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ref) == noErr, let r = ref else { return "" }
    return r.takeRetainedValue() as String
}
func state() -> (mic: Bool, playing: Bool, who: String) {
    var mic = false, playing = false, who = ""
    for p in processList() {
        let b = bundleID(p)
        if flag(p, kAudioProcessPropertyIsRunningInput) { mic = true; who = b }
        if flag(p, kAudioProcessPropertyIsRunningOutput), !b.isEmpty, !ignoreOutput.contains(where: { b.hasPrefix($0) }) { playing = true }
    }
    return (mic, playing, who)
}

// ---- Systeemvolume (voor rustig oplopen) ----
func outDevice() -> AudioObjectID {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var id = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &id); return id
}
func getVol() -> Float32? {
    var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
    var v: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(outDevice(), &a, 0, nil, &size, &v) == noErr ? v : nil
}
func setVol(_ v: Float32) {
    var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
    var x = max(0, min(1, v))
    AudioObjectSetPropertyData(outDevice(), &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &x)
}

// ---- ⏯-toets ----
func pressPlayPause() {
    func post(_ down: Bool) {
        let data1 = Int((16 << 16) | ((down ? 0xa : 0xb) << 8))   // 16 = NX_KEYTYPE_PLAY
        let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                    modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                                    timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
        ev?.cgEvent?.post(tap: .cghidEventTap)
    }
    post(true); post(false)
}

let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(opts)

// ---- Toestand ----
var rawMic = false, rawSince = Date()
var stableMic = false
var weePaused = false
var fadeTarget: Float32? = nil
var fadeGen = 0

func stopFade() { if let t = fadeTarget { setVol(t); fadeTarget = nil }; fadeGen += 1 }

func resumeWithFade() {
    let target = getVol()
    fadeGen += 1; let gen = fadeGen
    if let t = target, t > 0.01 { fadeTarget = t; setVol(0) }
    pressPlayPause()
    guard let t = target, t > 0.01 else { return }
    let steps = 25
    for i in 1...steps {
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeSeconds * Double(i) / Double(steps)) {
            guard gen == fadeGen else { return }
            let f = Float32(i) / Float32(steps)
            setVol(t * f * f)          // zacht beginnen, dan sneller
            if i == steps { fadeTarget = nil }
        }
    }
}

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(150))
timer.setEventHandler {
    let s = state()
    if s.mic != rawMic { rawMic = s.mic; rawSince = Date() }
    let held = Date().timeIntervalSince(rawSince)
    if rawMic && !stableMic && held >= micOnStable {
        stableMic = true
        if fadeTarget != nil { stopFade() }
        if !weePaused && s.playing { pressPlayPause(); weePaused = true }
    } else if !rawMic && stableMic && held >= micOffStable {
        stableMic = false
        if weePaused { weePaused = false; resumeWithFade() }
    }
}
timer.resume()

// Status: http://127.0.0.1:47321/state
let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 47321)
if let listener = try? NWListener(using: params) {
    listener.newConnectionHandler = { c in
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
            let s = state()
            let body = "{\"versie\":3,\"mic\":\(s.mic),\"micStabiel\":\(stableMic),\"playing\":\(s.playing),\"wijPauzeerden\":\(weePaused),\"toegang\":\(AXIsProcessTrusted()),\"who\":\"\(s.who)\"}"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Private-Network: true\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
            c.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }
    listener.start(queue: .main)
}
dispatchMain()
SWIFT

echo "Bouwen… (kan een minuut duren)"
swiftc -O "$BASE/main.swift" -o "$APP/Contents/MacOS/hubdempen"
cat > "$APP/Contents/Info.plist" <<'INFO'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>nl.tdtrading.hubdempen</string>
  <key>CFBundleName</key><string>HubDempen</string>
  <key>CFBundleExecutable</key><string>hubdempen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
INFO
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
rm -f "$BASE/hubdempen"   # oude versie (v1/v2)

cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>nl.tdtrading.hubdempen</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/hubdempen</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST

# Oude toestemming opruimen zodat macOS netjes opnieuw vraagt
tccutil reset Accessibility nl.tdtrading.hubdempen >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$PL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PL"
sleep 2
echo ""
echo "LAATSTE STAP: er komt een melding 'HubDempen wil deze computer bedienen'."
echo "Klik 'Open Systeeminstellingen' en zet HubDempen AAN."
echo "Staat er nog een oude 'hubdempen' (zonder hoofdletters) in de lijst: die mag UIT of weg (−)."
curl -s http://127.0.0.1:47321/state; echo
