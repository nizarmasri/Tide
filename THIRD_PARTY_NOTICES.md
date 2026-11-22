# Third-party software

The Tide app bundle includes the following software. Each keeps its own license.

| Component | Version | License | Source |
|---|---|---|---|
| aria2 | 1.37.0 | GPL-2.0-or-later (with OpenSSL exception) | https://github.com/aria2/aria2 |
| OpenSSL (libssl, libcrypto) | 3.x | Apache-2.0 | https://github.com/openssl/openssl |
| libssh2 | 1.x | BSD-3-Clause | https://github.com/libssh2/libssh2 |
| c-ares | 1.x | MIT | https://github.com/c-ares/c-ares |
| SQLite | 3.x | Public domain | https://sqlite.org |
| GNU gettext (libintl) | 0.2x | LGPL-2.1-or-later | https://www.gnu.org/software/gettext/ |

aria2 runs as a separate program inside the app (`Tide.app/Contents/Helpers/aria2c`), with its libraries in `Tide.app/Contents/Frameworks`. They're unmodified Homebrew builds. You can get the source code for each from the links above, or open an issue and I'll send it to you.
