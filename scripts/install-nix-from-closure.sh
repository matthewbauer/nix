#!/bin/sh

set -e

dest="/nix"
self="$(dirname "$0")"
nix="@nix@"
cacert="@cacert@"

if ! [ -e $self/.reginfo ]; then
    echo "$0: incomplete installer (.reginfo is missing)" >&2
    exit 1
fi

if [ -z "$USER" ]; then
    echo "$0: \$USER is not set" >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "performing a multi-user installation of Nix..." >&2

    group=nixbld

    echo "trying to add users"

    if command -v dseditgroup >/dev/null 2>&1; then
        echo "Creating $group group"
        dseditgroup -q -o create $group

        gid=$(dscl -q . read /Groups/$group | awk '($1 == "PrimaryGroupID:") {print $2 }')

        echo "Create $group users"
        for i in $(seq 1 10); do
            user=/Users/$group$i
            uid="$((30000 + $i))"

            dscl -q . create $user
            dscl -q . create $user RealName "Nix build user $i"
            dscl -q . create $user PrimaryGroupID $gid
            dscl -q . create $user UserShell /usr/bin/false
            dscl -q . create $user NFSHomeDirectory /var/empty
            dscl -q . create $user UniqueID $uid

            dscl . -append /Groups/$group GroupMembership $group$i

            dseditgroup -q -o edit -a $group$i -t user $group
        done

    elif command -v groupadd >/dev/null 2>&1; then

        groupadd -r $group
        for n in $(seq 1 10); do
            useradd -c "Nix build user $n" \
                    -d /var/empty -g nixbld -G nixbld -M -N -r -s "$(which nologin)" \
                    $group$n
        done

    else

        echo "Cannot setup nixbld group/users." >&2
        exit 1

    fi

    mkdir -m 0755 $dest
    chown -R root:$group $dest

    mkdir -p /etc/nix
    echo "Adding build-users-group to /etc/nix/nix.conf."
    echo "build-users-group = $group # added by installer" >> /etc/nix/nix.conf

else
    echo "performing a single-user installation of Nix..." >&2

    if ! [ -e $dest ]; then
        cmd="mkdir -m 0755 $dest && chown $USER $dest"
        echo "directory $dest does not exist; creating it by running '$cmd' using sudo" >&2
        if ! sudo sh -c "$cmd"; then
            echo "$0: please manually run ‘$cmd’ as root to create $dest" >&2
            exit 1
        fi
    fi
fi

if ! [ -w $dest ]; then
    echo "$0: directory $dest exists, but is not writable by you. This could indicate that another user has already performed a single-user installation of Nix on this system. If you wish to enable multi-user support see http://nixos.org/nix/manual/#ssec-multi-user. If you wish to continue with a single-user install for $USER please run ‘chown -R $USER $dest’ as root." >&2
    exit 1
fi

if command -v chflags >/dev/null 2>&1; then
    echo "Hiding $dest directory."
    # just automatically set hidden
    chflags hidden $dest
fi

mkdir -p $dest/store

echo -n "copying Nix to $dest/store..." >&2

for i in $(cd $self/store >/dev/null && echo *); do
    echo -n "." >&2
    i_tmp="$dest/store/$i.$$"
    if [ -e "$i_tmp" ]; then
        rm -rf "$i_tmp"
    fi
    if ! [ -e "$dest/store/$i" ]; then
        cp -Rp "$self/store/$i" "$i_tmp"
        chmod -R a-w "$i_tmp"
        chmod +w "$i_tmp"
        mv "$i_tmp" "$dest/store/$i"
        chmod -w "$dest/store/$i"
    fi
done
echo "" >&2

echo "initialising Nix database..." >&2
if ! $nix/bin/nix-store --init; then
    echo "$0: failed to initialize the Nix database" >&2
    exit 1
fi

if ! $nix/bin/nix-store --load-db < $self/.reginfo; then
    echo "$0: unable to register valid paths" >&2
    exit 1
fi

. $nix/etc/profile.d/nix.sh

if ! $nix/bin/nix-env -i "$nix"; then
    echo "$0: unable to install Nix into your default profile" >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    if [ -d /Library/LaunchDaemons ]; then
        echo "Installing org.nixos.nix-daemon.plist in /Library/LaunchDaemons."
        ln -fs $nix/Library/LaunchDaemons/org.nixos.nix-daemon.plist /Library/LaunchDaemons/

        echo "Starting nix-daemon."
        launchctl load -F /Library/LaunchDaemons/org.nixos.nix-daemon.plist
        launchctl start org.nixos.nix-daemon
    elif [ -d /etc/systemd/system ]; then
        echo "Installing in /etc/systemd/system."
        ln -fs $nix/lib/nix-daemon.service /etc/systemd/system
        ln -fs $nix/lib/nix-daemon.socket /etc/systemd/system

        echo "Starting nix-daemon."
        systemctl enable nix-daemon
        systemctl start nix-daemon
    fi

    if [ -d /etc/paths.d ]; then
        echo "Adding /etc/paths.d/nix."
        echo $dest/var/nix/profiles/default/bin > /etc/paths.d/nix
    fi
fi

# Install an SSL certificate bundle.
if [ -z "$NIX_SSL_CERT_FILE" -o ! -f "$NIX_SSL_CERT_FILE" ]; then
    $nix/bin/nix-env -i "$cacert"
    export NIX_SSL_CERT_FILE="$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt"
fi

# Subscribe the user to the Nixpkgs channel and fetch it.
if ! $nix/bin/nix-channel --list | grep -q "^nixpkgs "; then
    $nix/bin/nix-channel --add https://nixos.org/channels/nixpkgs-unstable
fi
if [ -z "$_NIX_INSTALLER_TEST" ]; then
    $nix/bin/nix-channel --update nixpkgs
fi

added=
if [ -z "$NIX_INSTALLER_NO_MODIFY_PROFILE" ]; then

    if [ "$(id -u)" -eq 0 ]; then

        # Make the shell source nix.sh during login.
        p=/nix/var/profiles/default/etc/profile.d/nix.sh

        for i in bashrc profile; do
            fn="/etc/$i"
            if [ -w "$fn" ]; then
                if ! grep -q "$p" "$fn"; then
                    echo "modifying $fn..." >&2
                    echo "if [ -e $p ]; then . $p; fi # added by Nix installer" >> $fn
                fi
                added=1
                break
            fi
        done
    else
        # Make the shell source nix.sh during login.
        p=$HOME/.nix-profile/etc/profile.d/nix.sh

        for i in .bash_profile .bash_login .profile; do
            fn="$HOME/$i"
            if [ -w "$fn" ]; then
                if ! grep -q "$p" "$fn"; then
                    echo "modifying $fn..." >&2
                    echo "if [ -e $p ]; then . $p; fi # added by Nix installer" >> $fn
                fi
                added=1
                break
            fi
        done
    fi
fi

if [ -z "$added" ]; then
    cat >&2 <<EOF

Installation finished!  To ensure that the necessary environment
variables are set, please add the line

  . $p

to your shell profile (e.g. ~/.profile).
EOF
else
    cat >&2 <<EOF

Installation finished!  To ensure that the necessary environment
variables are set, either log in again, or type

  . $p

in your shell.
EOF
fi
