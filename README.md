# DNS Sinkholing with SSL Orchestrator

#### This tool creates a configuration on the F5 BIG-IP to support DNS sinkholing and decrypted blocking page injection with SSL Orchestrator.

-----------------

The configuration relies on two components:

* A **sinkhole internal** virtual server with client SSL profile to host a sinkhole certificate and key. This is a certificate with empty Subject field used as the origin for forging a trusted certificate to the internal client. 

* An **SSL Orchestrator** outbound L3 topology that is modified to accept traffic on a specific internal client-facing IP:port and points to the internal virtual server. When a client makes a request to this virtual, SSL Orchestrator fetches the origin "sinkhole" certificate, forges a new local certificate, and auto-injects a subject-alternative-name into the forged cert to match the client's request. An iRule is added to enable an HTTP blocking page response on the explicitly decrypted traffic.

-----------------

To create the **sinkhole internal** virtual server configuration:

* **Optional easy-install step**: The following Bash script builds all of the necessary objects for the internal virtual server configuration. You can either use this or follow the steps below to create these manually.

  ```
  curl -s https://raw.githubusercontent.com/kevingstewart/sslo-dns-sinkhole/main/create-sinkhole-internal-config.sh | bash
  ```

* **Step 1: Create the sinkhole certificate and key** The sinkhole certificate is specifically crafted to contain an empty Subject field. SSL Orchestrator is able to dynamically modify the subject-alternative-name field in the forged certificate, which is the only value of the two required by modern browsers.

  ```
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
  extendedKeyUsage=serverAuth,clientAuth")
  ```

* **Step 2: Install the sinkhole certificate and key to the BIG-IP** Either manually install the new certificate and key to the BIG-IP, or use the following TMSH transaction:
  ```
  (echo create cli transaction
  echo install sys crypto key sinkhole-cert from-local-file "$(pwd)/sinkhole.key"
  echo install sys crypto cert sinkhole-cert from-local-file "$(pwd)/sinkhole.crt"
  echo submit cli transaction
  ) | tmsh
  ```

* **Step 3: Create a client SSL profile that uses the sinkhole certificate and key** Either manually create a client SSL profile and bind the sinkhole certificate and key, or use the following TMSH command:
  ```
  tmsh create ltm profile client-ssl sinkhole-clientssl cert sinkhole-cert key sinkhole-cert > /dev/null
  ```

* **Step 4: Create the sinkhole "internal" virtual server** This virtual server simply hosts the client SSL profile and sinkhole certificate that SSL Orchestrator will use to forge a blocking certificate.

  - Type: Standard
  - Source Address: 0.0.0.0/0
  - Destination Address/Mask: 0.0.0.0/0
  - Service Port: 9999 (does not really matter)
  - HTTP Profile (Client): http
  - SSL Profile (Client): the sinkhole client SSL profile
  - VLANs and Tunnel Traffic: select "Enabled on..." and leave the Selected box empty

  or use the following TMSH command:

  ```
  tmsh create ltm virtual sinkhole-internal-vip destination 0.0.0.0:9999 profiles replace-all-with { tcp http sinkhole-clientssl } vlans-enabled
  ```

* **Step 5: Create the sinkhole target iRule** This iRule will be placed on the SSL Orchestrator topology to steer traffic to the sinkhole internal virtual server. Notice the contents of the HTTP_REQUEST event. This is the HTML blocking page content. Edit this at will to meet your local requriements.

  ```
  when CLIENT_ACCEPTED {
      virtual "sinkhole-internal-vip"
  }
  when CLIENTSSL_CLIENTHELLO priority 800 {
      if {[SSL::extensions exists -type 0]} {
          binary scan [SSL::extensions -type 0] @9a* SNI
      }
  
      if { [info exists SNI] } {
          SSL::forward_proxy extension 2.5.29.17 "critical,DNS:${SNI}"
      }
  }
  when HTTP_REQUEST {
      HTTP::respond 403 content "<html><head></head><body><h1>Site Blocked!</h1></body></html>"
  }
  ```

-----------------

To create the **SSL Orchestrator** outbound L3 topology configuration, in the SSL Orchestrator UI, create a new Topology. Any section not mentioned below can be skipped.

* **Topology Properties**

  - Protocol: TCP
  - SSL Orchestrator Topologies: select L3 Outbound

* **SSL Configuration**

  - Click on "Show Advanced Setting"
  - CA Certificate Key Chain: select the correct client-trusted internal signing CA certificate and key
  - Expire Certificate Response: Mask
  - Untrusted Certificate Response: Mask

* **Security Policy**

  - Delete the Pinners_Rule

* **Interception Rule**

  - Destination Address/Mask: enter the client-facing IP address/mask. This will be the address sent to clients from the DNS for the sinkhole
  - Ingress Network/VLANs: select the client-facing VLAN
  - Protocol Settings/SSL Configurations: ensure the previously-created SSL configuration is selected

Ignore all other settings and **Deploy**. Once deployed, navigate to the Interception Rules tab and edit the new topology interception rule.

  - Resources/iRules: add the **sinkhole-target-rule** iRule

Ignore all other settings and **Deploy**.

-----------------

To **Test**, update an /etc/hosts file entry on a client, or update a local DNS server record to point a specific url (ex. www.example.com) to the IP address specified in the SSL Orchestrator outbound L3 topology. Attempt to access that HTTPS and HTTP URL from a browser on this client. The blocking page content will be returned along with a valid locally-issued server certificate.





  
