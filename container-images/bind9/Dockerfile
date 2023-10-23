FROM docker.io/ubuntu/bind9:9.18-22.04_beta
COPY ./named.conf /etc/bind/named.conf
COPY ./cdgnet-org.zone /etc/bind/cdgnet-org.zone
EXPOSE 53

LABEL maintainer="Filip Ruzicka" \
      image="pirateofthecerulean/bind9-cdg-homelab"
