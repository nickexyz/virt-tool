#!/usr/bin/env bash

# This is a bash script that interactively exports or imports VM:s from virt-manager (libvrt).
# All exports are compressed as 7zip archives and encrypted with the specified password.

# All backups will be created in the directory where the script is located.

# It uses gum (https://github.com/charmbracelet/gum) for the menu. Gum will be installed in ~/.local/bin if it is not installed already.
# An entry in ~/.bashrc to add ~/.local/bin to PATH will also be created.

# If you are using Fedora Silverblue, a Podman container will be created (Where 7zip and xmlstarlet will be installed).

# Should sudo be used? (Usually yes)
USE_SUDO="yes"

# If you are using Fedora Silverblue, specify a container that should be used for 7zip here.
# A container image with that name will be created. 7zip and xmlstarlet will be installed.
#
# If you do not want to use a container, leave this variable empty.
# In that case, you will probably need to install 7zip and xmlstarlet.
CONTAINER_NAME="vm-backup"


######################
# Script starts here #
######################

# set -o errexit   # Exit on nonzero exitstatus. Add "|| true" to commands that are allowed to fail.
set -o nounset   # Exit on unbound variable.
set -o pipefail  # Show errors within pipes.

run_command() {
  if [[ "$USE_SUDO" == "yes" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

# We use this for temporary files
random_string=$( tr -dc A-Za-z0-9 </dev/urandom | head -c 20 )

cleanup () {
  rm -rf /tmp/virt-tool-container-"$random_string"
  rm -f /tmp/virt-tool."$random_string".tmp
  rm -f /tmp/virt-tool-vms."$random_string".tmp
  rm -f /tmp/virt-tool-import-list."$random_string".tmp
  kill $KEEP_ALIVE_PID 2>/dev/null
}

finish() {
  result=$?
  cleanup
  exit ${result}
}
trap finish EXIT ERR

# Function to keep sudo session alive
keep_sudo_alive() {
  while true; do
    if [[ "$USE_SUDO" == "yes" ]]; then
      sudo -v
    fi
    sleep 120
    done
}
# Start the keep-alive function in the background
keep_sudo_alive &
KEEP_ALIVE_PID=$!

## COLORS ##
# Define foreground color codes
fg_black='\033[30m'
fg_red='\033[31m'
fg_green='\033[32m'
fg_yellow='\033[33m'
fg_blue='\033[34m'
fg_magenta='\033[35m'
fg_cyan='\033[36m'
fg_white='\033[37m'
fg_reset='\033[39m'

# Define background color codes
bg_black='\033[40m'
bg_red='\033[41m'
bg_green='\033[42m'
bg_yellow='\033[43m'
bg_blue='\033[44m'
bg_magenta='\033[45m'
bg_cyan='\033[46m'
bg_white='\033[47m'
bg_reset='\033[49m'

# Reset both foreground and background colors
colors_reset='\033[0m'

echo_success() {
  echo -e "[${fg_green}✓${fg_reset}] SUCCESS - ${1-}"
}
echo_fail() {
  echo -e "[${fg_red}✗${fg_reset}] FAIL - ${1-}"
}

## /COLORS ##

build_container() {
  if [ -n "$CONTAINER_NAME" ]; then
    # Check if the container exists
    container_exists=$(run_command podman images | grep -w "localhost/$CONTAINER_NAME")
    if [ -z "$container_exists" ]; then
      echo_gum "Container $CONTAINER_NAME does not exist. Creating..."
      echo
      mkdir -p /tmp/virt-tool-container-"$random_string"
      echo "FROM registry.fedoraproject.org/fedora-toolbox:latest" > /tmp/virt-tool-container-"$random_string"/Dockerfile
      echo "RUN sudo dnf install -y p7zip p7zip-plugins && sudo dnf install -y xmlstarlet" >> /tmp/virt-tool-container-"$random_string"/Dockerfile
      run_command podman build -t localhost/"$CONTAINER_NAME" /tmp/virt-tool-container-"$random_string"
      if [ $? -eq 0 ]; then
        echo
        echo_success "Container $CONTAINER_NAME created"
        echo
      else
        echo
        echo_fail "Container $CONTAINER_NAME build failed"
        echo
        exit 1
      fi
      rm -r /tmp/virt-tool-container-"$random_string"
      echo
    fi
  else
    echo -n
  fi
}

# Get the folder where the script is
ourpath=$(dirname "$(realpath "$0")")

install_gum() {
  gum_curl_output=$(curl -s -w "%{http_code}" -o /tmp/gum_latest.json https://api.github.com/repos/charmbracelet/gum/releases/latest)
  if [ "$gum_curl_output" -ne 200 ]; then
    echo "Failed to fetch data from GitHub API, HTTP status: $gum_curl_output"
    rm -f /tmp/gum_latest.txt
    exit 1
  fi
  gum_version=$(awk '/tag_name/{print $4;exit}' FS='[""]' /tmp/gum_latest.json)
  gum_version_without_v=$( echo $gum_version | sed 's/v//' )


  echo "=== Installing or updating gum if necessary ==="
  echo
  echo "=== Latest available release is $gum_version ==="
  echo

  gum_currver=$( cat ~/.local/share/gum.ver 2>/dev/null )
  if [ "$gum_currver" != "$gum_version" ] ; then
    if [ ! -f ~/.local/share/gum.ver ]; then
      echo
      echo "=== gum does not seem to be installed, installing ==="
      echo
    else
      echo
      echo "=== gum is out of date (Current version: $gum_currver), updating ==="
      echo
    fi
    rm -f /tmp/gum_latest.txt
    rm -f /tmp/gum_latest.json
    mkdir -p /tmp/gum
    curl -o \
      /tmp/gum.tar.gz -L \
      "https://github.com/charmbracelet/gum/releases/download/${gum_version}/gum_${gum_version_without_v}_Linux_x86_64.tar.gz"

    tar xzf /tmp/gum.tar.gz -C /tmp/gum --strip-components=1

    rm -f ~/.local/bin/gum
    mkdir -p ~/.local/bin
    cp /tmp/gum/gum ~/.local/bin/gum
    rm -r /tmp/gum
    rm -f /tmp/gum.tar.gz

    mkdir -p ~/.local/share
    echo "$gum_version" > ~/.local/share/gum.ver
    echo

  else
    echo "=== gum is already at the latest version (Current version: $gum_currver) ==="
  fi

  if ! grep -q ".local/bin" ~/.bashrc ; then
    echo "if [ -d \"\$HOME/.local/bin\" ] ; then" >> ~/.bashrc
    echo "  PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc
    echo "fi" >> ~/.bashrc
    source ~/.bashrc
  fi
}

# We run sudo here so that we probably don't destroy the look of the menu
run_command echo -n

# Check if gum is installed
if ! command -v gum &> /dev/null
then
  install_gum
fi

echo_gum() {
#  clear
  gum style \
    --foreground 212 --border-foreground 212 --border double \
    --align center --width 50 --margin "1 2" --padding "2 4" "$@"
}

locate_virt_manager=$( whereis virt-manager )
if pgrep -f "$locate_virt_manager=" > /dev/null; then
  echo "virt-manager seems to be running, please close it before running this script."
  exit 1
fi
if ps ax | grep -v grep | grep -q "/usr/bin/virt-manager" ; then
  echo "virt-manager seems to be running, please close it before running this script."
  exit 1
fi

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
current_dir=$(pwd)
if [ "$script_dir" != "$current_dir" ]; then
  echo "Please run the script in its directory: $script_dir"
  exit 1
fi

if ! command -v virsh &> /dev/null; then
  echo "virsh command could not be found. Please ensure 'virtinst' is installed."
  exit 1
fi

if [ -z "$CONTAINER_NAME" ]; then
  if ! command -v xmlstarlet &> /dev/null; then
    echo "xmlstarlet command could not be found. Please ensure it is installed."
    exit 1
  fi

  if ! command -v 7z &> /dev/null; then
    echo "7z command could not be found. Please ensure 'p7zip-full' is installed."
    exit 1
  fi
fi

echo_gum 'virt-tool.sh' 'Do you want to import or export a VM?'
selected_option=$(gum choose "Export" "Import" "Quit")


if [ "$selected_option" == "Quit" ]; then
  echo "Exiting..."
  exit 0
fi

case $selected_option in
  [Ee]* )
    echo
    echo_gum "Choose VM to export: "
    export_vm=$(run_command virsh -c qemu:///session list --all | awk 'NR>2 {print $2}' | sed '/^$/d' | gum choose)
    if [ -z "$export_vm" ]; then
      echo
      echo_fail "No VM name entered. Exiting..."
      echo
      exit 1
    fi

    if ! run_command virsh dominfo "$export_vm" &> /dev/null ; then
      echo
      echo_fail "VM '$export_vm' does not exist."
      echo
      exit 1
    fi

    echo "Enter an encryption passphrase for the 7zip file:"
    while true; do
      passphrase=$(gum input --password --placeholder "Passphrase")
      echo
      if [ -z "$passphrase" ]; then
        echo "Passphrase cannot be empty. Please try again."
      else
        break
      fi
    done
    echo "Repeat passphrase:"
    passphrase_repeat=$(gum input --password --placeholder "Passphrase")
    echo
    if [ "$passphrase" != "$passphrase_repeat" ]; then
      echo "Passphrases do not match!"
      exit 1
    fi
    echo

    mkdir "$export_vm"
    echo_gum "Exporting metadata for VM:" "$export_vm"
    echo
    run_command virsh -c qemu:///session dumpxml "$export_vm" > "$export_vm/$export_vm.xml"
    echo
    echo_success "Metadata export"
    echo

    build_container

    echo_gum "Compressing and encrypting directory:" "$export_vm/"
    echo
    pushd "$export_vm"
    if [ -n "$CONTAINER_NAME" ]; then
      echo "Running in a container..."

      run_command podman run --rm --volume "$ourpath:$ourpath":Z localhost/"$CONTAINER_NAME" sh -c "cd '$ourpath'/'$export_vm' && 7z a -p'$passphrase' -mhe=on '../$export_vm.7z' ./*"
      if [ $? -eq 0 ]; then
        popd
        echo
        echo_success "Compression and encryption"
        echo
        echo_gum "Removing the temporary directory:" "$export_vm/"
        echo
        rm -rf ./"$export_vm"
        echo_success "Cleanup"
        echo
      else
        popd
        echo
        echo_fail "Compression"
        echo
        exit 1
      fi
    else
      7z a -p"$passphrase" -mhe=on ../"$export_vm.7z" ./*
      if [ $? -eq 0 ]; then
        popd
        echo
        echo_success "Compression"
        echo
        echo_gum "Removing temporary directory:" "$export_vm/"
        echo
        rm -rf ./"$export_vm"
        echo_success "Cleanup"
        echo
      else
        popd
        echo
        echo_fail "Compression"
        echo
        exit 1
      fi
    fi

    run_command virsh domblklist $export_vm --details | awk '{print $4}' | grep -v Source | grep -v "^-" > /tmp/virt-tool."$random_string".tmp
    while IFS= read -r vmdisk; do
      # Skip empty lines
      if [ -z "$vmdisk" ]; then
        continue
      fi
      echo
      echo_gum "Generating SHA1 checksum for:" "$vmdisk"
      echo
      check_status() {
        if [ $? -eq 0 ]; then
          return 0
        else
          return 1
        fi
      }
      folder_path=$(dirname "$vmdisk")
      pushd "$folder_path"
      file_name=$(basename "$vmdisk")
      run_command sh -c "sha1sum $file_name > $file_name.sha1"
      if ! check_status; then
        echo
        echo_fail "Couldn't find or create a SHA1 file for $vmdisk"
        echo
        error_occurred=1
        break
      else
        echo
        echo_success "SHA1"
        echo
        error_occurred=0
      fi
      popd
      echo "Adding .sha1 file to 7zip file"
      if [ -n "$CONTAINER_NAME" ]; then
        echo "Running 7zip in a container..."
        run_command podman run --rm --volume "$ourpath:$ourpath":Z  --volume "$folder_path:$folder_path":Z localhost/"$CONTAINER_NAME" sh -c "cd '$ourpath' && 7z a -p'$passphrase' -mhe=on '$export_vm.7z' '$vmdisk'.sha1"
        if ! check_status; then
          error_occurred=1
          echo
          echo_fail "Could not add SHA1 file to 7zip"
          echo
          run_command rm -f "$folder_path/$file_name.sha1"
          break
        else
          echo
          echo_success "SHA1 added to 7zip file"
          run_command rm -f "$folder_path/$file_name.sha1"
          error_occurred=0
        fi
      else
        run_command 7z a -p"$passphrase" -mhe=on "$export_vm.7z" "$vmdisk.sha1"
        if ! check_status; then
          error_occurred=1
          echo
          echo_fail "Could not add SHA1 file to 7zip"
          echo
          run_command rm -f "$folder_path/$file_name.sha1"
          break
        else
          echo
          echo_success "SHA1 added to 7zip file"
          run_command rm -f "$folder_path/$file_name.sha1"
          error_occurred=0
       fi
      fi
      echo
      check_status() {
        if [ $? -eq 0 ]; then
          return 0
        else
          return 1
        fi
      }
      echo
      echo_gum "Adding VM disk to the 7zip archive:" "$vmdisk"
      echo
      if [ -n "$CONTAINER_NAME" ]; then
        echo "Running 7zip in a container. Adding .qcow2 file..."
        run_command podman run --rm --volume "$ourpath:$ourpath":Z  --volume "$folder_path:$folder_path":Z localhost/"$CONTAINER_NAME" sh -c "cd '$ourpath' && 7z a -p'$passphrase' -mhe=on '$export_vm.7z' '$vmdisk'"
        if ! check_status; then
          echo
          echo_fail "Compression failed. Please check the error messages above."
          echo
          error_occurred=1
          break
        else
          echo
          echo_success "Compression"
          echo
          error_occurred=0
        fi
      else
        run_command 7z a -p"$passphrase" -mhe=on "$export_vm.7z" "$vmdisk"
        if ! check_status; then
          echo
          echo_fail "Compression failed. Please check the error messages above."
          echo
          error_occurred=1
          break
        else
          echo
          echo_success "Compression"
          echo
          error_occurred=0
        fi
      fi
    done < /tmp/virt-tool."$random_string".tmp
    rm -f /tmp/virt-tool."$random_string".tmp
    if [ "$error_occurred" -eq 1 ] 2>/dev/null; then
      exit 1
    fi

    echo_gum "Generating SHA256 checksum for 7zip file:" "$export_vm.7z"
    echo
    sha256sum "$export_vm.7z" > "$export_vm.7z.sha256"
    echo
    echo_success "SHA256"
    echo

    # Prompt the user to verify the 7zip file
    if gum confirm "Do you want to verify the 7zip? It will take a while."; then
      echo
      echo_gum "Verifying 7zip:" "$export_vm.7z"
      echo
      echo "Enter your passphrase again to verify that we can open the 7zip file:"
      echo

      # Enter passphrase
      passphrase_verify=$(gum input --password --placeholder "Passphrase")
      echo
      check_status() {
        if [ $? -eq 0 ]; then
          echo
          echo_success "Export and compression with encryption completed successfully."
          echo
        else
          echo
          echo_fail "The passphrase didn't work!"
          exit 1
        fi
      }
      if [ -n "$CONTAINER_NAME" ]; then
        echo
        echo "Running 7zip in a container..."
        run_command podman run --rm --volume "$ourpath:$ourpath":Z localhost/"$CONTAINER_NAME" sh -c "cd '$ourpath' && 7z t -p'$passphrase_verify' '$export_vm.7z'"
        check_status
      else
        7z t -p"$passphrase_verify" "$export_vm.7z"
        check_status
      fi
    else
      echo_gum "Not verifying 7zip"
      echo
    fi
    if [ -n "$CONTAINER_NAME" ]; then
      check_status() {
        if [ $? -eq 0 ]; then
          echo_success "SELinux security context set"
        else
          echo
          echo_fail "Failed to set SELinux security context!"
          exit 1
        fi
      }
      echo_gum "Restoring SELinux security context for VM storage pool"
      echo
      run_command sh -c "chcon -u system_u -r object_r -t virt_image_t -l s0 $folder_path"
      check_status
      run_command sh -c "chcon -u system_u -r object_r -t virt_image_t -l s0 $folder_path/*"
      check_status
    fi

    ;;
  [Ii]* )
    echo
    echo "Existing VM:s"
    run_command virsh -c qemu:///session list --all
    echo
    find . -maxdepth 1 -mindepth 1 -type f -name "*.7z" | sed 's|./||;s|.*/||;s|.7z$||' | sort -u > /tmp/virt-tool-import-list."$random_string".tmp
    echo
    echo "Choose a VM to import:"
    import_vm=$(cat /tmp/virt-tool-import-list."$random_string".tmp | gum choose)
    rm -f /tmp/virt-tool-import-list."$random_string".tmp

    if [ -z "$import_vm" ]; then
      echo
      echo "No VM name entered. Exiting..."
      exit 1
    fi

    if [ -f "$import_vm.7z" ]; then
      echo
      echo "Enter the passphrase for the 7zip file."
      while true; do
        passphrase=$(gum input --password --placeholder "Passphrase")
        if [ -z "$passphrase" ]; then
          echo "Passphrase cannot be empty. Please try again."
        else
          break
        fi
      done

      build_container

      echo
      echo_gum "Verifying SHA256 checksum for the .7z file..."
      echo
      if sha256sum -c "$import_vm.7z.sha256"; then
        echo
        echo_success "Checksum verification successful."
        echo
      else
        echo_fail "Checksum verification failed. Exiting..."
        echo
        exit 1
      fi

      echo_gum "Unpacking the 7zip file..."
      echo
      if test -d "./$import_vm"; then
        echo_fail "The directory $import_vm already exists, exiting..."
        exit 1
      fi
      mkdir "$import_vm"
      pushd "$import_vm"
      check_status() {
        if [ $? -eq 0 ]; then
          popd
          echo
          echo_success "Unarchiving"
        else
          popd
          echo
          echo_fail "Unarchiving"
          echo
          exit 1
        fi
      }
      if [ -n "$CONTAINER_NAME" ]; then
        echo "Running in a container..."
        run_command podman run --rm --volume "$ourpath:$ourpath":Z localhost/"$CONTAINER_NAME" sh -c "cd '$ourpath'/'$import_vm' && 7z x ../'$import_vm'.7z -p'$passphrase'"
        check_status
      else
        7z x ../"$import_vm.7z" -p"$passphrase"
        check_status
      fi
      echo

      echo_gum "Verifying SHA1 checksum for .qcow2 file:" "$import_vm"
      echo
      pushd "$import_vm"
      if run_command sha1sum -c "$import_vm.qcow2.sha1"; then
        popd
        echo
        echo_success "Checksum verification successful."
        echo
      else
        popd
        echo_fail "Checksum verification failed. Exiting..."
        echo
        exit 1
      fi

      echo_gum "Moving the VM disks..."
      echo
      # Loop through each .qcow2 file in the source directory
      for file in ./"$import_vm"/*.qcow2; do
        # Extract the filename from the path
        filename=$(basename "$file")
        # Extract disk file paths from the XML file
        xml_file="$ourpath/$import_vm/$import_vm.xml"
        if [ -n "$CONTAINER_NAME" ]; then
          run_command podman run --rm --volume "$ourpath:$ourpath":Z localhost/"$CONTAINER_NAME" sh -c "xmlstarlet sel -t -v \"/domain/devices/disk[@device='disk']/source/@file\" -n '$xml_file' | grep '$filename' > '$xml_file'.tmp"
        else
          xmlstarlet sel -t -v "/domain/devices/disk[@device='disk']/source/@file" -n "$xml_file" | grep "$filename" > "$xml_file".tmp
        fi
        disk_path=$( cat "$xml_file".tmp )
        if [ -z "$disk_path" ]; then
          echo
          echo_fail "Couldn't find a disk path in the XML file, exiting..."
          error_occurred=1
          break
        else
          error_occurred=0
        fi
        folder_path=$(dirname "$disk_path")
        if [ -z "$folder_path" ]; then
          echo
          echo_fail "Couldn't find a folder path in the XML file, exiting..."
          error_occurred=1
          break
        else
          error_occurred=0
        fi
        mkdir -p "$folder_path"

        # Check if the file already exists in the destination
        if [ -e "$folder_path/$filename" ]; then
          echo
          echo_fail "File $filename already exists in the destination. Skipping copy."
        else
          # Move the file to the destination
          echo "Moving $filename to $folder_path"
          sudo mv "$import_vm/$filename" "$folder_path"
          if [ $? -eq 0 ]; then
            echo_success "Moved $filename to $folder_path."
            error_occurred=0
          else
            echo_fail "Failed to move $filename"
            error_occurred=1
            break
          fi
        fi
      done
      if [ "$error_occurred" -eq 1 ] 2>/dev/null; then
        exit 1
      fi
      echo
      echo_gum "Defining VM:" "$import_vm.xml"
      echo
      import_vm_xml="$import_vm/$import_vm.xml"

      # Check if the VM already exists
      if run_command virsh -c qemu:///session list --all | grep -q " $import_vm "; then
        echo "A VM with the name '$import_vm' already exists."
        exit 1
      else
        # If the VM does not exist, define it
        if run_command virsh -c qemu:///session define --file "$import_vm/$import_vm.xml"; then
          echo
          echo_success "$import_vm defined successfully."
          echo
          echo_gum "Deleting temporary folder:" "$import_vm/"
          echo
          rm -rf ./"$import_vm"
          echo_success "VM imported!"
          echo
        else
          echo
          echo_fail "Failed to define $import_vm."
          echo
        fi
      fi
      if [ -n "$CONTAINER_NAME" ]; then
        check_status() {
          if [ $? -eq 0 ]; then
            echo
            echo_success "SELinux security context set"
            echo
          else
            echo
            echo_fail "Failed to set SELinux security context!"
            exit 1
          fi
        }
        echo_gum "Restoring SELinux security context for VM storage pool"
        echo
        run_command sh -c "chcon -u system_u -r object_r -t virt_image_t -l s0 $folder_path"
        check_status
        run_command sh -c "chcon -u system_u -r object_r -t virt_image_t -l s0 $folder_path/*"
        check_status
      fi

    else
      echo
      echo_fail "No .7z file found for $import_vm"
      echo
      exit 1
    fi
    ;;
  * )
    echo
    echo_fail "Invalid option."
    echo
    exit 1
    ;;
esac

if [ -n "$CONTAINER_NAME" ]; then
  echo
  if gum confirm --default="no" "Do you want to remove the container image?"; then
    run_command podman rmi localhost/"$CONTAINER_NAME"
  fi
fi
cleanup
echo
