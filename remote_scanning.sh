#! /bin/bash

CURRENT_DIR=$(pwd)
NIPE_PROJECT_PATH=$(pwd)/nipe
NIPE_NUM_OF_RETRY=3
REMOTE_SERVER_IP=192.168.236.132
REMOTE_SERVER_USERNAME=tc
REMOTE_SERVER_PASSWORD=tc
LOG_FILE="/var/log/nr.log"
TARGET=""

# Function to precess installationprocess
function installRequiredPackage {
    case $1 in
        nipe)
            if ! [ -d $NIPE_PROJECT_PATH ]
            then
                echo "[*] Downloading Nipe project"
                git clone https://github.com/htrgouvea/nipe $NIPE_PROJECT_PATH >/dev/null 2>&1
            fi
            
            cd $NIPE_PROJECT_PATH
            
            if [[ $(sudo perl nipe.pl status 2>/dev/null) == "" ]]
            then
                echo "[#] Installing $1"
                cpanm --installdeps . >/dev/null 2>&1
                sudo cpanm -i Switch JSON LWP::UserAgent Config::Simple >/dev/null 2>&1
                sudo perl nipe.pl install >/dev/null 2>&1
            fi
        ;;
        *)
            local package_status
            package_status=$(dpkg-query -W -f='${Status}' $1 2>/dev/null | grep "install ok installed")
            if [[ "" = $package_status ]]
            then
                echo "[#] Installing $1..."
                sudo apt-get install -y $1 >/dev/null 2>&1
            fi
        ;;
    esac
    echo "[#] $1 has been installed."
}

# Function that execute command on remote server
function executeCommandOnRemote {
    # sshpass only execute the command on known hosts
    # which mean this device must have connected to private server before
    # we can escape this check by adding this ssh flag -> -o StrictHostKeyChecking=no
    # but it will expose to man in the middle attack
    sshpass -p $REMOTE_SERVER_PASSWORD ssh -o StrictHostKeyChecking=no $REMOTE_SERVER_USERNAME@$REMOTE_SERVER_IP $* 2>/dev/null
}

# Function that log message with addtional information
function logMessage {
    echo "$(date +'%a %d-%b-%Y %r %z') - $*" | sudo tee -a $LOG_FILE > /dev/null
}

# Function to show available options
function usage {
    echo "Usage: remote_scanning [option]"
    echo
    echo "Options:"
    echo "---------------------------------------------------------"
    echo -e "-h \t\t\t Help menu"
    echo -e "-n \t [NUMBER] \t Number of Nipe try to reconnect if Nipe failed to connect"
    echo -e "-p \t [PATH] \t Nipe project path"
    echo -e "-t \t [TARGET] \t Domain or IP address target to run the scan"
}

# Modify the default setup based on options input
while getopts ":hn:p:t:" flag
do
    case $flag in
        h)
            usage
            exit
        ;;
        n)
            NIPE_NUM_OF_RETRY=$OPTARG
        ;;
        p)
            NIPE_PROJECT_PATH=$OPTARG
        ;;
        t)
            TARGET=$OPTARG
        ;;
    esac
done

# Create log file
sudo touch $LOG_FILE
sudo chown 644 $LOG_FILE


# Install required package
APP_TO_INSTALL=("geoip-bin cpanminus nipe sshpass")

echo "[#] Updating package repo...."
sudo apt-get update > /dev/null 2>&1

for str in $APP_TO_INSTALL
do
    installRequiredPackage $str
done

echo

# Try to connect Nipe
echo "[#] Connecting to NIPE"
cd $NIPE_PROJECT_PATH      # NIPE only can run on it project folder

for (( i=0; i <= $NIPE_NUM_OF_RETRY; i++))
do
    nipe_status=$(sudo perl nipe.pl status 2>/dev/null)     # Ignore error message if any
    
    if [[ $(echo $nipe_status | grep "Status: true") == "" ]]
    then
        if [[ $i != 0 ]]
        then
            echo "[*] Failed to connect. Retry NIPE connection: $i"
            sleep 1s
        fi
        sudo perl nipe.pl restart
    else
        break
    fi
done

echo
# Check NIPE status & get the IP
if [[ $(echo $nipe_status | grep "Status: true") == "" ]]
then
    echo "[*] Failed to connect NIPE. Exit the program now"
    exit
else
    nipe_ip=$(echo $nipe_status | grep "Ip" | awk '{print $NF}')
    echo "[#] Connected to NIPE."
    echo "[*] Spoofed Ip: $nipe_ip"
    echo "[*] Spoofed country: $(geoiplookup $nipe_ip | cut -d ':' -f 2)"
fi

echo
if [[ $TARGET == "" ]]
then
    # Get user input of domain or ip to scan
    read -p "[?] Specific a Domain/IP address to scan: " TARGET
else
    echo "[*] Start to scan target: $TARGET"
fi

echo
# Try connect to private server
echo "[#] Connecting to remote server...."
remote_uptime=$(executeCommandOnRemote uptime)
if [[ $remote_uptime == "" ]]
then
    echo "[*] Failed to connect remote server. Kindly check the remote server Ip and user credential."
    exit
fi

echo "[*] Remote server status: $remote_uptime"
remote_public_ip=$(executeCommandOnRemote curl -s ifconfig.io)
echo "[*] Remote server IP details: $remote_public_ip, $(geoiplookup $remote_public_ip | cut -d ':' -f 2)"
executeCommandOnRemote mkdir $TARGET

echo
# Whois scanning
echo "[#] Whois scanning...."
output_name=$TARGET/whois_$TARGET.txt
executeCommandOnRemote "whois $TARGET > $output_name"
echo "[#] Whois scanning done. Whois scan output will saved as $output_name"
logMessage "Whois data collected for: $TARGET"

echo
# Nmap scanning
echo "[#] Nmap scanning...."
output_name=$TARGET/nmap_$TARGET.txt
executeCommandOnRemote nmap -Pn -oN $output_name scanme.nmap.com > /dev/null 2>&1
echo "[#] Nmap scanning done. Nmap scan output will saved as $output_name"
logMessage "Nmap data collected for: $TARGET"

echo
# Copy the file to local
echo "[#] Cloning the output"
cd $CURRENT_DIR
wget ftp://$REMOTE_SERVER_USERNAME:$REMOTE_SERVER_PASSWORD@$REMOTE_SERVER_IP/$TARGET/* -P $TARGET >/dev/null 2>&1
echo "[*] All the output saved to \"$TARGET\" directory."

# Final
# Stop Nipe connection
echo "[#] Stoping Nipe"
cd $NIPE_PROJECT_PATH
sudo perl nipe.pl stop
