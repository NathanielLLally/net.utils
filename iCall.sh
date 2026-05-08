#!/bin/sh
#
#   check the system default audio devices
#
#  right now setup as it is generated feedback when using the iphone for calls.
#  didn't test desktop
#
#


PID=`pidof easyeffects` 
if [ -n "$PID" ];  then
  kill -9 $PID
fi

systemctl --user stop pipewire pipewire-pulse pipewire-media-session pipewire.socket pipewire-pulse.socket
systemctl --user status pipewire pipewire-pulse pipewire-media-session pipewire.socket pipewire-pulse.socket | grep loaded

N=2
echo "\n\n***waiting $N seconds \n\n"
sleep $N

systemctl --user start pipewire
systemctl --user start pipewire-pulse
systemctl --user start pipewire-media-session 

systemctl --user status pipewire pipewire-pulse pipewire-media-session pipewire.socket pipewire-pulse.socket | grep loaded

PID=`ps -e | grep blueman-manager` 
if [ -z "$PID" ];  then
  /usr/bin/python3 -sPE /usr/bin/blueman-manager &
fi

PID=`pidof qjackctl` 
if [ -z "$PID" ];  then
  /usr/bin/qjackctl &
  sleep 1
  /usr/bin/qjackctl --start 
  /usr/bin/qjackctl --active-patchbay /home/nathaniel/etc/patchbay_iCall.xml 
fi

PID=`pidof easyeffects` 
if [ -z "$PID" ];  then
  /usr/bin/easyeffects &
  sleep 5
fi

PID=`pidof audacity` 
if [ -z "$PID" ];  then
  /usr/bin/audacity &
fi

sleep 5
echo "blutetoothctl power on"
/usr/bin/bluetoothctl power on
echo "connecting to iPhone via bluetooth"
/usr/bin/bluetoothctl connect 78:64:C0:2B:BB:96
