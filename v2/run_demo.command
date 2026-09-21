#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
MATLAB_BIN=""

if command -v matlab >/dev/null 2>&1; then
  MATLAB_BIN="$(command -v matlab)"
else
  for candidate in /Applications/MATLAB_R*.app/bin/matlab(N); do
    MATLAB_BIN="$candidate"
  done
fi

if [[ -z "$MATLAB_BIN" || ! -x "$MATLAB_BIN" ]]; then
  echo "MATLAB was not found. Install MATLAB and Psychtoolbox, then try again."
  read -r "?Press Return to close."
  exit 1
fi

if ! "$MATLAB_BIN" -sd "$SCRIPT_DIR" -batch "two_group_motion_demo"; then
  echo
  echo "The MATLAB/Psychtoolbox demo did not start successfully."
  echo "See README.md for setup and licence checks."
  read -r "?Press Return to close."
  exit 1
fi
