# MRAS Ecosystem and User Model

## Purpose
This document defines the final ecosystem actors, user groups, system surfaces, and access rules for the Minority Report Advertising System (MRAS) v1.0. It is intended to serve as implementation context for architecture planning, system design, role-based access control, and product scoping.

## Product Scope
MRAS is a fully managed digital out-of-home advertising platform that detects nearby people, selects personalized or non-personalized ad content, and plays media on connected on-site display systems. The system includes sensing hardware, playback hardware, an on-site control and playback system, and back-office reporting and administration tools.

The v1.0 product scope excludes DSP and SSP integrations, excludes consumer self-service portals, and assumes a direct operating model in which all advertising demand is managed through an Agency of Record.

## Operating Model
MRAS operates as a fully managed system.

- The platform operator is responsible for building, deploying, managing, monitoring, updating, and maintaining the entire MRAS system.
- Hosts do not directly manage player software, camera configuration, firmware deployment, or infrastructure settings.
- The on-site MRAS system may display hardware and system status information locally for awareness and troubleshooting, but that visibility does not imply administrative control by the host.

## Ecosystem Actors
The MRAS ecosystem in v1.0 consists of four primary external actor groups and one internal operator group.

### 1. Customers
Customers are the people detected by the MRAS sensing and playback environment.

Customer subtypes:
- Opt-in identified customer: a person who has previously opted into identification or recognition through an external business process such as loyalty enrollment or similar identity linkage.
- Anonymous passer-by: a person detected for presence or audience measurement but not matched to an identity profile.
- Blocklisted customer: a person who has opted out of biometric tracking or has otherwise been marked as ineligible for identification or personalization. The system must suppress identification and suppress personalized targeting for this user type.

Customers do not have direct access to any MRAS interface, dashboard, portal, or control surface in v1.0.

### 2. Hosts
Hosts are the organizations or locations where MRAS hardware is installed and operated.

Host examples:
- Retail stores
- Indoor malls
- Outdoor malls
- Central business district buildings
- Trade show venues
- Airports
- Other venue operators

Host role in v1.0:
- Provide installation location and physical operating environment for MRAS.
- Receive ads and experiences on screens installed at their site.
- Potentially review scoped reporting relevant to their location.

Host internal roles in v1.0:
- Host IT

Host IT does not administer the MRAS platform, but may view local on-site system status information and may coordinate with the platform operator when issues occur.

### 3. Advertisers
All advertisers in MRAS v1.0 operate through an Agency of Record.

Advertiser types may include:
- Brands
- Partners
- Other paying demand-side clients

Advertisers do not directly manage campaigns in the primary operating model. Their reporting access, when granted, is read-only and limited to sub-accounts scoped only to their own campaigns.

### 4. Agency of Record
The Agency of Record is the primary demand-side operating entity for advertiser activity in MRAS.

Agency responsibilities include:
- Managing advertiser relationships
- Coordinating campaign setup
- Managing creative submissions and approvals
- Reviewing reporting for represented advertisers
- Acting as the primary demand-side interface into MRAS

If an advertiser does not already have an external Agency of Record, the platform operator serves as that Agency of Record for the account.

### 5. Platform Operator
The platform operator is the organization that builds, runs, and maintains MRAS.

Internal roles in v1.0:
- System Admin
- Senior System Admin

Future internal roles may be added later, but are out of scope for v1.0.

## System Surfaces
MRAS v1.0 is divided into three primary system surfaces.

### 1. On-Site MRAS Control and Playback System
This is the on-premise runtime environment that operates the local MRAS installation.

It includes:
- Cameras and sensing hardware
- Playback screens
- Local compute or player hardware
- The Electron-based playback and control application
- Local status and health visibility

Primary responsibilities:
- Detect people in view
- Apply eligibility and suppression rules
- Trigger ad playback
- Render and control media playback
- Show on-site operational state and hardware health information

Information shown on this surface may include:
- Network status
- Player online or offline state
- Camera health
- Screen state
- Application status
- Maintenance windows
- Other local diagnostics relevant to runtime operations

This surface is operated by the platform operator. Host IT may be allowed to view status information locally, but does not receive administrative control in v1.0.

### 2. MRAS Reporting Dashboard
This is the back-office reporting interface for campaign and location performance.

Reporting may include:
- When ads were run
- Which campaigns ran at which locations
- Whether a viewed event was identified or anonymous
- Whether a view was suppressed from personalization due to blocklist status
- Duration watched or dwell metrics
- Aggregate performance statistics for a location
- Aggregate performance statistics for a campaign

This dashboard is not a consumer-facing interface.

### 3. MRAS Administration Surface
This is the administrative interface used to configure and operate the platform.

Administrative functions may include:
- System setup
- Device registration
- Location configuration
- Campaign assignment
- User and account management
- Audit and operational oversight
- Diagnostics and system maintenance

This surface is reserved for the platform operator in v1.0.

## Access Model
The v1.0 access model is intentionally narrow and highly structured.

### Customers
- No direct access to any MRAS interface.
- No portal, self-service dashboard, or account access in v1.0.
- Privacy or deletion requests are handled outside the platform through email or a website form reached via QR code.

### Host IT
- No administrative access to the platform.
- May view on-site MRAS system status information at the installed location.
- May receive read-only access to reporting scoped to the host location if required by business operations.
- Must contact the platform operator for changes, maintenance, privacy issues, and support.

### Agency of Record
- Primary external operating user for advertiser-side activity.
- May receive dashboard access for campaign reporting and account oversight.
- Access is scoped to the campaigns and advertisers under that agency relationship.
- Does not manage infrastructure or core system administration.

### Advertiser
- Access is optional and read-only only.
- Access, when granted, is through sub-accounts scoped strictly to that advertiser's own campaigns.
- Advertisers do not receive access to campaigns belonging to other advertisers, even if they share the same Agency of Record.
- Advertisers do not receive administrative access to platform configuration or hardware controls.

### System Admin
- Full operational access to the platform.
- Can manage devices, locations, campaigns, user access, reporting configuration, and system operations.

### Senior System Admin
- Full operational access plus elevated authority for sensitive, global, or high-risk actions.
- Can override lower-level controls, manage core system settings, and perform advanced maintenance and administrative functions.

## Identity and Personalization Rules
MRAS v1.0 must support three customer states in the decisioning and playback flow.

### Opt-In Identified Customer
- The system may identify the person using approved identity linkage.
- The system may permit personalized ad delivery if the account, campaign, and rules allow it.
- Reporting may classify the impression or event as identified.

### Anonymous Passer-By
- The system may detect presence and generate anonymous audience metrics.
- The system must not claim identity for the person.
- The system may deliver non-identified or contextually relevant advertising.

### Blocklisted Customer
- The system must suppress identity resolution.
- The system must suppress personalization.
- The system may either skip personalized delivery or fall back to a non-personalized/default ad path according to campaign rules.
- Reporting should preserve the fact that personalization was suppressed without exposing prohibited identity details.

## Reporting Model
The reporting model in v1.0 is designed for operational review and campaign visibility, not for broad ecosystem sharing.

Reporting audiences:
- Agency of Record
- Optional advertiser read-only sub-accounts
- Optional host read-only views
- Platform operator administrators

Reporting principles:
- Scope all views by account and location boundaries.
- Expose only the minimum information necessary for the role.
- Keep consumer access out of scope.
- Keep regulator and public-interest stakeholder access out of scope.
- Route all external inquiries about privacy, governance, or compliance to the platform operator.

## Explicit v1.0 Exclusions
The following items are intentionally excluded from MRAS v1.0:

- DSP integrations
- SSP integrations
- Programmatic demand paths
- Consumer dashboards or self-service portals
- Consumer account login
- Consumer in-product opt-out management
- Regulator access to internal systems
- Public-interest stakeholder access to internal systems
- Distributed advertiser administration outside the Agency of Record model
- Host administration of infrastructure, player software, or platform configuration
- Expanded internal operator role hierarchy beyond System Admin and Senior System Admin

## Default Governance Handling
MRAS does not provide system access to regulators, advocacy groups, public-interest organizations, or other external governance stakeholders in v1.0.

All such parties must contact the platform operator through external communication channels.

Privacy removal or right-to-be-forgotten style requests are handled outside the product through email or website form submission and are processed operationally by the platform operator.

## Implementation Guidance for Architecture Planning
Use this document as the source of truth for v1.0 planning assumptions.

Architectural planning should assume:
- A fully managed deployment model
- A narrow role set in v1.0
- Strong separation between on-site visibility and administrative control
- A single demand-side operating path through the Agency of Record
- Optional read-only advertiser sub-accounts only
- No consumer-facing application surface in v1.0
- Suppression logic for blocklisted individuals as a core system requirement
- Separate reporting and administration surfaces even if implemented within a single application shell

## Suggested Canonical Role List
Use the following canonical role labels in planning artifacts unless later revised:

- Customer.OptInIdentified
- Customer.Anonymous
- Customer.Blocklisted
- Host.IT
- Advertiser.ReadOnly
- AgencyOfRecord.Standard
- Operator.SystemAdmin
- Operator.SeniorSystemAdmin

## Suggested Canonical System Surface Labels
Use the following canonical surface labels in planning artifacts unless later revised:

- Surface.OnSiteControlPlayback
- Surface.ReportingDashboard
- Surface.Administration

## Suggested Canonical Scope Statement
MRAS v1.0 is a fully managed personalized digital out-of-home advertising system in which all advertiser demand is routed through an Agency of Record, all consumer interactions are non-self-service, all host involvement is operationally limited, and all platform control remains with the operator.
