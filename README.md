# Hece

Mac için Türkçe odaklı, bas-konuş dikte aracı. Sağ ⌘'yi basılı tut, konuş, bırak: metin imlecin olduğu yere yapıştırılır. Düzelttiğin kelimeleri fark edip bir dahakine doğru yazmayı öğrenir.

*Push-to-talk dictation for macOS, tuned for Turkish with English tech terms. Speech → ElevenLabs Scribe (or local Whisper) → cleanup with Claude → paste. Learns from your corrections.*

## Nasıl çalışır

1. **Kayıt:** Sağ ⌘ basılı tutulurken küçük bir Swift kaydedici mikrofonu ~0,1 sn'de açar (ilk hece kaçmasın). Bırakınca 0,4 sn daha kaydeder (son hece kesilmesin). 0,4 sn'den kısa basışlar yanlışlık sayılıp atılır; Esc kaydı iptal eder.
2. **Yazıya dökme:** Varsayılan ElevenLabs **Scribe v2** (bulut). Anahtar yoksa, internet yoksa ya da hata olursa Mac'te **Whisper large-v3** (whisper.cpp) devreye girer. Menüden "Yerel" seçilirse ses Mac'ten hiç çıkmaz.
3. **Temizleme:** Metin, sürekli açık bir Claude Code oturumunda (`claude -p`; abonelikle çalışır, API anahtarı gerekmez) düzeltilir: yazım, ekler, noktalama, sözlükteki terimler, sesli işaretler ("alt tire" → `_`), "salı, yok çarşamba" gibi kendini düzeltmeler. Model cevap vermez, yalnız metni düzeltir; çıktı şüpheli uzunsa ham metin kullanılır.
4. **Yapıştırma:** Pano geçici kullanılır, eski içerik geri konur.
5. **Öğrenme:** Yapıştırdıktan sonra yazdığın alan Erişilebilirlik ile okunur. Bir kelimeyi düzeltirsen fark bulunur; Claude bunun yanlış duyma mı yoksa fikir değişikliği mi olduğuna karar verir. Yanlış duymaysa `sozluk.txt` dosyasına `yanlış => doğru` olarak yazılır ve göstergenin yerinde 5 sn "✓ Öğrendim: yanlış → doğru" yazar. Enter'ın mesaj gönderdiği uygulamalarda (terminal, Slack, WhatsApp, Mesajlar) karar Enter'da, diğerlerinde 30 sn sonra verilir.

Hece Dock'ta durmaz; uygulamayı açınca ayar penceresi gelir, kapatınca menü çubuğuna çekilir. Gösterge ekranın alt ortasında küçük, koyu bir kutudur: kayıtta yeşil mikrofon, işlenirken kum saati, öğrenince yeşil ✓.

## Kurulum

Gereken: macOS (Apple Silicon), [Homebrew](https://brew.sh), Xcode Command Line Tools (`swiftc`), Python 3. Temizleme için [Claude Code](https://claude.com/claude-code) (isteğe bağlı), bulut ses tanıma için bir ElevenLabs hesabı (isteğe bağlı).

```bash
git clone https://github.com/zaferyildiz12/hece-dikte.git
cd hece-dikte
./kurulum.sh
```

Betik whisper.cpp ve Hammerspoon'u kurar, yedek modeli indirir (~1 GB), kaydediciyi derler, arka plan servisini (`com.hece.dikte`) başlatır ve Hammerspoon'a bağlar. Sonra:

- Hammerspoon'a **Erişilebilirlik** izni ver ve yapılandırmayı yeniden yükle; ilk kayıtta **Mikrofon** iznini onayla.
- ElevenLabs anahtarını Anahtar Zinciri'ne ekle (anahtar hiçbir dosyaya yazılmaz):
  ```bash
  security add-generic-password -s elevenlabs -a "$USER" -w "ANAHTARIN"
  ```

Kaldırmak: `./kurulum.sh --kaldir`.

## Hece.app (v2, geliştiriliyor)

`app/` klasöründe Hammerspoon ve ayrı kaydedicinin yerini alan menü çubuğu uygulaması var (Swift, tek dosya `app/Sources/main.swift`): sağ ⌘ kısayolu, kayıt, gösterge, yapıştırma, düzeltme izleme ve menü (Bulut/Yerel, temizleme, sözlük, girişte aç). Yazıya dökme, temizleme ve öğrenme için aynı servisi (`servis/dikte.py`) kullanır.

```bash
./app/sertifika.sh   # bir kez: izinlerin yeniden derlemede korunması için yerel imza sertifikası
./app/derle.sh       # app/build/Hece.app
```

Hece.app'i çalıştırmadan önce Hammerspoon'daki dikte satırını kapat (ikisi aynı anda sağ ⌘'yi dinlememeli). İlk açılışta Erişilebilirlik ve Mikrofon izni ister.

## Sözlük

`sozluk.txt` kişiseldir; yoksa ilk çalıştırmada `sozluk.ornek.txt`'den oluşur. Sözlük git'e girmez. Kendi fork'unda sözlüğü de saklamak istersen `.gitignore`'dan çıkar ve `DIKTE_GIT_GONDER=1` ver; öğrenilen satırlar kendiliğinden commit edilip gönderilir. Menü çubuğundaki 🎙 → "Sözlüğü aç".

```
# Öğrenilenler (otomatik; yanlışsa satırı sil)
Lukır => Looker  # 2026-10-21

# Sık yanlış duyulanlar
Concert Mode, Konsent Mod => Consent Mode

# Terimler
GA4
dataLayer
```

## Parçalar

| Yol | Ne yapar |
|---|---|
| `hammerspoon/dikte.lua` | Kısayol, gösterge, yapıştırma, düzeltme izleme, menü |
| `kaydedici/kaydedici.swift` | Hızlı açılan mikrofon kaydedici (AVAudioEngine, 16 kHz mono WAV) |
| `servis/dikte.py` | 127.0.0.1:8766 servisi: Scribe / whisper-server, Claude oturumu, `/yazi` ve `/ogren` uçları |
| `servis/ogrenme.py` | Düzeltme farkını bulma, Claude kararı, sözlüğe yazma |

Ayarlar ortam değişkeniyle: `DIKTE_MODEL` (Claude modeli, varsayılan `sonnet`), `DIKTE_ANAHTAR_SERVIS` (Anahtar Zinciri servis adı), `ELEVENLABS_API_KEY`, `DIKTE_GIT_GONDER=1` (öğrenilen sözlüğü git'e gönder), `DIKTE_KAYIT_SAKLA=1` (kayıtları teşhis için sakla). Günlük: `~/Library/Logs/dikte.log`.

## Gizlilik

- Bulut modunda ses ElevenLabs'a, metin Claude'a gider. Yerel modda ses Mac'ten çıkmaz (temizleme açıksa metin yine Claude'a gider; menüden kapatılabilir).
- Öğrenme için okunan ekran metni yalnız yerel servise gider; Claude'a yalnız dikte cümlesi ve düzeltilen bölüm gönderilir.
- Kayıtlar işlendikten sonra silinir.

## Lisans

MIT
