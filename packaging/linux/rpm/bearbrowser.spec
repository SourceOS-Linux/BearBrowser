Name: bearbrowser
Version: 0.1.0
Release: 0.overlay%{?dist}
Summary: SourceOS governed browser for humans and agents
License: MPL-2.0
URL: https://github.com/SourceOS-Linux/BearBrowser
BuildArch: x86_64

%description
BearBrowser is a SourceOS governed browser with separate human-secure and
agent-runtime profiles, policy-mediated automation surfaces, and workspace
integration contracts.

%prep
# Full source prep depends on Lane 13 full browser build.

%build
# Full browser binary build depends on Lane 13.

%install
mkdir -p %{buildroot}%{_datadir}/applications
mkdir -p %{buildroot}%{_datadir}/metainfo
mkdir -p %{buildroot}%{_datadir}/icons/hicolor/scalable/apps
install -m 0644 packaging/linux/dev.sourceos.BearBrowser.desktop %{buildroot}%{_datadir}/applications/dev.sourceos.BearBrowser.desktop
install -m 0644 packaging/linux/dev.sourceos.BearBrowser.metainfo.xml %{buildroot}%{_datadir}/metainfo/dev.sourceos.BearBrowser.metainfo.xml
install -m 0644 branding/bearbrowser.svg %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/dev.sourceos.BearBrowser.svg

%files
%{_datadir}/applications/dev.sourceos.BearBrowser.desktop
%{_datadir}/metainfo/dev.sourceos.BearBrowser.metainfo.xml
%{_datadir}/icons/hicolor/scalable/apps/dev.sourceos.BearBrowser.svg

%changelog
* Sun May 03 2026 SourceOS <maintainers@sourceos.dev> - 0.1.0-0.overlay
- Initial BearBrowser RPM scaffold.
