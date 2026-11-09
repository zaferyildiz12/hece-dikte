// Hece: bas-konuş dikte uygulaması (menü çubuğu).
// Hammerspoon + kaydedici sürümünün yerini alır; yazıya dökme, temizleme ve öğrenme için
// 127.0.0.1:8766'daki servisi (servis/dikte.py) kullanır.
import AVFoundation
import ApplicationServices
import Cocoa
import CoreAudio
import ServiceManagement

let SERVIS = "http://127.0.0.1:8766"
let SAG_CMD_TUS: Int64 = 54
let ESC_TUS: Int64 = 53
let ENTER_TUS: Int64 = 36
let SAG_CMD_MASKE: UInt64 = 0x10               // NX_DEVICERCMDKEYMASK
let ETKINLESME_SURE = 0.4                      // daha kısa basış yanlışlık sayılır
let KUYRUK_SURE = 0.4                          // bırakınca kayıt bu kadar sürer (son hece kesilmesin)
let IZLEME_SURE = 30.0                         // yapıştırdıktan sonra düzeltme izleme süresi
let IZLEME_ARALIK = 2.0
// Enter'ın mesaj gönderdiği uygulamalar: izleme Enter'da biter
let ENTER_GONDERIR: Set<String> = ["com.cmuxterm.app", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp",
                                   "com.apple.MobileSMS", "com.apple.Terminal", "com.mitchellh.ghostty"]
// Terminallerde Enter anındaki ekran yarım çizilmiş olabiliyor; mesaj temiz yazılınca bir kez daha okunur
let ENTER_SONRA_OKU: [String: Double] = ["com.cmuxterm.app": 1.5, "com.apple.Terminal": 1.5, "com.mitchellh.ghostty": 1.5]

let GUNLUK = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/hece.log")

func gunluk(_ s: String) {
    let satir = "\(Date()) \(s)\n".data(using: .utf8)!
    if let h = try? FileHandle(forWritingTo: GUNLUK) {
        h.seekToEndOfFile()
        h.write(satir)
        try? h.close()
    } else {
        try? satir.write(to: GUNLUK)
    }
}

// MARK: - Servis

enum Servis {
    static func istek(_ yol: String, _ govde: [String: Any]?, zamanAsimi: Double = 60,
                      _ tamam: @escaping ([String: Any]?) -> Void) {
        var r = URLRequest(url: URL(string: SERVIS + yol)!, timeoutInterval: zamanAsimi)
        if let govde = govde {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: govde)
        }
        URLSession.shared.dataTask(with: r) { veri, cevap, _ in
            let kod = (cevap as? HTTPURLResponse)?.statusCode ?? 0
            let json = veri.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { tamam(kod == 200 ? json : nil) }
        }.resume()
    }
}

// MARK: - Kayıt (mikrofon yalnız kayıt sırasında açık, ~0,1 sn'de başlar)

final class Kaydedici {
    private let motor = AVAudioEngine()
    private let hedef = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var dosya: AVAudioFile?
    private var cevirici: AVAudioConverter?
    private let kuyruk = DispatchQueue(label: "hece.kayit")
    private(set) var yol: URL?
    var seviyeGeri: ((Float) -> Void)?       // 0...1 ses seviyesi (gösterge çubukları için)

    init() {
        _ = motor.inputNode         // prepare() giriş düğümü oluşmadan çağrılırsa çöküyor
        motor.prepare()
    }

    func basla(_ hedefYol: URL) -> Bool {
        bitir(sil: true)
        let giris = motor.inputNode
        let bicim = giris.outputFormat(forBus: 0)
        guard bicim.sampleRate > 0, let cv = AVAudioConverter(from: bicim, to: hedef) else { return false }
        let ayarlar: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let f = try? AVAudioFile(forWriting: hedefYol, settings: ayarlar, commonFormat: .pcmFormatInt16,
                                       interleaved: true) else { return false }
        dosya = f
        cevirici = cv
        yol = hedefYol
        let oran = 16000 / bicim.sampleRate
        giris.installTap(onBus: 0, bufferSize: 1024, format: bicim) { [weak self] tampon, _ in
            if let veri = tampon.floatChannelData?[0], tampon.frameLength > 0 {
                var toplam: Float = 0
                for i in 0..<Int(tampon.frameLength) { toplam += veri[i] * veri[i] }
                let rms = (toplam / Float(tampon.frameLength)).squareRoot()
                let seviye = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 40))   // -50 dB ... -10 dB
                DispatchQueue.main.async { self?.seviyeGeri?(seviye) }
            }
            self?.kuyruk.async {
                guard let self = self, let dosya = self.dosya, let cv = self.cevirici else { return }
                let kapasite = AVAudioFrameCount(Double(tampon.frameLength) * oran) + 32
                guard let cikti = AVAudioPCMBuffer(pcmFormat: self.hedef, frameCapacity: kapasite) else { return }
                var verildi = false
                var hata: NSError?
                cv.convert(to: cikti, error: &hata) { _, durum in
                    if verildi { durum.pointee = .noDataNow; return nil }
                    verildi = true
                    durum.pointee = .haveData
                    return tampon
                }
                if cikti.frameLength > 0 { try? dosya.write(from: cikti) }
            }
        }
        do { try motor.start() } catch {
            gunluk("mikrofon açılamadı: \(error)")
            bitir(sil: true)
            return false
        }
        return true
    }

    @discardableResult
    func bitir(sil: Bool) -> URL? {
        guard let y = yol else { return nil }
        motor.inputNode.removeTap(onBus: 0)
        motor.stop()
        kuyruk.sync { dosya = nil; cevirici = nil }     // dosya kapanınca WAV başlığı tamamlanır
        yol = nil
        if sil { try? FileManager.default.removeItem(at: y); return nil }
        return y
    }
}

// MARK: - Sistem sesi (dikte sırasında arkadaki müzik/video sessize alınır, kayıt bitince geri açılır)
// Çıkış cihazında sessize alma varsa o kullanılır, yoksa ses seviyesi 0'a çekilip eski değere döndürülür.
// Zaten sessizdeyse dokunulmaz.

final class SistemSesi {
    private var cihaz = AudioObjectID(0)
    private var susturuldu = false
    private var eskiSeviye: [UInt32: Float32] = [:]   // sessize alma yoksa: kanal → eski seviye

    private static func adres(_ secici: AudioObjectPropertySelector, _ eleman: UInt32 = kAudioObjectPropertyElementMain,
                              _ kapsam: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: secici, mScope: kapsam, mElement: eleman)
    }

    private static func oku<T>(_ nesne: AudioObjectID, _ a: AudioObjectPropertyAddress, _ bos: T) -> T? {
        var a = a
        var deger = bos
        var boy = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(nesne, &a),
              AudioObjectGetPropertyData(nesne, &a, 0, nil, &boy, &deger) == noErr else { return nil }
        return deger
    }

    private static func yaz<T>(_ nesne: AudioObjectID, _ a: AudioObjectPropertyAddress, _ deger: T) -> Bool {
        var a = a
        var deger = deger
        var yazilir: DarwinBoolean = false
        guard AudioObjectHasProperty(nesne, &a), AudioObjectIsPropertySettable(nesne, &a, &yazilir) == noErr,
              yazilir.boolValue else { return false }
        return AudioObjectSetPropertyData(nesne, &a, 0, nil, UInt32(MemoryLayout<T>.size), &deger) == noErr
    }

    func kapat() {
        guard !susturuldu, let c = SistemSesi.oku(AudioObjectID(kAudioObjectSystemObject),
            SistemSesi.adres(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyElementMain,
                             kAudioObjectPropertyScopeGlobal), AudioObjectID(0)), c != 0 else { return }
        let sessiz = SistemSesi.adres(kAudioDevicePropertyMute)
        if let m = SistemSesi.oku(c, sessiz, UInt32(0)) {
            guard m == 0 else { return }                       // kullanıcı zaten sessize almış
            if SistemSesi.yaz(c, sessiz, UInt32(1)) { cihaz = c; susturuldu = true }
            return
        }
        // Sessize alma yok (bazı USB/HDMI çıkışlar): ana eleman, yoksa sol/sağ kanal seviyesi
        eskiSeviye = [:]
        for eleman in [kAudioObjectPropertyElementMain, 1, 2] {
            let a = SistemSesi.adres(kAudioDevicePropertyVolumeScalar, eleman)
            if let v = SistemSesi.oku(c, a, Float32(0)), v > 0, SistemSesi.yaz(c, a, Float32(0)) { eskiSeviye[eleman] = v }
            if eleman == kAudioObjectPropertyElementMain && !eskiSeviye.isEmpty { break }
        }
        if !eskiSeviye.isEmpty { cihaz = c; susturuldu = true }
    }

    func ac() {
        guard susturuldu else { return }
        susturuldu = false
        if eskiSeviye.isEmpty {
            _ = SistemSesi.yaz(cihaz, SistemSesi.adres(kAudioDevicePropertyMute), UInt32(0))
        } else {
            for (eleman, v) in eskiSeviye { _ = SistemSesi.yaz(cihaz, SistemSesi.adres(kAudioDevicePropertyVolumeScalar, eleman), v) }
            eskiSeviye = [:]
        }
    }
}

// MARK: - Gösterge (ekranın alt ortasında küçük koyu kutu)

final class Gosterge {
    enum Hal { case kayit, isleniyor, ogrendi(String) }
    private var pencere: NSPanel
    private let nokta = NSView()
    private let simge = NSImageView()
    private let yazi = NSTextField(labelWithString: "")
    private let kutu = NSView()
    private var gizleZamanlayici: Timer?
    private var cubuklar: [CALayer] = []
    private var gecmis = [Float](repeating: 0, count: 9)    // en yeni sağda
    private let cubukSayisi = 9

    init() {
        let boyut = NSSize(width: 64, height: 30)
        pencere = Gosterge.panelKur()
        kutu.frame = NSRect(origin: .zero, size: boyut)
        kutu.wantsLayer = true
        kutu.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        kutu.layer?.cornerRadius = 15
        kutu.layer?.borderWidth = 1
        kutu.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        nokta.frame = NSRect(x: 11, y: 11, width: 8, height: 8)
        nokta.wantsLayer = true
        nokta.layer?.cornerRadius = 4
        simge.frame = NSRect(x: 24, y: 5, width: 32, height: 20)
        simge.imageScaling = .scaleProportionallyDown
        yazi.font = .systemFont(ofSize: 13, weight: .medium)
        yazi.textColor = .white
        yazi.lineBreakMode = .byTruncatingTail
        kutu.addSubview(nokta)
        kutu.addSubview(simge)
        kutu.addSubview(yazi)
        for _ in 0..<cubukSayisi {
            let c = CALayer()
            c.cornerRadius = 1.5
            c.isHidden = true
            kutu.layer?.addSublayer(c)
            cubuklar.append(c)
        }
        pencere.contentView = kutu
    }

    private static func panelKur() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 64, height: 30), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false      // uygulama aktif değilken panel gizlenmesin
        p.isReleasedWhenClosed = false
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return p
    }

    /// Panel pencere sunucusunda ekranda mı (orderFront sonrası bazen görünmez kalıyor).
    private func ekrandaMi() -> Bool {
        guard pencere.windowNumber > 0,
              let bilgi = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(pencere.windowNumber))
                as? [[String: Any]], let w = bilgi.first else { return false }
        return (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    /// Uygulama uzun süre açık kalınca (uyku/kilit sonrası) panel orderFront'a rağmen ekrana gelmeyebiliyor;
    /// öyleyse paneli yeniden kurup tekrar göster.
    private func gorunmezseOnar() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.pencere.isVisible, !self.ekrandaMi() else { return }
            gunluk("gösterge ekrana gelmedi, panel yeniden kuruldu")
            let cerceve = self.pencere.frame
            self.pencere.orderOut(nil)
            self.pencere.contentView = nil
            self.pencere = Gosterge.panelKur()
            self.pencere.contentView = self.kutu
            self.pencere.setFrame(cerceve, display: true)
            self.pencere.orderFrontRegardless()
        }
    }

    /// Mikrofon seviyesini (0...1) çubuklara işler: yeni değer sağdan girer, eskiler sola kayar.
    func seviye(_ v: Float) {
        gecmis.removeFirst()
        gecmis.append(v)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, c) in cubuklar.enumerated() {
            let h = 4 + CGFloat(gecmis[i]) * 20
            c.frame = NSRect(x: 36 + CGFloat(i) * 6, y: (30 - h) / 2, width: 3, height: h)
        }
        CATransaction.commit()
    }

    func goster(_ hal: Hal) {
        gizleZamanlayici?.invalidate()
        // Kayıtta yeşil mikrofon , işlenirken beyaz kum saati, öğrenince yeşil onay
        let yesil = NSColor(red: 0.2, green: 0.85, blue: 0.35, alpha: 1)
        func sembol(_ ad: String, _ renk: NSColor) -> NSImage? {
            let ayar = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [renk]))
            return NSImage(systemSymbolName: ad, accessibilityDescription: nil)?.withSymbolConfiguration(ayar)
        }
        var genislik: CGFloat = 64
        yazi.isHidden = true
        nokta.isHidden = false
        simge.frame = NSRect(x: 24, y: 5, width: 32, height: 20)
        cubuklar.forEach { $0.isHidden = true; $0.removeAllAnimations() }
        simge.image = nil
        switch hal {
        case .kayit:
            // Sol: yeşil mikrofon, sağ: canlı ses çubukları
            nokta.isHidden = true
            simge.image = sembol("mic.fill", yesil)
            simge.frame = NSRect(x: 10, y: 5, width: 20, height: 20)
            genislik = 36 + CGFloat(cubukSayisi) * 6 + 8
            gecmis = [Float](repeating: 0, count: cubukSayisi)
            for c in cubuklar { c.cornerRadius = 1.5; c.opacity = 1; c.transform = CATransform3DIdentity
                                c.backgroundColor = yesil.cgColor; c.isHidden = false }
            seviye(0)
        case .isleniyor:
            // Yazı hazırlanırken: sırayla yanıp sönen üç yeşil nokta
            nokta.isHidden = true
            for (i, c) in cubuklar.prefix(3).enumerated() {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                c.frame = NSRect(x: 32 + CGFloat(i - 1) * 14 - 4, y: 11, width: 8, height: 8)
                c.cornerRadius = 4
                c.backgroundColor = yesil.cgColor
                c.isHidden = false
                CATransaction.commit()
                let a = CAKeyframeAnimation(keyPath: "transform.scale")
                a.values = [0.55, 1.0, 0.55]
                let o = CAKeyframeAnimation(keyPath: "opacity")
                o.values = [0.35, 1.0, 0.35]
                let grup = CAAnimationGroup()
                grup.animations = [a, o]
                grup.duration = 0.9
                grup.repeatCount = .infinity
                grup.beginTime = CACurrentMediaTime() + Double(i) * 0.15
                grup.fillMode = .backwards
                c.add(grup, forKey: "bekle")
            }
        case .ogrendi(let metin):
            // Öğrenilen kelimeyi aynı yerde 5 sn göster: "✓ Öğrendim: yanlış → doğru"
            nokta.isHidden = true
            simge.image = sembol("checkmark", yesil)
            simge.frame = NSRect(x: 12, y: 5, width: 18, height: 20)
            yazi.stringValue = "Öğrendim: " + metin
            yazi.sizeToFit()
            let yaziGenislik = min(yazi.frame.width, 520)
            yazi.frame = NSRect(x: 34, y: (30 - yazi.frame.height) / 2, width: yaziGenislik, height: yazi.frame.height)
            yazi.isHidden = false
            genislik = 34 + yaziGenislik + 14
            gizleZamanlayici = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.gizle() }
        }
        kutu.frame = NSRect(x: 0, y: 0, width: genislik, height: 30)
        if let ekran = NSScreen.main?.visibleFrame {
            pencere.setFrame(NSRect(x: ekran.midX - genislik / 2, y: ekran.minY + 30, width: genislik, height: 30),
                             display: true)
        }
        pencere.orderFrontRegardless()
        gorunmezseOnar()
    }

    func gizle() { pencere.orderOut(nil) }
}

// MARK: - Son dikte dosyası
// Yazı alanı seçili değilken yapıştırma boşa gider; metin kaybolmasın diye son dikte dosyaya
// yazılır (Raycast "Hece Kopyala" buradan panoya alır). Son 20 dikte ayrıca geçmiş dosyasında.

enum SonDikte {
    static let klasor = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dikte")
    static func kaydet(_ metin: String) {
        try? FileManager.default.createDirectory(at: klasor, withIntermediateDirectories: true)
        try? metin.write(to: klasor.appendingPathComponent("son-dikte.txt"), atomically: true, encoding: .utf8)
        let gecmisYol = klasor.appendingPathComponent("son-dikteler.txt")
        let ayrac = "\n\u{1E}\n"   // kayıt ayırıcı: metinlerde satır sonu olabilir
        var liste = ((try? String(contentsOf: gecmisYol, encoding: .utf8)) ?? "")
            .components(separatedBy: ayrac).filter { !$0.isEmpty }
        let zaman = ISO8601DateFormatter().string(from: Date())
        liste.insert("\(zaman)\t\(metin)", at: 0)
        try? liste.prefix(20).joined(separator: ayrac).write(to: gecmisYol, atomically: true, encoding: .utf8)
    }
}

// MARK: - Yapıştırma

enum Yapistirici {
    static func yapistir(_ metin: String) {
        let pano = NSPasteboard.general
        // Panonun eski içeriğini (tüm türleriyle) sakla, sonra geri koy
        let eski: [[NSPasteboard.PasteboardType: Data]] = (pano.pasteboardItems ?? []).map { oge in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in oge.types { if let v = oge.data(forType: t) { d[t] = v } }
            return d
        }
        pano.clearContents()
        pano.setString(metin, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let kaynak = CGEventSource(stateID: .combinedSessionState)
            for asagi in [true, false] {
                let e = CGEvent(keyboardEventSource: kaynak, virtualKey: 9, keyDown: asagi)   // V
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard !eski.isEmpty else { return }
                pano.clearContents()
                pano.writeObjects(eski.map { d in
                    let oge = NSPasteboardItem()
                    for (t, v) in d { oge.setData(v, forType: t) }
                    return oge
                })
            }
        }
    }
}

// MARK: - Düzeltme izleme (öğrenme)

final class Izleyici {
    private var metin = ""
    private var uygulama = ""
    private var alan: String?
    private var zamanlayici: Timer?
    private var bitis = Date()
    private var electronAcik: Set<String> = []
    var ogrendi: (([[String: String]]) -> Void)?
    var aktif: Bool { zamanlayici != nil }

    static func odakMetni() -> String? {
        let sistem = AXUIElementCreateSystemWide()
        var odak: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sistem, kAXFocusedUIElementAttribute as CFString, &odak) == .success,
              let eleman = odak else { return nil }
        var deger: CFTypeRef?
        guard AXUIElementCopyAttributeValue(eleman as! AXUIElement, kAXValueAttribute as CFString, &deger) == .success
        else { return nil }
        return deger as? String
    }

    func basla(_ yapistirilan: String) {
        bitir()
        guard let onde = NSWorkspace.shared.frontmostApplication, let kimlik = onde.bundleIdentifier else { return }
        // Electron uygulamaları (Slack vb.) metin alanını ancak bu bayrakla açar
        if !electronAcik.contains(kimlik) {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(onde.processIdentifier),
                                         "AXManualAccessibility" as CFString, kCFBooleanTrue)
            electronAcik.insert(kimlik)
        }
        metin = yapistirilan
        uygulama = kimlik
        okunamayan = 0
        gunluk("öğrenme: izleme başladı (\(kimlik))")
        alan = nil
        bitis = Date().addingTimeInterval(IZLEME_SURE)
        zamanlayici = Timer.scheduledTimer(withTimeInterval: IZLEME_ARALIK, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.oku()
            if Date() >= self.bitis { self.bitir() }
        }
    }

    func oku() {
        guard aktif else { return }
        let onde = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard onde == uygulama else { return }
        if let d = Izleyici.odakMetni() { alan = d } else { okunamayan += 1 }
    }
    private var okunamayan = 0

    func enter() {
        guard aktif else { return }
        gunluk("öğrenme: Enter (\(uygulama))")
        oku()
        if let bekle = ENTER_SONRA_OKU[uygulama] {
            zamanlayici?.invalidate()
            zamanlayici = Timer.scheduledTimer(withTimeInterval: bekle, repeats: false) { [weak self] _ in
                self?.oku()
                self?.bitir()
            }
        } else if ENTER_GONDERIR.contains(uygulama) {
            bitir()
        }
    }

    func bitir() {
        guard zamanlayici != nil else { return }
        zamanlayici?.invalidate()
        zamanlayici = nil
        // Alan okunamadıysa ya da yapıştırılan metin aynen duruyorsa öğrenilecek bir şey yok
        guard var a = alan else { gunluk("öğrenme: alan okunamadı (\(uygulama))"); return }
        if a.contains(metin) { gunluk("öğrenme: değişiklik yok (\(uygulama))"); return }
        gunluk("öğrenme: fark gönderiliyor (\(uygulama))")
        if a.count > 20000 { a = String(a.suffix(20000)) }
        Servis.istek("/ogren", ["dikte": metin, "alan": a], zamanAsimi: 120) { [weak self] json in
            let liste = (json?["ogrenilen"] as? [[String: String]]) ?? []
            if !liste.isEmpty { self?.ogrendi?(liste) }
        }
    }
}

// MARK: - Pencere (uygulama açılınca görünür: durum, ayarlar, sözlük)
// Hece normalde Dock'ta durmaz; pencere açıkken Dock'ta görünür, kapatınca çekilir.

final class Pencere: NSObject, NSWindowDelegate {
    let pencere: NSWindow
    let durum = NSTextField(labelWithString: "")
    let kaynakSecici = NSSegmentedControl(labels: ["Bulut (ElevenLabs)", "Yerel (Whisper)"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    let temizleKutu = NSButton(checkboxWithTitle: "Claude ile temizle", target: nil, action: nil)
    let girisKutu = NSButton(checkboxWithTitle: "Mac açılınca başlat", target: nil, action: nil)
    let sesKutu = NSButton(checkboxWithTitle: "Konuşurken arkadaki sesi kapat (müzik, video)", target: nil, action: nil)
    let sonMetin = NSTextField(wrappingLabelWithString: "")
    let sonOgrenilen = NSTextField(wrappingLabelWithString: "")
    let sozlukDugme = NSButton(title: "Sözlüğü aç", target: nil, action: nil)
    let gunlukDugme = NSButton(title: "Günlük", target: nil, action: nil)

    override init() {
        pencere = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 356),
                           styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        pencere.title = "Hece"
        pencere.isReleasedWhenClosed = false
        pencere.delegate = self
        let kullanim = NSTextField(wrappingLabelWithString: "Sağ ⌘ tuşunu basılı tut, konuş, bırak. Metin imlecin olduğu yere yapıştırılır. Düzelttiğin kelimeleri öğrenir.")
        kullanim.textColor = .secondaryLabelColor
        sonMetin.textColor = .secondaryLabelColor
        sonOgrenilen.textColor = .secondaryLabelColor
        let baslik = { (t: String) -> NSTextField in
            let f = NSTextField(labelWithString: t)
            f.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            f.textColor = .secondaryLabelColor
            return f
        }
        let dugmeler = NSStackView(views: [sozlukDugme, gunlukDugme])
        let yigin = NSStackView(views: [durum, kullanim, baslik("SES TANIMA"), kaynakSecici, temizleKutu, sesKutu, girisKutu,
                                        baslik("SON DİKTE"), sonMetin, baslik("SON ÖĞRENİLEN"), sonOgrenilen, dugmeler])
        yigin.orientation = .vertical
        yigin.alignment = .leading
        yigin.spacing = 8
        yigin.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        yigin.setCustomSpacing(14, after: kullanim)
        yigin.setCustomSpacing(14, after: girisKutu)
        for v in [kullanim, sonMetin, sonOgrenilen] { v.preferredMaxLayoutWidth = 360 }
        pencere.contentView = yigin
        pencere.center()
    }

    func goster() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        pencere.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Uygulama

final class Uygulama: NSObject, NSApplicationDelegate {
    enum Durum { case bos, hazirlik, kayit, isleniyor }
    private var durum = Durum.bos { didSet { menuSimgesi() } }
    private let kaydedici = Kaydedici()
    private let gosterge = Gosterge()
    private let izleyici = Izleyici()
    private let pencere = Pencere()
    private let sistemSesi = SistemSesi()
    private var durumOgesi: NSStatusItem!
    private var menuDonmeZamanlayici: Timer?
    private var musluk: CFMachPort?
    private var sagCmdBasili = false
    private var etkinlesme: DispatchWorkItem?
    private var sonMetin = ""
    private var sonOgrenilen = ""
    private let ayar = UserDefaults.standard
    private var kaynak: String { ayar.string(forKey: "kaynak") ?? "bulut" }
    private var temizle: Bool { ayar.object(forKey: "temizle") as? Bool ?? true }
    private var sesiKapat: Bool { ayar.object(forKey: "sesiKapat") as? Bool ?? true }
    private let kayitKlasoru = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dikte")

    func applicationDidFinishLaunching(_ n: Notification) {
        durumOgesi = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        anaMenuKur()
        pencereBagla()
        menuSimgesi()
        menuKur()
        // Elle açılınca pencere görünsün; Mac açılışında (giriş öğesi) sessiz başlasın
        if SMAppService.mainApp.status != .enabled || ProcessInfo.processInfo.environment["HECE_PENCERE"] != nil
            || !ayar.bool(forKey: "pencereGosterildi") {
            ayar.set(true, forKey: "pencereGosterildi")
            pencere.goster()
        }
        izleyici.ogrendi = { [weak self] liste in
            guard let self = self else { return }
            self.sonOgrenilen = liste.map { "\($0["yanlis"] ?? "") → \($0["dogru"] ?? "")" }.joined(separator: ", ")
            gunluk("öğrendi: \(self.sonOgrenilen)")
            if self.durum == .bos { self.gosterge.goster(.ogrendi(self.sonOgrenilen)) }
            self.menuKur()
        }
        try? FileManager.default.createDirectory(at: kayitKlasoru, withIntermediateDirectories: true)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        kaydedici.seviyeGeri = { [weak self] v in
            if self?.durum == .kayit { self?.gosterge.seviye(v) }
        }
        musluguKur()
    }

    func applicationWillTerminate(_ n: Notification) { sistemSesi.ac() }

    // Uygulama zaten çalışırken yeniden açılınca (Uygulamalar, Spotlight, Dock) pencereyi göster
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        pencere.goster()
        return true
    }

    private func anaMenuKur() {
        let ana = NSMenu()
        let uygulamaOgesi = NSMenuItem()
        ana.addItem(uygulamaOgesi)
        let m = NSMenu()
        m.addItem(withTitle: "Hece'den çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        uygulamaOgesi.submenu = m
        NSApp.mainMenu = ana
    }

    private func pencereBagla() {
        pencere.kaynakSecici.target = self
        pencere.kaynakSecici.action = #selector(pencereKaynak)
        pencere.temizleKutu.target = self
        pencere.temizleKutu.action = #selector(temizleDegistir)
        pencere.sesKutu.target = self
        pencere.sesKutu.action = #selector(sesiKapatDegistir)
        pencere.girisKutu.target = self
        pencere.girisKutu.action = #selector(giristeAcDegistir)
        pencere.sozlukDugme.target = self
        pencere.sozlukDugme.action = #selector(sozluguAc)
        pencere.gunlukDugme.target = self
        pencere.gunlukDugme.action = #selector(gunluguAc)
    }

    @objc private func pencereKaynak() {
        ayar.set(pencere.kaynakSecici.selectedSegment == 0 ? "bulut" : "yerel", forKey: "kaynak")
        menuKur()
    }

    private func pencereGuncelle() {
        pencere.durum.stringValue = musluk == nil
            ? "⚠︎ Erişilebilirlik izni bekleniyor (Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik → Hece)"
            : "● Hazır: sağ ⌘ dinleniyor"
        pencere.durum.textColor = musluk == nil ? .systemOrange : .systemGreen
        pencere.kaynakSecici.selectedSegment = kaynak == "bulut" ? 0 : 1
        pencere.temizleKutu.state = temizle ? .on : .off
        pencere.sesKutu.state = sesiKapat ? .on : .off
        pencere.girisKutu.state = SMAppService.mainApp.status == .enabled ? .on : .off
        pencere.sonMetin.stringValue = sonMetin.isEmpty ? "Henüz yok" : sonMetin
        pencere.sonOgrenilen.stringValue = sonOgrenilen.isEmpty ? "Henüz yok" : sonOgrenilen
    }

    // MARK: Menü

    private func menuSimgesi() {
        menuDonmeZamanlayici?.invalidate()
        menuDonmeZamanlayici = nil
        if durum == .isleniyor {
            // Yeşil dönen simge: yazı yapıştırılana kadar
            let kareler = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            var k = 0
            let yesil = NSColor(red: 0.2, green: 0.85, blue: 0.35, alpha: 1)
            func ciz() {
                durumOgesi?.button?.attributedTitle = NSAttributedString(
                    string: kareler[k % kareler.count],
                    attributes: [.foregroundColor: yesil, .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)])
                k += 1
            }
            ciz()
            menuDonmeZamanlayici = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in ciz() }
            return
        }
        durumOgesi?.button?.attributedTitle = NSAttributedString(string: "")
        durumOgesi?.button?.title = [.bos: "🎙", .hazirlik: "🎙", .kayit: "🟢", .isleniyor: "⏳"][durum]!
    }

    private func menuKur() {
        let m = NSMenu()
        m.addItem(withTitle: "Sağ ⌘ basılı tut, konuş, bırak", action: nil, keyEquivalent: "")
        if musluk == nil {
            m.addItem(oge("⚠︎ Erişilebilirlik izni gerekiyor…", #selector(erisilebilirlikAc)))
        }
        m.addItem(.separator())
        m.addItem(oge("Ses tanıma: Bulut (ElevenLabs)", #selector(bulutSec), secili: kaynak == "bulut"))
        m.addItem(oge("Ses tanıma: Yerel (Whisper)", #selector(yerelSec), secili: kaynak == "yerel"))
        m.addItem(.separator())
        m.addItem(oge("Claude ile temizle", #selector(temizleDegistir), secili: temizle))
        m.addItem(oge("Konuşurken arkadaki sesi kapat", #selector(sesiKapatDegistir), secili: sesiKapat))
        let son = oge("Son metni kopyala", #selector(sonMetniKopyala))
        son.isEnabled = !sonMetin.isEmpty
        m.addItem(son)
        if !sonOgrenilen.isEmpty {
            m.addItem(withTitle: "Son öğrenilen: \(sonOgrenilen)", action: nil, keyEquivalent: "")
        }
        m.addItem(oge("Sözlüğü aç", #selector(sozluguAc)))
        m.addItem(oge("Servis günlüğü", #selector(gunluguAc)))
        m.addItem(.separator())
        m.addItem(oge("Girişte aç", #selector(giristeAcDegistir), secili: SMAppService.mainApp.status == .enabled))
        m.addItem(oge("Hece'den çık", #selector(NSApplication.terminate(_:))))
        durumOgesi.menu = m
        pencereGuncelle()
    }

    private func oge(_ baslik: String, _ eylem: Selector, secili: Bool = false) -> NSMenuItem {
        let o = NSMenuItem(title: baslik, action: eylem, keyEquivalent: "")
        o.target = eylem == #selector(NSApplication.terminate(_:)) ? NSApp : self
        o.state = secili ? .on : .off
        return o
    }

    @objc private func bulutSec() { ayar.set("bulut", forKey: "kaynak"); menuKur() }
    @objc private func yerelSec() { ayar.set("yerel", forKey: "kaynak"); menuKur() }
    @objc private func temizleDegistir() { ayar.set(!temizle, forKey: "temizle"); menuKur() }
    @objc private func sesiKapatDegistir() { ayar.set(!sesiKapat, forKey: "sesiKapat"); menuKur() }
    @objc private func sonMetniKopyala() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sonMetin, forType: .string)
    }
    @objc private func sozluguAc() {
        Servis.istek("/durum", nil) { json in
            guard let yol = json?["sozluk"] as? String else { return }
            NSWorkspace.shared.open([URL(fileURLWithPath: yol)],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }
    @objc private func gunluguAc() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/dikte.log"))
    }
    @objc private func giristeAcDegistir() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
        menuKur()
    }
    @objc private func erisilebilirlikAc() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    // MARK: Kısayol (sağ ⌘)

    private func musluguKur() {
        let maske = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let geri: CGEventTapCallBack = { _, tip, olay, kullanici in
            let u = Unmanaged<Uygulama>.fromOpaque(kullanici!).takeUnretainedValue()
            return u.olay(tip, olay)
        }
        musluk = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: CGEventMask(maske), callback: geri,
                                   userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let musluk = musluk {
            let kaynak = CFMachPortCreateRunLoopSource(nil, musluk, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), kaynak, .commonModes)
            CGEvent.tapEnable(tap: musluk, enable: true)
            gunluk("kısayol dinleniyor")
        } else {
            // İzin yok: iste ve verilene kadar dene
            erisilebilirlikAc()
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.musluguKur() }
        }
        menuKur()
    }

    private func olay(_ tip: CGEventType, _ olay: CGEvent) -> Unmanaged<CGEvent>? {
        if tip == .tapDisabledByTimeout || tip == .tapDisabledByUserInput {
            if let musluk = musluk { CGEvent.tapEnable(tap: musluk, enable: true) }
            return Unmanaged.passUnretained(olay)
        }
        let tus = olay.getIntegerValueField(.keyboardEventKeycode)
        if tip == .flagsChanged {
            if tus == SAG_CMD_TUS {
                let basili = (olay.flags.rawValue & SAG_CMD_MASKE) != 0
                if basili != sagCmdBasili {
                    sagCmdBasili = basili
                    DispatchQueue.main.async { self.sagCmd(basili) }
                }
            }
            return Unmanaged.passUnretained(olay)
        }
        // keyDown
        if tus == ENTER_TUS { izleyici.enter() }
        if durum == .kayit || durum == .hazirlik {
            if tus == ESC_TUS {
                DispatchQueue.main.async { self.kayitDurdur(iptal: true) }
                return nil
            }
            if sagCmdBasili { DispatchQueue.main.async { self.kayitDurdur(iptal: true) } }   // ⌘C gibi kısayol
        }
        return Unmanaged.passUnretained(olay)
    }

    private func sagCmd(_ basildi: Bool) {
        if basildi {
            if durum == .bos { kayitBaslat() }
        } else if durum == .hazirlik {
            kayitDurdur(iptal: true)         // kısa basış: yanlışlık
        } else if durum == .kayit {
            kayitDurdur(iptal: false)
        }
    }

    private func kayitBaslat() {
        izleyici.bitir()                     // yeni dikte başlarken önceki izlemenin son halini gönder
        let yol = kayitKlasoru.appendingPathComponent("kayit-\(Int(Date().timeIntervalSince1970)).wav")
        guard kaydedici.basla(yol) else { return }
        if sesiKapat { sistemSesi.kapat() }  // basışta: müzik kaydın başına da karışmasın
        durum = .hazirlik
        let is_ = DispatchWorkItem { [weak self] in
            guard let self = self, self.durum == .hazirlik else { return }
            self.durum = .kayit
            self.gosterge.goster(.kayit)
        }
        etkinlesme = is_
        DispatchQueue.main.asyncAfter(deadline: .now() + ETKINLESME_SURE, execute: is_)
    }

    private func kayitDurdur(iptal: Bool) {
        guard durum == .kayit || durum == .hazirlik else { return }
        etkinlesme?.cancel()
        if iptal {
            kaydedici.bitir(sil: true)
            sistemSesi.ac()
            durum = .bos
            gosterge.gizle()
            return
        }
        durum = .isleniyor
        gosterge.goster(.isleniyor)
        DispatchQueue.main.asyncAfter(deadline: .now() + KUYRUK_SURE) { [weak self] in
            guard let self = self else { return }
            let yol = self.kaydedici.bitir(sil: false)
            self.sistemSesi.ac()             // ses kayıt biter bitmez döner, yazıya dökmeyi beklemez
            if let yol = yol { self.isle(yol) }
        }
    }

    private func isle(_ yol: URL) {
        Servis.istek("/yazi", ["wav": yol.path, "temizle": temizle, "kaynak": kaynak]) { [weak self] json in
            guard let self = self else { return }
            self.durum = .bos
            self.gosterge.gizle()
            guard let json = json else {
                gunluk("servis yanıt vermedi")
                return
            }
            let metin = (json["metin"] as? String) ?? ""
            guard !metin.isEmpty else { return }
            self.sonMetin = metin
            SonDikte.kaydet(metin)
            self.menuKur()
            Yapistirici.yapistir(metin)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.izleyici.basla(metin) }
        }
    }
}

let uygulama = NSApplication.shared
let temsilci = Uygulama()
uygulama.delegate = temsilci
uygulama.setActivationPolicy(.accessory)
uygulama.run()
