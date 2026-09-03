# Dedicated DFU host setup

This guidance prepares a trusted technician workstation for repeated DFUUtility use without bypassing macOS security controls.

## Host and connection

- Use macOS 14 or newer and install Apple Configurator. The current automatic Mac DFU workflow requires an Apple-silicon host.
- Connect targets with a direct, data-capable USB cable where practical. Charging capability alone does not prove that a cable carries data.
- For Mac targets, use Apple's model-specific DFU-port guidance. Port behavior is not universal. On the tested `Mac17,6`, automatic entry and post-transition enumeration required different left-side ports; that observation must not be generalized to every newer Mac.

## macOS accessory authorization

Apple-silicon Mac laptops can require approval before a new USB, Thunderbolt, or supported card accessory communicates with the host. Review:

**System Settings → Privacy & Security → Accessories → Allow accessories to connect**

Apple currently documents four choices: Always ask, Ask for new accessories, Automatically allow when unlocked, and Always allow. For a dedicated, physically trusted technician workstation, **Automatically allow when unlocked** is the recommended balance: it avoids repeated approvals while the bench Mac is unlocked but retains accessory restrictions while it is locked.

**Always allow** can minimize interruptions on a dedicated bench. Its security cost is material: a newly attached wired accessory can connect without individual approval. Do not treat it as a blanket recommendation for a personal or unattended Mac.

DFUUtility does not read, change, approve, dismiss, or bypass this setting. Apple documents the user interface and managed restriction, but not a public API or stable ordinary-application configuration source for reading the effective policy. Diagnostics therefore reports the state as not reliably readable and directs the technician to System Settings rather than inspecting private preferences or scraping the UI.

Apple reference: [Allow USB and other accessories to connect to your Mac](https://support.apple.com/en-us/102282).

## Managed Macs

Apple documents accessory security as Restricted Mode and states that a device-management service can control the behavior on supervised Apple-silicon Mac laptops using Apple's supported USB Restricted Mode restriction. Exact availability and semantics can vary by OS and management platform. Administrators should use the current [Apple Platform Deployment accessory-access guidance](https://support.apple.com/guide/deployment/manage-accessory-access-depf8a4cb051/web) and their MDM vendor's current documentation. DFUUtility does not install or alter MDM profiles, and no managed setting should be assumed to suppress every USB, trust, pairing, or security prompt.

## Separate mechanisms

Do not conflate these independent controls:

- **Host accessory authorization:** whether the Mac permits a newly connected wired accessory to communicate; this is the setting addressed above.
- **iPhone/iPad trust and pairing:** a relationship authorized on the mobile device for normal host access. It is separate from the Mac's accessory policy.
- **Recovery and DFU transport:** low-level restore modes with their own physical-entry, discovery, and authorization behavior.
- **Mac DFU port selection:** the model-specific physical port required for a Mac-to-Mac DFU workflow.

Changing one of these does not imply that the others are configured or bypassed.
