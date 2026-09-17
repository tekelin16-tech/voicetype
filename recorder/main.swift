// vtrec — VoiceType 的錄音器
//
// 為什麼需要這個東西：Homebrew 的 ffmpeg 是 ad-hoc 簽章、沒有 TeamIdentifier，
// macOS 不會為它跳麥克風授權對話框，而是「靜默拒絕」——ffmpeg 照常 exit 0、
// 照常產生檔案，內容卻是一串零（-91dB）。從 Hammerspoon 叫起來也一樣。
//
// 解法是把碰麥克風這件事交給一個有正式 bundle 與 NSMicrophoneUsageDescription
// 的 app，macOS 才認得它、才會跳授權，也才會出現在系統設定的麥克風清單裡。
// 轉檔（16kHz 單聲道）留給 ffmpeg 做——那不需要麥克風權限。

import AVFoundation
import Foundation

let args = CommandLine.arguments

func audioDevices() -> [AVCaptureDevice] {
    if #available(macOS 14.0, *) {
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
    }
    return AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified).devices
}

// vtrec --list  → 每行一個裝置，格式 uniqueID|名稱
if args.count >= 2, args[1] == "--list" {
    for d in audioDevices() { print("\(d.uniqueID)|\(d.localizedName)") }
    exit(0)
}

// vtrec --check → 只回報授權狀態，給診斷用
if args.count >= 2, args[1] == "--check" {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:    print("authorized");    exit(0)
    case .denied:        print("denied");        exit(2)
    case .restricted:    print("restricted");    exit(3)
    case .notDetermined: print("notDetermined"); exit(4)
    @unknown default:    print("unknown");       exit(5)
    }
}

guard args.count >= 2 else {
    FileHandle.standardError.write("用法: vtrec <輸出.wav> [裝置名稱] [音量檔]\n       vtrec --list | --check\n".data(using: .utf8)!)
    exit(64)
}
let outPath = args[1]
let wantName = (args.count >= 3 && !args[2].isEmpty) ? args[2] : nil
// 音量檔：給 UI 畫即時音量條用。走檔案而不是 stdout，是因為中間隔了 vt.sh，
// 管線串接容易卡在緩衝區；一個每次覆寫的小檔案最不會出錯。
let levelPath = args.count >= 4 ? args[3] : nil

// 主動要求授權。第一次執行會跳系統對話框；使用者拒絕過就會直接回 false，
// 這時明講原因，不要靜靜錄出一個全零的檔案。
let sem = DispatchSemaphore(value: 0)
var granted = false
AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; sem.signal() }
sem.wait()
guard granted else {
    FileHandle.standardError.write("麥克風權限被拒：系統設定 → 隱私權與安全性 → 麥克風，打開 VoiceTypeRec\n".data(using: .utf8)!)
    exit(77)
}

let devices = audioDevices()
guard !devices.isEmpty else {
    FileHandle.standardError.write("找不到任何錄音裝置\n".data(using: .utf8)!); exit(69)
}
// 依名稱挑裝置；找不到就用第一個（跟 vt.sh 的 fallback 行為一致）
let device = wantName.flatMap { n in devices.first { $0.localizedName == n } } ?? devices[0]
if let n = wantName, device.localizedName != n {
    FileHandle.standardError.write("找不到「\(n)」，改用「\(device.localizedName)」\n".data(using: .utf8)!)
}

let session = AVCaptureSession()
guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
    FileHandle.standardError.write("無法開啟裝置: \(device.localizedName)\n".data(using: .utf8)!); exit(70)
}
session.addInput(input)

let output = AVCaptureAudioFileOutput()
guard session.canAddOutput(output) else {
    FileHandle.standardError.write("無法建立輸出\n".data(using: .utf8)!); exit(71)
}
session.addOutput(output)

final class Delegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ o: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from c: [AVCaptureConnection], error: Error?) {
        if let e = error as NSError?, e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
            FileHandle.standardError.write("錄音結束時出錯: \(e.localizedDescription)\n".data(using: .utf8)!)
            exit(74)
        }
        exit(0)
    }
}
let delegate = Delegate()
var signalSources: [DispatchSourceSignal] = []   // 不留著會被 ARC 回收，訊號就收不到了

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
session.startRunning()
output.startRecording(to: url, outputFileType: .wav, recordingDelegate: delegate)

// 每 50ms 把目前音量寫進音量檔。AVCaptureConnection 的 audioChannels 本來就有
// averagePowerLevel（dBFS），不用另外接一條 AVCaptureAudioDataOutput 自己算 RMS。
if let lp = levelPath {
    let url = URL(fileURLWithPath: lp)
    let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
        guard let conn = output.connection(with: .audio) else { return }
        let ch = conn.audioChannels
        guard !ch.isEmpty else { return }
        let avg = ch.map { $0.averagePowerLevel }.max() ?? -160
        try? String(format: "%.1f", avg).write(to: url, atomically: true, encoding: .utf8)
    }
    RunLoop.main.add(timer, forMode: .common)
}

// 收到 INT/TERM 就把檔案收乾淨再退出。直接被 kill -9 的話 WAV 檔尾寫不完整，
// 後面的 whisper 會讀不了——所以一定要走 stopRecording() 這條路。
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { output.stopRecording() }   // 收尾在 delegate 裡 exit(0)
    src.resume()
    signalSources.append(src)
}
RunLoop.main.run()
