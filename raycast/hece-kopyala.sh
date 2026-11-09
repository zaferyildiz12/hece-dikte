#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Hece Kopyala
# @raycast.mode silent
# @raycast.packageName Hece
# @raycast.icon 🎙️
# @raycast.description Son dikteyi panoya kopyalar (yazı alanı seçili değilken konuşulduysa)

# Hece.app her diktede metni bu dosyaya yazar.
dosya="$HOME/Library/Application Support/dikte/son-dikte.txt"
if [[ ! -s "$dosya" ]]; then
  echo "Henüz kayıtlı dikte yok"
  exit 1
fi
LC_ALL=en_US.UTF-8 pbcopy < "$dosya"
metin=$(head -c 60 "$dosya" | tr '\n' ' ')
echo "Kopyalandı: $metin…"
