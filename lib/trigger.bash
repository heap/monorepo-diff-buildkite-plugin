#!/bin/bash
set -ueo pipefail

function generate_pipeline_yml() {
  for pipeline in "${pipelines_to_trigger[@]}";
    do
      set -- $pipeline
      # Word split on purpose using spaces

      local pipeline_index=$1
      local pipeline_path=$2
      add_action "$pipeline_index" "$pipeline_path"
    done
  add_wait
  add_hooks
}

function add_action() {
  local pipeline_index=$1
  local pipeline_path=$2

  local action_trigger
  local action_command

  action_trigger=$(read_pipeline_config "$pipeline_index" "TRIGGER")
  action_command=$(read_pipeline_config "$pipeline_index" "COMMAND")

  if [[ -n $action_trigger ]]
  then
    add_action_trigger "$pipeline_index" "$pipeline_path"
  elif [[ -n $action_command ]]
  then
    add_action_command "$pipeline_index" "$pipeline_path"
  else
    echo "Invalid config. Pipeline trigger or command is required"
  fi
}

#
# HELPERS SHARED BETWEEN COMMIT AND TRIGGER
#

function add_label() {
  local label=$1

  if [[ -n $label ]]; then
    pipeline_yml+=("    label: \"${label}\"")
  fi
}

function add_branches() {
  local branches=$1

  if [[ -n $branches ]]; then
    pipeline_yml+=("    branches: ${branches}")
  fi
}

function add_if() {
  local iff=$1

  if [[ -n $iff ]]; then
    pipeline_yml+=("    if: ${iff}")
  fi
}

function add_key() {
  local key=$1

  if [[ -n $key ]]; then
    pipeline_yml+=("    key: ${key}")
  fi
}

function add_depends_on() {
  local pipeline_index=$1

  local prefix="BUILDKITE_PLUGIN_MONOREPO_DIFF_WATCH_${pipeline_index}_CONFIG_DEPENDS"
  local parameter="${prefix}_0"

  pipeline_yml+=("    depends_on:")
  if [[ -n "${!parameter:-}" ]]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [[ -n "${!parameter:-}" ]]; do
      pipeline_yml+=("      - ${!parameter}")
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  fi
}

#
# TRIGGER-SPECIFIC LOGIC
#

function add_action_trigger() {
  local pipeline_index=$1
  local pipeline_path=$2

  echo >&2 "Generating trigger for path: $pipeline_path"

  local trigger
  trigger=$(read_pipeline_config "$pipeline_index" "TRIGGER")

  pipeline_yml+=("  - trigger: ${trigger}")

  # Generic properties to output
  add_label "$(read_pipeline_config "$pipeline_index" "LABEL")"
  add_branches "$(read_pipeline_config "$pipeline_index" "BRANCHES")"
  add_if "$(read_pipeline_config "$pipeline_index" "IF")"
  add_key "$(read_pipeline_config "$pipeline_index" "KEY")"
  add_depends_on "$pipeline_index"
  # Trigger-only properties to output
  add_async "$(read_pipeline_config "$pipeline_index" "ASYNC")"
  add_build "$pipeline_index"
}

function add_async() {
  local async=$1

  if [[ -n $async ]]; then
    pipeline_yml+=("    async: ${async}")
  fi
}

function add_build() {
  local pipeline_index=$1

  pipeline_yml+=("    build:")
  add_build_message "$(read_pipeline_config "$pipeline_index" "BUILD_MESSAGE")"
  add_build_commit "$(read_pipeline_config "$pipeline_index" "BUILD_COMMIT")"
  add_build_branch "$(read_pipeline_config "$pipeline_index" "BUILD_BRANCH")"
  add_build_env "$pipeline_index"
}

function add_build_commit() {
  local build_commit=$1
  default_commit=${BUILDKITE_COMMIT:-}

  pipeline_yml+=("      commit: ${build_commit:-$default_commit}")
}

function add_build_message() {
  local build_message=$1
  default_message="${BUILDKITE_MESSAGE:-}"
  sanitized_build_message=$(sanitize_string "${build_message:-$default_message}")

  pipeline_yml+=("      message: \"$sanitized_build_message\"")
}

function add_build_branch() {
  local build_branch=$1
  default_branch=${BUILDKITE_BRANCH:-}

  pipeline_yml+=("      branch: ${build_branch:-$default_branch}")
}

function add_build_env() {
  local pipeline_index=$1
  local build_env
  build_envs=$(read_pipeline_read_env "$pipeline_index" "BUILD_ENV")

  if [[ -z "$build_envs" ]]; then
    # Default: if no 'env' is specified, pass through PR and TAG to dependent build
    build_envs=$(echo "BUILDKITE_PULL_REQUEST"; echo "BUILDKITE_TAG")
  fi

  if [[ -n "$build_envs" ]]; then
    pipeline_yml+=("      env:")
    while IFS=$'\n' read -r build_env ; do
      IFS='=' read -r key value <<< "$build_env"
      if [[ -n "$value" ]]; then
        pipeline_yml+=("        ${key}: ${value}")
      else
        pipeline_yml+=("        ${key}: ${!key:-}")
      fi
    done <<< "$build_envs"
  fi
}

#
# COMMAND-SPECIFIC LOGIC
#

function add_action_command() {
  local pipeline_index=$1
  local pipeline_path=$2

  echo >&2 "Generating command for path: $pipeline_path"

  local command
  command=$(read_pipeline_config "$pipeline_index" "COMMAND")

  pipeline_yml+=("  - command: ${command}")

  # Generic properties to output
  add_label "$(read_pipeline_config "$pipeline_index" "LABEL")"
  add_branches "$(read_pipeline_config "$pipeline_index" "BRANCHES")"
  add_if "$(read_pipeline_config "$pipeline_index" "IF")"
  add_key "$(read_pipeline_config "$pipeline_index" "KEY")"
  add_depends_on "$pipeline_index"
  # Command-only properties to output
  add_agents "$pipeline_index"
  add_artifacts "$pipeline_index"
  add_envs "$pipeline_index"
}

function add_agents() {
  local pipeline_index=$1

  pipeline_yml+=("    agents:")
  add_agents_queue "$(read_pipeline_config "$pipeline_index" "AGENTS_QUEUE")"
}

function add_agents_queue() {
  local queue=$1

  if [[ -n "$queue" ]]; then
    pipeline_yml+=("      queue: \"${queue}\"")
  fi
}

function add_artifacts() {
  local pipeline_index=$1

  local prefix="BUILDKITE_PLUGIN_MONOREPO_DIFF_WATCH_${pipeline_index}_CONFIG_ARTIFACTS"
  local parameter="${prefix}_0"

  pipeline_yml+=("    artifact_paths:")
  if [[ -n "${!parameter:-}" ]]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [[ -n "${!parameter:-}" ]]; do
      pipeline_yml+=("        - ${!parameter}")
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  fi
}

function add_envs () {
  local pipeline_index=$1
  local envs
  envs=$(read_pipeline_read_env "$pipeline_index" "ENV")

  if [[ -n "$envs" ]]; then
    pipeline_yml+=("    env:")
    while IFS=$'\n' read -r env ; do
      IFS='=' read -r key value <<< "$env"
      if [[ -n "$value" ]]; then
        pipeline_yml+=("      ${key}: ${value}")
      else
        pipeline_yml+=("      ${key}: ${!key}")
      fi
    done <<< "$envs"
  fi
}

#
# METHODS BUILDING THE FOOTER
#

function add_wait() {
  local wait
  wait=${BUILDKITE_PLUGIN_MONOREPO_DIFF_WAIT:-true}

  if [[ "$wait" = true ]] ; then
    pipeline_yml+=("  - wait")
  fi
}

function add_hooks() {
  while IFS=$'\n' read -r command ; do
    add_command "$command"
  done <<< "$(plugin_read_list HOOKS COMMAND)"
}

function add_command() {
  local command=$1

  if [[ -n $command ]];
    then
      pipeline_yml+=("  - command: ${command}")
  fi
}

function sanitize_string() {
  local string=$1
  escaped="${string//\"/\\\"}"
  escaped="${escaped//\$/\$\$}"
  echo "$escaped"
}
