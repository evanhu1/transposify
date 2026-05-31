import AppKit
import CoreAudio

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff),
                 UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    let cc = printable ? "'" + String(bytes: bytes, encoding: .ascii)! + "'" : "----"
    return "\(status) \(cc)"
}

func step(_ name: String, _ status: OSStatus) {
    print(String(format: "%-42@", name as NSString), "->", fourCC(status))
}

let bundleID = "com.spotify.client"
guard let pid = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier else {
    print("Spotify not running"); exit(1)
}
print("Spotify pid:", pid)

// 1. translate pid -> process object
var pidVar = pid
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var processObject = AudioObjectID(kAudioObjectUnknown)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
let s1 = withUnsafeMutablePointer(to: &pidVar) {
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                               UInt32(MemoryLayout<pid_t>.size), $0, &size, &processObject)
}
step("TranslatePIDToProcessObject", s1)
print("  processObject:", processObject)

// 2. create tap
let desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
desc.name = "Probe Tap"
desc.isPrivate = true
desc.muteBehavior = .mutedWhenTapped
var tapID = AudioObjectID(kAudioObjectUnknown)
let s2 = AudioHardwareCreateProcessTap(desc, &tapID)
step("AudioHardwareCreateProcessTap", s2)
print("  tapID:", tapID)

// 3. format
var asbd = AudioStreamBasicDescription()
var fmtAddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
let s3 = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &asbd)
step("read kAudioTapPropertyFormat", s3)
print(String(format: "  sampleRate=%.0f channels=%d flags=0x%x bytesPerFrame=%d",
             asbd.mSampleRate, asbd.mChannelsPerFrame, asbd.mFormatFlags, asbd.mBytesPerFrame))

// 4. uid
var uidAddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var uidSize = UInt32(MemoryLayout<CFString?>.size)
var cfStr: Unmanaged<CFString>?
let s4 = withUnsafeMutablePointer(to: &cfStr) {
    AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, $0)
}
step("read kAudioTapPropertyUID", s4)
let tapUID = cfStr?.takeRetainedValue() as String? ?? "(nil)"
print("  tapUID:", tapUID)

// 5. aggregate device
let aggUID = "com.evanhu.transposify.probe-\(UUID().uuidString)"
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Probe Aggregate",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
    ],
    kAudioAggregateDeviceSubDeviceListKey: [Any](),
]
var aggID = AudioObjectID(kAudioObjectUnknown)
let s5 = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
step("AudioHardwareCreateAggregateDevice", s5)
print("  aggID:", aggID)

// 6. IO proc
var procID: AudioDeviceIOProcID?
var callbackCount = 0
let s6 = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, input, _, _, _ in
    callbackCount += 1
}
step("AudioDeviceCreateIOProcIDWithBlock", s6)

// 7. start
if let proc = procID {
    let s7 = AudioDeviceStart(aggID, proc)
    step("AudioDeviceStart", s7)
    Thread.sleep(forTimeInterval: 2.0)
    print("  IOProc callbacks in 2s:", callbackCount)
    AudioDeviceStop(aggID, proc)
    AudioDeviceDestroyIOProcID(aggID, proc)
}

// teardown
if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
print("done")
