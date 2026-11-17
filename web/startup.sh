#!/bin/sh
# Writes runtime config for the page, then serves the static files
printf 'window.API_BASE_URL = "%s";\n' "$API_BASE_URL" > /home/site/wwwroot/config.js
exec pm2 serve /home/site/wwwroot --no-daemon