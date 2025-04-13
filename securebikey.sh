#!/bin/bash

MICROSOFT_GUID=77fa9abd-0359-4d32-bd60-28f4e78f784b
CUSTOM_GUID=$(systemd-id128 new --uuid)
certdir="$(dirname "$(readlink -f "$0")")/build/certs"
authdir="$(dirname "$(readlink -f "$0")")/mkosi.extra/efi/loader/keys/sbkeys"
tmpdir=$(mktemp -d)
declare -A yubikey_piv_slots=(
	["PK"]=95
	["KEK"]=94
	["db"]=93
	["verity"]=92
	["pcr"]=91
)

out() { printf "$1 $2\n" "${@:3}"; }
error() { out "==> ERROR:" "$@"; } >&2
msg() { out "==>" "$@"; }
msg2() { out "  ->" "$@"; }
die() {
	error "$@"
	exit 1
}

verify_packages_installed() {
	local p
	for p in "$@"; do
		pacman -Qi "$p" &>/dev/null || die "package '$p' was not found"
	done
}

gen_yubikeycerts() {
	local key
	local slot
	local subj
	msg 'Generating credentials on Yubikey'
	for key in "${!yubikey_piv_slots[@]}"; do
		slot="${yubikey_piv_slots[$key]}"
		[[ $key =~ KEK|PK|db ]] && subj="CN=SecureBoot ${key}" || subj="CN=Ligmarch ${key}"
		msg2 "Generating ${key} key on slot ${slot}"
		ykman piv keys generate \
			--algorithm RSA2048 \
			--format PEM \
			--pin-policy ONCE \
			--touch-policy CACHED \
			"${slot}" "${key}.pub"
		msg2 "Generating certificate on slot ${slot}"
		ykman piv certificates generate \
			--hash-algorithm SHA256 \
			--valid-days 3650 \
			--subject "${subj}" \
			"${slot}" "${key}.pub"
		msg2 "Exporting certificate on slot ${slot}"
		ykman piv certificates export --format PEM "${slot}" "${key}.crt"
		[[ $key =~ db|verity|pcr ]] && cp "$_" "${certdir}/$_"
	done
}

get_microsoft_certs() {
	msg 'Acquiring Microsoft secure boot certificates'
	curl --location -s \
		"https://go.microsoft.com/fwlink/p/?linkid=321192" -o ms-db-2011.cer \
		"https://go.microsoft.com/fwlink/p/?linkid=321194" -o ms-uefi-db-2011.cer \
		"https://go.microsoft.com/fwlink/p/?linkid=2239776" -o ms-db-2023.cer \
		"https://go.microsoft.com/fwlink/p/?linkid=2239872" -o ms-uefi-db-2023.cer
	msg2 'Verifying certificate hashes'
	sha1sum -c <<-EOF
		580a6f4cc4e4b669b9ebdc1b2b3e087b80d0678d  ms-db-2011.cer
		46def63b5ce61cf8ba0de2e6639c1019d0ed14f3  ms-uefi-db-2011.cer
		45a0fa32604773c82433c3b7d59e7466b3ac0c67  ms-db-2023.cer
		b5eeb4a6706048073f0ed296e7f580a790b59eaa  ms-uefi-db-2023.cer
	EOF
}

gen_siglists() {
	local cert
	msg 'Generating EFI signature lists'
	for cert in ms-*.cer; do
		openssl x509 -inform DER -outform PEM -in "${cert}" -out "${cert%cer}crt"
		cert-to-efi-sig-list -g "${MICROSOFT_GUID}" "${_}" "${_%crt}esl"
	done
	for cert in KEK PK db; do
		cert-to-efi-sig-list -g "${CUSTOM_GUID}" "${cert}.crt" "${cert}.esl"
	done
	# Add Microsoft Windows certificates (needed to boot into Windows).
	cat ms-db-*.esl >>db.esl
	# Add Microsoft UEFI certificates for firmware drivers / option ROMs
	# and third-party boot loaders.
	cat ms-uefi-*.esl >>db.esl
}

sign_efi_vars() {
	local key
	msg 'Signing EFI signature lists'
	for key in PK KEK; do
		msg2 "Signing esl for ${key} (pay attention to yubikey in case touch required)"
		sign-efi-sig-list \
			-t "$(date --date='1 second' +'%Y-%m-%d %H:%M:%S')" \
			-g "${CUSTOM_GUID}" \
			-e pkcs11 \
			-k "pkcs11:object=Private key for Retired Key $((16#${yubikey_piv_slots[PK]} - 16#81));type=private" \
			-c "PK.crt" \
			"${key}" "${key}.esl" "${authdir}/${key}.auth"
	done
	msg2 "Signing esl for db (pay attention to yubikey in case touch required)"
	sign-efi-sig-list \
		-t "$(date --date='1 second' +'%Y-%m-%d %H:%M:%S')" \
		-g "${CUSTOM_GUID}" \
		-e pkcs11 \
		-k "pkcs11:object=Private key for Retired Key $((16#${yubikey_piv_slots[KEK]} - 16#81));type=private" \
		-c "KEK.crt" \
		db "db.esl" "${authdir}/db.auth"
}

trap 'rm -rf "$tmpdir"' EXIT
[[ -d "${certdir}" ]] || mkdir -p "${certdir}"
[[ -d "${authdir}" ]] || mkdir -p "${authdir}"
cd "$tmpdir" || exit
verify_packages_installed yubikey-manager yubico-piv-tool efitools openssl
gen_yubikeycerts
get_microsoft_certs
gen_siglists
sign_efi_vars
