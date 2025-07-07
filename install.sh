#!/bin/bash

set -e

forge install
git submodule update --init
forge build