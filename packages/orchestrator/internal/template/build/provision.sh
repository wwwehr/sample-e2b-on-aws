#!/bin/bash
# Minimal provision script - unconditionally succeed
echo -n "0" > "{{ .ResultPath }}"
