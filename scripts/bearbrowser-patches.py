#!/usr/bin/env python3

#
# The script that patches the firefox source into the bearbrowser source.
#


import os
import sys
import optparse
import time
from pathlib import Path
from tempfile import TemporaryDirectory


#
# general functions, skip these, they are not that interesting
#

start_time = time.time()
parser = optparse.OptionParser()
parser.add_option('-n', '--no-execute', dest='no_execute', default=False, action="store_true")
parser.add_option('-P', '--no-settings-pane', dest='settings_pane', default=True, action="store_false")
options, args = parser.parse_args()


def script_exit(statuscode):
    if (time.time() - start_time) > 60:
        # print elapsed time
        elapsed = time.strftime("%H:%M:%S", time.gmtime(time.time() - start_time))
        print("\n\aElapsed time: {elapsed}")
        sys.stdout.flush()

    sys.exit(statuscode)

def exec(cmd, exit_on_fail = True, do_print = True):
    if cmd != '':
        if do_print:
            print(cmd)
            sys.stdout.flush()
        if not options.no_execute:
            retval = os.system(cmd)
            if retval != 0 and exit_on_fail:
                print("fatal error: command '{}' failed".format(cmd))
                sys.stdout.flush()
                script_exit(1)
            return retval
        return None

def patch(patchfile):
    cmd = "patch -p1 -i {}".format(patchfile)
    print("\n*** -> {}".format(cmd))
    sys.stdout.flush()
    if not options.no_execute:
        retval = os.system(cmd)
        if retval != 0:
            print("fatal error: patch '{}' failed".format(patchfile))
            sys.stdout.flush()
            script_exit(1)

def enter_srcdir(_dir = None):
    if _dir == None:
        dir = "bearbrowser-{}-{}".format(version, release)
    else:
        dir = _dir
    print("cd {}".format(dir))
    sys.stdout.flush()
    if not options.no_execute:
        try:
            os.chdir(dir)
        except:
            print("fatal error: can't change to '{}' folder.".format(dir))
            sys.stdout.flush()
            script_exit(1)
        
def leave_srcdir():
    print("cd ..")
    sys.stdout.flush()
    if not options.no_execute:
        os.chdir("..")


        
#
# This is the only interesting function in this script
#


def bearbrowser_patches():

    enter_srcdir()

    # remove OpenAI integration
    exec('rm -vf toolkit/components/ml/content/backends/OpenAIPipeline.mjs')
    exec('rm -vrf toolkit/components/ml/vendor/openai')
    
    # create the right mozconfig file..
    exec('cp -v ../assets/mozconfig.new mozconfig')

    # copy branding files..
    exec("cp -r ../themes/browser .")
    # Create bearbrowser branding directory from librewolf (which already has BearBrowser identity)
    # so --with-branding=browser/branding/bearbrowser resolves correctly.
    import shutil as _shutil
    _lw_brand = Path("browser/branding/librewolf")
    _bb_brand = Path("browser/branding/bearbrowser")
    if _lw_brand.exists() and not _bb_brand.exists():
        _shutil.copytree(str(_lw_brand), str(_bb_brand))
        print(f"Created {_bb_brand} from {_lw_brand}")

    # copy the right search-config.json file
    exec('cp -v ../assets/search-config.json services/settings/dumps/main/search-config.json')

    # read lines of .txt file into 'patches'
    with open('../assets/patches.txt'.format(version), "r") as f:
        for line in f.readlines():
            patch('../'+line)

    # apply xmas.patch seperately because not all builders use this repo the same way, and
    # we don't want to disturbe those workflows.
    patch('../patches/xmas.patch')


    # vs_pack.py issue... should be temporary
    exec('cp -v ../patches/pack_vs.py build/vs/')

    # https://codeberg.org/bearbrowser/source/pulls/97#issuecomment-5654510
    # Use Python instead of sed -i with \n for macOS BSD sed compatibility.
    gkrust_file = Path("toolkit/library/rust/gkrust-features.mozbuild")
    if gkrust_file.exists():
        content = gkrust_file.read_text()
        marker = "# This must remain last."
        if marker in content and 'glean_disable_upload' not in content:
            content = content.replace(marker, 'gkrust_features += ["glean_disable_upload"]\n\n' + marker)
            gkrust_file.write_text(content)
            print(f"patched {gkrust_file}")
        else:
            print(f"note: gkrust_features glean_disable_upload already present or marker not found, skipping")
    else:
        print(f"warning: {gkrust_file} not found, skipping glean_disable_upload patch")

    # Temporary fix used with patches/rust-build.patch — rust-build.patch edits
    # encoding_rs, so its recorded cargo checksum must be updated to match.
    # Done in Python: `sed -i ''` is BSD/macOS syntax and FAILS on GNU sed (Linux
    # CI), where -i takes no separate '' argument.
    _checksum = "third_party/rust/encoding_rs/.cargo-checksum.json"
    with open(_checksum, "r") as _f:
        _c = _f.read()
    _c = _c.replace(
        "9456ca46168ef86c98399a2536f577ef7be3cdde90c0c51392d8ac48519d3fae",
        "60cd124908737068ab21c7773b3df71d00e186cd605f15bad9977232830aabc0")
    _c = _c.replace(
        "d7405d2bcf99cf9729075473c45f677630f4c1947c8ba9757db607f2025a7da2",
        "a066ad881d5a74386e666fc844f7fecbbd70021d0330c1b08a2d7a2a67437ccf")
    with open(_checksum, "w") as _f:
        _f.write(_c)

    #
    # Apply most recent `settings` repository files.
    #

    exec('mkdir -p lw')
    enter_srcdir('lw')
    exec('cp -v ../../settings/bearbrowser.cfg .')
    exec('cp -v ../../settings/distribution/policies.json .')
    exec('cp -v ../../settings/defaults/pref/local-settings.js .')
    leave_srcdir();


    
    #
    # pref-pane patches
    #

    # The pref-pane is an optional BearBrowser UI feature whose assets
    # (category-bearbrowser.svg + css/xhtml/js) are not present in the tree. It is
    # orthogonal to the browser engine and to anti-fingerprinting, so skip the
    # whole block gracefully when the assets are missing rather than hard-failing
    # the build (otherwise the patch references files that don't exist).
    if os.path.exists('../patches/pref-pane/category-bearbrowser.svg'):
        patch('../patches/pref-pane/pref-pane-small.patch')
        exec('cp ../patches/pref-pane/category-bearbrowser.svg browser/themes/shared/preferences/category-bearbrowser.svg')
        exec('cp ../patches/pref-pane/bearbrowser.css browser/themes/shared/preferences/bearbrowser.css')
        exec('cp ../patches/pref-pane/bearbrowser.inc.xhtml browser/components/preferences/bearbrowser.inc.xhtml')
        exec('cp ../patches/pref-pane/bearbrowser.js browser/components/preferences/bearbrowser.js')
    else:
        print("WARNING: pref-pane assets missing — skipping pref-pane feature "
              "(build proceeds; orthogonal to the engine + anti-fingerprinting)")
    
    # provide a script that fetches and bootstraps Nightly and some mozconfigs
    exec('cp -v ../scripts/mozfetch.sh lw/')
    exec('cp -v ../assets/mozconfig.new lw/')

    # override the firefox version
    for file in ["browser/config/version.txt", "browser/config/version_display.txt"]:
        with open(file, "w") as f:
            f.write("{}-{}".format(version,release))

    print("-> Patching appstrings.properties")
    # Python instead of `find ... -exec sed -i '' ...` — BSD/macOS sed syntax
    # fails on GNU sed (Linux CI).
    for _root, _dirs, _files in os.walk("."):
        if "appstrings.properties" in _files:
            _p = os.path.join(_root, "appstrings.properties")
            with open(_p, "r") as _f:
                _t = _f.read()
            with open(_p, "w") as _f:
                _f.write(_t.replace("Firefox", "BearBrowser"))

    # Fix StaticPrefList.yaml: move bearbrowser.* prefs to correct alphabetical position
    # (webgl-permission.patch inserts them after layout.* but they must precede bidi.*).
    # The canonical bearbrowser.* block — alphabetical order is mandatory.
    # Covers BearBlocker, BearNav, BearSponsor, runtime identity, and webgl prefs.
    pref_yaml = Path("modules/libpref/init/StaticPrefList.yaml")
    if pref_yaml.exists():
        _yaml = pref_yaml.read_text()
        _bb_block = (
            "\n#---------------------------------------------------------------------------\n"
            "# Prefs starting with \"bearbrowser.\"\n"
            "#---------------------------------------------------------------------------\n"
            "\n- name: bearbrowser.bearblocker.cosmetic.enabled\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.capture.enabled\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.clip.enabled\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.nav.keyboard.enabled\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.privacy.block_local_fonts\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.privacy.reduce_time_precision\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.runtime.agent\n  type: RelaxedAtomicBool\n"
            "  value: false\n  mirror: always\n"
            "\n- name: bearbrowser.sponsorblock.enabled\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.vault.enabled\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.webgl.prompt\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.webgl.prompt.hide\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
        )
        _bidi_marker = (
            "\n#---------------------------------------------------------------------------\n"
            "# Prefs starting with \"bidi.\"\n"
            "#---------------------------------------------------------------------------"
        )
        if "bearbrowser.webgl.prompt" in _yaml and "bidi." in _yaml:
            # Remove any existing bearbrowser.* section (misplaced or outdated) then
            # insert the canonical block immediately before bidi.*.
            _bb_section_start = (
                "\n#---------------------------------------------------------------------------\n"
                "# Prefs starting with \"bearbrowser.\"\n"
                "#---------------------------------------------------------------------------\n"
            )
            if _bb_section_start in _yaml:
                # Strip from section header to the next section header
                import re as _re
                _yaml = _re.sub(
                    r'\n#-+\n# Prefs starting with "bearbrowser\."\n#-+\n.*?(?=\n#-+\n# Prefs starting with)',
                    '',
                    _yaml,
                    flags=_re.DOTALL,
                )
            _yaml = _yaml.replace(_bidi_marker, _bb_block + _bidi_marker, 1)
            pref_yaml.write_text(_yaml)
            print(f"Fixed StaticPrefList.yaml: canonical bearbrowser.* block placed before bidi.*")

    # ── Accept-Language / Intl locale normalization ───────────────────────────
    # Patch StaticPrefList.yaml: set en-US defaults for intl prefs that control
    # both the HTTP Accept-Language header (sent before JS runs) and Intl API
    # locale output. When privacy.resistFingerprinting=true Firefox normalizes
    # these, but setting the pref defaults makes it explicit and auditable.
    _intl_yaml = Path("modules/libpref/init/StaticPrefList.yaml")
    if _intl_yaml.exists():
        import re as _ire
        _iy = _intl_yaml.read_text()
        # intl.accept_languages default → en-US, en
        _iy_new, _n = _ire.subn(
            r'(- name: intl\.accept_languages\n(?:  [^\n]+\n)*?  value: )\"[^\"]+\"',
            r'\g<1>"en-US, en"',
            _iy,
        )
        if _n:
            _iy = _iy_new
            print("-> BearBrowser locale: set intl.accept_languages default to en-US, en")
        _intl_yaml.write_text(_iy)

    # l10n locale patching skipped for dev build (--with-l10n-base removed from mozconfig)
    print("-> Skipping l10n download (dev build — en-US only)")

    # ── BearBlocker: native adblock-rust content classifier + cosmetic filtering ──
    # Step 1: Install filter lists into browser/bearblocker/
    _bb_dir = Path("browser/bearblocker")
    _bb_dir.mkdir(exist_ok=True)

    _lists_src = Path("../settings/filter-lists")
    for _list_file in ["bearblocker-ads.txt", "bearblocker-privacy.txt"]:
        _src = _lists_src / _list_file
        if _src.exists():
            _shutil.copy(str(_src), str(_bb_dir / _list_file))
            print(f"-> Installed {_list_file} to browser/bearblocker/")
        else:
            print(f"warning: {_src} not found — BearBlocker filter list missing")

    # Step 2: Create browser/bearblocker/moz.build so the build system packages the lists
    _bb_mozbuild = _bb_dir / "moz.build"
    if not _bb_mozbuild.exists():
        _bb_mozbuild.write_text(
            "# BearBlocker filter lists — packaged to dist/bin/browser/bearblocker/\n"
            "# Accessible at resource:///bearblocker/ inside the browser.\n"
            "FINAL_TARGET_FILES.bearblocker += [\n"
            '    "bearblocker-ads.txt",\n'
            '    "bearblocker-privacy.txt",\n'
            "]\n"
        )
        print("-> Created browser/bearblocker/moz.build")

    # Step 3: Install JSWindowActor files into browser/actors/
    # Source dirs: settings/bearblocker/ (BearBlocker) and settings/actors/ (BearSponsor, BearNav)
    _actor_sources = {
        "BearBlockerChild.sys.mjs":  Path("../settings/bearblocker"),
        "BearBlockerParent.sys.mjs": Path("../settings/bearblocker"),
        "BearBlockerPolicy.sys.mjs": Path("../settings/bearblocker"),
        "BearCaptureChild.sys.mjs":  Path("../settings/actors"),
        "BearCaptureParent.sys.mjs": Path("../settings/actors"),
        "BearClipChild.sys.mjs":     Path("../settings/actors"),
        "BearClipParent.sys.mjs":    Path("../settings/actors"),
        "BearNavChild.sys.mjs":      Path("../settings/actors"),
        "BearNavParent.sys.mjs":     Path("../settings/actors"),
        "BearSponsorChild.sys.mjs":  Path("../settings/actors"),
        "BearSponsorParent.sys.mjs": Path("../settings/actors"),
        "BearVaultChild.sys.mjs":    Path("../settings/actors"),
        "BearVaultParent.sys.mjs":   Path("../settings/actors"),
    }
    for _actor_file, _actors_src in _actor_sources.items():
        _src = _actors_src / _actor_file
        if _src.exists():
            _shutil.copy(str(_src), str(Path("browser/actors") / _actor_file))
            print(f"-> Installed {_actor_file} to browser/actors/")
        else:
            print(f"warning: {_src} not found — actor missing")

    # Step 4: Add browser/bearblocker to browser/moz.build DIRS
    _browser_mozbuild = Path("browser/moz.build")
    if _browser_mozbuild.exists():
        _bm = _browser_mozbuild.read_text()
        if '"bearblocker"' not in _bm:
            _bm = _bm.replace(
                '    "actors",\n    "base",',
                '    "actors",\n    "base",\n    "bearblocker",',
            )
            _browser_mozbuild.write_text(_bm)
            print("-> Added bearblocker to browser/moz.build DIRS")

    # Step 5: Add all BearBrowser actor files to browser/actors/moz.build
    _actors_mozbuild = Path("browser/actors/moz.build")
    if _actors_mozbuild.exists():
        _am = _actors_mozbuild.read_text()
        if "BearBlockerChild.sys.mjs" not in _am:
            _bear_actor_entry = (
                '\nFINAL_TARGET_FILES.actors += [\n'
                '    "BearBlockerChild.sys.mjs",\n'
                '    "BearBlockerParent.sys.mjs",\n'
                '    "BearBlockerPolicy.sys.mjs",\n'
                '    "BearCaptureChild.sys.mjs",\n'
                '    "BearCaptureParent.sys.mjs",\n'
                '    "BearClipChild.sys.mjs",\n'
                '    "BearClipParent.sys.mjs",\n'
                '    "BearNavChild.sys.mjs",\n'
                '    "BearNavParent.sys.mjs",\n'
                '    "BearSponsorChild.sys.mjs",\n'
                '    "BearSponsorParent.sys.mjs",\n'
                '    "BearVaultChild.sys.mjs",\n'
                '    "BearVaultParent.sys.mjs",\n'
                ']\n'
            )
            _am = _am.replace(
                "\nBROWSER_CHROME_MANIFESTS",
                _bear_actor_entry + "\nBROWSER_CHROME_MANIFESTS",
            )
            _actors_mozbuild.write_text(_am)
            print("-> Added BearBrowser actors to browser/actors/moz.build")

    # Step 6: Register all BearBrowser JSWindowActors in DesktopActorRegistry
    _registry = Path("browser/components/DesktopActorRegistry.sys.mjs")
    if _registry.exists():
        _reg = _registry.read_text()
        if "BearBlocker:" not in _reg:
            _bear_actor_reg = (
                '\n  BearBlocker: {\n'
                '    parent: {\n'
                '      esModuleURI: "resource:///actors/BearBlockerParent.sys.mjs",\n'
                '    },\n'
                '    child: {\n'
                '      esModuleURI: "resource:///actors/BearBlockerChild.sys.mjs",\n'
                '      events: {\n'
                '        DOMContentLoaded: {},\n'
                '        pageshow: { mozSystemGroup: true },\n'
                '      },\n'
                '    },\n'
                '    matches: ["https://*/*", "http://*/*"],\n'
                '    allFrames: true,\n'
                '    enablePreference: "bearbrowser.bearblocker.cosmetic.enabled",\n'
                '  },\n'
                '\n  BearNav: {\n'
                '    parent: {\n'
                '      esModuleURI: "resource:///actors/BearNavParent.sys.mjs",\n'
                '    },\n'
                '    child: {\n'
                '      esModuleURI: "resource:///actors/BearNavChild.sys.mjs",\n'
                '      events: {\n'
                '        keydown: { mozSystemGroup: false },\n'
                '      },\n'
                '    },\n'
                '    matches: ["https://*/*", "http://*/*"],\n'
                '    allFrames: false,\n'
                '    enablePreference: "bearbrowser.nav.keyboard.enabled",\n'
                '  },\n'
                '\n  BearSponsor: {\n'
                '    parent: {\n'
                '      esModuleURI: "resource:///actors/BearSponsorParent.sys.mjs",\n'
                '    },\n'
                '    child: {\n'
                '      esModuleURI: "resource:///actors/BearSponsorChild.sys.mjs",\n'
                '      events: {\n'
                '        DOMContentLoaded: {},\n'
                '        pageshow: { mozSystemGroup: true },\n'
                '      },\n'
                '    },\n'
                '    matches: ["https://www.youtube.com/*", "https://youtube.com/*"],\n'
                '    allFrames: false,\n'
                '    enablePreference: "bearbrowser.sponsorblock.enabled",\n'
                '  },\n'
                '\n  BearCapture: {\n'
                '    parent: {\n'
                '      esModuleURI: "resource:///actors/BearCaptureParent.sys.mjs",\n'
                '    },\n'
                '    child: {\n'
                '      esModuleURI: "resource:///actors/BearCaptureChild.sys.mjs",\n'
                '      events: {\n'
                '        DOMContentLoaded: {},\n'
                '        pageshow: { mozSystemGroup: true },\n'
                '        keydown: {},\n'
                '      },\n'
                '    },\n'
                '    matches: ["https://*/*", "http://*/*"],\n'
                '    allFrames: false,\n'
                '    enablePreference: "bearbrowser.capture.enabled",\n'
                '  },\n'
                '\n  BearClip: {\n'
                '    parent: {\n'
                '      esModuleURI: "resource:///actors/BearClipParent.sys.mjs",\n'
                '    },\n'
                '    child: {\n'
                '      esModuleURI: "resource:///actors/BearClipChild.sys.mjs",\n'
                '      events: {\n'
                '        keydown: {},\n'
                '      },\n'
                '    },\n'
                '    matches: ["https://*/*", "http://*/*"],\n'
                '    allFrames: false,\n'
                '    enablePreference: "bearbrowser.clip.enabled",\n'
                '  },\n'
                '\n  BearVault: {\n'
                '    parent: {\n'
                '      esModuleURI: "resource:///actors/BearVaultParent.sys.mjs",\n'
                '    },\n'
                '    child: {\n'
                '      esModuleURI: "resource:///actors/BearVaultChild.sys.mjs",\n'
                '      events: {\n'
                '        DOMContentLoaded: {},\n'
                '        pageshow: { mozSystemGroup: true },\n'
                '        keydown: {},\n'
                '      },\n'
                '    },\n'
                '    matches: ["https://*/*", "http://*/*"],\n'
                '    allFrames: false,\n'
                '    enablePreference: "bearbrowser.vault.enabled",\n'
                '  },\n'
            )
            _reg = _reg.replace(
                "let JSWINDOWACTORS = {",
                "let JSWINDOWACTORS = {" + _bear_actor_reg,
            )
            _registry.write_text(_reg)
            print("-> Registered BearBlocker, BearNav, BearSponsor in DesktopActorRegistry")

    # ── Engine-level fingerprinting hardening ─────────────────────────────────
    # Close two vectors that JS injection cannot cover: @font-face local() CSS
    # resolution (happens in the Gecko layout engine before JS can intercept) and
    # Web Worker performance.now() precision (workers run in a separate JS context
    # unreachable by WKUserScript / content-process injection).
    import re as _rfp_re

    # Patch 1: gfxUserFontSet.cpp — block LookupLocalFont when our pref is set.
    # @font-face { src: local('FontName') } triggers this C++ call to check whether
    # the named font is installed. Sites time the CSS rendering pipeline to infer
    # which fonts are installed, building a fingerprint. Returning nullptr forces all
    # local() entries to fail, routing the browser through the next src: candidate
    # (usually a web font URL), identical behaviour to a machine without that font.
    # The file moved gfx/src -> gfx/thebes (Firefox ~150) and the call site is now
    # gfxPlatform::GetPlatform()->LookupLocalFont(...). Try both locations so the
    # patch survives upstream churn instead of silently no-op'ing.
    _gfxufs = next((Path(p) for p in ("gfx/thebes/gfxUserFontSet.cpp",
                                      "gfx/src/gfxUserFontSet.cpp")
                    if Path(p).exists()), None)
    if _gfxufs is not None:
        _gfx = _gfxufs.read_text()
        if "BearBrowser_block_local_fonts" not in _gfx:
            # Accept either the legacy gfxPlatformFontList::PlatformFontList() or the
            # current gfxPlatform::GetPlatform() receiver for LookupLocalFont().
            _gfx_new = _rfp_re.sub(
                r'((?:gfxPlatformFontList\s*::\s*PlatformFontList'
                r'|gfxPlatform\s*::\s*GetPlatform)\s*\(\s*\)\s*->\s*'
                r'LookupLocalFont\s*\([^;]+\))',
                r'(StaticPrefs::bearbrowser_privacy_block_local_fonts()'
                r' ? nullptr /* BearBrowser_block_local_fonts */'
                r' : \1)',
                _gfx,
            )
            if _gfx_new != _gfx:
                # The bearbrowser_* accessor lives in StaticPrefs_bearbrowser.h; the
                # file only includes StaticPrefs_gfx.h, so add ours next to it.
                inc = '#include "mozilla/StaticPrefs_gfx.h"'
                if inc in _gfx_new and "StaticPrefs_bearbrowser.h" not in _gfx_new:
                    _gfx_new = _gfx_new.replace(
                        inc, inc + '\n#include "mozilla/StaticPrefs_bearbrowser.h"', 1)
                _gfxufs.write_text(_gfx_new)
                print(f"-> Patched {_gfxufs}: @font-face local() blocked by bearbrowser.privacy.block_local_fonts")
            else:
                print(f"note: {_gfxufs}: LookupLocalFont call-site not matched — font-visibility pref is the primary guard")
        else:
            print(f"note: {_gfxufs} already patched — skipping")
    else:
        print("note: gfxUserFontSet.cpp not found (tried gfx/thebes, gfx/src) — skipping local() patch")

    # Patch 2: clamp Now() to 1ms by wrapping ReduceTimePrecisionAsMSecs() in
    # std::floor(). Firefox's RFP already reduces precision when
    # privacy.resistFingerprinting=true, but the default bucket is 2ms.
    # In current Firefox the reduction lives in Performance::Now()/
    # NowUnclamped() (Performance.cpp); PerformanceWorker does NOT override
    # Now(), so dedicated/shared/service workers inherit the patched base class
    # — there is no separate ReduceTimePrecisionAsMSecs call in
    # PerformanceWorker.cpp to clamp. We still look at the worker file so the
    # patch self-heals if upstream ever reintroduces a worker-local reduction.
    for _perf_src in ["dom/performance/Performance.cpp",
                      "dom/performance/PerformanceWorker.cpp"]:
        _pf = Path(_perf_src)
        if not _pf.exists():
            print(f"note: {_perf_src} not found — skipping 1ms clamp patch")
            continue
        _pc = _pf.read_text()
        if "BearBrowser_1ms_clamp" in _pc:
            print(f"note: {_perf_src} already patched — skipping")
            continue
        _pc_new = _rfp_re.sub(
            r'(nsRFPService::ReduceTimePrecisionAsMSecs\([^;]+\))',
            r'std::floor(\1) /* BearBrowser_1ms_clamp */',
            _pc,
        )
        if _pc_new != _pc:
            _pf.write_text(_pc_new)
            print(f"-> Patched {_perf_src}: performance.now() hard-clamped to 1ms integer granularity")
        elif _perf_src.endswith("PerformanceWorker.cpp"):
            print("note: PerformanceWorker.cpp has no own reduction — workers inherit the patched Performance::Now() (expected, not a gap)")
        else:
            print(f"note: {_perf_src}: ReduceTimePrecisionAsMSecs pattern not matched — RFP pref is the fallback")

    leave_srcdir()



#
# Main functionality in this script.. which is to call bearbrowser_patches()
#

if len(args) != 2:
    sys.stderr.write('error: please specify version and release of bearbrowser source')
    sys.exit(1)
version = args[0]
release = args[1]
srcdir = "bearbrowser-{}-{}".format(version, release)
if not os.path.exists(srcdir + '/configure.py'):
    sys.stderr.write('error: folder doesn\'t look like a Firefox folder.')
    sys.exit(1)

bearbrowser_patches()

sys.exit(0) # ensure 0 exit code
