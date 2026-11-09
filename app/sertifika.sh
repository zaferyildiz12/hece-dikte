#!/bin/zsh
# Hece'yi sabit bir kimlikle imzalamak için yerel, kendinden imzalı kod imzalama sertifikası oluşturur.
# Sertifika giriş anahtar zincirine değil, ayrı bir anahtar zincirine (hece.keychain-db) konur.
set -e
KC=~/Library/Keychains/hece.keychain-db
T=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -keyout $T/k.pem -out $T/c.pem -days 3650 -nodes -subj "/CN=Hece Yerel" \
  -addext "extendedKeyUsage=critical,codeSigning" -addext "keyUsage=critical,digitalSignature" \
  -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -legacy -out $T/h.p12 -inkey $T/k.pem -in $T/c.pem -passout pass:hece
[[ -f $KC ]] || security create-keychain -p hece $KC
security unlock-keychain -p hece $KC
security set-keychain-settings $KC
security import $T/h.p12 -k $KC -P hece -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k hece $KC >/dev/null
security list-keychains -d user | grep -q hece.keychain || \
  security list-keychains -d user -s $(security list-keychains -d user | tr -d '"' | xargs) $KC
rm -rf $T
echo "Sertifika hazır: Hece Yerel ($KC)"
