#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later

swtpm_dir="$(dirname "$(readlink -f "$0")")/swtpm"
[[ -d $swtpm_dir ]] || mkdir -p "$swtpm_dir"
rm -rf "${swtpm_dir:?}"/*
swtpm_setup --tpm2 --tpmstate "$swtpm_dir" --pcr-banks sha256
swtpm socket --tpmstate dir="$swtpm_dir" --ctrl type=unixio,path=swtpm/sock --tpm2 --daemon
