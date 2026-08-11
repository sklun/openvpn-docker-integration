# FROM alpine:3.18
FROM alpine

RUN apk add --no-cache \
        bash \
        curl \
        easy-rsa \
        iproute2 \
        ipset \
        iptables \
        jq \
        libqrencode-tools \
        logrotate \
        openvpn \
        openvpn-auth-ldap \
        openvpn-auth-pam \
        google-authenticator \
        tzdata \
        ulogd \
        util-linux \
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    && ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa \
    && for command in \
        iptables iptables-save iptables-restore \
        ip6tables ip6tables-save ip6tables-restore; do \
        ln -sf xtables-nft-multi "/usr/sbin/${command}"; \
    done

ENV OPENVPN=/etc/openvpn \
    EASYRSA=/usr/share/easy-rsa \
    EASYRSA_CRL_DAYS=3650 \
    EASYRSA_CERT_EXPIRE=3650 \
    EASYRSA_PKI=/etc/openvpn/pki

VOLUME ["/etc/openvpn"]
EXPOSE 1194/udp

COPY bin/ /usr/local/bin/
COPY otp/openvpn /etc/pam.d/openvpn

RUN chmod a+x /usr/local/bin/*

CMD ["ovpn_run"]
