### base variables
SYSTEMDDIR="/etc/systemd/system"
KLIPPY_ENV="${HOME}/klippy-env"
KLIPPER_DIR="${HOME}/klipper"

klipper_setup_dialog(){
  status_msg "Initializing Klipper installation ..."

  ### check for existing klipper service files
  INITD=$(ls /etc/init.d | grep -E "^klipper(\-[[:digit:]]+)?$")
  SYSTEMD=$(ls /etc/systemd/system | grep -E "^klipper(\-[[:digit:]]+)?\.service$")

  if [ ! -z "$INITD" ] || [ ! -z "$SYSTEMD" ]; then
    echo "${red}$INITD${default}" && echo "${red}$SYSTEMD${default}"
    ERROR_MSG="At least one Klipper service is already installed!\n Please remove Klipper first, before installing it again." && return 0
  fi

  ### initial printer.cfg path check
  check_klipper_cfg_path

  ### ask for amount of instances to create
  INSTANCE_COUNT=""
  while [[ ! ($INSTANCE_COUNT =~ ^[1-9]+$) ]]; do
    echo
    read -p "${cyan}###### Number of Klipper instances to set up:${default} " INSTANCE_COUNT
    if [[ ! ($INSTANCE_COUNT =~ ^[1-9]+$) ]]; then
      warn_msg "Invalid Input!" && echo
    else
      echo
      read -p "${cyan}###### Install $INSTANCE_COUNT instance(s)? (Y/n):${default} " yn
      case "$yn" in
        Y|y|Yes|yes|"")
          echo -e "###### > Yes"
          status_msg "Installing $INSTANCE_COUNT Klipper instance(s) ..."
          klipper_setup
          break;;
        N|n|No|no)
          echo -e "###### > No"
          warn_msg "Exiting Klipper setup ..."
          echo
          break;;
        *)
          print_unkown_cmd
          print_msg && clear_msg;;
      esac
    fi
  done
}

install_klipper_packages(){
  ### read PKGLIST from official install script
  status_msg "Reading dependencies..."
  install_script="${HOME}/klipper/scripts/install-octopi.sh"
  PKGLIST=$(grep "PKGLIST=" $install_script | sed 's/PKGLIST//g; s/[$={}\n"]//g')
  ### rewrite packages into new array
  unset PKGARR
  for PKG in $PKGLIST; do PKGARR+=($PKG); done
  ### add dbus requirement for DietPi distro
  if [ -e "/boot/dietpi" ]; then
    PKGARR+=("dbus")
  fi

  ### display dependencies to user
  echo "${cyan}${PKGARR[@]}${default}"

  ### Update system package info
  status_msg "Running apt-get update..."
  sudo apt-get update

  ### Install desired packages
  status_msg "Installing packages..."
  sudo apt-get install --yes ${PKGARR[@]}
}

create_klipper_virtualenv(){
  status_msg "Installing python virtual environment..."
  # Create virtualenv if it doesn't already exist
  [ ! -d ${KLIPPY_ENV} ] && virtualenv -p python2 ${KLIPPY_ENV}
  # Install/update dependencies
  ${KLIPPY_ENV}/bin/pip install -r ${KLIPPER_DIR}/scripts/klippy-requirements.txt
}

klipper_setup(){
  ### step 1: clone klipper
  status_msg "Downloading Klipper ..."
  ### force remove existing klipper dir and clone into fresh klipper dir
  [ -d $KLIPPER_DIR ] && rm -rf $KLIPPER_DIR
  cd ${HOME} && git clone $KLIPPER_REPO
  status_msg "Download complete!"

  ### step 2: install klipper dependencies and create python virtualenv
  status_msg "Installing dependencies ..."
  install_klipper_packages
  create_klipper_virtualenv

  ### step 3: create shared gcode_files and logs folder
  [ ! -d ${HOME}/gcode_files ] && mkdir -p ${HOME}/gcode_files
  [ ! -d ${HOME}/klipper_logs ] && mkdir -p ${HOME}/klipper_logs

  ### step 4: create klipper instances
  create_klipper_service

  ### confirm message
  CONFIRM_MSG="$INSTANCE_COUNT Klipper instances have been set up!"
  [ $INSTANCE_COUNT -eq 1 ] && CONFIRM_MSG="Klipper has been set up!"
  print_msg && clear_msg
}

create_klipper_service(){
  ### get config directory
  source_kiauh_ini

  ### set up default values
  SINGLE_INST=1
  CFG_PATH="$klipper_cfg_loc"
  KL_ENV=$KLIPPY_ENV
  KL_DIR=$KLIPPER_DIR
  KL_LOG="${HOME}/klipper_logs/klippy.log"
  KL_UDS="/tmp/klippy_uds"
  P_TMP="/tmp/printer"
  P_CFG="$CFG_PATH/printer.cfg"
  P_CFG_SRC="${SRCDIR}/kiauh/resources/printer.cfg"
  KL_SERV_SRC="${SRCDIR}/kiauh/resources/klipper.service"
  KL_SERV_TARGET="$SYSTEMDDIR/klipper.service"

  write_kl_service(){
    [ ! -d $CFG_PATH ] && mkdir -p $CFG_PATH
    ### create a minimal config if there is no printer.cfg
    [ ! -f $P_CFG ] && cp $P_CFG_SRC $P_CFG
    ### replace placeholder
    if [ ! -f $KL_SERV_TARGET ]; then
      status_msg "Creating Klipper Service $i ..."
        sudo cp $KL_SERV_SRC $KL_SERV_TARGET
        sudo sed -i "s|%INST%|$i|" $KL_SERV_TARGET
        sudo sed -i "s|%USER%|${USER}|" $KL_SERV_TARGET
        sudo sed -i "s|%KL_ENV%|$KL_ENV|" $KL_SERV_TARGET
        sudo sed -i "s|%KL_DIR%|$KL_DIR|" $KL_SERV_TARGET
        sudo sed -i "s|%KL_LOG%|$KL_LOG|" $KL_SERV_TARGET
        sudo sed -i "s|%P_CFG%|$P_CFG|" $KL_SERV_TARGET
        sudo sed -i "s|%P_TMP%|$P_TMP|" $KL_SERV_TARGET
        sudo sed -i "s|%KL_UDS%|$KL_UDS|" $KL_SERV_TARGET
    fi
  }

  if [ $SINGLE_INST -eq $INSTANCE_COUNT ]; then
    ### write single instance service
    write_kl_service
    ### enable instance
    sudo systemctl enable klipper.service
    ok_msg "Single Klipper instance created!"
    ### launching instance
    status_msg "Launching Klipper instance ..."
    sudo systemctl start klipper
  else
    i=1
    while [ $i -le $INSTANCE_COUNT ]; do
      ### rewrite default variables for multi instance cases
      CFG_PATH="$klipper_cfg_loc/printer_$i"
      KL_SERV_TARGET="$SYSTEMDDIR/klipper-$i.service"
      P_TMP="/tmp/printer-$i"
      P_CFG="$CFG_PATH/printer.cfg"
      KL_LOG="${HOME}/klipper_logs/klippy-$i.log"
      KL_UDS="/tmp/klippy_uds-$i"
      ### write multi instance service
      write_kl_service
      ### enable instance
      sudo systemctl enable klipper-$i.service
      ok_msg "Klipper instance #$i created!"
      ### launching instance
      status_msg "Launching Klipper instance #$i ..."
      sudo systemctl start klipper-$i

      ### raise values by 1
      i=$((i+1))
    done
    unset i
  fi
}

flash_routine(){
  echo
  top_border
  echo -e "|        ${red}~~~~~~~~~~~ [ ATTENTION! ] ~~~~~~~~~~~~${default}        |"
  hr
  echo -e "| Flashing a Smoothie based board with this method will |"
  echo -e "| certainly fail. This applies to boards like the SKR   |"
  echo -e "| V1.3 / V1.4. You have to copy the firmware file to    |"
  echo -e "| the SD card manually and rename it to 'firmware.bin'. |"
  hr
  echo -e "| You can find the file in: ~/klipper/out/klipper.bin   |"
  bottom_border
  while true; do
    read -p "${cyan}###### Do you want to continue? (Y/n):${default} " yn
    case "$yn" in
      Y|y|Yes|yes|"")
        echo -e "###### > Yes"
        FLASH_FIRMWARE="true"
        get_mcu_id
        break;;
      N|n|No|no)
        echo -e "###### > No"
        FLASH_FIRMWARE="false"
        break;;
      *)
        print_unkown_cmd
        print_msg && clear_msg;;
    esac
  done
}

flash_routine_sd(){
  echo
  top_border
  echo -e "|        ${red}~~~~~~~~~~~ [ ATTENTION! ] ~~~~~~~~~~~~${default}        |"
  hr
  echo -e "| If you have a Smoothie based board with an already    |"
  echo -e "| flashed Klipper Firmware, you can now choose to flash |"
  echo -e "| directly from the internal SD if your control board   |"
  echo -e "| is supported by that function.                        |"
  bottom_border
  while true; do
    read -p "${cyan}###### Do you want to continue? (Y/n):${default} " yn
    case "$yn" in
      Y|y|Yes|yes|"")
        echo -e "###### > Yes"
        FLASH_FW_SD="true"
        get_mcu_id
        break;;
      N|n|No|no)
        echo -e "###### > No"
        FLASH_FW_SD="false"
        break;;
      *)
        print_unkown_cmd
        print_msg && clear_msg;;
    esac
  done
}

select_mcu_id(){
  if [ ${#mcu_list[@]} -ge 1 ]; then
    echo
    top_border
    echo -e "|                   ${red}!!! ATTENTION !!!${default}                   |"
    hr
    echo -e "| Make sure, to select the correct number for the MCU!  |"
    echo -e "| ${red}ONLY flash a firmware created for the respective MCU!${default} |"
    bottom_border
    echo -e "${cyan}###### List of available MCU:${default}"
    ### list all mcus
    id=0
    for mcu in ${mcu_list[@]}; do
      let id++
      echo -e " $id) $mcu"
    done
    ### verify user input
    sel_index=""
    while [[ ! ($sel_index =~ ^[1-9]+$) ]] || [ $sel_index -gt $id ]; do
      echo
      read -p "${cyan}###### Select MCU to flash:${default} " sel_index
      if [[ ! ($sel_index =~ ^[1-9]+$) ]]; then
        warn_msg "Invalid input!"
      elif [ $sel_index -lt 1 ] || [ $sel_index -gt $id ]; then
        warn_msg "Please select a number between 1 and $id!"
      fi
      mcu_index=$(echo $((sel_index - 1)))
      selected_mcu_id="${mcu_list[$mcu_index]}"
    done
    ### process flashing
    while true; do
      echo -e "\n###### You selected:\n ● MCU #$sel_index: $selected_mcu_id\n"
      read -p "${cyan}###### Continue? (Y/n):${default} " yn
      case "$yn" in
        Y|y|Yes|yes|"")
          echo -e "###### > Yes"
          status_msg "Flashing $selected_mcu_id ..."
          if [ "$FLASH_FIRMWARE" = "true" ]; then
            flash_mcu
          fi
          if [ "$FLASH_FW_SD" = "true" ]; then
            flash_mcu_sd
          fi
          break;;
        N|n|No|no)
          echo -e "###### > No"
          break;;
        *)
          print_unkown_cmd
          print_msg && clear_msg;;
      esac
    done
  fi
}

flash_mcu(){
  do_action_service "stop" "klipper"
  if ! make flash FLASH_DEVICE="${mcu_list[$mcu_index]}" ; then
    warn_msg "Flashing failed!"
    warn_msg "Please read the console output above!"
  else
    ok_msg "Flashing successfull!"
  fi
  do_action_service "start" "klipper"
}

flash_mcu_sd(){
  do_action_service "stop" "klipper"

  ### write each supported board to the array to make it selectable
  board_list=()
  for board in $(~/klipper/scripts/flash-sdcard.sh -l | tail -n +2); do
    board_list+=($board)
  done

  i=0
  top_border
  echo -e "|  Please select the type of board that corresponds to  |"
  echo -e "|  the currently selected MCU ID you chose before.      |"
  blank_line
  echo -e "|  The following boards are currently supported:        |"
  hr
  ### display all supported boards to the user
  for board in ${board_list[@]}; do
    if [ $i -lt 10 ]; then
      printf "|  $i) %-50s|\n" "${board_list[$i]}"
    else
      printf "|  $i) %-49s|\n" "${board_list[$i]}"
    fi
    i=$((i + 1))
  done
  quit_footer

  ### make the user select one of the boards
  while true; do
    read -p "${cyan}###### Please select board type:${default} " choice
    if [ $choice = "q" ] || [ $choice = "Q" ]; then
      clear && advanced_menu && break
    elif [ $choice -le ${#board_list[@]} ]; then
      selected_board="${board_list[$choice]}"
      break
    else
      clear && print_header
      ERROR_MSG="Invalid choice!" && print_msg && clear_msg
      flash_mcu_sd
    fi
  done

  while true; do
    top_border
    echo -e "| If your board is flashed with firmware that connects  |"
    echo -e "| at a custom baud rate, please change it now.          |"
    blank_line
    echo -e "| If you are unsure, stick to the default 250000!       |"
    bottom_border
    echo -e "${cyan}###### Please set the baud rate:${default} "
    unset baud_rate
    while [[ ! $baud_rate =~ ^[0-9]+$ ]]; do
      read -e -i "250000" -e baud_rate
      selected_baud_rate=$baud_rate
      break
    done
  break
  done

  if ! ${HOME}/klipper/scripts/flash-sdcard.sh -b "$selected_baud_rate" "$selected_mcu_id" "$selected_board" ; then
    warn_msg "Flashing failed!"
    warn_msg "Please read the console output above!"
  else
    ok_msg "Flashing successfull!"
  fi

  do_action_service "start" "klipper"
}

build_fw(){
  if [ -d $KLIPPER_DIR ]; then
    cd $KLIPPER_DIR
    status_msg "Initializing firmware build ..."
    dep=(build-essential dpkg-dev make)
    dependency_check
    make clean
    make menuconfig
    status_msg "Building firmware ..."
    make && ok_msg "Firmware built!"
  else
    warn_msg "Can not build firmware without a Klipper directory!"
  fi
}

### grab the mcu id
get_mcu_id(){
  echo
  top_border
  echo -e "| Please make sure your MCU is connected to the Pi!     |"
  echo -e "| If the MCU is not connected yet, connect it now.      |"
  bottom_border
  echo -e "${cyan}"
  read -p "###### Press ANY KEY to continue ... " -n 1 -r
  echo -e "${default}"
  status_msg "Identifying the ID of your MCU ..."
  sleep 1
  unset MCU_ID
  ### if there are devices found, continue, else show warn message
  if ls /dev/serial/by-id/* 2>/dev/null 1>&2; then
    mcu_count=1
    mcu_list=()
    status_msg "The ID of your printers MCU is:"
    ### loop over the IDs, write every ID as an item of the array 'mcu_list'
    for mcu in /dev/serial/by-id/*; do
      declare "mcu_id_$mcu_count"="$mcu"
      mcu_id="mcu_id_$mcu_count"
      mcu_list+=("${!mcu_id}")
      echo " ● MCU #$mcu_count: ${cyan}$mcu${default}"
      mcu_count=$(expr $mcu_count + 1)
    done
    unset mcu_count
  else
    warn_msg "Could not retrieve ID!"
    warn_msg "Printer not plugged in or not detectable!"
  fi
}
