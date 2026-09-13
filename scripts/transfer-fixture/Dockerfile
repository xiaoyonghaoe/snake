FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server openssl perl fish zsh && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /run/sshd /fixture-bin/md5 /fixture-bin/none && \
    for user in sha md5 none restricted corrupt fish zsh probeerror hasherror; do useradd -m -s /bin/sh "$user"; echo "$user:snake-fixture-only" | chpasswd; ln -s ../missing /home/$user/fixture-link; done && \
    usermod -s /usr/bin/fish fish && usermod -s /usr/bin/zsh zsh && \
    for tool in cat mv rm; do ln -s /usr/bin/$tool /fixture-bin/md5/$tool; ln -s /usr/bin/$tool /fixture-bin/none/$tool; done && \
    ln -s /usr/bin/md5sum /fixture-bin/md5/md5sum
COPY sshd_config /etc/ssh/sshd_config
COPY command.sh /fixture-command
RUN chmod 755 /fixture-command
EXPOSE 22
CMD ["/bin/sh", "-c", "ssh-keygen -A && exec /usr/sbin/sshd -D -e"]
