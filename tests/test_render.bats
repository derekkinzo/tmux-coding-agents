#!/usr/bin/env bats
# tests/test_render.bats — visual rendering helpers.

load test_helper

setup() {
  source "$LIB/render.sh"
}

@test "render::status with all 0 → empty" {
  run render::status 0 0 0
  assert_output ""
}

@test "render::status with idle only shows IDLE segment" {
  run render::status 0 0 4
  assert_output --partial "NEED 0"
  assert_output --partial "WORK 0"
  assert_output --partial "IDLE 4"
}

@test "render::status with all three counts shows all three segments" {
  run render::status 1 2 5
  assert_output --partial "NEED 1"
  assert_output --partial "WORK 2"
  assert_output --partial "IDLE 5"
}

@test "render::status sanitizes non-numeric counts to 0" {
  run render::status "garbage" "abc" "junk"
  assert_output ""
}

@test "render::ago seconds" {
  run render::ago 5
  assert_output " 5s"
}

@test "render::ago minutes" {
  run render::ago 120
  assert_output " 2m"
}

@test "render::ago hours" {
  run render::ago 7200
  assert_output " 2h"
}

@test "render::ago days" {
  run render::ago 172800
  assert_output " 2d"
}

@test "render::ago saturates at 99d" {
  run render::ago 999999999
  assert_output "99d"
}

@test "render::ago handles non-numeric input" {
  run render::ago "abc"
  assert_output " 0s"
}

@test "render::scrub_ansi strips NUL/ESC/DEL" {
  result=$(printf 'a\x1b[31mb\x00c\x07d\x7fe' | render::scrub_ansi)
  assert_equal "$result" "a[31mbcde"
}

@test "render::scrub_ansi preserves TAB and LF" {
  result=$(printf 'a\tb\nc' | render::scrub_ansi)
  expected=$(printf 'a\tb\nc')
  assert_equal "$result" "$expected"
}

@test "render::tmux_escape doubles all #" {
  run bash -c 'source "$LIB/render.sh"; printf "%s" "##{a}#test#" | render::tmux_escape'
  assert_output "####{a}##test##"
}

@test "render::utf8_truncate_bytes does not split codepoint" {
  # 'abc日本語def' — abc=3 bytes, 日=3 bytes, 本=3 bytes, 語=3 bytes, def=3 bytes (15 total)
  # truncating to 5 bytes should yield "abc" (3 bytes), since adding 日 would put us at 6.
  run render::utf8_truncate_bytes "abc日本語def" 5
  assert_output "abc"
}

@test "render::utf8_truncate_bytes returns input when under limit" {
  run render::utf8_truncate_bytes "abc" 100
  assert_output "abc"
}

@test "render::row produces 3-column output" {
  run render::row waiting myproj 30
  # Expect to find icon, project, age in output
  assert_output --partial "!"
  assert_output --partial "myproj"
  assert_output --partial "30s"
}

@test "render::row truncates long project names" {
  long="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # 32 chars
  run render::row idle "$long" 5
  # Should contain ellipsis when truncated
  assert_output --partial "…"
}

@test "render::utf8_truncate_bytes max=0 returns empty (no cut error)" {
  run render::utf8_truncate_bytes "abc" 0
  assert_success
  assert_output ""
}

@test "render::status template substitutes {NEED}/{WORK}/{IDLE}/{TOTAL}" {
  run render::status 3 5 2 'INBOX:{NEED}/{WORK}/{IDLE}={TOTAL}'
  assert_output "INBOX:3/5/2=10"
}

@test "render::status template emits even when all counts are 0" {
  run render::status 0 0 0 'idle:{TOTAL}'
  # Built-in path is empty when all 0; template path overrides.
  assert_output "idle:0"
}
