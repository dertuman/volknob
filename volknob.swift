import Cocoa
import CoreAudio
import CoreGraphics
import ApplicationServices

// ════════════════════════════════════════════════════════════════════════════
// VolKnob — menu-bar output switcher + software volume for hardware-only devices
//
// Topology:  all system audio → BlackHole → [this app: ×gain] → chosen device
// The volume keys are intercepted and drive `gain`, so they work on devices
// (like the Scarlett) that expose no hardware volume to macOS.
// ════════════════════════════════════════════════════════════════════════════

setbuf(stdout, nil)

let kBlackHoleUID = "BlackHole2ch_UID"
let kAggregateUID = "com.volknob.aggregate"

// ── shared state (read on the audio thread, written on the main thread) ───────
var gain: Float = 0.5
var muted = false
var preMuteGain: Float = 0.5
let kSteps: Float = 16
var balance: Float = 0   // −1 = full left … 0 = center … +1 = full right

func saveBalance() { UserDefaults.standard.set(Double(balance), forKey: "balance") }
func loadBalance() {
    if UserDefaults.standard.object(forKey: "balance") != nil {
        balance = max(-1, min(1, Float(UserDefaults.standard.double(forKey: "balance"))))
    }
}

// ── 31-band graphic EQ (FxSound-style, ISO 1/3-octave) ───────────────────────
let eqBandCount = 31
let eqFreqs: [Double] = [20,25,31.5,40,50,63,80,100,125,160,200,250,315,400,500,
                         630,800,1000,1250,1600,2000,2500,3150,4000,5000,6300,
                         8000,10000,12500,16000,20000]
let eqLabels = ["20","25","32","40","50","63","80","100","125","160","200","250",
                "315","400","500","630","800","1k","1.2k","1.6k","2k","2.5k","3.2k",
                "4k","5k","6.3k","8k","10k","12k","16k","20k"]
let eqQ: Double = 4.318            // ~1/3-octave bandwidth
let eqRange: Float = 12            // ±12 dB per band
var eqEnabled = true
var eqGainsDB = [Float](repeating: 0, count: 31)

struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1                 // transposed Direct Form II
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

// Raw buffer (2 channels × 31 bands) — a raw pointer, not a Swift array, so the
// audio thread and UI thread can touch it without tripping exclusivity checks.
let eqBank = UnsafeMutablePointer<Biquad>.allocate(capacity: 2 * 31)
func eqInit() { for i in 0..<(2 * eqBandCount) { eqBank[i] = Biquad() } }

// RBJ peaking-EQ coefficients for one band, written into both channels.
func eqComputeBand(_ band: Int) {
    let A = pow(10.0, Double(eqGainsDB[band]) / 40.0)
    let w0 = 2 * Double.pi * eqFreqs[band] / 48000.0
    let cw = cos(w0), sw = sin(w0)
    let alpha = sw / (2 * eqQ)
    let a0 = 1 + alpha / A
    let b0 = Float((1 + alpha * A) / a0)
    let b1 = Float((-2 * cw) / a0)
    let b2 = Float((1 - alpha * A) / a0)
    let a1 = Float((-2 * cw) / a0)
    let a2 = Float((1 - alpha / A) / a0)
    for ch in 0..<2 {
        let i = ch * eqBandCount + band
        eqBank[i].b0 = b0; eqBank[i].b1 = b1; eqBank[i].b2 = b2
        eqBank[i].a1 = a1; eqBank[i].a2 = a2
    }
}
func eqRebuildAll() { for b in 0..<eqBandCount { eqComputeBand(b) } }
func eqResetState() { for i in 0..<(2 * eqBandCount) { eqBank[i].z1 = 0; eqBank[i].z2 = 0 } }

func saveEQ() {
    let d = UserDefaults.standard
    d.set(eqEnabled, forKey: "eqEnabled")
    d.set(eqGainsDB.map { Double($0) }, forKey: "eqGains")
}
func loadEQ() {
    let d = UserDefaults.standard
    if d.object(forKey: "eqEnabled") != nil { eqEnabled = d.bool(forKey: "eqEnabled") }
    if let arr = d.array(forKey: "eqGains") as? [Double], arr.count == eqBandCount {
        for i in 0..<eqBandCount { eqGainsDB[i] = Float(arr[i]) }
    }
}

// ── Enhance section (FxSound-style): Bass, Clarity, Dynamic, Ambience, Surround
var enhanceEnabled = true
var enhClarity:  Float = 0     // all 0…10
var enhAmbience: Float = 0
var enhSurround: Float = 0
var enhDynamic:  Float = 0
var enhBass:     Float = 0

// Tone shelves: [0]=bass L, [1]=bass R, [2]=clarity L, [3]=clarity R
let enhBank = UnsafeMutablePointer<Biquad>.allocate(capacity: 4)
func enhInit() { for i in 0..<4 { enhBank[i] = Biquad() } }

// RBJ shelving-filter coefficients (S=1 slope) into one enhBank slot.
func shelfCoeffs(_ slot: Int, freq: Double, gainDB: Float, high: Bool) {
    let A = pow(10.0, Double(gainDB) / 40.0)
    let w0 = 2 * Double.pi * freq / 48000.0
    let cw = cos(w0), sw = sin(w0)
    let alpha = sw / 2 * sqrt(2.0)
    let sqA = sqrt(A)
    let b0, b1, b2, a0, a1, a2: Double
    if high {
        b0 =    A * ((A+1) + (A-1)*cw + 2*sqA*alpha)
        b1 = -2*A * ((A-1) + (A+1)*cw)
        b2 =    A * ((A+1) + (A-1)*cw - 2*sqA*alpha)
        a0 =        (A+1) - (A-1)*cw + 2*sqA*alpha
        a1 =    2 * ((A-1) - (A+1)*cw)
        a2 =        (A+1) - (A-1)*cw - 2*sqA*alpha
    } else {
        b0 =    A * ((A+1) - (A-1)*cw + 2*sqA*alpha)
        b1 =  2*A * ((A-1) - (A+1)*cw)
        b2 =    A * ((A+1) - (A-1)*cw - 2*sqA*alpha)
        a0 =        (A+1) + (A-1)*cw + 2*sqA*alpha
        a1 =   -2 * ((A-1) + (A+1)*cw)
        a2 =        (A+1) + (A-1)*cw - 2*sqA*alpha
    }
    enhBank[slot].b0 = Float(b0/a0); enhBank[slot].b1 = Float(b1/a0); enhBank[slot].b2 = Float(b2/a0)
    enhBank[slot].a1 = Float(a1/a0); enhBank[slot].a2 = Float(a2/a0)
}

// Compressor (Dynamic Boost) + width/wet params, recomputed when a knob moves.
var enhWidth: Float = 1, enhWet: Float = 0
var compThreshDB: Float = 0, compRatio: Float = 2, compMakeup: Float = 1
let compAtk: Float = Float(exp(-1.0 / (48000.0 * 0.005)))   // 5 ms attack
let compRel: Float = Float(exp(-1.0 / (48000.0 * 0.150)))   // 150 ms release
var compEnv: Float = 0

func updateEnhance() {
    shelfCoeffs(0, freq: 100,  gainDB: enhBass/10*12,    high: false)
    shelfCoeffs(1, freq: 100,  gainDB: enhBass/10*12,    high: false)
    shelfCoeffs(2, freq: 3500, gainDB: enhClarity/10*9,  high: true)
    shelfCoeffs(3, freq: 3500, gainDB: enhClarity/10*9,  high: true)
    let a = enhDynamic/10
    compThreshDB = -6 - a*18            // more amount → lower threshold → more compression
    compRatio    = 2 + a*4             // 2:1 … 6:1
    compMakeup   = Float(pow(10.0, Double(a*6)/20.0))   // up to +6 dB makeup
    enhWidth = 1 + (enhSurround/10) * 1.0               // 1.0 … 2.0
    enhWet   = (enhAmbience/10) * 0.3                   // subtle wet
}

func saveEnh() {
    let d = UserDefaults.standard
    d.set(enhanceEnabled, forKey: "enhOn")
    d.set([enhClarity, enhAmbience, enhSurround, enhDynamic, enhBass].map { Double($0) }, forKey: "enhVals")
}
func loadEnh() {
    let d = UserDefaults.standard
    if d.object(forKey: "enhOn") != nil { enhanceEnabled = d.bool(forKey: "enhOn") }
    if let v = d.array(forKey: "enhVals") as? [Double], v.count == 5 {
        enhClarity = Float(v[0]); enhAmbience = Float(v[1]); enhSurround = Float(v[2])
        enhDynamic = Float(v[3]); enhBass = Float(v[4])
    }
}

// Safety soft-clip: transparent below 0.8, gently limits above (stops harsh clipping
// once Bass/Dynamic push peaks past full scale).
@inline(__always) func softclip(_ x: Float) -> Float {
    let t: Float = 0.8
    let a = abs(x)
    if a <= t { return x }
    let s: Float = x < 0 ? -1 : 1
    return s * (t + (1 - t) * tanh((a - t) / (1 - t)))
}

// Freeverb-lite stereo reverb for Ambience. Feedback < 1 → guaranteed to decay.
final class Reverb {
    struct Comb {
        var buf: UnsafeMutablePointer<Float>; var size: Int; var idx = 0; var store: Float = 0
        mutating func process(_ x: Float, _ fb: Float, _ damp: Float) -> Float {
            let y = buf[idx]
            store = y * (1 - damp) + store * damp
            buf[idx] = x + store * fb
            idx += 1; if idx >= size { idx = 0 }
            return y
        }
    }
    struct Allpass {
        var buf: UnsafeMutablePointer<Float>; var size: Int; var idx = 0
        mutating func process(_ x: Float) -> Float {
            let bo = buf[idx]
            let y = -x + bo
            buf[idx] = x + bo * 0.5
            idx += 1; if idx >= size { idx = 0 }
            return y
        }
    }
    var combsL: [Comb] = [], combsR: [Comb] = []
    var apsL: [Allpass] = [], apsR: [Allpass] = []
    let feedback: Float = 0.82, damp: Float = 0.2

    init() {
        let combTune = [1116, 1188, 1277, 1356], apTune = [556, 441], spread = 23
        for t in combTune {
            combsL.append(Comb(buf: Reverb.alloc(t), size: t))
            combsR.append(Comb(buf: Reverb.alloc(t + spread), size: t + spread))
        }
        for t in apTune {
            apsL.append(Allpass(buf: Reverb.alloc(t), size: t))
            apsR.append(Allpass(buf: Reverb.alloc(t + spread), size: t + spread))
        }
    }
    static func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p
    }
    func process(_ l: inout Float, _ r: inout Float, wet: Float) {
        let input = (l + r) * 0.25
        var outL: Float = 0, outR: Float = 0
        for i in 0..<combsL.count { outL += combsL[i].process(input, feedback, damp) }
        for i in 0..<combsR.count { outR += combsR[i].process(input, feedback, damp) }
        for i in 0..<apsL.count { outL = apsL[i].process(outL) }
        for i in 0..<apsR.count { outR = apsR[i].process(outR) }
        l += outL * wet
        r += outR * wet
    }
}
let reverb = Reverb()

// ── CoreAudio property helpers ───────────────────────────────────────────────
func cfStringProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var n: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let st = AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &n)
    if st == noErr, let cf = n?.takeRetainedValue() { return cf as String }
    return ""
}
func deviceName(_ id: AudioObjectID) -> String { cfStringProp(id, kAudioObjectPropertyName) }
func deviceUID(_ id: AudioObjectID) -> String { cfStringProp(id, kAudioDevicePropertyDeviceUID) }

func allDevices() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz = UInt32(0)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
    return ids
}
func outputChannels(_ id: AudioObjectID) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var sz = UInt32(0)
    AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz)
    if sz == 0 { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16); defer { buf.deallocate() }
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, buf)
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}
// Real, user-pickable output devices (exclude BlackHole and our own aggregate).
func realOutputDevices() -> [(id: AudioObjectID, name: String, uid: String)] {
    allDevices().compactMap { id in
        let uid = deviceUID(id)
        if uid == kBlackHoleUID || uid == kAggregateUID { return nil }
        if outputChannels(id) == 0 { return nil }
        return (id, deviceName(id), uid)
    }
}

func systemDefaultOutput() -> AudioObjectID {
    var id = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id)
    return id
}
func setSystemDefaultOutput(uid: String) {
    guard let dev = allDevices().first(where: { deviceUID($0) == uid }) else { return }
    var d = dev; let sz = UInt32(MemoryLayout<AudioObjectID>.size)
    for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, sz, &d)
    }
}
func setRate(_ dev: AudioObjectID, _ rate: Float64) {
    var r = rate
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &r)
}

// ── the audio engine: rebuildable aggregate + IOProc ─────────────────────────
let ioProc: AudioDeviceIOProc = { _, _, inData, _, outData, _, _ in
    let inBL  = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    guard inBL.count >= 1, outBL.count >= 2 else { return noErr }   // [BlackHole, target]
    let src = inBL[0]            // BlackHole loopback = the system audio
    let dst = outBL[1]          // chosen output device
    let bh  = outBL[0]          // BlackHole's own output — keep silent
    let g = muted ? 0 : gain
    let bal = balance                                    // stereo balance: attenuate the far channel
    let gL = g * (bal > 0 ? 1 - bal : 1)
    let gR = g * (bal < 0 ? 1 + bal : 1)
    let ch = Int(src.mNumberChannels)
    let total = Int(src.mDataByteSize) / MemoryLayout<Float>.size
    if ch >= 1, total > 0,
       let s = src.mData?.assumingMemoryBound(to: Float.self),
       let d = dst.mData?.assumingMemoryBound(to: Float.self),
       Int(dst.mDataByteSize) >= Int(src.mDataByteSize) {
        if !eqEnabled && !enhanceEnabled {
            if bal == 0 {
                for i in 0..<total { d[i] = s[i] * g }   // pure volume passthrough
            } else {                                     // volume + balance passthrough
                let frames = total / ch
                for n in 0..<frames {
                    d[n*ch + 0] = s[n*ch + 0] * gL
                    if ch >= 2 { d[n*ch + 1] = s[n*ch + 1] * gR }
                    if ch > 2 { for c in 2..<ch { d[n*ch + c] = s[n*ch + c] * g } }
                }
            }
        } else {
            let frames = total / ch
            let cc = min(ch, 2)
            let doEnh   = enhanceEnabled
            let doComp  = doEnh && enhDynamic  > 0.01
            let doRev   = doEnh && enhAmbience > 0.01
            let doWidth = doEnh && enhSurround > 0.01 && cc == 2
            let width = enhWidth, wet = enhWet, makeup = compMakeup
            for n in 0..<frames {
                var L = s[n*ch + 0]
                var R = cc == 2 ? s[n*ch + 1] : L
                if eqEnabled {                                   // 31-band graphic EQ
                    for b in 0..<eqBandCount { L = eqBank[b].process(L) }
                    if cc == 2 { for b in 0..<eqBandCount { R = eqBank[eqBandCount + b].process(R) } }
                }
                if doEnh {
                    L = enhBank[0].process(L); L = enhBank[2].process(L)   // bass + clarity (0 = transparent)
                    if cc == 2 { R = enhBank[1].process(R); R = enhBank[3].process(R) }
                    if doComp {                                  // Dynamic Boost: stereo-linked compressor + makeup
                        let det = cc == 2 ? max(abs(L), abs(R)) : abs(L)
                        if det > compEnv { compEnv = compAtk*compEnv + (1 - compAtk)*det }
                        else             { compEnv = compRel*compEnv + (1 - compRel)*det }
                        var cg: Float = 1
                        if compEnv > 1e-6 {
                            let over = 20 * log10(compEnv) - compThreshDB
                            if over > 0 { cg = Float(pow(10.0, Double(-(over * (1 - 1/compRatio)) / 20))) }
                        }
                        cg *= makeup
                        L *= cg; R *= cg
                    }
                    if doRev   { reverb.process(&L, &R, wet: wet) }        // Ambience
                    if doWidth {                                          // Surround / width (M/S)
                        let m = (L + R) * 0.5, sd = (L - R) * 0.5 * width
                        L = m + sd; R = m - sd
                    }
                    L = softclip(L); if cc == 2 { R = softclip(R) }
                }
                d[n*ch + 0] = L * gL
                if cc == 2 { d[n*ch + 1] = R * gR }
                if ch > 2 { for c in 2..<ch { d[n*ch + c] = s[n*ch + c] * g } }
            }
        }
    }
    if let p = bh.mData { memset(p, 0, Int(bh.mDataByteSize)) }
    return noErr
}

final class Engine {
    private var agg: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private(set) var targetUID: String = ""

    func start(toUID uid: String) {
        stop()
        targetUID = uid
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "VolKnob",
            kAudioAggregateDeviceUIDKey as String: kAggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceMasterSubDeviceKey as String: kBlackHoleUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: kBlackHoleUID],
                [kAudioSubDeviceUIDKey as String: uid,
                 kAudioSubDeviceDriftCompensationKey as String: 1],
            ],
        ]
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg) == noErr else {
            print("aggregate create failed for \(uid)"); return
        }
        setRate(agg, 48000)
        eqResetState()   // clear filter memory so switching outputs doesn't pop
        AudioDeviceCreateIOProcID(agg, ioProc, nil, &procID)
        AudioDeviceStart(agg, procID)
    }
    func stop() {
        if agg != 0 {
            AudioDeviceStop(agg, procID)
            if let p = procID { AudioDeviceDestroyIOProcID(agg, p) }
            AudioHardwareDestroyAggregateDevice(agg)
        }
        agg = 0; procID = nil
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Media-key interception (volume up / down / mute)
// ════════════════════════════════════════════════════════════════════════════
let NX_KEYTYPE_SOUND_UP: Int32 = 0
let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
let NX_KEYTYPE_MUTE: Int32 = 7

func applyVolumeKey(_ keyCode: Int32) {
    switch keyCode {
    case NX_KEYTYPE_SOUND_UP:
        muted = false
        gain = min(1.0, gain + 1.0/kSteps)
    case NX_KEYTYPE_SOUND_DOWN:
        muted = false
        gain = max(0.0, gain - 1.0/kSteps)
    case NX_KEYTYPE_MUTE:
        if muted { muted = false; gain = preMuteGain }
        else { muted = true; preMuteGain = gain }
    default: return
    }
    DispatchQueue.main.async { appDelegate?.refreshTitle() }
}

let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type.rawValue == 14 {   // NX_SYSDEFINED
        if let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
            let keyCode = Int32((ns.data1 & 0xFFFF0000) >> 16)
            let keyState = (ns.data1 & 0x0000FF00) >> 8
            let isDown = keyState == 0x0A
            if isDown && (keyCode == NX_KEYTYPE_SOUND_UP || keyCode == NX_KEYTYPE_SOUND_DOWN || keyCode == NX_KEYTYPE_MUTE) {
                applyVolumeKey(keyCode)
                return nil   // swallow — stop macOS from showing the "no volume" slash
            }
        }
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = globalTap { CGEvent.tapEnable(tap: t, enable: true) }
    }
    return Unmanaged.passUnretained(event)
}

var globalTap: CFMachPort?
func installMediaKeyTap() -> Bool {
    let mask: CGEventMask = 1 << 14   // NX_SYSDEFINED
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask,
                                      callback: eventTapCallback, userInfo: nil) else {
        return false
    }
    globalTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// ════════════════════════════════════════════════════════════════════════════
// Menu-bar status image — compact, fixed-size, sleek
// ════════════════════════════════════════════════════════════════════════════
let kBarW: CGFloat = 43   // fits big cone + "100" tightly; fixed → never changes width

// Big speaker cone + big number, butted right together. The number sits at the VISIBLE cone
// edge (the SF cone glyph has ~4pt of dead padding on its right, which is why it used to look
// far). Fixed width → never resizes 0→100, never dropped. Template = auto light/dark tint.
func volumeStatusImage(pct: Int, gain: Double, muted: Bool) -> NSImage {
    let W = kBarW, H: CGFloat = 18
    let out = NSImage(size: NSSize(width: W, height: H))
    out.lockFocus()
    NSColor.black.set()

    let symName = muted ? "speaker.slash.fill" : "speaker.fill"
    if let s = NSImage(systemSymbolName: symName, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) {
        let sz = s.size
        s.draw(in: NSRect(x: 2, y: (H - sz.height) / 2, width: sz.width, height: sz.height))
    }

    if !muted {
        let text = "\(pct)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let ts = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: 16.7, y: (H - ts.height) / 2 - 0.5), withAttributes: attrs)  // tight to the cone's ink
    }

    out.unlockFocus()
    out.isTemplate = true
    return out
}

// ════════════════════════════════════════════════════════════════════════════
// Menu-bar app
// ════════════════════════════════════════════════════════════════════════════
var appDelegate: AppDelegate?

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    var statusItem: NSStatusItem!
    var originalSystemOutputUID = ""
    var signalSources: [DispatchSourceSignal] = []
    var eqWindow: EQWindowController?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Remember what audio was on, so we can hand it back on quit.
        originalSystemOutputUID = deviceUID(systemDefaultOutput())
        let firstTarget = (originalSystemOutputUID == kBlackHoleUID)
            ? (realOutputDevices().first?.uid ?? "")
            : originalSystemOutputUID

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        refreshTitle()

        loadEQ(); eqInit(); eqRebuildAll()   // restore saved EQ, build filter coefficients
        loadEnh(); enhInit(); updateEnhance()   // restore + build enhance effects
        loadBalance()   // restore saved L/R balance

        // Funnel everything through us, then forward to the chosen device.
        setSystemDefaultOutput(uid: kBlackHoleUID)
        engine.start(toUID: firstTarget)

        if !installMediaKeyTap() {
            promptAccessibility()
        }

        // Restore audio even on signal kill (SIGTERM/SIGINT) — applicationWillTerminate
        // does NOT fire for signals, which is how we left the Mac silent earlier.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.cleanupAndRestore(); exit(0) }
            s.resume()
            signalSources.append(s)
        }
    }

    func applicationWillTerminate(_ note: Notification) { cleanupAndRestore() }

    func cleanupAndRestore() {
        engine.stop()
        // Hand audio back to the real device so the Mac isn't left silent.
        let restore = engine.targetUID.isEmpty ? originalSystemOutputUID : engine.targetUID
        if !restore.isEmpty && restore != kBlackHoleUID { setSystemDefaultOutput(uid: restore) }
    }

    func refreshTitle() {
        guard let b = statusItem.button else { return }
        let pct = muted ? 0 : Int((gain * 100).rounded())
        statusItem.length = kBarW              // fixed width → never jumps, never dropped
        b.imagePosition = .imageOnly
        b.title = ""
        b.image = volumeStatusImage(pct: pct, gain: Double(gain), muted: muted)
        b.toolTip = muted ? "Muted" : "Volume \(pct)%"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Output → (volume keys control this)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        for d in realOutputDevices() {
            let item = NSMenuItem(title: d.name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.uid
            item.state = (d.uid == engine.targetUID) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: muted ? "Volume: muted" : "Volume: \(Int((gain*100).rounded()))%",
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let eqItem = NSMenuItem(title: "Equalizer…", action: #selector(openEQ), keyEquivalent: "e")
        eqItem.target = self; menu.addItem(eqItem)
        let q = NSMenuItem(title: "Quit VolKnob", action: #selector(quit), keyEquivalent: "q")
        q.target = self; menu.addItem(q)
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        engine.start(toUID: uid)   // rebuild aggregate around the new target
    }
    @objc func openEQ() {
        if eqWindow == nil { eqWindow = EQWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        eqWindow?.showWindow(nil)
        eqWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }

    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        print("Accessibility permission needed for the volume keys. Grant it, then relaunch.")
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Equalizer window — 31 vertical sliders
// ════════════════════════════════════════════════════════════════════════════
final class EQWindowController: NSWindowController {
    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []
    private var enhSliders: [NSSlider] = []
    private var enhLabels: [NSTextField] = []
    private var balanceValueLabel: NSTextField!
    private let enhNames = ["Clarity", "Ambience", "Surround Sound", "Dynamic Boost", "Bass Boost"]
    private let eqLeft: CGFloat = 290

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 380),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "VolKnob — Equalizer & Enhance"
        w.isReleasedWhenClosed = false
        self.init(window: w)
        buildUI()
        w.center()
    }

    private func fmtDB(_ v: Float) -> String { let r = Int(v.rounded()); return r > 0 ? "+\(r)" : "\(r)" }
    private func enhVal(_ i: Int) -> Float { [enhClarity, enhAmbience, enhSurround, enhDynamic, enhBass][i] }
    private func fmtBalance(_ v: Float) -> String {
        let p = Int((abs(v) * 100).rounded())
        if p == 0 { return "C" }
        return v < 0 ? "L \(p)" : "R \(p)"
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // ── left: enhance panel ──────────────────────────────────────────────
        let enhOn = NSButton(checkboxWithTitle: "Enhance On", target: self, action: #selector(toggleEnh(_:)))
        enhOn.state = enhanceEnabled ? .on : .off
        enhOn.frame = NSRect(x: 20, y: 344, width: 120, height: 20)
        content.addSubview(enhOn)

        for i in 0..<enhNames.count {
            let y = CGFloat(292 - i * 52)
            let name = NSTextField(labelWithString: enhNames[i])
            name.frame = NSRect(x: 20, y: y + 20, width: 180, height: 15)
            name.font = NSFont.systemFont(ofSize: 11)
            content.addSubview(name)

            let s = NSSlider(frame: NSRect(x: 20, y: y, width: 210, height: 20))
            s.minValue = 0; s.maxValue = 10; s.doubleValue = Double(enhVal(i))
            s.tag = i; s.target = self; s.action = #selector(enhChanged(_:))
            content.addSubview(s); enhSliders.append(s)

            let vl = NSTextField(labelWithString: String(Int(enhVal(i).rounded())))
            vl.frame = NSRect(x: 236, y: y + 2, width: 28, height: 15)
            vl.font = NSFont.systemFont(ofSize: 11); vl.textColor = .secondaryLabelColor
            content.addSubview(vl); enhLabels.append(vl)
        }

        // ── balance (left / right) ───────────────────────────────────────────
        let balName = NSTextField(labelWithString: "Balance")
        balName.frame = NSRect(x: 20, y: 52, width: 180, height: 15)
        balName.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(balName)

        let balSlider = NSSlider(frame: NSRect(x: 20, y: 28, width: 210, height: 20))
        balSlider.minValue = -1; balSlider.maxValue = 1; balSlider.doubleValue = Double(balance)
        balSlider.numberOfTickMarks = 3            // ends + center marker
        balSlider.target = self; balSlider.action = #selector(balanceChanged(_:))
        content.addSubview(balSlider)

        let lLbl = NSTextField(labelWithString: "L")
        lLbl.frame = NSRect(x: 20, y: 10, width: 12, height: 13)
        lLbl.font = NSFont.systemFont(ofSize: 9); lLbl.textColor = .secondaryLabelColor
        content.addSubview(lLbl)
        let rLbl = NSTextField(labelWithString: "R")
        rLbl.frame = NSRect(x: 218, y: 10, width: 12, height: 13)
        rLbl.alignment = .right
        rLbl.font = NSFont.systemFont(ofSize: 9); rLbl.textColor = .secondaryLabelColor
        content.addSubview(rLbl)

        balanceValueLabel = NSTextField(labelWithString: fmtBalance(balance))
        balanceValueLabel.frame = NSRect(x: 236, y: 30, width: 40, height: 15)
        balanceValueLabel.font = NSFont.systemFont(ofSize: 11)
        balanceValueLabel.textColor = .secondaryLabelColor
        content.addSubview(balanceValueLabel)

        // divider
        let div = NSBox(frame: NSRect(x: eqLeft - 16, y: 20, width: 1, height: 340))
        div.boxType = .separator
        content.addSubview(div)

        // ── right: 31-band EQ ────────────────────────────────────────────────
        let onOff = NSButton(checkboxWithTitle: "EQ On", target: self, action: #selector(toggleEQ(_:)))
        onOff.state = eqEnabled ? .on : .off
        onOff.frame = NSRect(x: eqLeft, y: 344, width: 80, height: 20)
        content.addSubview(onOff)

        let flat = NSButton(title: "Flat", target: self, action: #selector(flatten))
        flat.bezelStyle = .rounded
        flat.frame = NSRect(x: eqLeft + 84, y: 340, width: 64, height: 26)
        content.addSubview(flat)

        let colW: CGFloat = 28, sliderH: CGFloat = 244, sliderY: CGFloat = 66
        for i in 0..<eqBandCount {
            let x = eqLeft + CGFloat(i) * colW
            let s = NSSlider(frame: NSRect(x: x, y: sliderY, width: 18, height: sliderH))
            s.isVertical = true
            s.minValue = Double(-eqRange); s.maxValue = Double(eqRange)
            s.doubleValue = Double(eqGainsDB[i])
            s.tag = i; s.target = self; s.action = #selector(sliderChanged(_:))
            content.addSubview(s); sliders.append(s)

            let vl = NSTextField(labelWithString: fmtDB(eqGainsDB[i]))
            vl.frame = NSRect(x: x - 5, y: sliderY + sliderH + 2, width: colW, height: 13)
            vl.alignment = .center; vl.font = NSFont.systemFont(ofSize: 9)
            content.addSubview(vl); valueLabels.append(vl)

            let fl = NSTextField(labelWithString: eqLabels[i])
            fl.frame = NSRect(x: x - 5, y: sliderY - 20, width: colW, height: 13)
            fl.alignment = .center; fl.font = NSFont.systemFont(ofSize: 9)
            fl.textColor = .secondaryLabelColor
            content.addSubview(fl)
        }
    }

    // EQ handlers
    @objc private func sliderChanged(_ s: NSSlider) {
        let i = s.tag
        eqGainsDB[i] = Float(s.doubleValue)
        eqComputeBand(i)
        valueLabels[i].stringValue = fmtDB(eqGainsDB[i])
        saveEQ()
    }
    @objc private func toggleEQ(_ b: NSButton) { eqEnabled = (b.state == .on); saveEQ() }
    @objc private func flatten() {
        for i in 0..<eqBandCount {
            eqGainsDB[i] = 0; eqComputeBand(i)
            sliders[i].doubleValue = 0; valueLabels[i].stringValue = fmtDB(0)
        }
        saveEQ()
    }

    // Enhance handlers
    @objc private func enhChanged(_ s: NSSlider) {
        let v = Float(s.doubleValue)
        switch s.tag {
        case 0: enhClarity = v
        case 1: enhAmbience = v
        case 2: enhSurround = v
        case 3: enhDynamic = v
        default: enhBass = v
        }
        updateEnhance()
        enhLabels[s.tag].stringValue = String(Int(v.rounded()))
        saveEnh()
    }
    @objc private func toggleEnh(_ b: NSButton) { enhanceEnabled = (b.state == .on); saveEnh() }

    // Balance handler
    @objc private func balanceChanged(_ s: NSSlider) {
        var v = Float(s.doubleValue)
        if abs(v) < 0.03 { v = 0; s.doubleValue = 0 }   // snap to center
        balance = v
        balanceValueLabel.stringValue = fmtBalance(v)
        saveBalance()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
appDelegate = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
