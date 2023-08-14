#!/bin/bash

## Generate a self-signed template cert with empty Subject field
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
-keyout "sinkhole.key" \
-out "sinkhole.crt" \
-subj "/" \
-config <(printf "[req]\n
distinguished_name=dn\n
x509_extensions=v3_req\n
[dn]\n\n
[v3_req]\n
keyUsage=critical,digitalSignature,keyEncipherment\n
extendedKeyUsage=serverAuth,clientAuth") > /dev/null 2>&1

## Create the sinkhole internal iRule
tmsh create ltm rule sinkhole-rule when HTTP_REQUEST { HTTP::respond 200 content "Access Denied\!" "connection" "close" } > /dev/null 2>&1

## Create the BIG-IP certificate/key, client SSL profile, and internal sinkhole virtual server
(echo create cli transaction
echo install sys crypto key sinkhole from-local-file "$(pwd)/sinkhole.key"
echo install sys crypto cert sinkhole from-local-file "$(pwd)/sinkhole.crt"
echo create ltm profile client-ssl sinkhole-clientssl cert sinkhole key sinkhole
echo create ltm virtual sinkhole-vip destination 0.0.0.0:9999 profiles replace-all-with { tcp http sinkhole-clientssl } vlans-enabled rules { sinkhole-rule }
echo submit cli transaction
) | tmsh > /dev/null 2>&1

## Clean up sinkhole template cert/key
rm -f sinkhole.crt sinkhole.key





