#!/bin/bash
clear

CYAN='\033[0;36m'
PURPLE='\033[1;35m'
GREEN='\033[1;32m'
GRAY='\033[1;30m'
NC='\033[0m'


echo -e "${PURPLE}"
cat << 'EOF'
 _   _ _____ _____ ____   ___  _   _ _   _  ____ _____ ____  
| \ | | ____|_   _| __ ) / _ \| | | | \ | |/ ___| ____|  _ \ 
|  \| |  _|   | | |  _ \| | | | | | |  \| | |   |  _| | |_) |
| |\  | |___  | | | |_) | |_| | |_| | |\  | |___| |___|  _ < 
|_| \_|_____| |_| |____/ \___/ \___/|_| \_|\____|_____|_| \_\                                                                
EOF

# Extract IPs using root
LOCAL_IP=$(su -c "ip -4 addr show wlan0 2>/dev/null" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "OFFLINE")
TUNNEL_IP=$(su -c "ip -4 addr show tailscale0 2>/dev/null" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "DOWN")

# Optimization: Call the API only once to avoid slowing down terminal startup
BAT_JSON=$(termux-battery-status 2>/dev/null)
BATTERY=$(echo "$BAT_JSON" | grep -oP '(?<="percentage": )\d+' || echo "N/A")
CPU_TEMP=$(echo "$BAT_JSON" | grep -oP '(?<="temperature": )[\d.]+' || echo "N/A")
CHARGE_RAW=$(echo "$BAT_JSON" | grep -oP '(?<="status": ")[^"]+' || echo "UNKNOWN")

# Format power state
if [ "$CHARGE_RAW" == "CHARGING" ] || [ "$CHARGE_RAW" == "FULL" ]; then
    PWR_STATE="${GREEN}PLUGGED${NC}"
else
    PWR_STATE="${GRAY}BATTERY${NC}"
fi

# Format temperature
if [ "$CPU_TEMP" != "N/A" ]; then
    TEMP_STATUS="${CYAN}${CPU_TEMP}°C${NC}"
else
    TEMP_STATUS="${GRAY}N/A${NC}"
fi

UPTIME=$(uptime -p | cut -d' ' -f2-)

# Read IP Forwarding state using root
FWD_STATE=$(su -c "cat /proc/sys/net/ipv4/ip_forward 2>/dev/null")
if [ "$FWD_STATE" == "1" ]; then
    ROUTING_STATUS="${GREEN}ACTIVE${NC}"
else
    ROUTING_STATUS="${GRAY}DISABLED${NC}"
fi

echo -e "${PURPLE}============================================================${NC}"
echo -e "${GREEN} [+]${NC} Uptime         	   : ${UPTIME}"
echo -e "${GREEN} [+]${NC} Hardware Core         : Bat: ${CYAN}${BATTERY}%${NC} [${PWR_STATE}] | Temp: ${TEMP_STATUS}"
echo -e "${GREEN} [+]${NC} IP Forwarding         : ${ROUTING_STATUS}"
echo -e "${GREEN} [+]${NC} Local IP (wlan0)      : ${CYAN}${LOCAL_IP}${NC}"
echo -e "${GREEN} [+]${NC} Tunnel IP (tailscale0): ${CYAN}${TUNNEL_IP}${NC}"
echo -e "${PURPLE}============================================================${NC}"
echo -e "${CYAN} Quick Commands Reference:${NC}"
echo -e " ${GREEN}su${NC}                    - Switch to root (super user)"
echo -e " ${GREEN}pkg install <pkg>${NC}     - Install a new Termux package"
echo -e " ${GREEN}pkg update${NC}            - Update installed packages list"
echo -e " ${GREEN}htop${NC}                  - Monitor system processes & RAM"
echo -e " ${GREEN}proot-distro login ubuntu${NC} - Enter the Pi-hole environment"
echo -e "${PURPLE}============================================================${NC}"