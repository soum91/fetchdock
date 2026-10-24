import json
import plistlib
from pathlib import Path
import sys

app = Path(sys.argv[1])
build = sys.argv[2]
expected = '1.1.0.' + build
bundles = {app: 'com.soum91.fetchdock',
           app / 'PlugIns/FetchDockActivity.appex': 'com.soum91.fetchdock.activity',
           app / 'PlugIns/FetchDockShare.appex': 'com.soum91.fetchdock.share',
           app / 'PlugIns/FetchDockSafari.appex': 'com.soum91.fetchdock.safari'}
for path, identifier in bundles.items():
    info = plistlib.loads((path / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == identifier
    assert info['CFBundleVersion'] == build
    assert info['CFBundleShortVersionString'] == expected
    print('Verified', identifier, expected)
manifest = json.loads((app / 'PlugIns/FetchDockSafari.appex/manifest.json').read_text())
assert manifest['manifest_version'] == 3
assert manifest['action']['default_popup'] == 'popup.html'
assert (app / 'PlugIns/FetchDockSafari.appex/popup.html').is_file()
print('Verified Safari resources')
