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

    # Temporary fix used with patches/rust-build.patch
    exec("sed -i '' 's/9456ca46168ef86c98399a2536f577ef7be3cdde90c0c51392d8ac48519d3fae/60cd124908737068ab21c7773b3df71d00e186cd605f15bad9977232830aabc0/g' third_party/rust/encoding_rs/.cargo-checksum.json")
    exec("sed -i '' 's/d7405d2bcf99cf9729075473c45f677630f4c1947c8ba9757db607f2025a7da2/a066ad881d5a74386e666fc844f7fecbbd70021d0330c1b08a2d7a2a67437ccf/g' third_party/rust/encoding_rs/.cargo-checksum.json")

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

    # 1) patch it in
    patch('../patches/pref-pane/pref-pane-small.patch')
    # 2) new files
    exec('cp ../patches/pref-pane/category-bearbrowser.svg browser/themes/shared/preferences/category-bearbrowser.svg')
    exec('cp ../patches/pref-pane/bearbrowser.css browser/themes/shared/preferences/bearbrowser.css')
    exec('cp ../patches/pref-pane/bearbrowser.inc.xhtml browser/components/preferences/bearbrowser.inc.xhtml')
    exec('cp ../patches/pref-pane/bearbrowser.js browser/components/preferences/bearbrowser.js')
    
    # provide a script that fetches and bootstraps Nightly and some mozconfigs
    exec('cp -v ../scripts/mozfetch.sh lw/')
    exec('cp -v ../assets/mozconfig.new lw/')

    # override the firefox version
    for file in ["browser/config/version.txt", "browser/config/version_display.txt"]:
        with open(file, "w") as f:
            f.write("{}-{}".format(version,release))

    print("-> Patching appstrings.properties")
    exec("find . -path '*/appstrings.properties' -exec sed -i '' 's/Firefox/BearBrowser/g' {} \\;")

    # Fix StaticPrefList.yaml: move bearbrowser.* prefs to correct alphabetical position
    # (webgl-permission.patch inserts them after layout.* but they must precede bidi.*).
    # The canonical bearbrowser.* block includes BearBlocker prefs + webgl prefs in order.
    pref_yaml = Path("modules/libpref/init/StaticPrefList.yaml")
    if pref_yaml.exists():
        _yaml = pref_yaml.read_text()
        _bb_block = (
            "\n#---------------------------------------------------------------------------\n"
            "# Prefs starting with \"bearbrowser.\"\n"
            "#---------------------------------------------------------------------------\n"
            "\n- name: bearbrowser.bearblocker.cosmetic.enabled\n  type: RelaxedAtomicBool\n"
            "  value: true\n  mirror: always\n"
            "\n- name: bearbrowser.runtime.agent\n  type: RelaxedAtomicBool\n"
            "  value: false\n  mirror: always\n"
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
    _actors_src = Path("../settings/bearblocker")
    for _actor_file in [
        "BearBlockerChild.sys.mjs",
        "BearBlockerParent.sys.mjs",
        "BearBlockerPolicy.sys.mjs",
    ]:
        _src = _actors_src / _actor_file
        if _src.exists():
            _shutil.copy(str(_src), str(Path("browser/actors") / _actor_file))
            print(f"-> Installed {_actor_file} to browser/actors/")
        else:
            print(f"warning: {_src} not found — BearBlocker actor missing")

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

    # Step 5: Add BearBlocker actor files to browser/actors/moz.build
    _actors_mozbuild = Path("browser/actors/moz.build")
    if _actors_mozbuild.exists():
        _am = _actors_mozbuild.read_text()
        if "BearBlockerChild.sys.mjs" not in _am:
            _bb_actor_entry = (
                '\nFINAL_TARGET_FILES.actors += [\n'
                '    "BearBlockerChild.sys.mjs",\n'
                '    "BearBlockerParent.sys.mjs",\n'
                '    "BearBlockerPolicy.sys.mjs",\n'
                ']\n'
            )
            _am = _am.replace(
                "\nBROWSER_CHROME_MANIFESTS",
                _bb_actor_entry + "\nBROWSER_CHROME_MANIFESTS",
            )
            _actors_mozbuild.write_text(_am)
            print("-> Added BearBlocker actors to browser/actors/moz.build")

    # Step 6: Register BearBlocker JSWindowActor in DesktopActorRegistry
    _registry = Path("browser/components/DesktopActorRegistry.sys.mjs")
    if _registry.exists():
        _reg = _registry.read_text()
        if "BearBlocker:" not in _reg:
            _bb_actor_reg = (
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
            )
            _reg = _reg.replace(
                "let JSWINDOWACTORS = {",
                "let JSWINDOWACTORS = {" + _bb_actor_reg,
            )
            _registry.write_text(_reg)
            print("-> Registered BearBlocker in DesktopActorRegistry")

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
