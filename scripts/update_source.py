import datetime
import json
import os
from pathlib import Path

build = os.environ['BUILD_NUMBER']
root = Path(__file__).resolve().parent.parent
path = root / 'source.json'
source = json.loads(path.read_text())
app = source['apps'][0]
version = {
    'version': f'1.0.0.{build}', 'buildVersion': build,
    'date': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d'),
    'localizedDescription': 'Native iOS downloads, queue, pause/resume, browser and Live Activities.',
    'downloadURL': f'https://github.com/soum91/fetchdock/releases/download/build-{build}/FetchDock-1.0.0-build-{build}.ipa',
    'size': (root / 'build' / f'FetchDock-1.0.0-build-{build}.ipa').stat().st_size,
    'minOSVersion': '18.0'
}
app['versions'] = [version] + [v for v in app.get('versions', []) if v['buildVersion'] != build]
app.update(version=version['version'], versionDate=version['date'], versionDescription=version['localizedDescription'], downloadURL=version['downloadURL'], size=version['size'])
path.write_text(json.dumps(source, indent=2) + '\n')
