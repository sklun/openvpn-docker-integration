FROM alpine:3.18

RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories \
    && apk add --no-cache \
        bash \
        curl \
        easy-rsa \
        iproute2 \
        ipset \
        iptables \
        jq \
        libqrencode \
        logrotate \
        openvpn \
        openvpn-auth-ldap \
        openvpn-auth-pam \
        pamtester \
        google-authenticator \
        tzdata \
        ulogd \
        util-linux \
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    && ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa

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
