#!/usr/bin/env bash

INPUT=""
LOCATION=""
MOUNT=""
PARTITION=""
VERBOSE=false
SQUASH=false
SQUASH_FILE=""
SQUASH_MOUNT=""
SQUASH_MOUNT_CREATED=false
LOOP=""

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
  echo "Usage: $0 [OPTIONS] IMAGE LOCATION PARTITION" 1>&2
  echo "" 1>&2
  echo "Mount SD Card Image" 1>&2
  echo "" 1>&2
  echo "Arguments:" 1>&2
  echo "image                Image file to mount" 1>&2
  echo "location             Where to mount the image" 1>&2
  echo "partition            Partition number to mount" 1>&2
  echo "" 1>&2
  echo "Options:" 1>&2
  echo "-f|--squashfile      Name of image file inside squashfs file. Defaults to [output].img" 1>&2
  echo "-m|--squashmount     Where to mount the squash image" 1>&2
  echo "-s|--squash          Image is squashfs" 1>&2
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

  if [ ! -d "$LOCATION" ]; then
    printf "\nBase mount location is not a directory\n"
    exit 3
  fi

  MOUNT="$LOCATION/image"
  mkdir -p "$MOUNT"

  if [[ "$VERBOSE" = true ]]; then
    echo "Created directory $MOUNT"
  fi

  if [ ! -d "$MOUNT" ]; then
    printf "\nMount location is not a directory\n"
    exit 3
  fi

  # shellcheck disable=SC2162
    if find "$MOUNT" -mindepth 1 -maxdepth 1 | read; then
      echo -e "\nMount location is not empty"
      exit 5
    fi

  if [[ "$SQUASH" = true ]]; then
    if [[ "$SQUASH_FILE" = "" ]]; then
      SQUASH_FILE=${INPUT%.*}.img
    fi

    if [[ "$SQUASH_MOUNT" = "" ]]; then
      SQUASH_MOUNT="$LOCATION/squashfs"
      mkdir -p "$SQUASH_MOUNT"
      SQUASH_MOUNT_CREATED=true

      if [[ "$VERBOSE" = true ]]; then
        echo "Created directory $SQUASH_MOUNT"
      fi
    fi

    if [ ! -d "$SQUASH_MOUNT" ]; then
      printf "\nSquash mount location is not a directory\n"
      exit 3
    fi

    # shellcheck disable=SC2162
    if find "$SQUASH_MOUNT" -mindepth 1 -maxdepth 1 | read; then
      echo -e "\nSquash mount location is not empty"
      exit 5
    fi

  fi
}

doMountSquash() {
  local loop
  echo -e "\nMounting squashed image"
  mount "$INPUT" "$SQUASH_MOUNT"
  loop=$(losetup -vfP --show "$SQUASH_MOUNT/$SQUASH_FILE")
  echo -e "\nMake note of this loop device path for use when unmounting this image.\n$loop"
  mount "$loop""p""$PARTITION" "$MOUNT"
  LOOP=$loop
}

doMountImg() {
  local loop
  echo -e "\nMounting raw image"
  loop=$(losetup -vfP --show "$INPUT")
  echo -e "\nMake note of this loop device path for use when unmounting this image.\n$loop"
  mount "$loop""p""$PARTITION" "$MOUNT"
  LOOP=$loop
}

# Check if no arguments or options
[ $# -eq 0 ] && usage

# option --output/-o requires 1 argument
LONG_OPTS=squashfile:squashmount:squash,verbose,help
OPTIONS=f:m:svh

# -temporarily store output to be able to check for errors
# -activate quoting/enhanced mode (e.g. by writing out “--options”)
# -pass arguments only via   -- "$@"   to separate them correctly
# -if getopt fails, it complains itself to stdout
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONG_OPTS --name "$0" -- "$@") || exit 2
# read getopt’s output this way to handle the quoting right:
eval set -- "$PARSED"

while [[ $# -gt 0 ]]; do
  case "$1" in
  -f | --squashfile)
    SQUASH_FILE="$2"
    shift 2
    ;;
  -m | --squashmount)
    SQUASH_MOUNT="$2"
    shift 2
    ;;
  -s | --squash)
    SQUASH=true
    shift
    ;;
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
if [[ $# -ne 3 ]]; then
  if [ "$INPUT" = "" ] && [ "$LOCATION" = "" ]; then
    printf "Arguments image and location are required.\nExecute '%s -h' for help\n" "$0"
    exit 4
  fi
fi

INPUT="$1"
LOCATION="$2"
PARTITION="$3"

checkRoot
checkArguments

if [[ "$VERBOSE" = true ]]; then
  echo "Arguments and options:"
  echo "INPUT = $INPUT"
  echo "LOCATION = $LOCATION"
  echo "SQUASH = $SQUASH"
  if [[ "$SQUASH" = true ]]; then
    echo "SQUASH FILE = $SQUASH_FILE"
  fi
  echo ""
fi

if ! ask "Proceed with mount?" N 10; then
  exit 1
fi
echo ""

if [[ "$SQUASH" = true ]]; then
  doMountSquash
else
  doMountImg
fi

echo -e "\nSD Card image mounted to $MOUNT"

# Write out mount file
HASH=$(echo -n "$INPUT" | shasum | cut -d ' ' -f 1)
rm -f /tmp/"$HASH".mount 2> /dev/null
echo "input,mount,squash,squash_mount,squash_mount_created,loop" > /tmp/"$HASH".mount
echo "$INPUT,$MOUNT,$SQUASH,$SQUASH_MOUNT,$SQUASH_MOUNT_CREATED,$LOOP" >> /tmp/"$HASH".mount

if [[ "$VERBOSE" = true ]]; then
  echo -e "\nCreated mount file /tmp/$HASH.mount"
fi