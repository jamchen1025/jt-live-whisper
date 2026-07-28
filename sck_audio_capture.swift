// jt-live-whisper — ScreenCaptureKit 系統音訊擷取 helper
// Author: Jason Cheng (Jason Tools)
//
// 用途：取代 BlackHole + 多重輸出裝置，直接向 macOS 借系統音訊。
// 需求：macOS 13.0+、「螢幕錄製」權限（僅取音訊，不取畫面）。
//
// 編譯：
//   swiftc -O -target arm64-apple-macos13.0 -o bin/jt-sck-audio sck_audio_capture.swift \
//       -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework CoreGraphics
//
// 用法：
//   jt-sck-audio --check          偵測能力與權限，輸出單行 JSON 後結束
//   jt-sck-audio --request        觸發系統權限對話框後結束
//   jt-sck-audio [--rate 48000] [--channels 2]
//                                 持續將 float32 交錯 PCM 寫入 stdout（訊息走 stderr）
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

let kDefaultRate = 48000
let kDefaultChannels = 2

func writeErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func emitJSON(_ dict: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func osVersionString() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

func supportsSCK() -> Bool {
    if #available(macOS 13.0, *) { return true }
    return false
}

// ── 參數解析 ──────────────────────────────────────────────
var mode = "stream"
var rate = kDefaultRate
var channels = kDefaultChannels

var argIdx = 1
let argv = CommandLine.arguments
while argIdx < argv.count {
    switch argv[argIdx] {
    case "--check":
        mode = "check"
    case "--request":
        mode = "request"
    case "--rate":
        argIdx += 1
        if argIdx < argv.count, let v = Int(argv[argIdx]) { rate = v }
    case "--channels":
        argIdx += 1
        if argIdx < argv.count, let v = Int(argv[argIdx]) { channels = max(1, min(2, v)) }
    default:
        writeErr("[sck] 未知參數: \(argv[argIdx])")
    }
    argIdx += 1
}

// ── --check / --request ──────────────────────────────────
if mode == "check" {
    emitJSON([
        "available": supportsSCK(),
        "permission": CGPreflightScreenCaptureAccess(),
        "macos": osVersionString(),
    ])
    exit(0)
}

if mode == "request" {
    let granted = CGRequestScreenCaptureAccess()
    emitJSON(["permission": granted, "macos": osVersionString()])
    exit(granted ? 0 : 1)
}

guard supportsSCK() else {
    writeErr("[sck] 需要 macOS 13.0 以上")
    exit(2)
}

// ── 串流擷取 ──────────────────────────────────────────────
@available(macOS 13.0, *)
final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    private let out = FileHandle.standardOutput
    private let targetChannels: Int
    private var scratch = [Float]()

    init(targetChannels: Int) {
        self.targetChannels = targetChannels
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let fmt = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }

        let srcChannels = Int(fmt.mChannelsPerFrame)
        guard srcChannels > 0 else { return }

        try? sampleBuffer.withAudioBufferList { abl, _ in
            let buffers = abl.unsafePointer.pointee
            guard buffers.mNumberBuffers > 0 else { return }

            // ScreenCaptureKit 給的是 float32 non-interleaved（每聲道一個 buffer）
            let isPlanar = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            var planes = [UnsafePointer<Float>]()
            var frameCount = 0

            for buf in abl {
                guard let data = buf.mData else { continue }
                let floats = data.assumingMemoryBound(to: Float.self)
                planes.append(UnsafePointer(floats))
                let perBufferChannels = isPlanar ? 1 : Int(buf.mNumberChannels)
                let n = Int(buf.mDataByteSize) / 4 / max(1, perBufferChannels)
                frameCount = max(frameCount, n)
            }
            guard frameCount > 0, !planes.isEmpty else { return }

            let outCh = self.targetChannels
            if self.scratch.count != frameCount * outCh {
                self.scratch = [Float](repeating: 0, count: frameCount * outCh)
            }

            if isPlanar {
                // planar → 交錯，聲道不足時複製最後一個聲道
                for ch in 0..<outCh {
                    let src = planes[min(ch, planes.count - 1)]
                    for f in 0..<frameCount {
                        self.scratch[f * outCh + ch] = src[f]
                    }
                }
            } else {
                let src = planes[0]
                for f in 0..<frameCount {
                    for ch in 0..<outCh {
                        self.scratch[f * outCh + ch] = src[f * srcChannels + min(ch, srcChannels - 1)]
                    }
                }
            }

            self.scratch.withUnsafeBufferPointer { ptr in
                let data = Data(buffer: ptr)
                // Python 端關閉 pipe 時這裡會拿到 EPIPE，直接結束程序
                if write(self.out.fileDescriptor, (data as NSData).bytes, data.count) < 0 {
                    exit(0)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        writeErr("[sck] 串流中止: \(error.localizedDescription)")
        exit(3)
    }
}

// SCStream 對 delegate 是弱參考，且 stream 本身若只存在區域變數，
// runCapture() 一 return 就會被 ARC 釋放 → 串流靜默停止、audio callback 永遠不進來。
// 必須用全域變數持有整個程序生命週期。
var gStream: AnyObject?
var gTap: AnyObject?

@available(macOS 13.0, *)
func runCapture(rate: Int, channels: Int) async {
    guard CGPreflightScreenCaptureAccess() else {
        writeErr("[sck] 尚未取得「螢幕錄製」權限")
        exit(4)
    }

    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    } catch {
        writeErr("[sck] 無法取得可擷取內容: \(error.localizedDescription)")
        exit(5)
    }
    guard let display = content.displays.first else {
        writeErr("[sck] 找不到顯示器")
        exit(6)
    }

    // 只掛 audio output，不掛 screen output → 不會有畫面資料流動
    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = rate
    config.channelCount = channels
    // 畫面設到最小、更新率壓到最低，降低不必要的負擔
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    config.queueDepth = 6

    let tap = AudioTap(targetChannels: channels)
    let stream = SCStream(filter: filter, configuration: config, delegate: tap)
    do {
        try stream.addStreamOutput(tap, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "jt.sck.audio"))
        try await stream.startCapture()
    } catch {
        writeErr("[sck] 啟動擷取失敗: \(error.localizedDescription)")
        exit(7)
    }
    gStream = stream
    gTap = tap
    writeErr("[sck] ready rate=\(rate) channels=\(channels)")
}

if #available(macOS 13.0, *) {
    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    signal(SIGPIPE) { _ in exit(0) }
    Task { await runCapture(rate: rate, channels: channels) }
    RunLoop.main.run()
}
