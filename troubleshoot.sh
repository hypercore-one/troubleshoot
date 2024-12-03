#!/bin/bash

# Get the directory where the script is being run from
SCRIPT_DIR="$(pwd)"

# Set up variables
OUTPUT_FILE="$SCRIPT_DIR/troubleshoot_zenon.txt"
LOGS_DIR="$SCRIPT_DIR/logs"
COMPRESSED_FILE="$LOGS_DIR/troubleshoot_zenon.txt.gz"

# Delete existing output file and compressed file if they exist
if [ -f "$OUTPUT_FILE" ]; then
    rm -f "$OUTPUT_FILE"
fi

if [ -f "$COMPRESSED_FILE" ]; then
    rm -f "$COMPRESSED_FILE"
fi

# Make the logs directory if it does not exist
mkdir -p "$LOGS_DIR"

# Prompt the user for the URL/IP and port for the curl commands
read -p "Enter the IP address and port for the curl commands (default: 127.0.0.1:35997): " CURL_ENDPOINT

# Set default value if the user presses enter
if [ -z "$CURL_ENDPOINT" ]; then
    CURL_ENDPOINT="127.0.0.1:35997"
fi

# Check if the user included 'http://' or 'https://' at the beginning
if [[ "$CURL_ENDPOINT" =~ ^https?:// ]]; then
    CURL_URL="$CURL_ENDPOINT"
else
    CURL_URL="http://$CURL_ENDPOINT"
fi

# Function to decrypt .env.gpg file and load environment variables
function load_env_variables() {
    if [ -f .env.gpg ]; then
        echo "Please enter the password to decrypt the .env file:"
        decrypted_env=$(gpg --quiet --decrypt .env.gpg 2>/dev/null)
        if [ $? -eq 0 ]; then
            # Export the variables
            export $(echo "$decrypted_env" | xargs)
        else
            echo "Failed to decrypt .env file. Exiting."
            exit 1
        fi
    else
        echo "Encrypted .env.gpg file not found. Skipping sending report to Telegram."
    fi
}

# Load environment variables from encrypted .env.gpg file
load_env_variables

# Redirect all output to both console and the output file
exec > >(tee -a "$OUTPUT_FILE") 2> >(tee -a "$OUTPUT_FILE" >&2)

# Function to add separator and label
function add_section() {
    echo ""
    echo "========== $1 =========="
    echo ""
}

# Function to check if a command exists
function command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect package manager
function detect_package_manager() {
    if command_exists apt-get; then
        echo "apt"
    elif command_exists yum; then
        echo "yum"
    elif command_exists dnf; then
        echo "dnf"
    else
        echo ""
    fi
}

# List of required commands and their corresponding packages
declare -A required_commands=(
    ["netstat"]="net-tools"
    ["ss"]="iproute2"
    ["jq"]="jq"
    ["lsb_release"]="lsb-release"
    ["curl"]="curl"
    ["journalctl"]="systemd"  # journalctl is part of systemd
    ["gpg"]="gnupg"
)

# Check and install missing commands
missing_packages=()

echo "Checking for required commands and installing missing packages..."

for cmd in "${!required_commands[@]}"; do
    if ! command_exists "$cmd"; then
        missing_packages+=("${required_commands[$cmd]}")
    fi
done

if [ ${#missing_packages[@]} -ne 0 ]; then
    echo "The following packages are missing: ${missing_packages[*]}"
    package_manager=$(detect_package_manager)
    if [ -n "$package_manager" ]; then
        echo "Detected package manager: $package_manager"
        read -p "Do you want to install the missing packages? [y/N]: " install_packages
        if [[ "$install_packages" =~ ^[Yy]$ ]]; then
            if [ "$package_manager" = "apt" ]; then
                sudo apt-get update
                sudo apt-get install -y "${missing_packages[@]}"
            elif [ "$package_manager" = "yum" ]; then
                sudo yum install -y "${missing_packages[@]}"
            elif [ "$package_manager" = "dnf" ]; then
                sudo dnf install -y "${missing_packages[@]}"
            fi
        else
            echo "Cannot proceed without installing the required packages. Exiting."
            exit 1
        fi
    else
        echo "Could not detect package manager. Please install the missing packages manually."
        exit 1
    fi
else
    echo "All required commands are available."
fi

add_section "Zenon Validator Troubleshooting Script"

add_section "1. Checking Linux Version"
lsb_release -a 2>/dev/null || cat /etc/*release
uname -a

add_section "2. Checking Open Ports (35995, 35997, 35998)"
echo "Using ss or netstat command:"
if command_exists ss; then
    sudo ss -tulpn | grep -E ':(35995|35997|35998)'
elif command_exists netstat; then
    sudo netstat -tulpn | grep -E ':(35995|35997|35998)'
else
    echo "Neither ss nor netstat commands are available."
fi

add_section "3. Checking Running Services"
systemctl list-units --type=service --state=running

add_section "4. Checking UFW Status"
sudo ufw status verbose

add_section "5. Checking Disk Usage"
df -h

add_section "6. Checking if go-zenon service is running"
if systemctl is-active --quiet go-zenon.service; then
    echo "go-zenon.service is running."
else
    echo "go-zenon.service is NOT running."
fi

add_section "7. Printing last 100 log lines for go-zenon service"
sudo journalctl -u go-zenon.service -n 100

add_section "8. Executing stats Commands to Check Zenon Node Status"

# Function to execute curl commands with timeout
function execute_curl() {
    local method=$1
    echo ""
    echo "8.${counter}. ${method}:"
    response=$(curl -s --max-time 10 -X POST "$CURL_URL" \
         -H 'Content-Type: application/json' \
         -d "{\"jsonrpc\": \"2.0\", \"id\": 40, \"method\": \"${method}\", \"params\": []}")
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        if echo "$response" | jq . >/dev/null 2>&1; then
            echo "$response" | jq .
        else
            echo "Error: Invalid JSON response from ${method}."
            echo "Response: $response"
        fi
    else
        echo "Error: Failed to get response from ${method}. The request timed out or failed."
    fi
    counter=$((counter+1))
}

counter=1
execute_curl "stats.syncInfo"
execute_curl "stats.processInfo"
execute_curl "stats.networkInfo"

add_section "9. Reporting Last 'Momentum' Entry from go-zenon Service Logs"

# Search for the last 'Momentum' entry in journalctl logs
if command_exists journalctl; then
    echo "Searching for the last 'Momentum' entry in go-zenon service logs..."
    momentum_entry=$(sudo journalctl -u go-zenon --no-pager | grep 'Momentum' | tail -n 1)
    if [ -n "$momentum_entry" ]; then
        echo "Last 'Momentum' log entry from go-zenon service:"
        echo "$momentum_entry"
    else
        echo "No 'Momentum' entries found in go-zenon service logs."
    fi
else
    echo "journalctl command not found. Cannot search service logs."
fi

# Save troubleshoot_zenon.txt to logs directory
cp "$OUTPUT_FILE" "$LOGS_DIR/"

# Copy log files to logs directory
LOG_FILES=(
    "/root/.znn/log/zenon.log"
    "/root/.znn/log/error/zenon.error.log"
)

for log_file in "${LOG_FILES[@]}"; do
    if [ -f "$log_file" ]; then
        cp "$log_file" "$LOGS_DIR/"
    else
        echo "Log file not found: $log_file"
    fi
done

# Compress the files in the logs directory into troubleshoot_zenon.txt.gz
cd "$LOGS_DIR"
tar -czf troubleshoot_zenon.txt.gz troubleshoot_zenon.txt zenon.log zenon.error.log

# Delete the 3 files after compression
rm -f troubleshoot_zenon.txt zenon.log zenon.error.log

cd "$SCRIPT_DIR"

if [ -f "$COMPRESSED_FILE" ]; then
    echo "Troubleshooting data collected and compressed to $COMPRESSED_FILE"
else
    echo "Error: Failed to create compressed file."
fi

# Send the compressed file to Telegram (if API keys are set)
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    echo "Sending compressed report to Telegram..."
    response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
         -F chat_id="$TELEGRAM_CHAT_ID" \
         -F document=@"$COMPRESSED_FILE" \
         -F caption="Zenon Validator Troubleshooting Report")
    if echo "$response" | grep -q '"ok":true'; then
        echo "Report sent to Telegram successfully."
        # Clean up only if the upload was successful
        rm -f "$COMPRESSED_FILE"
        echo "Temporary files have been cleaned up."
    else
        echo "Failed to send report to Telegram. Response:"
        echo "$response"
        echo "The compressed file is available at $COMPRESSED_FILE"
    fi
else
    echo "Telegram API keys not set or incomplete. Skipping sending report to Telegram."
    echo "The troubleshooting report is available at $COMPRESSED_FILE"
fi

echo ""
echo "========== End of Troubleshooting Script =========="

# Unset sensitive environment variables
unset TELEGRAM_BOT_TOKEN
unset TELEGRAM_CHAT_ID
