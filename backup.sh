#!/usr/bin/env bash

DEVICE=""
OUTPUT=""
VERBOSE=false
NOCOMPRESS=false
GZIP=false
SQUASH=false
SHRINK=false
DDCMD="dd"
USE_DCFLDD=true
SQUASHFILE=""
BS="1M"
BS_COUNT="FULL"
TMPLOC=$(mktemp -d)
DRY_RUN=false
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )


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
  echo "Usage: $0 [OPTIONS] DEVICE OUTPUT" 1>&2
  echo "" 1>&2
  echo "Backup SD Card Image" 1>&2
  echo "" 1>&2
  echo "Examples:" 1>&2
  echo "$0 -f MyImage.img /dev/sdd ./MyImage.sqfs" 1>&2
  echo "$0 -s -f MyImage.img /dev/sdd ./MyImage.sqfs" 1>&2
  echo "$0 -g /dev/sdd ./MyImage.img.gz" 1>&2
  echo "$0 -n /dev/sdd ./MyImage.img" 1>&2
  echo "$0 -n -c 4000 /dev/sdd ./MyImage.img" 1>&2
  echo "" 1>&2
  echo "Arguments:" 1>&2
  echo "device               SD Card Device (/dev/sdX)" 1>&2
  echo "output               Output file for image" 1>&2
  echo "" 1>&2
  echo "Options:" 1>&2
  echo "-f|--squashfile      Name of image file inside squashfs file. Defaults to [output].img" 1>&2
  echo "-b|--bs              Set dd/dcfldd bs argument. Defaults to $BS" 1>&2
  echo "-c|--count           Set dd/dcfldd count argument. Defaults to full disk" 1>&2
  echo "-t|--temploc         Set the temp folder location when squashing. Defaults to $TMPLOC" 1>&2
  echo "-n|--nocompress      Do not compress the image" 1>&2
  echo "-g|--gz              (default) Compress image with gzip" 1>&2
  echo "-s|--squash          Compress image with squashfs" 1>&2
  echo "-p|--shrink          Shrink image with PiShrink" 1>&2
  echo "-d|--nodcfldd        Do not use dcfldd if installed" 1>&2
  echo "-v|--verbose         Verbose" 1>&2
  echo "--dryrun             Do not actually backup the SD Card" 1>&2
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
  if [ ! -e "$DEVICE" ]; then
    printf "\nSD Card device not found\nCheck that the device is plugged in\n"
    exit 3
  fi

  if [[ "$SQUASH" = true ]]; then
    if [[ "$SQUASHFILE" = "" ]]; then
      SQUASHFILE=${OUTPUT%.*}.img
    fi
  fi
}

checkDcflddExists() {
  if [[ "$USE_DCFLDD" = false ]]; then
    return 2
  fi

  if ! command -v dcfldd &>/dev/null; then
    echo "dcfldd not installed"

    if checkAptExists; then
      if ask "Install dcfldd?" N 10; then
        installDcfldd
      fi

      echo ""

      if ! command -v dcfldd &>/dev/null; then
        echo -e "\ndcfldd tools not installed"

        return 1
      fi

      return 0
    fi

    return 1
  fi

  return 0
}

checkSquashFsExists() {
  if ! command -v mksquashfs &>/dev/null; then
    echo -e "\nSquashFS tools not installed"

    if checkAptExists; then
      if ask "Install squashfs-tools?" N 10; then
        installSquashFs
      fi

      echo ""

      if ! command -v mksquashfs &>/dev/null; then
        echo -e "\nSquashFS tools not installed"

        return 1
      fi

      return 0
    fi

    return 1
  fi

  return 0
}

checkAptExists() {
  if ! command -v apt &>/dev/null; then
    if [[ "$VERBOSE" = true ]]; then
      echo "apt not found"
    fi
    return 1
  fi

  return 0
}

checkWgetExists() {
  if ! command -v wget &>/dev/null; then
      if [[ "$VERBOSE" = true ]]; then
        echo "wget not found"
      fi
      return 1
  fi

  return 0
}

checkPiShrinkExists() {
  if [ ! -f "$SCRIPT_DIR/pishrink.sh" ]; then
      echo -e "\nPiShrink not installed"

      if checkWgetExists; then
        if ask "Install PiShrink" N 10; then
          installPiShrink
        fi

        echo ""

        if [ ! -f pishrink.sh ]; then
          echo -e "\nPiShrink not installed"

          return 1
        fi

        return 0
      fi

      return 1
  fi

  return 0
}

installSquashFs() {
  apt update
  apt install -y squashfs-tools
}

installDcfldd() {
  apt update
  apt install -y dcfldd
}

installPiShrink() {
  wget -O $SCRIPT_DIR/pishrink.sh https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
  chmod +x $SCRIPT_DIR/pishrink.sh
}

doBackup() {
  local CMD_DD_TEMP=" "
  local CMD=" "
  local CMD_SHRINK=" "

  if [[ "$DDCMD" = "dcfldd" ]]; then
    CMD_DD_TEMP="$DDCMD bs=$BS status=on"
  else
    CMD_DD_TEMP="$DDCMD bs=$BS status=progress"
  fi

  if [[ "$BS_COUNT" != "FULL" ]]; then
    CMD_DD_TEMP="$CMD_DD_TEMP count=$BS_COUNT"
  fi

  CMD_DD_TEMP="$CMD_DD_TEMP if=$DEVICE"

  if [[ "$SHRINK" = true ]]; then
    CMD_SHRINK="$SCRIPT_DIR/pishrink.sh "

    if [[ "$VERBOSE" = true ]]; then
      CMD_SHRINK="${CMD_SHRINK}-v "
    fi

    if [[ "$GZIP" = true ]]; then
      CMD_SHRINK="${CMD_SHRINK}-z -a "
    fi
  fi

  if [[ "$SQUASH" = true ]]; then
    echo -e "\nBacking up SD Card to $OUTPUT and squashing it"
    mkdir "$TEMPLOC"
    CMD="mksquashfs $TMPLOC $OUTPUT -p '$SQUASHFILE f 644 root root $CMD_DD_TEMP'"
  elif [[ "$SHRINK" = true ]]; then
    echo -e "\nBacking up SD Card to $OUTPUT and shrinking it"
    CMD="$CMD_DD_TEMP of=$OUTPUT && $CMD_SHRINK$OUTPUT"
  elif [[ "$GZIP" = true ]]; then
    echo -e "\nBacking up SD Card to $OUTPUT and gzipping it"
    CMD="$CMD_DD_TEMP | gzip > $OUTPUT"
  else
    echo -e "\nBacking up SD Card to $OUTPUT as uncompressed"
    CMD="$CMD_DD_TEMP of=$OUTPUT"
  fi

  if [[ "$VERBOSE" = true ]]; then
    echo "$CMD"
  fi

  if [[ "$DRY_RUN" = false ]]; then
    eval "$CMD"
  fi

  if [[ "$SQUASH" = true ]]; then
    echo -e "\nCleaning up"
    rm -rf "$TEMPLOC"
  fi

  if [[ "$DRY_RUN" = false ]]; then
    echo -e "\nBacking up SD Card to $OUTPUT completed"
  else
    echo -e "\nDry run backing up SD Card to $OUTPUT completed"
  fi
}

# Check if no arguments or options
[ $# -eq 0 ] && usage

# option --output/-o requires 1 argument
LONG_OPTS=squashfile:bs:count:temploc:nocompress,gzip,squash,shrink,nodcfldd,dryrun,verbose,help
OPTIONS=f:b:c:t:ngspdvh

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
    SQUASHFILE="$2"
    shift 2
    ;;
  -b | --bs)
    BS="$2"
    shift 2
    ;;
  -c | --count)
    BS_COUNT="$2"
    shift 2
    ;;
  -t | --temploc)
    TEMPLOC="$2"
    shift 2
    ;;
  -n | --nocompress)
    NOCOMPRESS=true
    SQUASH=false
    GZIP=false
    SHRINK=false
    shift
    ;;
  -g | --gz)
    if [ "$NOCOMPRESS" = false ]; then
      SQUASH=false
      GZIP=true
    fi
    shift
    ;;
  -s | --squash)
    if [ "$NOCOMPRESS" = false ]; then
      SQUASH=true
      GZIP=false
    fi
    shift
    ;;
  -p | --shrink)
    SHRINK=true
    SQUASH=false
    shift
    ;;
  -d | --nodcfldd)
    USE_DCFLDD=false
    shift
    ;;
  -v | --verbose)
    VERBOSE=true
    shift
    ;;
  --dryrun)
    DRY_RUN=true
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
if [[ $# -ne 2 ]]; then
  if [ "$DEVICE" = "" ] && [ "$OUTPUT" = "" ]; then
    printf "Arguments device and output are required.\nExecute '%s -h' for help\n" "$0"
    exit 4
  fi
fi

DEVICE="$1"
OUTPUT="$2"

checkRoot
checkArguments

if [[ "$VERBOSE" = true ]]; then
  echo "Arguments and options:"
  echo "DEVICE = $DEVICE"
  echo "OUTPUT = $OUTPUT"
  echo "NOCOMPRESS = $NOCOMPRESS"
  echo "GZIP = $GZIP"
  echo "SQUASH = $SQUASH"
  echo "SHRINK = $SHRINK"
  echo "USE DCFLDD = $USE_DCFLDD"
  echo "BS = $BS"
  echo "COUNT = $BS_COUNT"
  if [[ "$SQUASH" = true ]]; then
    echo "SQUASH FILE = $SQUASHFILE"
  fi
  echo ""
fi

if checkDcflddExists; then
  DDCMD="dcfldd"
fi

if [[ "$SQUASH" = true ]]; then
  if ! checkSquashFsExists; then
    echo -e "\nMust install squashfs tools\napt install squashfs-tools"
    exit 5
  fi
fi

if [[ "$SHRINK" = true ]]; then
  if ! checkPiShrinkExists; then
    echo -e "\nMust download PiShrink to this scripts directory"
    exit 5
  fi
fi

if [[ "$VERBOSE" = true ]]; then
  echo "Using $DDCMD for backing up card"
  echo ""
fi

if ask "Proceed with backup?" N 10; then
  doBackup
fi
echo ""
