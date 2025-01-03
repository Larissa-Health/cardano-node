#!/usr/bin/env bash

set -e

OUT=$(dirname $(realpath $0))
ROOT=$(realpath ${OUT}/../..)
nix build "${ROOT}"#hydraJobs.cardano-deployment
SRC="${ROOT}/result"

copyFile() {
  echo $1
  cp ${SRC}/$1 ${OUT}/$1
}

echo "#################"
echo "# Copying files #"
echo "#################"

copyFile "mainnet-alonzo-genesis.json"
copyFile "mainnet-byron-genesis.json"
copyFile "mainnet-conway-genesis.json"
copyFile "mainnet-config.json"
copyFile "mainnet-config-new-tracing.json"
copyFile "mainnet-shelley-genesis.json"
copyFile "mainnet-topology.json"

copyFile "shelley_qa-conway-genesis.json"
copyFile "shelley_qa-alonzo-genesis.json"
copyFile "shelley_qa-byron-genesis.json"
copyFile "shelley_qa-config.json"
copyFile "shelley_qa-shelley-genesis.json"
copyFile "shelley_qa-topology.json"
