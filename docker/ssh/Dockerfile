FROM alpine:3.20
# mysql-client = MariaDB client (mysqldump/mariadb-dump); connector-c carries caching_sha2_password for MySQL 8.
# postgresql16-client + gzip: remote export tests run mysqldump/pg_dump | gzip on the bastion.
RUN apk add --no-cache openssh netcat-openbsd mysql-client mariadb-connector-c postgresql16-client gzip procps \
 && ssh-keygen -A \
 && adduser -D -s /bin/sh querywell \
 && echo 'querywell:querywell_ssh_pw' | chpasswd
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
