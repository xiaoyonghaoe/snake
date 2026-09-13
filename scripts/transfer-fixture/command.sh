#!/bin/sh
# Disposable fixture accounts only. No production credentials or configuration.
case "$SSH_ORIGINAL_COMMAND" in
    internal-sftp*|sftp*|/usr/lib/openssh/sftp-server*) exec /usr/lib/openssh/sftp-server ;;
esac
case "$USER" in
    md5) export PATH=/fixture-bin/md5 ;;
    none) export PATH=/fixture-bin/none ;;
    restricted) echo 'This service allows sftp connections only.'; exit 1 ;;
    corrupt)
        case "$SSH_ORIGINAL_COMMAND" in
            "/bin/sh -c 'sha256sum < "*) echo '0000000000000000000000000000000000000000000000000000000000000000  -'; exit 0 ;;
        esac ;;
    probeerror)
        case "$SSH_ORIGINAL_COMMAND" in
            *"if command -v sha256sum"*) echo 'fixture: unexpected probe output'; exit 2 ;;
        esac ;;
    hasherror)
        case "$SSH_ORIGINAL_COMMAND" in
            "/bin/sh -c 'sha256sum < "*) echo 'fixture: checksum failed' >&2; exit 1 ;;
        esac ;;
esac
exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
