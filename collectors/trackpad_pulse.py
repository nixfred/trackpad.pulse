#!/usr/bin/env python3
"""Trackpad Pulse: touchpad telemetry recorder, seven days of history, no root.

Reads the touchpad's own event node when the user may open it, falls back to
the compositor's cursor when they may not, and records what the fingers did:
touches, taps, clicks, scrolls, swipes, pinches, rejected palms, distance,
speed, and the time-weighted distribution of finger speed that the pointer-
feel editor draws under its acceleration curve.

Settings never come through here. They are David Fano's trackpads.py, which
this plugin ships with its device detection widened to every Mac.

Files
  $XDG_STATE_HOME/trackpad-pulse/snapshot.json   counters, device facts, access
  $XDG_STATE_HOME/trackpad-pulse/history.json    1h / 24h / 7d buckets
  $XDG_STATE_HOME/trackpad-pulse/history.sqlite3 one row per minute, 7 days
  $XDG_STATE_HOME/trackpad-pulse/today.json      today's counters, survives restarts
  $XDG_RUNTIME_DIR/trackpad-pulse/live.json      finger positions, tmpfs, 20 Hz
"""
import argparse
import array
import configparser
import hashlib
import random
import sys
import fcntl
import glob
import json
import math
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import socket
import sqlite3
import struct
import subprocess
import time
from collections import deque

STATE = Path(os.environ.get('XDG_STATE_HOME') or str(Path.home() / '.local/state')) / 'trackpad-pulse'
RUNTIME = Path(os.environ.get('XDG_RUNTIME_DIR') or ('/run/user/' + str(os.getuid()))) / 'trackpad-pulse'
LINKS = {'repo': 'https://github.com/nixfred/trackpad.pulse',
         'author': 'https://nixfred.com',
         'plugins': 'https://omarchy.nixfred.com',
         'upstream': 'https://github.com/davefano/omarchy-trackpad-plus',
         'origin': 'https://github.com/awkent01/omarchy-touchpad-widget'}
UNIT_NAME = 'trackpad-pulse.service'
PLUGIN_ROOT = Path(__file__).resolve().parent.parent
GESTURES_LUA = Path(os.environ.get('XDG_STATE_HOME') or str(Path.home() / '.local/state')) / 'omarchy/toggles/hypr/zz-trackpad-pulse-gestures.lua'
HINT_INTERVAL = 600
AUTO_OFF_MARKER = 'auto-off'
# Stray touches: a touch that looks accidental and moved the cursor. A brush is
# a brief, short touch on a pad that sat idle; a rest is a slow, short drift
# that began in the thumb strip at the bottom or the palm strips at the sides.
STRAY_GUARD_MARKER = 'stray-guard'
# Left by Stop the recorder, so the panel's start-on-load leaves a stopped
# recorder stopped. Start the recorder removes it.
RECORDER_STOPPED_MARKER = 'recorder-stopped'
STRAY_BRUSH_S = 0.25
STRAY_BRUSH_MM = 4.0
STRAY_COLD_S = 2.0
STRAY_REST_MM = 10.0
STRAY_REST_MM_S = 15.0
STRAY_EDGE = 0.08
STRAY_BOTTOM = 0.85
STRAY_CURSOR_PX = 2.0
STRAY_HOLD = 0.3           # the guard waits this long after the finger lifts
STRAY_DRIFT_PX = 4.0       # cursor moved this much after the lift: a mouse is driving, leave it
STRAY_REGRET_S = 1.0       # a real move this soon after a put-back means the guard was wrong
STRAY_REGRET_MM = 4.0
AUTO_OFF_AFTER = 15.0      # seconds of continuous mouse motion before the pad goes off
AUTO_OFF_MIN = 5.0         # seconds the pad stays off before a touch may bring it back
MOUSE_GAP = 3.0            # seconds without cursor motion that end a mouse streak
DELIBERATE_MM = 10.0       # a touch that moves this far, or a tap, is a request for the pad
APPS_KEPT = 40
# Where the fingers land, as a coarse grid over the pad, kept per day.
HEAT_W, HEAT_H = 32, 20

# Omarchy removes users from the `input` group on purpose (migration
# 1787865477: membership lets any process keylog). This rule grants the
# logged-in seat read access to touchpad nodes only, through logind's uaccess
# ACLs, and never touches a keyboard node. It is the one thing here that needs
# root, once, and it is offered, never required.
UDEV_RULE_PATH = Path('/etc/udev/rules.d/70-trackpad-pulse.rules')
UDEV_RULE = ('# Trackpad Pulse: let the active seat read its own touchpad. Keyboards stay root:input.\n'
             'SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHPAD}=="1", TAG+="uaccess"\n')

# ---- evdev ----------------------------------------------------------------
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
SYN_REPORT = 0
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT, ABS_MT_TOUCH_MAJOR = 0x2f, 0x30
ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
ABS_MT_TOOL_TYPE, ABS_MT_TRACKING_ID, ABS_MT_PRESSURE = 0x37, 0x39, 0x3a
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
BTN_TOOL_FINGER, BTN_TOUCH = 0x145, 0x14a
BTN_TOOL_PEN = 0x140
BTN_TOOL_DOUBLETAP, BTN_TOOL_TRIPLETAP, BTN_TOOL_QUADTAP, BTN_TOOL_QUINTTAP = 0x14d, 0x14e, 0x14f, 0x148
MT_TOOL_PALM = 2
INPUT_PROP_POINTER, INPUT_PROP_DIRECT = 0, 1
EVENT = struct.Struct('@qqHHi')
CLOCK_MONOTONIC = 1


def _ioc(direction, nr, size):
    return (direction << 30) | (size << 16) | (ord('E') << 8) | nr


def EVIOCGNAME(n): return _ioc(2, 0x06, n)
def EVIOCGID(): return _ioc(2, 0x02, 8)
def EVIOCGABS(code): return _ioc(2, 0x40 + code, 24)
def EVIOCSCLOCKID(): return _ioc(1, 0xa0, 4)


# The speed histogram: how much time the fingers spent at each speed, in
# 5 mm/s bins up to 150 mm/s and one bin for everything faster. libinput's
# custom curve runs 0..4.2 device units per millisecond, and touchpad deltas
# are normalized to 1000 dpi, so one unit per ms is 25.4 mm/s: the whole
# curve editor spans the first 21 bins. Everything past that lands on the
# curve's flat tail, which is exactly what the last bin says.
BIN_MM_S = 5.0
BINS = 30
MM_PER_UNIT_MS = 25.4
REST_MM_S = 2.0          # slower than this is a finger resting, not moving
TAP_SECONDS = 0.25
TAP_MM = 3.0
SWIPE_MM = 8.0
PINCH_MM = 6.0
LIVE_INTERVAL = 1 / 20
RETENTION = 7 * 86400

COUNTERS = ('touches', 'taps', 'taps2', 'taps3', 'clicks', 'rightClicks', 'moves', 'scrolls', 'pinches',
            'swipes3', 'swipes4', 'palms', 'distance', 'scroll', 'active', 'moving', 'frames',
            'longMoves', 'corrections', 'restrokes', 'scrollCorrections', 'scrollRestrokes',
            'strays', 'strayReverts', 'strayRegrets')

# A wrong curve leaves fingerprints. An overshoot is a move followed at once by
# a short move back the other way; a re-stroke is a long move followed at once
# by another in the same direction, because the first ran out of pad. The
# optimizer reads their rates per speed band; nothing here changes a setting.
CORRECTION_GAP = 0.45      # s between lift and the correcting touch
CORRECTION_MAX_MM = 4.0    # the correction itself is short
LONG_MOVE_MM = 6.0         # a move worth judging
RESTROKE_GAP = 0.6
SCROLL_GAP = 0.6
SCROLL_LONG_MM = 10.0
OPTIMIZE_LOG = 'optimize-log.json'
# Gain nudges per pass, so the loop converges instead of lurching.
NUDGE_DOWN = 0.92
NUDGE_UP = 1.10
# One change a pass. The next pass judges it once it has seen this much, and
# undoes it when the rate it was meant to lower rose by WORSE_BY or the
# opposite fingerprint crossed its own trigger.
JUDGE_MOVES = 150
JUDGE_SECONDS = 180
WORSE_BY = 0.05
HELPED_BY = 0.02
METRIC_NAMES = {'correctionRate': ('overshoot corrections', 'long moves'), 'restrokeRate': ('re-strokes', 'long moves'),
                'fastCorrectionRate': ('overshoots after fast moves', 'fast moves'), 'slowCorrectionRate': ('corrections after slow moves', 'slow moves'),
                'scrollReversalRate': ('scroll reversals', 'scrolls'), 'scrollRestrokeRate': ('repeated scrolls', 'scrolls')}


def zero_counters():
    return {k: 0 for k in COUNTERS}


def read(path):
    try:
        return Path(path).read_text(errors='replace')
    except (OSError, ValueError):
        return ''


def atomic(directory, name, value):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / name
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, separators=(',', ':'), ensure_ascii=True))
    tmp.replace(path)


def bit(words, index):
    """Test one bit of a /proc/bus/input/devices bitmap ("e520 10000 0 0")."""
    parts = words.split()
    parts.reverse()
    word, offset = divmod(index, 64)
    if word >= len(parts):
        return False
    try:
        return (int(parts[word], 16) >> offset) & 1 == 1
    except ValueError:
        return False


def parse_devices(text):
    """Touchpads from /proc/bus/input/devices: multitouch, indirect, with an event node.

    Readable by everyone, so discovery always works even when the node does
    not open; the panel can then say which pad it cannot read and why.
    """
    pads = []
    for block in text.split('\n\n'):
        fields = {}
        for line in block.splitlines():
            if len(line) > 3 and line[1:3] == ': ':
                key, _, value = line[3:].partition('=')
                fields[line[0] + ':' + key] = value
        name = fields.get('N:Name', '').strip('"')
        handlers = fields.get('H:Handlers', '').split()
        node = next((h for h in handlers if h.startswith('event')), None)
        abs_bits = fields.get('B:ABS', '')
        if not node or not abs_bits:
            continue
        multitouch = bit(abs_bits, ABS_MT_SLOT) and bit(abs_bits, ABS_MT_POSITION_X)
        single = bit(abs_bits, ABS_X) and bit(abs_bits, ABS_Y) and bit(fields.get('B:KEY', ''), BTN_TOOL_FINGER)
        pointer = bit(fields.get('B:PROP', ''), INPUT_PROP_POINTER)
        direct = bit(fields.get('B:PROP', ''), INPUT_PROP_DIRECT)
        named = re.search(r'touchpad|trackpad', name, re.I) is not None
        # udev's own test for a touchpad: a finger tool, no pen, not a screen.
        # It finds pads that set no pointer property and name no touchpad,
        # like the Intel MacBook's bcm5974.
        keys = fields.get('B:KEY', '')
        finger = bit(keys, BTN_TOOL_FINGER) and not bit(keys, BTN_TOOL_PEN)
        if direct or not (multitouch or single) or not (pointer or named or finger):
            continue
        pads.append({'node': '/dev/input/' + node, 'name': name[:128], 'phys': fields.get('P:Phys', ''),
                     'sysfs': fields.get('S:Sysfs', ''), 'multitouch': multitouch,
                     'pressure': bit(abs_bits, ABS_MT_PRESSURE), 'major': bit(abs_bits, ABS_MT_TOUCH_MAJOR)})
    return pads


def abs_info(fd, code):
    buf = array.array('i', [0] * 6)
    try:
        fcntl.ioctl(fd, EVIOCGABS(code), buf)
    except OSError:
        return None
    value, minimum, maximum, fuzz, flat, resolution = buf
    if maximum <= minimum:
        return None
    return {'min': minimum, 'max': maximum, 'res': resolution}


def identity(fd):
    buf = array.array('H', [0] * 4)
    try:
        fcntl.ioctl(fd, EVIOCGID(), buf)
    except OSError:
        return {}
    bus = {0x03: 'usb', 0x05: 'bluetooth', 0x11: 'ps/2', 0x18: 'i2c', 0x1d: 'rmi', 0x19: 'host', 0x06: 'virtual'}.get(buf[0], hex(buf[0]))
    return {'bus': bus, 'vendor': '%04x' % buf[1], 'product': '%04x' % buf[2], 'version': buf[3]}


# ---- hardware: which pad, how big, and how its preset should scale ---------
UDEV_DATA = Path('/run/udev/data')
# libinput's own answers for a pad that reports no resolution: the size hint it
# ships for Apple's USB touchpads (50-system-apple.quirks), else its default.
APPLE_USB_SIZE_MM = (104.0, 75.0)
DEFAULT_SIZE_MM = (69.0, 55.0)
# The Mac-inspired gains as Trackpad Plus ships them are taken as right for a
# pad 124 mm wide driving a screen 1920 logical pixels across, a common laptop.
# That is the anchor, not a measurement. Any other pad and screen scale the
# gains by their own pixels per pad millimetre, so a long swipe carries the
# cursor the same share of the screen; clamped so a wrong size stays usable.
PRESET_PX_PER_MM = 1920 / 124.0
PRESET_SCALE_RANGE = (0.5, 2.0)


def hypr_name(kernel_name):
    """The name Hyprland gives a device: lowercased, with spaces, newlines and
    commas turned into dashes (deviceNameToInternalString). '/' survives."""
    return ''.join('-' if ch in ' \n,' else ch.lower() if ch.isascii() else ch for ch in kernel_name)


def settings_group(kernel_name):
    """The Trackpad Plus group a pad's settings live in, so telemetry and settings name the same pad."""
    name = hypr_name(kernel_name)
    if str(PLUGIN_ROOT) not in sys.path:
        sys.path.insert(0, str(PLUGIN_ROOT))
    try:
        import trackpads  # noqa: E402 - the one place grouping is decided
        return next(iter(trackpads.group_devices([{'name': name}])), name)
    except (ImportError, ValueError):
        return name


def udev_size(node):
    """A pad's width and height in mm as udev recorded them, or None."""
    try:
        rdev = os.stat(node).st_rdev
    except OSError:
        return None
    values = {}
    for line in read(UDEV_DATA / ('c%d:%d' % (os.major(rdev), os.minor(rdev)))).splitlines():
        if line.startswith('E:') and '=' in line:
            key, _, value = line[2:].partition('=')
            values[key] = value
    try:
        size = (float(values['ID_INPUT_WIDTH_MM']), float(values['ID_INPUT_HEIGHT_MM']))
    except (KeyError, ValueError):
        return None
    return size if size[0] > 0 and size[1] > 0 else None


def screen_width():
    """The widest monitor in logical pixels: how far a long swipe has to carry the cursor."""
    try:
        out = subprocess.run(['hyprctl', 'monitors', '-j'], capture_output=True, text=True, timeout=3, check=False).stdout
        monitors = json.loads(out or '[]')
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0.0
    widths = []
    for m in monitors if isinstance(monitors, list) else []:
        try:
            side = float(m['height'] if int(m.get('transform') or 0) % 2 else m['width'])
            widths.append(side / float(m.get('scale') or 1))
        except (KeyError, TypeError, ValueError, ZeroDivisionError):
            pass
    return max(widths, default=0.0)


def preset_scale(pad_mm, screen_px):
    if not pad_mm or not screen_px or pad_mm <= 0 or screen_px <= 0:
        return 1.0
    low, high = PRESET_SCALE_RANGE
    return round(min(high, max(low, screen_px / pad_mm / PRESET_PX_PER_MM)), 3)


def preset_gains(gain_max, scale=1.0):
    """The Mac-inspired precision and fast gains for one pad. Keep in sync with Curve.presetFor.

    Sized to the editor's ceiling first, as Trackpad Plus does, then by the
    pad's scale; Fast swipes never passes the ceiling (Device scale).
    """
    factor = min(1.0, gain_max / 1.6)
    precision, fast = max(0.01, 0.3 * factor), 1.6 * factor
    k = min(PRESET_SCALE_RANGE[1], max(PRESET_SCALE_RANGE[0], float(scale or 1.0)))
    if k != 1.0:
        precision = max(0.01, precision * k)
        fast = max(precision, min(max(gain_max, fast), fast * k))
    return round(precision, 4), round(fast, 4)


class Pad:
    """One touchpad's event stream turned into counts. Pure: feed() and tick() only.

    Positions arrive in device units and leave in millimetres via the axis
    resolution the kernel reports, so distance and speed are physical whether
    the pad is a 4010-unit ELAN or a 7000-unit Apple.
    """

    def __init__(self, info, axes, now):
        self.info = info
        self.axes = axes
        x, y = axes.get('x') or {'min': 0, 'max': 1, 'res': 0}, axes.get('y') or {'min': 0, 'max': 1, 'res': 0}
        # A pad that reports no resolution is sized the way libinput sizes it
        # (open_pad finds udev's size or libinput's hint), so millimetres stay
        # physical on it too; 30 units/mm is the last resort for a bare Pad.
        size = info.get('sizeMm')
        self.res_x = x['res'] or (max(1, x['max'] - x['min']) / size[0] if size else 30.0)
        self.res_y = y['res'] or (max(1, y['max'] - y['min']) / size[1] if size else 30.0)
        self.range_x = (x['min'], max(x['max'], x['min'] + 1))
        self.range_y = (y['min'], max(y['max'], y['min'] + 1))
        self.width_mm = (self.range_x[1] - self.range_x[0]) / self.res_x
        self.height_mm = (self.range_y[1] - self.range_y[0]) / self.res_y
        self.multitouch = info.get('multitouch', True)
        self.pressure_axis = axes.get('pressure')
        self.slots = {}
        self.slot = 0
        self.pending = {}
        self.buttons = {}
        self.touch = False
        self.session = None
        self.sessions = []
        self.prev = None
        self.heat = [0] * (HEAT_W * HEAT_H)
        self.hours = [0] * 24
        self.palm_x = 0.0
        self.palm_y = 0.0
        self.palm_n = 0
        self.counts = zero_counters()
        self.hist = [0.0] * (BINS + 1)
        self.peak = 0.0
        self.peak_at = 0.0
        self.last_frame = now
        self.last_touch = 0.0
        self.frames = deque()
        self.hz = 0.0
        self.hz_seen = 0.0
        self.live = []
        self.speed = 0.0
        self.fingers = 0
        self.dirty = False

    # -- events ------------------------------------------------------------
    def feed(self, typ, code, value, now):
        if typ == EV_ABS:
            if code == ABS_MT_SLOT:
                self.slot = value
            elif code == ABS_MT_TRACKING_ID:
                self.pending.setdefault(self.slot, {})['id'] = value
            elif code == ABS_MT_POSITION_X or (code == ABS_X and not self.multitouch):
                self.pending.setdefault(self.slot, {})['x'] = value
            elif code == ABS_MT_POSITION_Y or (code == ABS_Y and not self.multitouch):
                self.pending.setdefault(self.slot, {})['y'] = value
            elif code == ABS_MT_PRESSURE:
                self.pending.setdefault(self.slot, {})['p'] = value
            elif code == ABS_MT_TOUCH_MAJOR:
                self.pending.setdefault(self.slot, {})['major'] = value
            elif code == ABS_MT_TOOL_TYPE:
                self.pending.setdefault(self.slot, {})['tool'] = value
        elif typ == EV_KEY:
            if code == BTN_TOUCH:
                self.touch = value == 1
                if not self.multitouch:
                    self.pending.setdefault(0, {})['id'] = 0 if value else -1
            elif code in (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE):
                pressed = value == 1 and not self.buttons.get(code)
                self.buttons[code] = value == 1
                if pressed:
                    self.counts['clicks' if code == BTN_LEFT else 'rightClicks'] += 1
                    if self.session:
                        self.session['clicked'] = True
                    self.dirty = True
        elif typ == EV_SYN and code == SYN_REPORT:
            self._frame(now)

    def _frame(self, now):
        dt = max(0.0, now - self.last_frame)
        self.last_frame = now
        for slot, change in self.pending.items():
            state = self.slots.get(slot)
            if 'id' in change:
                if change['id'] < 0:
                    if state:
                        state['id'] = -1
                    continue
                if not state or state['id'] != change['id']:
                    state = {'id': change['id'], 'x': None, 'y': None, 'p': 0, 'major': 0, 'tool': 0, 'px': None, 'py': None, 'moved': 0.0}
                    self.slots[slot] = state
            if state is None:
                continue
            for key in ('x', 'y', 'p', 'major', 'tool'):
                if key in change:
                    state[key] = change[key]
        self.pending = {}
        active = [s for s in self.slots.values() if s['id'] >= 0 and s['x'] is not None and s['y'] is not None]
        fingers = len(active)
        # Motion since the last frame, per finger, in millimetres.
        speeds, dists = [], []
        for s in active:
            if s['px'] is not None and dt > 0:
                d = math.hypot((s['x'] - s['px']) / self.res_x, (s['y'] - s['py']) / self.res_y)
                s['moved'] += d
                dists.append(d)
                speeds.append(d / dt)
            s['px'], s['py'] = s['x'], s['y']
        speed = sum(speeds) / len(speeds) if speeds else 0.0
        dist = sum(dists) / len(dists) if dists else 0.0
        self.speed = speed
        self.fingers = fingers
        if fingers:
            # Wall-clock, unlike the event timestamps, because the panel compares
            # it with the time of day to say how long ago the last touch was.
            self.last_touch = time.time()
            self.counts['frames'] += 1
            self.frames.append(now)
            while self.frames and now - self.frames[0] > 1.0:
                self.frames.popleft()
            self.hz = len(self.frames) if now - (self.frames[0] if self.frames else now) >= 0.5 else self.hz
            if self.hz:
                self.hz_seen = self.hz
            if self.session is None:
                lead = active[0]
                self.session = {'start': now, 'max': 0, 'dist': 0.0, 'palm': False, 'clicked': False, 'gap0': None, 'gapMax': 0.0,
                                'peak': 0.0, 'lead': next((k for k, s in self.slots.items() if s is lead), None),
                                'x0': lead['x'] / self.res_x, 'y0': lead['y'] / self.res_y, 'x1': lead['x'] / self.res_x, 'y1': lead['y'] / self.res_y,
                                'nx0': (lead['x'] - self.range_x[0]) / (self.range_x[1] - self.range_x[0]),
                                'ny0': (lead['y'] - self.range_y[0]) / (self.range_y[1] - self.range_y[0])}
                self.counts['touches'] += 1
                self.hours[time.localtime().tm_hour] += 1
            ses = self.session
            ses['max'] = max(ses['max'], fingers)
            for s in active:
                nx = (s['x'] - self.range_x[0]) / (self.range_x[1] - self.range_x[0])
                ny = (s['y'] - self.range_y[0]) / (self.range_y[1] - self.range_y[0])
                self.heat[min(HEAT_H - 1, max(0, int(ny * HEAT_H))) * HEAT_W + min(HEAT_W - 1, max(0, int(nx * HEAT_W)))] += 1
                if s['tool'] == MT_TOOL_PALM:
                    self.palm_x += nx
                    self.palm_y += ny
                    self.palm_n += 1
            ses['dist'] += dist
            ses['peak'] = max(ses['peak'], speed)
            leader = self.slots.get(ses['lead'])
            if leader is None or leader['id'] < 0 or leader['x'] is None:
                leader = active[0]
            ses['x1'], ses['y1'] = leader['x'] / self.res_x, leader['y'] / self.res_y
            if any(s['tool'] == MT_TOOL_PALM for s in active):
                ses['palm'] = True
            if fingers == 2:
                a, b = active[0], active[1]
                gap = math.hypot((a['x'] - b['x']) / self.res_x, (a['y'] - b['y']) / self.res_y)
                if ses['gap0'] is None:
                    ses['gap0'] = gap
                ses['gapMax'] = max(ses['gapMax'], abs(gap - ses['gap0']))
                if dist > 0:
                    self.counts['scroll'] += dist
            if dist > 0:
                self.counts['distance'] += dist
            if dt > 0:
                self.counts['active'] += dt
                if speed >= REST_MM_S:
                    self.counts['moving'] += dt
                    index = min(BINS, int(speed / BIN_MM_S))
                    self.hist[index] += dt
                    if speed > self.peak:
                        self.peak, self.peak_at = speed, time.time()
            self.dirty = True
        elif self.session is not None:
            self._end_session(now)
        if fingers or self.live:
            self.live = [{'slot': slot, 'x': round((s['x'] - self.range_x[0]) / (self.range_x[1] - self.range_x[0]), 4),
                          'y': round((s['y'] - self.range_y[0]) / (self.range_y[1] - self.range_y[0]), 4),
                          'p': self._pressure(s), 'palm': s['tool'] == MT_TOOL_PALM,
                          'speed': round(speeds[i] if i < len(speeds) else 0.0, 1)}
                         for i, (slot, s) in enumerate((k, v) for k, v in self.slots.items() if v['id'] >= 0 and v['x'] is not None and v['y'] is not None)]
            self.dirty = True
        for slot in [k for k, v in self.slots.items() if v['id'] < 0]:
            del self.slots[slot]

    def _pressure(self, s):
        if self.pressure_axis and s['p']:
            span = max(1, self.pressure_axis['max'] - self.pressure_axis['min'])
            return round(min(1.0, max(0.0, (s['p'] - self.pressure_axis['min']) / span)), 3)
        return None

    def _end_session(self, now):
        ses, self.session = self.session, None
        kind = classify(ses, now)
        self.counts[{'tap': 'taps', 'tap2': 'taps2', 'tap3': 'taps3', 'move': 'moves', 'scroll': 'scrolls', 'pinch': 'pinches',
                     'swipe3': 'swipes3', 'swipe4': 'swipes4', 'palm': 'palms'}.get(kind, 'moves')] += 1
        rec = {'wall': time.time(), 'start': ses['start'], 'end': now, 'kind': kind, 'fingers': ses['max'],
               'duration': round(now - ses['start'], 3), 'dist': round(ses['dist'], 2), 'peak': round(ses['peak'], 1),
               'mean': round(ses['dist'] / max(0.01, now - ses['start']), 1),
               'dx': round(ses['x1'] - ses['x0'], 2), 'dy': round(ses['y1'] - ses['y0'], 2), 'flag': '', 'ref': 0.0, 'app': ses.get('app', ''),
               'x0': round(ses.get('nx0', 0.5), 3), 'y0': round(ses.get('ny0', 0.5), 3), 'clicked': bool(ses['clicked']),
               'gap': round(ses['start'] - self.prev['end'], 2) if self.prev else None, 'cursor0': ses.get('cursor0'), 'cursor': 0.0, 'stray': '',
               'device': self.info.get('device', '')}
        rec['flag'], rec['ref'] = flag_session(rec, self.prev)
        if kind == 'move' and rec['dist'] >= LONG_MOVE_MM:
            self.counts['longMoves'] += 1
        if rec['flag']:
            self.counts[rec['flag'] + 's'] += 1
        self.sessions.append(rec)
        self.prev = rec
        self.dirty = True

    def tick(self, now):
        """Called with no event for a while: lets a stuck session close and hz decay."""
        if self.frames and now - self.frames[-1] > 1.0:
            self.frames.clear()
            self.hz = 0.0
        if self.session is not None and not any(s['id'] >= 0 for s in self.slots.values()) and now - self.last_frame > 0.5:
            self._end_session(now)
            self.live = []
            self.fingers = 0
            self.speed = 0.0
            self.dirty = True

    def take(self):
        """Hand over the counters accumulated since the last take and reset them."""
        counts, self.counts = self.counts, zero_counters()
        hist, self.hist = self.hist, [0.0] * (BINS + 1)
        return counts, hist

    def take_maps(self):
        heat, self.heat = self.heat, [0] * (HEAT_W * HEAT_H)
        hours, self.hours = self.hours, [0] * 24
        palm, self.palm_x, self.palm_y, self.palm_n = (self.palm_x, self.palm_y, self.palm_n), 0.0, 0.0, 0
        return heat, hours, palm

    def facts(self):
        f = dict(self.info)
        f.update({'width': round(self.width_mm, 1), 'height': round(self.height_mm, 1),
                  'resX': self.res_x, 'resY': self.res_y, 'unitsX': self.range_x[1] - self.range_x[0], 'unitsY': self.range_y[1] - self.range_y[0],
                  'slots': (self.axes.get('slot') or {}).get('max', 0) + 1 if self.axes.get('slot') else 1,
                  'pressure': bool(self.pressure_axis), 'major': bool(self.axes.get('major')),
                  'hz': round(self.hz_seen), 'hzNow': round(self.hz), 'fingers': self.fingers, 'speed': round(self.speed, 1), 'lastTouch': self.last_touch})
        return f


def _cos(a, b):
    la, lb = math.hypot(a['dx'], a['dy']), math.hypot(b['dx'], b['dy'])
    if la < 0.5 or lb < 0.5:
        return None
    return (a['dx'] * b['dx'] + a['dy'] * b['dy']) / (la * lb)


def flag_session(rec, prev):
    """Name what this session says about the one before it, or nothing.

    Returns (flag, reference speed): 'correction' when a long move is answered
    at once by a short move the other way (the curve moved the cursor too far
    at that speed), 'restroke' when a long move is continued at once in the
    same direction (not far enough), and the scroll equivalents.
    """
    if not prev:
        return '', 0.0
    gap = rec['start'] - prev['end']
    if rec['kind'] == 'move' and prev['kind'] == 'move':
        c = _cos(rec, prev)
        if c is not None and gap < CORRECTION_GAP and rec['dist'] < CORRECTION_MAX_MM and prev['dist'] >= LONG_MOVE_MM and c < -0.3:
            return 'correction', prev['peak']
        if c is not None and gap < RESTROKE_GAP and rec['dist'] >= LONG_MOVE_MM and prev['dist'] >= LONG_MOVE_MM and c > 0.7:
            return 'restroke', prev['peak']
    if rec['kind'] == 'scroll' and prev['kind'] == 'scroll' and gap < SCROLL_GAP and abs(rec['dy']) >= 0.5 and abs(prev['dy']) >= 0.5:
        same = (rec['dy'] > 0) == (prev['dy'] > 0)
        if not same and rec['dist'] < prev['dist'] * 0.5:
            return 'scrollCorrection', prev['peak']
        if same and rec['dist'] >= SCROLL_LONG_MM and prev['dist'] >= SCROLL_LONG_MM:
            return 'scrollRestroke', prev['peak']
    return '', 0.0


def classify(ses, now):
    """Name a touch session from how many fingers, how far, how long and whether it clicked."""
    duration = now - ses['start']
    if ses['palm']:
        return 'palm'
    if duration <= TAP_SECONDS and ses['dist'] < TAP_MM and not ses['clicked']:
        return {1: 'tap', 2: 'tap2'}.get(ses['max'], 'tap3')
    if ses['max'] >= 4:
        return 'swipe4' if ses['dist'] >= SWIPE_MM else 'move'
    if ses['max'] == 3:
        return 'swipe3' if ses['dist'] >= SWIPE_MM else 'move'
    if ses['max'] == 2:
        if ses['gapMax'] >= PINCH_MM:
            return 'pinch'
        return 'scroll' if ses['dist'] >= TAP_MM else 'move'
    return 'move'


# ---- stray touches: naming them, and the guard that puts the cursor back ------
def stray_kind(rec):
    """Name a one-finger move that looks accidental, or ''. Pure.

    'brush': shorter than STRAY_BRUSH_S and STRAY_BRUSH_MM on a pad that had
    sat idle for STRAY_COLD_S. 'rest': a slow drift under STRAY_REST_MM that
    began in the bottom thumb strip or a side palm strip. Both only count when
    the cursor actually moved; a click or a second finger means it was meant.
    """
    if rec.get('kind') != 'move' or rec.get('clicked') or int(rec.get('fingers') or 1) != 1:
        return ''
    if float(rec.get('cursor') or 0.0) < STRAY_CURSOR_PX:
        return ''
    gap = rec.get('gap')
    if rec['duration'] < STRAY_BRUSH_S and rec['dist'] < STRAY_BRUSH_MM and (gap is None or gap >= STRAY_COLD_S):
        return 'brush'
    x0, y0 = rec.get('x0'), rec.get('y0')
    if x0 is None or y0 is None:
        return ''
    edge = x0 <= STRAY_EDGE or x0 >= 1.0 - STRAY_EDGE or y0 >= STRAY_BOTTOM
    if edge and rec['dist'] < STRAY_REST_MM and rec['mean'] < STRAY_REST_MM_S:
        return 'rest'
    return ''


def guard_verdict(pending, now, touching, drift):
    """What the guard does with a queued put-back: 'wait', 'cancel' or 'revert'. Pure.

    It waits STRAY_HOLD after the finger lifted so a touch that continues is
    left alone, and it cancels when a finger is back on the pad or the cursor
    has since moved on its own, because then something else is driving.
    """
    if touching:
        return 'cancel'
    if now - pending['at'] < STRAY_HOLD:
        return 'wait'
    if drift > STRAY_DRIFT_PX:
        return 'cancel'
    return 'revert'


def is_regret(rec, last_revert):
    """A real move right after a put-back: the guard undid something meant. Pure."""
    if not last_revert or rec.get('kind') != 'move':
        return False
    return rec['dist'] >= STRAY_REGRET_MM and 0.0 <= rec['start'] - last_revert['at'] <= STRAY_REGRET_S


def warp_cursor(x, y):
    result = subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.cursor.move({ x = %.2f, y = %.2f })' % (float(x), float(y))],
                            capture_output=True, text=True, timeout=2, check=False)
    return result.returncode == 0 and 'ok' in (result.stdout or '')


# ---- which hand, from where the fingers and palms land ------------------------
def hand_verdict(heat, palm_x, palm_n):
    """Right or left hand, with the reasons. Pure.

    A right hand rests its thumb at the bottom-left of the pad and drops its
    heel at the bottom-right; a left hand mirrors that. Two votes: where the
    bottom-row mass sits and where rejected palms land.
    """
    total = float(sum(heat)) if heat else 0.0
    if total < 200 and palm_n < 5:
        return {'hand': 'unknown', 'confidence': 0.0, 'reason': 'Not enough touches yet to tell.'}
    left = right = 0.0
    for i, n in enumerate(heat or []):
        row, col = divmod(i, HEAT_W)
        if row >= HEAT_H * 0.6:
            if col < HEAT_W * 0.4:
                left += n
            elif col >= HEAT_W * 0.6:
                right += n
    votes, reasons = 0.0, []
    if left + right > 50:
        share = (left - right) / (left + right)        # +1 all thumb-left, -1 all thumb-right
        votes += share
        reasons.append('%.0f%% of the bottom-row touching sits on the %s' % (max(left, right) / (left + right) * 100, 'left' if left >= right else 'right'))
    if palm_n >= 5:
        px = palm_x / palm_n
        votes += (px - 0.5) * 2                          # palms right => right hand
        reasons.append('rejected palms land %s of centre' % ('right' if px >= 0.5 else 'left'))
    if abs(votes) < 0.15:
        return {'hand': 'unknown', 'confidence': round(abs(votes), 2), 'reason': 'Touches are spread too evenly to say. ' + '; '.join(reasons) + '.'}
    return {'hand': 'right' if votes > 0 else 'left', 'confidence': round(min(1.0, abs(votes)), 2),
            'reason': ('Thumb rests left, heel falls right: a right hand. ' if votes > 0 else 'Thumb rests right, heel falls left: a left hand. ') + '; '.join(reasons) + '.'}


# ---- access ---------------------------------------------------------------
def in_input_group():
    try:
        import grp
        return any(grp.getgrgid(g).gr_name == 'input' for g in os.getgroups())
    except (KeyError, OSError, ImportError):
        return False


def udev_rule_present():
    try:
        return UDEV_RULE_PATH.read_text() == UDEV_RULE
    except OSError:
        return False


def open_pad(info, now):
    fd = os.open(info['node'], os.O_RDONLY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, EVIOCSCLOCKID(), array.array('i', [CLOCK_MONOTONIC]))
    except OSError:
        pass
    axes = {'x': abs_info(fd, ABS_MT_POSITION_X) or abs_info(fd, ABS_X),
            'y': abs_info(fd, ABS_MT_POSITION_Y) or abs_info(fd, ABS_Y),
            'slot': abs_info(fd, ABS_MT_SLOT), 'pressure': abs_info(fd, ABS_MT_PRESSURE), 'major': abs_info(fd, ABS_MT_TOUCH_MAJOR)}
    if not axes['x'] or not axes['y']:
        os.close(fd)
        raise OSError('no position axes on ' + info['node'])
    name = array.array('B', [0] * 256)
    try:
        fcntl.ioctl(fd, EVIOCGNAME(256), name)
        info = dict(info, kernelName=name.tobytes().split(b'\0')[0].decode(errors='replace')[:128])
    except OSError:
        pass
    info.update(identity(fd))
    info['multitouch'] = bool(axes['slot'])
    if axes['x']['res'] and axes['y']['res']:
        info['sizeSource'] = 'kernel'
    else:
        size, source = udev_size(info['node']), 'udev'
        if not size:
            apple_usb = info.get('vendor') == '05ac' and info.get('bus') == 'usb'
            size, source = (APPLE_USB_SIZE_MM, 'libinput hint') if apple_usb else (DEFAULT_SIZE_MM, 'libinput default')
        info.update(sizeMm=list(size), sizeSource=source)
    return fd, Pad(info, axes, now)


# ---- cursor fallback ------------------------------------------------------
class Cursor:
    """What the compositor will say about the pointer when the pad itself is closed to us.

    Distance and speed are in logical pixels, not millimetres, and there are
    no fingers, taps or gestures in it: that is the whole difference, and the
    panel says so.
    """

    def __init__(self):
        self.path = None
        self.x = self.y = None
        self.at = None
        self.counts = {'distance': 0.0, 'active': 0.0, 'moving': 0.0}
        self.hist = [0.0] * (BINS + 1)
        self.peak = 0.0
        self.peak_at = 0.0
        self.speed = 0.0
        self.last_move = 0.0

    def socket_path(self):
        runtime = os.environ.get('XDG_RUNTIME_DIR') or '/run/user/' + str(os.getuid())
        sig = os.environ.get('HYPRLAND_INSTANCE_SIGNATURE')
        candidates = [os.path.join(runtime, 'hypr', sig, '.socket.sock')] if sig else []
        candidates += sorted(glob.glob(os.path.join(runtime, 'hypr', '*', '.socket.sock')), key=os.path.getmtime, reverse=True)
        for path in candidates:
            if os.path.exists(path):
                return path
        return None

    def poll(self, now):
        if not self.path or not os.path.exists(self.path):
            self.path = self.socket_path()
            if not self.path:
                return False
        try:
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(0.5)
                s.connect(self.path)
                s.sendall(b'cursorpos')
                reply = s.recv(64).decode(errors='replace')
            x, y = (float(v) for v in reply.split(',')[:2])
        except (OSError, ValueError):
            self.path = None
            return False
        if self.x is not None and self.at is not None:
            dt = now - self.at
            d = math.hypot(x - self.x, y - self.y)
            if d > 0 and dt > 0:
                speed = d / dt
                self.counts['distance'] += d
                self.counts['moving'] += dt
                self.counts['active'] += dt
                # Pixel speed lands in the same bins scaled by 10, so 5 mm/s
                # bins read as 50 px/s bins on the cursor-only histogram.
                self.hist[min(BINS, int(speed / (BIN_MM_S * 10)))] += dt
                self.speed = speed
                self.last_move = now
                if speed > self.peak:
                    self.peak, self.peak_at = speed, time.time()
            else:
                self.speed = 0.0
        self.x, self.y, self.at = x, y, now
        return True

    def take(self):
        counts, self.counts = self.counts, {'distance': 0.0, 'active': 0.0, 'moving': 0.0}
        hist, self.hist = self.hist, [0.0] * (BINS + 1)
        return counts, hist


class MouseWatch:
    """Cursor motion while no finger is on the pad is another pointing device, called the mouse here."""

    def __init__(self):
        self.x = self.y = None
        self.at = None
        self.streak_start = None
        self.last_motion = 0.0
        self.active = 0.0
        self.distance = 0.0

    def observe(self, x, y, now, pad_touched):
        moved = False
        if self.x is not None and self.at is not None:
            d = math.hypot(x - self.x, y - self.y)
            if d > 0 and not pad_touched:
                moved = True
                self.distance += d
                self.active += min(1.0, now - self.at)
                if self.streak_start is None or now - self.last_motion > MOUSE_GAP:
                    self.streak_start = now
                self.last_motion = now
        self.x, self.y, self.at = x, y, now
        if now - self.last_motion > MOUSE_GAP:
            self.streak_start = None
        return moved

    @property
    def streak(self):
        return 0.0 if self.streak_start is None else self.last_motion - self.streak_start

    def take(self):
        out, self.active, self.distance = {'active': self.active, 'distance': self.distance}, 0.0, 0.0
        return out


# ---- persistence ----------------------------------------------------------
def db_open():
    db = sqlite3.connect(STATE / 'history.sqlite3', timeout=5)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('CREATE TABLE IF NOT EXISTS minutes (ts REAL PRIMARY KEY, touches INTEGER, taps INTEGER, clicks INTEGER, '
               'distance REAL, scroll REAL, swipes INTEGER, palms INTEGER, active REAL, peak REAL, hist TEXT, source TEXT, boot TEXT)')
    db.execute('CREATE TABLE IF NOT EXISTS sessions (ts REAL, kind TEXT, fingers INTEGER, duration REAL, dist REAL, '
               'peak REAL, mean REAL, dx REAL, dy REAL, flag TEXT, ref REAL)')
    db.execute('CREATE INDEX IF NOT EXISTS sessions_ts ON sessions (ts)')
    # The finger-speed histogram per pad per minute, so a laptop pad and a
    # Magic Trackpad are optimized on their own movement, not an average.
    db.execute('CREATE TABLE IF NOT EXISTS pad_minutes (ts REAL, device TEXT, hist TEXT, PRIMARY KEY (ts, device))')
    # One row per calendar day, kept forever: a year is 365 short rows.
    db.execute('CREATE TABLE IF NOT EXISTS days (day TEXT PRIMARY KEY, touches INTEGER, taps INTEGER, clicks INTEGER, moves INTEGER, '
               'scrolls INTEGER, gestures INTEGER, palms INTEGER, distance REAL, scroll REAL, active REAL, moving REAL, peak REAL)')
    for column, kind in (('mouse', 'REAL DEFAULT 0'), ('apps', 'TEXT'), ('strays', 'INTEGER DEFAULT 0'), ('strayReverts', 'INTEGER DEFAULT 0'), ('strayRegrets', 'INTEGER DEFAULT 0')):
        try:
            db.execute('ALTER TABLE days ADD COLUMN %s %s' % (column, kind))
        except sqlite3.OperationalError:
            pass
    for column, kind in (('x0', 'REAL'), ('y0', 'REAL'), ('gap', 'REAL'), ('cursor', 'REAL DEFAULT 0'), ('stray', 'TEXT DEFAULT \'\''), ('device', 'TEXT DEFAULT \'\'')):
        try:
            db.execute('ALTER TABLE sessions ADD COLUMN %s %s' % (column, kind))
        except sqlite3.OperationalError:
            pass
    return db


def record_day(db, today):
    c = today['counts']
    db.execute('INSERT OR REPLACE INTO days VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
               (today['day'], c['touches'], c['taps'] + c['taps2'] + c['taps3'], c['clicks'] + c['rightClicks'], c['moves'], c['scrolls'],
                c['pinches'] + c['swipes3'] + c['swipes4'], c['palms'], round(c['distance'], 1), round(c['scroll'], 1),
                round(c['active'], 1), round(c['moving'], 1), round(today.get('peak', 0.0), 1),
                round((today.get('mouse') or {}).get('active', 0.0), 1), json.dumps(today.get('apps') or {}),
                c.get('strays', 0), c.get('strayReverts', 0), c.get('strayRegrets', 0)))
    db.commit()


def stray_summary(db, today, now):
    """Stray touches this week and today, and how the guard did."""
    row = db.execute('SELECT SUM(strays), SUM(strayReverts), SUM(strayRegrets) FROM days WHERE day >= ? AND day < ?',
                     (day_key(now - 6 * 86400), today['day'])).fetchone()
    c = today['counts']
    return {'today': c.get('strays', 0), 'week': (row[0] or 0) + c.get('strays', 0),
            'reverts': (row[1] or 0) + c.get('strayReverts', 0), 'regrets': (row[2] or 0) + c.get('strayRegrets', 0),
            'revertsToday': c.get('strayReverts', 0), 'regretsToday': c.get('strayRegrets', 0)}


def report(db, today, log, now):
    """The week, put together: totals against last week, a bar per day, apps, hand, mouse share, what Optimize did."""
    def rows(since, until):
        return db.execute('SELECT day, touches, taps, clicks, distance, active, mouse, peak, gestures, palms, apps FROM days WHERE day >= ? AND day < ? ORDER BY day',
                          (since, until)).fetchall()
    week = rows(day_key(now - 6 * 86400), today['day']) + [(today['day'], today['counts']['touches'],
            today['counts']['taps'] + today['counts']['taps2'] + today['counts']['taps3'], today['counts']['clicks'] + today['counts']['rightClicks'],
            today['counts']['distance'], today['counts']['active'], (today.get('mouse') or {}).get('active', 0.0), today.get('peak', 0.0),
            today['counts']['pinches'] + today['counts']['swipes3'] + today['counts']['swipes4'], today['counts']['palms'], json.dumps(today.get('apps') or {}))]
    last = rows(day_key(now - 13 * 86400), day_key(now - 6 * 86400))

    def total(rs, i):
        return sum((r[i] or 0) for r in rs)
    apps = {}
    for r in week:
        try:
            for name, a in json.loads(r[10] or '{}').items():
                slot = apps.setdefault(name, {'touches': 0, 'distance': 0.0, 'active': 0.0})
                for key in slot:
                    slot[key] += a.get(key, 0)
        except (ValueError, AttributeError):
            pass
    top = sorted(apps.items(), key=lambda kv: kv[1]['touches'], reverse=True)[:8]
    busiest = max(week, key=lambda r: r[1] or 0) if week else None
    heat = today.get('heat') or []
    hand = hand_verdict(heat, today.get('palmX', 0.0), today.get('palmN', 0))
    return {'ts': now, 'days': [{'day': r[0], 'touches': r[1] or 0, 'taps': r[2] or 0, 'clicks': r[3] or 0, 'distance': round(r[4] or 0, 1),
                                 'active': round(r[5] or 0, 1), 'mouse': round(r[6] or 0, 1), 'peak': round(r[7] or 0, 1), 'gestures': r[8] or 0, 'palms': r[9] or 0} for r in week],
            'week': {'distance': total(week, 4), 'touches': total(week, 1), 'taps': total(week, 2), 'clicks': total(week, 3), 'active': total(week, 5),
                     'mouse': total(week, 6), 'gestures': total(week, 8), 'palms': total(week, 9), 'peak': max((r[7] or 0) for r in week) if week else 0, 'days': len(week)},
            'lastWeek': {'distance': total(last, 4), 'touches': total(last, 1), 'clicks': total(last, 3), 'active': total(last, 5), 'days': len(last)},
            'busiestDay': busiest[0] if busiest else '', 'busiestHour': max(range(24), key=lambda h: (today.get('hours') or [0] * 24)[h]) if today.get('hours') else None,
            'apps': [{'app': name, **vals} for name, vals in top], 'hand': hand,
            'palms': {'today': today['counts']['palms'], 'x': round(today.get('palmX', 0.0) / max(1, today.get('palmN', 0)), 2) if today.get('palmN') else None},
            'autoOff': {'today': today.get('autoOff', 0)},
            'strays': stray_summary(db, today, now),
            'optimize': [{'ts': e['ts'], 'changes': [c.get('label', c.get('key')) for c in e.get('changes', [])], 'before': (e.get('evidence') or {}).get('correctionRate'),
                          'verdict': e.get('verdict', ''), 'judgement': e.get('judgement') or ('undo' if e.get('undo') else 'watching'),
                          'reason': e.get('judgeReason', ''), 'undo': bool(e.get('undo'))} for e in (log or []) if e.get('applied')][-5:]}


WINDOW_KEYS = ('distance', 'touches', 'taps', 'clicks', 'active')


def counts_window(c):
    """The five numbers every window carries, from a counters dict."""
    return {'distance': c.get('distance', 0.0), 'touches': c.get('touches', 0),
            'taps': c.get('taps', 0) + c.get('taps2', 0) + c.get('taps3', 0),
            'clicks': c.get('clicks', 0) + c.get('rightClicks', 0), 'active': c.get('active', 0.0)}


def windows(db, today, now, recent=None):
    """Distance, touches, taps, clicks and active time over the last minute, hour, today, week, month, year and all time.

    `recent` is the recorder's rolling list of (bucketStart, counts) ten-second
    buckets, so the minute is a true trailing 60 s rather than the calendar
    minute in progress.
    """
    live = counts_window(today['counts'])
    minute = {k: 0 for k in WINDOW_KEYS}
    for start, counts in (recent or []):
        if start >= now - 60:
            for k, val in counts_window(counts).items():
                minute[k] += val
    hour = db.execute('SELECT SUM(distance), SUM(touches), SUM(taps), SUM(clicks), SUM(active) FROM minutes WHERE ts >= ?', (now - 3600,)).fetchone()

    def span(since_day):
        row = db.execute('SELECT SUM(distance), SUM(touches), SUM(taps), SUM(clicks), SUM(active), COUNT(*) FROM days WHERE day >= ? AND day < ?', (since_day, today['day'])).fetchone()
        return {'distance': (row[0] or 0) + live['distance'], 'touches': (row[1] or 0) + live['touches'], 'taps': (row[2] or 0) + live['taps'],
                'clicks': (row[3] or 0) + live['clicks'], 'active': (row[4] or 0) + live['active'], 'days': (row[5] or 0) + 1}
    first = db.execute('SELECT MIN(day) FROM days').fetchone()[0] or today['day']
    return {'minute': minute,
            'hour': {'distance': hour[0] or 0, 'touches': hour[1] or 0, 'taps': hour[2] or 0, 'clicks': hour[3] or 0, 'active': hour[4] or 0},
            'today': live, 'week': span(day_key(now - 6 * 86400)), 'month': span(day_key(now - 29 * 86400)),
            'year': span(day_key(now - 364 * 86400)), 'all': span('0000-00-00'), 'firstDay': min(first, today['day'])}


def record_sessions(db, recs):
    if not recs:
        return
    db.executemany('INSERT INTO sessions (ts, kind, fingers, duration, dist, peak, mean, dx, dy, flag, ref, x0, y0, gap, cursor, stray, device) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                   [(r['wall'], r['kind'], r['fingers'], r['duration'], r['dist'], r['peak'], r['mean'], r['dx'], r['dy'], r['flag'], r['ref'],
                     r.get('x0'), r.get('y0'), r.get('gap'), r.get('cursor', 0.0), r.get('stray', ''), r.get('device', '')) for r in recs])
    db.commit()


def load_sessions(db, since, device=None):
    """Sessions since a time; for one pad, its own plus those recorded before pads were kept apart."""
    keys = ('ts', 'kind', 'fingers', 'duration', 'dist', 'peak', 'mean', 'dx', 'dy', 'flag', 'ref', 'x0', 'y0', 'gap', 'cursor', 'stray', 'device')
    query = 'SELECT ts,kind,fingers,duration,dist,peak,mean,dx,dy,flag,ref,x0,y0,gap,cursor,stray,device FROM sessions WHERE ts >= ?'
    if device:
        return [dict(zip(keys, row)) for row in db.execute(query + " AND device IN (?, '') ORDER BY ts", (since, device))]
    return [dict(zip(keys, row)) for row in db.execute(query + ' ORDER BY ts', (since,))]


def load_hist(db, since, device=None):
    """The finger-speed histogram since a time; for one pad, its own minutes
    plus the combined ones recorded before pads were kept apart."""
    hist = [0.0] * (BINS + 1)
    if device:
        first = db.execute('SELECT MIN(ts) FROM pad_minutes').fetchone()[0]
        rows = db.execute('SELECT hist FROM pad_minutes WHERE ts >= ? AND device = ? UNION ALL '
                          'SELECT hist FROM minutes WHERE ts >= ? AND ts < ?', (since, device, since, first if first is not None else float('inf'))).fetchall()
    else:
        rows = db.execute('SELECT hist FROM minutes WHERE ts >= ?', (since,)).fetchall()
    for (raw,) in rows:
        try:
            for i, v in enumerate(json.loads(raw)[:BINS + 1]):
                hist[i] += v
        except (ValueError, TypeError):
            pass
    return hist


def record(db, ts, counts, hist, source, pads=None):
    db.execute('INSERT OR REPLACE INTO minutes VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
               (ts, counts.get('touches', 0), counts.get('taps', 0) + counts.get('taps2', 0) + counts.get('taps3', 0),
                counts.get('clicks', 0) + counts.get('rightClicks', 0), counts.get('distance', 0.0), counts.get('scroll', 0.0),
                counts.get('swipes3', 0) + counts.get('swipes4', 0) + counts.get('pinches', 0), counts.get('palms', 0),
                counts.get('active', 0.0), counts.get('peak', 0.0), json.dumps([round(v, 3) for v in hist]), source,
                read('/proc/sys/kernel/random/boot_id').strip()))
    db.executemany('INSERT OR REPLACE INTO pad_minutes VALUES (?,?,?)',
                   [(ts, device, json.dumps([round(v, 3) for v in h])) for device, h in (pads or {}).items() if device])
    db.execute('DELETE FROM minutes WHERE ts < ?', (ts - RETENTION,))
    db.execute('DELETE FROM pad_minutes WHERE ts < ?', (ts - RETENTION,))
    db.execute('DELETE FROM sessions WHERE ts < ?', (ts - RETENTION,))
    db.commit()


def history(db, seconds, now=None):
    """Buckets for the graph: [start, touches, distance mm, peak mm/s, active s, taps, boot]."""
    now = time.time() if now is None else now
    bucket = max(60, seconds / 240)
    rows = db.execute('SELECT MIN(ts), SUM(touches), SUM(distance), MAX(peak), SUM(active), SUM(taps), boot, COUNT(*) FROM minutes '
                      'WHERE ts>=? AND ts<=? GROUP BY CAST(ts/? AS INTEGER), boot ORDER BY MIN(ts)', (now - seconds, now, bucket)).fetchall()
    points = [[r[0], r[1], round(r[2], 1), round(r[3], 1), round(r[4], 1), r[5], r[6]] for r in rows]
    return {'seconds': seconds, 'bucket': bucket, 'now': now, 'points': points, 'count': sum(r[7] for r in rows),
            'peak': max((r[3] for r in rows), default=0), 'touches': sum(r[1] for r in rows),
            'distance': round(sum(r[2] for r in rows), 1), 'busiest': max((r[1] for r in rows), default=0)}


def week_summary(db, now):
    row = db.execute('SELECT SUM(touches), SUM(taps), SUM(clicks), SUM(distance), SUM(scroll), SUM(swipes), SUM(palms), SUM(active), MAX(peak), COUNT(*) '
                     'FROM minutes WHERE ts >= ?', (now - RETENTION,)).fetchone()
    hist = [0.0] * (BINS + 1)
    for (raw,) in db.execute('SELECT hist FROM minutes WHERE ts >= ?', (now - RETENTION,)):
        try:
            for i, v in enumerate(json.loads(raw)[:BINS + 1]):
                hist[i] += v
        except (ValueError, TypeError):
            pass
    keys = ('touches', 'taps', 'clicks', 'distance', 'scroll', 'swipes', 'palms', 'active', 'peak', 'minutes')
    return dict({k: (row[i] or 0) for i, k in enumerate(keys)}, hist=[round(v, 2) for v in hist])


def day_key(ts):
    return time.strftime('%Y-%m-%d', time.localtime(ts))


class Recorder:
    def __init__(self):
        self.pads = {}          # node -> (fd, Pad)
        self.known = {}         # node -> info from /proc even when unopenable
        self.denied = {}        # node -> error text
        self.cursor = Cursor()
        self.db = db_open()
        self.today = self._load_today()
        self.minute = {'counts': zero_counters(), 'hist': [0.0] * (BINS + 1), 'peak': 0.0, 'start': time.time(), 'pads': {}}
        self.screen_px = 0.0
        self.week_by_device = {}
        self.last_scan = 0.0
        self.last_live = 0.0
        self.last_snapshot = 0.0
        self.last_history = 0.0
        self.live_clear_pending = False
        self.pending_sessions = []
        self.last_hint = time.time() - HINT_INTERVAL + 60
        self.recent = deque()   # (bucketStart, counts) ten-second buckets for the trailing minute
        self.mouse = MouseWatch()
        self.last_cursor = 0.0
        self.pad_off_by_us = False
        self.pad_off_at = 0.0
        self.auto_off_checked = 0.0
        self.auto_off_wanted = False
        self.stray_wanted = False
        self.stray_checked = 0.0
        self.pending_revert = None
        self.last_revert = None

    def bump(self, key, n=1):
        """Count something the recorder itself did, in the minute, the day and the trailing-minute buckets."""
        self.minute['counts'][key] = self.minute['counts'].get(key, 0) + n
        self.today['counts'][key] = self.today['counts'].get(key, 0) + n
        if self.recent:
            self.recent[-1][1][key] = self.recent[-1][1].get(key, 0) + n

    def _load_today(self):
        fresh = self._fresh_today(time.time())
        try:
            saved = json.loads((STATE / 'today.json').read_text())
            if saved.get('day') == fresh['day'] and isinstance(saved.get('counts'), dict):
                # Merge over a fresh record: a release that adds a counter must
                # not choke on the file the previous release wrote.
                fresh['counts'].update({k: saved['counts'].get(k, 0) for k in COUNTERS})
                for key in ('hist', 'peak', 'peakAt', 'lastTouch', 'heat', 'hours', 'palmX', 'palmY', 'palmN', 'apps', 'mouse', 'autoOff', 'strayHeat'):
                    if key in saved:
                        fresh[key] = saved[key]
                if len(fresh.get('heat') or []) != HEAT_W * HEAT_H:
                    fresh['heat'] = [0] * (HEAT_W * HEAT_H)
                if len(fresh.get('strayHeat') or []) != HEAT_W * HEAT_H:
                    fresh['strayHeat'] = [0] * (HEAT_W * HEAT_H)
                if len(fresh.get('hours') or []) != 24:
                    fresh['hours'] = [0] * 24
                if isinstance(saved.get('cursor'), dict):
                    fresh['cursor'].update(saved['cursor'])
                if len(fresh['hist']) != BINS + 1:
                    fresh['hist'] = [0.0] * (BINS + 1)
        except (OSError, ValueError, TypeError):
            pass
        return fresh

    def _fresh_today(self, ts):
        return {'day': day_key(ts), 'counts': zero_counters(), 'hist': [0.0] * (BINS + 1), 'peak': 0.0, 'peakAt': 0.0, 'lastTouch': 0.0,
                'heat': [0] * (HEAT_W * HEAT_H), 'strayHeat': [0] * (HEAT_W * HEAT_H), 'hours': [0] * 24, 'palmX': 0.0, 'palmY': 0.0, 'palmN': 0, 'apps': {},
                'mouse': {'active': 0.0, 'distance': 0.0}, 'autoOff': 0,
                'cursor': {'distance': 0.0, 'active': 0.0, 'moving': 0.0, 'peak': 0.0, 'peakAt': 0.0, 'hist': [0.0] * (BINS + 1)}}

    @property
    def access(self):
        if self.pads:
            return 'evdev'
        if self.known and self.denied:
            return 'cursor' if self.cursor.path else 'none'
        return 'nopad' if not self.known else 'cursor' if self.cursor.path else 'none'

    def scan(self, now):
        self.last_scan = now
        found = {p['node']: p for p in parse_devices(read('/proc/bus/input/devices'))}
        for info in found.values():
            info['hyprName'] = hypr_name(info['name'])
            info['device'] = settings_group(info['name'])
        self.screen_px = screen_width()
        for node in list(self.pads):
            if node not in found:
                os.close(self.pads[node][0])
                del self.pads[node]
        self.known = found
        for node, info in found.items():
            if node in self.pads:
                continue
            try:
                self.pads[node] = open_pad(info, time.monotonic())
                self.denied.pop(node, None)
            except OSError as e:
                self.denied[node] = str(e)
        for node in list(self.denied):
            if node not in found:
                del self.denied[node]

    def pump(self, timeout):
        fds = {fd: pad for fd, pad in self.pads.values()}
        ready = []
        if fds:
            try:
                ready, _, _ = select.select(list(fds), [], [], timeout)
            except (OSError, ValueError):
                ready = []
        else:
            time.sleep(timeout)
        for fd in ready:
            pad = fds[fd]
            try:
                data = os.read(fd, EVENT.size * 256)
            except BlockingIOError:
                continue
            except OSError:
                for node, (nfd, npad) in list(self.pads.items()):
                    if nfd == fd:
                        os.close(nfd)
                        del self.pads[node]
                        self.last_scan = 0.0
                continue
            for off in range(0, len(data) - EVENT.size + 1, EVENT.size):
                sec, usec, typ, code, value = EVENT.unpack_from(data, off)
                pad.feed(typ, code, value, sec + usec / 1e6)

    def gather(self, now):
        """Fold every pad's fresh counts into the minute and the day."""
        peak = 0.0
        for fd, pad in self.pads.values():
            pad.tick(time.monotonic())
            if not pad.dirty:
                continue
            pad.dirty = False
            finished, pad.sessions = pad.sessions, []
            self.pending_sessions.extend(finished)
            heat, hours, palm = pad.take_maps()
            for i, n in enumerate(heat):
                if n:
                    self.today['heat'][i] += n
            for i, n in enumerate(hours):
                if n:
                    self.today['hours'][i] += n
            self.today['palmX'] += palm[0]
            self.today['palmY'] += palm[1]
            self.today['palmN'] += palm[2]
            self.judge_strays(pad, finished)
            for rec in finished:
                if rec.get('app'):
                    slot = self.today['apps'].setdefault(rec['app'], {'touches': 0, 'distance': 0.0, 'active': 0.0})
                    slot['touches'] += 1
                    slot['distance'] += rec['dist']
                    slot['active'] += rec['duration']
            if len(self.today['apps']) > APPS_KEPT:
                keep = sorted(self.today['apps'].items(), key=lambda kv: kv[1]['touches'], reverse=True)[:APPS_KEPT]
                self.today['apps'] = dict(keep)
            counts, hist = pad.take()
            bucket = int(now // 10) * 10
            if not self.recent or self.recent[-1][0] != bucket:
                self.recent.append((bucket, zero_counters()))
                while self.recent and self.recent[0][0] < now - 70:
                    self.recent.popleft()
            for k, v in counts.items():
                self.minute['counts'][k] += v
                self.today['counts'][k] += v
                self.recent[-1][1][k] += v
            mine = self.minute['pads'].setdefault(pad.info.get('device', ''), [0.0] * (BINS + 1))
            for i, v in enumerate(hist):
                self.minute['hist'][i] += v
                self.today['hist'][i] += v
                mine[i] += v
            if pad.peak > self.today['peak']:
                self.today['peak'], self.today['peakAt'] = pad.peak, pad.peak_at
            self.today['lastTouch'] = max(self.today.get('lastTouch', 0.0), pad.last_touch)
            peak = max(peak, pad.peak)
            pad.peak = 0.0
        self.minute['peak'] = max(self.minute['peak'], peak)
        if not self.pads and self.cursor.path:
            counts, hist = self.cursor.take()
            c = self.today['cursor']
            for k, v in counts.items():
                c[k] += v
            for i, v in enumerate(hist):
                c['hist'][i] += v
                self.minute['hist'][i] += v
            self.minute['counts']['distance'] += counts['distance']
            self.minute['counts']['active'] += counts['active']
            self.minute['counts']['moving'] += counts['moving']
            if self.cursor.peak > c['peak']:
                c['peak'], c['peakAt'] = self.cursor.peak, self.cursor.peak_at
            self.minute['peak'] = max(self.minute['peak'], self.cursor.peak)
            self.cursor.peak = 0.0

    def roll(self, now):
        if day_key(now) != self.today['day']:
            self.today = self._fresh_today(now)
        if now - self.minute['start'] >= 60:
            counts = dict(self.minute['counts'], peak=self.minute['peak'])
            if counts['frames'] or counts['distance'] > 0 or counts['touches']:
                record(self.db, self.minute['start'], counts, self.minute['hist'], self.access, self.minute['pads'])
            self.minute = {'counts': zero_counters(), 'hist': [0.0] * (BINS + 1), 'peak': 0.0, 'start': now, 'pads': {}}
            taken = self.mouse.take()
            self.today['mouse']['active'] += taken['active']
            self.today['mouse']['distance'] += taken['distance']
            record_day(self.db, self.today)
            devices = {pad.info.get('device') for _, pad in self.pads.values()} - {None, ''}
            self.week_by_device = {d: [round(v, 2) for v in load_hist(self.db, now - RETENTION, d)] for d in sorted(devices)}
            atomic(STATE, 'history.json', {str(s): history(self.db, s, now) for s in (3600, 86400, 604800)})
            self.last_history = now
        if now - self.last_hint >= HINT_INTERVAL:
            self.last_hint = now
            try:
                write_hint(self.db, now)
            except Exception as e:  # noqa: BLE001 - a hint is advice, never a reason to stop recording
                print('Trackpad Pulse: hint: ' + str(e), flush=True)

    def touching(self):
        return any(pad.fingers for _, pad in self.pads.values())

    def active_window_class(self):
        path = self.cursor.path or self.cursor.socket_path()
        if not path:
            return ''
        try:
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(0.3)
                s.connect(path)
                s.sendall(b'activewindow')
                reply = s.recv(4096).decode(errors='replace')
        except (OSError, ValueError):
            return ''
        for line in reply.splitlines():
            if line.strip().startswith('class:'):
                return line.split(':', 1)[1].strip()[:48]
        return ''

    def name_sessions(self):
        """Stamp each new touch session with the window that had focus when it began, and where the cursor was."""
        for _, pad in self.pads.values():
            if pad.session is not None and 'app' not in pad.session:
                pad.session['app'] = self.active_window_class()
                # The last poll before the touch: with the pad idle the cursor was
                # not moving, so a poll up to 200 ms old is where it really was.
                pad.session['cursor0'] = (self.cursor.x, self.cursor.y) if self.cursor.x is not None else None

    def judge_strays(self, pad, finished):
        """Name the accidental-looking touches among the sessions that just ended, and queue a put-back if asked."""
        if not finished:
            return
        mono = time.monotonic()
        if any(r.get('cursor0') for r in finished):
            self.cursor.poll(time.time())
        for rec in finished:
            c0 = rec.get('cursor0')
            if c0 and self.cursor.x is not None:
                rec['cursor'] = round(math.hypot(self.cursor.x - c0[0], self.cursor.y - c0[1]), 1)
            if is_regret(rec, self.last_revert):
                self.bump('strayRegrets')
                self.last_revert = None
                print('Trackpad Pulse: put-back regretted: a %.0f mm move followed within %.1f s' % (rec['dist'], rec['start'] - (self.last_revert or {}).get('at', rec['start'])), flush=True)
            rec['stray'] = stray_kind(rec)
            if not rec['stray']:
                continue
            pad.counts['strays'] += 1
            cell = min(HEAT_H - 1, max(0, int(rec['y0'] * HEAT_H))) * HEAT_W + min(HEAT_W - 1, max(0, int(rec['x0'] * HEAT_W)))
            self.today['strayHeat'][cell] += 1
            if self.stray_wanted and c0:
                self.pending_revert = {'at': mono, 'to': c0, 'end': (self.cursor.x, self.cursor.y), 'kind': rec['stray']}

    def stray_guard(self, now):
        """Opt-in: after a stray touch the cursor goes back to where it was before the finger landed.

        The kernel already delivered the motion, so this is a put-back, not a
        block: STRAY_HOLD after the finger lifts, if nothing else is driving
        the cursor and no finger is back on the pad, one warp through Hyprland.
        A real move right after it is counted as a regret, so the Report can
        say whether the guard is helping or fighting.
        """
        if now - self.stray_checked >= 2.0:
            self.stray_checked = now
            self.stray_wanted = (STATE / STRAY_GUARD_MARKER).exists()
        if self.pending_revert is None:
            return
        if not self.stray_wanted:
            self.pending_revert = None
            return
        mono = time.monotonic()
        pending = self.pending_revert
        drift = 0.0
        if mono - pending['at'] >= STRAY_HOLD:
            if self.cursor.poll(now) and self.cursor.x is not None and pending['end'][0] is not None:
                drift = math.hypot(self.cursor.x - pending['end'][0], self.cursor.y - pending['end'][1])
        verdict = guard_verdict(pending, mono, self.touching(), drift)
        if verdict == 'wait':
            return
        self.pending_revert = None
        if verdict == 'revert' and warp_cursor(*pending['to']):
            self.bump('strayReverts')
            self.last_revert = {'at': mono, 'to': pending['to']}
            print('Trackpad Pulse: cursor put back after a %s' % pending['kind'], flush=True)

    def watch_mouse(self, now):
        """Five times a second, twenty while it moves: is another pointing device driving the cursor?"""
        if not self.pads:
            return
        interval = 0.05 if now - self.mouse.last_motion < 2.0 else 0.2
        if now - self.last_cursor < interval:
            return
        self.last_cursor = now
        if not self.cursor.poll(now):
            return
        touched = self.touching() or now - max([pad.last_touch for _, pad in self.pads.values()] or [0.0]) < 0.3
        self.mouse.observe(self.cursor.x, self.cursor.y, now, touched)

    def set_pad(self, enabled):
        try:
            current = current_settings()
            result = subprocess.run([sys.executable, str(PLUGIN_ROOT / 'trackpads.py'), 'set', str(current['device']), 'enabled', json.dumps(bool(enabled))],
                                    capture_output=True, text=True, timeout=15, check=False)
            return result.returncode == 0
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as e:
            print('Trackpad Pulse: set_pad: ' + str(e), flush=True)
            return False

    def auto_off(self, now):
        """Opt-in: the pad goes off after a stretch of mouse use, and comes back on a deliberate touch.

        The kernel keeps reporting the pad while Hyprland ignores it, so the
        recorder sees the touch that asks for it back. A resting finger or a
        palm is not a request: it takes a tap, or a move of DELIBERATE_MM.
        """
        if now - self.auto_off_checked >= 2.0:
            self.auto_off_checked = now
            self.auto_off_wanted = (STATE / AUTO_OFF_MARKER).exists()
        if not self.auto_off_wanted:
            if self.pad_off_by_us:
                self.pad_off_by_us = not self.set_pad(True)
            return
        if not self.pad_off_by_us:
            if self.mouse.streak >= AUTO_OFF_AFTER and not self.touching() and self.set_pad(False):
                self.pad_off_by_us = True
                self.pad_off_at = now
                self.today['autoOff'] = self.today.get('autoOff', 0) + 1
                print('Trackpad Pulse: pad off after %.0f s of mouse use' % self.mouse.streak, flush=True)
            return
        if now - self.pad_off_at < AUTO_OFF_MIN:
            return
        for _, pad in self.pads.values():
            asked = any(r['kind'] == 'tap' or (r['kind'] == 'move' and r['dist'] >= DELIBERATE_MM) for r in pad.sessions if r['wall'] >= self.pad_off_at)
            asked = asked or (pad.session is not None and pad.session.get('dist', 0.0) >= DELIBERATE_MM)
            if asked:
                if self.set_pad(True):
                    self.pad_off_by_us = False
                    self.mouse.streak_start = None
                    print('Trackpad Pulse: pad back on, deliberate touch', flush=True)
                return

    def write_live(self, now):
        pads = []
        for _, pad in self.pads.values():
            pads.append({'node': pad.info['node'], 'fingers': pad.live, 'down': pad.fingers > 0, 'speed': round(pad.speed, 1), 'hz': round(pad.hz)})
        atomic(RUNTIME, 'live.json', {'ts': now, 'pads': pads,
                                      'cursor': {'speed': round(self.cursor.speed, 1)} if not self.pads and self.cursor.path else None})
        self.last_live = now

    def snapshot(self, now):
        pads = []
        for node, info in self.known.items():
            if node in self.pads:
                pad = self.pads[node][1]
                pads.append(dict(pad.facts(), readable=True, presetScale=preset_scale(pad.width_mm, self.screen_px)))
            else:
                size = udev_size(node)
                pads.append(dict(info, readable=False, error=self.denied.get(node, ''), presetScale=preset_scale(size[0] if size else 0, self.screen_px)))
        pads.sort(key=lambda p: p['node'])
        week = week_summary(self.db, now)
        try:
            spans = windows(self.db, self.today, now, self.recent)
        except sqlite3.Error:
            spans = {}
        mouse_live = {'active': self.today['mouse']['active'] + self.mouse.active, 'distance': self.today['mouse']['distance'] + self.mouse.distance,
                      'streak': round(self.mouse.streak, 1)}
        return {'ts': now, 'warm': True, 'access': self.access, 'inputGroup': in_input_group(), 'udevRule': udev_rule_present(), 'windows': spans,
                'heatW': HEAT_W, 'heatH': HEAT_H, 'mouse': mouse_live,
                'autoOff': {'enabled': self.auto_off_wanted, 'offNow': self.pad_off_by_us, 'today': self.today.get('autoOff', 0)},
                'strayGuard': dict(stray_summary(self.db, self.today, now), enabled=self.stray_wanted),
                'hand': hand_verdict(self.today.get('heat') or [], self.today.get('palmX', 0.0), self.today.get('palmN', 0)),
                'udevRulePath': str(UDEV_RULE_PATH), 'pads': pads, 'today': self.today, 'week': week,
                'screenPx': round(self.screen_px), 'weekByDevice': self.week_by_device,
                'binMmS': BIN_MM_S, 'bins': BINS, 'mmPerUnitMs': MM_PER_UNIT_MS, 'pid': os.getpid(),
                'cursorSocket': bool(self.cursor.path), 'lastTouch': max([pad.last_touch for _, pad in self.pads.values()] + [self.today.get('lastTouch', 0.0)])}

    def run(self):
        with (STATE / 'collector.lock').open('w') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            atomic(STATE, 'history.json', {str(s): history(self.db, s) for s in (3600, 86400, 604800)})
            # Seed an idle live.json before the loop. It lives on tmpfs and was
            # otherwise written only once a finger or the cursor moved, so on a
            # fresh boot it did not exist yet; the panel's FileView bound its
            # watch to a missing path, which never attaches when the file later
            # appears, and the bar chip stayed dead until a shell restart. Now
            # the file exists as soon as the recorder does, before the first
            # snapshot makes the panel warm, so the panel's warm-up reload finds
            # it and binds the watch.
            self.write_live(time.time())
            while True:
                try:
                    self.tick()
                except Exception as e:  # noqa: BLE001 - one bad tick must not stop the recording
                    print('Trackpad Pulse: %s: %s' % (type(e).__name__, e), flush=True)
                    time.sleep(1)

    def tick(self):
                now = time.time()
                if now - self.last_scan >= 10:
                    self.scan(now)
                if self.pads:
                    self.pump(LIVE_INTERVAL if self.touching() else 0.25)
                else:
                    moving = now - self.cursor.last_move < 2.0
                    self.cursor.poll(now)
                    time.sleep(0.05 if moving else 0.2)
                now = time.time()
                self.name_sessions()
                self.watch_mouse(now)
                self.gather(now)
                self.auto_off(now)
                self.stray_guard(now)
                if self.touching():
                    if now - self.last_live >= LIVE_INTERVAL:
                        self.write_live(now)
                    self.live_clear_pending = True
                elif self.live_clear_pending or (not self.pads and self.cursor.path and now - self.last_live >= 0.1 and now - self.cursor.last_move < 1.0):
                    self.write_live(now)
                    self.live_clear_pending = False
                self.roll(now)
                interval = 1.0 if (self.touching() or now - self.cursor.last_move < 2.0) else 5.0
                if now - self.last_snapshot >= interval:
                    try:
                        record_sessions(self.db, self.pending_sessions)
                        self.pending_sessions = []
                    except sqlite3.Error as e:
                        print('Trackpad Pulse: sessions: ' + str(e), flush=True)
                    atomic(STATE, 'snapshot.json', self.snapshot(now))
                    atomic(STATE, 'today.json', self.today)
                    self.last_snapshot = now


# ---- the optimizer --------------------------------------------------------
def percentile(hist, fraction):
    total = sum(hist)
    if total <= 0:
        return 0.0
    acc = 0.0
    for i, v in enumerate(hist):
        acc += v
        if acc / total >= fraction:
            return (i + 1) * BIN_MM_S
    return len(hist) * BIN_MM_S


def rates(sessions, start_mm, end_mm):
    """Overshoot and re-stroke rates, overall and per speed band of the move they answer."""
    moves = [s for s in sessions if s['kind'] == 'move']
    long_moves = [s for s in moves if s['dist'] >= LONG_MOVE_MM]
    corrections = [s for s in moves if s['flag'] == 'correction']
    restrokes = [s for s in moves if s['flag'] == 'restroke']
    scrolls = [s for s in sessions if s['kind'] == 'scroll']
    fast = [s for s in long_moves if s['peak'] >= end_mm]
    slow = [s for s in long_moves if s['peak'] < start_mm]

    def rate(n, d):
        return n / d if d else 0.0
    return {'sessions': len(sessions), 'moves': len(moves), 'longMoves': len(long_moves), 'corrections': len(corrections), 'restrokes': len(restrokes),
            'correctionRate': rate(len(corrections), len(long_moves)), 'restrokeRate': rate(len(restrokes), len(long_moves)),
            'fastMoves': len(fast), 'fastCorrectionRate': rate(sum(1 for s in corrections if s['ref'] >= end_mm), len(fast)),
            'slowMoves': len(slow), 'slowCorrectionRate': rate(sum(1 for s in corrections if s['ref'] < start_mm), len(slow)),
            'scrolls': len(scrolls), 'scrollReversalRate': rate(sum(1 for s in scrolls if s['flag'] == 'scrollCorrection'), len(scrolls)),
            'scrollRestrokeRate': rate(sum(1 for s in scrolls if s['flag'] == 'scrollRestroke'), len(scrolls))}


def watch_for(key, direction):
    """What the next pass watches to keep or undo this change.

    A nudge must earn its keep: the rate it targets has to fall. A shape change
    (Start, End, a first fit) is kept unless a guarded rate rises by WORSE_BY.
    Either is undone when the opposite fingerprint crosses its own trigger.
    """
    if key == 'fast':
        return ({'target': 'fastCorrectionRate', 'guard': [], 'opposite': {'metric': 'restrokeRate', 'threshold': 0.12}} if direction == 'down'
                else {'target': 'restrokeRate', 'guard': [], 'opposite': {'metric': 'fastCorrectionRate', 'threshold': 0.20}})
    if key == 'precision':
        return {'target': 'slowCorrectionRate', 'guard': [], 'opposite': None}
    if key == 'scroll':
        return ({'target': 'scrollReversalRate', 'guard': [], 'opposite': {'metric': 'scrollRestrokeRate', 'threshold': 0.30}} if direction == 'down'
                else {'target': 'scrollRestrokeRate', 'guard': [], 'opposite': {'metric': 'scrollReversalRate', 'threshold': 0.25}})
    return {'target': None, 'guard': ['correctionRate', 'restrokeRate'], 'opposite': None}


def fmt_value(v):
    """A setting for a sentence: 0.7641474222 → 0.7641, None → an em dash."""
    if v is None:
        return '—'
    if isinstance(v, float):
        return ('%.4f' % v).rstrip('0').rstrip('.') or '0'
    return str(v)


def watch_of(entry):
    """The watch spec of a log entry; derived from the change itself for rows written before 1.5.0."""
    if entry.get('watch'):
        return entry['watch']
    head = (entry.get('changes') or [{}])[0]
    if head.get('watch'):
        return head['watch']
    direction = head.get('direction')
    if not direction:
        frm, to = head.get('from'), head.get('to')
        direction = 'shape' if head.get('key') in ('profile', 'start', 'end') or frm is None or to is None else 'down' if float(to) < float(frm) else 'up'
    return watch_for(head.get('key'), direction)


def judge(entry, after, moving):
    """Keep or undo the last applied change, by the rates since it was applied. Pure.

    Returns {'judgement': 'watching' | 'kept' | 'undo', 'reason': str}. One
    decision per change: the callers write it into the log and never re-judge.
    """
    if entry.get('undo'):
        return {'judgement': 'kept', 'reason': 'An undo puts back a value that was already judged; it is not judged again.'}
    watch = watch_of(entry)
    if after['moves'] < JUDGE_MOVES or moving < JUDGE_SECONDS:
        return {'judgement': 'watching', 'reason': '%d of %d moves and %.0f of %d s of movement seen since it was applied.' % (after['moves'], JUDGE_MOVES, moving, JUDGE_SECONDS)}
    before = entry.get('evidence') or {}

    def pct(v):
        return '%.0f%%' % (float(v or 0) * 100)
    for metric in watch.get('guard') or []:
        b, a = float(before.get(metric) or 0), float(after.get(metric) or 0)
        name, of = METRIC_NAMES.get(metric, (metric, 'moves'))
        if a - b > WORSE_BY:
            return {'judgement': 'undo', 'reason': '%s rose from %s to %s of %s over the %d moves since it was applied.' % (name.capitalize(), pct(b), pct(a), of, after['moves'])}
    opp = watch.get('opposite')
    if opp:
        b, a = float(before.get(opp['metric']) or 0), float(after.get(opp['metric']) or 0)
        name, of = METRIC_NAMES.get(opp['metric'], (opp['metric'], 'moves'))
        if a > opp['threshold'] >= b:
            return {'judgement': 'undo', 'reason': 'The opposite fingerprint appeared: %s went from %s to %s of %s, past the %s trigger.' % (name, pct(b), pct(a), of, pct(opp['threshold']))}
    target = watch.get('target')
    if target:
        b, a = float(before.get(target) or 0), float(after.get(target) or 0)
        name, of = METRIC_NAMES.get(target, (target, 'moves'))
        if a > b - HELPED_BY:
            return {'judgement': 'undo', 'reason': '%s did not fall: %s of %s before, %s over the %d moves since. A nudge that did not help is undone.' % (name.capitalize(), pct(b), of, pct(a), after['moves'])}
        return {'judgement': 'kept', 'reason': '%s fell from %s to %s of %s over the %d moves since it was applied.' % (name.capitalize(), pct(b), pct(a), of, after['moves'])}
    parts = ['%s %s → %s' % (METRIC_NAMES.get(m, (m, ''))[0], pct(before.get(m)), pct(after.get(m))) for m in watch.get('guard') or []]
    return {'judgement': 'kept', 'reason': 'Nothing got worse over the %d moves since it was applied: %s.' % (after['moves'], ', '.join(parts) or 'no fingerprint rose')}


def propose(current, sessions, hist, log=None, now=None):
    """What to change and why. Pure: settings in, proposal out, nothing applied.

    current: {profile, curve:{precision,start,end,fast}, scrollFactor (slider 0.01..1),
              scrollScale, gainMaximum}. Start/End are in the editor's 0..4 units.

    One change a pass. The last applied change is judged first; while it is
    still being watched nothing new is proposed, and when it made things worse
    the only proposal is to undo it, carrying the logged reason. Everything
    else the data would change is listed as queued for a later pass.
    """
    now = time.time() if now is None else now
    curve = dict(current.get('curve') or {'precision': 0.3, 'start': 0.8, 'end': 2.8, 'fast': 1.6})
    profile = current.get('profile', 'adaptive')
    custom = profile in ('custom', 'mac')
    gain_max = float(current.get('gainMaximum') or current.get('scrollScale') or 1)
    scroll = float(current.get('scrollFactor') or 0.4)
    moving = sum(hist)
    p45, p50, p90 = percentile(hist, 0.45), percentile(hist, 0.5), percentile(hist, 0.9)
    start_mm = curve['start'] * MM_PER_UNIT_MS if custom else p45
    end_mm = curve['end'] * MM_PER_UNIT_MS if custom else p90
    r = rates(sessions, start_mm, end_mm)
    candidates, notes = [], []
    proposal = {'curve': dict(curve), 'scrollFactor': scroll, 'profile': 'custom' if custom else profile}

    enough = moving >= 300 and r['moves'] >= 200
    confidence = 'high' if moving >= 1800 and r['longMoves'] >= 600 else 'medium' if enough else 'low'

    def value_of(key):
        return scroll if key == 'scroll' else profile if key == 'profile' else curve.get(key)

    # 0. The last applied change, judged once by the same rates since it was applied.
    previous, hold = None, None
    applied = [e for e in (log or []) if e.get('applied')]
    if applied:
        last = applied[-1]
        after = rates([s for s in sessions if s['ts'] >= last['ts']], start_mm, end_mm)
        stored = last.get('judgement')
        j = {'judgement': stored, 'reason': last.get('judgeReason', '')} if stored else judge(last, after, moving)
        head = last.get('changes') or []
        if j['judgement'] == 'undo' and head and any(abs(float(value_of(c['key']) or 0) - float(c.get('to') or 0)) > 1e-6 if c['key'] != 'profile' else value_of('profile') != c.get('to') for c in head):
            j = {'judgement': 'overridden', 'reason': 'You changed it by hand since the pass; there is nothing to undo.'}
        previous = {'ts': last['ts'], 'changes': head, 'before': last.get('evidence') or {}, 'after': last.get('after') or after,
                    'practiceBefore': last.get('practiceMedianMs'), 'practiceAfter': current.get('practiceMedianMs'),
                    'judgement': j['judgement'], 'reason': j['reason'], 'undo': bool(last.get('undo')),
                    'summary': ', '.join('%s %s → %s' % (c.get('label', c['key']), fmt_value(c.get('from')), fmt_value(c.get('to'))) for c in head)}
        if last.get('undo') and last.get('hold'):
            hold = last['hold']

    # 1. The shape: Start where 45% of movement is slower, End at the 90th percentile.
    first_fit = []
    if moving > 0:
        new_start = round(min(3.6, max(0.0, p45 / MM_PER_UNIT_MS)), 2)
        new_end = round(min(4.0, max(new_start + 0.2, p90 / MM_PER_UNIT_MS)), 2)
        if not custom:
            precision, fast = preset_gains(gain_max, current.get('presetScale') or 1.0)
            base = {'precision': precision, 'start': new_start, 'end': new_end, 'fast': fast}
            first_fit = [{'key': 'profile', 'label': 'Profile', 'from': profile, 'to': 'custom', 'direction': 'shape',
                          'reason': 'A custom curve is the only place Start and End exist; gains start from the Mac-inspired preset, sized to this pad and screen.'},
                         {'key': 'start', 'label': 'Start', 'from': None, 'to': new_start, 'direction': 'shape', 'reason': '45%% of your movement is slower than %.0f mm/s; below that the curve stays at precision gain.' % p45},
                         {'key': 'end', 'label': 'End', 'from': None, 'to': new_end, 'direction': 'shape', 'reason': '90%% of your movement is slower than %.0f mm/s; the fastest tenth gets full gain.' % p90}]
            for c in first_fit:
                c['watch'] = watch_for(c['key'], 'shape')
            candidates.append({'key': 'fit', 'rank': (0, 0), 'records': first_fit, 'proposal': {'curve': base, 'profile': 'custom'}})
        else:
            if abs(new_start - curve['start']) >= 0.02:
                candidates.append({'key': 'start', 'rank': (0, -abs(p45 - start_mm)), 'records': [{'key': 'start', 'label': 'Start', 'from': curve['start'], 'to': new_start, 'direction': 'shape',
                                   'reason': '45%% of your movement is slower than %.0f mm/s; Start sits there so half of what you do stays precise.' % p45}], 'proposal': {'curve': {'start': new_start}}})
            if abs(new_end - curve['end']) >= 0.02:
                candidates.append({'key': 'end', 'rank': (0, -abs(p90 - end_mm)), 'records': [{'key': 'end', 'label': 'End', 'from': curve['end'], 'to': new_end, 'direction': 'shape',
                                   'reason': '90%% of your movement is slower than %.0f mm/s; only the fastest tenth needs full gain.' % p90}], 'proposal': {'curve': {'end': new_end}}})

    # 2. The gains, from the fingerprints, one bounded nudge at a time.
    if custom and enough:
        fast_up = r['restrokeRate'] > 0.12 and r['longMoves'] >= 50
        fast_down = r['fastCorrectionRate'] > 0.20 and r['fastMoves'] >= 30
        if fast_up and fast_down:
            notes.append('Re-strokes and overshoots after fast moves both run high (%.0f%% and %.0f%%); they cancel, so Fast swipes is left alone this pass.' % (r['restrokeRate'] * 100, r['fastCorrectionRate'] * 100))
        elif fast_down:
            new_fast = round(max(curve['precision'], curve['fast'] * NUDGE_DOWN), 4)
            candidates.append({'key': 'fast', 'rank': (1, 0), 'records': [{'key': 'fast', 'label': 'Fast swipes', 'from': curve['fast'], 'to': new_fast, 'direction': 'down',
                               'reason': '%.0f%% of fast moves were answered by an overshoot correction; the cursor is going too far at speed.' % (r['fastCorrectionRate'] * 100)}], 'proposal': {'curve': {'fast': new_fast}}})
        elif fast_up:
            new_fast = round(curve['fast'] * NUDGE_UP, 4)
            if new_fast > gain_max:
                notes.append('%.0f%% of long moves were re-strokes, but Fast swipes is already at the %.2f× ceiling; raise Device scale to go further.' % (r['restrokeRate'] * 100, gain_max))
            else:
                candidates.append({'key': 'fast', 'rank': (1, 0), 'records': [{'key': 'fast', 'label': 'Fast swipes', 'from': curve['fast'], 'to': new_fast, 'direction': 'up',
                                   'reason': '%.0f%% of long moves were re-strokes: the pad ran out before the cursor arrived.' % (r['restrokeRate'] * 100)}], 'proposal': {'curve': {'fast': new_fast}}})
        if r['slowCorrectionRate'] > 0.25 and r['slowMoves'] >= 30:
            new_prec = round(max(0.01, curve['precision'] * NUDGE_DOWN), 4)
            candidates.append({'key': 'precision', 'rank': (2, 0), 'records': [{'key': 'precision', 'label': 'Precision', 'from': curve['precision'], 'to': new_prec, 'direction': 'down',
                               'reason': '%.0f%% of slow moves were followed by a correction; fine work is overshooting.' % (r['slowCorrectionRate'] * 100)}], 'proposal': {'curve': {'precision': new_prec}}})

    # 3. Scroll speed, same two signals.
    if r['scrolls'] >= 40:
        if r['scrollReversalRate'] > 0.25:
            new_scroll = round(max(0.01, scroll * NUDGE_DOWN), 2)
            candidates.append({'key': 'scroll', 'rank': (3, 0), 'records': [{'key': 'scroll', 'label': 'Scroll speed', 'from': scroll, 'to': new_scroll, 'direction': 'down',
                               'reason': '%.0f%% of scrolls were reversed at once; content is flying past.' % (r['scrollReversalRate'] * 100)}], 'proposal': {'scrollFactor': new_scroll}})
        elif r['scrollRestrokeRate'] > 0.30:
            new_scroll = round(min(1.0, scroll * NUDGE_UP), 2)
            candidates.append({'key': 'scroll', 'rank': (3, 0), 'records': [{'key': 'scroll', 'label': 'Scroll speed', 'from': scroll, 'to': new_scroll, 'direction': 'up',
                               'reason': '%.0f%% of scrolls were immediately repeated in the same direction; each one is not going far enough.' % (r['scrollRestrokeRate'] * 100)}], 'proposal': {'scrollFactor': new_scroll}})

    for cand in candidates:
        for c in cand['records']:
            c.setdefault('watch', watch_for(c['key'], c['direction']))
    candidates.sort(key=lambda c: c['rank'])

    # 4. An undone change is held: the same nudge is not offered again until as
    # many moves as first asked for it say so a second time.
    if hold and r['moves'] < int(hold.get('moves') or 0):
        held = [c for c in candidates if c['key'] == hold.get('key') and c['records'][0].get('direction') == hold.get('direction')]
        if held:
            candidates = [c for c in candidates if c not in held]
            notes.append('%s was undone; the same change waits until %d more moves ask for it again (%d seen).' % (held[0]['records'][0]['label'], int(hold['moves']) - r['moves'], r['moves']))

    def as_queued(cand):
        return [{'key': c['key'], 'label': c['label'], 'from': c['from'], 'to': c['to'], 'reason': c['reason']} for c in cand['records']]

    # 5. One change. The last one first, if it is still open.
    changes, queued = [], []
    if previous and previous['judgement'] == 'watching':
        verdict = 'watching'
        queued = [q for cand in candidates for q in as_queued(cand)]
    elif previous and previous['judgement'] == 'undo':
        verdict = 'undo'
        head = previous['changes']
        if head and head[0]['key'] == 'profile':
            back = head[0]['from'] or 'adaptive'
            proposal['profile'] = back
            changes = [{'key': 'profile', 'label': 'Profile', 'from': 'custom', 'to': back, 'direction': 'undo', 'undo': True, 'reverts': previous['ts'],
                        'reason': previous['reason'] + ' Undo goes back to the %s profile.' % back}]
        else:
            for c in head:
                if c['key'] == 'scroll':
                    proposal['scrollFactor'] = c['from']
                else:
                    proposal['curve'][c['key']] = c['from']
                changes.append({'key': c['key'], 'label': c.get('label', c['key']), 'from': c['to'], 'to': c['from'], 'direction': 'undo', 'undo': True, 'reverts': previous['ts'],
                                'reason': previous['reason'] + ' Undo puts %s back to %s.' % (c.get('label', c['key']), fmt_value(c['from']))})
        queued = [q for cand in candidates for q in as_queued(cand)]
    elif candidates:
        first = candidates[0]
        changes = first['records']
        for key, val in first['proposal'].items():
            if key == 'curve':
                proposal['curve'].update(val)
            else:
                proposal[key] = val
        if proposal['curve']['end'] < proposal['curve']['start'] + 0.2:
            proposal['curve']['end'] = round(min(4.0, proposal['curve']['start'] + 0.2), 2)
        if proposal['curve']['fast'] < proposal['curve']['precision']:
            proposal['curve']['fast'] = proposal['curve']['precision']
        queued = [q for cand in candidates[1:] for q in as_queued(cand)]
        if first['key'] == 'fit':
            verdict = 'first fit'
            notes.append('A first fit sets the profile, Start and End together: a custom curve cannot exist with only one of them. From here on it is one change a pass.')
        else:
            verdict = 'fit' if first['key'] in ('start', 'end') else 'nudge'
    else:
        verdict = 'nothing to change' if enough else 'nothing to change yet'

    message = ('%.0f minutes of movement and %d moves in the window. ' % (moving / 60, r['moves'])
               + ('' if enough else 'Fewer than five minutes of movement or 200 moves: the shape can be fitted, the gains wait for more data. '))
    return {'verdict': verdict, 'confidence': confidence, 'proposal': proposal, 'changes': changes, 'queued': queued, 'notes': notes, 'message': message.strip(),
            'evidence': dict(r, movingSeconds=round(moving, 1), p45=round(p45, 1), median=round(p50, 1), p90=round(p90, 1),
                             startMm=round(start_mm, 1), endMm=round(end_mm, 1)),
            'previous': previous, 'now': now, 'device': current.get('device') or ''}


def load_log():
    try:
        value = json.loads((STATE / OPTIMIZE_LOG).read_text())
        return value if isinstance(value, list) else []
    except (OSError, ValueError):
        return []


def device_log(log, device):
    """The optimize log rows for one pad. Rows written before pads were kept apart belong to every pad."""
    return [e for e in log if not device or e.get('device', device) in (device, '')]


def settle(log, p):
    """Write a decided judgement of the last applied pass into the log, once, so it is never re-judged."""
    prev = p.get('previous')
    if not prev or prev['judgement'] == 'watching':
        return
    applied = [e for e in device_log(log, p.get('device')) if e.get('applied')]
    if not applied or applied[-1].get('judgement'):
        return
    applied[-1].update({'judgement': prev['judgement'], 'judgeReason': prev['reason'], 'judgedTs': p['now'], 'after': prev['after']})
    atomic(STATE, OPTIMIZE_LOG, log[-50:])


def optimize(current):
    db = db_open()
    now = time.time()
    log = load_log()
    since = now - RETENTION
    device = current.get('device') or ''
    mine = device_log(log, device)
    applied = [e for e in mine if e.get('applied')]
    # Judge with everything since the last applied pass, so an old habit does
    # not outvote a week of the new curve; the first pass sees the whole week.
    if applied:
        since = max(since, applied[-1]['ts'])
    p = propose(current, load_sessions(db, since, device), load_hist(db, since, device), mine, now)
    settle(log, p)
    return p


def optimize_applied(entry):
    log = load_log()
    changes = entry.get('changes', [])
    head = changes[0] if changes else {}
    row = {'ts': time.time(), 'applied': True, 'changes': changes, 'evidence': entry.get('evidence', {}),
           'practiceMedianMs': entry.get('practiceMedianMs'), 'verdict': entry.get('verdict', ''), 'watch': head.get('watch'),
           'device': str(entry.get('device') or '')}
    if head.get('undo'):
        original = next((e for e in log if e.get('applied') and e.get('ts') == head.get('reverts')), None)
        if original:
            original['judgement'] = 'undone'
            original['judgeReason'] = (original.get('judgeReason') or '') + ' Undone.'
        first = (original or {}).get('changes') or [{}]
        row.update({'undo': True, 'reverts': head.get('reverts'), 'watch': None,
                    'hold': {'key': first[0].get('key'), 'direction': first[0].get('direction'), 'moves': int(((original or {}).get('evidence') or {}).get('moves') or 0)}})
        message = 'Undone and logged. The same change waits until as many moves ask for it again.'
    else:
        message = 'Applied and logged. After %d moves and %d s of movement the next pass keeps it or undoes it, and says why.' % (JUDGE_MOVES, JUDGE_SECONDS)
    log.append(row)
    atomic(STATE, OPTIMIZE_LOG, log[-50:])
    return {'message': message}


def optimize_keep(entry):
    """You disagree with an undo: keep the change and let the optimizer move on."""
    log = load_log()
    applied = [e for e in device_log(log, entry.get('device')) if e.get('applied')]
    if not applied or applied[-1].get('judgement') != 'undo':
        return {'message': 'Nothing is waiting to be undone.'}
    applied[-1]['judgement'] = 'kept by you'
    applied[-1]['judgeReason'] = (applied[-1].get('judgeReason') or '') + ' Kept by you.'
    atomic(STATE, OPTIMIZE_LOG, log[-50:])
    return {'message': 'Kept. The next pass moves on to the next change.'}


# ---- the standing check: does the best curve differ from the one in use? ------
def current_settings(device=None):
    """One pad's live settings, through Trackpad Plus's own backend.

    The pad asked for, else the connected pad touched last (from the recorder's
    snapshot), else the first connected one. presetScale is that pad's size
    against the screen, for the Mac-inspired gains.
    """
    result = subprocess.run([sys.executable, str(PLUGIN_ROOT / 'trackpads.py'), 'state'], capture_output=True, text=True, timeout=20, check=False)
    data = json.loads(result.stdout or '{}')
    devices = [d for d in data.get('devices', []) if isinstance(d, dict)]
    if not devices:
        raise RuntimeError('no trackpad in Trackpad Plus state')
    connected = [d for d in devices if d.get('connected')]
    try:
        pads = [p for p in json.loads((STATE / 'snapshot.json').read_text()).get('pads') or [] if isinstance(p, dict)]
    except (OSError, ValueError, AttributeError):
        pads = []
    ids = [d.get('id') for d in connected]
    touched = sorted((p for p in pads if p.get('device') in ids and p.get('lastTouch')), key=lambda p: -p['lastTouch'])
    wanted = device or (touched[0]['device'] if touched else None)
    dev = next((d for d in devices if d.get('id') == wanted), None) or (connected or devices)[0]
    s = dev['settings']
    profile = (s.get('curve_preset') or 'custom') if s.get('accel_profile') == 'custom' else s.get('accel_profile', 'adaptive')
    scale = s.get('scroll_scale') or max(1, s.get('scroll_factor', 0.4))
    preset = next((p['presetScale'] for p in pads if p.get('device') == dev.get('id') and p.get('presetScale')), 1.0)
    return {'device': dev.get('id'), 'profile': profile, 'curve': s.get('curve'), 'scrollFactor': s.get('scroll_factor', 0.4) / scale,
            'scrollScale': scale, 'gainMaximum': scale, 'presetScale': preset}


def hint_signature(changes):
    return hashlib.sha1(json.dumps(sorted([str(c['key']), str(c['to'])] for c in changes)).encode()).hexdigest()[:12]


def write_hint(db, now):
    """Re-run the optimizer against the settings in use and leave the verdict for the panel to light up."""
    current = current_settings()
    log = load_log()
    device = current.get('device') or ''
    mine = device_log(log, device)
    applied = [e for e in mine if e.get('applied')]
    since = max(now - RETENTION, applied[-1]['ts'] if applied else 0)
    p = propose(current, load_sessions(db, since, device), load_hist(db, since, device), mine, now)
    settle(log, p)
    summary = ('Undo ' if p['verdict'] == 'undo' else '') + ' · '.join('%s %s → %s' % (c['label'], fmt_value(c['from']), fmt_value(c['to'])) for c in p['changes'])
    atomic(STATE, 'hint.json', {'ts': now, 'device': current.get('device'), 'verdict': p['verdict'], 'confidence': p['confidence'],
                                'changes': p['changes'], 'signature': hint_signature(p['changes']), 'summary': summary,
                                'movingSeconds': p['evidence'].get('movingSeconds', 0)})


# ---- themes ------------------------------------------------------------------
def theme_names():
    out = subprocess.run(['omarchy-theme-list'], capture_output=True, text=True, timeout=10, check=False).stdout
    return [line.strip() for line in out.splitlines() if line.strip()]


def theme_current():
    return subprocess.run(['omarchy-theme-current'], capture_output=True, text=True, timeout=10, check=False).stdout.strip()


def pick_theme(names, current, step):
    """The next, previous or a random other theme. Pure."""
    if not names:
        raise RuntimeError('No themes installed.')
    if step == 'random':
        others = [n for n in names if n != current] or names
        return random.choice(others)
    index = names.index(current) if current in names else -1
    return names[(index + (1 if step == 'next' else -1)) % len(names)]


def theme_step(step):
    names = theme_names()
    target = pick_theme(names, theme_current(), step)
    result = subprocess.run(['omarchy-theme-set', target], capture_output=True, text=True, timeout=60, check=False)
    if result.returncode:
        raise RuntimeError('omarchy-theme-set failed: ' + (result.stderr.strip() or 'no reason given')[:160])
    return {'message': 'Theme: ' + target}


# ---- gestures ----------------------------------------------------------------
# Every slot Hyprland offers for three and four fingers, and every action the
# catalogue knows. The panel only ever sends ids; the Lua below is built from
# these constants and nothing else reaches Hyprland's config.
FINGERS = (3, 4)
DIRECTIONS = ('left', 'right', 'up', 'down', 'pinchin', 'pinchout')
SLOTS = ['%d-%s' % (f, d) for f in FINGERS for d in DIRECTIONS]
AXIS = {'left': 'horizontal', 'right': 'horizontal', 'up': 'vertical', 'down': 'vertical'}
PARTNER = {'left': 'right', 'right': 'left', 'up': 'down', 'down': 'up'}
COLLECTOR = str(Path(__file__).resolve())


def _exec(cmd):
    return {'kind': 'exec', 'cmd': cmd}


def _dispatch(lua):
    return {'kind': 'dispatch', 'lua': lua}


def _native(action, **extra):
    return dict({'kind': 'native', 'action': action}, **extra)


CATALOGUE = [
    {'id': 'none', 'group': 'Nothing', 'label': 'Nothing', 'hint': 'Leave this gesture unassigned.', 'spec': {'kind': 'none'}},
    # Workspaces
    {'id': 'ws-slide', 'group': 'Workspaces', 'label': 'Slide between workspaces', 'hint': 'Follows your fingers, animated, like macOS. Takes both directions of the axis.', 'pair': True, 'spec': _native('workspace')},
    {'id': 'ws-next', 'group': 'Workspaces', 'label': 'Next workspace', 'hint': 'Jump one workspace to the right.', 'spec': _dispatch('hl.dsp.focus({ workspace = "e+1" })')},
    {'id': 'ws-prev', 'group': 'Workspaces', 'label': 'Previous workspace', 'hint': 'Jump one workspace to the left.', 'spec': _dispatch('hl.dsp.focus({ workspace = "e-1" })')},
    {'id': 'ws-last', 'group': 'Workspaces', 'label': 'Last used workspace', 'hint': 'Back to where you just were.', 'spec': _dispatch('hl.dsp.focus({ workspace = "previous" })')},
    {'id': 'ws-scratch', 'group': 'Workspaces', 'label': 'Toggle the scratchpad', 'hint': 'The special workspace, in and out.', 'spec': _native('special', workspace_name='scratchpad')},
    {'id': 'ws-layout', 'group': 'Workspaces', 'label': 'Toggle workspace layout', 'hint': 'Tiled or scrolling, per workspace.', 'spec': _exec('omarchy-hyprland-workspace-layout-toggle')},
    {'id': 'scroll-move', 'group': 'Workspaces', 'label': 'Scroll the tape', 'hint': 'Move along the scrolling layout, 1:1. Takes both directions of the axis.', 'pair': True, 'spec': _native('scroll_move')},
    # Windows
    {'id': 'win-fullscreen', 'group': 'Windows', 'label': 'Fullscreen window', 'hint': 'Toggle the active window fullscreen.', 'spec': _native('fullscreen')},
    {'id': 'win-maximize', 'group': 'Windows', 'label': 'Maximize window', 'hint': 'Fill the screen but keep the bar.', 'spec': _native('fullscreen', mode='maximize')},
    {'id': 'win-close', 'group': 'Windows', 'label': 'Close window', 'hint': 'Close the active window.', 'spec': _native('close')},
    {'id': 'win-float', 'group': 'Windows', 'label': 'Float or tile window', 'hint': 'Pop the window out of the tiling, or back in.', 'spec': _native('float')},
    {'id': 'win-move', 'group': 'Windows', 'label': 'Move window', 'hint': 'Drag the active window with the gesture. Takes both directions of the axis.', 'pair': True, 'spec': _native('move')},
    {'id': 'win-resize', 'group': 'Windows', 'label': 'Resize window', 'hint': 'Resize the active window with the gesture. Takes both directions of the axis.', 'pair': True, 'spec': _native('resize')},
    {'id': 'focus-left', 'group': 'Windows', 'label': 'Focus window to the left', 'hint': 'Move focus one window left.', 'spec': _dispatch('hl.dsp.focus({ direction = "l" })')},
    {'id': 'focus-right', 'group': 'Windows', 'label': 'Focus window to the right', 'hint': 'Move focus one window right.', 'spec': _dispatch('hl.dsp.focus({ direction = "r" })')},
    {'id': 'focus-up', 'group': 'Windows', 'label': 'Focus window above', 'hint': 'Move focus one window up.', 'spec': _dispatch('hl.dsp.focus({ direction = "u" })')},
    {'id': 'focus-down', 'group': 'Windows', 'label': 'Focus window below', 'hint': 'Move focus one window down.', 'spec': _dispatch('hl.dsp.focus({ direction = "d" })')},
    {'id': 'win-gaps', 'group': 'Windows', 'label': 'Toggle window gaps', 'hint': 'Gaps on or off, everywhere.', 'spec': _exec('omarchy-hyprland-window-gaps-toggle')},
    {'id': 'win-transparency', 'group': 'Windows', 'label': 'Toggle window transparency', 'hint': 'See through the active window, or not.', 'spec': _exec('omarchy-hyprland-window-transparency-toggle')},
    # Themes & backgrounds
    {'id': 'theme-next', 'group': 'Themes & backgrounds', 'label': 'Next theme', 'hint': 'Step through your installed themes.', 'spec': _exec(shlex.join([sys.executable, COLLECTOR, 'theme-next']))},
    {'id': 'theme-prev', 'group': 'Themes & backgrounds', 'label': 'Previous theme', 'hint': 'Step back through your themes.', 'spec': _exec(shlex.join([sys.executable, COLLECTOR, 'theme-prev']))},
    {'id': 'theme-random', 'group': 'Themes & backgrounds', 'label': 'Random theme', 'hint': 'Surprise me.', 'spec': _exec(shlex.join([sys.executable, COLLECTOR, 'theme-random']))},
    {'id': 'theme-pick', 'group': 'Themes & backgrounds', 'label': 'Theme picker', 'hint': "Open Omarchy's theme switcher.", 'spec': _exec('omarchy-theme-switcher')},
    {'id': 'bg-next', 'group': 'Themes & backgrounds', 'label': 'Next background', 'hint': "The current theme's next background.", 'spec': _exec('omarchy-theme-bg-next')},
    {'id': 'bg-pick', 'group': 'Themes & backgrounds', 'label': 'Background picker', 'hint': "Open Omarchy's background switcher.", 'spec': _exec('omarchy-theme-bg-switcher')},
    {'id': 'nightlight', 'group': 'Themes & backgrounds', 'label': 'Toggle night light', 'hint': 'Warm the screen, or cool it.', 'spec': _exec('omarchy-toggle-nightlight')},
    # Omarchy
    {'id': 'menu', 'group': 'Omarchy', 'label': 'Omarchy menu', 'hint': 'The main menu.', 'spec': _exec('omarchy-menu toggle')},
    {'id': 'emoji', 'group': 'Omarchy', 'label': 'Emoji picker', 'hint': 'Search and insert an emoji.', 'spec': _exec('omarchy-menu-emoji')},
    {'id': 'clipboard', 'group': 'Omarchy', 'label': 'Clipboard history', 'hint': 'Pick something you copied earlier.', 'spec': _exec('omarchy-menu-clipboard')},
    {'id': 'keybindings', 'group': 'Omarchy', 'label': 'Keybindings', 'hint': 'Search every shortcut.', 'spec': _exec('omarchy-menu-keybindings')},
    {'id': 'shot-region', 'group': 'Omarchy', 'label': 'Screenshot a region', 'hint': 'Select an area and capture it.', 'spec': _exec('omarchy-capture-screenshot region')},
    {'id': 'shot-full', 'group': 'Omarchy', 'label': 'Screenshot the screen', 'hint': 'Capture everything.', 'spec': _exec('omarchy-capture-screenshot fullscreen')},
    {'id': 'record', 'group': 'Omarchy', 'label': 'Screen recording', 'hint': 'Start or stop recording.', 'spec': _exec('omarchy-capture-screenrecording')},
    {'id': 'lock', 'group': 'Omarchy', 'label': 'Lock the screen', 'hint': 'Lock now.', 'spec': _exec('omarchy-system-lock')},
    {'id': 'screensaver', 'group': 'Omarchy', 'label': 'Screensaver', 'hint': 'Start the Omarchy screensaver.', 'spec': _exec('omarchy-launch-screensaver')},
    {'id': 'bar', 'group': 'Omarchy', 'label': 'Toggle the bar', 'hint': 'Hide or show the top bar.', 'spec': _exec('omarchy-toggle-bar toggle')},
    {'id': 'dnd', 'group': 'Omarchy', 'label': 'Do not disturb', 'hint': 'Silence notifications, or let them back.', 'spec': _exec('omarchy-toggle-notification-silencing')},
    {'id': 'terminal', 'group': 'Omarchy', 'label': 'New terminal', 'hint': 'Open a terminal.', 'spec': _exec('omarchy-launch-terminal')},
    {'id': 'browser', 'group': 'Omarchy', 'label': 'Browser', 'hint': 'Open or focus the browser.', 'spec': _exec('omarchy-launch-browser')},
    {'id': 'files', 'group': 'Omarchy', 'label': 'Files', 'hint': 'Open the file manager.', 'spec': _exec('omarchy-launch-nautilus')},
    # Media & audio
    {'id': 'vol-up', 'group': 'Media & audio', 'label': 'Volume up', 'hint': 'Raise the volume with the OSD.', 'spec': _exec('omarchy-audio-output-volume raise')},
    {'id': 'vol-down', 'group': 'Media & audio', 'label': 'Volume down', 'hint': 'Lower the volume with the OSD.', 'spec': _exec('omarchy-audio-output-volume lower')},
    {'id': 'mute', 'group': 'Media & audio', 'label': 'Mute', 'hint': 'Toggle mute.', 'spec': _exec('omarchy-audio-output-volume mute-toggle')},
    {'id': 'mic-mute', 'group': 'Media & audio', 'label': 'Mute microphone', 'hint': 'Toggle the mic.', 'spec': _exec('omarchy-audio-input-mute')},
    {'id': 'audio-switch', 'group': 'Media & audio', 'label': 'Switch audio output', 'hint': 'Next speaker or headset.', 'spec': _exec('omarchy-audio-output-switch')},
    {'id': 'bright-up', 'group': 'Media & audio', 'label': 'Brightness up', 'hint': 'Screen brighter by 5%.', 'requires': 'omarchy-brightness-display', 'spec': _exec('omarchy-brightness-display +5%')},
    {'id': 'bright-down', 'group': 'Media & audio', 'label': 'Brightness down', 'hint': 'Screen dimmer by 5%.', 'requires': 'omarchy-brightness-display', 'spec': _exec('omarchy-brightness-display 5%-')},
    {'id': 'play-pause', 'group': 'Media & audio', 'label': 'Play / pause', 'hint': 'Needs playerctl.', 'requires': 'playerctl', 'spec': _exec('playerctl play-pause')},
    {'id': 'track-next', 'group': 'Media & audio', 'label': 'Next track', 'hint': 'Needs playerctl.', 'requires': 'playerctl', 'spec': _exec('playerctl next')},
    {'id': 'track-prev', 'group': 'Media & audio', 'label': 'Previous track', 'hint': 'Needs playerctl.', 'requires': 'playerctl', 'spec': _exec('playerctl previous')},
    # Zoom
    {'id': 'zoom', 'group': 'Zoom', 'label': 'Zoom the screen ×2', 'hint': 'Toggle a 2× zoom at the cursor. Made for pinches.', 'spec': _native('cursor_zoom', zoom_level=2)},
    {'id': 'zoom-live', 'group': 'Zoom', 'label': 'Zoom with the pinch', 'hint': 'Zoom follows the pinch live. Made for pinches.', 'spec': _native('cursor_zoom', zoom_level=1, mode='live')},
    # Trackpad Pulse
    {'id': 'pulse-open', 'group': 'Trackpad Pulse', 'label': 'Open Trackpad Pulse', 'hint': 'The dashboard.', 'spec': _exec('omarchy-shell nixfred.trackpad-pulse toggle')},
    {'id': 'pulse-optimize', 'group': 'Trackpad Pulse', 'label': 'Optimize for my hand', 'hint': 'A fresh proposal on Pointer feel.', 'spec': _exec('omarchy-shell nixfred.trackpad-pulse optimize')},
    {'id': 'pad-off', 'group': 'Trackpad Pulse', 'label': 'Trackpad off', 'hint': 'Switch the pad off; turn it back on from the bar icon.', 'spec': _exec('omarchy-shell nixfred.trackpad-pulse enable false')},
]
CATALOGUE_BY_ID = {a['id']: a for a in CATALOGUE}
# Fullscreen launches. Omarchy's launchers go through setsid and uwsm-app, so a
# window is never a child of the gesture's shell and Hyprland's [fullscreen]
# exec prefix cannot attach. The recorder launches, watches the client list
# for the window that appears, focuses it by address and fullscreens it.
FULLSCREEN_WAIT = 8.0
APP_ID_RE = re.compile(r'^[A-Za-z0-9._@+-]{1,120}$')


def desktop_dirs():
    home = os.environ.get('XDG_DATA_HOME') or str(Path.home() / '.local/share')
    dirs = [home + '/applications']
    for d in (os.environ.get('XDG_DATA_DIRS') or '/usr/local/share:/usr/share').split(':'):
        if d:
            dirs.append(d.rstrip('/') + '/applications')
    return dirs


def desktop_apps():
    """Launchable desktop entries, first one wins per id, sorted by name."""
    seen, apps = set(), []
    for d in desktop_dirs():
        for f in sorted(glob.glob(d + '/*.desktop')):
            base = os.path.basename(f)[:-8]
            if base in seen or not APP_ID_RE.match(base):
                continue
            cp = configparser.RawConfigParser(strict=False, interpolation=None)
            try:
                cp.read(f, encoding='utf-8')
            except (configparser.Error, OSError, UnicodeDecodeError):
                continue
            if 'Desktop Entry' not in cp:
                continue
            e = cp['Desktop Entry']
            if e.get('Type', '') != 'Application' or e.get('NoDisplay', 'false').lower() == 'true' or e.get('Hidden', 'false').lower() == 'true' or not e.get('Exec'):
                continue
            seen.add(base)
            apps.append({'id': base, 'name': (e.get('Name') or base)[:60], 'file': f})
    apps.sort(key=lambda a: a['name'].lower())
    return apps


def dynamic_actions():
    launcher = shlex.join([sys.executable, COLLECTOR, 'open-fullscreen'])
    out = [{'id': 'term-full', 'group': 'Fullscreen apps', 'label': 'Terminal (default)', 'hint': 'Open the default terminal and fullscreen it.',
            'spec': _exec(launcher + ' terminal')}]
    for a in desktop_apps():
        out.append({'id': 'app:' + a['id'], 'group': 'Fullscreen apps', 'label': a['name'], 'hint': 'Open ' + a['name'] + ' and fullscreen its window.',
                    'spec': _exec(launcher + ' ' + shlex.quote('app:' + a['id']))})
    return out


def all_actions():
    by_id = dict(CATALOGUE_BY_ID)
    for a in dynamic_actions():
        by_id.setdefault(a['id'], a)
    return by_id


def new_window(before, after):
    """The first mapped, non-special window in `after` that was not in `before`. Pure."""
    known = {w.get('address') for w in before}
    for w in after:
        if w.get('address') in known or not w.get('mapped', True):
            continue
        ws = w.get('workspace') or {}
        if isinstance(ws, dict) and int(ws.get('id', 0) or 0) < 0:
            continue
        return w
    return None


def clients():
    try:
        out = subprocess.run(['hyprctl', 'clients', '-j'], capture_output=True, text=True, timeout=3, check=False).stdout
        value = json.loads(out or '[]')
        return value if isinstance(value, list) else []
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def open_fullscreen(target):
    if target == 'terminal':
        argv = ['omarchy-launch-terminal']
        label = 'the terminal'
    elif target.startswith('app:') and APP_ID_RE.match(target[4:]) and any(a['id'] == target[4:] for a in desktop_apps()):
        argv = ['gtk-launch', target[4:]]
        label = target[4:]
    else:
        raise RuntimeError('Unknown app.')
    before = clients()
    subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + FULLSCREEN_WAIT
    while time.monotonic() < deadline:
        time.sleep(0.1)
        w = new_window(before, clients())
        if w:
            addr = str(w.get('address'))
            if not re.fullmatch(r'0x[0-9a-fA-F]+', addr):
                break
            subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.focus({ window = "address:%s" })' % addr], capture_output=True, timeout=3, check=False)
            time.sleep(0.05)
            subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.window.fullscreen({ mode = "fullscreen" })'], capture_output=True, timeout=3, check=False)
            return {'message': 'Opened ' + label + ' fullscreen.', 'address': addr}
    return {'message': 'Launched ' + label + ', but no new window appeared within %.0f s to fullscreen.' % FULLSCREEN_WAIT}
DEFAULT_GESTURES = {'3-left': 'ws-slide', '3-right': 'ws-slide', '3-up': 'win-fullscreen', '3-down': 'ws-scratch',
                    '3-pinchin': 'none', '3-pinchout': 'none',
                    '4-left': 'theme-prev', '4-right': 'theme-next', '4-up': 'bg-next', '4-down': 'menu',
                    '4-pinchin': 'none', '4-pinchout': 'zoom'}


def gesture_catalogue():
    """The catalogue, minus actions whose command is not installed here."""
    out = []
    for a in CATALOGUE + dynamic_actions():
        entry = {k: a[k] for k in ('id', 'group', 'label', 'hint')}
        entry['pair'] = bool(a.get('pair'))
        entry['available'] = not a.get('requires') or bool(shutil.which(a['requires']))
        out.append(entry)
    current = None
    try:
        current = normalize_gestures(json.loads((STATE / 'gestures.json').read_text()))
    except (OSError, ValueError, RuntimeError):
        current = None
    return {'actions': out, 'slots': SLOTS, 'defaults': DEFAULT_GESTURES, 'file': str(GESTURES_LUA),
            'applied': GESTURES_LUA.exists(), 'current': current if GESTURES_LUA.exists() else None}


def lua_quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def normalize_gestures(assignments):
    """Validate a slot→action map from the panel. Unknown slots or actions are refused, not guessed."""
    if not isinstance(assignments, dict):
        raise RuntimeError('Gestures must be an object of slot → action.')
    out = {slot: 'none' for slot in SLOTS}
    known = all_actions()
    for slot, action in assignments.items():
        if slot not in out:
            raise RuntimeError('Unknown gesture slot: ' + str(slot)[:40])
        if action not in known:
            raise RuntimeError('Unknown action: ' + str(action)[:40])
        out[slot] = action
    # A pair action owns its whole axis: both directions say the same thing.
    for slot, action in list(out.items()):
        fingers, direction = slot.split('-')
        if direction in PARTNER and known[action].get('pair'):
            out['%s-%s' % (fingers, PARTNER[direction])] = action
    return out


def gestures_lua(assignments):
    """The Hyprland Lua for a validated map. Pair actions are emitted once per axis."""
    lines = ['do -- Managed by nixfred.trackpad-pulse. Change gestures in Trackpad Pulse.']
    emitted = set()
    known = all_actions()
    for slot in SLOTS:
        action = known.get(assignments.get(slot, 'none'), CATALOGUE_BY_ID['none'])
        spec = action['spec']
        if spec['kind'] == 'none':
            continue
        fingers, direction = slot.split('-')
        if action.get('pair'):
            direction = AXIS.get(direction, direction)
            if (fingers, direction) in emitted:
                continue
            emitted.add((fingers, direction))
        fields = ['fingers = %s' % fingers, 'direction = %s' % lua_quote(direction)]
        if spec['kind'] == 'native':
            fields.append('action = %s' % lua_quote(spec['action']))
            for key in ('workspace_name', 'mode'):
                if key in spec:
                    fields.append('%s = %s' % (key, lua_quote(spec[key])))
            if 'zoom_level' in spec:
                fields.append('zoom_level = %s' % spec['zoom_level'])
        elif spec['kind'] == 'exec':
            fields.append('action = function() hl.exec_cmd(%s) end' % lua_quote(spec['cmd']))
        else:
            fields.append('action = function() hl.dispatch(%s) end' % spec['lua'])
        lines.append('hl.gesture({ ' + ', '.join(fields) + ' })')
    return '\n'.join(lines + ['end']) + '\n'


def _reload_hyprland():
    sys.path.insert(0, str(PLUGIN_ROOT))
    import trackpads  # noqa: E402 - Trackpad Plus's bounded hyprctl and hardened writer
    trackpads.hypr('reload', 'config-only')


def gestures_apply(assignments):
    clean = normalize_gestures(assignments)
    sys.path.insert(0, str(PLUGIN_ROOT))
    import trackpads  # noqa: E402
    trackpads.atomic_write(GESTURES_LUA, gestures_lua(clean))
    _reload_hyprland()
    atomic(STATE, 'gestures.json', clean)
    live = sum(1 for a in clean.values() if a != 'none')
    return {'message': '%d gesture%s live in Hyprland.' % (live, '' if live == 1 else 's'), 'gestures': clean}


def gestures_remove():
    for path in (GESTURES_LUA, STATE / 'gestures.json'):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    _reload_hyprland()
    return {'message': 'Gesture file removed; Hyprland reloaded. Your own input.lua gestures, if any, are all that is left.'}


# ---- actions --------------------------------------------------------------
def unit_text(script):
    return ('[Unit]\nDescription=Trackpad Pulse: touch telemetry and seven days of history\n'
            'After=graphical-session.target\nPartOf=graphical-session.target\n\n'
            '[Service]\nType=simple\nExecStart=/usr/bin/python3 ' + str(script) + ' daemon\n'
            'Restart=on-failure\nRestartSec=5\nUMask=0077\nNice=10\nNoNewPrivileges=yes\n\n'
            '[Install]\nWantedBy=graphical-session.target\n')


def install_service():
    (STATE / RECORDER_STOPPED_MARKER).unlink(missing_ok=True)
    units = Path.home() / '.config/systemd/user'
    units.mkdir(parents=True, exist_ok=True)
    script = Path(__file__).resolve()
    (units / UNIT_NAME).write_text(unit_text(script))
    for args in (['daemon-reload'], ['enable', '--now', UNIT_NAME], ['restart', UNIT_NAME]):
        result = subprocess.run(['systemctl', '--user'] + args, capture_output=True, text=True, timeout=30, check=False)
        if result.returncode:
            raise RuntimeError('systemctl --user ' + ' '.join(args) + ': ' + (result.stderr.strip() or 'failed'))
    return {'message': 'Recorder started as ' + UNIT_NAME + '. History begins now.'}


def uninstall_service():
    (STATE / RECORDER_STOPPED_MARKER).touch()
    units = Path.home() / '.config/systemd/user'
    subprocess.run(['systemctl', '--user', 'disable', '--now', UNIT_NAME], capture_output=True, timeout=30, check=False)
    (units / UNIT_NAME).unlink(missing_ok=True)
    subprocess.run(['systemctl', '--user', 'daemon-reload'], capture_output=True, timeout=30, check=False)
    return {'message': 'Recorder stopped and its unit removed. History files were kept.'}


def service_status():
    result = subprocess.run(['systemctl', '--user', 'is-active', UNIT_NAME], capture_output=True, text=True, timeout=10, check=False)
    return result.stdout.strip() or 'unknown'


def ensure_service():
    """Start the recorder if nothing has. `omarchy plugin add` publishes the
    panel but runs no installer, so on a fresh machine the recorder stayed
    offline until someone found Start the recorder. A deliberate Stop wins."""
    status = service_status()
    if (STATE / RECORDER_STOPPED_MARKER).exists():
        return {'service': status, 'started': False, 'reason': 'stopped by you'}
    if status in ('active', 'activating', 'reloading'):
        return {'service': status, 'started': False}
    install_service()
    return {'service': service_status(), 'started': True}


def privileged(script, what):
    """Run one fixed root command through polkit. The text is a constant above;
    nothing from a snapshot, a device name or the panel reaches it."""
    if not shutil.which('pkexec'):
        raise RuntimeError('pkexec is not installed; run this as root instead:\n' + script)
    try:
        result = subprocess.run(['pkexec', 'sh', '-c', script], capture_output=True, text=True, timeout=120, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError('The polkit prompt did not complete.')
    if result.returncode == 126 or result.returncode == 127:
        raise RuntimeError('Authorisation was cancelled; nothing changed.')
    if result.returncode:
        raise RuntimeError(what + ' failed: ' + (result.stderr.strip().splitlines() or ['no reason given'])[-1][:160])
    return result


def grant_access():
    # umask 022: this process runs at 077 for its own state files and pkexec
    # carries that into the shell, which left the rule readable by root alone.
    # udev honoured it anyway; the panel could not confirm it was there.
    script = ('set -e; umask 022; printf %s ' + shlex.quote(UDEV_RULE) + ' > ' + shlex.quote(str(UDEV_RULE_PATH))
              + '; udevadm control --reload; udevadm trigger --subsystem-match=input --action=change; udevadm settle --timeout=5 || true')
    privileged(script, 'Installing the udev rule')
    return {'message': 'Touchpad access granted through ' + str(UDEV_RULE_PATH) + '. The recorder picks it up within ten seconds.'}


def revoke_access():
    # Dropping the tag does not take back an ACL logind already granted, so
    # the caller's entry is stripped from every touchpad node explicitly.
    # PKEXEC_UID is set by pkexec itself; nothing from here names the user.
    script = ('set -e; rm -f ' + shlex.quote(str(UDEV_RULE_PATH)) + '; udevadm control --reload; '
              'for n in /dev/input/event*; do if udevadm info -q property -n "$n" 2>/dev/null | grep -q "^ID_INPUT_TOUCHPAD=1$"; '
              'then setfacl -x "u:$PKEXEC_UID" "$n" 2>/dev/null || true; fi; done')
    privileged(script, 'Removing the udev rule')
    return {'message': 'The udev rule is gone. Finger telemetry stops at the next scan; cursor-only continues.'}


def visit(link):
    url = LINKS.get(link)
    if not url:
        raise RuntimeError('Unknown link.')
    if not shutil.which('xdg-open'):
        raise RuntimeError('No xdg-open on PATH. The address is ' + url)
    subprocess.Popen(['xdg-open', url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return {'message': 'Handed ' + url + ' to your browser.'}


def one_shot():
    rec = Recorder()
    rec.scan(time.time())
    value = rec.snapshot(time.time())
    value['service'] = service_status()
    for fd, _ in rec.pads.values():
        os.close(fd)
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['daemon', 'snapshot', 'install-service', 'uninstall-service', 'ensure-service', 'grant-access', 'revoke-access', 'visit', 'udev-rule',
                                           'optimize', 'optimize-applied', 'optimize-keep', 'hint', 'gestures-catalogue', 'gestures-apply', 'gestures-remove',
                                           'theme-next', 'theme-prev', 'theme-random', 'report', 'auto-off-on', 'auto-off-off', 'stray-guard-on', 'stray-guard-off', 'open-fullscreen'])
    parser.add_argument('payload', nargs='?', default='{}', help='JSON for optimize / optimize-applied')
    parser.add_argument('--link', choices=sorted(LINKS))
    args = parser.parse_args()
    os.umask(0o077)
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        if args.action == 'daemon':
            Recorder().run()
            return
        if args.action == 'udev-rule':
            print(UDEV_RULE, end='')
            return
        if args.action in ('optimize', 'optimize-applied', 'optimize-keep', 'gestures-apply'):
            try:
                payload = json.loads(args.payload or '{}')
            except ValueError:
                raise RuntimeError('This action needs a JSON payload.')
            if not isinstance(payload, dict):
                raise RuntimeError('The payload must be an object.')
            value = {'optimize': optimize, 'optimize-applied': optimize_applied, 'optimize-keep': optimize_keep, 'gestures-apply': gestures_apply}[args.action](payload)
        elif args.action == 'hint':
            write_hint(db_open(), time.time())
            value = json.loads((STATE / 'hint.json').read_text())
        elif args.action == 'gestures-catalogue':
            value = gesture_catalogue()
        elif args.action == 'open-fullscreen':
            value = open_fullscreen(str(args.payload or ''))
        elif args.action == 'report':
            today = Recorder._fresh_today(None, time.time())
            try:
                saved = json.loads((STATE / 'today.json').read_text())
                if saved.get('day') == today['day']:
                    today.update(saved)
            except (OSError, ValueError):
                pass
            value = report(db_open(), today, load_log(), time.time())
        elif args.action in ('stray-guard-on', 'stray-guard-off'):
            marker = STATE / STRAY_GUARD_MARKER
            if args.action == 'stray-guard-on':
                marker.touch()
                value = {'message': 'Put-back is on: after a stray touch the cursor goes back to where it was, 0.3 s after the finger lifts.'}
            else:
                marker.unlink(missing_ok=True)
                value = {'message': 'Put-back is off. Stray touches are still counted.'}
        elif args.action in ('auto-off-on', 'auto-off-off'):
            marker = STATE / AUTO_OFF_MARKER
            if args.action == 'auto-off-on':
                marker.touch()
                value = {'message': 'Auto-off is on: the pad goes off after 15 s of mouse use and comes back on a tap or a real move.'}
            else:
                marker.unlink(missing_ok=True)
                value = {'message': 'Auto-off is off. If the pad was off, the recorder switches it back on within two seconds.'}
        elif args.action == 'gestures-remove':
            value = gestures_remove()
        elif args.action.startswith('theme-'):
            value = theme_step(args.action[6:])
        else:
            value = {'snapshot': one_shot, 'install-service': install_service, 'uninstall-service': uninstall_service,
                     'ensure-service': ensure_service, 'grant-access': grant_access, 'revoke-access': revoke_access}.get(args.action, lambda: visit(args.link))()
        print(json.dumps(value))
    except Exception as e:  # noqa: BLE001 - every failure is reported as JSON for the panel
        print(json.dumps({'error': str(e)}))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
