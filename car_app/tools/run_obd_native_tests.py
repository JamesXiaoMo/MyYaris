#!/usr/bin/env python3
"""Run the JVM-only journal/storage checks with the cached Gradle Kotlin compiler.
No Android device, network, app startup or signing material is accessed.
"""
from pathlib import Path
import argparse
import re
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
artifacts = {
    'org.jetbrains.kotlin': ['kotlin-compiler-embeddable', 'kotlin-stdlib', 'kotlin-reflect', 'kotlin-script-runtime', 'kotlin-daemon-embeddable'],
    'org.jetbrains.kotlinx': ['kotlinx-coroutines-core-jvm'],
    'org.jetbrains': ['annotations'],
    'org.jetbrains.intellij.deps': ['trove4j'],
}
jars = []
for group, names in artifacts.items():
    for name in names:
        folder = cache / group / name
        if not folder.is_dir():
            continue
        versions = sorted(folder.iterdir(), key=lambda p: tuple(int(x) for x in re.findall(r'\d+', p.name)), reverse=True)
        found = list(versions[0].rglob('*.jar'))
        jars.extend(p for p in found if not p.name.endswith(('-sources.jar', '-javadoc.jar')))
assert any(p.name.startswith('kotlin-compiler-embeddable') for p in jars), 'Cached Kotlin compiler not available'
stdlib = next(p for p in jars if p.name.startswith('kotlin-stdlib-'))
annotations = [p for p in jars if p.name.startswith('annotations-')]
java = shutil.which('java')
assert java, 'JDK not available'
args.output.mkdir(parents=True, exist_ok=True)
jar = args.output.resolve() / 'obd-native-checks.jar'
source = root / 'android/app/src/main/kotlin/com/myyaris/my_yaris/ObdTransportStore.kt'
test = root / 'test/native/ObdTransportStoreChecks.kt'
subprocess.run([java, '-cp', ':'.join(map(str, jars)), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', ':'.join(map(str, [stdlib, *annotations])),
                '-d', str(jar), str(source), str(test)], check=True)
subprocess.run([java, '-cp', ':'.join(map(str, [jar, stdlib])), 'com.myyaris.my_yaris.ObdTransportStoreChecksKt'], check=True)
