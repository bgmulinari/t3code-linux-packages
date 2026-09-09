# Building packages

The GitHub workflow uses the same core toolchain family as upstream T3 Code releases:

- Native Ubuntu 24.04 x86-64 or ARM64
- Vite+ and the Node.js version declared by the selected upstream tag
- Rust with `x86_64-unknown-linux-gnu` or `aarch64-unknown-linux-gnu`
- ImageMagick
- `libsecret-1-dev` and `pkg-config` to compile upstream's browser secret helper
- `libcrypt.so.1` compatibility required by Electron Builder's bundled FPM Ruby
- RPM and Debian packaging tools

An x86-64 local build looks like:

```bash
scripts/build-upstream-packages.sh \
  --source /path/to/t3code \
  --patch patches/t3code-native-packaging.patch \
  --output out \
  --version 0.0.33 \
  --arch x64 \
  --commit FULL_40_CHARACTER_UPSTREAM_COMMIT
```

On an ARM64 host, use `--arch arm64`. The automated workflow maps the architecture to the
appropriate native runner and Rust target; it does not emulate or cross-compile the desktop
application.

The script copies upstream's public `.env.example` configuration into the temporary checkout so the
resulting source build has the same public T3 Connect identifiers as official releases. It also pins
the desktop update repository to `pingdotgg/t3code`. Native packages remain package-manager updated
because T3 Code disables the AppImage updater when `APPIMAGE` is absent.

The packaging patch asks Electron Builder to emit Debian and RPM packages in
one invocation, avoiding a second desktop application build for the other package format. It also
copies T3 Code's upstream MIT license into every generated package.
