#!/bin/zsh
# Hece kurulumu (macOS, Apple Silicon). Tekrar çalıştırmak güvenlidir.
#   ./kurulum.sh            kur / güncelle
#   ./kurulum.sh --kaldir   servisi ve Hammerspoon bağlantısını kaldır (dosyalara dokunmaz)
set -e
KOK=${0:A:h}
ETIKET=com.hece.dikte
PLIST=~/Library/LaunchAgents/$ETIKET.plist
MODEL_KLASOR=~/Library/Application\ Support/dikte/models
MODEL=$MODEL_KLASOR/ggml-large-v3-q5_0.bin
PYTHON=${PYTHON:-$(command -v python3)}

if [[ $1 == --kaldir ]]; then
  launchctl bootout gui/$(id -u)/$ETIKET 2>/dev/null || true
  rm -f $PLIST
  sed -i '' '/dikte\/hammerspoon\/dikte.lua\|hece.*dikte.lua/d' ~/.hammerspoon/init.lua 2>/dev/null || true
  echo "Kaldırıldı. Model: $MODEL_KLASOR"
  exit 0
fi

echo "1/5 Bağımlılıklar (Homebrew)"
command -v brew >/dev/null || { echo "Homebrew gerekli: https://brew.sh"; exit 1; }
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
[[ -d /Applications/Hammerspoon.app ]] || brew install --cask hammerspoon
command -v claude >/dev/null || echo "   Uyarı: Claude Code (claude) yok; temizleme adımı çalışmaz, ham metin yapıştırılır."

echo "2/5 Yerel yedek model (Whisper large-v3, ~1 GB)"
mkdir -p $MODEL_KLASOR
[[ -f $MODEL ]] || curl -L --fail -o $MODEL https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin

echo "3/5 Kaydedici derleniyor"
swiftc -O $KOK/kaydedici/kaydedici.swift -o $KOK/kaydedici/kaydedici

echo "4/5 Arka plan servisi ($ETIKET)"
[[ -f $KOK/sozluk.txt ]] || cp $KOK/sozluk.ornek.txt $KOK/sozluk.txt
cat > $PLIST <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$ETIKET</string>
  <key>ProgramArguments</key>
  <array><string>$PYTHON</string><string>$KOK/servis/dikte.py</string></array>
  <key>WorkingDirectory</key><string>$KOK/servis</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/dikte.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/dikte.log</string>
</dict>
</plist>
EOF
launchctl bootout gui/$(id -u)/$ETIKET 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $PLIST

echo "5/5 Hammerspoon"
mkdir -p ~/.hammerspoon
touch ~/.hammerspoon/init.lua
grep -q "$KOK/hammerspoon/dikte.lua" ~/.hammerspoon/init.lua || \
  printf 'hs.autoLaunch(true)\ndikte = dofile("%s/hammerspoon/dikte.lua")\n' "$KOK" >> ~/.hammerspoon/init.lua
open -a Hammerspoon

cat <<EOF

Kuruldu. Son adımlar:
  • Hammerspoon'a Erişilebilirlik izni ver (Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik),
    sonra menü çubuğundaki Hammerspoon simgesinden "Reload Config".
  • İlk kayıtta mikrofon iznini onayla.
  • Bulut ses tanıma için ElevenLabs anahtarını Anahtar Zinciri'ne ekle:
      security add-generic-password -s elevenlabs -a \$USER -w "ANAHTARIN"
    Anahtar yoksa araç kendiliğinden yerel Whisper'a döner.
Kullanım: sağ ⌘ basılı tut, konuş, bırak.
EOF
