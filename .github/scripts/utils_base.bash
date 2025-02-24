#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

################################################################################
# Platform Specific Variables
################################################################################

# shellcheck disable=SC2155
export KERN_NAME="$(uname -s)"
# shellcheck disable=SC2155
export MACHINE_NAME="$(uname -m)"
# shellcheck disable=SC2155
export PLATFORM_NAME="$KERN_NAME-$MACHINE_NAME"
# shellcheck disable=SC2155
export KERN_NAME_LC="$(echo "$KERN_NAME" | awk '{print tolower($0)}')"
# shellcheck disable=SC2155
export MACHINE_NAME_LC="$(echo "$MACHINE_NAME" | awk '{print tolower($0)}')"
# shellcheck disable=SC2155
export PLATFORM_NAME_LC="$KERN_NAME_LC-$MACHINE_NAME_LC"


################################################################################
# Command Execution Functions
################################################################################

print_exec () {
  echo "+ $*"
  echo ""
  if eval "$*"; then
    local retcode=0
  else
    local retcode=$?
  fi
  echo ""
  return $retcode
}

exec_with_retries () {
  local max_retries="$1"
  local delay_secs=2
  local retcode=0

  # shellcheck disable=SC2086
  for i in $(seq 0 ${max_retries}); do
    # shellcheck disable=SC2145
    echo "[EXEC] [ATTEMPT ${i}/${max_retries}]    + ${@:2}"

    if "${@:2}"; then
      local retcode=0
      break
    else
      local retcode=$?
      echo "[EXEC] [ATTEMPT ${i}/${max_retries}] Command attempt failed."
      echo ""

      if [ "$i" -ne "$max_retries" ]; then
        sleep $delay_secs
      fi
    fi
  done

  if [ $retcode -ne 0 ]; then
    echo "[EXEC] The command has failed after ${max_retries} + 1 attempts; aborting."
  fi

  return $retcode
}


display_time() {
  local seconds="$1"
  ((h=seconds/3600))
  ((m=(seconds%3600)/60))
  ((s=seconds%60))
  printf "%02d:%02d:%02d\n" $h $m $s
}


################################################################################
# Assert Functions
################################################################################

env_name_or_prefix () {
  local env=$1
  if [[ ${env} == /* ]]; then
    # If the input string is a PATH (i.e. starts with '/'), then determine the
    # Conda environment by directory prefix
    echo "-p ${env}";
  else
    # Else, determine the Conda environment by name
    echo "-n ${env}";
  fi
}

append_to_envvar () {
  local env_name="$1"
  local key="$2"
  local value="$3"

  local env_prefix=$(env_name_or_prefix "${env_name}")

  echo "[ENV] Appending to ${key}: ${value} ..."
  # shellcheck disable=SC2155,SC2086
  local current_value=$(conda run ${env_prefix} printenv ${key})
  # shellcheck disable=SC2086
  (print_exec conda env config vars set ${env_prefix} "${key}"="${current_value:+${current_value}:}${value}") || return 1
}

append_to_library_path () {
  local env_name="$1"
  local value="$2"

  (append_to_envvar "${env_name}" LD_LIBRARY_PATH "${value}") || return 1
}

test_network_connection () {
  exec_with_retries 3 wget -q --timeout 1 pypi.org -O /dev/null
  local exit_status=$?

  # https://man7.org/linux/man-pages/man1/wget.1.html
  if [ $exit_status == 0 ]; then
    echo "[CHECK] Network does not appear to be blocked."
  else
    echo "[CHECK] Network check exit status: ${exit_status}"
    echo "[CHECK] Network appears to be blocked or suffering from poor connection."
    echo "[CHECK] Please remember to proxy the network connections if needed, i.e. re-run the command prefixed with 'with-proxy'."
    return 1
  fi
}

test_python_import_symbol () {
  local env_name="$1"
  local package_name="$2"
  local target_symbol="$3"
  if [ "$target_symbol" == "" ]; then
    echo "Usage: ${FUNCNAME[0]} ENV_NAME PACKAGE_NAME SYMBOL"
    echo "Example(s):"
    echo "    ${FUNCNAME[0]} build_env numpy __version__"
    return 1
  fi

  local env_prefix=$(env_name_or_prefix "${env_name}")

  # shellcheck disable=SC2086
  if conda run ${env_prefix} python -c "from ${package_name} import ${target_symbol}"; then
    echo "[CHECK] Found symbol '${target_symbol}' in Python package '${package_name}'."
  else
    echo "[CHECK] Could not find symbol '${target_symbol}' in Python package '${package_name}'; the package might be missing or broken."
    return 1
  fi
}

test_python_import_package () {
  local env_name="$1"
  local python_import="$2"
  if [ "$python_import" == "" ]; then
    echo "Usage: ${FUNCNAME[0]} ENV_NAME PYTHON_IMPORT"
    echo "Example(s):"
    echo "    ${FUNCNAME[0]} build_env numpy"
    return 1
  fi

  local env_prefix=$(env_name_or_prefix "${env_name}")

  # shellcheck disable=SC2086
  if conda run ${env_prefix} python -c "import ${python_import}"; then
    echo "[CHECK] Python (sub-)package '${python_import}' found ..."
  else
    echo "[CHECK] Python (sub-)package '${python_import}' was not found!  Please check if the Python sources have been packaged correctly."
    return 1
  fi
}

test_binpath () {
  local env_name="$1"
  local bin_name="$2"
  if [ "$bin_name" == "" ]; then
    echo "Usage: ${FUNCNAME[0]} ENV_NAME BIN_NAME"
    echo "Example(s):"
    echo "    ${FUNCNAME[0]} build_env nvcc"
    return 1
  fi

  local env_prefix=$(env_name_or_prefix "${env_name}")

  # shellcheck disable=SC2086
  if conda run ${env_prefix} which "${bin_name}"; then
    echo "[CHECK] Binary ${bin_name} found in PATH"
  else
    echo "[CHECK] Binary ${bin_name} not found in PATH!"
    return 1
  fi
}

test_filepath () {
  local env_name="$1"
  local file_name="$2"
  if [ "$file_name" == "" ]; then
    echo "Usage: ${FUNCNAME[0]} ENV_NAME FILE_NAME"
    echo "Example(s):"
    echo "    ${FUNCNAME[0]} build_env cuda_runtime.h"
    return 1
  fi

  local env_prefix=$(env_name_or_prefix "${env_name}")

  # shellcheck disable=SC2155,SC2086
  local conda_prefix=$(conda run ${env_prefix} printenv CONDA_PREFIX)
  # shellcheck disable=SC2155
  local file_path=$(find "${conda_prefix}" -type f -name "${file_name}")
  # shellcheck disable=SC2155
  local link_path=$(find "${conda_prefix}" -type l -name "${file_name}")

  if [ "${file_path}" != "" ]; then
    echo "[CHECK] ${file_name} found in CONDA_PREFIX PATH (file): ${file_path}"
  elif [ "${link_path}" != "" ]; then
    echo "[CHECK] ${file_name} found in CONDA_PREFIX PATH (symbolic link): ${link_path}"
  else
    echo "[CHECK] ${file_name} not found in CONDA_PREFIX PATH!"
    return 1
  fi
}

test_env_var () {
  local env_name="$1"
  local env_key="$2"
  if [ "$env_key" == "" ]; then
    echo "Usage: ${FUNCNAME[0]} ENV_NAME ENV_KEY"
    echo "Example(s):"
    echo "    ${FUNCNAME[0]} build_env CUDNN_INCLUDE_DIR"
    return 1
  fi

  local env_prefix=$(env_name_or_prefix "${env_name}")

  # shellcheck disable=SC2086
  if conda run ${env_prefix} printenv "${env_key}"; then
    echo "[CHECK] Environment variable ${env_key} is defined in the Conda environment"
  else
    echo "[CHECK] Environment variable ${env_key} is not defined in the Conda environment!"
    return 1
  fi
}

test_library_symbol () {
  local lib_path="$1"
  local lib_symbol="$2"
  if [ "$lib_symbol" == "" ]; then
    echo "Usage: ${FUNCNAME[0]} LIB_PATH FULL_NAMESPACE_PATH_LIB_SYMBOL"
    echo "Example(s):"
    echo "    ${FUNCNAME[0]} fbgemm_gpu_py.so fbgemm_gpu::merge_pooled_embeddings"
    return 1
  fi

  # Add space and '(' to the grep string to get the full method path
  symbol_entries=$(nm -gDC "${lib_path}" | grep " ${lib_symbol}(")
  if [ "${symbol_entries}" != "" ]; then
    echo "[CHECK] Found symbol in ${lib_path}: ${lib_symbol}"
  else
    echo "[CHECK] Symbol NOT found in ${lib_path}: ${lib_symbol}"
    return 1
  fi
}

set_clang_symlinks () {
  local env_name="$1"
  if [ "$env_name" == "" ]; then
    echo "Usage: ${FUNCNAME[0]} ENV_NAME"
    echo "Example(s):"
    echo "    ${FUNCNAME[0]} build_env"
    return 1
  fi

  # shellcheck disable=SC2155
  local env_prefix=$(env_name_or_prefix "${env_name}")

  # shellcheck disable=SC2155,SC2086
  local cc_path=$(conda run ${env_prefix} which clang)
  # shellcheck disable=SC2155,SC2086
  local cxx_path=$(conda run ${env_prefix} which clang++)

  # Set the symlinks, override if needed
  #
  # NOTE: Setting the symlink CONDA_PREFIX/bin/c++ to point to clang++ can mess
  # up the runtime for tests, since torch dynamo makes compilation calls with
  # gcc-specific compiler flags, effectively making gcc a hard dependency:
  #
  #   clang-16: error: unknown argument: '-fno-tree-loop-vectorize'
  #
  # As such, clang is installed only during the build step, where we are
  # exercising building FBGEMM in clang.
  print_exec ln -sf "${cc_path}" "$(dirname "$cc_path")/cc"
  print_exec ln -sf "${cc_path}" "$(dirname "$cc_path")/gcc"
  print_exec ln -sf "${cxx_path}" "$(dirname "$cxx_path")/c++"
  print_exec ln -sf "${cxx_path}" "$(dirname "$cxx_path")/g++"
}
