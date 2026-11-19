#!/bin/bash
ll-builder build --skip-output-check --skip-strip-symbols && ll-builder export --layer -z lzma
