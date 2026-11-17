# bugs-vault setup

The installer for a private, invitation-only service.  It is no use
without an account: Patrick Farrell sends each person a setup note with
their user name and the connection details this script needs.  If you
did not get one, there is nothing here for you.

`install.sh` sets up, for one user and with no root:

- an SSH tunnel (a systemd user unit on Linux, a launchd agent on macOS)
  to a forward-only account on the service, carried by
  [pigeons](https://github.com/n0-computer/pigeons) so it works from
  any network, with the service's host key pinned;
- the `bugs-vault` command line tool and its agent skill, fetched through
  that tunnel and checked against the service's manifest, after which
  the script replaces itself with the service's own copy.

It touches only `~/.local/share/bugs-vault`, `~/.local/bin`,
`~/.config/bugs-vault`, one marked block at the top of `~/.ssh/config`,
the tunnel service and skill links in `~/.claude` and `~/.codex`.  It
never creates, changes or sends a private key.

```bash
bash install.sh --help
bash install.sh --check
bash install.sh --uninstall
```

Exit status: 0 ready; 2 bad usage or a missing prerequisite; 3 the
service does not accept the key yet; 4 the tunnel or the service is not
answering, or its host key does not match (stop and tell Patrick); 5 the
tunnel works but the command line login fails.

Linux (WSL included) and macOS, with `ssh`, `curl`, `tar` and Python 3.10
or newer with `venv`.
