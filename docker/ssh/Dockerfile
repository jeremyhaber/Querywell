FROM alpine:3.20
RUN apk add --no-cache openssh netcat-openbsd \
 && ssh-keygen -A \
 && adduser -D -s /bin/sh querywell \
 && echo 'querywell:querywell_ssh_pw' | chpasswd
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
