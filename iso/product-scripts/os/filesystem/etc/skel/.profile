# ~/.profile: executed by the command interpreter for login shells.
# This file is not read by bash(1), if ~/.bash_profile or ~/.bash_login
# exists.
# see /usr/share/doc/bash/examples/startup-files for examples.
# the files are located in the bash-doc package.

# the default umask is set in /etc/profile; for setting the umask
# for ssh logins, install and configure the libpam-umask package.
#umask 022

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
	. "$HOME/.bashrc"
    fi
fi

# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi

# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi

if [ -x /opt/ssmt/bin/pinapps.sh -a .done.mt.pinapps -ot /opt/ssmt/bin/pinapps.sh ]; then
    touch .done.mt.pinapps
    /opt/ssmt/bin/pinapps.sh
fi

if [ -x /opt/ssxm/pinapps.sh -a .done.xm.pinapps -ot /opt/ssxm/pinapps.sh ]; then
    touch .done.xm.pinapps
    /opt/ssxm/pinapps.sh
fi

if [ -n ${DISPLAY} ]
then
    if [[ $DISPLAY =~ ^: ]]
    then
	echo ${DISPLAY} > ".DISPLAY"
    fi 
fi

if [ ! -e .done.login ]; then
    # Set the desktop background.
    gsettings set org.gnome.desktop.background picture-options 'zoom'
    gsettings set org.gnome.desktop.background picture-uri "file:///usr/share/backgrounds/triveni/PHTO_StreamScope_MT_16x9.png"

    # Disable screensaver and screen lock.
    gsettings set org.gnome.desktop.screensaver lock-enabled false
    gsettings set org.gnome.desktop.session idle-delay 0

    #set chrome as the default browser with localhost the default page
    if [ -e /usr/share/applications/google-chrome.desktop ]
    then
        xdg-settings set default-web-browser google-chrome.desktop

        mkdir -p ~/.config/google-chrome/Default
        cp /etc/skel/.config/google-chrome/Default/Preferences ~/.config/google-chrome/Default
#        # Set startup behavior to "Open a specific page or set of pages" (type 4)
#        jq '.session.restore_on_startup = 4' ~/.config/google-chrome/Default/Preferences > tmp.json && mv tmp.json ~/.config/google-chrome/Default/Preferences
#        # Define the startup URL(s)
#        jq '.session.startup_urls = ["http://127.0.0.1"]' ~/.config/google-chrome/Default/Preferences > tmp.json && mv tmp.json ~/.config/google-chrome/Default/Preferences
    fi

    # reset the shell so it doesn't keep popping up the search when logging in
    dconf reset -f /org/gnome/shell

    # Force default dock favorites for first login and keep Firefox unpinned.
    # gsettings set org.gnome.shell favorite-apps "['google-chrome.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'snap-store_snap-store.desktop']"
    gsettings set org.gnome.shell favorite-apps "['google-chrome.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']"

    # Re-apply app-specific favorites after shell reset/default favorites.
    if [ -x /opt/ssmt/bin/pinapps.sh ]; then
        /opt/ssmt/bin/pinapps.sh
    fi

    if [ -x /opt/ssxm/pinapps.sh ]; then
        /opt/ssxm/pinapps.sh
    fi

    touch .done.login
fi
