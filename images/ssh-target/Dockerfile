FROM alpine:3.22@sha256:3e9b4b680bfc9fb5269227cffbd6d42be39fbf7c0b908123913864aa4447e764

RUN apk add --no-cache openssh-server openssh-sftp-server python3 \
    && adduser -D -s /bin/sh foreman \
    && install -d -m 0755 /run/sshd \
    && printf '%s\n' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      'AllowUsers foreman' \
      'PidFile /tmp/sshd.pid' \
      >> /etc/ssh/sshd_config

COPY --chmod=0755 images/ssh-target/entrypoint.sh /usr/local/bin/ssh-target-entrypoint

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/ssh-target-entrypoint"]
