#!/bin/bash

# entrypoint.sh
# Bash script to do a test-compile of one or more Arduino programs in a repository each with different compile parameters.
#
# Copyright (C) 2020  Armin Joachimsmeyer
# https://github.com/ArminJo/Github-Actions
# License: MIT
#

# Input parameter
readonly CLI_VERSION="$1"
readonly SKETCH_NAME="$2"
readonly ARDUINO_BOARD_FQBN="$3"
readonly PLATFORM_URL="$4"
readonly LIBRARIES="$5"
readonly EXAMPLES_EXCLUDE="$6"
EXAMPLES_BUILD_PROPERTIES="$7"
readonly DEBUG="$8"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'

#
# Echo input parameter
#
echo -e "\n\n"$YELLOW"Echo input parameter"
echo CLI_VERSION=$CLI_VERSION
echo SKETCH_NAME=$SKETCH_NAME
echo ARDUINO_BOARD_FQBN=$ARDUINO_BOARD_FQBN
echo PLATFORM_URL=$PLATFORM_URL
echo LIBRARIES=$LIBRARIES
echo EXAMPLES_EXCLUDE=$EXAMPLES_EXCLUDE
echo EXAMPLES_BUILD_PROPERTIES=$EXAMPLES_BUILD_PROPERTIES
echo DEBUG=$DEBUG

#echo HOME=$HOME # /github/home
#echo PWD=$PWD # /github/workspace
declare -p BASH_ARGV
#set
#ls -lR $PWD

#
# Download and install arduino IDE, if not already cached
#
echo -n -e "\n\n"$YELLOW"arduino-cli "
if [ -f $HOME/arduino_ide/arduino-cli ]; then
  echo -e "cached: ""$GREEN""\xe2\x9c\x93"
else
  echo -n "downloading: "
  wget --quiet https://downloads.arduino.cc/arduino-cli/arduino-cli_${CLI_VERSION}_Linux_64bit.tar.gz
  if [ $? -ne 0 ]; then echo -e """$RED""\xe2\x9c\x96"; else echo -e """$GREEN""\xe2\x9c\x93"; fi
  echo -n "Upacking arduino-cli to ${HOME}/arduino_ide:  "
  if [ ! -d $HOME/arduino_ide/ ]; then
    mkdir $HOME/arduino_ide
  fi
  tar xf arduino-cli_${CLI_VERSION}_Linux_64bit.tar.gz -C $HOME/arduino_ide/
  if [ $? -ne 0 ]; then echo -e """$RED""\xe2\x9c\x96"; else echo -e """$GREEN""\xe2\x9c\x93"; fi
#  ls -l $HOME/arduino_ide/* # LICENSE.txt + arduino-cli
#  ls -l $HOME # only arduino_ide
fi

#print version
$HOME/arduino_ide/arduino-cli version

# add the arduino CLI to our PATH
export PATH="$HOME/arduino_ide:$PATH"


#
# Link this repository as Arduino library
#
if [ -f $PWD/library.properties ]; then
  echo -e "\n\n"$YELLOW"Link this repository as Arduino library"
  mkdir -p "$HOME/Arduino/libraries"
  ln -s "$PWD" "$HOME/Arduino/libraries/."
fi


#
# Update index and install the required board platform
#
echo -e "\n\n"$YELLOW"Update index and install the required board platform"
remainder=${ARDUINO_BOARD_FQBN#*:}; PLATFORM=${ARDUINO_BOARD_FQBN%%:*}:${remainder%%:*}
echo PLATFORM=${PLATFORM}
if [[ ${PLATFORM} != *"arduino"* && -z "$PLATFORM_URL" ]]; then
  echo -e "::error::Non Arduino platform $PLATFORM requested, but \"platform-url\" parameter is missing."
  exit 1
fi
if [ -z "$PLATFORM_URL" ]; then
  echo -e "arduino-cli core update-index > /dev/null"
  arduino-cli core update-index > /dev/null
  echo "arduino-cli core install $PLATFORM > /dev/null"
  arduino-cli core install $PLATFORM > /dev/null
else
  echo -e "arduino-cli core update-index --additional-urls \"$PLATFORM_URL\" > /dev/null"
  arduino-cli core update-index --additional-urls "$PLATFORM_URL" > /dev/null # must specify --additional-urls here
  echo -e "arduino-cli core install $PLATFORM --additional-urls \"$PLATFORM_URL\" > /dev/null"
  arduino-cli core install $PLATFORM --additional-urls "$PLATFORM_URL" > /dev/null
fi

if [[ "${PLATFORM}" == "esp8266:esp8266" && ! -f /usr/bin/python3 ]]; then ## double brackets required
  # /github/home/.arduino15/packages/esp8266/tools/python3/3.7.2-post1/python3 -> /usr/bin/python3
  echo "install python3 for ESP8266"
  apt-get install -qq python3 > /dev/null
fi
          
if [ "$PLATFORM" == "esp32:esp32" ]; then
  if [ ! -f /usr/bin/pip ]; then
    echo "install python and pip for ESP32"
    apt-get install -qq python-pip > /dev/null # this installs also python
  fi
  pip install pyserial
fi

echo -e "\n\n"$YELLOW"List installed boards with their FQBN"
arduino-cli board listall


#
# Install libraries if needed
#
echo -e "\n"$YELLOW"Install libraries if needed"
if [ -z "$LIBRARIES" ]; then
  echo "No additional libraries to install"
else
  echo -n "Install libraries $LIBRARIES "
  # Support library names which contain whitespace
  declare -a -r LIBRARIES_ARRAY="(${LIBRARIES})"
  arduino-cli lib install "${LIBRARIES_ARRAY[@]}"
  if [ $? -ne 0 ]; then
    echo "::error::Installation of "$LIBRARIES" failed"
    exit 1
  fi
fi

#
# Finally, we compile all examples
#
echo -e "\n"$YELLOW"Compiling sketches / examples for board $ARDUINO_BOARD_FQBN \n"

# If matrix.examples-build-properties are specified, create an associative shell array
EXAMPLES_BUILD_PROPERTIES=${EXAMPLES_BUILD_PROPERTIES#\{} # remove the "{". The "}" is required as end token
if [[ -n $EXAMPLES_BUILD_PROPERTIES && $EXAMPLES_BUILD_PROPERTIES != "null" ]]; then 
  echo EXAMPLES_BUILD_PROPERTIES=$EXAMPLES_BUILD_PROPERTIES
  declare -A PROP_MAP="( $(echo $EXAMPLES_BUILD_PROPERTIES | sed -E 's/"(\w*)": *([^,}]*)[,}]/\[\1\]=\2/g' ) )"
  declare -p PROP_MAP # print properties of PROP_MAP
else
  declare -A PROP_MAP=( [dummy]=dummy )
fi


# Search recursively for *.ino files starting at root
SKETCHES=($(find . -name "$SKETCH_NAME"))
for sketch in "${SKETCHES[@]}"; do # Loop over all sketch files
  SKETCH_PATH=$(dirname $sketch) # complete path to sketch
  SKETCH_DIR=${SKETCH_PATH##*/}  # directory of sketch, must match sketch basename
  SKETCH_FILENAME=$(basename $sketch) # complete name of sketch
  SKETCH_EXTENSION=${SKETCH_FILENAME##*.} # extension of sketch
  SKETCH_BASENAME=${SKETCH_FILENAME%%.*} # name wihout extension / basename of sketch, must match directory name
  if [[ "$EXAMPLES_EXCLUDE" == *"$SKETCH_BASENAME"* ]]; then
    echo -e "Skipping $SKETCH_BASENAME \xe2\x9e\x9e" # Right arrow
  else
    # If sketch name does not end with .ino, rename it locally
    if [ "$SKETCH_EXTENSION" != "ino" ]; then
      echo "Rename ${SKETCH_PATH}/${SKETCH_FILENAME} to ${SKETCH_PATH}/${SKETCH_BASENAME}.ino"
      mv ${SKETCH_PATH}/${SKETCH_FILENAME} ${SKETCH_PATH}/${SKETCH_BASENAME}.ino
    fi
    # If directory name does not match sketch name, create an appropriate directory, copy the files recursively and compile
    if [ "$SKETCH_DIR" != "$SKETCH_BASENAME" ]; then
      mkdir $HOME/$SKETCH_BASENAME
      echo "Creating directory $HOME/$SKETCH_BASENAME and copy ${SKETCH_PATH}/* to it"
      cp -R ${SKETCH_PATH}/* $HOME/$SKETCH_BASENAME
      SKETCH_PATH=$HOME/$SKETCH_BASENAME
    fi
    # check if there is an entry in the associative array and create compile parameter to put in compiler.cpp.extra_flags
    echo -n "Compiling $SKETCH_BASENAME "
    if [ "${PROP_MAP[$SKETCH_BASENAME]}" != "" ]; then
      echo -n "with ${PROP_MAP[$SKETCH_BASENAME]} "
    fi
    if [ "$DEBUG" == "true" ]; then
      arduino-cli compile --verbose --warnings all --fqbn ${ARDUINO_BOARD_FQBN%|*} --build-properties compiler.cpp.extra_flags="${PROP_MAP[$SKETCH_BASENAME]}" $SKETCH_PATH
    else
      build_stdout=$(arduino-cli compile --verbose --warnings all --fqbn ${ARDUINO_BOARD_FQBN%|*} --build-properties compiler.cpp.extra_flags="${PROP_MAP[$SKETCH_BASENAME]}" $SKETCH_PATH 2>&1)
    fi
    if [ $? -ne 0 ]; then
      echo -e ""$RED"\xe2\x9c\x96" # If ok output a green checkmark else a red X and the command output.
      echo "::error::Compile of  $SKETCH_BASENAME ${PROP_MAP[$SKETCH_BASENAME]} failed"
      exit_code=1
      if [ "$DEBUG" != "true" ]; then
        echo -e "$build_stdout \n"
      fi
    else
      echo -e ""$GREEN"\xe2\x9c\x93"
    fi
    echo "arduino-cli compile --verbose --warnings all --fqbn ${ARDUINO_BOARD_FQBN%|*} --build-properties compiler.cpp.extra_flags=\"${PROP_MAP[$SKETCH_BASENAME]}\" $SKETCH_PATH"
  fi
done
exit $exit_code
