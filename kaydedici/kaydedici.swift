// Dikte için hızlı başlayan mikrofon kaydedici.
// ffmpeg'in avfoundation girişi açılırken ~0,8 sn kaybediyordu; kısa sözlerin ilk heceleri kayda girmiyordu.
// Sürekli açık durur, mikrofonu yalnız kayıt sırasında açar. stdin komutları:
//   basla <yol>   kaydı başlatır (16 kHz, mono, 16 bit WAV)
//   dur           kaydı bitirir, stdout'a "bitti <yol>" yazar
//   iptal         kaydı bitirir, dosyayı siler, "iptal" yazar
import AVFoundation
import Foundation

let motor = AVAudioEngine()
let hedefBicim = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
var dosya: AVAudioFile?
var dosyaYolu: String?
var donusturucu: AVAudioConverter?
let kuyruk = DispatchQueue(label: "kaydedici")

func yaz(_ satir: String) {
    print(satir)
    fflush(stdout)
}

func basla(_ yol: String) {
    bitir(sil: true, sessiz: true)
    let giris = motor.inputNode
    let girisBicimi = giris.outputFormat(forBus: 0)
    guard let cevirici = AVAudioConverter(from: girisBicimi, to: hedefBicim) else {
        yaz("hata dönüştürücü")
        return
    }
    do {
        let ayarlar: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        dosya = try AVAudioFile(forWriting: URL(fileURLWithPath: yol), settings: ayarlar,
                                commonFormat: .pcmFormatInt16, interleaved: true)
    } catch {
        yaz("hata dosya \(error)")
        return
    }
    dosyaYolu = yol
    donusturucu = cevirici
    giris.installTap(onBus: 0, bufferSize: 1024, format: girisBicimi) { tampon, _ in
        kuyruk.async {
            guard let dosya = dosya, let cevirici = donusturucu else { return }
            let kapasite = AVAudioFrameCount(Double(tampon.frameLength) * 16000 / girisBicimi.sampleRate) + 32
            guard let cikti = AVAudioPCMBuffer(pcmFormat: hedefBicim, frameCapacity: kapasite) else { return }
            var verildi = false
            var hata: NSError?
            cevirici.convert(to: cikti, error: &hata) { _, durum in
                if verildi {
                    durum.pointee = .noDataNow
                    return nil
                }
                verildi = true
                durum.pointee = .haveData
                return tampon
            }
            if cikti.frameLength > 0 { try? dosya.write(from: cikti) }
        }
    }
    do {
        try motor.start()
        yaz("basladi")
    } catch {
        yaz("hata motor \(error)")
    }
}

func bitir(sil: Bool, sessiz: Bool = false) {
    guard let yol = dosyaYolu else { return }
    motor.inputNode.removeTap(onBus: 0)
    motor.stop()
    kuyruk.sync {
        dosya = nil          // AVAudioFile kapanınca WAV başlığı tamamlanır
        donusturucu = nil
    }
    dosyaYolu = nil
    if sil { try? FileManager.default.removeItem(atPath: yol) }
    if !sessiz { yaz(sil ? "iptal" : "bitti \(yol)") }
}

_ = motor.inputNode   // prepare() giriş düğümü oluşmadan çağrılırsa çöküyor
motor.prepare()
yaz("hazir")
while let satir = readLine() {
    let parcalar = satir.split(separator: " ", maxSplits: 1).map(String.init)
    switch parcalar.first {
    case "basla" where parcalar.count == 2: basla(parcalar[1])
    case "dur": bitir(sil: false)
    case "iptal": bitir(sil: true)
    default: yaz("hata komut")
    }
}
