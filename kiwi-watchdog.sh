#!/bin/bash

###  kiwi-watchdog:   pings Kiwis and powe cycles them if they don't respond

###    Copyright (C) 2021-2023  Robert S. Robinett
###
###    This program is free software: you can redistribute it and/or modify
###    it under the terms of the GNU General Public License as published by
###    the Free Software Foundation, either version 3 of the License, or
###    (at your option) any later version.
###
###    This program is distributed in the hope that it will be useful,
###    but WITHOUT ANY WARRANTY; without even the implied warranty of
###    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
###   GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with this program.  If not, see <https://www.gnu.org/licenses/>.

### 4/21/2023:
### This program controls the relays on a IOTZone web controlled 8 channel relay board bought for $40 from one of the many vendors on ebay:
###           https://www.ebay.com/itm/123388529835
### The board is delivered set to ip 192.168.1.166, but it is easy to change it to DHCP
### Documenation of how to interact with it was very hard to find, but some kind person found the manufacturer in China and posted the manual on github at:
###           https://github.com/mgx0/ZMRN0808-V5

### This program previously controlled a Sain brand ethernet controller to control a bank of 8 mechanical relays
### The Sain controller has a fixed IP address of 192.168.1.4, so the Pi running this program must have a LOCAL path to the that address i.e. IP traffic can't go through a router
### So this program needs to run on a Pi attached to the same LAN as the Sain controller and the Pi must be configured 
### with an additional IP addresss on eth0 by executing:  'ip address add 192.168.1.xx/24 dev etho'
### IOTZone board is so superior to the Sain that I don't plan to use it again but left the control function for it in this file.

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced

declare -r CMD_NAME="${0##*/}"
declare -r CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

declare CONF_FILE="${CMD_DIR}/${CMD_NAME%.*}.conf"
if [[ ! -f ${CONF_FILE} ]]; then
    echo "ERROR: can't find '${CONF_FILE}'"
    return 1
fi
source  ${CONF_FILE}

declare -r VERSION=0.3
declare    VERBOSITY=${VERBOSITY-0}     ### default to level 0 so that when running as a daemon the program doesn't fill up a file systrem with log messages
declare -r CMD_PATH="${CMD_DIR}/${CMD_NAME}"
declare -r CMD_DESCRIPTION="Power Control Watchdog"
declare -r KIWI_POWER_WAIT_SECS=60           ### How long to wait after powering off a Kiwi before checking if it is back online
declare -r KIWI_POWER_WATCH_DAEMON_PID_FILE=${CMD_DIR}/kiwi-watchdog-daemon.pid
declare -r KIWI_POWER_WATCH_DAEMON_LOG_FILE=${CMD_DIR}/kiwi-watchdog-daemon.log

###  Manage 
declare -r KIWI_STARTUP_DELAY_SECONDS=60   ### When starting the Pi wait this long before checking the Kiwis which may be powering up at the same time.
declare    SYSTEMNCTL_UNIT_FILE_NAME=${0##*/}
declare -r SYSTEMNCTL_SERVICE_NAME=${SYSTEMNCTL_UNIT_FILE_NAME%.*}
           SYSTEMNCTL_UNIT_FILE_NAME=${SYSTEMNCTL_SERVICE_NAME}.service
declare -r SYSTEMNCTL_UNIT_DIR=/lib/systemd/system
declare -r SYSTEMNCTL_UNIT_PATH=${SYSTEMNCTL_UNIT_DIR}/${SYSTEMNCTL_UNIT_FILE_NAME}

cat > ${SYSTEMNCTL_UNIT_FILE_NAME} <<EOF
    [Unit]
    Description= ${CMD_DESCRIPTION}
    After=multi-user.target

    [Service]
    User=$(id -u -n)
    Group=$(id -g -n) 
    WorkingDirectory=${CMD_DIR}
    ExecStart=${CMD_PATH} -A
    ExecStop=${CMD_PATH} -z
    Type=forking
    Restart=on-abort

    [Install]
    WantedBy=multi-user.target
EOF

function setup_systemctl_deamon() 
{
    if [[ ! -d ${SYSTEMNCTL_UNIT_DIR} ]]; then
        echo "WARNING: this server appears to not be configured to use 'systemnctl' needed to start the kiwiwspr daemon at startup"
        return
    fi
    if [[ -f ${SYSTEMNCTL_UNIT_PATH} ]]; then
        if diff ${SYSTEMNCTL_UNIT_FILE_NAME} ${SYSTEMNCTL_UNIT_PATH} ; then
            echo "This service is already setup"
            return 0
        else
            echo "This service template ${SYSTEMNCTL_UNIT_FILE_NAME} differs from the installed service file ${SYSTEMNCTL_UNIT_PATH}, so reinstall it."
        fi
    fi
    sudo cp ${SYSTEMNCTL_UNIT_FILE_NAME} ${SYSTEMNCTL_UNIT_PATH}
    echo "Copied ${SYSTEMNCTL_UNIT_FILE_NAME} to ${SYSTEMNCTL_UNIT_PATH}"

    sudo systemctl daemon-reload
    echo "Created '${SYSTEMNCTL_UNIT_PATH}'."
}

function start_systemctl_daemon()
{
    sudo systemctl start ${SYSTEMNCTL_SERVICE_NAME}
}

function enable_systemctl_deamon() 
{
    setup_systemctl_deamon
    sudo systemctl enable ${SYSTEMNCTL_SERVICE_NAME}
    echo "Watchdog daemon will now automatically start after a powerup or reboot of this system"
}

function disable_systemctl_deamon() 
{
    sudo systemctl stop    ${SYSTEMNCTL_SERVICE_NAME}
    sudo systemctl disable ${SYSTEMNCTL_SERVICE_NAME}
}

function get_systemctl_deamon_status()
{
    setup_systemctl_deamon
    sudo systemctl status ${SYSTEMNCTL_UNIT_FILE_NAME}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        echo "${SYSTEMNCTL_UNIT_FILE_NAME} is enabled"
    else
        echo "${SYSTEMNCTL_UNIT_FILE_NAME} is disabled"
    fi
}

function startup_daemon_control()
{
    local action=${1-h}

    case ${action} in
        h)
            echo "usage: -d [a|i|z|s]     setup to be run at startup of this server using the systemctl service (a=start, i=install and enable, z=disable and stop, s=show status"
            ;;
        a)
            start_systemctl_daemon
            ;;
        i)
            enable_systemctl_deamon
            ;;
        z)
            disable_systemctl_deamon
            ;;
        s)
            get_systemctl_deamon_status
            ;;
        *)
            echo "ERROR: action ${action} is invalid"
            ;;
    esac
}

# The 8 relay control board is 
#  URL commands
# (1) http://admin:12345678@192.168.1.166/relay.cgi?relayon1=on
# The relay 1 is on.
# (2) http://admin:12345678@192.168.1.166/relay.cgi?relayoff1=off
# The relay 1 is off.
# (3) http://admin:12345678@192.168.1.166/relay.cgi?pulse1=pulse
# The relay 1 is pulse.
# (4) http://admin:12345678@192.168.1.166/state.cgi
# Get the state of the device.
# 
function relay_control()
{
    local kiwi=$1          ## 72...78, or 100 = netgear
    local on_off=$2        ## on or off

    local relay=$(( ${kiwi} - 71 ))
    curl http://admin:12345678@${RELAY_CONTROL_IP}/relay.cgi?relay${on_off}${relay} > /dev/null 2> /dev/null
}


########################################
### This controls the V1.0 relay controller which was very, very stupid and is no longer installed anywhere
### But I have them in HMB as a last resort backup
function sain_control() 
{
    local kiwi=$1          ## 72...78, or 100 = netgear
    local on_off=$2        ## on or off

    local relay=$(( ${kiwi} - 71 ))
    local state=0   ## Default to "on"

    if [[ "${on_off}" == "off" ]]; then
        state=1
    fi
    echo -n -e "\xfd\x02\x20\x${relay}\x${state}\x5d" | nc -w 0 192.168.1.4 30000
}

function kiwi_watchdog_daemon()
{
    local startup_delay=${1-0}

    if [[ ${startup_delay} -eq 0 ]]; then
        echo "$(date): kiwi_watchdog_daemon() is starting" | tee -a ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
    else
        echo "$(date): kiwi_watchdog_daemon() will start after a delay of ${startup_delay} seconds" | tee -a ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
        sleep ${startup_delay}
        echo "$(date): kiwi_watchdog_daemon() now starting after a delay of ${startup_delay} seconds" | tee -a ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
    fi

    while true; do
        [[ ${VERBOSITY} -ge 2 ]] && echo "$(date): Checking that all Kiwis are running" >> ${KIWI_POWER_WATCH_DAEMON_LOG_FILE} 

        ### Make sure the IP interface to the Kiwis is active by successfully pinging the router
        local router_ip=${KIWI_BASE_IP}.1
        while ! ping -c 1 ${router_ip} > /dev/null ; do
            echo "$(date): failed to ping router at ${router_ip}, so assume that ethernet interface on this server is down and can't reach the Kiwis even if they are online.  Sleeping 60 seconds and retrying"
            sleep 60;
        done
        
        local kiwi_id
        for kiwi_id in ${KIWI_ID_LIST[@]}; do
            local kiwi_ip="${KIWI_BASE_IP}.${kiwi_id}"
            ##ping -c 1 ${kiwi_ip} > /dev/null
            curl --silent ${kiwi_ip}:8073/status > curl_output.txt
            local ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                [[ ${VERBOSITY} -ge 2 ]] && echo "$(date): 'curl --silent ${kiwi_ip}/status => ${ret_code}, so Kiwi ${kiwi_id} is OK" >> ${KIWI_POWER_WATCH_DAEMON_LOG_FILE} 
            else
                echo "$(date): ERROR: 'curl --silent ${kiwi_ip}/status' => ${ret_code}, so power cycling Kiwi${kiwi_id} for 10 seconds"  >> ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
                relay_control ${kiwi_id} on
                sleep 10
                relay_control ${kiwi_id} off 
                ### We won't check this Kiwi again for at least 60 seconds, so no need to wait for it to come alive again
            fi
        done
        sleep ${KIWI_POWER_WAIT_SECS}
    done
}

function check_kiwi_status()
{
    local router_ip=${KIWI_BASE_IP}.1
    if ! ping -c 1 ${router_ip} > /dev/null ; then
        echo "$(date): failed to ping router at ${router_ip}, so assume that ethernet interface on this server is down and can't reach the Kiwis even if they are online.  Sleeping 60 seconds and retrying"
        return 1
    fi

    local kiwi_id
    for kiwi_id in ${KIWI_ID_LIST[@]}; do
        local kiwi_ip="${KIWI_BASE_IP}.${kiwi_id}"
        if ping -c 1 ${kiwi_ip} > /dev/null; then
            echo "'ping -c 1 ${kiwi_ip}' => $?, so Kiwi ${kiwi_id} is OK" 
        else
            echo "ERROR: 'ping -c 1 ${kiwi_ip}' => $?"
        fi
    done
}


function spawn_kiwi_watchdog_daemon()
{
    local startup_delay=$1 

    if [[ -f ${KIWI_POWER_WATCH_DAEMON_PID_FILE} ]]; then
        local daemon_pid=$( < ${KIWI_POWER_WATCH_DAEMON_PID_FILE}) 
        if ps ${daemon_pid} > /dev/null ; then
            echo "kiwi_watchdog_daemon is running with pid = ${daemon_pid}"
            return 0
        else
            echo "kiwi_watchdog_daemon pid ${daemon_pid} in ${KIWI_POWER_WATCH_DAEMON_PID_FILE} is not active."
            rm ${KIWI_POWER_WATCH_DAEMON_PID_FILE}
        fi
    fi
    kiwi_watchdog_daemon ${startup_delay} &
    local daemon_pid=$!
    echo ${daemon_pid} > ${KIWI_POWER_WATCH_DAEMON_PID_FILE}
    echo "Spawned kiwi_watchdog_daemon which has pid ${daemon_pid}"
}

function kill_kiwi_watchdog_daemon()
{
    if [[ -f ${KIWI_POWER_WATCH_DAEMON_PID_FILE} ]]; then
        local daemon_pid=$( < ${KIWI_POWER_WATCH_DAEMON_PID_FILE}) 
        if ps ${daemon_pid} > /dev/null ; then
            kill ${daemon_pid}
            echo "Killed running kiwi_watchdog_daemon which had pid = ${daemon_pid}"
        else
            echo "Found kiwi_watchdog_daemon pid ${daemon_pid} in ${KIWI_POWER_WATCH_DAEMON_PID_FILE} is not active."
        fi
        rm ${KIWI_POWER_WATCH_DAEMON_PID_FILE}
    else
        echo "There is no file ${KIWI_POWER_WATCH_DAEMON_PID_FILE}, so kiwi_watchdog_daemon was not running"
    fi
}

function status_of_kiwi_watchdog_daemon()
{
    if [[ -f ${KIWI_POWER_WATCH_DAEMON_PID_FILE} ]]; then
        local daemon_pid=$( < ${KIWI_POWER_WATCH_DAEMON_PID_FILE}) 
        if ps ${daemon_pid} > /dev/null ; then
            echo "kiwi_watchdog_daemon is running with pid = ${daemon_pid}"
        else
            echo "Found kiwi_watchdog_daemon pid ${daemon_pid} in ${KIWI_POWER_WATCH_DAEMON_PID_FILE} but that pid is not active."
            rm ${KIWI_POWER_WATCH_DAEMON_PID_FILE}
        fi
    else
        echo "There is no file ${KIWI_POWER_WATCH_DAEMON_PID_FILE}, so kiwi_watchdog_daemon is not running"
    fi
    check_kiwi_status
}

function usage()
{
    echo "$0 Version ${VERSION}: 
    -c KIWI STATE    KIWI=72...78  STATE=on|off
    -a               start daemon which pings kiwis and power cycles them if they don't respond
    -A               start daemon with a delay of ${KIWI_STARTUP_DELAY_SECONDS}
    -z               kill the daemon
    -s               show the daemon status
    -d [a|i|z|s]     setup to be run at startup of this server using the systemctl service (a=start, i=install and enable, z=disable and stop, s=show status"
}

case ${1--h} in
    -c)
        relay_control $2 $3
        ;;
    -a)
        spawn_kiwi_watchdog_daemon ${2-0}
        ;;
    -A)
        ### If this is installed as a Pi daemon by '-d a', the systemctl system will execute '-A'.  
        spawn_kiwi_watchdog_daemon ${KIWI_STARTUP_DELAY_SECONDS}
        ;;
    -z)
        kill_kiwi_watchdog_daemon
        ;;
    -s)
        status_of_kiwi_watchdog_daemon
        ;;
    -d)
        startup_daemon_control ${2-h}
        ;;
    -h)
        usage
        ;;
    *)
        echo "ERROR: flag '$1' is not valid"
        ;;
esac

exit 0
