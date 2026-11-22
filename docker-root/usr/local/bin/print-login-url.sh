#!/bin/bash
# External browser of openconnect (--external-browser), for gateways that ask for single sign-on in an external
# browser. Once openconnect listens for the browser's callback on [::1]:29786, it runs this program with the login
# URL as its only argument and its own output, the login terminal (spawn_browser in main.c and
# handle_external_browser in hpke.c of openconnect 9.01). The image has no browser, so this prints the URL in the
# terminal and in docker logs; the user opens it in a browser of their own. After the login, that browser opens
# http://localhost:29786/api/sso/..., which must reach the port 29786 that the container publishes.

url=$1
printf '\nOpen this URL in your browser to log in:\n\n%s\n\n' "$url"
echo "After the login, the browser opens http://localhost:29786/, which must reach port 29786 of this container."
echo
# The output of PID 1, the entrypoint, is what docker logs shows; the prefix is the login terminal's in start.sh
echo "[openconnect] open this URL in your browser to log in: $url" >/proc/1/fd/1
