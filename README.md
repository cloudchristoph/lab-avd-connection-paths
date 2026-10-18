# lab-avd-connection-paths

Lab code, queries and scripts for the blog series **AVD connection paths** on
[cloudchristoph.com](https://cloudchristoph.com): how an Azure Virtual Desktop session finds its
way from the client to the session host (TCP reverse connect, RDP Shortpath direct via STUN, TURN
relay, the private path over VPN or ExpressRoute with and without the listener on UDP 3390), and
what firewalls, NAT and logs have to do with it.

> **Lab code, not production.** This is the setup I used to measure the results in the series.
> It deliberately does things you should not copy (a public IP on a session host NIC, "UDP to any",
> local state, a generated local admin password). Use it to reproduce and to learn, not as a
> landing zone pattern.

## The series

1. [Part 1: the client decides which path you get](https://cloudchristoph.com/articles/avd-connection-paths-1-the-client-decides/)
2. [Part 2: what the AVD settings really do to the path](https://cloudchristoph.com/articles/avd-connection-paths-2-what-avd-settings-do/)
3. [Part 3: the firewall rules you need, the ones you don't, and three traps](https://cloudchristoph.com/articles/avd-connection-paths-3-firewall-rules-and-three-traps/)
4. [Part 4: why RDP Shortpath over private networks is luck, and a fix](https://cloudchristoph.com/articles/avd-connection-paths-4-shortpath-over-private-networks/)
5. [Part 5: the join type decides your sign-in firewall rules](https://cloudchristoph.com/articles/avd-connection-paths-5-join-type-and-sign-in-rules/)
6. [Part 6: reading the logs without being fooled](https://cloudchristoph.com/articles/avd-connection-paths-6-reading-the-logs/)
7. [The checklist](https://cloudchristoph.com/articles/avd-connection-paths-checklist/)

## What's in here

| Path | Content | Part |
| --- | --- | --- |
| [`terraform/`](./terraform/) | Spoke VNet with switchable egress, pooled host pool with the four RDP Shortpath switches, Entra joined Windows 11 multi-session hosts, diagnostics to Log Analytics, optional AVD rules for an existing Azure Firewall policy | 2, 3 |
| [`kql/session-classification.kql`](./kql/session-classification.kql) | One row per session: which path it really took (listener, STUN or private ICE, TURN, TCP and why) | 6 |
| [`kql/session-classification-summary.kql`](./kql/session-classification-summary.kql) | Same classification, summarized per client type | 6 |
| [`kql/agent-health-status-changes.kql`](./kql/agent-health-status-changes.kql) | `WVDAgentHealthStatus`, status changes only (what an egress switch does to the agent) | 3, 6 |
| [`kql/transport-checkpoints.kql`](./kql/transport-checkpoints.kql) | All checkpoints and errors of one session, by correlation ID (Activity ID) | 6 |
| [`kql/firewall-avd-hits.kql`](./kql/firewall-avd-hits.kql) | What Azure Firewall allowed and denied for the session hosts, per rule | 3, 6 |
| [`kql/firewall-who-checks-whom.kql`](./kql/firewall-who-checks-whom.kql) | RDP Shortpath UDP between clients and one session host: did the client send first? | 4, 6 |
| [`kql/session-checkpoints.kql`](./kql/session-checkpoints.kql) | Shortpath checkpoints of one session with seconds since session start (`ShortpathRequested`, `initialUdpType`) | 4, 6 |
| [`kql/extras/session-classification-with-network-data.kql`](./kql/extras/session-classification-with-network-data.kql) | Optional: classification plus client IP, RTT and bandwidth estimates (trends only; `BwMbps` is the log's kilobytes per second converted to megabits per second) | 6 |
| [`kql/extras/paths-over-time.kql`](./kql/extras/paths-over-time.kql) | Optional: share of each path per 15 minutes as a chart, for before and after a change | 6 |
| [`scripts/Show-AvdTransport.ps1`](./scripts/Show-AvdTransport.ps1) | Runs inside the session: UDP or TCP right now (RdpCoreCDV events 131/135, UDP sockets) | 2 |
| [`scripts/Get-RemoteFxCounters.ps1`](./scripts/Get-RemoteFxCounters.ps1) | Runs on the session host: `RemoteFX Network` counters, proves UDP when the client dialog says `Multipath Websocket` | 4, 6 |
| [`scripts/Set-ShortpathListener.ps1`](./scripts/Set-ShortpathListener.ps1) | Lab shortcut: RDP Shortpath listener on UDP 3390 plus Windows Firewall rule (production: use the policy) | 4 |
| [`scripts/avd-transport.sh`](./scripts/avd-transport.sh) | Runs the session classification via az CLI and prints one coloured line per session | 6 |
| [`scripts/get-hostpool-shortpath.sh`](./scripts/get-hostpool-shortpath.sh) | Reads `managedPrivateUDP`, `directUDP`, `publicUDP`, `relayUDP` with a preview API version | 2 |
| [`scripts/check-service-tag.sh`](./scripts/check-service-tag.sh) | Optional: does the service tag `WindowsVirtualDesktop` contain `51.5.0.0/16` in your region? | 3 |
| [`scripts/macos-enable-udp.sh`](./scripts/macos-enable-udp.sh) | Turns on UDP in Windows App for macOS (`ClientSettings.EnableAvdUdpSideTransport`) | 1 |

The checkpoint names and `initialUdpType` labels the queries rely on are **observed, not
documented** on Microsoft Learn. Test the queries in your own workspace before you build a
dashboard on them.

## Lab topology

As described in [part 3, "The lab"](https://cloudchristoph.com/articles/avd-connection-paths-3-firewall-rules-and-three-traps/#the-lab):

- **Session host:** Windows 11 Enterprise multi-session 24H2, Entra joined, in a spoke VNet.
  Default route `0.0.0.0/0` to an Azure Firewall (Premium in my lab) in the hub.
- **Host pool:** pooled, all four RDP Shortpath options enabled (the default). The listener for
  managed networks from part 4 is not part of the Terraform code; use
  [`scripts/Set-ShortpathListener.ps1`](./scripts/Set-ShortpathListener.ps1) or, better, the policy.
- **On-prem:** a site-to-site VPN from a home network (a prosumer router) into the hub, plus a
  WireGuard client VPN on that router for the private-network tests in part 4 (its pool has to be
  known in the local network gateway, the firewall rules and the NSG, just like the home LAN).
- **Clients:** Windows App for Windows and Windows App for macOS, on the same network behind the
  same NAT.
- **Egress variants**, switched between connects (exactly one active at a time):

| `egress_mode` | Extra switch | Way to the internet |
| --- | --- | --- |
| `firewall` | | `0.0.0.0/0` to the hub Azure Firewall (SNAT to the firewall's public IP) |
| `natgw` | | NAT gateway on the host subnet, no firewall in the internet path |
| `direct` | | Standard public IP on each session host NIC (comparison only) |
| `firewall` | `avd_traffic_bypasses_firewall = true` | UDR `WindowsVirtualDesktop` to next hop Internet plus a NAT gateway; everything else still via the firewall |

Further switches: `block_turn_udp` (NSG denies UDP 3478 to `51.5.0.0/16`, part 3 trap 1) and
`shortpath` (the four host pool properties, part 2). On-prem traffic stays on the firewall path
in every mode.

```text
 on-prem (home network)                    Azure
 +-------------------------+   S2S VPN    +----------------------------------------------+
 | Windows App (Win, macOS)|<============>| hub VNet (existing, NOT in this repo)        |
 | NAT router              |              |   VPN gateway, Azure Firewall (+ policy)     |
 +-----------+-------------+              +---------------------+------------------------+
             |                                                  | peering
             | TCP 443, UDP 3478                                 |
             v                                    +-------------+--------------------------+
 +---------------------------+                    | spoke VNet (this repo)                 |
 | Microsoft                 |<-------------------|   snet-hosts: vm-avd-demo-01           |
 |  AVD gateway/broker  443  |  TCP 443, UDP 3478 |   route table, NSG, optional NAT GW,   |
 |  STUN/TURN 51.5.0.0/16    |  (via the active   |   optional public IP on the NIC        |
 +---------------------------+   egress variant)  +----------------------------------------+
```

## What is NOT included

The lab in the series ran inside my larger Azure lab (Azure Landing Zones, hub and spoke). These
parts are not portable and are not in this repo:

- **The hub:** hub VNet, VPN gateway, the on-prem side of the VPN, Azure Firewall and its policy.
  Bring your own and pass their IDs (see below). Without a hub, only `natgw` and `direct` work.
- **The GatewaySubnet route** in the hub for the spoke's address space to the firewall. Needed for
  symmetric routing of the managed path (on-prem to session host through the firewall). Add it to
  your hub's GatewaySubnet route table yourself.
- **ALZ policy exemptions.** In a corp landing zone, the policies `Deny-Public-IP-On-NIC`,
  `Deny-Public-Endpoints` (host pool, workspace, managed disk) and "Allowed locations" (AVD
  metadata region) block parts of this lab. My lab waived them for the lab resource group only.
  If your subscription has such policies, you need comparable exemptions.
- **Live switches without Terraform.** On stage I switched egress, TURN block and Shortpath with a
  small function app. Here, every switch is a `terraform apply -var ...`.
- **FSLogix on Azure Files** (part 5 is docs only). The lab also ran FSLogix with Entra Kerberos and
  a private endpoint; it does not change the connection path and is left out here.
- **Key Vault** for the local admin password: it is a sensitive Terraform output instead.

## Prerequisites

- Terraform 1.9 or later, Azure CLI, signed in (`az login`).
- A subscription for the spoke and Owner (or Contributor plus User Access Administrator) on it.
- For `egress_mode = firewall` and the managed path: an existing hub VNet with Azure Firewall and,
  for on-prem clients, a VPN or ExpressRoute gateway. Network Contributor on the hub VNet (for the
  peering) and, if this stack should add the firewall rules, on the firewall policy.
- Entra ID: a group with the lab users, the object ID of the "Azure Virtual Desktop" service
  principal (for Start VM on Connect), and licences that cover AVD and Windows 11 Enterprise
  multi-session for the users.
- Windows Cloud Login (Entra SSO for RDP) enabled for the users, if you want single sign-on from
  macOS and Windows.

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your IDs; terraform.tfvars is git-ignored
terraform init
terraform apply
```

Then subscribe to the workspace in Windows App, connect, and open **Connection Information**
(after 40 seconds or more, not right after connecting).

Diagnostics lag up to about 15 minutes. Run the queries from `kql/` in the workspace, or:

```bash
WORKSPACE_ID=$(terraform -chdir=terraform output -raw log_analytics_workspace_customer_id) \
  WATCH=30 ./scripts/avd-transport.sh
```

## Switch between variants

```bash
terraform -chdir=terraform apply -var egress_mode=natgw
terraform -chdir=terraform apply -var egress_mode=direct
terraform -chdir=terraform apply -var egress_mode=firewall -var avd_traffic_bypasses_firewall=true
terraform -chdir=terraform apply -var block_turn_udp=true
terraform -chdir=terraform apply -var 'shortpath={managed="Enabled",public_stun="Disabled",public_turn="Enabled"}'
```

**Restart the session hosts after every egress change** before you test. Otherwise you measure
the AVD agent recovering, not the network ([part 3, trap 2](https://cloudchristoph.com/articles/avd-connection-paths-3-firewall-rules-and-three-traps/#trap-2-changing-the-egress-breaks-the-avd-agent)).

## Tear down

```bash
terraform -chdir=terraform destroy
```

This removes the spoke, the host pool, the session hosts, the peering on both sides, the Log
Analytics workspace (if this stack created it) and the AVD rule collection group (if
`firewall_policy_id` was set). Your hub stays as it is. Remove any manual additions (GatewaySubnet
route, policy exemptions) yourself.

## Costs

Mostly the session host VM (deallocate it when you don't test; Start VM on Connect powers it on),
its disk, Log Analytics ingestion and, while active, the NAT gateway and public IPs. The hub and
its Azure Firewall are not part of this repo, but they are usually the largest cost in this setup.

## License

MIT, see [LICENSE](LICENSE).

---

_This repo reflects my personal opinion and lab results, not the position of Microsoft or my
employer._
