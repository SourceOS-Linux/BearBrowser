# BearBrowser Chocolatey Package

Windows packaging for BearBrowser.

## Install

```powershell
choco install bearbrowser
```

## Build Locally

```powershell
cd packaging\chocolatey\bearbrowser
choco pack
choco install bearbrowser --source .
```

## Notes

BearBrowser requires the GCP compile pipeline for the full patched Gecko build.
During early access, installs a hardened Gecko base and applies the
BearBrowser configuration profile (user.js with 101 fingerprinting protections).
The patched build (OS-spoof patch + FF140 ESR cohort patch) ships via GitHub Releases.
