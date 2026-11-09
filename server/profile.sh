# Login shells reset PATH in /etc/profile, so the paths of the image are added back here.
# The mise shims pick the version of the project in shells without the mise hook, such as bash -lc of agents.
for dir in /opt/node/bin /home/dev/.local/share/mise/shims /home/dev/.local/bin; do
  case ":$PATH:" in *":$dir:"*) ;; *) PATH="$dir:$PATH" ;; esac
done
export PATH
