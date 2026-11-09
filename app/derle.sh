#!/bin/zsh
# Hece.app'i derler ve imzalar: ./app/derle.sh        → ~/Library/Caches/Hece/Hece.app
#                                ./app/derle.sh --kur  → ayrıca /Applications/Hece.app'e kurar ve yeniden açar
# Derleme Masaüstü dışında yapılır: iCloud'lu Masaüstü dosyalara ek öznitelik ekleyip imzayı bozuyor.
# İmza: "Hece Yerel" kod imzalama sertifikası (ayrı hece.keychain-db içinde) varsa onunla; böylece
# Erişilebilirlik/Mikrofon izinleri yeniden derlemede korunur. Yoksa geçici (ad-hoc) imza atılır ve
# her derlemeden sonra izinlerin yeniden verilmesi gerekir. Sertifikayı oluşturmak: ./app/sertifika.sh
set -e
D=${0:A:h}
APP=~/Library/Caches/Hece/Hece.app
KC=~/Library/Keychains/hece.keychain-db
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $D/Info.plist $APP/Contents/Info.plist
cp $D/Resources/* $APP/Contents/Resources/
swiftc -O -o $APP/Contents/MacOS/Hece $D/Sources/*.swift
xattr -cr $APP                       # Masaüstü dosyalarındaki ek öznitelikler imzayı bozuyor
KIMLIK=-
if [[ -f $KC ]] && security find-identity -p codesigning $KC 2>/dev/null | grep -q "Hece Yerel"; then
  security unlock-keychain -p hece $KC
  KIMLIK="Hece Yerel"
fi
codesign --force --sign "$KIMLIK" --identifier com.hece.app $APP
codesign -v $APP
echo "Derlendi: $APP (imza: $KIMLIK)"
if [[ $1 == --kur ]]; then
  pkill -x Hece 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Hece.app
  ditto $APP /Applications/Hece.app
  open /Applications/Hece.app
  echo "Kuruldu: /Applications/Hece.app"
fi
