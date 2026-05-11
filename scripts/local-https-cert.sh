#!/bin/sh
set -eu

dir="${FOLK_HTTPS_DIR:-$HOME/folk-data/https}"
mkdir -p "$dir"

unix_host="$(hostname)"
unix_host="${unix_host%.local}"
unix_short="${unix_host%%.*}"
bonjour_host=""
if [ "$(uname -s)" = "Darwin" ] && command -v scutil >/dev/null 2>&1; then
    bonjour_host="$(scutil --get LocalHostName 2>/dev/null || true)"
fi
bonjour_host="${bonjour_host%.local}"

cert_host="$bonjour_host"
if [ -z "$cert_host" ]; then cert_host="$unix_short"; fi
if [ -z "$cert_host" ]; then cert_host="localhost"; fi
case "$cert_host" in
    localhost) cert_dns="localhost" ;;
    *.*) cert_dns="$cert_host" ;;
    *) cert_dns="$cert_host.local" ;;
esac
ca_cn="Folk Local CA for $cert_dns"

tmp_ca="$(mktemp)"
tmp_leaf="$(mktemp)"
trap 'rm -f "$tmp_ca" "$tmp_leaf" "$dir/cert.csr"' EXIT

names=""
add_name() {
    name="$1"
    if [ -n "$name" ]; then
        case " $names " in *" $name "*) ;; *) names="$names $name";; esac
    fi
}
add_host_name() {
    name="${1%.}"
    if [ -z "$name" ]; then return; fi
    add_name "$name"
    case "$name" in
        localhost) ;;
        *.local) add_name "${name%.local}" ;;
        *.*) ;;
        *) add_name "$name.local" ;;
    esac
}
add_host_name "$cert_host"
add_host_name "$unix_host"
add_host_name "$unix_short"
add_name localhost

cat > "$tmp_ca" <<EOF_CA
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
CN = $ca_cn

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
EOF_CA

cat > "$tmp_leaf" <<EOF_LEAF
[req]
distinguished_name = req_distinguished_name
req_extensions = req_ext
prompt = no

[req_distinguished_name]
CN = $cert_dns

[req_ext]
subjectAltName = @alt_names

[server_cert]
subjectAltName = @alt_names
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[alt_names]
EOF_LEAF

dns_i=1
for name in $names; do
    printf 'DNS.%s = %s\n' "$dns_i" "$name" >> "$tmp_leaf"
    dns_i=$((dns_i + 1))
done
printf 'IP.1 = 127.0.0.1\n' >> "$tmp_leaf"

ca_needs_regen=0
if [ ! -f "$dir/ca.key" ] || [ ! -f "$dir/ca.pem" ]; then
    ca_needs_regen=1
else
    ca_subject="$(openssl x509 -in "$dir/ca.pem" -noout -subject 2>/dev/null || true)"
    ca_text="$(openssl x509 -in "$dir/ca.pem" -noout -text 2>/dev/null || true)"
    case "$ca_subject" in *"$ca_cn"*) ;; *) ca_needs_regen=1 ;; esac
    printf '%s\n' "$ca_text" | grep -q 'CA:TRUE' || ca_needs_regen=1
    printf '%s\n' "$ca_text" | grep -A1 'X509v3 Key Usage' | grep -q 'Certificate Sign' || ca_needs_regen=1
    printf '%s\n' "$ca_text" | grep -A1 'X509v3 Key Usage' | grep -q 'CRL Sign' || ca_needs_regen=1
fi

if [ "$ca_needs_regen" -eq 1 ]; then
    if [ -f "$dir/ca.pem" ] || [ -f "$dir/ca.key" ]; then
        stamp="$(date +%Y%m%d%H%M%S)"
        [ -f "$dir/ca.pem" ] && mv "$dir/ca.pem" "$dir/ca.pem.$stamp.bak"
        [ -f "$dir/ca.key" ] && mv "$dir/ca.key" "$dir/ca.key.$stamp.bak"
        [ -f "$dir/ca.srl" ] && mv "$dir/ca.srl" "$dir/ca.srl.$stamp.bak"
        printf 'Existing Folk HTTPS CA was incomplete or for another host; backed it up with suffix %s.\n' "$stamp"
    fi
    openssl genrsa -out "$dir/ca.key" 2048
    openssl req -x509 -new -nodes -key "$dir/ca.key" \
        -sha256 -days 3650 -config "$tmp_ca" \
        -out "$dir/ca.pem"
fi

openssl genrsa -out "$dir/key.pem" 2048
openssl req -new -key "$dir/key.pem" \
    -subj "/CN=$cert_dns" \
    -out "$dir/cert.csr" -config "$tmp_leaf"
openssl x509 -req -in "$dir/cert.csr" \
    -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -CAcreateserial \
    -out "$dir/cert.pem" -days 825 -sha256 \
    -extensions server_cert -extfile "$tmp_leaf"
openssl x509 -in "$dir/ca.pem" -outform der -out "$dir/ca.cer"

chmod 600 "$dir/key.pem" "$dir/ca.key"

printf 'Created Folk HTTPS certs in %s\n' "$dir"
printf 'Root CA subject: %s\n' "$ca_cn"
printf 'Install/trust %s or %s on LAN devices, then open https://%s:4273/screenshare\n' "$dir/ca.pem" "$dir/ca.cer" "$cert_dns"
printf 'When Folk is running with HTTPS, you can also download the CA from https://%s:4273/folk-ca.cer\n' "$cert_dns"
printf 'On iPhone/iPad, install the profile, then enable full trust in Settings > General > About > Certificate Trust Settings.\n'
printf 'In TLS mode, use https://localhost:4273/ locally; bare localhost:4273 is HTTP and will fail.\n'
