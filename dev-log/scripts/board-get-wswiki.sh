#!/bin/sh
# Runs ON the UNO Q. Stdin secrets contract: 1. sudo password  2. SSID  3. wifi pw
# Fetch the Waveshare wiki page for our exact panel and extract the hardware facts.
unset HISTFILE
IFS= read -r SUDO_PASS; IFS= read -r WIFI_SSID; IFS= read -r WIFI_PASS

cd /tmp || exit 1
UA="Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

echo "=== fetching wiki ==="
curl -fsSL --max-time 60 -A "$UA" -H "Accept-Language: en" \
    "https://www.waveshare.com/wiki/5inch_DSI_LCD" -o ws.html 2>&1 \
    && echo "OK ($(stat -c%s ws.html) bytes)" || { echo "fetch FAILED"; exit 1; }

echo
echo "=== stripped text ==="
# crude html -> text
sed -e 's/<script[^>]*>.*<\/script>//g' \
    -e 's/<style[^>]*>.*<\/style>//g' \
    -e 's/<[^>]*>/ /g' ws.html \
  | sed -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' \
  | tr -s ' \t' ' ' | grep -v '^ *$' > ws.txt
wc -l ws.txt

echo
echo "=== specifications / power ==="
grep -n -i -B3 -A6 "power\|voltage\|consumption\|current\|5V\|3.3V\|supply" ws.txt | head -60

echo
echo "=== interface / connector / pin ==="
grep -n -i -B2 -A6 "pin\|connector\|FPC\|FFC\|cable\|interface" ws.txt | head -60

echo
echo "=== resolution / lanes / driver chip ==="
grep -n -i -B2 -A4 "resolution\|lane\|driver\|controller\|IC\|touch" ws.txt | head -50

echo
echo "=== raspberry pi model compatibility / how to connect ==="
grep -n -i -B2 -A8 "Pi 5\|Pi5\|22-pin\|15-pin\|DSI1\|DSI0\|connect" ws.txt | head -60
