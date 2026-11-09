-- Dikte: sağ Command ile kayıt, yerel servis ile yazıya dökme, imlecin olduğu yere yapıştırma.
--   Basılı tut: konuştuğun sürece kaydeder, bırakınca yapıştırır.
--   Kısa basışlar yok sayılır (yanlışlıkla basınca açılmasın diye).
--   Esc: kaydı iptal eder.  Sağ Command ile kısayol yaparsan (⌘C gibi) kayıt sessizce iptal olur.
--   Öğrenme: yapıştırdıktan sonra 20 sn odaktaki metin alanını okur; düzeltme yaptıysan servis
--   yanlış duyulan kelimeyi sözlüğe ekler ve bildirim gösterir.

local M = {}

-- Aracın kök klasörü (bu dosya <kök>/hammerspoon/dikte.lua)
local KLASOR = debug.getinfo(1, "S").source:match("^@(.*)/hammerspoon/[^/]*$")

local AYAR = {
  sagCmdMaske = 0x10,          -- NX_DEVICERCMDKEYMASK
  sagCmdTus = 54,
  escTus = 53,
  etkinlesmeSure = 0.4,        -- sn; bundan kısa basış yanlışlık sayılır ve atılır
  kuyrukSure = 0.4,            -- sn; tuş bırakılınca kayıt bu kadar sürer (son hece kesilmesin;
                               -- kesik hece Scribe'da sözlükteki bir marka adına dönüşüyordu)
  kaydedici = KLASOR .. "/kaydedici/kaydedici",
  servis = "http://127.0.0.1:8766/yazi",
  ogrenmeServis = "http://127.0.0.1:8766/ogren",
  izlemeSure = 30,             -- sn; yapıştırmadan sonra düzeltme için izleme süresi
  izlemeAralik = 2,
  enterTus = 36,
  -- Enter'ın mesajı gönderdiği uygulamalar: Enter'da izleme hemen biter (✓ beklemeden gelir).
  -- Diğerlerinde (Sublime vb.) Enter yeni satırdır, izleme süresince devam eder.
  enterGonderir = { ["com.cmuxterm.app"] = true, ["com.tinyspeck.slackmacgap"] = true,
                    ["net.whatsapp.WhatsApp"] = true, ["com.apple.MobileSMS"] = true },
  -- Terminalde Enter anındaki ekran yarım çizilmiş olabiliyor ("Piwik PRO vicypro" artığı);
  -- gönderilen mesaj ekrana temiz yazıldıktan sonra bir kez daha okunur.
  enterSonraOku = { ["com.cmuxterm.app"] = 1.5 },
  kayitKlasoru = os.getenv("HOME") .. "/Library/Application Support/dikte",
  sozluk = KLASOR .. "/sozluk.txt",
  gunluk = os.getenv("HOME") .. "/Library/Logs/dikte.log",
}

-- bos | hazirlik (tuş basılı, kayıt sürüyor ama henüz etkin sayılmadı) | kayit | isleniyor
local durum = "bos"
local sagCmdBasili = false
local etkinlesmeZamanlayici = nil
local kayitYolu = nil
local sonMetin = ""
local temizle = hs.settings.get("dikte.temizle")
if temizle == nil then temizle = true end
local kaynak = hs.settings.get("dikte.kaynak") or "bulut"   -- bulut (ElevenLabs Scribe) | yerel (Whisper)

local menu = hs.menubar.new()

-- Ekranın alt ortasında küçük koyu gösterge: kayıtta mikrofon, işlenirken kum saati.
local gosterge = nil
local ogrendiZamanlayici = nil

local function gostergeHazirla()
  local ekran = hs.screen.mainScreen():frame()
  local g, y = 64, 30
  local cerceve = { x = ekran.x + (ekran.w - g) / 2, y = ekran.y + ekran.h - y - 60, w = g, h = y }
  if not gosterge then
    gosterge = hs.canvas.new(cerceve)
    gosterge:level(hs.canvas.windowLevels.overlay)
    gosterge:behavior({ "canJoinAllSpaces", "stationary" })
    gosterge[1] = { type = "rectangle", action = "strokeAndFill", roundedRectRadii = { xRadius = 15, yRadius = 15 },
                    strokeColor = { white = 1, alpha = 0.35 }, strokeWidth = 1 }
    gosterge[2] = { type = "text", textSize = 16, textAlignment = "center",
                    frame = { x = 10, y = 4, w = g - 10, h = y } }
    gosterge[3] = { type = "circle", action = "fill", center = { x = 15, y = y / 2 }, radius = 4 }
  end
  gosterge:frame(cerceve)
end

local function gostergeGuncelle()
  if durum == "bos" or durum == "hazirlik" then
    if gosterge and not ogrendiZamanlayici then gosterge:hide() end
    return
  end
  if ogrendiZamanlayici then ogrendiZamanlayici:stop(); ogrendiZamanlayici = nil end
  gostergeHazirla()
  gosterge[2].textColor = { white = 1 }
  if durum == "kayit" then
    gosterge[1].fillColor = { white = 0.1, alpha = 0.92 }
    gosterge[2].text = "🎙"
    gosterge[3].fillColor = { red = 1, green = 0.23, blue = 0.19, alpha = 1 }
  else
    gosterge[1].fillColor = { white = 0.1, alpha = 0.92 }
    gosterge[2].text = "⏳"
    gosterge[3].fillColor = { white = 1, alpha = 0 }
  end
  gosterge:show()
end

-- Öğrenince aynı yerde 2,5 sn yeşil ✓
local function ogrendiGoster()
  if durum ~= "bos" then return end
  gostergeHazirla()
  gosterge[1].fillColor = { white = 0.1, alpha = 0.92 }
  gosterge[2].text = "✓"
  gosterge[2].textColor = { red = 0.2, green = 0.85, blue = 0.35, alpha = 1 }
  gosterge[3].fillColor = { red = 0.2, green = 0.85, blue = 0.35, alpha = 1 }
  gosterge:show()
  if ogrendiZamanlayici then ogrendiZamanlayici:stop() end
  ogrendiZamanlayici = hs.timer.doAfter(2.5, function()
    ogrendiZamanlayici = nil
    if durum == "bos" and gosterge then gosterge:hide() end
  end)
end

local function simgeGuncelle()
  local simge = ({ bos = "🎙", hazirlik = "🎙", kayit = "🔴", isleniyor = "⏳" })[durum]
  menu:setTitle(simge)
  gostergeGuncelle()
end

local function yapistir(metin)
  local eski = hs.pasteboard.readAllData()
  hs.pasteboard.setContents(metin)
  hs.timer.doAfter(0.05, function()
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    hs.timer.doAfter(0.8, function()
      if eski then hs.pasteboard.writeAllData(eski) end
    end)
  end)
end

-- Düzeltme izleme ----------------------------------------------------------
local izleme = nil   -- { metin, uygulama, alan, zamanlayici, bitis }
local electronAcik = {}

local function odakMetni()
  local ok, deger = pcall(function()
    local odak = hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
    return odak and odak:attributeValue("AXValue")
  end)
  if ok and type(deger) == "string" then return deger end
  return nil
end

local function izlemeBitir()
  if not izleme then return end
  local i = izleme
  izleme = nil
  if i.zamanlayici then i.zamanlayici:stop() end
  -- Alan okunamadıysa ya da yapıştırılan metin aynen duruyorsa öğrenilecek bir şey yok
  if not i.alan then
    print("dikte öğrenme: alan okunamadı (" .. tostring(i.uygulama) .. ")")
    return
  end
  if i.alan:find(i.metin, 1, true) then
    print("dikte öğrenme: değişiklik yok (" .. tostring(i.uygulama) .. ")")
    return
  end
  print("dikte öğrenme: fark gönderiliyor (" .. tostring(i.uygulama) .. ")")
  local alan = i.alan
  if #alan > 20000 then alan = alan:sub(-20000) end
  hs.http.asyncPost(AYAR.ogrenmeServis, hs.json.encode({ dikte = i.metin, alan = alan }),
    { ["Content-Type"] = "application/json" }, function(kod, cevap)
      if kod ~= 200 then return end
      local veri = hs.json.decode(cevap) or {}
      local satirlar = {}
      for _, k in ipairs(veri.ogrenilen or {}) do table.insert(satirlar, k.yanlis .. " → " .. k.dogru) end
      if #satirlar > 0 then
        ogrendiGoster()
        hs.notify.new({ title = "Dikte öğrendi", informativeText = table.concat(satirlar, "\n"),
                        withdrawAfter = 8 }):send()
      end
    end)
end

local function izlemeOku()
  if not izleme then return end
  local onde = hs.application.frontmostApplication()
  if not onde or onde:bundleID() ~= izleme.uygulama then return end
  local deger = odakMetni()
  if deger then izleme.alan = deger end
end

local function izlemeBaslat(metin)
  izlemeBitir()
  local uygulama = hs.application.frontmostApplication()
  if not uygulama then return end
  local kimlik = uygulama:bundleID()
  -- Electron uygulamaları (Slack vb.) metin alanını ancak bu bayrakla açar
  if not electronAcik[kimlik] then
    pcall(function()
      hs.axuielement.applicationElement(uygulama):setAttributeValue("AXManualAccessibility", true)
    end)
    electronAcik[kimlik] = true
  end
  izleme = { metin = metin, uygulama = kimlik, alan = nil,
             bitis = hs.timer.secondsSinceEpoch() + AYAR.izlemeSure }
  izleme.zamanlayici = hs.timer.doEvery(AYAR.izlemeAralik, function()
    izlemeOku()
    if izleme and hs.timer.secondsSinceEpoch() >= izleme.bitis then izlemeBitir() end
  end)
end

local function isle(yol)
  durum = "isleniyor"
  simgeGuncelle()
  local govde = hs.json.encode({ wav = yol, temizle = temizle, kaynak = kaynak })
  hs.http.asyncPost(AYAR.servis, govde, { ["Content-Type"] = "application/json" }, function(kod, cevap)
    durum = "bos"
    simgeGuncelle()
    if kod ~= 200 then
      hs.alert.show("Dikte servisi yanıt vermedi (" .. tostring(kod) .. ")")
      return
    end
    local veri = hs.json.decode(cevap) or {}
    local metin = veri.metin or ""
    if metin == "" then return end
    sonMetin = metin
    yapistir(metin)
    hs.timer.doAfter(1, function() izlemeBaslat(metin) end)
  end)
end

-- Kayıt, sürekli açık duran kaydedici/kaydedici ile yapılır (mikrofonu ~0,1 sn'de açar;
-- ffmpeg ~0,9 sn kaybediyor, kısa sözlerin ilk heceleri kayda girmiyordu).
local kaydedici = nil
local kayitSuruyor = false

local function kaydediciBaslat()
  kaydedici = hs.task.new(AYAR.kaydedici, function(kod)
    print("dikte: kaydedici kapandı (" .. tostring(kod) .. "), yeniden açılıyor")
    kaydedici = nil
    kayitSuruyor = false
    if durum ~= "isleniyor" then durum = "bos"; simgeGuncelle() end
    hs.timer.doAfter(1, kaydediciBaslat)
  end, function(_, cikti)
    for satir in (cikti or ""):gmatch("[^\n]+") do
      local yol = satir:match("^bitti (.+)$")
      if yol then
        isle(yol)
      elseif satir == "iptal" then
        durum = "bos"
        simgeGuncelle()
      elseif satir:match("^hata") then
        print("dikte kaydedici: " .. satir)
        durum = "bos"
        simgeGuncelle()
      end
    end
    return true
  end)
  kaydedici:start()
end
kaydediciBaslat()

local function kayitBaslat()
  izlemeBitir()                  -- yeni dikte başlarken önceki izlemenin son halini gönder
  if not kaydedici then return end
  hs.fs.mkdir(AYAR.kayitKlasoru)
  kayitYolu = AYAR.kayitKlasoru .. "/kayit-" .. os.time() .. ".wav"
  kaydedici:setInput("basla " .. kayitYolu .. "\n")
  kayitSuruyor = true
  -- Kayıt hemen başlar ki ilk heceler kaçmasın; gösterge ancak tuş yeterince basılı kalınca çıkar
  durum = "hazirlik"
  etkinlesmeZamanlayici = hs.timer.doAfter(AYAR.etkinlesmeSure, function()
    if durum == "hazirlik" then
      durum = "kayit"
      simgeGuncelle()
    end
  end)
end

local function kayitDurdur(iptal)
  if not kayitSuruyor or not kaydedici then return end
  kayitSuruyor = false
  if etkinlesmeZamanlayici then etkinlesmeZamanlayici:stop() end
  if iptal then
    kaydedici:setInput("iptal\n")
    return
  end
  durum = "isleniyor"
  simgeGuncelle()
  hs.timer.doAfter(AYAR.kuyrukSure, function()
    if kaydedici then kaydedici:setInput("dur\n") end
  end)
end

local function sagCmd(basildi)
  if basildi then
    if durum == "bos" then kayitBaslat() end
  elseif durum == "hazirlik" then
    kayitDurdur(true)            -- kısa basış: yanlışlık, at
  elseif durum == "kayit" then
    kayitDurdur(false)
  end
end

M.dinleyici = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged, hs.eventtap.event.types.keyDown }, function(e)
  local tip = e:getType()
  if tip == hs.eventtap.event.types.flagsChanged then
    if e:getKeyCode() == AYAR.sagCmdTus then
      local basili = (e:rawFlags() & AYAR.sagCmdMaske) ~= 0
      if basili ~= sagCmdBasili then
        sagCmdBasili = basili
        sagCmd(basili)
      end
    end
    return false
  end
  -- keyDown
  -- Enter mesajı gönderip alanı boşaltabilir (Slack, WhatsApp); göndermeden hemen önce son hali al
  if izleme and e:getKeyCode() == AYAR.enterTus then
    izlemeOku()
    local bekle = AYAR.enterSonraOku[izleme.uygulama]
    if bekle then
      if izleme.zamanlayici then izleme.zamanlayici:stop() end
      local i = izleme
      hs.timer.doAfter(bekle, function()
        if izleme == i then
          izlemeOku()
          izlemeBitir()
        end
      end)
    elseif AYAR.enterGonderir[izleme.uygulama] then
      izlemeBitir()
    end
  end
  if durum == "kayit" or durum == "hazirlik" then
    if e:getKeyCode() == AYAR.escTus then
      kayitDurdur(true)
      return true
    end
    if sagCmdBasili then
      kayitDurdur(true)          -- sağ Command bir kısayolun parçasıymış
    end
  end
  return false
end)
M.dinleyici:start()

menu:setMenu(function()
  return {
    { title = "Sağ ⌘ basılı tut, konuş, bırak", disabled = true },
    { title = "-" },
    { title = "Ses tanıma: Bulut (ElevenLabs)", checked = kaynak == "bulut", fn = function()
        kaynak = "bulut"
        hs.settings.set("dikte.kaynak", kaynak)
      end },
    { title = "Ses tanıma: Yerel (Whisper)", checked = kaynak == "yerel", fn = function()
        kaynak = "yerel"
        hs.settings.set("dikte.kaynak", kaynak)
      end },
    { title = "-" },
    { title = "Claude ile temizle", checked = temizle, fn = function()
        temizle = not temizle
        hs.settings.set("dikte.temizle", temizle)
      end },
    { title = "Son metni kopyala", disabled = sonMetin == "", fn = function()
        hs.pasteboard.setContents(sonMetin)
      end },
    { title = "Sözlüğü aç", fn = function() hs.execute("open -t '" .. AYAR.sozluk .. "'") end },
    { title = "Servis günlüğü", fn = function() hs.execute("open -a Console '" .. AYAR.gunluk .. "'") end },
  }
end)
simgeGuncelle()

-- Hammerspoon dinleyiciyi uzun süre sonra kapatabiliyor; açık tut.
M.bekci = hs.timer.doEvery(30, function()
  if not M.dinleyici:isEnabled() then M.dinleyici:start() end
end)

return M
