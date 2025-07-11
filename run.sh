#!/bin/sh
sudo chown -R "$USER:$USER" . && cabal build && sudo cabal run phing -- "$1"
