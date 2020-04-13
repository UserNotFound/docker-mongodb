#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/test_helpers.sh"

@test "It should install mongod 4.0.14" {
  run mongod --version
  [[ "$output" =~ "db version v4.0.14"  ]]
}
