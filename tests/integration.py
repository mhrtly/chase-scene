#!/usr/bin/env python3
"""End-to-end tests against a real, silent instance of the built app.

Needs a Mac GUI session (a GitHub Actions macOS runner works). Everything runs in temporary
folders through CHASE_SCENE_STATE_DIR / CHASE_SCENE_HOME, so your real setup is never touched.
"""
import concurrent.futures
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / 'build/Chase Scene.app/Contents/MacOS/ChaseScene'
POSTER = ROOT / 'build/post-mouse'
TEST_AUDIO = os.environ.get('CHASE_SCENE_TEST_AUDIO') == '1'


class RunningAppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='chase-test-', dir='/private/tmp')
        cls.folder = pathlib.Path(cls.temp.name) / 'state'
        cls.home = pathlib.Path(cls.temp.name) / 'home'
        cls.home.mkdir()
        cls.env = dict(os.environ, CHASE_SCENE_STATE_DIR=str(cls.folder), CHASE_SCENE_HOME=str(cls.home),
                       CHASE_SCENE_NO_AUTO_LAUNCH='1', CHASE_SCENE_AUTO_LINGER='3')
        cls.folder.mkdir(mode=0o700)
        (cls.folder / 'preferences.json').write_text(json.dumps({
            'enabled': True, 'volume': 0, 'welcomed': True, 'autoDetect': False}))
        cls.log = open(pathlib.Path(cls.temp.name) / 'app.log', 'w+')
        cls.start_app()

    @classmethod
    def start_app(cls):
        cls.app = subprocess.Popen([str(BINARY)] + ([] if TEST_AUDIO else ['--test-mode']),
                                   env=cls.env, stdout=cls.log, stderr=cls.log)
        for _ in range(100):
            try:
                cls.send({'action': 'status'})
                return
            except (OSError, RuntimeError):
                if cls.app.poll() is not None:
                    cls.log.flush()
                    raise RuntimeError((pathlib.Path(cls.temp.name) / 'app.log').read_text() or 'Test app exited early')
                time.sleep(.05)
        raise RuntimeError('Test app did not start')

    @classmethod
    def tearDownClass(cls):
        cls.app.terminate()
        cls.app.wait(timeout=5)
        cls.log.close()
        cls.temp.cleanup()

    @classmethod
    def send(cls, request):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(3)
            sock.connect(str(cls.folder / 'control.sock'))
            sock.sendall((json.dumps(request) + '\n').encode())
            result = b''
            while not result.endswith(b'\n'):
                part = sock.recv(65536)
                if not part:
                    raise RuntimeError('Connection closed')
                result += part
            return json.loads(result)

    def tearDown(self):
        self.send({'action': 'clear'})
        self.send({'action': 'set_enabled', 'enabled': True})
        self.send({'action': 'credits_preview_stop'})
        self.send({'action': 'set_credits_enabled', 'enabled': False})
        self.send({'action': 'set_auto_detect', 'enabled': False})

    def run_binary(self, *args, binary=None, stdin=None, check=True):
        return subprocess.run([str(binary or BINARY), *args], input=stdin, capture_output=True, text=True,
                              env=self.env, check=check, timeout=20)

    def hook(self, client, binary=None, **event):
        result = self.run_binary('hook', client, binary=binary, stdin=json.dumps(event))
        self.assertEqual(json.loads(result.stdout), {})

    def wait_for(self, predicate, timeout=6.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.send({'action': 'status'})
            if predicate(status):
                return status
            time.sleep(.1)
        return self.send({'action': 'status'})

    def test_socket_and_state_permissions(self):
        self.assertEqual((self.folder / 'control.sock').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.folder.stat().st_mode & 0o777, 0o700)

    def test_cli_status_and_signal(self):
        status = json.loads(self.run_binary('status').stdout)
        self.assertEqual(status['app'], 'Chase Scene')
        self.assertFalse(status['auto_detect'])
        begun = json.loads(self.run_binary('signal', json.dumps({'action': 'begin', 'session_id': 'cli', 'agent': 'My AI'})).stdout)
        self.assertEqual(begun['state'], 'controlling')
        self.run_binary('signal', json.dumps({'action': 'end', 'session_id': 'cli'}))
        self.assertEqual(self.send({'action': 'status'})['state'], 'idle')
        self.assertEqual(self.run_binary('version').stdout.strip(), '1.2.0')

    def test_parallel_sessions_and_owner_isolation(self):
        def begin(i):
            return self.send({'action': 'begin', 'session_id': 'agent-%d' % i, 'agent': 'AI %d' % i, 'owner': str(i)})
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            self.assertTrue(all(x['ok'] for x in pool.map(begin, range(24))))
        self.send({'action': 'end_owner', 'owner': '4'})
        self.assertEqual(len(self.send({'action': 'status'})['sessions']), 23)

    def test_codex_hook_payloads_keep_music_between_calls(self):
        self.hook('codex', session_id='s1', turn_id='t1', hook_event_name='PreToolUse', tool_name='mcp__node_repl__js')
        self.hook('codex', session_id='s1', turn_id='t1', hook_event_name='PostToolUse', tool_name='mcp__node_repl__js')
        self.assertEqual(self.send({'action': 'status'})['state'], 'controlling')
        self.hook('codex', session_id='s1', turn_id='t1', hook_event_name='Interrupt')
        self.assertEqual(self.send({'action': 'status'})['state'], 'unknown')
        self.hook('codex', session_id='s1', turn_id='t1', hook_event_name='Stop')
        self.assertEqual(self.send({'action': 'status'})['state'], 'idle')

    def test_claude_hook_through_stable_launcher(self):
        (self.home / '.claude').mkdir(exist_ok=True)
        self.run_binary('connect', 'claude')
        launcher = self.folder / 'bin/chase-scene'
        self.assertTrue(launcher.is_symlink())
        self.hook('claude', binary=launcher, session_id='c1', hook_event_name='PreToolUse',
                  tool_name='mcp__computer-use__left_click', tool_input={'coordinate': [1, 2]})
        status = self.send({'action': 'status'})
        self.assertEqual(status['state'], 'controlling')
        self.assertEqual(status['sessions'][0]['agent'], 'Claude Code')
        self.hook('claude', binary=launcher, session_id='c1', hook_event_name='SessionEnd')
        self.assertEqual(self.send({'action': 'status'})['state'], 'idle')
        self.run_binary('disconnect', 'claude')

    def test_unrelated_and_own_mcp_tools_do_not_start(self):
        for name in ('Bash', 'mcp__github__read', 'mcp__chase-scene__control_status'):
            self.hook('codex', session_id='s1', turn_id='t1', hook_event_name='PreToolUse', tool_name=name)
        self.assertEqual(self.send({'action': 'status'})['state'], 'idle')

    def test_mute_and_stale_session_are_not_handback(self):
        self.send({'action': 'begin', 'session_id': 'stale', 'agent': 'AI', 'ttl': 1})
        self.send({'action': 'set_enabled', 'enabled': False})
        time.sleep(1.1)
        status = self.send({'action': 'status'})
        self.assertEqual(status['state'], 'unknown')
        self.assertFalse(status['enabled'])
        self.assertEqual(len(status['sessions']), 1)

    @unittest.skipUnless(TEST_AUDIO, 'Set CHASE_SCENE_TEST_AUDIO=1 to test silent real audio playback')
    def test_audio_cancellation_and_late_hook(self):
        self.hook('codex', session_id='audio', turn_id='t', hook_event_name='PreToolUse', tool_name='mcp__cua_repl__js')
        self.assertTrue(self.send({'action': 'status'})['playing'])
        self.hook('codex', session_id='audio', turn_id='t', hook_event_name='Interrupt')
        self.assertFalse(self.send({'action': 'status'})['playing'])
        self.hook('codex', session_id='audio', turn_id='t', hook_event_name='PostToolUse', tool_name='Bash')
        self.assertFalse(self.send({'action': 'status'})['playing'])
        self.hook('codex', session_id='audio', turn_id='t', hook_event_name='PreToolUse', tool_name='mcp__cua_repl__js')
        self.assertTrue(self.send({'action': 'status'})['playing'])
        self.hook('codex', session_id='audio', turn_id='t', hook_event_name='Stop')
        self.assertFalse(self.send({'action': 'status'})['playing'])

    @unittest.skipUnless(TEST_AUDIO, 'Set CHASE_SCENE_TEST_AUDIO=1 to test silent real audio playback')
    def test_audio_expiry_without_followup_request(self):
        self.assertTrue(self.send({'action': 'begin', 'session_id': 'expiry', 'ttl': 1})['playing'])
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            # Read persistence rather than making a status request that would itself expire the lease.
            if json.loads((self.folder / 'sessions.json').read_text())['expiry']['uncertain']:
                break
            time.sleep(.05)
        else:
            self.fail('The expiry timer did not run')
        self.assertFalse(self.send({'action': 'status'})['playing'])

    @unittest.skipUnless(TEST_AUDIO, 'Set CHASE_SCENE_TEST_AUDIO=1 to test silent real audio playback')
    def test_audio_overlapping_live_and_unknown_sessions(self):
        self.send({'action': 'begin', 'session_id': 'lost'})
        self.send({'action': 'unknown', 'session_id': 'lost'})
        self.assertTrue(self.send({'action': 'begin', 'session_id': 'live'})['playing'])
        result = self.send({'action': 'end', 'session_id': 'live'})
        self.assertFalse(result['playing'])
        self.assertEqual(result['state'], 'unknown')

    @unittest.skipUnless(TEST_AUDIO, 'Set CHASE_SCENE_TEST_AUDIO=1 to test silent real audio playback')
    def test_audio_restart_does_not_resume_saved_control(self):
        self.assertTrue(self.send({'action': 'begin', 'session_id': 'restart'})['playing'])
        type(self).app.terminate()
        type(self).app.wait(timeout=5)
        type(self).start_app()
        status = self.send({'action': 'status'})
        self.assertTrue(status['enabled'])
        self.assertTrue(status['audio_available'])
        self.assertFalse(status['playing'])
        self.assertEqual(status['state'], 'unknown')

    @unittest.skipUnless(TEST_AUDIO, 'Set CHASE_SCENE_TEST_AUDIO=1 to test native overlays')
    def test_credits_follow_live_control_independently_of_sound(self):
        self.send({'action': 'set_enabled', 'enabled': False})
        self.send({'action': 'set_credits_layout', 'layout': 'corner'})
        self.send({'action': 'set_credits_enabled', 'enabled': True})
        status = self.send({'action': 'begin', 'session_id': 'roll', 'task': 'Minimize windows'})
        self.assertTrue(status['credits_visible'])
        self.assertTrue(status['credits_scrolling'])
        self.assertTrue(status['credits_click_through'])
        self.assertFalse(status['playing'])
        self.assertEqual(status['credits_task'], 'Minimize windows')
        self.assertFalse(self.send({'action': 'unknown', 'session_id': 'roll'})['credits_visible'])
        self.assertFalse(self.send({'action': 'keepalive', 'session_id': 'roll'})['credits_visible'])

    @unittest.skipUnless(TEST_AUDIO, 'Set CHASE_SCENE_TEST_AUDIO=1 to test native overlays')
    def test_credits_preview_is_silent_and_stoppable(self):
        status = self.send({'action': 'credits_preview', 'task': 'App development'})
        self.assertTrue(status['credits_visible'])
        self.assertTrue(status['credits_scrolling'])
        self.assertFalse(status['playing'])
        self.assertEqual(status['state'], 'idle')
        self.assertFalse(self.send({'action': 'credits_preview_stop'})['credits_visible'])

    @unittest.skipUnless(TEST_AUDIO, 'Set CHASE_SCENE_TEST_AUDIO=1 to test native overlays')
    def test_credits_preview_automatically_stops(self):
        self.assertTrue(self.send({'action': 'credits_preview'})['credits_preview'])
        status = self.wait_for(lambda s: not s['credits_preview'], timeout=19)
        self.assertFalse(status['credits_visible'])
        self.assertFalse(status['playing'])
        self.assertEqual(status['state'], 'idle')

    @unittest.skipUnless(TEST_AUDIO, 'Set CHASE_SCENE_TEST_AUDIO=1 to test the native live roll')
    def test_live_credits_continue_past_six_and_accept_action_updates(self):
        self.send({'action': 'set_credits_layout', 'layout': 'corner'})
        self.send({'action': 'set_credits_enabled', 'enabled': True})
        self.hook('codex', session_id='live-feed', turn_id='live', hook_event_name='PreToolUse',
                  tool_name='mcp__cua_repl__js')
        initial = self.send({'action': 'status'})
        scroll_id = initial['credits_scroll_id']
        self.assertTrue(scroll_id)
        deadline = time.monotonic() + 12
        seen = set()
        while time.monotonic() < deadline:
            status = self.send({'action': 'status'})
            self.assertTrue(status['credits_scrolling'])
            self.assertGreater(status['credits_active_rows'], 0)
            self.assertLessEqual(status['credits_active_rows'], 6)
            self.assertEqual(status['credits_scroll_id'], scroll_id)
            seen.add(status['credits_last_name'])
            if status['credits_rows_emitted'] > 7:
                break
            time.sleep(.2)
        self.assertGreater(status['credits_rows_emitted'], 7)
        self.assertGreater(len(seen), 2)
        before_update = status['credits_rows_emitted']
        metadata = {'task': 'Place Safari on the left', 'credits': [
            {'role': 'Left wing coordination', 'name': 'Pat T. Placement'}]}
        self.hook('codex', session_id='live-feed', turn_id='live', hook_event_name='PreToolUse',
                  tool_name='mcp__cua_repl__js', tool_input={'code': '// chase-credits: ' + json.dumps(metadata) + '\nawait app.click(5);'})
        status = self.wait_for(lambda s: s['credits_last_name'] == 'Pat T. Placement')
        self.assertEqual(status['credits_last_task'], 'Place Safari on the left')
        self.assertEqual(status['credits_scroll_id'], scroll_id)
        self.assertGreater(status['credits_rows_emitted'], before_update)
        ended = self.send({'action': 'end_owner', 'owner': 'hook:codex:live-feed'})
        self.assertFalse(ended['credits_scrolling'])
        self.assertEqual(ended['credits_active_rows'], 0)

    def test_credit_metadata_does_not_start_control(self):
        status = self.send({'action': 'set_credits', 'task': 'Minimize windows'})
        self.assertEqual(status['state'], 'idle')
        self.assertFalse(status['playing'])
        status = self.send({'action': 'begin', 'session_id': 'topic'})
        self.assertEqual(status['credits_task'], 'Minimize windows')

    def test_stalled_client_does_not_block_other_clients(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stalled:
            stalled.connect(str(self.folder / 'control.sock'))
            stalled.sendall(b'{')
            start = time.monotonic()
            self.assertTrue(self.send({'action': 'status'})['ok'])
            self.assertLess(time.monotonic() - start, 1)

    def test_stdio_mcp_round_trip_and_disconnect(self):
        proc = subprocess.Popen([str(BINARY), 'mcp'], env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)

        def rpc(method, params=None, ident=1):
            proc.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': ident, 'method': method, 'params': params or {}}) + '\n')
            proc.stdin.flush()
            return json.loads(proc.stdout.readline())
        try:
            init = rpc('initialize', {'protocolVersion': '2025-11-25'})['result']
            self.assertEqual(init['protocolVersion'], '2025-11-25')
            self.assertEqual(init['serverInfo']['name'], 'chase-scene')
            self.assertEqual(len(rpc('tools/list')['result']['tools']), 5)
            begun = rpc('tools/call', {'name': 'begin_control', 'arguments': {'agent': 'Other AI', 'task': 'Edit a spreadsheet'}})['result']
            sid = begun['structuredContent']['session_id']
            self.assertFalse(begun['isError'])
            self.assertEqual(begun['structuredContent']['credits_task'], 'Edit a spreadsheet')
            updated = rpc('tools/call', {'name': 'set_credits', 'arguments': {'session_id': sid, 'task': 'Contract review', 'credits': [{'role': 'Legal advice', 'name': 'Dewey, Cheatham and Howe'}]}})['result']
            self.assertFalse(updated['isError'])
            self.assertEqual(updated['structuredContent']['credits_task'], 'Contract review')
            self.assertFalse(rpc('tools/call', {'name': 'keepalive', 'arguments': {'session_id': sid}})['result']['isError'])
            self.assertTrue(rpc('tools/call', {'name': 'end_control', 'arguments': {'session_id': 'someone-else'}})['result']['isError'])
            self.assertFalse(rpc('tools/call', {'name': 'end_control', 'arguments': {'session_id': sid}})['result']['isError'])
            self.assertEqual(self.send({'action': 'status'})['state'], 'idle')
            rpc('tools/call', {'name': 'begin_control', 'arguments': {'agent': 'Other AI'}})
            proc.stdin.close()
            proc.wait(timeout=5)
            self.assertEqual(self.send({'action': 'status'})['state'], 'unknown')
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)
            proc.stdout.close()
            proc.stderr.close()

    def test_connect_and_disconnect_preserve_user_settings(self):
        codex = self.home / '.codex'
        codex.mkdir(exist_ok=True)
        hooks = codex / 'hooks.json'
        original = ('{\n  "hooks": {\n    "Stop": [\n      {\n        "hooks": [\n          {\n'
                    '            "type": "command",\n            "command": "say done"\n          }\n'
                    '        ]\n      }\n    ]\n  }\n}\n')
        hooks.write_text(original)
        out = self.run_binary('connect', 'codex').stdout
        self.assertIn('/hooks', out)
        document = json.loads(hooks.read_text())
        self.assertEqual(document['hooks']['Stop'][0]['hooks'][0]['command'], 'say done')
        self.assertEqual(len(document['hooks']['Stop']), 2)
        self.assertEqual(set(document['hooks']), {'Stop', 'PreToolUse', 'PostToolUse', 'SessionEnd', 'Interrupt'})
        self.run_binary('connect', 'codex')
        self.assertEqual(len(json.loads(hooks.read_text())['hooks']['Stop']), 2, 'connect is idempotent')
        self.run_binary('disconnect', 'codex')
        self.assertEqual(hooks.read_text(), original)
        self.assertTrue(list((self.folder / 'backups').glob('*-codex/hooks.json')))
        hooks.write_text('{ broken')
        result = self.run_binary('connect', 'codex', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(hooks.read_text(), '{ broken')

    def test_mcp_config_snippet(self):
        config = json.loads(self.run_binary('mcp-config').stdout)
        server = config['mcpServers']['chase-scene']
        self.assertEqual(server['args'], ['mcp'])
        self.assertTrue(pathlib.Path(server['command']).resolve().samefile(BINARY))

    @unittest.skipIf(os.environ.get('CHASE_SCENE_SKIP_SYNTHETIC_INPUT') == '1', 'Synthetic input explicitly disabled for this test run')
    def test_synthetic_mouse_input_starts_and_ends_the_chase(self):
        self.send({'action': 'set_auto_detect', 'enabled': True})
        status = self.send({'action': 'status'})
        self.assertTrue(status['detector_running'])
        poster = subprocess.run([str(POSTER)], capture_output=True, text=True, timeout=30)
        if poster.stdout.strip() == 'no-permission':
            self.skipTest('This session may not post synthetic events (no Accessibility permission)')
        status = self.wait_for(lambda s: any(x['automatic'] for x in s['sessions']))
        automatic = [x for x in status['sessions'] if x['automatic']]
        self.assertEqual([x['agent'] for x in automatic], ['post-mouse'], status)
        self.assertEqual(status['state'], 'controlling')
        # The chase ends quietly a few seconds after the synthetic input stops (linger = 3s here).
        status = self.wait_for(lambda s: not s['sessions'], timeout=8)
        self.assertEqual(status['state'], 'idle')
        # Ignoring an app keeps it quiet.
        self.send({'action': 'ignore_app', 'app': 'post-mouse'})
        subprocess.run([str(POSTER)], capture_output=True, text=True, timeout=30)
        time.sleep(.5)
        self.assertEqual(self.send({'action': 'status'})['state'], 'idle')
        self.send({'action': 'unignore_app', 'app': 'post-mouse'})


if __name__ == '__main__':
    unittest.main(verbosity=2)
