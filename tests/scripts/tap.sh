#!/bin/sh

# SPDX-License-Identifier: MIT
# 
# Copyright (c) 2021 David Farrell
# Copyright (c) 2025 Collabora Ltd
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

TAP_TOTAL_TEST_COUNT=
TAP_TEST_COUNT=0
TAP_FAIL_COUNT=0
TAP_FAIL_FATAL=
TAP_PLAN_PRINTED=
TAP_LOG=$PWD/$(basename $0)-tap.log

: > "$TAP_LOG"

tap_pass() {
	TAP_TEST_COUNT=$((TAP_TEST_COUNT + 1))
	echo "ok $TAP_TEST_COUNT $1" | tee -a "$TAP_LOG"
}

tap_fail() {
	TAP_TEST_COUNT=$((TAP_TEST_COUNT + 1))
	TAP_FAIL_COUNT=$((TAP_FAIL_COUNT + 1))
	echo "not ok $TAP_TEST_COUNT $1" | tee -a "$TAP_LOG"
}

tap_end() {
	num_tests="${1:-$TAP_TOTAL_TEST_COUNT}"
	[ -z "$num_tests" ] && num_tests="$TAP_TEST_COUNT"
	if [ -z "$TAP_PLAN_PRINTED" ]
	then
		echo "1..$num_tests" | tee -a "$TAP_LOG"
		TAP_PLAN_PRINTED=1
	fi
	[ "$num_tests" = "$TAP_TEST_COUNT" ] || exit 1
	exit $((TAP_FAIL_COUNT > 0)) # C semantics
}

tap_ok() {
	if [ "$1" -eq 0 ]; then
		tap_pass "$2"
	else
		tap_fail "$2"
		if [ "$TAP_FAIL_FATAL" = 1 ]
		then
			tap_fatal
		fi
	fi
}

tap_cmp() {
	if [ "$1" = "$2" ]; then
		tap_pass "$3"
	else
		tap_fail "$3 - expected '$2' but got '$1'"
	fi
}

tap_fatal() {
	echo "Bail out!${1:+ $1}" | tee -a "$TAP_LOG"
	tap_end
}

tap_skip() {
	tap_pass "# SKIP $1"
}

tap_todo() {
	tap_pass "# TODO $1"
}
