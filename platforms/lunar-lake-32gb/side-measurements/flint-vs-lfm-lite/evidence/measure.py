#!/usr/bin/env python3
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request


class GuardStop(Exception):
    pass


def clock():
    return subprocess.check_output(['date', '-Iseconds'], text=True).strip()


def memory():
    values = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        fields = line.split()
        if fields[0].rstrip(':') in {'MemAvailable', 'GPUActive', 'GPUReclaim', 'SwapFree'}:
            values[fields[0].rstrip(':')] = int(fields[1]) * 1024
    return values


def disk_free():
    values = os.statvfs(Path.home())
    return values.f_bavail * values.f_frsize


def digest(path):
    value = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def clean(text):
    hostname = os.uname().nodename
    if hostname:
        text = text.replace(hostname, '[HOST-REDACTED]')
    text = re.sub(r'(?i)(?<![0-9a-f])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f])', '[MAC-REDACTED]', text)
    text = re.sub(r'(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '[UUID-REDACTED]', text)
    if re.search(r'(?i)(serial number|machine-id|deviceUUID|driverUUID|pipelineCacheUUID)\s*[:=]', text):
        return '[IDENTIFIER-LINE-REDACTED]\n'
    return text


class Measurement:
    def __init__(self, work):
        self.work = work
        self.evidence = work / 'evidence'
        self.bin = work / 'llama.cpp/build-vulkan/bin'
        self.state_path = self.evidence / 'measurement-state.json'
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}
        self.log = self.evidence / 'measurement-status.txt'
        self.child = None

    def report(self, message):
        line = f'{clock()} {message}'
        print(line, flush=True)
        with self.log.open('a') as stream:
            stream.write(clean(line) + '\n')

    def save(self):
        temporary = self.state_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.state, indent=2) + '\n')
        temporary.replace(self.state_path)

    def guard(self, label, required):
        values = memory()
        available = values['MemAvailable']
        free = disk_free()
        self.report(f'guard {label}: MemAvailable={available} bytes need={required * 1024**3}; disk={free} bytes')
        if available < required * 1024**3:
            raise GuardStop(f'MemAvailable below {required} GiB before {label}; owner action required')
        if free < 5 * 1024**3:
            raise GuardStop(f'disk below 5 GiB remaining reserve before {label}; owner chooses cleanup')

    def telemetry(self, process, label, stop):
        with (self.evidence / 'telemetry.jsonl').open('a') as stream:
            while not stop.is_set():
                record = {'time': clock(), 'stage': label, 'memory': memory(), 'disk_free': disk_free()}
                try:
                    for line in Path(f'/proc/{process.pid}/status').read_text().splitlines():
                        fields = line.split()
                        if fields[0] in {'VmRSS:', 'VmSwap:'}:
                            record[fields[0].rstrip(':')] = int(fields[1]) * 1024
                except OSError:
                    pass
                record['memory_pressure'] = Path('/proc/pressure/memory').read_text().strip()
                stream.write(json.dumps(record) + '\n')
                stream.flush()
                (self.work / 'live-status.json').write_text(json.dumps(record, indent=2) + '\n')
                stop.wait(10)

    def launch(self, arguments, label, output):
        self.report(f'start {label}')
        with (self.evidence / 'commands.jsonl').open('a') as stream:
            stream.write(json.dumps({'time': clock(), 'stage': label, 'argv': arguments}) + '\n')
        process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, start_new_session=True)
        self.child = process
        stop = threading.Event()
        monitor = threading.Thread(target=self.telemetry, args=(process, label, stop), daemon=True)
        monitor.start()

        def capture():
            with output.open('w') as stream:
                for line in process.stdout:
                    line = clean(line)
                    stream.write(line)
                    stream.flush()
                    print(line, end='', flush=True)

        reader = threading.Thread(target=capture, daemon=True)
        reader.start()
        return process, stop, monitor, reader

    def finish(self, launched, label):
        process, stop, monitor, reader = launched
        result = process.wait()
        reader.join()
        stop.set()
        monitor.join()
        self.child = None
        self.report(f'end {label}: exit={result}')
        return result

    def run(self, arguments, label, output):
        return self.finish(self.launch(arguments, label, output), label)

    def stop_server(self, launched, label):
        process = launched[0]
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                raise GuardStop('owned server did not stop after SIGTERM; no replacement server started')
        return self.finish(launched, label)

    def benchmark(self, label, model, required):
        key = label + '-bench'
        if key in self.state:
            self.report(f'skip recorded {key}: exit={self.state[key]["exit"]}')
            return
        self.guard(key, required)
        started = clock()
        arguments = [str(self.bin / 'llama-bench'), '-m', str(model), '-ngl', '99', '-fa', '1', '-ctk', 'q8_0', '-ctv', 'q8_0', '-b', '2048', '-ub', '512', '-t', '4', '-r', '3', '-p', '512', '-n', '128', '-d', '0,16384', '-o', 'md']
        result = self.run(arguments, key, self.evidence / (key + '.log'))
        self.state[key] = {'start': started, 'end': clock(), 'exit': result}
        self.save()

    def tools(self, label, model, required, sampling, repositories):
        key = label + '-tools'
        if key in self.state:
            self.report(f'skip recorded {key}')
            return
        self.guard(key, required)
        helper = self.evidence / 'check_sampling.sh'
        result = self.run(['bash', str(helper), str(model), *repositories], label + '-sampling', self.evidence / (label + '-sampling.log'))
        if result:
            raise GuardStop('sampling helper failed; no server started')
        self.guard(key, required)
        with socket.socket() as endpoint:
            endpoint.bind(('127.0.0.1', 18081))
        arguments = [str(self.bin / 'llama-server'), '-m', str(model), '--host', '127.0.0.1', '--port', '18081', '--alias', label, '-ngl', '99', '-fa', 'on', '-ctk', 'q8_0', '-ctv', 'q8_0', '-b', '2048', '-ub', '512', '-t', '4', '-np', '1', '-c', '16384', '--jinja', '--metrics', *sampling]
        started = clock()
        launched = self.launch(arguments, label + '-server', self.evidence / (label + '-server.log'))
        outcomes = {'start': started}
        ready = False
        try:
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                if launched[0].poll() is not None:
                    break
                try:
                    with urllib.request.urlopen('http://127.0.0.1:18081/health', timeout=3) as response:
                        ready = response.status == 200
                    if ready:
                        break
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(2)
            if not ready:
                outcomes['server'] = 'failed to become healthy'
                self.report(label + ': server did not become healthy; tool modes unavailable')
            else:
                with urllib.request.urlopen('http://127.0.0.1:18081/props', timeout=10) as response:
                    properties = json.load(response)
                (self.evidence / (label + '-props.json')).write_text(clean(json.dumps(properties, indent=2)) + '\n')
                parameters = properties.get('default_generation_settings', {}).get('params', {})
                expected = {'temperature': 1.0, 'top_p': 0.95, 'top_k': 20} if label == 'Flint' else {'temperature': 0.1, 'top_k': 50, 'repeat_penalty': 1.05}
                for name, value in expected.items():
                    if name not in parameters or abs(float(parameters[name]) - value) > 0.0001:
                        raise GuardStop(f'{label}: effective sampling mismatch for {name}')
                for mode, count in [('probe', 10), ('agentic', 3)]:
                    probe_label = label + '-' + mode
                    probe = [str(Path('/usr/bin/python3')), str(self.evidence / 'probe_toolcalls.py'), mode, probe_label, str(self.evidence / (label + '-tool-results.txt')), '--url', 'http://127.0.0.1:18081', '--n', str(count)]
                    outcomes[mode] = self.run(probe, probe_label, self.evidence / (probe_label + '-console.log'))
        finally:
            outcomes['server_exit'] = self.stop_server(launched, label + '-server')
        outcomes['end'] = clock()
        self.state[key] = outcomes
        self.save()

    def execute(self):
        if not (self.evidence / 'prepared.txt').exists():
            raise GuardStop('preparation has not completed')
        subprocess.run(['sha256sum', '-c', str(self.evidence / 'binaries.sha256')], check=True)
        subprocess.run(['sha256sum', '-c', str(self.evidence / 'suite-tools.sha256')], check=True)
        for label, model, required, expected_hash, sampling, repositories in [
            ('Flint', self.work / 'models/RecursiveSI_flint-Q3_K_M.gguf', 26, '1d6d5800dbed15e60c6ca8b3af9f131a5570bae3f1b85a552632930dc033a7ea', ['--temp', '1.0', '--top-p', '0.95', '--top-k', '20'], ['bartowski/RecursiveSI_flint-GGUF', 'RecursiveSI/flint']),
            ('LFM', Path.home() / 'm4c/LFM2.5-24B-A2B-CAL-Q4_K_M.gguf', 18, 'd3334405b96228eb9908cdebb5c6194908f2da64282bda852afc3a3910c64e7d', ['--temp', '0.1', '--top-k', '50', '--repeat-penalty', '1.05'], ['LiquidAI/LFM2.5-24B-A2B-GGUF'])]:
            self.report('verify model ' + label)
            if digest(model) != expected_hash:
                raise GuardStop(label + ' model hash mismatch')
            self.benchmark(label, model, required)
            self.tools(label, model, required, sampling, repositories)
        self.report('MEASUREMENTS FINISHED; failures remain recorded; identifier review and publication are separate')
        (self.evidence / 'measurement-finished.txt').write_text(clock() + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('work', type=Path)
    arguments = parser.parse_args()
    measurement = Measurement(arguments.work.resolve())
    with (measurement.work / 'measurement.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        measurement.report('measurement/resume begins')
        try:
            measurement.execute()
        except GuardStop as error:
            measurement.report('STOP: ' + str(error))
            return 75
        except (KeyboardInterrupt, BaseException) as error:
            if measurement.child and measurement.child.poll() is None:
                os.killpg(measurement.child.pid, signal.SIGTERM)
            measurement.report('INTERRUPTED/ERROR: ' + type(error).__name__ + ': ' + str(error))
            raise
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
