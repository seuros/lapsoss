# lapsossd

The platform gem packages the standalone Rust `lapsossd` executable. It has no
native extension and never compiles or downloads code during installation.
Ruby only launches the executable; the daemon itself does not embed Ruby.

Run in the foreground under systemd, Docker, or your process supervisor:

```sh
lapsossd --config /etc/lapsossd.json
```

Build on each target host with `bundle exec rake daemon:build` from the repository
root. Never relabel an executable built for a different OS or architecture.
Publishing is manual: `gem push pkg/lapsossd-0.1.0-<platform>.gem`.

See [the daemon guide](https://github.com/seuros/lapsoss/blob/master/docs/daemon.md)
for configuration, filtering semantics, protocol, and operational limitations.
