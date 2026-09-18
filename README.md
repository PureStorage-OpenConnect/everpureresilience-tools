### Everpure Resilience service — In-Guest ToolsInstallation and User Guide

*Applies to [tools version 2.25.0](https://github.com/PureStorage-OpenConnect/everpureresilience-tools/releases/tag/2.25.0) · Windows and Linux*

---

## 1\. Overview of Everpure Resilience service tools

Everpure Resilience service tools enable the features to change a virtual machine's IP address, gateway and DNS servers when it recovers that machine at another site. Those changes have to be applied *inside* the guest operating system. The in-guest tool is what applies them.

Install it once on each protected virtual machine. It then sits dormant and does nothing on a normal boot. After a recovery where you have configured a network change, it applies the new settings automatically as the machine starts.

It can also run a script of your own after recovery — see section 6\.

Whether IP reassignment requires this tool depends on the recovery target:

* **Recovery to AWS** — no tool required. IP addresses are assigned natively through AWS.  
* **Recovery to VMware via the VADP flow (no FlashArray integration)** — no tool required. The necessary components are injected automatically during recovery.  
* **Recovery to VMware with FlashArray integration** — the tool must be installed. Without it, recovered virtual machines will start with their original network settings.

## 2\. Pre-Requisites

| Requirement | Windows | Linux |
| :---- | :---- | :---- |
| Privileges to install | Administrator | root |
| Shell | PowerShell 5.0 or later | bash |
| Network stack | Any | netplan, NetworkManager, RHEL ifcfg, SLES ifcfg, or systemd-networkd |

Also worth knowing:

- IPv4 only. IPv6 settings are never modified.  
- Both scripts come from the Everpure Resilience tools repository and can be deployed at scale with Microsoft MCM/SCCM, Ansible, or any comparable tool.

## 3\. Installing

Run the script once, as administrator or root. It copies itself to a permanent location and registers itself to run at every startup.

### Windows

Command: powershell.exe \-ExecutionPolicy Bypass \-File .\\pure-protect.ps1

- Installed to: C:\\PureProtect\\Scripts\\configurator.ps1  
- Startup mechanism: scheduled task PureProtectConfigurator under \\PureStorage\\PureProtect\\, run at startup as SYSTEM  
- Logs: C:\\PureProtect\\Scripts\\configurator-\<timestamp\>.log

### Linux

Command: sudo ./pure-protect.sh

- Installed to: /usr/local/pureprotect/scripts/configurator.sh  
- Startup mechanism: systemd service pureprotect-configurator.service, or a cron @reboot job on systems without systemd  
- Logs: /usr/local/pureprotect/scripts/configurator-\<timestamp\>.log

Running the installer again is safe. It detects an existing installation and repairs only what is missing.

## 4\. What happens at each boot

Every time the machine starts, the tool runs and checks whether Everpure Resilience has left network instructions for it.

- **Normal boot** — no instructions present. The tool records that no configuration was needed and exits. Your networking is left completely untouched.  
- **After a recovery with a network change** — the tool identifies each adapter by its MAC address, applies the new IP address, gateway and DNS servers, verifies the result, and reports back to Everpure Resilience.

Because results are reported back to the service, the outcome is visible in the recovery job without logging into the guest.

## 5\. Confirming it is installed

- Windows: Get-ScheduledTask \-TaskPath "\\PureStorage\\PureProtect\\"  
- Linux, with systemd: systemctl status pureprotect-configurator.service  
- Linux, without systemd: cat /etc/cron.d/pureprotect-configurator

You can also open the most recent log in the install directory. A healthy normal-boot log ends with a line confirming that no network configuration was performed in that run.

## 6\. Running your own script after recovery

If you need to do something else inside the guest after recovery — restart an application, re-register with a licence server, update a configuration file — place your own script in the install directory using the exact filename below. The filename is fixed.

- Windows: C:\\PureProtect\\Scripts\\post-failover.ps1  
- Linux: /usr/local/pureprotect/scripts/post-failover.sh

Its output is written to post-failover-\<timestamp\>.log in the same directory.

The tool checks for your script on every boot and reports its presence to Everpure Resilience, but only runs it when a recovery calls for it, after network configuration has completed. Its exit code and any error output are reported back to the service, so a failure in your script is visible in the recovery job.

## 7\. Logs

Logs are written to the install directory and timestamped in UTC.

- The five most recent configurator logs are kept; older ones are removed automatically.  
- Post-failover script logs are never removed automatically. Clear them yourself if space is a concern.  
- A copy of the most recent run's log is also reported back to Everpure Resilience, so support can review it without guest access.

## 8\. Uninstalling

Run as Administrator or root.

- Windows: powershell.exe \-ExecutionPolicy Bypass \-File C:\\PureProtect\\Scripts\\configurator.ps1 \--uninstall  
- Linux: sudo /usr/local/pureprotect/scripts/configurator.sh \--uninstall

This removes the scheduled task or service, the installed script, and the configurator logs.

If your own post-failover script is present, the install directory and your script are preserved — only the tool's own files are removed.

One thing to be aware of: the properties the tool exchanges with VMware Tools cannot be deleted from inside the guest. They remain until the next power cycle of the virtual machine, at which point they clear automatically. They have no effect once the tool is removed.

## 9\. Troubleshooting

Start with the most recent configurator log in the install directory. Almost every problem is explained there in plain language, and each entry carries the code shown below.

| What you see | What it means | What to do |
| :---- | :---- | :---- |
| No network properties detected (code 17\) | Normal. This is what a routine boot looks like — there was no recovery, so there was nothing to apply. | No action needed. |
| Nothing happens after a recovery, and no log for that boot | The tool is not installed, or its startup task or service was removed. | Confirm installation using section 5\. Re-run the installer if needed. |
| VMware Tools not found or not functional (code 18\) | VMware Tools is missing, stopped, or mid-upgrade. The tool waits five minutes before giving up. | Confirm VMware Tools is installed and running, then restart the guest. |
| Must be run as root, or missing group (codes 10 and 21\) | The script was not run with sufficient privileges. | Re-run as Administrator on Windows, or with sudo on Linux. |
| PowerShell version too low (code 24\) | The guest has PowerShell below 5.0. | Upgrade PowerShell, or apply the network change manually after recovery. |
| Invalid address format (code 20\) | The address in the recovery plan is not valid CIDR notation, for example 10.0.0.5/24. | Correct the address in the recovery plan and run the recovery again. |
| Failed to apply settings to an adapter (codes 13 and 22\) | The address was rejected by the guest, or another configuration claimed the adapter first. | Review the log for the adapter named. A conflicting static address or a competing connection profile is the usual cause. |
| An adapter is disconnected (code 23\) | An adapter was configured but is not connected to a network. | Check the port group or network mapping for that adapter at the recovery site. |
| Unsupported network management system (code 11, Linux only) | The distribution uses a network stack the tool does not recognise. | See the supported list in section 2\. Apply the settings manually, or use a post-failover script. |
| Your post-failover script did not run (code 19\) | The file was not found at the expected path, or was named incorrectly. | Confirm the exact filename and location in section 6\. |
| Your post-failover script ran but failed | The script's own exit code and error output are reported back to the service. | Open the post-failover log in the install directory. |

A note on Windows: some network problems are recorded against the network step while the tool itself still exits successfully. Always read the log along with the process exit code.

If a problem persists, have ready the guest operating system and version, the most recent configurator log, and the name of the recovery plan and job.

## 10\. Support

- Contact Everpure Support  
- Post in the Everpure Community at purecommunity.purestorage.com  
- Contact your Everpure Account team

---

*Behaviour described here reflects [in-guest tools version 2.25.0](https://github.com/PureStorage-OpenConnect/everpureresilience-tools/releases/tag/2.25.0).*
