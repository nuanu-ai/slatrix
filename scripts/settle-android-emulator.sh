#!/bin/sh
# The emulator runner presses Menu the moment the device boots. On a cold emulator the launcher has no focused
# window yet, so input dispatch times out and an "isn't responding" dialog opens a few seconds later, over
# whatever the device tests show. Stop new error dialogs, close one already on its way, and wait for the launcher.
adb shell settings put global hide_error_dialogs 1
settled=0
for _ in $(seq 90); do
  focus=$(adb shell dumpsys window | grep -m1 mCurrentFocus)
  case $focus in
    *"Application Not Responding"*)
      echo "Closing $focus"
      adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null
      settled=0 ;;
    *launcher*)
      settled=$((settled + 1))
      [ "$settled" -ge 5 ] && exit 0 ;;
    *) settled=0 ;;
  esac
  sleep 1
done
echo "The emulator never settled on the launcher: $focus" >&2
exit 1
