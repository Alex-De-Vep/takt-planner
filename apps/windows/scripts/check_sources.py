#!/usr/bin/env python3
"""Source-only checks. Never invokes .NET, NuGet, MSBuild or the Windows app."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--csharp', action='store_true', help='Parse C# with installed tree-sitter packages')
args = parser.parse_args()
for pattern in ('*.xaml', '*.csproj', '*.props', '*.slnx', '*.manifest'):
    for path in root.rglob(pattern):
        ET.parse(path)
for path in root.rglob('*.csproj'):
    for ref in ET.parse(path).iter('ProjectReference'):
        assert (path.parent / ref.attrib['Include']).is_file(), f'Missing reference in {path}'
    for ref in ET.parse(path).iter('Content'):
        if '*' not in ref.attrib.get('Include', ''):
            assert (path.parent / ref.attrib['Include']).is_file(), f'Missing content in {path}'
for project in ET.parse(root / 'Takt.slnx').iter('Project'):
    assert (root / project.attrib['Path']).is_file()
events = {'Click', 'Loaded', 'SizeChanged', 'SelectionChanged', 'Tapped', 'DragOver', 'Drop', 'TextChanged', 'KeyDown',
          'DragItemsStarting', 'DragItemsCompleted', 'Toggled', 'PointerPressed', 'PointerMoved', 'PointerReleased',
          'PointerCanceled', 'PointerCaptureLost', 'DragStarted', 'DragDelta', 'DragCompleted', 'Paste', 'ItemClick', 'CalendarViewDayItemChanging', 'SelectedDatesChanged'}
handlers = set()
for path in (root / 'src/Takt.Windows').rglob('*.xaml'):
    xaml = ET.parse(path)
    class_name = xaml.getroot().attrib.get('{http://schemas.microsoft.com/winfx/2006/xaml}Class', '').split('.')[-1]
    code = '\n'.join(p.read_text() for p in path.parent.glob(class_name + '*.cs'))
    for node in xaml.iter():
        for key, value in node.attrib.items():
            if key not in events:
                continue
            handlers.add((class_name, value))
            assert re.search(r'\b' + re.escape(value) + r'\s*\(', code), f'Missing handler: {class_name}.{value}'
html = (root / 'design/task-workspace.html').read_text()
assert not any(tag in html.lower() for tag in ('<!doctype', '<html', '<body'))
ids = re.findall(r'\bid="([^"]+)"', html)
assert len(ids) == len(set(ids)), 'Duplicate preview IDs'
script = re.search(r'<script>(.*?)</script>', html, re.S).group(1)
for reference in re.findall(r"q\('([^']+)'\)", script):
    assert reference in ids, f'Missing preview element: {reference}'
assert not re.search(r'\b(fetch|XMLHttpRequest|WebSocket)\s*\(', script), 'Preview must stay offline'
if shutil.which('node'):
    with tempfile.TemporaryDirectory(prefix='takt-source-check-') as directory:
        path = Path(directory) / 'preview.js'
        path.write_text(script)
        subprocess.run(['node', '--check', str(path)], check=True)
if args.csharp:
    from tree_sitter import Language, Parser
    import tree_sitter_c_sharp
    grammar = Parser(Language(tree_sitter_c_sharp.language()))
    for path in root.rglob('*.cs'):
        tree = grammar.parse(path.read_bytes())
        assert not tree.root_node.has_error, f'C# syntax issue in {path}'
print(f'Parsed project/XAML XML, checked {len(handlers)} handlers and preview references.'
      + (' Parsed C# syntax.' if args.csharp else ''))
print('No restore, build, .NET tests or native application launch performed.')
