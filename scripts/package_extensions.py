"""Package the shared companion scripts for Safari and Gecko-based Reynard."""
import json
from pathlib import Path
import shutil
import zipfile

root = Path(__file__).resolve().parent.parent
common = root / 'Extensions/Companion'
safari = root / 'FetchDockSafari/Resources'
reynard = root / 'build/ReynardExtension'
for path in (safari, reynard):
    path.mkdir(parents=True, exist_ok=True)
    for source in common.iterdir():
        if source.is_file():
            shutil.copy2(source, path / source.name)
    shutil.copy2(root / 'FetchDock/Assets.xcassets/AppIcon.appiconset/AppIcon.png', path / 'icon.png')
manifest = {
    'name': 'FetchDock Companion', 'version': '1.1.0',
    'description': 'Send HTTPS file links from this browser to FetchDock on the same iPhone or iPad.',
    'icons': {'128': 'icon.png'}, 'permissions': ['activeTab', 'storage'],
    'content_scripts': [{'matches': ['https://*/*'], 'js': ['core.js', 'content.js'], 'run_at': 'document_idle', 'all_frames': False}],
    'content_security_policy': {'extension_pages': "script-src 'self'; object-src 'none'"}
}
safari_manifest = {**manifest, 'manifest_version': 3, 'host_permissions': ['https://*/*'], 'action': {'default_popup': 'popup.html', 'default_icon': 'icon.png', 'default_title': 'FetchDock'}}
(safari / 'manifest.json').write_text(json.dumps(safari_manifest, indent=2) + '\n')
# GeckoView's browserAction API is already implemented by the Reynard fork.
gecko = {**manifest, 'manifest_version': 2, 'permissions': ['activeTab', 'storage', 'https://*/*'],
         'browser_action': {'default_popup': 'popup.html', 'default_icon': 'icon.png', 'default_title': 'FetchDock'},
         'browser_specific_settings': {'gecko': {'id': 'fetchdock@soum91', 'strict_min_version': '109.0'}},
         'content_security_policy': "script-src 'self'; object-src 'none'"}
(reynard / 'manifest.json').write_text(json.dumps(gecko, indent=2) + '\n')
with zipfile.ZipFile(root / 'build/FetchDock-Reynard.xpi', 'w', zipfile.ZIP_DEFLATED) as package:
    for path in sorted(reynard.iterdir()):
        package.write(path, path.name)
print('Safari resources and build/FetchDock-Reynard.xpi are ready')
