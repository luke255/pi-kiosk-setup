#!/bin/bash

# create a temp file
tmp=$(mktemp)

# set to 1 if any errors occur
err=0

# define styling variables
reset=\\e[0m
bold=\\e[1m
red=\\e[1\;97\;101m
green=\\e[1\;97\;42m
blue=\\e[1\;97\;104m
cyan=\\e[1\;97\;46m
magenta=\\e[1\;97\;105m
yellow=\\e[1\;30\;103m

# requires:
#  - description
#  - command
#  - prompt formatting description OR "SHOW" to indicate command contains custom prompt
function run () {
  show="false"
  prompt=$3
    echo -e "${bold}$1${reset}$([[ ${prompt} == "" ]] && echo "..." || ([[ ${prompt} == "SHOW" ]] && echo -e " -\n" || echo " [${prompt}]: "))" # print description of current command
    echo -e "####\n\nDescription: \"$1\"\n\nCommand: $2\n\nOutput:\n" >> ${tmp} # write command and description to log file
    if [[ ${prompt} == "SHOW" ]] # if 3rd parameter set to "SHOW", the command itself is a prompt
    then
      prompt="" # not a built in prompt, handle as normal command later on
      eval "$2" >> ${tmp} # execute given command, output shown to user and logged to temp file
    else
      eval "$2" &>> ${tmp} # execute given command, output logged to temp file only
    fi
    ec=$? # store commands exit code
    echo -e "\nExit code: ${ec}\n" >> ${tmp} # write exit code to log file
    if [ ${ec} -eq 0 ] # check for errors
    then
        echo -e "${green}Success${reset}\n" # no errors!
    else
        echo -e "${red}Failed${reset}" # indicate an error and provide a choice
        select option in Abort Retry$([[ ${prompt} == "" ]] && echo " Fail")
        do
            case ${option} in
                "Abort") # exit the script, display report and don't process any further commands
                    err=1
                    echo -e "${red}Script aborted${reset}\n"
                    report
                    exit 0
                    break
                ;;
                "Retry") # run the command again
                    echo -e "${cyan}Retrying command${reset}\n"
                    run "$1" "$2" "$3" "$4"
                    break
                ;;
                "Fail") # record that an error occurred and continue with other commands
                    err=1
                    echo -e "${yellow}Skipping command${reset}\n"
                    break
                ;;
                *) # handle incorrect entries
                    echo -e "${red}Invalid selection${reset}\n"
                ;;
            esac
        done
    fi
}

# to be called as last step
function report () {
    if [ ${err} -eq 0 ] # alert if there were errors
    then
        echo -e "${green}Script finished without errors${reset}\n"
    else
        echo -e "${red}Script finished with errors${reset}"
    fi
    echo -e "${bold}Log file:${reset} ${tmp}\n" # print path to log file
}

# wrapper for run function. requires:
#  - prompt title
#  - formatting description
#  - prompt variable
#  - validation command
function prompt () {
    run "Please enter the $1" "read -p \"\" $3; $4" "$2"
}

# clean slate protocol
clear
echo ""

#############################
#                           #
#       MAIN SECTION        #
#                           #
#############################

# authenticate
pw="default"
run "Aquire authentication" "echo raspberry | sudo -S -v || pw=""; sudo -v" # authenticate with default password, fallback to a prompt
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null & # maintain authentication
username=$USER

# get project details
prompt "project name" "Maximum of 16 alphanumeric characters/underscores" "project" "grep -E \"^\\w+\$\" <<< \"\$project\""
prompt "kiosk url" "Valid, active URL" "kurl" "curl --head \"\$kurl\""

# not for everyone
enableRemote=1
read -p "Enable remote control? [Y/n]" -n 1 -r
echo ""
if [[ $REPLY =~ ^[Nn]$ ]]
then
    enableRemote=0
fi

# secure device and prompt user to fuck off for a bit
if [[ $pw = "default" ]]
then
    run "Setting new password" "sudo passwd ${username}" "SHOW"
fi
run "Enable passwordless sudo" "sudo rm -f '/etc/sudoers.d/*' && echo \"${username} ALL=(ALL:ALL) NOPASSWD:ALL\" | sudo tee -a '/etc/sudoers.d/$project'"
echo -e "${blue}All required information gathered. Remaining steps are automatic.\n\nRun the following command on your host device to copy your ssh key:${reset}\n\n${bold}ssh-copy-id ${username}@$(hostname -I)${reset}\n"
read -s -p "Press enter to finalise. This may take a little while."
echo -e "\n"

# apt update, upgrade and install
run "Update packages" "sudo apt-get update && sudo apt-get upgrade -y"
run "Install packages" "sudo apt-get install chromium-browser unattended-upgrades unclutter"

# clear existing scripts
run "Clear existing scripts" "rm -f /home/${username}/*.sh;rm -f /home/${username}/*.js;echo 1 > /home/pi/display_power.conf"

# configure remote control
if [[ $enableRemote = 1 ]]
then
    run "Install Node.js version manager" "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.36.0/install.sh | bash; export NVM_DIR=\"\$([ -z \"\${XDG_CONFIG_HOME-}\" ] && printf %s \"\${HOME}/.nvm\" || printf %s \"\${XDG_CONFIG_HOME}/nvm\")\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\""
    run "Install Node.js" "nvm install --lts; nvm use --lts"
    run "Install PM2" "npm install pm2 -g"
    echo "const{execFile:execFile}=require(\"child_process\"),fs=require(\"fs\");require(\"http\").createServer((e,i)=>{execFile(\"/usr/bin/vcgencmd\",[\"display_power\",e.url.split("/")[1]],(e,r)=>{let l=r.split(\"=\")[1];fs.writeFile(\"/home/pi/display_power.conf\",l,e=>{}),i.write(l),i.end()})}).listen(8080);" > /home/${username}/${project}.js
    run "Set up remote control script" "pm2 start /home/${username}/${project}.js; pm2 save; sudo env PATH=$PATH:/home/${username}/.nvm/versions/node/$(node -v)/bin /home/${username}/.nvm/versions/node/$(node -v)/lib/node_modules/pm2/bin/pm2 startup systemd -u ${username} --hp /home/${username}"
fi

# set boot options
tempConf=$(mktemp)
sed '/# --- /Q' /boot/config.txt > ${tempConf}
cat >> ${tempConf} << EOF
# --- ${project} config. DO NOT EDIT BELOW HERE! ---
disable_overscan=1
disable_splash=1
display_rotate=1
EOF
run "Set boot parameters" "sudo cp \$tempConf /boot/config.txt"
run "Wait for network on boot" "sudo raspi-config nonint do_boot_wait 1"
run "Disable splash screen" "sudo rm -f /usr/share/plymouth/themes/pix/splash.png"
run "Set hostname" "sudo raspi-config nonint do_hostname ${project}"
run "Disable Raspberry Pi welcome app" "sudo rm -f /etc/xdg/autostart/piwiz.desktop" 
run "Disable default password prompt" "sudo rm -f /etc/xdg/autostart/pprompt.desktop"

# auto updates, for better or worse
tempConf=$(mktemp)
cat > ${tempConf} <<EOF
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${distro_codename}-updates";
    "origin=Debian,codename=\${distro_codename},label=Debian";
    "origin=Debian,codename=\${distro_codename},label=Debian-Security";
    "origin=Raspbian,codename=\${distro_codename},label=Raspbian";
    "origin=Raspberry Pi Foundation,codename=\${distro_codename},label=Raspberry Pi Foundation";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
run "Configure unattended upgrades" "sudo cp \$tempConf /etc/apt/apt.conf.d/50unattended-upgrades"

# auto reboot at 03:30 every night, because i've given up trying to make Chrome run long term
run "Set up auto reboot" "echo \"30 3 * * * /home/${username}/${project}_reboot.sh\" | crontab"
cat >/home/${username}/${project}_reboot.sh <<EOF
#!/bin/bash

# make it so
sudo reboot
EOF
sudo chmod +x /home/${username}/${project}_reboot.sh

# clear chromium profile to avoid error when changing hostname
run "Remove old Chromium profiles" "rm -rf /home/${username}/.config/chromium/Singleton*"

# build and install the startup scripts
run "Create startup script" "mkdir -p /home/${username}/.config/lxsession/LXDE-pi && echo -e \"@/home/${username}/${project}.sh\" > /home/${username}/.config/lxsession/LXDE-pi/autostart"
cat >/home/${username}/${project}.sh <<EOF
#!/bin/bash

# Adapted from https://github.com/futurice/chilipie-kiosk

export DISPLAY=:0.0

# always keep the screen on, but not always
xset s off
xset -dpms
xset s noblank

# blank the screen for 20 seconds while the desktop ui and Chromium loads
/usr/bin/vcgencmd display_power 0
(sleep 20; /usr/bin/vcgencmd display_power \$(cat /home/${username}/display_power.conf)) &

# Hide cursor
unclutter -idle 0.5 -root &

# Make sure Chromium profile is marked clean, even if it crashed
if [ -f .config/chromium/Default/Preferences ]; then
    cat .config/chromium/Default/Preferences \\
        | jq '.profile.exit_type = "SessionEnded" | .profile.exited_cleanly = true' \\
        > .config/chromium/Default/Preferences-clean
    mv .config/chromium/Default/Preferences{-clean,}
fi

# Remove notes of previous sessions, if any
find .config/chromium/ -name "Last *" | xargs rm

# Start Chromium
/usr/bin/chromium-browser --app=$kurl \\
    --kiosk \\
    --noerrdialogs \\
    --disable-session-crashed-bubble \\
    --disable-infobars \\
    --check-for-update-interval=604800 \\
    --disable-pinch
EOF
sudo chmod +x /home/${username}/${project}.sh

# print summary
report

# ready to go?
echo -e "${yellow}Restarting in 10 seconds...${reset} "
sleep 10
echo -e "\nRestarting NOW!\n\nYou should be able to reconnect shortly with this command:\n\n${bold}ssh ${username}@${project}${reset}\n"
sudo shutdown -r now
