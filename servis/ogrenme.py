"""Kendi kendine öğrenme: yapıştırılan dikte ile kullanıcının düzelttiği hali karşılaştırıp
yanlış duyulan kelimeleri sözlüğe `yanlış => doğru` olarak ekler.

Hammerspoon yapıştırmadan sonra ~20 sn boyunca odaktaki metin alanını okur ve son halini
POST /ogren ile gönderir. Alan bütün terminal ekranı ya da bütün mesaj kutusu olabilir;
dikte metnine en çok benzeyen bölüm bulunur, yalnız orada değişen kısa kelime grupları aday
olur. Adayların gerçekten yanlış duyma düzeltmesi mi, yoksa içerik değişikliği mi olduğuna
Claude karar verir.
"""
import difflib
import json
import os
import re
import subprocess
import time

ADAY_EN_COK_KELIME = 3        # bir düzeltmenin iki yanı da en çok bu kadar kelime olabilir
KELIME_BENZERLIK = 0.6       # büyük değişiklik içinde bu kadar benzeyen kelimeler tek tek çiftlenir
BENZERLIK_ESIGI = 0.6         # alandaki bölüm dikteye bu kadar benzemiyorsa (silinmiş/başka metin) öğrenme
OGRENILEN_BASLIK = "# Öğrenilenler (otomatik; yanlışsa satırı sil)"

KARAR_KURALLARI = """Bir dikte aracının öğrenme adımısın. Konuşma otomatik yazıya döküldü, kullanıcı yapıştırılan metni elle düzeltti.
Sana dikte metni, düzeltilmiş metin ve değişen kelime çiftleri verilecek. Her çift için karar ver:
- KABUL: ses tanıma yanlış duymuş, kullanıcı doğrusunu yazmış (sese benzeyen yanlış kelime, özel ad, marka, teknik terim, İngilizce kelime, ek hatası).
- RET: kullanıcı fikrini değiştirmiş ya da üslubu düzeltmiş (farklı anlamda kelime, ekleme/çıkarma, yeniden yazma, yazım zevki, büyük-küçük harf, noktalama).
- RET: yanlış taraf yaygın ve doğru yazılmış bir Türkçe kelimeyse (ettim, ile, ve, bir): sözlüğe girerse başka cümlelerde doğru kelimeyi bozar.
Emin değilsen RET ver. Yalnız JSON yaz: {"kabul": [{"yanlis": "...", "dogru": "..."}]}"""


def kelimeler(metin):
    # Terminal çerçeve karakterleri ve satır kaydırmaları kelime sayılmasın
    # Terminalde Claude Code'un durum satırları ("✢ Thinking…", "⏺ cevap") dikteye en yakın bölüme
    # karışıp "form takibi ✢" gibi sahte düzeltme üretiyordu; bu işaretleri taşıyan satırlar atılır
    metin = "\n".join(s for s in metin.split("\n") if not re.search(r"[✢✳✶✻✽✺⏺⎿]", s))
    metin = re.sub(r"[│┃║╭╮╰╯─━═▌▐█❯›>·•]+", " ", metin)
    return metin.split()


def sade(kelime):
    return kelime.strip(".,;:!?\"'()[]«»“”‘’").lower()


def bolumu_bul(dikte, alan):
    """Alandaki kelimelerden dikteye en çok benzeyen ardışık bölümü döndürür."""
    d = [sade(k) for k in dikte]
    a = [sade(k) for k in alan]
    eslesme = difflib.SequenceMatcher(None, a, d, autojunk=False)
    bloklar = [b for b in eslesme.get_matching_blocks() if b.size]
    en_iyi, en_iyi_puan, en_iyi_oran = None, None, 0
    # Her eşleşen parçanın hizasından başlayan, dikte boyuna yakın pencereleri dene
    for b in bloklar:
        for basla in {max(0, b.a - b.b + kayma) for kayma in range(-3, 4)}:
            for uzunluk in range(max(1, len(dikte) - 5), len(dikte) + 6):
                bitis = min(len(alan), basla + uzunluk)
                sm = difflib.SequenceMatcher(None, a[basla:bitis], d, autojunk=False)
                ortak_bloklar = [x for x in sm.get_matching_blocks() if x.size]
                ortak = sum(x.size for x in ortak_bloklar)
                bas_bosluk = ortak_bloklar[0].a if ortak_bloklar else 99
                # Önce en çok ortak kelime, sonra boyu dikteye en yakın, sonra başında yabancı kelime
                # olmayan pencere (sondaki düzeltme bir önceki kelimeye kaymasın)
                puan = (ortak, -abs((bitis - basla) - len(dikte)), -bas_bosluk)
                if en_iyi is None or puan > en_iyi_puan:
                    en_iyi, en_iyi_puan, en_iyi_oran = (basla, bitis), puan, sm.ratio()
    return (alan[en_iyi[0]:en_iyi[1]] if en_iyi else None), en_iyi_oran


def adaylar(dikte_metni, alan_metni):
    dikte = kelimeler(dikte_metni)
    alan = kelimeler(alan_metni)
    if not dikte or not alan:
        return [], None
    bolum, oran = bolumu_bul(dikte, alan)
    if not bolum or oran < BENZERLIK_ESIGI:
        return [], None
    sonuc = []
    eslesme = difflib.SequenceMatcher(None, [sade(k) for k in dikte], [sade(k) for k in bolum], autojunk=False)
    for islem, i1, i2, j1, j2 in eslesme.get_opcodes():
        if islem != "replace":
            continue
        eski, yeni = dikte[i1:i2], bolum[j1:j2]
        if len(eski) <= ADAY_EN_COK_KELIME and len(yeni) <= ADAY_EN_COK_KELIME:
            ciftler = [(eski, yeni)]
        else:
            # Büyük değişiklikte birbirine benzeyen kelimeleri tek tek eşle (Lukır -> Looker)
            ciftler = []
            for y in yeni:
                en = max(eski, key=lambda e: difflib.SequenceMatcher(None, sade(e), sade(y)).ratio())
                if difflib.SequenceMatcher(None, sade(en), sade(y)).ratio() >= KELIME_BENZERLIK:
                    ciftler.append(([en], [y]))
        for e, y in ciftler:
            eski_m = " ".join(k.strip(".,;:!?\"()") for k in e)
            yeni_m = " ".join(k.strip(".,;:!?\"()") for k in y)
            if eski_m and yeni_m and eski_m.lower() != yeni_m.lower():
                sonuc.append({"yanlis": eski_m, "dogru": yeni_m})
    return sonuc, " ".join(bolum)


def claude_karar(dikte_metni, duzeltilmis, ciftler):
    istem = json.dumps({"dikte": dikte_metni, "duzeltilmis": duzeltilmis, "ciftler": ciftler}, ensure_ascii=False)
    r = subprocess.run(
        ["claude", "-p", "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
         "--model", os.environ.get("DIKTE_MODEL", "sonnet"), "--effort", "low",
         "--system-prompt", KARAR_KURALLARI, istem],
        capture_output=True, text=True, timeout=90, cwd="/tmp")
    eslesme = re.search(r"\{.*\}", r.stdout, re.S)
    if not eslesme:
        return []
    try:
        kabul = json.loads(eslesme.group(0)).get("kabul", [])
    except ValueError:
        return []
    gecerli = {(c["yanlis"], c["dogru"]) for c in ciftler}
    return [k for k in kabul if (k.get("yanlis"), k.get("dogru")) in gecerli]


def sozluge_ekle(sozluk_yolu, kabuller):
    """Kabul edilen düzeltmeleri sözlüğün başındaki Öğrenilenler bölümüne yazar; olanı tekrar yazmaz."""
    with open(sozluk_yolu, encoding="utf-8") as f:
        satirlar = f.read().split("\n")
    mevcut = set()
    for s in satirlar:
        if "=>" in s and not s.lstrip().startswith("#"):
            sol, sag = s.split("#", 1)[0].split("=>", 1)
            for y in sol.split(","):
                mevcut.add((y.strip().lower(), sag.strip()))
    yeniler = [k for k in kabuller if (k["yanlis"].lower(), k["dogru"]) not in mevcut]
    if not yeniler:
        return []
    tarih = time.strftime("%Y-%m-%d")
    eklenecek = [f"{k['yanlis']} => {k['dogru']}  # {tarih}" for k in yeniler]
    if OGRENILEN_BASLIK in satirlar:
        i = satirlar.index(OGRENILEN_BASLIK) + 1
    else:
        # İlk boş satırdan (açıklama bloğunun sonu) sonra yeni bölüm aç
        i = next((n for n, s in enumerate(satirlar) if not s.strip()), len(satirlar)) + 1
        satirlar[i:i] = [OGRENILEN_BASLIK, ""]
        i += 1
    satirlar[i:i] = eklenecek
    with open(sozluk_yolu, "w", encoding="utf-8") as f:
        f.write("\n".join(satirlar))
    return yeniler
