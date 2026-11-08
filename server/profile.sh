# Login shells reset PATH in /etc/profile, so the paths of the image are added back here.
for dir in /opt/node/bin /home/dev/.local/bin; do
  case ":$PATH:" in *":$dir:"*) ;; *) PATH="$dir:$PATH" ;; esac
done
export PATH
