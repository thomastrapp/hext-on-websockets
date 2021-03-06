#!/usr/bin/env bash

[[ $# -lt 2 ]] && {
  echo "Usage: $0 <endpoint> <hext-file...>"
  echo
  cat <<HelpMessage | fold -s -w 78 | sed 's/^/  /'
$0 applies Hext snippets to HTML documents and compares the result to a third \
file that contains the expected output. For example, there is a test case \
icase-quoted-regex that consists of three files:
  icase-quoted-regex.hext
  icase-quoted-regex.html
  icase-quoted-regex.expected
To run this test case you would do the following:
  $ $0 wss://localhost:8080 case/icase-quoted-regex.hext

$0 will then look for the corresponding .html and .expected files of the same \
name in the directory of icase-quoted-regex.hext. Then it will send a request \
to <endpoint> with the given Hext snippet and HTML document and compare the \
result to icase-quoted-regex.expected.

To run all blackbox tests in succession:
  $ $0 wss://localhost:8080 case/*.hext
HelpMessage
  exit
}


C_RED=$(tput setaf 1)
C_GRN=$(tput setaf 2)
C_BLD=$(tput bold)
C_RST=$(tput sgr0)

# Use colordiff, if available
DIFF="diff"
hash colordiff >/dev/null 2>&1 && DIFF="colordiff"


# Prints error message to stdout.
perror() {
  echo -e "${C_RED}${C_BLD}Error:${C_RST}" "$@"
}


for dependency in websocat jq ; do
  hash $dependency >/dev/null 2>&1 || {
    perror "cannot execute '$dependency'" >&2
    exit 1
  }
done


# Prints a failed test case to stdout.
perror_case() {
  local case_name=${1:-"unknown"}
  echo "${C_RED}${C_BLD}✘ Test case <${case_name}>: Failure${C_RST}"
}


# Indents each line from stdin with two spaces and prints to stdout.
# The amount of spaces can be overridden by providing an argument
# greater than 0.
pindent() {
  local width=${1:-"2"}

  # hax: generate a string filled with $width amount of spaces
  local spaces=$(printf "%0.s " $(seq 1 "$width"))

  # insert spaces at the beginning of each line
  sed "s/^/${spaces}/" < /dev/stdin
}


# Run a hext test case.
# Expects a path to a file ending in hext, whose directory contains a
# file with the same name but ending in ".html", which will be passed
# to htmlext alongside the given hext file, and a file ending in
# ".expected", whose contents will be compared to the output of
# htmlext.
#
# Prints whether or not the test was successfull.
# Returns 0 on success.
#
# Example:
# $ ls case/nth-child.*
#   nth-child.expected
#   nth-child.hext
#   nth-child.html
# $ test_hext case/nth-child.hext
test_hext() {
  [[ $# -eq 4 ]] || {
    perror "invalid usage. usage: <endpoint> <input-pipe> <output-pipe> <hext-file>" >&2
    return 1
  }

  endpoint="$1"
  ws_input="$2"
  ws_output="$3"
  shift
  shift
  shift

  [[ "${1##*.}" == "hext" ]] || {
    perror_case "$1"
    perror "invalid format, expected <${1}.hext>" | pindent
    return 1
  } >&2

  local t_case="${1%.*}"
  local f_hext="$1"
  local f_html="${t_case}.html"
  local f_expe="${t_case}.expected"

  for f in "$f_hext" "$f_html" "$f_expe" ; do
    [[ -f "$f" && -r "$f" ]] || {
      perror_case "$t_case"
      perror "<$f> does not exist or is not readable" | pindent
      return 1
    } >&2
  done

  # $(<"$f_hext") would remove trailing newlines
  # see https://stackoverflow.com/a/22607352
  hext_str="$(cat $f_hext; printf a)"
  hext_str="${hext_str%a}"
  html_str="$(cat $f_html; printf a)"
  html_str="${html_str%a}"

  truncate -s0 "$ws_output"
  jq -n -c --arg hext "$hext_str" --arg html "$html_str" '[$hext,$html]' >>"$ws_input" || {
    perror_case "$t_case"
    perror "cannot send <$f_hext>" | pindent
    return 1
  } >&2

  local actual
  local response
  response=$(tail -f "$ws_output" | grep -a -m1 '$' | tr -d '\000')
  actual=$(echo "$response" | jq -c '.result | .[]') || {
    perror_case "$t_case"
    perror "$endpoint failed for <$f_hext>" | pindent
    return 1
  } >&2

  actual=$(echo "$actual" | sort)

  local expect
  expect=$(sort "$f_expe")

  [[ "$actual" == "$expect" ]] || {
    perror_case "$t_case"

    echo "$DIFF <expected> <actual>:" | pindent
    $DIFF <(echo "$expect") <(echo "$actual") | pindent 4

    echo "See <$f_hext>, <$f_html> and <$f_expe>" | pindent

    return 1
  } >&2

  echo "${C_GRN}${C_BLD}✔ <${t_case}>${C_RST}"
  return 0
}


# Run a test for each parameter
failure=0
total=0
endpoint="$1"
ws_input="$(mktemp -u)"
touch "$ws_input"
ws_output="$(mktemp -u)"
touch "$ws_output"
tail -f "$ws_input" | websocat --text "$endpoint" >"$ws_output" &
# kill background job and remove temp files on exit
trap "{ { kill %1 && wait %1 ; } 2>/dev/null ; rm -f $ws_input $ws_output ; }" EXIT
shift
while [[ $# -gt 0 ]] ; do
  test_hext "$endpoint" "$ws_input" "$ws_output" "$1" || {
    failure=$(expr $failure + 1)
    echo >&2
  }
  total=$(expr $total + 1)
  shift
done

echo
echo "$total tested, $failure failed"

exit $failure

