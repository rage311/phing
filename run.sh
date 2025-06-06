#!/bin/sh
sudo chown -R "$USER:$USER" . && cabal build && sudo cabal run ping-tui -- "$1"
