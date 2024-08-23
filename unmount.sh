#!/usr/bin/env bash

INPUT=""
VERBOSE=false
HASH=""
INPUT_MNT=""
MOUNT=""
SQUASH=false
SQUASH_MOUNT=""
SQUASH_MOUNT_CREATED=false
LOOP=""
GZIPPED=false

# More safety, by turning some bugs into errors.
set -o errexit -o pipefail -o noclobber -o nounset

# ignore errexit with `&& true`
getopt --test >/dev/null && true
if [[ $? -ne 4 ]]; then
  echo "I'm sorry, getopt --test failed in this environment."
  exit 1
fi

usage() {
  echo "" 1>&2
  echo "Usage: $0 [OPTIONS] IMAGE" 1>&2
  echo "" 1>&2
  echo "Mount SD Card Image" 1>&2
  echo "" 1>&2
  echo "Arguments:" 1>&2
  echo "image                Image file to mount" 1>&2
  echo "" 1>&2
  echo "Options:" 1>&2
  echo "-v|--verbose         Verbose" 1>&2
  echo "-h|--help            Show help" 1>&2
  exit 1
}

ask() {
  # https://djm.me/ask
  local prompt default reply

  if [[ "${2:-}" = "Y" ]]; then
    prompt="Y/n"
    default=Y
  elif [[ "${2:-}" = "N" ]]; then
    prompt="y/N"
    default=N
  else
    prompt="y/n"
    default=
  fi

  while true; do

    # Ask the question (not using "read -p" as it uses stderr not stdout)
    echo -n "$1 [$prompt] "

    # Read the answer (use /dev/tty in case stdin is redirected from somewhere else)
    if [[ "$3" ]]; then
      # Timeout supplied
      # shellcheck disable=SC2086
      read -t $3 -n 1 -r reply </dev/tty
    else
      read -n 1 -r reply </dev/tty
    fi

    # Default?
    if [[ -z "$reply" ]]; then
      reply=${default}
    fi

    # Check if the reply is valid
    case "$reply" in
    Y* | y*) return 0 ;;
    N* | n*) return 1 ;;
    esac

  done
}

checkRoot() {
  if [ $(id -u) -ne 0 ]; then
    echo Please run this script as root or using sudo!
    exit
  fi
}

checkArguments() {
  if [ ! -f "$INPUT" ]; then
    printf "\nSD Card image not found\n"
    exit 3
  fi
}

readMountFile() {
  local csv_input csv_mount csv_squash csv_squash_mount csv_squash_mount_created csv_loop csv_gzipped
  if [[ ! -f /tmp/"$HASH".mount ]]; then
    echo -e "\nNo mount file found for this image\nYou will need to manually unmount /dev/loopX and the folder(s)"
    exit 3
  fi

  while IFS="," read -r csv_input csv_mount csv_squash csv_squash_mount csv_squash_mount_created csv_loop csv_gzipped; do
#    if [[ "$VERBOSE" = true ]]; then
#      echo "INPUT = $csv_input"
#      echo "MOUNT = $csv_mount"
#      echo "SQUASH = $csv_squash"
#      echo "SQUASH_MOUNT = $csv_squash_mount"
#      echo "SQUASH_MOUNT_CREATED = $csv_squash_mount_created"
#      echo "LOOP = $csv_loop"
#      echo "GZIPPED = $csv_gzipped"
#    fi
    INPUT_MNT=$csv_input
    MOUNT=$csv_mount
    SQUASH=$csv_squash
    SQUASH_MOUNT=$csv_squash_mount
    SQUASH_MOUNT_CREATED=$csv_squash_mount_created
    LOOP=$csv_loop
    GZIPPED=$csv_gzipped
  done < <(tail -n +2 /tmp/"$HASH".mount)
}

unmountSquash() {
  umount -vd "$MOUNT"
  losetup -vd "$LOOP"
  umount "$SQUASH_MOUNT"
}

unmountImg() {
  umount -vd "$MOUNT"
  losetup -vd "$LOOP"
}

rmGzipped() {
  if [[ "$GZIPPED" = true ]]; then
    if ! ask "Remove uncompressed image $INPUT?" N 10; then
      return 1
    fi

    rm $INPUT

    return 0
  fi

  return 0
}

cleanUp() {
  if [[ "$VERBOSE" = true ]]; then
    echo -e "\nCleaning up"
  fi
  if [[ "$SQUASH_MOUNT_CREATED" = true ]]; then
    rm -rf "$SQUASH_MOUNT"
  fi

  rm -rf "$MOUNT"

  rmGzipped

  rm -f /tmp/"$HASH".mount
}

# Check if no arguments or options
[ $# -eq 0 ] && usage

# option --output/-o requires 1 argument
LONG_OPTS=verbose,help
OPTIONS=vh

# -temporarily store output to be able to check for errors
# -activate quoting/enhanced mode (e.g. by writing out “--options”)
# -pass arguments only via   -- "$@"   to separate them correctly
# -if getopt fails, it complains itself to stdout
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONG_OPTS --name "$0" -- "$@") || exit 2
# read getopt’s output this way to handle the quoting right:
eval set -- "$PARSED"

while [[ $# -gt 0 ]]; do
  case "$1" in
  -v | --verbose)
    VERBOSE=true
    shift
    ;;
  -h | --help)
    usage
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "Error"
    exit 3
    ;;
  esac
done

# Check arguments
if [[ $# -ne 1 ]]; then
  if [ "$INPUT" = "" ]; then
    printf "Argument image is required.\nExecute '%s -h' for help\n" "$0"
    exit 4
  fi
fi

INPUT="$1"

checkRoot
checkArguments

if ! ask "Proceed with unmount?" N 10; then
  exit 1
fi
echo ""

HASH=$(echo -n "$INPUT" | shasum | cut -d ' ' -f 1)

readMountFile

if [[ "$VERBOSE" = true ]]; then
  echo "INPUT = $INPUT_MNT"
  echo "MOUNT = $MOUNT"
  echo "SQUASH = $SQUASH"
  if [[ "$SQUASH" = true ]]; then
    echo "SQUASH MOUNT = $SQUASH_MOUNT"
    echo "SQUASH MOUNT CREATED= $SQUASH_MOUNT_CREATED"
  fi
  echo "LOOP = $LOOP"
  echo "GZIPPED = $GZIPPED"
  echo ""
fi

if [[ "$SQUASH" = true ]]; then
  unmountSquash
else
  unmountImg
fi

cleanUp

echo -e "\nUnmount $INPUT completed"